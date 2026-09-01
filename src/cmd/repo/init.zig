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

fn queryRemoteInfo(allocator: Allocator, repo_url: []const u8) !RemoteInitInfo {
    var detected_branch: ?[]u8 = null;

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
                        detected_branch = try allocator.dupe(u8, rest[0..end_idx]);
                        break;
                    }
                }
            }
        }
    } else |_| {}

    if (detected_branch == null) {
        detected_branch = try allocator.dupe(u8, defaultBranch());
    }

    const tmp_dir = try std.fmt.allocPrint(allocator, "/tmp/rice-init-{d}", .{fs.getMilliTimestamp()});
    defer allocator.free(tmp_dir);
    try fs.makePath(tmp_dir);
    defer fs.deleteTreeAbsolute(tmp_dir) catch {};

    try discovery.execGitInDir(allocator, tmp_dir, &.{ "init" });
    try discovery.execGitInDir(allocator, tmp_dir, &.{ "remote", "add", "origin", repo_url });

    var fetch_branch = detected_branch.?;
    var fetch_ok = false;

    if (discovery.execGitInDirQuiet(allocator, tmp_dir, &.{ "fetch", "--filter=blob:none", "--depth=1", "origin", fetch_branch })) |_| {
        fetch_ok = true;
    } else |_| {
        if (discovery.execGitInDirQuiet(allocator, tmp_dir, &.{ "fetch", "--depth=1", "origin", fetch_branch })) |_| {
            fetch_ok = true;
        } else |_| {}
    }

    if (!fetch_ok) {
        const fallbacks = [_][]const u8{ "main", "master", "HEAD" };
        for (fallbacks) |fb| {
            if (std.mem.eql(u8, fb, fetch_branch)) continue;
            if (discovery.execGitInDirQuiet(allocator, tmp_dir, &.{ "fetch", "--filter=blob:none", "--depth=1", "origin", fb })) |_| {
                fetch_ok = true;
                allocator.free(detected_branch.?);
                detected_branch = try allocator.dupe(u8, fb);
                fetch_branch = detected_branch.?;
                break;
            } else |_| {
                if (discovery.execGitInDirQuiet(allocator, tmp_dir, &.{ "fetch", "--depth=1", "origin", fb })) |_| {
                    fetch_ok = true;
                    allocator.free(detected_branch.?);
                    detected_branch = try allocator.dupe(u8, fb);
                    fetch_branch = detected_branch.?;
                    break;
                } else |_| {}
            }
        }
    }

    var ini_content: ?[]u8 = null;

    if (fetch_ok) {
        if (discovery.runGitInDirQuiet(allocator, tmp_dir, &.{ "cat-file", "-e", "FETCH_HEAD:.rice.ini" }, true)) |out| {
            allocator.free(out);
            if (discovery.runGitInDirQuiet(allocator, tmp_dir, &.{ "show", "FETCH_HEAD:.rice.ini" }, true)) |content| {
                if (content.len > 0) {
                    ini_content = content;
                } else {
                    allocator.free(content);
                }
            } else |_| {}
        } else |_| {}
    }

    return RemoteInitInfo{
        .branch = detected_branch.?,
        .ini_content = ini_content,
    };
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

    try git.initBare();

    if (normalized_remote) |nurl| {
        git.setRemote(nurl) catch |err| {
            std.debug.print("Error: failed to set remote origin: {s}\n", .{@errorName(err)});
            return err;
        };
    }

    const ini_path = try paths.getRiceIniPath(allocator, homeDir);
    defer allocator.free(ini_path);

    var branch_name: ?[]u8 = null;
    defer if (branch_name) |b| allocator.free(b);

    if (normalized_remote) |nurl| {
        var remote_info = queryRemoteInfo(allocator, nurl) catch null;
        defer if (remote_info) |*ri| ri.deinit(allocator);

        if (remote_info) |*ri| {
            branch_name = try allocator.dupe(u8, ri.branch);

            if (ri.ini_content) |remote_ini_bytes| {
                if (fs.createFileAbsolute(ini_path, .{ .permissions = @enumFromInt(0o644) })) |f| {
                    var file = f;
                    file.writePositionalAll(paths.getProcessIo(), remote_ini_bytes, 0) catch {};
                    file.close(paths.getProcessIo());
                } else |_| {}
            }
        }
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
