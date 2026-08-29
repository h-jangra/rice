const std = @import("std");
const Allocator = std.mem.Allocator;
const paths = @import("paths/mod.zig");

pub fn downloadWithCurl(allocator: Allocator, url: []const u8, destPath: []const u8) !void {
    _ = allocator;
    const argv = [_][]const u8{ "curl", "-#", "-fSL", "--proto", "=https,http", url, "-o", destPath };
    var child = try std.process.spawn(paths.getProcessIo(), .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });

    const term = try child.wait(paths.getProcessIo());
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                return error.CurlDownloadFailed;
            }
        },
        else => return error.CurlProcessFailed,
    }
}

pub fn isHTMLContent(data: []const u8) bool {
    const sample_len = @min(data.len, 512);
    if (sample_len == 0) return false;
    const sample = data[0..sample_len];

    var lower_buf: [512]u8 = undefined;
    for (sample, 0..) |c, i| {
        lower_buf[i] = std.ascii.toLower(c);
    }
    const lower = std.mem.trim(u8, lower_buf[0..sample_len], " \t\r\n");

    return std.mem.startsWith(u8, lower, "<!doctype html") or
        std.mem.startsWith(u8, lower, "<html") or
        std.mem.startsWith(u8, lower, "<?xml") or
        std.mem.indexOf(u8, lower, "<head>") != null or
        std.mem.indexOf(u8, lower, "<body>") != null;
}

pub fn isArchive(name: []const u8) bool {
    var lower_buf: [256]u8 = undefined;
    const lower = if (name.len <= 256) blk: {
        for (name, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
        break :blk lower_buf[0..name.len];
    } else name;

    const exts = [_][]const u8{
        ".tar.gz", ".tgz",     ".zip",     ".tar",
        ".tar.xz", ".txz",     ".tar.bz2", ".tbz2",
        ".tbz",    ".tar.zst",
    };
    for (exts) |ext| {
        if (std.mem.endsWith(u8, lower, ext)) return true;
    }
    return false;
}

pub fn isArchiveData(data: []const u8) bool {
    if (data.len >= 262 and std.mem.eql(u8, data[257..262], "ustar")) return true;
    if (data.len >= 2 and data[0] == 0x1f and data[1] == 0x8b) return true; // gzip
    if (data.len >= 4 and std.mem.eql(u8, data[0..4], &[_]u8{ 0x50, 0x4b, 0x03, 0x04 })) return true; // zip
    if (data.len >= 3 and std.mem.eql(u8, data[0..3], "BZh")) return true; // bz2
    if (data.len >= 6 and std.mem.eql(u8, data[0..6], &[_]u8{ 0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00 })) return true; // xz
    if (data.len >= 4 and std.mem.eql(u8, data[0..4], &[_]u8{ 0x28, 0xb5, 0x2f, 0xfd })) return true; // zstd
    return false;
}

pub fn extractArchive(allocator: Allocator, data: []const u8, name: []const u8, destDir: []const u8) !void {
    const is_zip = std.mem.endsWith(u8, name, ".zip") or
        (data.len >= 4 and std.mem.eql(u8, data[0..4], &[_]u8{ 0x50, 0x4b, 0x03, 0x04 }));

    if (is_zip) {
        return extractZipWithSystem(allocator, data, destDir);
    }
    return extractTarWithSystem(allocator, data, destDir);
}

pub const max_path_bytes = std.Io.Dir.max_path_bytes;

pub fn makePath(p: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(paths.getProcessIo(), p);
}

pub fn openFileAbsolute(p: []const u8, options: std.Io.Dir.OpenFileOptions) !std.Io.File {
    return std.Io.Dir.cwd().openFile(paths.getProcessIo(), p, options);
}

pub fn createFileAbsolute(p: []const u8, flags: std.Io.Dir.CreateFileOptions) !std.Io.File {
    return std.Io.Dir.cwd().createFile(paths.getProcessIo(), p, flags);
}

pub fn openDirAbsolute(p: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    return std.Io.Dir.cwd().openDir(paths.getProcessIo(), p, options);
}

pub fn deleteFileAbsolute(p: []const u8) !void {
    return std.Io.Dir.cwd().deleteFile(paths.getProcessIo(), p);
}

pub fn deleteTreeAbsolute(p: []const u8) !void {
    return std.Io.Dir.cwd().deleteTree(paths.getProcessIo(), p);
}

pub fn renameAbsolute(old_path: []const u8, new_path: []const u8) !void {
    return std.Io.Dir.renameAbsolute(old_path, new_path, paths.getProcessIo());
}

pub fn readFileAlloc(allocator: Allocator, p: []const u8, limit: std.Io.Limit) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(paths.getProcessIo(), p, allocator, limit);
}

pub fn writeFile(p: []const u8, data: []const u8) !void {
    return std.Io.Dir.cwd().writeFile(paths.getProcessIo(), .{ .sub_path = p, .data = data });
}

pub fn getTimestamp() i64 {
    return @as(i64, @intCast(@divFloor(std.Io.Timestamp.now(paths.getProcessIo(), .real).nanoseconds, 1_000_000_000)));
}

pub fn getMilliTimestamp() i64 {
    return @as(i64, @intCast(@divFloor(std.Io.Timestamp.now(paths.getProcessIo(), .real).nanoseconds, 1_000_000)));
}

pub fn extractTarWithSystem(allocator: Allocator, data: []const u8, destDir: []const u8) !void {
    var tmp_dir_buf: [max_path_bytes]u8 = undefined;
    const tmp_file_path = try std.fmt.bufPrint(&tmp_dir_buf, "/tmp/rice-tar-{d}.tmp", .{getMilliTimestamp()});

    const file = try createFileAbsolute(tmp_file_path, .{ .permissions = @enumFromInt(0o600) });
    try file.writePositionalAll(paths.getProcessIo(), data, 0);
    file.close(paths.getProcessIo());
    defer deleteFileAbsolute(tmp_file_path) catch {};

    const argv = [_][]const u8{ "tar", "-xf", tmp_file_path, "-C", destDir };
    const res = try std.process.run(allocator, paths.getProcessIo(), .{
        .argv = &argv,
    });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    switch (res.term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("system tar extraction failed: {s}\n", .{res.stderr});
                return error.TarExtractionFailed;
            }
        },
        else => return error.TarProcessFailed,
    }
}

pub fn extractZipWithSystem(allocator: Allocator, data: []const u8, destDir: []const u8) !void {
    var tmp_dir_buf: [max_path_bytes]u8 = undefined;
    const tmp_file_path = try std.fmt.bufPrint(&tmp_dir_buf, "/tmp/rice-zip-{d}.zip", .{getMilliTimestamp()});

    const file = try createFileAbsolute(tmp_file_path, .{ .permissions = @enumFromInt(0o600) });
    try file.writePositionalAll(paths.getProcessIo(), data, 0);
    file.close(paths.getProcessIo());
    defer deleteFileAbsolute(tmp_file_path) catch {};

    // Try unzip first, fall back to tar
    var argv = [_][]const u8{ "unzip", "-q", "-o", tmp_file_path, "-d", destDir };
    if (std.process.run(allocator, paths.getProcessIo(), .{ .argv = &argv })) |res| {
        defer allocator.free(res.stdout);
        defer allocator.free(res.stderr);
        if (res.term == .exited and res.term.exited == 0) return;
    } else |_| {}

    // Fallback: tar -xf
    const tar_argv = [_][]const u8{ "tar", "-xf", tmp_file_path, "-C", destDir };
    const res = try std.process.run(allocator, paths.getProcessIo(), .{ .argv = &tar_argv });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) {
        return error.ZipExtractionFailed;
    }
}

pub fn copyFile(src: []const u8, dst: []const u8) !void {
    const parent = std.fs.path.dirname(dst);
    if (parent) |p| {
        try makePath(p);
    }

    const in_file = try openFileAbsolute(src, .{});
    defer in_file.close(paths.getProcessIo());

    const stat = try in_file.stat(paths.getProcessIo());
    const mode = stat.permissions;

    const out_file = try createFileAbsolute(dst, .{ .permissions = mode });
    defer out_file.close(paths.getProcessIo());

    var buf: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try in_file.readPositional(paths.getProcessIo(), &.{&buf}, offset);
        if (n == 0) break;
        try out_file.writePositionalAll(paths.getProcessIo(), buf[0..n], offset);
        offset += n;
    }
}

pub fn copyPath(allocator: Allocator, src: []const u8, dst: []const u8) !void {
    const file_stat = openFileAbsolute(src, .{}) catch |err| {
        if (err == error.IsDir) {
            // It's a directory
            try makePath(dst);
            var dir = try openDirAbsolute(src, .{ .iterate = true });
            defer dir.close(paths.getProcessIo());

            var it = dir.iterate();
            while (try it.next(paths.getProcessIo())) |entry| {
                const child_src = try std.fs.path.join(allocator, &[_][]const u8{ src, entry.name });
                defer allocator.free(child_src);
                const child_dst = try std.fs.path.join(allocator, &[_][]const u8{ dst, entry.name });
                defer allocator.free(child_dst);
                try copyPath(allocator, child_src, child_dst);
            }
            return;
        }
        return err;
    };
    file_stat.close(paths.getProcessIo());
    try copyFile(src, dst);
}

pub fn installPath(allocator: Allocator, src: []const u8, dst: []const u8) !void {
    const parent = std.fs.path.dirname(dst) orelse ".";
    try makePath(parent);

    const base_name = std.fs.path.basename(dst);
    const staging_dir_name = try std.fmt.allocPrint(allocator, "{s}/.rice-tmp-{d}", .{ parent, getMilliTimestamp() });
    defer allocator.free(staging_dir_name);

    try makePath(staging_dir_name);
    defer deleteTreeAbsolute(staging_dir_name) catch {};

    const staged_dst = try std.fs.path.join(allocator, &[_][]const u8{ staging_dir_name, base_name });
    defer allocator.free(staged_dst);

    try copyPath(allocator, src, staged_dst);

    deleteTreeAbsolute(dst) catch {};
    deleteFileAbsolute(dst) catch {};

    renameAbsolute(staged_dst, dst) catch {
        try copyPath(allocator, staged_dst, dst);
    };
}

pub fn backupFile(allocator: Allocator, targetPath: []const u8) ![]u8 {
    _ = openFileAbsolute(targetPath, .{}) catch |err| {
        if (err != error.IsDir) return err;
    };

    const ts = getTimestamp();
    const epoch_seconds = @as(u64, @intCast(ts));
    const epoch_day = epoch_seconds / 86400;
    const day_seconds = epoch_seconds % 86400;

    // Approximate UTC timestamp formatting: YYYYMMDD-HHMMSS
    const year_day = std.time.epoch.EpochDay{ .day = @as(u47, @intCast(epoch_day)) };
    const year_and_day = year_day.calculateYearDay();
    const month_and_day = year_and_day.calculateMonthDay();

    const hours = day_seconds / 3600;
    const minutes = (day_seconds % 3600) / 60;
    const seconds = day_seconds % 60;

    const base_backup = try std.fmt.allocPrint(allocator, "{s}.bak.{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        targetPath,
        year_and_day.year,
        month_and_day.month.numeric(),
        month_and_day.day_index + 1,
        hours,
        minutes,
        seconds,
    });
    errdefer allocator.free(base_backup);

    var final_backup = base_backup;

    var exists = true;
    if (openFileAbsolute(final_backup, .{})) |f| {
        f.close(paths.getProcessIo());
    } else |_| {
        exists = false;
    }

    if (exists) {
        var found = false;
        var i: usize = 1;
        while (i <= 100) : (i += 1) {
            const cand = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ base_backup, i });
            var cand_exists = true;
            if (openFileAbsolute(cand, .{})) |f| {
                f.close(paths.getProcessIo());
            } else |_| {
                cand_exists = false;
            }
            if (!cand_exists) {
                allocator.free(final_backup);
                final_backup = cand;
                found = true;
                break;
            }
            allocator.free(cand);
        }
        if (!found) {
            return error.BackupCollisionLimitReached;
        }
    }

    try copyPath(allocator, targetPath, final_backup);
    return final_backup;
}
