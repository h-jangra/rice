const std = @import("std");
const Allocator = std.mem.Allocator;
const clean = @import("clean.zig");

const builtin = @import("builtin");

var process_io: ?std.Io = null;
var process_environ: ?std.process.Environ = null;

pub fn setProcessIo(io: std.Io) void {
    process_io = io;
}

pub fn setProcessEnviron(env: std.process.Environ) void {
    process_environ = env;
}

pub fn getProcessIo() std.Io {
    if (process_io) |io| return io;
    if (builtin.is_test) return std.testing.io;
    unreachable;
}

pub fn getProcessEnviron() std.process.Environ {
    if (process_environ) |env| return env;
    return .{
        .block = switch (builtin.os.tag) {
            .windows => .global,
            else => .empty,
        },
    };
}

pub fn getHomeDir(allocator: Allocator) ![]u8 {
    const env = getProcessEnviron();
    if (std.process.Environ.getAlloc(env, allocator, "HOME")) |h| {
        // Clean trailing slash
        const trimmed = std.mem.trimEnd(u8, h, "/\\");
        if (trimmed.len < h.len) {
            const res = try allocator.dupe(u8, trimmed);
            allocator.free(h);
            return res;
        }
        return h;
    } else |_| {}

    if (std.process.Environ.getAlloc(env, allocator, "USERPROFILE")) |h| {
        const trimmed = std.mem.trimEnd(u8, h, "/\\");
        if (trimmed.len < h.len) {
            const res = try allocator.dupe(u8, trimmed);
            allocator.free(h);
            return res;
        }
        return h;
    } else |_| {}

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

    if (std.mem.startsWith(u8, s, "~")) {
        return error.UnsupportedTildeExpansion;
    }

    if (std.fs.path.isAbsolute(s)) {
        return clean.cleanPath(allocator, s);
    }

    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(getProcessIo(), &cwd_buf) catch return error.CannotGetCwd;
    const cwd = cwd_buf[0..cwd_len];
    const joined = try std.fs.path.join(allocator, &[_][]const u8{ cwd, s });
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

    // Compute relative path from homeDir to target
    const clean_home = try clean.cleanPath(allocator, homeDir);
    defer allocator.free(clean_home);

    const clean_target = target;

    if (std.mem.eql(u8, clean_home, clean_target)) {
        return error.CannotManageEntireHomeRoot;
    }

    var rel: []const u8 = undefined;
    if (std.mem.startsWith(u8, clean_target, clean_home)) {
        var rest = clean_target[clean_home.len..];
        if (rest.len > 0 and (rest[0] == '/' or rest[0] == '\\')) {
            rest = rest[1..];
            rel = rest;
        } else {
            return error.PathOutsideHome;
        }
    } else {
        return error.PathOutsideHome;
    }

    const slash_rel = try clean.toSlashOwned(allocator, rel);
    defer allocator.free(slash_rel);

    if (std.mem.eql(u8, slash_rel, ".rice") or std.mem.startsWith(u8, slash_rel, ".rice/")) {
        return error.CannotManageRiceRepository;
    }
    if (std.mem.eql(u8, slash_rel, ".rice.ini")) {
        return error.RiceIniAutoManaged;
    }

    const config_path = try std.fmt.allocPrint(allocator, "~/{s}", .{slash_rel});
    errdefer allocator.free(config_path);

    const git_path = try allocator.dupe(u8, slash_rel);
    errdefer allocator.free(git_path);

    return ResolvedPaths{
        .config_path = config_path,
        .abs_path = target,
        .git_path = git_path,
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
    if (std.mem.trim(u8, userInput, " \t\r\n").len == 0) {
        return error.DestinationPathEmpty;
    }

    var target = try resolveUserPath(allocator, homeDir, userInput);
    errdefer allocator.free(target);

    if (!isContents and itemName.len > 0) {
        const base = std.fs.path.basename(target);
        var is_dir = false;
        if (std.Io.Dir.openDirAbsolute(getProcessIo(), target, .{})) |d| {
            var dir = d;
            dir.close(getProcessIo());
            is_dir = true;
        } else |_| {}

        if (is_dir or std.mem.endsWith(u8, userInput, "/") or std.mem.endsWith(u8, userInput, "\\") or std.ascii.eqlIgnoreCase(base, "downloads")) {
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
        var rest = target[clean_home.len..];
        if (rest.len > 0 and (rest[0] == '/' or rest[0] == '\\')) {
            rest = rest[1..];
            rel = rest;
        } else if (rest.len == 0) {
            return error.CannotManageEntireHomeRoot;
        } else {
            is_outside = true;
        }
    } else {
        is_outside = true;
    }

    if (is_outside) {
        const cfg_p = try allocator.dupe(u8, target);
        return InstallDestResult{
            .config_path = cfg_p,
            .abs_path = target,
            .is_outside_home = true,
        };
    }

    const slash_rel = try clean.toSlashOwned(allocator, rel);
    defer allocator.free(slash_rel);

    if (std.mem.eql(u8, slash_rel, ".rice") or std.mem.startsWith(u8, slash_rel, ".rice/")) {
        return error.CannotManageRiceRepository;
    }
    if (std.mem.eql(u8, slash_rel, ".rice.ini")) {
        return error.RiceIniAutoManaged;
    }

    const cfg_p = try std.fmt.allocPrint(allocator, "~/{s}", .{slash_rel});
    return InstallDestResult{
        .config_path = cfg_p,
        .abs_path = target,
        .is_outside_home = false,
    };
}
