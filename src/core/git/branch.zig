const std = @import("std");
const Allocator = std.mem.Allocator;
const exec = @import("exec.zig");

pub fn getCurrentBranch(allocator: Allocator, rice_dir: []const u8, home_dir: []const u8) ![]u8 {
    if (exec.execOutput(allocator, rice_dir, home_dir, &.{ "symbolic-ref", "--short", "HEAD" }, true)) |out| {
        if (out.len > 0) return out;
        allocator.free(out);
    } else |_| {}

    return exec.execOutput(allocator, rice_dir, home_dir, &.{ "rev-parse", "--abbrev-ref", "HEAD" }, true);
}

fn refExists(allocator: Allocator, rice_dir: []const u8, home_dir: []const u8, ref: []const u8) bool {
    if (exec.execOutput(allocator, rice_dir, home_dir, &.{ "rev-parse", "--verify", ref }, false)) |out| {
        allocator.free(out);
        return true;
    } else |_| {
        return false;
    }
}

pub fn switchBranch(allocator: Allocator, rice_dir: []const u8, home_dir: []const u8, branch_raw: []const u8, create: bool, force: bool, _: bool, has_commits: bool) !void {
    var branch = branch_raw;
    for ([_][]const u8{ "refs/heads/", "remotes/", "origin/" }) |prefix| {
        if (std.mem.startsWith(u8, branch, prefix)) branch = branch[prefix.len..];
    }

    const ref_branch = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch});
    defer allocator.free(ref_branch);

    const exists = refExists(allocator, rice_dir, home_dir, ref_branch);

    if (create) {
        if (exists) {
            if (!force) {
                std.debug.print("fatal: a branch named '{s}' already exists\n", .{branch});
                return error.BranchAlreadyExists;
            }
            if (has_commits) {
                try exec.execRun(allocator, rice_dir, home_dir, &.{ "branch", "-f", branch, "HEAD" }, false);
            }
        } else if (has_commits) {
            try exec.execRun(allocator, rice_dir, home_dir, &.{ "branch", branch, "HEAD" }, false);
        }
    } else if (!exists) {
        const remote_ref = try std.fmt.allocPrint(allocator, "refs/remotes/origin/{s}", .{branch});
        defer allocator.free(remote_ref);

        if (refExists(allocator, rice_dir, home_dir, remote_ref)) {
            const origin_branch = try std.fmt.allocPrint(allocator, "origin/{s}", .{branch});
            defer allocator.free(origin_branch);

            if (exec.execRun(allocator, rice_dir, home_dir, &.{ "branch", "--track", branch, origin_branch }, false)) {} else |_| {
                try exec.execRun(allocator, rice_dir, home_dir, &.{ "branch", branch, origin_branch }, false);
            }
        } else {
            std.debug.print("error: pathspec '{s}' did not match any file(s) known to git\n", .{branch});
            return error.BranchNotFound;
        }
    }

    try exec.execRun(allocator, rice_dir, home_dir, &.{ "symbolic-ref", "HEAD", ref_branch }, false);

    if (has_commits) {
        _ = exec.execRun(allocator, rice_dir, home_dir, &.{ "read-tree", "HEAD" }, false) catch {};
    }
}

pub fn branchList(allocator: Allocator, rice_dir: []const u8, home_dir: []const u8, args: []const []const u8) ![]u8 {
    var cmd_list: std.ArrayList([]const u8) = .empty;
    defer cmd_list.deinit(allocator);
    try cmd_list.append(allocator, "branch");
    try cmd_list.appendSlice(allocator, args);
    return exec.execOutput(allocator, rice_dir, home_dir, cmd_list.items, true);
}

