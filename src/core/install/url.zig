const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const paths = @import("../paths/mod.zig");
const fs = @import("../fs.zig");
const ui = @import("../ui.zig");
const bin_mod = @import("../bin/mod.zig");

pub fn runDirectURLInstall(allocator: Allocator, homeDir: []const u8, rawURL: []const u8, rawDest: []const u8, contentsFlag: bool, forceFlag: bool) !void {
    const tmp_dir_path = try std.fmt.allocPrint(allocator, "/tmp/rice-dl-{d}", .{fs.getMilliTimestamp()});
    defer allocator.free(tmp_dir_path);
    try fs.makePath(tmp_dir_path);
    defer fs.deleteTreeAbsolute(tmp_dir_path) catch {};

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
        if (std.mem.indexOfAny(u8, clean_url, "?#")) |idx| clean_url = clean_url[0..idx];
        clean_url = std.mem.trimEnd(u8, clean_url, "/");

        const base = std.fs.path.basename(clean_url);
        asset_name = if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "/"))
            try allocator.dupe(u8, "downloaded_file")
        else
            try allocator.dupe(u8, base);

        dl_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, asset_name });

        {
            const dl_msg = try std.fmt.allocPrint(allocator, "Downloading {s}...", .{asset_name});
            defer allocator.free(dl_msg);
            const spinner = try ui.Spinner.start(allocator, dl_msg);
            defer spinner.stop();

            fs.downloadWithCurl(allocator, parsed_url, dl_path) catch |err| {
                std.debug.print("Error: failed to download from {s}\n", .{parsed_url});
                return err;
            };
        }
    } else {
        var resolved_dl = rawURL;
        var allocated_dl: ?[]u8 = null;
        defer if (allocated_dl) |d| allocator.free(d);

        if (std.mem.startsWith(u8, resolved_dl, "~/") or std.mem.startsWith(u8, resolved_dl, "~\\")) {
            allocated_dl = try std.fs.path.join(allocator, &.{ homeDir, resolved_dl[2..] });
            resolved_dl = allocated_dl.?;
        }
        asset_name = try allocator.dupe(u8, std.fs.path.basename(resolved_dl));
        dl_path = try allocator.dupe(u8, resolved_dl);
    }
    defer {
        allocator.free(asset_name);
        allocator.free(dl_path);
    }

    const data = std.Io.Dir.cwd().readFileAlloc(paths.getProcessIo(), dl_path, allocator, .limited(100 * 1024 * 1024)) catch |err| {
        std.debug.print("Error reading downloaded file '{s}': {s}\n", .{ dl_path, @errorName(err) });
        return err;
    };
    defer allocator.free(data);

    if (fs.isHTMLContent(data)) {
        std.debug.print("Error: downloaded URL returned an HTML page rather than the requested file or archive.\n", .{});
        return error.DownloadedFileIsHTML;
    }

    const is_arch = fs.isArchive(asset_name) or fs.isArchiveData(data);

    var dest_abs = paths.resolveUserPath(allocator, homeDir, rawDest) catch |err| {
        std.debug.print("Error resolving destination path '{s}': {s}\n", .{ rawDest, @errorName(err) });
        return err;
    };
    defer allocator.free(dest_abs);

    if (!contentsFlag and !is_arch) {
        var is_dir = false;
        if (std.mem.endsWith(u8, rawDest, "/") or std.mem.endsWith(u8, rawDest, "\\") or
            std.mem.eql(u8, rawDest, ".") or std.mem.eql(u8, rawDest, "..") or
            std.mem.eql(u8, rawDest, "./") or std.mem.eql(u8, rawDest, ".\\") or
            std.mem.eql(u8, rawDest, "../") or std.mem.eql(u8, rawDest, "..\\"))
        {
            is_dir = true;
        } else if (fs.isDirAbsolute(dest_abs)) {
            is_dir = true;
        }

        if (is_dir) {
            const joined = try std.fs.path.join(allocator, &.{ dest_abs, asset_name });
            allocator.free(dest_abs);
            dest_abs = joined;
        }
    }

    const clean_home = try paths.cleanPath(allocator, homeDir);
    defer allocator.free(clean_home);

    var dest_display: []u8 = undefined;
    if (std.mem.startsWith(u8, dest_abs, clean_home)) {
        var rest = dest_abs[clean_home.len..];
        if (rest.len > 0 and (rest[0] == '/' or rest[0] == '\\')) {
            dest_display = try std.fmt.allocPrint(allocator, "~/{s}", .{rest[1..]});
        } else if (rest.len == 0) {
            dest_display = try allocator.dupe(u8, "~");
        } else {
            dest_display = try allocator.dupe(u8, dest_abs);
        }
    } else {
        dest_display = try allocator.dupe(u8, dest_abs);
    }
    defer allocator.free(dest_display);

    if (!forceFlag) {
        var conflict = false;
        if (!is_arch and !contentsFlag) {
            if (fs.isFileAbsolute(dest_abs) or fs.isDirAbsolute(dest_abs)) {
                conflict = true;
            }
        }
        if (conflict) {
            const prompt = try std.fmt.allocPrint(allocator, "Destination '{s}' already exists.\nOverwrite? [y/N]: ", .{dest_abs});
            defer allocator.free(prompt);
            if (!fs.promptConfirm(prompt)) {
                std.debug.print("Installation cancelled.\n", .{});
                return;
            }
        }
    }

    if (is_arch) {
        const extract_dir = try std.fs.path.join(allocator, &.{ tmp_dir_path, "extracted" });
        defer allocator.free(extract_dir);
        try fs.makePath(extract_dir);

        {
            const ext_msg = try std.fmt.allocPrint(allocator, "Extracting {s}...", .{asset_name});
            defer allocator.free(ext_msg);
            const ext_sp = try ui.Spinner.start(allocator, ext_msg);
            defer ext_sp.stop();

            fs.extractArchive(allocator, data, asset_name, extract_dir) catch |err| {
                std.debug.print("Error extracting archive {s}: {s}\n", .{ asset_name, @errorName(err) });
                return err;
            };
        }

        var target_extract_path: []const u8 = extract_dir;
        var allocated_target: ?[]u8 = null;
        defer if (allocated_target) |t| allocator.free(t);

        if (!contentsFlag) {
            var dir = try fs.openDirAbsolute(extract_dir, .{ .iterate = true });
            var it = dir.iterate();
            var count: usize = 0;
            var single_child_name: ?[]u8 = null;
            var is_child_dir = false;
            while (try it.next(paths.getProcessIo())) |entry| {
                count += 1;
                if (single_child_name) |scn| allocator.free(scn);
                single_child_name = try allocator.dupe(u8, entry.name);
                is_child_dir = entry.kind == .directory;
            }
            dir.close(paths.getProcessIo());

            if (count == 1 and is_child_dir and single_child_name != null) {
                allocated_target = try std.fs.path.join(allocator, &.{ extract_dir, single_child_name.? });
                target_extract_path = allocated_target.?;
            }
            if (single_child_name) |scn| allocator.free(scn);
        }

        var use_sudo = false;
        fs.makePath(dest_abs) catch |err| {
            if ((err == error.AccessDenied or err == error.PermissionDenied) and builtin.os.tag != .windows) {
                const prompt = try std.fmt.allocPrint(allocator, "Permission denied creating directory '{s}'. Elevate with sudo? [y/N]: ", .{dest_abs});
                defer allocator.free(prompt);
                if (fs.promptConfirm(prompt)) {
                    use_sudo = true;
                } else {
                    std.debug.print("Installation cancelled.\n", .{});
                    return error.PermissionDenied;
                }
            } else {
                std.debug.print("Error creating directory '{s}': {s}\n", .{ dest_abs, @errorName(err) });
                return err;
            }
        };

        if (!use_sudo and builtin.os.tag != .windows) {
            const probe_path = try std.fmt.allocPrint(allocator, "{s}/.rice-probe-{d}", .{ dest_abs, fs.getMilliTimestamp() });
            defer allocator.free(probe_path);
            if (fs.createFileAbsolute(probe_path, .{})) |probe_file| {
                probe_file.close(paths.getProcessIo());
                fs.deleteFileAbsolute(probe_path) catch {};
            } else |err| {
                if (err == error.AccessDenied or err == error.PermissionDenied) {
                    const prompt = try std.fmt.allocPrint(allocator, "Permission denied writing to '{s}'. Elevate with sudo? [y/N]: ", .{dest_abs});
                    defer allocator.free(prompt);
                    if (fs.promptConfirm(prompt)) {
                        use_sudo = true;
                    } else {
                        std.debug.print("Installation cancelled.\n", .{});
                        return error.PermissionDenied;
                    }
                }
            }
        }

        if (use_sudo) {
            fs.sudoInstallPath(allocator, target_extract_path, dest_abs, false) catch |err| {
                std.debug.print("Error installing with sudo: {s}\n", .{@errorName(err)});
                return err;
            };
        } else {
            var ext_dir = fs.openDirAbsolute(target_extract_path, .{ .iterate = true }) catch |err| {
                std.debug.print("Error reading extracted files in '{s}': {s}\n", .{ target_extract_path, @errorName(err) });
                return err;
            };
            defer ext_dir.close(paths.getProcessIo());
            var it = ext_dir.iterate();
            while (try it.next(paths.getProcessIo())) |entry| {
                const src_child = try std.fs.path.join(allocator, &.{ target_extract_path, entry.name });
                defer allocator.free(src_child);
                const dst_child = try std.fs.path.join(allocator, &.{ dest_abs, entry.name });
                defer allocator.free(dst_child);
                fs.copyPath(allocator, src_child, dst_child) catch |err| {
                    if (err == error.AccessDenied or err == error.PermissionDenied) {
                        std.debug.print("Error: permission denied writing to '{s}'. Try running with sudo or check permissions.\n", .{dst_child});
                    } else {
                        std.debug.print("Error installing '{s}' to '{s}': {s}\n", .{ src_child, dst_child, @errorName(err) });
                    }
                    return err;
                };
            }
        }
    } else {
        fs.installPath(allocator, dl_path, dest_abs) catch |err| {
            if (err == error.AccessDenied or err == error.PermissionDenied) {
                std.debug.print("Error: permission denied installing to '{s}'. Try running with sudo or check permissions.\n", .{dest_abs});
            } else {
                std.debug.print("Error installing to '{s}': {s}\n", .{ dest_abs, @errorName(err) });
            }
            return err;
        };

        if (builtin.os.tag != .windows and (bin_mod.isExecutableBinary(data) or (!fs.isHTMLContent(data) and !bin_mod.isIgnoredCandidate(asset_name, false, asset_name)))) {
            if (fs.openFileAbsolute(dest_abs, .{})) |f| {
                f.setPermissions(paths.getProcessIo(), @enumFromInt(0o755)) catch {};
                f.close(paths.getProcessIo());
            } else |_| {}
        }
    }

    std.debug.print("Successfully installed '{s}' to {s}\n", .{ dest_display, dest_abs });
}

