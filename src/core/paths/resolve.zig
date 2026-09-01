const std = @import("std");
const Allocator = std.mem.Allocator;
const clean = @import("clean.zig");
const builtin = @import("builtin");

var process_io: ?std.Io = null;
var process_environ: ?std.process.Environ = null;

pub fn setProcessIo(io: std.Io) void { process_io = io; }
pub fn setProcessEnviron(env: std.process.Environ) void { process_environ = env; }

pub fn getProcessIo() std.Io {
    if (process_io) |io| return io;
    if (builtin.is_test) return std.testing.io;
    unreachable;
}

pub fn getProcessEnviron() std.process.Environ {
    if (process_environ) |env| return env;
    if (builtin.is_test) return std.testing.environ;
    return .{ .block = if (builtin.os.tag == .windows) .global else .empty };
}

pub fn getHomeDir(allocator: Allocator) ![]u8 {
    const env = getProcessEnviron();
    for ([_][]const u8{ "HOME", "USERPROFILE" }) |var_name| {
        if (std.process.Environ.getAlloc(env, allocator, var_name)) |h| {
            const trimmed = std.mem.trimEnd(u8, h, "/\\");
            if (trimmed.len < h.len) {
                const res = try allocator.dupe(u8, trimmed);
                allocator.free(h);
                return res;
            }
            return h;
        } else |_| {}
    }
    return error.HomeDirNotFound;
}

pub fn getRiceDir(allocator: Allocator, homeDir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &[_][]const u8{ homeDir, ".rice" });
}

pub fn getRiceIniPath(allocator: Allocator, homeDir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &[_][]const u8{ homeDir, ".rice.ini" });
}

pub fn resolveUserPath(allocator: Allocator, homeDir: []const u8, input: []const u8) ![]u8 {
    const s = std.mem.trim(u8, input, " \t\r\n");
    if (s.len == 0) return error.PathCannotBeEmpty;
    if (std.mem.eql(u8, s, "~")) return error.CannotManageEntireHomeRoot;

    if (std.mem.startsWith(u8, s, "~/") or std.mem.startsWith(u8, s, "~\\")) {
        const joined = try std.fs.path.join(allocator, &[_][]const u8{ homeDir, s[2..] });
        defer allocator.free(joined);
        return clean.cleanPath(allocator, joined);
    }
    if (std.mem.startsWith(u8, s, "~")) return error.UnsupportedTildeExpansion;
    if (std.fs.path.isAbsolute(s)) return clean.cleanPath(allocator, s);

    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(getProcessIo(), &cwd_buf) catch return error.CannotGetCwd;
    const joined = try std.fs.path.join(allocator, &[_][]const u8{ cwd_buf[0..cwd_len], s });
    defer allocator.free(joined);
    return clean.cleanPath(allocator, joined);
}

pub const ResolvedPaths = struct {
    config_path: []u8,
    abs_path: []u8,
    git_path: []u8,

    pub fn deinit(self: *ResolvedPaths, allocator: Allocator) void {
        allocator.free(self.config_path);
        allocator.free(self.abs_path);
        allocator.free(self.git_path);
    }
};

pub fn resolvePath(allocator: Allocator, homeDir: []const u8, userInput: []const u8) !ResolvedPaths {
    const target = try resolveUserPath(allocator, homeDir, userInput);
    errdefer allocator.free(target);

    const clean_home = try clean.cleanPath(allocator, homeDir);
    defer allocator.free(clean_home);

    if (std.mem.eql(u8, clean_home, target)) return error.CannotManageEntireHomeRoot;

    if (!std.mem.startsWith(u8, target, clean_home)) return error.PathOutsideHome;
    const rest = target[clean_home.len..];
    if (rest.len == 0 or (rest[0] != '/' and rest[0] != '\\')) return error.PathOutsideHome;

    const slash_rel = try clean.toSlashOwned(allocator, rest[1..]);
    defer allocator.free(slash_rel);

    if (std.mem.eql(u8, slash_rel, ".rice") or std.mem.startsWith(u8, slash_rel, ".rice/")) {
        return error.CannotManageRiceRepository;
    }
    if (std.mem.eql(u8, slash_rel, ".rice.ini")) return error.RiceIniAutoManaged;

    return ResolvedPaths{
        .config_path = try std.fmt.allocPrint(allocator, "~/{s}", .{slash_rel}),
        .abs_path = target,
        .git_path = try allocator.dupe(u8, slash_rel),
    };
}

pub fn configPath(allocator: Allocator, homeDir: []const u8, userInput: []const u8) ![]u8 {
    const r = try resolvePath(allocator, homeDir, userInput);
    allocator.free(r.abs_path);
    allocator.free(r.git_path);
    return r.config_path;
}

pub fn absolutePath(allocator: Allocator, homeDir: []const u8, userInput: []const u8) ![]u8 {
    const r = try resolvePath(allocator, homeDir, userInput);
    allocator.free(r.config_path);
    allocator.free(r.git_path);
    return r.abs_path;
}

pub fn gitPath(allocator: Allocator, homeDir: []const u8, userInput: []const u8) ![]u8 {
    const r = try resolvePath(allocator, homeDir, userInput);
    allocator.free(r.config_path);
    allocator.free(r.abs_path);
    return r.git_path;
}

pub const InstallDestResult = struct {
    config_path: []u8,
    abs_path: []u8,
    is_outside_home: bool,

    pub fn deinit(self: *InstallDestResult, allocator: Allocator) void {
        allocator.free(self.config_path);
        allocator.free(self.abs_path);
    }
};

pub fn resolveInstallDestination(allocator: Allocator, homeDir: []const u8, userInput: []const u8, itemName: []const u8, isContents: bool) !InstallDestResult {
    const s = std.mem.trim(u8, userInput, " \t\r\n");
    if (s.len == 0) return error.DestinationPathEmpty;

    var target: []u8 = undefined;
    if (std.mem.startsWith(u8, s, "~/") or std.mem.startsWith(u8, s, "~\\")) {
        const joined = try std.fs.path.join(allocator, &[_][]const u8{ homeDir, s[2..] });
        defer allocator.free(joined);
        target = try clean.cleanPath(allocator, joined);
    } else if (std.mem.startsWith(u8, s, "./") or std.mem.startsWith(u8, s, ".\\") or std.mem.startsWith(u8, s, "../") or std.mem.startsWith(u8, s, "..\\") or std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) {
        target = try resolveUserPath(allocator, homeDir, s);
    } else if (std.fs.path.isAbsolute(s)) {
        target = try clean.cleanPath(allocator, s);
    } else {
        const joined = try std.fs.path.join(allocator, &[_][]const u8{ homeDir, s });
        defer allocator.free(joined);
        target = try clean.cleanPath(allocator, joined);
    }
    errdefer allocator.free(target);

    if (!isContents and itemName.len > 0) {
        const is_explicit_dot = std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..") or
            std.mem.eql(u8, s, "./") or std.mem.eql(u8, s, ".\\") or
            std.mem.eql(u8, s, "../") or std.mem.eql(u8, s, "..\\");
        const has_trailing_slash = std.mem.endsWith(u8, userInput, "/") or std.mem.endsWith(u8, userInput, "\\");

        var is_dir = false;
        if (std.Io.Dir.openDirAbsolute(getProcessIo(), target, .{})) |d| {
            var dir = d;
            dir.close(getProcessIo());
            is_dir = true;
        } else |_| {}

        if (is_explicit_dot or has_trailing_slash) {
            const joined = try std.fs.path.join(allocator, &[_][]const u8{ target, itemName });
            allocator.free(target);
            target = joined;
        } else if (is_dir or std.ascii.eqlIgnoreCase(std.fs.path.basename(target), "downloads")) {
            const base = std.fs.path.basename(target);
            if (!std.mem.eql(u8, base, itemName)) {
                const joined = try std.fs.path.join(allocator, &[_][]const u8{ target, itemName });
                allocator.free(target);
                target = joined;
            }
        }
    }

    const clean_home = try clean.cleanPath(allocator, homeDir);
    defer allocator.free(clean_home);

    var is_outside = false;
    var rel: []const u8 = "";

    if (std.mem.startsWith(u8, target, clean_home)) {
        const rest = target[clean_home.len..];
        if (rest.len > 0 and (rest[0] == '/' or rest[0] == '\\')) {
            rel = rest[1..];
        } else if (rest.len == 0) {
            return error.CannotManageEntireHomeRoot;
        } else {
            is_outside = true;
        }
    } else {
        is_outside = true;
    }

    if (is_outside) {
        return InstallDestResult{
            .config_path = try allocator.dupe(u8, target),
            .abs_path = target,
            .is_outside_home = true,
        };
    }

    const slash_rel = try clean.toSlashOwned(allocator, rel);
    defer allocator.free(slash_rel);

    if (std.mem.eql(u8, slash_rel, ".rice") or std.mem.startsWith(u8, slash_rel, ".rice/")) {
        return error.CannotManageRiceRepository;
    }
    if (std.mem.eql(u8, slash_rel, ".rice.ini")) return error.RiceIniAutoManaged;

    return InstallDestResult{
        .config_path = try std.fmt.allocPrint(allocator, "~/{s}", .{slash_rel}),
        .abs_path = target,
        .is_outside_home = false,
    };
}

