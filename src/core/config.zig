const std = @import("std");
const Allocator = std.mem.Allocator;
const paths = @import("paths/mod.zig");

pub const Config = struct {
    allocator: Allocator,
    remote: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    files: std.ArrayList([]const u8),
    binaries: std.StringHashMap([]const u8),

    pub fn init(allocator: Allocator) Config {
        return .{
            .allocator = allocator,
            .remote = null,
            .branch = null,
            .files = .empty,
            .binaries = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Config) void {
        if (self.remote) |r| self.allocator.free(r);
        if (self.branch) |b| self.allocator.free(b);
        for (self.files.items) |f| self.allocator.free(f);
        self.files.deinit(self.allocator);

        var it = self.binaries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.binaries.deinit();
    }

    pub fn addFile(self: *Config, path: []const u8) !bool {
        const norm = normalizeConfigFileEntry(self.allocator, path) catch return false;
        if (norm.len == 0) {
            self.allocator.free(norm);
            return false;
        }

        for (self.files.items) |f| {
            if (std.mem.eql(u8, f, norm)) {
                self.allocator.free(norm);
                return false;
            }
        }

        try self.files.append(self.allocator, norm);
        return true;
    }

    pub fn removeFile(self: *Config, path: []const u8) bool {
        const norm = normalizeConfigFileEntry(self.allocator, path) catch return false;
        defer self.allocator.free(norm);
        if (norm.len == 0) return false;

        for (self.files.items, 0..) |f, i| {
            if (std.mem.eql(u8, f, norm)) {
                self.allocator.free(f);
                _ = self.files.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn hasFile(self: *const Config, path: []const u8) bool {
        const norm = normalizeConfigFileEntry(self.allocator, path) catch return false;
        defer self.allocator.free(norm);
        if (norm.len == 0) return false;

        for (self.files.items) |f| {
            if (std.mem.eql(u8, f, norm)) return true;
        }
        return false;
    }

    pub fn addBinary(self: *Config, name: []const u8, source: []const u8) !bool {
        const t_name = std.mem.trim(u8, name, " \t\r\n");
        const t_source = std.mem.trim(u8, source, " \t\r\n");
        if (t_name.len == 0 or t_source.len == 0) return false;

        if (self.binaries.fetchRemove(t_name)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }

        const k = try self.allocator.dupe(u8, t_name);
        errdefer self.allocator.free(k);
        const v = try self.allocator.dupe(u8, t_source);
        errdefer self.allocator.free(v);

        try self.binaries.put(k, v);
        return true;
    }

    pub fn removeBinary(self: *Config, name: []const u8) bool {
        const t_name = std.mem.trim(u8, name, " \t\r\n");
        if (t_name.len == 0) return false;

        if (self.binaries.fetchRemove(t_name)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
            return true;
        }
        return false;
    }
};

pub fn normalizeConfigFileEntry(allocator: Allocator, path: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, path, " \t\r\n");
    if (trimmed.len == 0) return try allocator.dupe(u8, "");

    var norm_path = trimmed;
    if (std.mem.startsWith(u8, norm_path, "~/") or std.mem.startsWith(u8, norm_path, "~\\")) {
        norm_path = norm_path[2..];
    } else if (std.mem.startsWith(u8, norm_path, "~")) {
        return try allocator.dupe(u8, "");
    }

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    var it = std.mem.splitAny(u8, norm_path, "/\\");
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len > 0) {
                _ = parts.pop();
            } else {
                return try allocator.dupe(u8, "");
            }
        } else {
            try parts.append(allocator, part);
        }
    }

    if (parts.items.len == 0) return try allocator.dupe(u8, "");

    var total_len: usize = 2; // "~/"
    for (parts.items, 0..) |p, i| {
        total_len += p.len;
        if (i + 1 < parts.items.len) total_len += 1;
    }

    var result = try allocator.alloc(u8, total_len);
    @memcpy(result[0..2], "~/");
    var pos: usize = 2;

    for (parts.items, 0..) |p, i| {
        @memcpy(result[pos .. pos + p.len], p);
        pos += p.len;
        if (i + 1 < parts.items.len) {
            result[pos] = '/';
            pos += 1;
        }
    }

    return result;
}

pub fn loadConfig(allocator: Allocator, path: []const u8) !*Config {
    const file = try std.Io.Dir.cwd().openFile(paths.getProcessIo(), path, .{});
    defer file.close(paths.getProcessIo());

    const content = try std.Io.Dir.cwd().readFileAlloc(paths.getProcessIo(), path, allocator, .limited(10 * 1024 * 1024));
    defer allocator.free(content);

    const cfg = try allocator.create(Config);
    cfg.* = Config.init(allocator);
    errdefer {
        cfg.deinit();
        allocator.destroy(cfg);
    }

    var current_section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;

        if (line[0] == '[' and line[line.len - 1] == ']') {
            const sec = std.mem.trim(u8, line[1 .. line.len - 1], " \t\r");
            if (std.ascii.eqlIgnoreCase(sec, "files")) {
                current_section = "files";
            } else if (std.ascii.eqlIgnoreCase(sec, "binaries")) {
                current_section = "binaries";
            } else {
                current_section = "";
            }
            continue;
        }

        if (std.mem.eql(u8, current_section, "")) {
            if (std.mem.indexOfScalar(u8, line, '=')) |eq_pos| {
                const key = std.mem.trim(u8, line[0..eq_pos], " \t\r");
                const val = std.mem.trim(u8, line[eq_pos + 1 ..], " \t\r");
                if (std.ascii.eqlIgnoreCase(key, "repo")) {
                    if (cfg.remote) |r| allocator.free(r);
                    cfg.remote = try allocator.dupe(u8, val);
                } else if (std.ascii.eqlIgnoreCase(key, "branch")) {
                    if (cfg.branch) |b| allocator.free(b);
                    cfg.branch = try allocator.dupe(u8, val);
                }
            }
        } else if (std.mem.eql(u8, current_section, "files")) {
            _ = try cfg.addFile(line);
        } else if (std.mem.eql(u8, current_section, "binaries")) {
            if (std.mem.indexOfScalar(u8, line, '=')) |eq_pos| {
                const key = std.mem.trim(u8, line[0..eq_pos], " \t\r");
                const val = std.mem.trim(u8, line[eq_pos + 1 ..], " \t\r");
                if (key.len > 0 and val.len > 0) {
                    _ = try cfg.addBinary(key, val);
                }
            }
        }
    }

    return cfg;
}

pub fn saveConfig(allocator: Allocator, path: []const u8, cfg: *const Config) !void {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    var has_header = false;
    if (cfg.remote) |r| {
        const line = try std.fmt.allocPrint(allocator, "repo = {s}\n", .{r});
        defer allocator.free(line);
        try buffer.appendSlice(allocator, line);
        has_header = true;
    }
    if (cfg.branch) |b| {
        const line = try std.fmt.allocPrint(allocator, "branch = {s}\n", .{b});
        defer allocator.free(line);
        try buffer.appendSlice(allocator, line);
        has_header = true;
    }
    if (has_header) {
        try buffer.appendSlice(allocator, "\n");
    }

    try buffer.appendSlice(allocator, "[files]\n");
    for (cfg.files.items) |f| {
        const line = try std.fmt.allocPrint(allocator, "{s}\n", .{f});
        defer allocator.free(line);
        try buffer.appendSlice(allocator, line);
    }

    if (cfg.binaries.count() > 0) {
        if (cfg.files.items.len > 0) try buffer.appendSlice(allocator, "\n");
        try buffer.appendSlice(allocator, "[binaries]\n");

        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(allocator);

        var it = cfg.binaries.iterator();
        while (it.next()) |entry| {
            try keys.append(allocator, entry.key_ptr.*);
        }

        std.mem.sort([]const u8, keys.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        for (keys.items) |k| {
            const v = cfg.binaries.get(k).?;
            const line = try std.fmt.allocPrint(allocator, "{s} = {s}\n", .{ k, v });
            defer allocator.free(line);
            try buffer.appendSlice(allocator, line);
        }
    }

    const file = try std.Io.Dir.cwd().createFile(paths.getProcessIo(), path, .{ .permissions = @enumFromInt(0o644) });
    defer file.close(paths.getProcessIo());
    try file.writePositionalAll(paths.getProcessIo(), buffer.items, 0);
}
