const std = @import("std");
const Allocator = std.mem.Allocator;
const config = @import("../config.zig");

pub fn runGitInDir(allocator: Allocator, dir: []const u8, args: []const []const u8) ![]u8 {
    var cmd_list = std.ArrayList([]const u8).init(allocator);
    defer cmd_list.deinit();
    try cmd_list.append("git");
    for (args) |a| try cmd_list.append(a);

    var child = std.process.Child.init(cmd_list.items, allocator);
    child.cwd = dir;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put("GIT_TERMINAL_PROMPT", "0");
    child.env_map = &env_map;

    try child.spawn();
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 10 * 1024 * 1024);
    errdefer allocator.free(stdout);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(stderr);

    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        var err_str = std.mem.trim(u8, stderr, " \t\r\n");
        if (err_str.len == 0) err_str = std.mem.trim(u8, stdout, " \t\r\n");
        if (err_str.len > 0) {
            std.debug.print("{s}\n", .{err_str});
        }
        return error.GitInDirFailed;
    }
    return stdout;
}

pub const DiscoveredCandidate = struct {
    repo_path: []u8,
    dest_config_path: []u8,

    pub fn deinit(self: *DiscoveredCandidate, allocator: Allocator) void {
        allocator.free(self.repo_path);
        allocator.free(self.dest_config_path);
    }
};

pub fn generateDiscoveryCandidates(allocator: Allocator, name: []const u8) !std.ArrayList(DiscoveredCandidate) {
    var list = std.ArrayList(DiscoveredCandidate).init(allocator);
    const raw = std.mem.trim(u8, name, " \t\r\n");
    if (raw.len == 0) return list;

    var cleaned = raw;
    if (std.mem.startsWith(u8, cleaned, "~/")) cleaned = cleaned[2..];
    if (std.mem.startsWith(u8, cleaned, "~\\")) cleaned = cleaned[2..];
    if (std.mem.startsWith(u8, cleaned, "./")) cleaned = cleaned[2..];
    cleaned = std.mem.trimRight(u8, cleaned, "/\\");

    if (cleaned.len == 0 or std.mem.eql(u8, cleaned, ".") or std.mem.startsWith(u8, cleaned, "..")) {
        return list;
    }

    var core_name = cleaned;
    if (std.mem.startsWith(u8, core_name, ".config/")) core_name = core_name[".config/".len..];
    var base_name = core_name;
    if (std.mem.startsWith(u8, base_name, ".")) base_name = base_name[1..];

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    const addCand = struct {
        fn add(al: Allocator, cand_list: *std.ArrayList(DiscoveredCandidate), seen_map: *std.StringHashMap(void), rpath: []const u8, dpath: []const u8) !void {
            if (seen_map.contains(rpath)) return;
            try seen_map.put(rpath, {});
            try cand_list.append(DiscoveredCandidate{
                .repo_path = try al.dupe(u8, rpath),
                .dest_config_path = try al.dupe(u8, dpath),
            });
        }
    }.add;

    if (base_name.len > 0) {
        const rp = try std.fmt.allocPrint(allocator, ".config/{s}", .{base_name});
        defer allocator.free(rp);
        const dp = try std.fmt.allocPrint(allocator, "~/.config/{s}", .{base_name});
        defer allocator.free(dp);
        try addCand(allocator, &list, &seen, rp, dp);
    }

    if (std.mem.indexOfScalar(u8, core_name, '/') != null) {
        const dp = try std.fmt.allocPrint(allocator, "~/{s}", .{core_name});
        defer allocator.free(dp);
        try addCand(allocator, &list, &seen, core_name, dp);
    } else if (base_name.len > 0) {
        const dp = try std.fmt.allocPrint(allocator, "~/.config/{s}", .{base_name});
        defer allocator.free(dp);
        try addCand(allocator, &list, &seen, base_name, dp);
    }

    if (base_name.len > 0 and std.mem.indexOfScalar(u8, core_name, '/') == null) {
        const rp = try std.fmt.allocPrint(allocator, ".{s}", .{base_name});
        defer allocator.free(rp);
        const dp = try std.fmt.allocPrint(allocator, "~/." ++ "{s}", .{base_name});
        defer allocator.free(dp);
        try addCand(allocator, &list, &seen, rp, dp);
    }

    if (std.mem.indexOfScalar(u8, cleaned, '/') != null and !std.mem.startsWith(u8, cleaned, ".config/")) {
        const dp = try std.fmt.allocPrint(allocator, "~/{s}", .{cleaned});
        defer allocator.free(dp);
        try addCand(allocator, &list, &seen, cleaned, dp);
    }

    return list;
}

pub const ResolvedRemoteConfig = struct {
    repo_path: []u8,
    dest_config_path: []u8,

    pub fn deinit(self: *ResolvedRemoteConfig, allocator: Allocator) void {
        allocator.free(self.repo_path);
        allocator.free(self.dest_config_path);
    }
};

pub fn resolveRemoteConfig(allocator: Allocator, tmpDir: []const u8, _: []const u8, name: []const u8) !ResolvedRemoteConfig {
    if (runGitInDir(allocator, tmpDir, &[_][]const u8{ "cat-file", "-e", "FETCH_HEAD:.rice.ini" })) |out| {
        allocator.free(out);

        _ = runGitInDir(allocator, tmpDir, &[_][]const u8{ "sparse-checkout", "init", "--no-cone" }) catch {};
        _ = runGitInDir(allocator, tmpDir, &[_][]const u8{ "sparse-checkout", "set", "--no-cone", ".rice.ini" }) catch {};
        if (runGitInDir(allocator, tmpDir, &[_][]const u8{ "checkout", "--detach", "FETCH_HEAD" })) |chk_out| {
            allocator.free(chk_out);
        } else |_| {
            return error.CheckoutRiceIniFailed;
        }

        const ini_path = try std.fs.path.join(allocator, &[_][]const u8{ tmpDir, ".rice.ini" });
        defer allocator.free(ini_path);

        const remote_cfg = config.loadConfig(allocator, ini_path) catch return error.NoManagedPathsInRemoteRiceIni;
        defer {
            remote_cfg.deinit();
            allocator.destroy(remote_cfg);
        }

        if (remote_cfg.files.items.len == 0) {
            return error.NoManagedPathsInRemoteRiceIni;
        }

        var matches = std.ArrayList([]const u8).init(allocator);
        defer matches.deinit();

        const name_clean = std.mem.trim(u8, name, " \t\r\n");
        var name_clean_no_tilde = name_clean;
        if (std.mem.startsWith(u8, name_clean_no_tilde, "~/")) name_clean_no_tilde = name_clean_no_tilde[2..];

        for (remote_cfg.files.items) |f| {
            const norm = try config.normalizeConfigFileEntry(allocator, f);
            defer allocator.free(norm);
            if (norm.len == 0) continue;

            const git_p = if (std.mem.startsWith(u8, norm, "~/")) norm[2..] else norm;
            const base = std.fs.path.basename(git_p);
            var base_no_dot = base;
            if (std.mem.startsWith(u8, base_no_dot, ".")) base_no_dot = base_no_dot[1..];

            if (std.mem.eql(u8, name_clean, norm) or
                std.mem.eql(u8, name_clean, git_p) or
                std.mem.eql(u8, name_clean_no_tilde, git_p) or
                std.mem.eql(u8, name_clean, base) or
                std.mem.eql(u8, name_clean, base_no_dot) or
                std.ascii.eqlIgnoreCase(name_clean, base) or
                std.ascii.eqlIgnoreCase(name_clean, base_no_dot) or
                std.ascii.eqlIgnoreCase(name_clean, git_p) or
                std.ascii.eqlIgnoreCase(name_clean, norm))
            {
                try matches.append(f);
            }
        }

        if (matches.items.len == 0) {
            std.debug.print("Error: configuration not found: {s}\n", .{name});
            return error.ConfigNotFound;
        }
        if (matches.items.len > 1) {
            std.debug.print("Error: configuration name is ambiguous: {s}\nMatching paths:\n", .{name});
            for (matches.items) |m| {
                std.debug.print("  {s}\n", .{m});
            }
            return error.ConfigAmbiguous;
        }

        const dest_config_path = try allocator.dupe(u8, matches.items[0]);
        var repo_path = dest_config_path;
        if (std.mem.startsWith(u8, repo_path, "~/")) {
            repo_path = try allocator.dupe(u8, repo_path[2..]);
        } else {
            repo_path = try allocator.dupe(u8, repo_path);
        }

        return ResolvedRemoteConfig{
            .repo_path = repo_path,
            .dest_config_path = dest_config_path,
        };
    } else |_| {}

    var candidates = try generateDiscoveryCandidates(allocator, name);
    defer {
        for (candidates.items) |*c| c.deinit(allocator);
        candidates.deinit();
    }

    var matches = std.ArrayList(DiscoveredCandidate).init(allocator);
    defer matches.deinit();

    for (candidates.items) |c| {
        const spec = try std.fmt.allocPrint(allocator, "FETCH_HEAD:{s}", .{c.repo_path});
        defer allocator.free(spec);
        if (runGitInDir(allocator, tmpDir, &[_][]const u8{ "cat-file", "-e", spec })) |out| {
            allocator.free(out);
            try matches.append(c);
        } else |_| {}
    }

    if (matches.items.len == 0) {
        std.debug.print("Error: configuration not found: {s}\n", .{name});
        return error.ConfigNotFound;
    }
    if (matches.items.len > 1) {
        std.debug.print("Error: configuration name is ambiguous: {s}\nMatching paths:\n", .{name});
        for (matches.items) |m| {
            std.debug.print("  {s}\n", .{m.repo_path});
        }
        return error.ConfigAmbiguous;
    }

    return ResolvedRemoteConfig{
        .repo_path = try allocator.dupe(u8, matches.items[0].repo_path),
        .dest_config_path = try allocator.dupe(u8, matches.items[0].dest_config_path),
    };
}
