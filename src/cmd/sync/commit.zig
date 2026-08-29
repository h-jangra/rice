const std = @import("std");
const Allocator = std.mem.Allocator;
const git_mod = @import("../../core/git/mod.zig");
const paths = @import("../../core/paths/mod.zig");
const config = @import("../../core/config.zig");
const repo = @import("../repo/mod.zig");
const fs = @import("../../core/fs.zig");

pub fn parseCommitMessage(allocator: Allocator, args: []const []const u8) !?[]u8 {
    if (args.len == 0) return null;

    const first = std.mem.trim(u8, args[0], " \t\r\n");
    if (std.mem.eql(u8, first, "-m") or std.mem.eql(u8, first, "--message")) {
        if (args.len < 2) {
            std.debug.print("Error: commit message required after {s}\n", .{first});
            return error.CommitMessageRequired;
        }
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        for (args[1..], 0..) |a, idx| {
            try buf.appendSlice(allocator, a);
            if (idx + 1 < args[1..].len) try buf.append(allocator, ' ');
        }
        const trimmed = std.mem.trim(u8, buf.items, " \t\r\n");
        if (trimmed.len == 0) {
            return error.CommitMessageEmpty;
        }
        return try allocator.dupe(u8, trimmed);
    }

    const prefixes = [_][]const u8{ "--message=", "-m=" };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, first, p)) {
            const msg = first[p.len..];
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            try buf.appendSlice(allocator, msg);
            if (args.len > 1) {
                try buf.append(allocator, ' ');
                for (args[1..], 0..) |a, idx| {
                    try buf.appendSlice(allocator, a);
                    if (idx + 1 < args[1..].len) try buf.append(allocator, ' ');
                }
            }
            const trimmed = std.mem.trim(u8, buf.items, " \t\r\n");
            if (trimmed.len == 0) {
                return error.CommitMessageEmpty;
            }
            return try allocator.dupe(u8, trimmed);
        }
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (args, 0..) |a, idx| {
        try buf.appendSlice(allocator, a);
        if (idx + 1 < args.len) try buf.append(allocator, ' ');
    }
    const trimmed = std.mem.trim(u8, buf.items, " \t\r\n");
    if (trimmed.len == 0) {
        return null;
    }
    return try allocator.dupe(u8, trimmed);
}

pub fn stageTrackedFiles(allocator: Allocator, git: *git_mod.Git, homeDir: []const u8, cfg: ?*const config.Config) !void {
    try git.add(&[_][]const u8{".rice.ini"});
    if (cfg == null) return;

    for (cfg.?.files.items) |f| {
        if (paths.absolutePath(allocator, homeDir, f)) |abs_p| {
            defer allocator.free(abs_p);
            if (paths.gitPath(allocator, homeDir, f)) |git_p| {
                defer allocator.free(git_p);

                var exists = false;
                if (fs.openFileAbsolute(abs_p, .{})) |file| {
                    file.close(paths.getProcessIo());
                    exists = true;
                } else |_| {
                    if (fs.openDirAbsolute(abs_p, .{})) |d| {
                        var dir = d;
                        dir.close(paths.getProcessIo());
                        exists = true;
                    } else |_| {}
                }

                if (exists) {
                    git.add(&[_][]const u8{git_p}) catch |err| {
                        std.debug.print("Warning: could not add '{s}': {s}\n", .{ git_p, @errorName(err) });
                    };
                } else {
                    git.addUpdate(&[_][]const u8{git_p}) catch |err| {
                        std.debug.print("Warning: could not update index for '{s}': {s}\n", .{ git_p, @errorName(err) });
                    };
                }
            } else |_| {}
        } else |_| {}
    }

    var all_git_files = git.getAllGitTrackedFiles() catch return;
    defer {
        for (all_git_files.items) |gf| allocator.free(gf);
        all_git_files.deinit(allocator);
    }

    var to_untrack: std.ArrayList([]const u8) = .empty;
    defer to_untrack.deinit(allocator);

    for (all_git_files.items) |gf| {
        if (std.mem.eql(u8, gf, ".rice.ini")) continue;

        var covered = false;
        for (cfg.?.files.items) |f| {
            if (paths.gitPath(allocator, homeDir, f)) |gp| {
                defer allocator.free(gp);
                if (std.mem.eql(u8, gf, gp) or (std.mem.startsWith(u8, gf, gp) and gf.len > gp.len and gf[gp.len] == '/')) {
                    covered = true;
                    break;
                }
            } else |_| {}
        }

        if (!covered) {
            try to_untrack.append(allocator, gf);
        }
    }

    if (to_untrack.items.len > 0) {
        _ = git.removeCached(to_untrack.items) catch {};
    }
}

const FileChange = struct {
    status: []u8,
    path: []u8,

    pub fn deinit(self: *FileChange, allocator: Allocator) void {
        allocator.free(self.status);
        allocator.free(self.path);
    }
};

pub fn generateAutoCommitMessage(allocator: Allocator, git: *git_mod.Git, homeDir: []const u8, cfg: ?*const config.Config) ![]u8 {
    const diff_out = git.output(&[_][]const u8{ "diff", "--cached", "--name-status" }) catch return try allocator.dupe(u8, "update dotfiles");
    defer allocator.free(diff_out);

    if (diff_out.len == 0) return try allocator.dupe(u8, "update dotfiles");

    var changes: std.ArrayList(FileChange) = .empty;
    defer {
        for (changes.items) |*c| c.deinit(allocator);
        changes.deinit(allocator);
    }

    var non_ini_changes: std.ArrayList(FileChange) = .empty;
    defer non_ini_changes.deinit(allocator);

    var lines = std.mem.splitScalar(u8, diff_out, '\n');
    while (lines.next()) |line| {
        var it = std.mem.splitScalar(u8, std.mem.trim(u8, line, " \t\r"), '\t');
        const st = it.next();
        var fp = it.next();
        if (st == null or fp == null) continue;

        if (std.mem.startsWith(u8, st.?, "R")) {
            const next_p = it.next();
            if (next_p != null) fp = next_p;
        }

        const fc = FileChange{
            .status = try allocator.dupe(u8, st.?),
            .path = try allocator.dupe(u8, fp.?),
        };
        try changes.append(allocator, fc);
        if (!std.mem.eql(u8, fp.?, ".rice.ini")) {
            try non_ini_changes.append(allocator, fc);
        }
    }

    if (changes.items.len == 0) return try allocator.dupe(u8, "update dotfiles");
    if (non_ini_changes.items.len == 0) {
        if (changes.items.len > 0 and std.mem.startsWith(u8, changes.items[0].status, "A")) {
            return try allocator.dupe(u8, "add .rice.ini");
        }
        return try allocator.dupe(u8, "update .rice.ini");
    }

    var all_deleted = true;
    for (non_ini_changes.items) |c| {
        if (!std.mem.startsWith(u8, c.status, "D")) {
            all_deleted = false;
            break;
        }
    }

    var unique_names: std.ArrayList([]const u8) = .empty;
    defer {
        for (unique_names.items) |u| allocator.free(u);
        unique_names.deinit(allocator);
    }
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    if (cfg) |c_cfg| {
        for (c_cfg.files.items) |f| {
            if (paths.gitPath(allocator, homeDir, f)) |gp| {
                defer allocator.free(gp);
                for (non_ini_changes.items) |c| {
                    if (std.mem.eql(u8, c.path, gp) or (std.mem.startsWith(u8, c.path, gp) and c.path.len > gp.len and c.path[gp.len] == '/')) {
                        var disp = f;
                        if (std.mem.startsWith(u8, disp, "~/")) disp = disp[2..];
                        if (disp.len == 0) disp = gp;
                        if (!seen.contains(disp)) {
                            try seen.put(disp, {});
                            try unique_names.append(allocator, try allocator.dupe(u8, disp));
                        }
                        break;
                    }
                }
            } else |_| {}
        }
    }

    for (non_ini_changes.items) |c| {
        var matched = false;
        var it = seen.keyIterator();
        while (it.next()) |k| {
            if (std.mem.eql(u8, c.path, k.*) or (std.mem.startsWith(u8, c.path, k.*) and c.path.len > k.*.len and c.path[k.*.len] == '/')) {
                matched = true;
                break;
            }
        }
        if (!matched and !seen.contains(c.path)) {
            try seen.put(c.path, {});
            try unique_names.append(allocator, try allocator.dupe(u8, c.path));
        }
    }

    if (unique_names.items.len == 0) return try allocator.dupe(u8, "update dotfiles");

    const verb = if (all_deleted) "remove" else "add";

    switch (unique_names.items.len) {
        1 => return std.fmt.allocPrint(allocator, "{s} {s}", .{ verb, unique_names.items[0] }),
        2 => return std.fmt.allocPrint(allocator, "{s} {s}, {s}", .{ verb, unique_names.items[0], unique_names.items[1] }),
        3 => return std.fmt.allocPrint(allocator, "{s} {s}, {s}, {s}", .{ verb, unique_names.items[0], unique_names.items[1], unique_names.items[2] }),
        else => return std.fmt.allocPrint(allocator, "{s} {s}, {s}, {s} and {d} more files", .{ verb, unique_names.items[0], unique_names.items[1], unique_names.items[2], unique_names.items.len - 3 }),
    }
}

pub fn commitCmd(allocator: Allocator, git: *git_mod.Git, homeDir: []const u8, args: []const []const u8) !void {
    const msg_opt = parseCommitMessage(allocator, args) catch |err| {
        std.debug.print("Error: {s}.\nUsage: rice commit [-m|--message] [message]\n", .{@errorName(err)});
        return err;
    };
    defer if (msg_opt) |m| allocator.free(m);

    var cfg = try repo.loadConfigOrExit(allocator, homeDir);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }

    try stageTrackedFiles(allocator, git, homeDir, cfg);

    const diff = git.output(&[_][]const u8{ "diff", "--cached", "--name-only" }) catch return error.GitDiffFailed;
    defer allocator.free(diff);

    if (diff.len == 0) {
        std.debug.print("Nothing to commit, working tree clean.\n", .{});
        return;
    }

    var commit_msg: []u8 = undefined;
    var allocated_cmsg = false;
    if (msg_opt) |m| {
        commit_msg = m;
    } else {
        commit_msg = try generateAutoCommitMessage(allocator, git, homeDir, cfg);
        allocated_cmsg = true;
    }
    defer if (allocated_cmsg) allocator.free(commit_msg);

    try git.commit(commit_msg);
}

fn promptUser(prompt: []const u8) bool {
    std.debug.print("{s}", .{prompt});
    var buf: [128]u8 = undefined;
    const n = std.Io.File.stdin().readStreaming(paths.getProcessIo(), &.{&buf}) catch return false;
    if (n > 0) {
        const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
        return std.ascii.eqlIgnoreCase(trimmed, "y") or std.ascii.eqlIgnoreCase(trimmed, "yes");
    }
    return false;
}

pub fn pushCmd(allocator: Allocator, git: *git_mod.Git, homeDir: []const u8, args: []const []const u8) !void {
    const msg_opt = parseCommitMessage(allocator, args) catch |err| {
        std.debug.print("Error: {s}.\nUsage: rice push [-m|--message] [message]\n", .{@errorName(err)});
        return err;
    };
    defer if (msg_opt) |m| allocator.free(m);

    if (!git.isBareRepo()) {
        std.debug.print("Error: bare repository {s} not found or invalid.\n", .{git.rice_dir});
        return error.BareRepoInvalid;
    }

    const ini_path = try paths.getRiceIniPath(allocator, homeDir);
    defer allocator.free(ini_path);

    const cfg = config.loadConfig(allocator, ini_path) catch null;
    defer {
        if (cfg) |c| {
            c.deinit();
            allocator.destroy(c);
        }
    }

    if (cfg) |c| {
        _ = stageTrackedFiles(allocator, git, homeDir, c) catch {};
    }

    // 1. Check for uncommitted / staged changes
    const staged_diff = git.output(&[_][]const u8{ "diff", "--cached", "--name-status" }) catch null;
    defer if (staged_diff) |sd| allocator.free(sd);

    // 2. Check for unpushed commits compared to upstream origin remote
    var unpushed_commits: ?[]u8 = null;
    defer if (unpushed_commits) |uc| allocator.free(uc);

    const cur_branch = git.getCurrentBranch() catch null;
    defer if (cur_branch) |cb| allocator.free(cb);

    if (cur_branch) |cb| {
        if (cb.len > 0 and !std.mem.eql(u8, cb, "HEAD")) {
            const upstream_spec = std.fmt.allocPrint(allocator, "origin/{s}..HEAD", .{cb}) catch null;
            if (upstream_spec) |spec| {
                defer allocator.free(spec);
                if (git.output(&[_][]const u8{ "log", "--oneline", spec })) |uc| {
                    if (uc.len > 0) {
                        unpushed_commits = uc;
                    } else {
                        allocator.free(uc);
                    }
                } else |_| {
                    // Upstream might not exist yet; if has commits, show recent commits
                    if (git.hasCommits()) {
                        if (git.output(&[_][]const u8{ "log", "-n", "5", "--oneline" })) |recent| {
                            if (recent.len > 0) unpushed_commits = recent else allocator.free(recent);
                        } else |_| {}
                    }
                }
            }
        }
    }

    const has_staged = staged_diff != null and staged_diff.?.len > 0;
    const has_unpushed = unpushed_commits != null and unpushed_commits.?.len > 0;

    if (!has_staged and !has_unpushed) {
        std.debug.print("Everything up-to-date. Nothing to push.\n", .{});
        return;
    }

    std.debug.print("Changes to be pushed:\n", .{});

    if (has_staged) {
        std.debug.print("  Uncommitted changes:\n", .{});
        var lines = std.mem.splitScalar(u8, staged_diff.?, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            std.debug.print("    {s}\n", .{trimmed});
        }
    }

    if (has_unpushed) {
        std.debug.print("  Unpushed commit(s):\n", .{});
        var lines = std.mem.splitScalar(u8, unpushed_commits.?, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            std.debug.print("    {s}\n", .{trimmed});
        }
    }

    std.debug.print("\n", .{});

    if (!promptUser("Proceed with push? [y/N]: ")) {
        std.debug.print("Push cancelled.\n", .{});
        return;
    }

    // Auto-commit or commit with custom message staged changes if any
    if (has_staged and cfg != null) {
        if (msg_opt) |custom_msg| {
            _ = git.commit(custom_msg) catch {};
        } else if (generateAutoCommitMessage(allocator, git, homeDir, cfg)) |auto_msg| {
            defer allocator.free(auto_msg);
            _ = git.commit(auto_msg) catch {};
        } else |_| {}
    }

    try git.push();

    if (git.hasCommits()) {
        if (git.output(&[_][]const u8{ "log", "-1", "--format=%s" })) |cmsg| {
            defer allocator.free(cmsg);
            if (cmsg.len > 0) {
                std.debug.print("Pushed: {s}\n", .{cmsg});
            }
        } else |_| {}
    }
}
