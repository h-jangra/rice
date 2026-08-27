const std = @import("std");
const Allocator = std.mem.Allocator;
const exec = @import("exec.zig");

pub fn listRefFiles(allocator: Allocator, rice_dir: []const u8, home_dir: []const u8, ref: []const u8, paths_filter: []const []const u8) !std.ArrayList([]u8) {
    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();
    try args.append("ls-tree");
    try args.append("-r");
    try args.append("--name-only");
    try args.append(ref);
    if (paths_filter.len > 0) {
        try args.append("--");
        for (paths_filter) |p| try args.append(p);
    }

    const out = try exec.execOutput(allocator, rice_dir, home_dir, args.items, true);
    defer allocator.free(out);

    var result = std.ArrayList([]u8).init(allocator);
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) {
            try result.append(try allocator.dupe(u8, trimmed));
        }
    }
    return result;
}

pub fn listIndexFiles(allocator: Allocator, rice_dir: []const u8, home_dir: []const u8) !std.ArrayList([]u8) {
    const out = try exec.execOutput(allocator, rice_dir, home_dir, &[_][]const u8{"ls-files"}, true);
    defer allocator.free(out);

    var result = std.ArrayList([]u8).init(allocator);
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) {
            try result.append(try allocator.dupe(u8, trimmed));
        }
    }
    return result;
}

pub fn getAllGitTrackedFiles(allocator: Allocator, rice_dir: []const u8, home_dir: []const u8, has_commits: bool) !std.ArrayList([]u8) {
    var idx = try listIndexFiles(allocator, rice_dir, home_dir);
    defer {
        for (idx.items) |f| allocator.free(f);
        idx.deinit();
    }

    var head: std.ArrayList([]u8) = undefined;
    if (has_commits) {
        head = try listRefFiles(allocator, rice_dir, home_dir, "HEAD", &[_][]const u8{});
    } else {
        head = std.ArrayList([]u8).init(allocator);
    }
    defer {
        for (head.items) |f| allocator.free(f);
        head.deinit();
    }

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var result = std.ArrayList([]u8).init(allocator);
    for (idx.items) |f| {
        if (!seen.contains(f)) {
            try seen.put(f, {});
            try result.append(try allocator.dupe(u8, f));
        }
    }
    for (head.items) |f| {
        if (!seen.contains(f)) {
            try seen.put(f, {});
            try result.append(try allocator.dupe(u8, f));
        }
    }
    return result;
}
