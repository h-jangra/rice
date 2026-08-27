const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn downloadWithCurl(allocator: Allocator, url: []const u8, destPath: []const u8) !void {
    const argv = [_][]const u8{ "curl", "-#", "-fSL", "--proto", "=https,http", url, "-o", destPath };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;

    try child.spawn();

    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
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

pub fn extractTarWithSystem(allocator: Allocator, data: []const u8, destDir: []const u8) !void {
    var tmp_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_file_path = try std.fmt.bufPrint(&tmp_dir_buf, "/tmp/rice-tar-{d}.tmp", .{std.time.milliTimestamp()});

    const file = try std.fs.createFileAbsolute(tmp_file_path, .{ .mode = 0o600 });
    try file.writeAll(data);
    file.close();
    defer std.fs.deleteFileAbsolute(tmp_file_path) catch {};

    const argv = [_][]const u8{ "tar", "-xf", tmp_file_path, "-C", destDir };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(out);
    const err_out = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(err_out);

    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("system tar extraction failed: {s}\n", .{err_out});
                return error.TarExtractionFailed;
            }
        },
        else => return error.TarProcessFailed,
    }
}

pub fn extractZipWithSystem(allocator: Allocator, data: []const u8, destDir: []const u8) !void {
    var tmp_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_file_path = try std.fmt.bufPrint(&tmp_dir_buf, "/tmp/rice-zip-{d}.zip", .{std.time.milliTimestamp()});

    const file = try std.fs.createFileAbsolute(tmp_file_path, .{ .mode = 0o600 });
    try file.writeAll(data);
    file.close();
    defer std.fs.deleteFileAbsolute(tmp_file_path) catch {};

    // Try unzip first, fall back to tar
    var argv = [_][]const u8{ "unzip", "-q", "-o", tmp_file_path, "-d", destDir };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    if (child.spawn()) |_| {
        const out = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(out);
        const err_out = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(err_out);
        const term = try child.wait();
        if (term == .Exited and term.Exited == 0) return;
    } else |_| {}

    // Fallback: tar -xf
    const tar_argv = [_][]const u8{ "tar", "-xf", tmp_file_path, "-C", destDir };
    var tar_child = std.process.Child.init(&tar_argv, allocator);
    tar_child.stdin_behavior = .Ignore;
    tar_child.stdout_behavior = .Pipe;
    tar_child.stderr_behavior = .Pipe;
    try tar_child.spawn();
    const tout = try tar_child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(tout);
    const terr = try tar_child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(terr);
    const term2 = try tar_child.wait();
    if (term2 != .Exited or term2.Exited != 0) {
        return error.ZipExtractionFailed;
    }
}

pub fn copyFile(src: []const u8, dst: []const u8) !void {
    const parent = std.fs.path.dirname(dst);
    if (parent) |p| {
        try std.fs.cwd().makePath(p);
    }

    const in_file = try std.fs.openFileAbsolute(src, .{});
    defer in_file.close();

    const stat = try in_file.stat();
    const mode = stat.mode;

    const out_file = try std.fs.createFileAbsolute(dst, .{ .mode = @as(std.fs.File.Mode, @intCast(mode & 0o777)) });
    defer out_file.close();

    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try in_file.read(&buf);
        if (n == 0) break;
        try out_file.writeAll(buf[0..n]);
    }
}

pub fn copyPath(allocator: Allocator, src: []const u8, dst: []const u8) !void {
    const stat = std.fs.openFileAbsolute(src, .{}) catch |err| {
        if (err == error.IsDir) {
            // It's a directory
            try std.fs.cwd().makePath(dst);
            var dir = try std.fs.openDirAbsolute(src, .{ .iterate = true });
            defer dir.close();

            var it = dir.iterate();
            while (try it.next()) |entry| {
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
    stat.close();
    try copyFile(src, dst);
}

pub fn installPath(allocator: Allocator, src: []const u8, dst: []const u8) !void {
    const parent = std.fs.path.dirname(dst) orelse ".";
    try std.fs.cwd().makePath(parent);

    const base_name = std.fs.path.basename(dst);
    const staging_dir_name = try std.fmt.allocPrint(allocator, "{s}/.rice-tmp-{d}", .{ parent, std.time.milliTimestamp() });
    defer allocator.free(staging_dir_name);

    try std.fs.cwd().makePath(staging_dir_name);
    defer std.fs.deleteTreeAbsolute(staging_dir_name) catch {};

    const staged_dst = try std.fs.path.join(allocator, &[_][]const u8{ staging_dir_name, base_name });
    defer allocator.free(staged_dst);

    try copyPath(allocator, src, staged_dst);

    std.fs.deleteTreeAbsolute(dst) catch {};
    std.fs.deleteFileAbsolute(dst) catch {};

    std.fs.renameAbsolute(staged_dst, dst) catch {
        try copyPath(allocator, staged_dst, dst);
    };
}

pub fn backupFile(allocator: Allocator, targetPath: []const u8) ![]u8 {
    _ = std.fs.openFileAbsolute(targetPath, .{}) catch |err| {
        if (err != error.IsDir) return err;
    };

    const ts = std.time.timestamp();
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
    if (std.fs.openFileAbsolute(final_backup, .{})) |f| {
        f.close();
    } else |_| {
        exists = false;
    }

    if (exists) {
        var found = false;
        var i: usize = 1;
        while (i <= 100) : (i += 1) {
            const cand = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ base_backup, i });
            var cand_exists = true;
            if (std.fs.openFileAbsolute(cand, .{})) |f| {
                f.close();
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
