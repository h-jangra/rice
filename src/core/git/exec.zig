const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn makeCmdArgs(allocator: Allocator, rice_dir: []const u8, home_dir: []const u8, args: []const []const u8, with_work_tree: bool) !std.ArrayList([]const u8) {
    var list = std.ArrayList([]const u8).init(allocator);
    try list.append("git");

    const git_dir_arg = try std.fmt.allocPrint(allocator, "--git-dir={s}", .{rice_dir});
    try list.append(git_dir_arg);

    if (with_work_tree) {
        const work_tree_arg = try std.fmt.allocPrint(allocator, "--work-tree={s}", .{home_dir});
        try list.append(work_tree_arg);
        try list.append("-c");
        try list.append("status.showUntrackedFiles=no");
    }

    for (args) |arg| {
        try list.append(arg);
    }
    return list;
}

pub fn freeCmdArgs(allocator: Allocator, list: *std.ArrayList([]const u8), with_work_tree: bool) void {
    if (list.items.len > 1) allocator.free(list.items[1]); // git_dir_arg
    if (with_work_tree and list.items.len > 2) allocator.free(list.items[2]); // work_tree_arg
    list.deinit();
}

fn spawnGitChild(allocator: Allocator, rice_dir: []const u8, home_dir: []const u8, args: []const []const u8, with_work_tree: bool, pipe_out: bool) !struct { child: std.process.Child, cmd_list: std.ArrayList([]const u8), env_map: std.process.EnvMap } {
    const cmd_list = try makeCmdArgs(allocator, rice_dir, home_dir, args, with_work_tree);
    var env_map = try std.process.getEnvMap(allocator);
    try env_map.put("GIT_TERMINAL_PROMPT", "0");
    try env_map.put("GIT_SSH_COMMAND", "ssh -o BatchMode=yes");

    var child = std.process.Child.init(cmd_list.items, allocator);
    child.cwd = home_dir;
    child.stdin_behavior = if (pipe_out) .Ignore else .Inherit;
    child.stdout_behavior = if (pipe_out) .Pipe else .Inherit;
    child.stderr_behavior = if (pipe_out) .Pipe else .Inherit;
    child.env_map = &env_map;

    try child.spawn();
    return .{ .child = child, .cmd_list = cmd_list, .env_map = env_map };
}

pub fn execRun(allocator: Allocator, rice_dir: []const u8, home_dir: []const u8, args: []const []const u8, with_work_tree: bool) !void {
    var sc = try spawnGitChild(allocator, rice_dir, home_dir, args, with_work_tree, false);
    defer {
        sc.env_map.deinit();
        freeCmdArgs(allocator, &sc.cmd_list, with_work_tree);
    }
    const term = try sc.child.wait();
    if (term != .Exited or term.Exited != 0) return error.GitCommandFailed;
}

pub fn execOutputBytes(allocator: Allocator, rice_dir: []const u8, home_dir: []const u8, args: []const []const u8, with_work_tree: bool) ![]u8 {
    var sc = try spawnGitChild(allocator, rice_dir, home_dir, args, with_work_tree, true);
    defer {
        sc.env_map.deinit();
        freeCmdArgs(allocator, &sc.cmd_list, with_work_tree);
    }

    const stdout = try sc.child.stdout.?.readToEndAlloc(allocator, 10 * 1024 * 1024);
    errdefer allocator.free(stdout);
    const stderr = try sc.child.stderr.?.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(stderr);

    const term = try sc.child.wait();
    if (term != .Exited or term.Exited != 0) return error.GitCommandFailed;
    return stdout;
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
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024);
    defer allocator.free(stdout);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024);
    defer allocator.free(stderr);

    const term = try child.wait();
    if (term == .Exited and term.Exited == 0) {
        const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
        return allocator.dupe(u8, trimmed);
    }
    return error.GitNotFound;
}
