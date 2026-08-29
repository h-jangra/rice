const std = @import("std");
const Allocator = std.mem.Allocator;
const paths = @import("../paths/mod.zig");

pub fn makeCmdArgs(allocator: Allocator, rice_dir: []const u8, home_dir: []const u8, args: []const []const u8, with_work_tree: bool) !std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;
    try list.append(allocator, "git");

    const git_dir_arg = try std.fmt.allocPrint(allocator, "--git-dir={s}", .{rice_dir});
    try list.append(allocator, git_dir_arg);

    if (with_work_tree) {
        const work_tree_arg = try std.fmt.allocPrint(allocator, "--work-tree={s}", .{home_dir});
        try list.append(allocator, work_tree_arg);
        try list.append(allocator, "-c");
        try list.append(allocator, "status.showUntrackedFiles=no");
    }

    for (args) |arg| {
        try list.append(allocator, arg);
    }
    return list;
}

pub fn freeCmdArgs(allocator: Allocator, list: *std.ArrayList([]const u8), with_work_tree: bool) void {
    if (list.items.len > 1) allocator.free(list.items[1]); // git_dir_arg
    if (with_work_tree and list.items.len > 2) allocator.free(list.items[2]); // work_tree_arg
    list.deinit(allocator);
}

pub fn execRun(allocator: Allocator, rice_dir: []const u8, home_dir: []const u8, args: []const []const u8, with_work_tree: bool) !void {
    var cmd_list = try makeCmdArgs(allocator, rice_dir, home_dir, args, with_work_tree);
    defer freeCmdArgs(allocator, &cmd_list, with_work_tree);

    var env_map = try std.process.Environ.createMap(paths.getProcessEnviron(), allocator);
    defer env_map.deinit();
    try env_map.put("GIT_TERMINAL_PROMPT", "0");
    try env_map.put("GIT_SSH_COMMAND", "ssh -o BatchMode=yes");

    var child = try std.process.spawn(paths.getProcessIo(), .{
        .argv = cmd_list.items,
        .cwd = .{ .path = home_dir },
        .environ_map = &env_map,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(paths.getProcessIo());
    if (term != .exited or term.exited != 0) return error.GitCommandFailed;
}

pub fn execOutputBytes(allocator: Allocator, rice_dir: []const u8, home_dir: []const u8, args: []const []const u8, with_work_tree: bool) ![]u8 {
    var cmd_list = try makeCmdArgs(allocator, rice_dir, home_dir, args, with_work_tree);
    defer freeCmdArgs(allocator, &cmd_list, with_work_tree);

    var env_map = try std.process.Environ.createMap(paths.getProcessEnviron(), allocator);
    defer env_map.deinit();
    try env_map.put("GIT_TERMINAL_PROMPT", "0");
    try env_map.put("GIT_SSH_COMMAND", "ssh -o BatchMode=yes");

    const res = try std.process.run(allocator, paths.getProcessIo(), .{
        .argv = cmd_list.items,
        .cwd = .{ .path = home_dir },
        .environ_map = &env_map,
    });
    defer allocator.free(res.stderr);

    if (res.term != .exited or res.term.exited != 0) {
        allocator.free(res.stdout);
        return error.GitCommandFailed;
    }
    return res.stdout;
}

pub fn execOutput(allocator: Allocator, rice_dir: []const u8, home_dir: []const u8, args: []const []const u8, with_work_tree: bool) ![]u8 {
    const stdout = try execOutputBytes(allocator, rice_dir, home_dir, args, with_work_tree);
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    const res = try allocator.dupe(u8, trimmed);
    allocator.free(stdout);
    return res;
}

pub fn verifyGitInstalled(allocator: Allocator) ![]u8 {
    const argv = [_][]const u8{ "which", "git" };
    const res = std.process.run(allocator, paths.getProcessIo(), .{
        .argv = &argv,
    }) catch return error.GitNotFound;
    defer allocator.free(res.stderr);

    if (res.term == .exited and res.term.exited == 0) {
        defer allocator.free(res.stdout);
        const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
        return allocator.dupe(u8, trimmed);
    }
    allocator.free(res.stdout);
    return error.GitNotFound;
}
