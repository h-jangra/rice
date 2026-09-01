const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const paths = @import("paths/mod.zig");

pub fn downloadWithCurl(allocator: Allocator, url: []const u8, destPath: []const u8) !void {
    const res = std.process.run(allocator, paths.getProcessIo(), .{
        .argv = &.{ "curl", "-sSfL", "--proto", "=https,http", url, "-o", destPath },
    }) catch return error.CurlProcessFailed;
    defer {
        allocator.free(res.stdout);
        allocator.free(res.stderr);
    }

    if (res.term != .exited or res.term.exited != 0) {
        const err_str = std.mem.trim(u8, res.stderr, " \t\r\n");
        if (err_str.len > 0) std.debug.print("{s}\n", .{err_str});
        return error.CurlDownloadFailed;
    }
}

pub fn isHTMLContent(data: []const u8) bool {
    const sample_len = @min(data.len, 512);
    if (sample_len == 0) return false;

    var lower_buf: [512]u8 = undefined;
    for (data[0..sample_len], 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
    const lower = std.mem.trim(u8, lower_buf[0..sample_len], " \t\r\n");

    return std.mem.startsWith(u8, lower, "<!doctype html") or
        std.mem.startsWith(u8, lower, "<html") or
        std.mem.startsWith(u8, lower, "<?xml") or
        std.mem.indexOf(u8, lower, "<head>") != null or
        std.mem.indexOf(u8, lower, "<body>") != null;
}

pub fn isArchive(name: []const u8) bool {
    const exts = [_][]const u8{
        ".tar.gz", ".tgz",     ".zip",     ".tar",
        ".tar.xz", ".txz",     ".tar.bz2", ".tbz2",
        ".tbz",    ".tar.zst",
    };
    for (exts) |ext| {
        if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
    }
    return false;
}

pub fn isArchiveData(data: []const u8) bool {
    if (data.len >= 262 and std.mem.eql(u8, data[257..262], "ustar")) return true;
    if (data.len >= 2 and data[0] == 0x1f and data[1] == 0x8b) return true; // gzip
    if (data.len >= 4 and std.mem.eql(u8, data[0..4], &.{ 0x50, 0x4b, 0x03, 0x04 })) return true; // zip
    if (data.len >= 3 and std.mem.eql(u8, data[0..3], "BZh")) return true; // bz2
    if (data.len >= 6 and std.mem.eql(u8, data[0..6], &.{ 0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00 })) return true; // xz
    return data.len >= 4 and std.mem.eql(u8, data[0..4], &.{ 0x28, 0xb5, 0x2f, 0xfd }); // zstd
}

pub fn extractArchive(allocator: Allocator, data: []const u8, name: []const u8, destDir: []const u8) !void {
    if (std.ascii.endsWithIgnoreCase(name, ".zip") or (data.len >= 4 and std.mem.eql(u8, data[0..4], &.{ 0x50, 0x4b, 0x03, 0x04 }))) {
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

pub fn isFileAbsolute(p: []const u8) bool {
    if (openFileAbsolute(p, .{})) |f| {
        defer f.close(paths.getProcessIo());
        if (f.stat(paths.getProcessIo())) |stat| {
            return stat.kind != .directory;
        } else |_| return false;
    } else |_| return false;
}

pub fn isDirAbsolute(p: []const u8) bool {
    if (openDirAbsolute(p, .{})) |d| {
        var dir = d;
        dir.close(paths.getProcessIo());
        return true;
    } else |_| return false;
}

pub fn pathExistsAbsolute(p: []const u8) bool {
    return isFileAbsolute(p) or isDirAbsolute(p);
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

    const res = try std.process.run(allocator, paths.getProcessIo(), .{
        .argv = &.{ "tar", "-xf", tmp_file_path, "-C", destDir },
    });
    defer {
        allocator.free(res.stdout);
        allocator.free(res.stderr);
    }

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

    if (std.process.run(allocator, paths.getProcessIo(), .{ .argv = &.{ "unzip", "-q", "-o", tmp_file_path, "-d", destDir } })) |res| {
        defer {
            allocator.free(res.stdout);
            allocator.free(res.stderr);
        }
        if (res.term == .exited and res.term.exited == 0) return;
    } else |_| {}

    const res = try std.process.run(allocator, paths.getProcessIo(), .{ .argv = &.{ "tar", "-xf", tmp_file_path, "-C", destDir } });
    defer {
        allocator.free(res.stdout);
        allocator.free(res.stderr);
    }
    if (res.term != .exited or res.term.exited != 0) return error.ZipExtractionFailed;
}

pub fn copyFile(src: []const u8, dst: []const u8) !void {
    if (std.fs.path.dirname(dst)) |p| try makePath(p);

    const in_file = try openFileAbsolute(src, .{});
    defer in_file.close(paths.getProcessIo());

    const stat = try in_file.stat(paths.getProcessIo());
    const out_file = try createFileAbsolute(dst, .{ .permissions = stat.permissions });
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

pub fn promptConfirm(prompt: []const u8) bool {
    std.debug.print("{s}", .{prompt});
    var buf: [128]u8 = undefined;
    const n = std.Io.File.stdin().readStreaming(paths.getProcessIo(), &.{&buf}) catch return false;
    if (n > 0) {
        const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
        return std.ascii.eqlIgnoreCase(trimmed, "y") or std.ascii.eqlIgnoreCase(trimmed, "yes");
    }
    return false;
}

fn runInherit(argv: []const []const u8) !void {
    var child = try std.process.spawn(paths.getProcessIo(), .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(paths.getProcessIo());
    if (term != .exited or term.exited != 0) return error.SudoElevationFailed;
}

pub fn sudoInstallPath(allocator: Allocator, src: []const u8, dst: []const u8, is_executable: bool) !void {
    const parent = std.fs.path.dirname(dst) orelse ".";
    try runInherit(&.{ "sudo", "mkdir", "-p", parent });

    const is_src_dir = if (openDirAbsolute(src, .{})) |d| blk: {
        var dir = d;
        dir.close(paths.getProcessIo());
        break :blk true;
    } else |_| false;

    if (is_src_dir) {
        try runInherit(&.{ "sudo", "mkdir", "-p", dst });
        const src_glob = try std.fmt.allocPrint(allocator, "{s}/.", .{src});
        defer allocator.free(src_glob);
        try runInherit(&.{ "sudo", "cp", "-R", src_glob, dst });
    } else {
        try runInherit(&.{ "sudo", "cp", src, dst });
    }

    if (is_executable and builtin.os.tag != .windows) {
        try runInherit(&.{ "sudo", "chmod", "755", dst });
    }
}

fn handlePermissionDenied(allocator: Allocator, src: []const u8, dst: []const u8, err: anyerror, is_write: bool) !void {
    if ((err == error.AccessDenied or err == error.PermissionDenied) and builtin.os.tag != .windows) {
        const action = if (is_write) "writing to" else "creating directory";
        const prompt = try std.fmt.allocPrint(allocator, "Permission denied {s} '{s}'. Elevate with sudo? [y/N]: ", .{ action, dst });
        defer allocator.free(prompt);
        if (promptConfirm(prompt)) return sudoInstallPath(allocator, src, dst, false);
        return error.PermissionDenied;
    }
    return err;
}

pub fn copyPath(allocator: Allocator, src: []const u8, dst: []const u8) !void {
    if (openDirAbsolute(src, .{ .iterate = true })) |d| {
        var dir = d;
        defer dir.close(paths.getProcessIo());
        makePath(dst) catch |err| {
            return handlePermissionDenied(allocator, src, dst, err, false);
        };
        var it = dir.iterate();
        while (try it.next(paths.getProcessIo())) |entry| {
            const child_src = try std.fs.path.join(allocator, &.{ src, entry.name });
            defer allocator.free(child_src);
            const child_dst = try std.fs.path.join(allocator, &.{ dst, entry.name });
            defer allocator.free(child_dst);
            try copyPath(allocator, child_src, child_dst);
        }
    } else |_| {
        return copyFile(src, dst) catch |err| {
            return handlePermissionDenied(allocator, src, dst, err, true);
        };
    }
}

pub fn installPath(allocator: Allocator, src: []const u8, dst: []const u8) !void {
    const parent = std.fs.path.dirname(dst) orelse ".";
    makePath(parent) catch |err| {
        return handlePermissionDenied(allocator, src, parent, err, false);
    };

    const is_src_dir = if (openDirAbsolute(src, .{})) |d| blk: {
        var dir = d;
        dir.close(paths.getProcessIo());
        break :blk true;
    } else |_| false;

    if (!is_src_dir) {
        const is_dst_dir = if (openDirAbsolute(dst, .{})) |d| blk: {
            var dir = d;
            dir.close(paths.getProcessIo());
            break :blk true;
        } else |_| false;

        if (is_dst_dir) {
            const target = try std.fs.path.join(allocator, &.{ dst, std.fs.path.basename(src) });
            defer allocator.free(target);
            return copyFile(src, target) catch |err| {
                return handlePermissionDenied(allocator, src, target, err, true);
            };
        }
    }

    return copyPath(allocator, src, dst);
}

fn fileExists(p: []const u8) bool {
    return pathExistsAbsolute(p);
}

pub fn backupFile(allocator: Allocator, targetPath: []const u8) ![]u8 {
    _ = openFileAbsolute(targetPath, .{}) catch |err| {
        if (err != error.IsDir) _ = openDirAbsolute(targetPath, .{}) catch return err;
    };

    const epoch_seconds = @as(u64, @intCast(getTimestamp()));
    const day_seconds = epoch_seconds % 86400;
    const year_day = std.time.epoch.EpochDay{ .day = @as(u47, @intCast(epoch_seconds / 86400)) };
    const yd = year_day.calculateYearDay();
    const month_day = yd.calculateMonthDay();

    const base_backup = try std.fmt.allocPrint(allocator, "{s}.bak.{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        targetPath,
        yd.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds / 3600,
        (day_seconds % 3600) / 60,
        day_seconds % 60,
    });
    errdefer allocator.free(base_backup);

    var final_backup = base_backup;
    if (fileExists(final_backup)) {
        var found = false;
        var i: usize = 1;
        while (i <= 100) : (i += 1) {
            const cand = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ base_backup, i });
            if (!fileExists(cand)) {
                allocator.free(final_backup);
                final_backup = cand;
                found = true;
                break;
            }
            allocator.free(cand);
        }
        if (!found) return error.BackupCollisionLimitReached;
    }

    try copyPath(allocator, targetPath, final_backup);
    return final_backup;
}

