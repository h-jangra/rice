const std = @import("std");
const Allocator = std.mem.Allocator;
const config = @import("../config.zig");
const paths = @import("../paths/mod.zig");

pub fn runGitInDir(allocator: Allocator, dir: []const u8, args: []const []const u8) ![]u8 {
    return runGitInDirQuiet(allocator, dir, args, false);
}

pub fn execGitInDir(allocator: Allocator, dir: []const u8, args: []const []const u8) !void {
    const out = try runGitInDirQuiet(allocator, dir, args, false);
    allocator.free(out);
}

pub fn execGitInDirQuiet(allocator: Allocator, dir: []const u8, args: []const []const u8) !void {
    const out = try runGitInDirQuiet(allocator, dir, args, true);
    allocator.free(out);
}

pub fn runGitInDirQuiet(allocator: Allocator, dir: []const u8, args: []const []const u8, quiet: bool) ![]u8 {
    var cmd_list: std.ArrayList([]const u8) = .empty;
    defer cmd_list.deinit(allocator);
    try cmd_list.append(allocator, "git");
    try cmd_list.appendSlice(allocator, args);

    var env_map = try std.process.Environ.createMap(paths.getProcessEnviron(), allocator);
    defer env_map.deinit();
    try env_map.put("GIT_TERMINAL_PROMPT", "0");

    const res = try std.process.run(allocator, paths.getProcessIo(), .{
        .argv = cmd_list.items,
        .cwd = .{ .path = dir },
        .environ_map = &env_map,
    });
    defer allocator.free(res.stderr);

    if (res.term != .exited or res.term.exited != 0) {
        defer allocator.free(res.stdout);
        if (!quiet) {
            var err_str = std.mem.trim(u8, res.stderr, " \t\r\n");
            if (err_str.len == 0) err_str = std.mem.trim(u8, res.stdout, " \t\r\n");
            if (err_str.len > 0) std.debug.print("{s}\n", .{err_str});
        }
        return error.GitInDirFailed;
    }
    return res.stdout;
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
    var list: std.ArrayList(DiscoveredCandidate) = .empty;
    const raw = std.mem.trim(u8, name, " \t\r\n");
    if (raw.len == 0) return list;

    var cleaned = raw;
    if (std.mem.startsWith(u8, cleaned, "~/") or std.mem.startsWith(u8, cleaned, "~\\") or std.mem.startsWith(u8, cleaned, "./")) {
        cleaned = cleaned[2..];
    } else if (std.mem.indexOf(u8, cleaned, "/.config/")) |idx| {
        cleaned = cleaned[idx + 1 ..];
    } else if (std.mem.startsWith(u8, cleaned, "/")) {
        const base = std.fs.path.basename(cleaned);
        if (base.len > 0) cleaned = base;
    }
    cleaned = std.mem.trimEnd(u8, cleaned, "/\\");

    if (cleaned.len == 0 or std.mem.eql(u8, cleaned, ".") or std.mem.startsWith(u8, cleaned, "..")) {
        return list;
    }

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    const addCand = struct {
        fn add(al: Allocator, cand_list: *std.ArrayList(DiscoveredCandidate), seen_map: *std.StringHashMap(void), rpath: []const u8, dpath: []const u8) !void {
            if (seen_map.contains(rpath)) return;
            try seen_map.put(rpath, {});
            try cand_list.append(al, .{
                .repo_path = try al.dupe(u8, rpath),
                .dest_config_path = try al.dupe(u8, dpath),
            });
        }
    }.add;

    const dp0 = try std.fmt.allocPrint(allocator, "~/{s}", .{cleaned});
    defer allocator.free(dp0);
    try addCand(allocator, &list, &seen, cleaned, dp0);

    if (std.mem.startsWith(u8, cleaned, ".config/")) {
        const sub = cleaned[".config/".len..];
        if (sub.len > 0) {
            const dp = try std.fmt.allocPrint(allocator, "~/.config/{s}", .{sub});
            defer allocator.free(dp);
            try addCand(allocator, &list, &seen, sub, dp);
        }
    } else {
        const rp = try std.fmt.allocPrint(allocator, ".config/{s}", .{cleaned});
        defer allocator.free(rp);
        const dp = try std.fmt.allocPrint(allocator, "~/.config/{s}", .{cleaned});
        defer allocator.free(dp);
        try addCand(allocator, &list, &seen, rp, dp);
    }

    var core_name = cleaned;
    if (std.mem.startsWith(u8, core_name, ".config/")) core_name = core_name[".config/".len..];
    if (std.mem.indexOfScalar(u8, core_name, '/') == null) {
        var base_name = core_name;
        if (std.mem.startsWith(u8, base_name, ".")) base_name = base_name[1..];

        if (base_name.len > 0) {
            const rp1 = try std.fmt.allocPrint(allocator, ".config/{s}", .{base_name});
            defer allocator.free(rp1);
            const dp1 = try std.fmt.allocPrint(allocator, "~/.config/{s}", .{base_name});
            defer allocator.free(dp1);
            try addCand(allocator, &list, &seen, rp1, dp1);
            try addCand(allocator, &list, &seen, base_name, dp1);

            const rp3 = try std.fmt.allocPrint(allocator, ".{s}", .{base_name});
            defer allocator.free(rp3);
            const dp3 = try std.fmt.allocPrint(allocator, "~/." ++ "{s}", .{base_name});
            defer allocator.free(dp3);
            try addCand(allocator, &list, &seen, rp3, dp3);
        }
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

fn anyMatchEqlIgnoreCase(needles: []const []const u8, haystacks: []const []const u8) bool {
    for (needles) |n| {
        for (haystacks) |h| {
            if (std.ascii.eqlIgnoreCase(n, h)) return true;
        }
    }
    return false;
}

pub fn resolveRemoteConfig(allocator: Allocator, tmpDir: []const u8, _: []const u8, name: []const u8) !ResolvedRemoteConfig {
    if (runGitInDirQuiet(allocator, tmpDir, &.{ "cat-file", "-e", "FETCH_HEAD:.rice.ini" }, true)) |out| {
        allocator.free(out);

        _ = execGitInDir(allocator, tmpDir, &.{ "sparse-checkout", "init", "--no-cone" }) catch {};
        _ = execGitInDir(allocator, tmpDir, &.{ "sparse-checkout", "set", "--no-cone", ".rice.ini" }) catch {};
        execGitInDir(allocator, tmpDir, &.{ "checkout", "--detach", "FETCH_HEAD" }) catch {
            return error.CheckoutRiceIniFailed;
        };

        const ini_path = try std.fs.path.join(allocator, &.{ tmpDir, ".rice.ini" });
        defer allocator.free(ini_path);

        const remote_cfg = config.loadConfig(allocator, ini_path) catch return error.NoManagedPathsInRemoteRiceIni;
        defer {
            remote_cfg.deinit();
            allocator.destroy(remote_cfg);
        }

        if (remote_cfg.files.items.len == 0) return error.NoManagedPathsInRemoteRiceIni;

        var matches: std.ArrayList([]const u8) = .empty;
        defer matches.deinit(allocator);

        const name_raw = std.mem.trim(u8, name, " \t\r\n");
        var name_clean = name_raw;
        if (std.mem.startsWith(u8, name_clean, "~/") or std.mem.startsWith(u8, name_clean, "./")) {
            name_clean = name_clean[2..];
        } else if (std.mem.indexOf(u8, name_clean, "/.config/")) |idx| {
            name_clean = name_clean[idx + 1 ..];
        }

        const name_base = std.fs.path.basename(name_clean);
        const name_base_no_dot = if (std.mem.startsWith(u8, name_base, ".")) name_base[1..] else name_base;
        const name_candidates = [_][]const u8{ name_raw, name_clean, name_base, name_base_no_dot };

        for (remote_cfg.files.items) |f| {
            const norm = try config.normalizeConfigFileEntry(allocator, f);
            defer allocator.free(norm);
            if (norm.len == 0) continue;

            const git_p = if (std.mem.startsWith(u8, norm, "~/")) norm[2..] else norm;
            const base = std.fs.path.basename(git_p);
            const base_no_dot = if (std.mem.startsWith(u8, base, ".")) base[1..] else base;
            const target_fields = [_][]const u8{ norm, git_p, base, base_no_dot };

            var is_match = anyMatchEqlIgnoreCase(&name_candidates, &target_fields);

            if (!is_match) {
                var norm_no_tilde = norm;
                if (std.mem.startsWith(u8, norm_no_tilde, "~/")) norm_no_tilde = norm_no_tilde[2..];

                if ((std.mem.startsWith(u8, git_p, name_clean) and git_p.len > name_clean.len and git_p[name_clean.len] == '/') or
                    (std.mem.startsWith(u8, norm, name_raw) and norm.len > name_raw.len and norm[name_raw.len] == '/') or
                    (std.mem.startsWith(u8, norm_no_tilde, name_clean) and norm_no_tilde.len > name_clean.len and norm_no_tilde[name_clean.len] == '/'))
                {
                    is_match = true;
                }

                if (std.fs.path.dirname(git_p)) |parent_dir| {
                    const parent_base = std.fs.path.basename(parent_dir);
                    const parent_fields = [_][]const u8{ parent_dir, parent_base };
                    if (anyMatchEqlIgnoreCase(&name_candidates, &parent_fields)) is_match = true;
                }
            }

            if (is_match) try matches.append(allocator, f);
        }

        if (matches.items.len == 0) {
            std.debug.print("Error: configuration not found: {s}\n", .{name});
            return error.ConfigNotFound;
        }
        if (matches.items.len > 1) {
            std.debug.print("Error: configuration name is ambiguous: {s}\nMatching paths:\n", .{name});
            for (matches.items) |m| std.debug.print("  {s}\n", .{m});
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
        candidates.deinit(allocator);
    }

    var matches: std.ArrayList(DiscoveredCandidate) = .empty;
    defer matches.deinit(allocator);

    for (candidates.items) |c| {
        const spec = try std.fmt.allocPrint(allocator, "FETCH_HEAD:{s}", .{c.repo_path});
        defer allocator.free(spec);
        if (runGitInDirQuiet(allocator, tmpDir, &.{ "cat-file", "-e", spec }, true)) |out| {
            allocator.free(out);
            try matches.append(allocator, c);
        } else |_| {}
    }

    if (matches.items.len == 0) {
        std.debug.print("Error: configuration not found: {s}\n", .{name});
        return error.ConfigNotFound;
    }
    if (matches.items.len > 1) {
        std.debug.print("Error: configuration name is ambiguous: {s}\nMatching paths:\n", .{name});
        for (matches.items) |m| std.debug.print("  {s}\n", .{m.repo_path});
        return error.ConfigAmbiguous;
    }

    return ResolvedRemoteConfig{
        .repo_path = try allocator.dupe(u8, matches.items[0].repo_path),
        .dest_config_path = try allocator.dupe(u8, matches.items[0].dest_config_path),
    };
}

