const std = @import("std");
const Allocator = std.mem.Allocator;
const exec = @import("exec.zig");

pub fn listRefFiles(allocator: Allocator, rice_dir: []const u8, home_dir: []const u8, ref: []const u8, paths_filter: []const []const u8) !std.ArrayList([]u8) {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.append(allocator, "ls-tree");
    try args.append(allocator, "-r");
    try args.append(allocator, "--name-only");
    try args.append(allocator, ref);
    if (paths_filter.len > 0) {
        try args.append(allocator, "--");
        for (paths_filter) |p| try args.append(allocator, p);
    }

    const out = try exec.execOutput(allocator, rice_dir, home_dir, args.items, true);
    defer allocator.free(out);

    var result: std.ArrayList([]u8) = .empty;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) {
            try result.append(allocator, try allocator.dupe(u8, trimmed));
        }
    }
    return result;
}

pub fn listIndexFiles(allocator: Allocator, rice_dir: []const u8, home_dir: []const u8) !std.ArrayList([]u8) {
    const out = try exec.execOutput(allocator, rice_dir, home_dir, &[_][]const u8{"ls-files"}, true);
    defer allocator.free(out);

    var result: std.ArrayList([]u8) = .empty;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) {
            try result.append(allocator, try allocator.dupe(u8, trimmed));
        }
    }
    return result;
}

pub fn getAllGitTrackedFiles(allocator: Allocator, rice_dir: []const u8, home_dir: []const u8, has_commits: bool) !std.ArrayList([]u8) {
    var idx = try listIndexFiles(allocator, rice_dir, home_dir);
    defer {
        for (idx.items) |f| allocator.free(f);
        idx.deinit(allocator);
    }

    var head: std.ArrayList([]u8) = .empty;
    if (has_commits) {
        head = try listRefFiles(allocator, rice_dir, home_dir, "HEAD", &[_][]const u8{});
    }
    defer {
        for (head.items) |f| allocator.free(f);
        head.deinit(allocator);
    }

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var result: std.ArrayList([]u8) = .empty;
    for (idx.items) |f| {
        if (!seen.contains(f)) {
            try seen.put(f, {});
            try result.append(allocator, try allocator.dupe(u8, f));
        }
    }
    for (head.items) |f| {
        if (!seen.contains(f)) {
            try seen.put(f, {});
            try result.append(allocator, try allocator.dupe(u8, f));
        }
    }
    return result;
}
