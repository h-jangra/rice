const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn toSlashOwned(allocator: Allocator, p: []const u8) ![]u8 {
    const res = try allocator.alloc(u8, p.len);
    for (p, 0..) |c, i| {
        res[i] = if (c == '\\') '/' else c;
    }
    return res;
}

pub fn cleanPath(allocator: Allocator, p: []const u8) ![]u8 {
    const is_abs = std.fs.path.isAbsolute(p);
    var parts = std.ArrayList([]const u8).init(allocator);
    defer parts.deinit();

    var it = std.mem.splitAny(u8, p, "/\\");
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len > 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
                _ = parts.pop();
            } else if (!is_abs) {
                try parts.append("..");
            }
        } else {
            try parts.append(part);
        }
    }

    if (parts.items.len == 0) {
        if (is_abs) return try allocator.dupe(u8, "/");
        return try allocator.dupe(u8, ".");
    }

    var total_len: usize = if (is_abs) 1 else 0;
    for (parts.items, 0..) |part, i| {
        total_len += part.len;
        if (i + 1 < parts.items.len) total_len += 1;
    }

    var res = try allocator.alloc(u8, total_len);
    var pos: usize = 0;
    if (is_abs) {
        res[0] = '/';
        pos = 1;
    }

    for (parts.items, 0..) |part, i| {
        @memcpy(res[pos .. pos + part.len], part);
        pos += part.len;
        if (i + 1 < parts.items.len) {
            res[pos] = '/';
            pos += 1;
        }
    }

    return res;
}
