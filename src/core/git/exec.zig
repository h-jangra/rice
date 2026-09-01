const std = @import("std");
const Allocator = std.mem.Allocator;
const paths = @import("../paths/mod.zig");

pub fn makeCmdArgs(allocator: Allocator, rice_dir: []const u8, home_dir: []const u8, args: []const []const u8, with_work_tree: bool) !std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;
    try list.append(allocator, "git");
    try list.append(allocator, try std.fmt.allocPrint(allocator, "--git-dir={s}", .{rice_dir}));

    if (with_work_tree) {
        try list.append(allocator, try std.fmt.allocPrint(allocator, "--work-tree={s}", .{home_dir}));
        try list.appendSlice(allocator, &.{ "-c", "status.showUntrackedFiles=no" });
    }

    try list.appendSlice(allocator, args);
    return list;
}

pub fn freeCmdArgs(allocator: Allocator, list: *std.ArrayList([]const u8), with_work_tree: bool) void {
    if (list.items.len > 1) allocator.free(list.items[1]);
    if (with_work_tree and list.items.len > 2) allocator.free(list.items[2]);
    list.deinit(allocator);
}

fn createGitEnv(allocator: Allocator) !std.process.Environ.Map {
    var env_map = try std.process.Environ.createMap(paths.getProcessEnviron(), allocator);
    errdefer env_map.deinit();
    try env_map.put("GIT_TERMINAL_PROMPT", "0");
    try env_map.put("GIT_SSH_COMMAND", "ssh -o BatchMode=yes");
    if (env_map.get("GIT_AUTHOR_NAME") == null) try env_map.put("GIT_AUTHOR_NAME", "rice");
    if (env_map.get("GIT_AUTHOR_EMAIL") == null) try env_map.put("GIT_AUTHOR_EMAIL", "rice@localhost");
    if (env_map.get("GIT_COMMITTER_NAME") == null) try env_map.put("GIT_COMMITTER_NAME", "rice");
    if (env_map.get("GIT_COMMITTER_EMAIL") == null) try env_map.put("GIT_COMMITTER_EMAIL", "rice@localhost");
    return env_map;
}

pub fn execRun(allocator: Allocator, rice_dir: []const u8, home_dir: []const u8, args: []const []const u8, with_work_tree: bool) !void {
    var cmd_list = try makeCmdArgs(allocator, rice_dir, home_dir, args, with_work_tree);
    defer freeCmdArgs(allocator, &cmd_list, with_work_tree);

    var env_map = try createGitEnv(allocator);
    defer env_map.deinit();

    const res = try std.process.run(allocator, paths.getProcessIo(), .{
        .argv = cmd_list.items,
        .cwd = .{ .path = home_dir },
        .environ_map = &env_map,
    });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    if (res.term != .exited or res.term.exited != 0) return error.GitCommandFailed;
}


pub fn execOutputBytes(allocator: Allocator, rice_dir: []const u8, home_dir: []const u8, args: []const []const u8, with_work_tree: bool) ![]u8 {
    var cmd_list = try makeCmdArgs(allocator, rice_dir, home_dir, args, with_work_tree);
    defer freeCmdArgs(allocator, &cmd_list, with_work_tree);

    var env_map = try createGitEnv(allocator);
    defer env_map.deinit();

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
    defer allocator.free(stdout);
    return allocator.dupe(u8, std.mem.trim(u8, stdout, " \t\r\n"));
}

pub fn verifyGitInstalled(allocator: Allocator) ![]u8 {
    const res = std.process.run(allocator, paths.getProcessIo(), .{
        .argv = &.{ "which", "git" },
    }) catch return error.GitNotFound;
    defer {
        allocator.free(res.stdout);
        allocator.free(res.stderr);
    }

    if (res.term == .exited and res.term.exited == 0) {
        return allocator.dupe(u8, std.mem.trim(u8, res.stdout, " \t\r\n"));
    }
    return error.GitNotFound;
}

