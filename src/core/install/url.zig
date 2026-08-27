const std = @import("std");
const Allocator = std.mem.Allocator;
const paths = @import("../paths/mod.zig");
const fs = @import("../fs.zig");

fn confirmPrompt(prompt: []const u8) bool {
    std.debug.print("{s}", .{prompt});
    const stdin = std.io.getStdIn().reader();
    var buf: [128]u8 = undefined;
    if (stdin.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        if (line) |l| {
            const trimmed = std.mem.trim(u8, l, " \t\r\n");
            return std.ascii.eqlIgnoreCase(trimmed, "y") or std.ascii.eqlIgnoreCase(trimmed, "yes");
        }
    } else |_| {}
    return false;
}

pub fn runDirectURLInstall(allocator: Allocator, homeDir: []const u8, rawURL: []const u8, rawDest: []const u8, contentsFlag: bool) !void {
    const tmp_dir_path = try std.fmt.allocPrint(allocator, "/tmp/rice-dl-{d}", .{std.time.milliTimestamp()});
    defer allocator.free(tmp_dir_path);
    try std.fs.cwd().makePath(tmp_dir_path);
    defer std.fs.deleteTreeAbsolute(tmp_dir_path) catch {};

    var dl_path: []u8 = undefined;
    var asset_name: []u8 = undefined;

    if (paths.isURL(rawURL)) {
        var parsed_url = rawURL;
        var allocated_purl: ?[]u8 = null;
        defer if (allocated_purl) |p| allocator.free(p);

        if (std.mem.startsWith(u8, parsed_url, "github.com/")) {
            allocated_purl = try std.fmt.allocPrint(allocator, "https://{s}", .{parsed_url});
            parsed_url = allocated_purl.?;
        }

        var clean_url = parsed_url;
        if (std.mem.indexOfAny(u8, clean_url, "?#")) |idx| {
            clean_url = clean_url[0..idx];
        }
        clean_url = std.mem.trimRight(u8, clean_url, "/");

        const base = std.fs.path.basename(clean_url);
        asset_name = if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "/"))
            try allocator.dupe(u8, "downloaded_file")
        else
            try allocator.dupe(u8, base);

        dl_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp_dir_path, asset_name });
        try fs.downloadWithCurl(allocator, parsed_url, dl_path);
    } else {
        var resolved_dl = rawURL;
        var allocated_dl: ?[]u8 = null;
        defer if (allocated_dl) |d| allocator.free(d);

        if (std.mem.startsWith(u8, resolved_dl, "~/") or std.mem.startsWith(u8, resolved_dl, "~\\")) {
            allocated_dl = try std.fs.path.join(allocator, &[_][]const u8{ homeDir, resolved_dl[2..] });
            resolved_dl = allocated_dl.?;
        }
        asset_name = try allocator.dupe(u8, std.fs.path.basename(resolved_dl));
        dl_path = try allocator.dupe(u8, resolved_dl);
    }
    defer allocator.free(asset_name);
    defer allocator.free(dl_path);

    const f = try std.fs.openFileAbsolute(dl_path, .{});
    defer f.close();
    const data = try f.readToEndAlloc(allocator, 100 * 1024 * 1024);
    defer allocator.free(data);

    if (fs.isHTMLContent(data)) {
        std.debug.print("Error: downloaded URL returned an HTML page rather than the requested file or archive.\n", .{});
        return error.DownloadedFileIsHTML;
    }

    const is_arch = fs.isArchive(asset_name) or fs.isArchiveData(data);

    var dest_abs = try paths.resolveUserPath(allocator, homeDir, rawDest);
    defer allocator.free(dest_abs);

    if (!contentsFlag and !is_arch) {
        var is_dir = false;
        if (std.fs.openDirAbsolute(dest_abs, .{})) |d| {
            var dir = d;
            dir.close();
            is_dir = true;
        } else |_| {}

        if (is_dir or std.mem.endsWith(u8, rawDest, "/") or std.mem.endsWith(u8, rawDest, "\\")) {
            const joined = try std.fs.path.join(allocator, &[_][]const u8{ dest_abs, asset_name });
            allocator.free(dest_abs);
            dest_abs = joined;
        }
    }

    const clean_home = try paths.cleanPath(allocator, homeDir);
    defer allocator.free(clean_home);

    var is_outside = false;
    var dest_display: []u8 = undefined;

    if (std.mem.startsWith(u8, dest_abs, clean_home)) {
        var rest = dest_abs[clean_home.len..];
        if (rest.len > 0 and (rest[0] == '/' or rest[0] == '\\')) {
            rest = rest[1..];
            dest_display = try std.fmt.allocPrint(allocator, "~/{s}", .{rest});
        } else if (rest.len == 0) {
            dest_display = try allocator.dupe(u8, "~");
        } else {
            is_outside = true;
            dest_display = try allocator.dupe(u8, dest_abs);
        }
    } else {
        is_outside = true;
        dest_display = try allocator.dupe(u8, dest_abs);
    }
    defer allocator.free(dest_display);

    if (is_outside) {
        const p_prompt = try std.fmt.allocPrint(allocator, "Destination '{s}' is outside home directory ({s}).\nProceed? [y/N]: ", .{ dest_abs, homeDir });
        defer allocator.free(p_prompt);
        if (!confirmPrompt(p_prompt)) {
            std.debug.print("Installation cancelled.\n", .{});
            return;
        }
    }

    if (is_arch) {
        const extract_dir = try std.fs.path.join(allocator, &[_][]const u8{ tmp_dir_path, "extracted" });
        defer allocator.free(extract_dir);
        try std.fs.cwd().makePath(extract_dir);
        try fs.extractArchive(allocator, data, asset_name, extract_dir);

        var target_extract_path: []const u8 = extract_dir;
        if (!contentsFlag) {
            var dir = try std.fs.openDirAbsolute(extract_dir, .{ .iterate = true });
            var it = dir.iterate();
            var count: usize = 0;
            var single_child_name: ?[]const u8 = null;
            var is_child_dir = false;
            while (try it.next()) |entry| {
                count += 1;
                single_child_name = entry.name;
                is_child_dir = entry.kind == .directory;
            }
            dir.close();

            if (count == 1 and is_child_dir and single_child_name != null) {
                target_extract_path = try std.fs.path.join(allocator, &[_][]const u8{ extract_dir, single_child_name.? });
            }
        }

        try std.fs.cwd().makePath(dest_abs);

        var ext_dir = try std.fs.openDirAbsolute(target_extract_path, .{ .iterate = true });
        defer ext_dir.close();
        var it = ext_dir.iterate();
        while (try it.next()) |entry| {
            const src_child = try std.fs.path.join(allocator, &[_][]const u8{ target_extract_path, entry.name });
            defer allocator.free(src_child);
            const dst_child = try std.fs.path.join(allocator, &[_][]const u8{ dest_abs, entry.name });
            defer allocator.free(dst_child);
            try fs.copyPath(allocator, src_child, dst_child);
        }
    } else {
        try fs.installPath(allocator, dl_path, dest_abs);
    }

    std.debug.print("Successfully installed '{s}' to {s}\n", .{ dest_display, dest_abs });
}
