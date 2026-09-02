const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const git_mod = @import("../../core/git/mod.zig");
const paths = @import("../../core/paths/mod.zig");
const config = @import("../../core/config.zig");
const fs = @import("../../core/fs.zig");
const discovery = @import("../../core/install/discovery.zig");

const RemoteInitInfo = struct {
    branch: []u8,
    ini_content: ?[]u8,

    pub fn deinit(self: *RemoteInitInfo, allocator: Allocator) void {
        allocator.free(self.branch);
        if (self.ini_content) |c| allocator.free(c);
    }
};

fn defaultBranch() []const u8 {
    if (builtin.os.tag == .windows) return "windows";
    return "main";
}

fn detectRemoteBranch(allocator: Allocator, repo_url: []const u8) ![]u8 {
    var cmd_list: std.ArrayList([]const u8) = .empty;
    defer cmd_list.deinit(allocator);
    try cmd_list.appendSlice(allocator, &.{ "git", "ls-remote", "--symref", repo_url, "HEAD" });

    var env_map = try std.process.Environ.createMap(paths.getProcessEnviron(), allocator);
    defer env_map.deinit();
    try env_map.put("GIT_TERMINAL_PROMPT", "0");

    if (std.process.run(allocator, paths.getProcessIo(), .{
        .argv = cmd_list.items,
        .environ_map = &env_map,
    })) |res| {
        defer allocator.free(res.stdout);
        defer allocator.free(res.stderr);

        if (res.term == .exited and res.term.exited == 0 and res.stdout.len > 0) {
            var lines = std.mem.splitScalar(u8, res.stdout, '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                const ref_prefix = "ref: refs/heads/";
                if (std.mem.startsWith(u8, trimmed, ref_prefix)) {
                    const rest = trimmed[ref_prefix.len..];
                    var end_idx: usize = 0;
                    while (end_idx < rest.len and rest[end_idx] != ' ' and rest[end_idx] != '\t') : (end_idx += 1) {}
                    if (end_idx > 0) {
                        return try allocator.dupe(u8, rest[0..end_idx]);
                    }
                }
            }
        }
    } else |_| {}

    return try allocator.dupe(u8, defaultBranch());
}



pub fn initCmd(allocator: Allocator, git: *git_mod.Git, homeDir: []const u8, args: []const []const u8) !void {
    var remote_url_arg: ?[]const u8 = null;
    if (args.len > 0) {
        const trimmed = std.mem.trim(u8, args[0], " \t\r\n");
        if (trimmed.len > 0) remote_url_arg = trimmed;
    }

    var normalized_remote: ?[]u8 = null;
    defer if (normalized_remote) |nr| allocator.free(nr);

    if (remote_url_arg) |rurl| {
        normalized_remote = paths.normalizeRepoURL(allocator, rurl) catch |err| {
            std.debug.print("Error: invalid remote URL '{s}': {s}\n", .{ rurl, @errorName(err) });
            return err;
        };
    }

    fs.deleteTreeAbsolute(git.rice_dir) catch {};
    try git.initBare();

    const ini_path = try paths.getRiceIniPath(allocator, homeDir);
    defer allocator.free(ini_path);

    var branch_name: ?[]u8 = null;
    defer if (branch_name) |b| allocator.free(b);

    if (normalized_remote) |nurl| {
        git.setRemote(nurl) catch |err| {
            std.debug.print("Error: failed to set remote origin: {s}\n", .{@errorName(err)});
            return err;
        };

        branch_name = detectRemoteBranch(allocator, nurl) catch try allocator.dupe(u8, defaultBranch());

        _ = git.bareRun(&.{ "fetch", "--depth=1", "origin", branch_name.? }) catch {};

        if (git.output(&.{ "rev-parse", "FETCH_HEAD" })) |fetch_head| {
            defer allocator.free(fetch_head);

            const bname = branch_name.?;
            const sym_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{bname});
            defer allocator.free(sym_ref);

            _ = git.bareRun(&.{ "symbolic-ref", "HEAD", sym_ref }) catch {};
            _ = git.bareRun(&.{ "update-ref", sym_ref, "FETCH_HEAD" }) catch {};
            const upstream_arg = try std.fmt.allocPrint(allocator, "--set-upstream-to=origin/{s}", .{bname});
            defer allocator.free(upstream_arg);
            _ = git.bareRun(&.{ "branch", upstream_arg, bname }) catch {};
            _ = git.bareRun(&.{ "read-tree", "HEAD" }) catch {};

            if (git.getRefFileContent("FETCH_HEAD", ".rice.ini")) |remote_ini_bytes| {
                defer allocator.free(remote_ini_bytes);
                if (fs.createFileAbsolute(ini_path, .{ .permissions = @enumFromInt(0o644) })) |f| {
                    var file = f;
                    file.writePositionalAll(paths.getProcessIo(), remote_ini_bytes, 0) catch {};
                    file.close(paths.getProcessIo());
                } else |_| {}
            } else |_| {}
        } else |_| {}
    }

    var cfg = config.loadConfig(allocator, ini_path) catch blk: {
        const new_c = try allocator.create(config.Config);
        new_c.* = config.Config.init(allocator);
        break :blk new_c;
    };
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }

    if (normalized_remote) |nurl| {
        if (cfg.remote) |r| allocator.free(r);
        cfg.remote = try allocator.dupe(u8, nurl);
    }

    if (branch_name) |b| {
        if (cfg.branch) |cb| allocator.free(cb);
        cfg.branch = try allocator.dupe(u8, b);
    } else if (cfg.branch == null) {
        cfg.branch = try allocator.dupe(u8, defaultBranch());
    }

    try config.saveConfig(allocator, ini_path, cfg);

    const target_branch = if (cfg.branch) |b| b else defaultBranch();
    const sym_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{target_branch});
    defer allocator.free(sym_ref);
    _ = git.bareRun(&.{ "symbolic-ref", "HEAD", sym_ref }) catch {};

    try git.add(&.{".rice.ini"});

    if (!git.hasCommits()) {
        _ = git.commit("Initialize rice dotfiles repository") catch {};
    }

    std.debug.print("Initialized bare repository in {s}\n", .{git.rice_dir});
    if (normalized_remote != null or remote_url_arg != null) {
        const disp_remote = if (remote_url_arg) |r| r else normalized_remote.?;
        std.debug.print("Remote origin configured: {s}\n", .{disp_remote});
        std.debug.print("Connected to remote branch '{s}'\n", .{target_branch});
    }
    std.debug.print("Created configuration in {s}\n", .{ini_path});
}
