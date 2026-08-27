const std = @import("std");
const Allocator = std.mem.Allocator;
const exec = @import("exec.zig");

pub fn getCurrentBranch(allocator: Allocator, rice_dir: []const u8, home_dir: []const u8) ![]u8 {
    if (exec.execOutput(allocator, rice_dir, home_dir, &[_][]const u8{ "symbolic-ref", "--short", "HEAD" }, true)) |out| {
        if (out.len > 0) return out;
        allocator.free(out);
    } else |_| {}

    return exec.execOutput(allocator, rice_dir, home_dir, &[_][]const u8{ "rev-parse", "--abbrev-ref", "HEAD" }, true);
}

pub fn switchBranch(allocator: Allocator, rice_dir: []const u8, home_dir: []const u8, branch_raw: []const u8, create: bool, force: bool, _: bool, has_commits: bool) !void {
    var branch = branch_raw;
    if (std.mem.startsWith(u8, branch, "refs/heads/")) {
        branch = branch["refs/heads/".len..];
    }
    if (std.mem.startsWith(u8, branch, "remotes/")) {
        branch = branch["remotes/".len..];
    }
    if (std.mem.startsWith(u8, branch, "origin/")) {
        branch = branch["origin/".len..];
    }

    if (create) {
        const ref_branch = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch});
        defer allocator.free(ref_branch);

        var exists = false;
        if (exec.execOutput(allocator, rice_dir, home_dir, &[_][]const u8{ "rev-parse", "--verify", ref_branch }, false)) |out| {
            allocator.free(out);
            exists = true;
        } else |_| {}

        if (exists) {
            if (!force) {
                std.debug.print("fatal: a branch named '{s}' already exists\n", .{branch});
                return error.BranchAlreadyExists;
            }
            if (has_commits) {
                try exec.execRun(allocator, rice_dir, home_dir, &[_][]const u8{ "branch", "-f", branch, "HEAD" }, false);
            }
        } else if (has_commits) {
            try exec.execRun(allocator, rice_dir, home_dir, &[_][]const u8{ "branch", branch, "HEAD" }, false);
        }
    } else {
        const ref_branch = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch});
        defer allocator.free(ref_branch);

        var exists = false;
        if (exec.execOutput(allocator, rice_dir, home_dir, &[_][]const u8{ "rev-parse", "--verify", ref_branch }, false)) |out| {
            allocator.free(out);
            exists = true;
        } else |_| {}

        if (!exists) {
            const remote_ref = try std.fmt.allocPrint(allocator, "refs/remotes/origin/{s}", .{branch});
            defer allocator.free(remote_ref);

            var remote_exists = false;
            if (exec.execOutput(allocator, rice_dir, home_dir, &[_][]const u8{ "rev-parse", "--verify", remote_ref }, false)) |out| {
                allocator.free(out);
                remote_exists = true;
            } else |_| {}

            if (remote_exists) {
                const origin_branch = try std.fmt.allocPrint(allocator, "origin/{s}", .{branch});
                defer allocator.free(origin_branch);

                if (exec.execRun(allocator, rice_dir, home_dir, &[_][]const u8{ "branch", "--track", branch, origin_branch }, false)) {} else |_| {
                    try exec.execRun(allocator, rice_dir, home_dir, &[_][]const u8{ "branch", branch, origin_branch }, false);
                }
            } else {
                std.debug.print("error: pathspec '{s}' did not match any file(s) known to git\n", .{branch});
                return error.BranchNotFound;
            }
        }
    }

    const symref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch});
    defer allocator.free(symref);

    try exec.execRun(allocator, rice_dir, home_dir, &[_][]const u8{ "symbolic-ref", "HEAD", symref }, false);

    if (has_commits) {
        _ = exec.execRun(allocator, rice_dir, home_dir, &[_][]const u8{ "read-tree", "HEAD" }, false) catch {};
    }
}

pub fn branchList(allocator: Allocator, rice_dir: []const u8, home_dir: []const u8, args: []const []const u8) ![]u8 {
    var cmd_list = std.ArrayList([]const u8).init(allocator);
    defer cmd_list.deinit();
    try cmd_list.append("branch");
    for (args) |a| try cmd_list.append(a);
    return exec.execOutput(allocator, rice_dir, home_dir, cmd_list.items, true);
}
