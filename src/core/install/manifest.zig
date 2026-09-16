const std = @import("std");
const Allocator = std.mem.Allocator;
const paths = @import("../paths.zig");
const fs = @import("../fs.zig");

pub fn collectSourceFiles(allocator: Allocator, source_dir: []const u8) !std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }
    try collectRecursive(allocator, source_dir, "", &list);

    // Sort alphabetically
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    return list;
}

fn collectRecursive(
    allocator: Allocator,
    root_dir: []const u8,
    current_rel: []const u8,
    list: *std.ArrayList([]const u8),
) !void {
    const full_dir = if (current_rel.len == 0)
        try allocator.dupe(u8, root_dir)
    else
        try std.fs.path.join(allocator, &.{ root_dir, current_rel });
    defer allocator.free(full_dir);

    var dir = fs.openDirAbsolute(full_dir, .{ .iterate = true }) catch return;
    defer dir.close(paths.getProcessIo());

    var it = dir.iterate();
    while (try it.next(paths.getProcessIo())) |entry| {
        if (std.mem.eql(u8, entry.name, ".git")) continue;
        if (current_rel.len == 0 and std.mem.eql(u8, entry.name, ".rice.ini")) continue;

        const entry_rel = if (current_rel.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ current_rel, entry.name });
        errdefer allocator.free(entry_rel);

        const child_full = try std.fs.path.join(allocator, &.{ root_dir, entry_rel });
        defer allocator.free(child_full);

        var is_dir = (entry.kind == .directory);
        if (entry.kind == .unknown) {
            if (fs.openDirAbsolute(child_full, .{})) |d| {
                var opened = d;
                opened.close(paths.getProcessIo());
                is_dir = true;
            } else |_| {}
        }

        if (is_dir) {
            try collectRecursive(allocator, root_dir, entry_rel, list);
            allocator.free(entry_rel);
        } else {
            try list.append(allocator, entry_rel);
        }
    }
}

pub fn generateManifestFile(allocator: Allocator, manifest_path: []const u8, file_paths: []const []const u8) !void {
    var file = try fs.createFileAbsolute(manifest_path, .{});
    defer file.close(paths.getProcessIo());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator,
        \\# Rice install manifest
        \\
        \\# Delete paths you do not want to install.
        \\
        \\
    );

    for (file_paths) |p| {
        try buf.appendSlice(allocator, p);
        try buf.append(allocator, '\n');
    }

    try file.writePositionalAll(paths.getProcessIo(), buf.items, 0);
}

pub fn readManifestFile(allocator: Allocator, manifest_path: []const u8) !std.ArrayList([]const u8) {
    const data = try fs.readFileAlloc(allocator, manifest_path, .limited(10 * 1024 * 1024));
    defer allocator.free(data);

    var remaining: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (remaining.items) |p| allocator.free(p);
        remaining.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw_line| {
        var line = raw_line;
        if (std.mem.endsWith(u8, line, "\r")) {
            line = line[0 .. line.len - 1];
        }
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;

        try remaining.append(allocator, try allocator.dupe(u8, trimmed));
    }

    return remaining;
}

pub fn validateManifestPaths(
    allocator: Allocator,
    remaining_paths: []const []const u8,
    original_paths: []const []const u8,
    source_dir: []const u8,
) !std.ArrayList([]const u8) {
    var orig_map = std.StringHashMap(void).init(allocator);
    defer orig_map.deinit();
    for (original_paths) |p| {
        try orig_map.put(p, {});
    }

    var seen_map = std.StringHashMap(void).init(allocator);
    defer seen_map.deinit();

    var valid_list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (valid_list.items) |p| allocator.free(p);
        valid_list.deinit(allocator);
    }

    for (remaining_paths) |path| {
        if (path.len == 0) continue;

        // 1. Path traversal check: must not be absolute, must not start with ~ or drive, must not have ".."
        if (std.fs.path.isAbsolute(path) or path[0] == '/' or path[0] == '\\' or path[0] == '~') {
            std.debug.print("Error: invalid manifest entry '{s}': path traversal not allowed\n", .{path});
            return error.PathTraversal;
        }

        var comp_it = std.mem.splitScalar(u8, path, '/');
        while (comp_it.next()) |comp| {
            var sub_it = std.mem.splitScalar(u8, comp, '\\');
            while (sub_it.next()) |sub| {
                if (std.mem.eql(u8, sub, "..")) {
                    std.debug.print("Error: invalid manifest entry '{s}': path traversal not allowed\n", .{path});
                    return error.PathTraversal;
                }
            }
        }

        // 2. Whitelist check: must be in original_paths
        if (!orig_map.contains(path)) {
            std.debug.print("Error: invalid manifest entry '{s}': path was not in downloaded source\n", .{path});
            return error.InvalidManifestEntry;
        }

        // 3. Filesystem check: must exist in source_dir and be a file
        const full_src = try std.fs.path.join(allocator, &.{ source_dir, path });
        defer allocator.free(full_src);

        if (!fs.isFileAbsolute(full_src)) {
            std.debug.print("Error: invalid manifest entry '{s}': file does not exist in temporary download\n", .{path});
            return error.InvalidManifestEntry;
        }

        // 4. Deduplicate
        if (seen_map.contains(path)) continue;
        try seen_map.put(path, {});

        try valid_list.append(allocator, try allocator.dupe(u8, path));
    }

    return valid_list;
}

pub fn openInEditor(allocator: Allocator, manifest_path: []const u8) !void {
    return openInEditorWithCustom(allocator, manifest_path, null);
}

pub fn openInEditorWithCustom(allocator: Allocator, manifest_path: []const u8, custom_editor: ?[]const u8) !void {
    var editor_str: []const u8 = "vi";
    var allocated_ed: ?[]u8 = null;
    defer if (allocated_ed) |ed| allocator.free(ed);

    if (custom_editor) |ce| {
        editor_str = ce;
    } else {
        const env = paths.getProcessEnviron();
        if (std.process.Environ.getAlloc(env, allocator, "VISUAL")) |ed| {
            if (std.mem.trim(u8, ed, " \t\r\n").len > 0) {
                allocated_ed = ed;
                editor_str = std.mem.trim(u8, ed, " \t\r\n");
            } else {
                allocator.free(ed);
            }
        } else |_| {}

        if (allocated_ed == null) {
            if (std.process.Environ.getAlloc(env, allocator, "EDITOR")) |ed| {
                if (std.mem.trim(u8, ed, " \t\r\n").len > 0) {
                    allocated_ed = ed;
                    editor_str = std.mem.trim(u8, ed, " \t\r\n");
                } else {
                    allocator.free(ed);
                }
            } else |_| {}
        }
    }

    var it = std.mem.splitScalar(u8, editor_str, ' ');
    var cmd_list: std.ArrayList([]const u8) = .empty;
    defer cmd_list.deinit(allocator);

    while (it.next()) |part| {
        if (part.len > 0) try cmd_list.append(allocator, part);
    }
    if (cmd_list.items.len == 0) {
        try cmd_list.append(allocator, "vi");
    }
    try cmd_list.append(allocator, manifest_path);

    var env_map = try std.process.Environ.createMap(paths.getProcessEnviron(), allocator);
    defer env_map.deinit();

    var child = std.process.spawn(paths.getProcessIo(), .{
        .argv = cmd_list.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .environ_map = &env_map,
    }) catch |err| {
        std.debug.print("Error: failed to open editor '{s}': {s}\n", .{ cmd_list.items[0], @errorName(err) });
        return err;
    };

    const term = try child.wait(paths.getProcessIo());
    if (term != .exited or term.exited != 0) {
        return error.EditorFailed;
    }
}

pub fn printInstallSummary(selected_count: usize, discarded_count: usize, installed_count: usize) void {
    std.debug.print(
        \\
        \\Rice · Install
        \\
        \\Selected   {d}
        \\Discarded  {d}
        \\
        \\✓ Installed {d} {s}
        \\
    , .{
        selected_count,
        discarded_count,
        installed_count,
        if (installed_count == 1) "file" else "files",
    });
}

pub fn runInteractiveInstall(
    allocator: Allocator,
    homeDir: []const u8,
    source_dir: []const u8,
    custom_dest: ?[]const u8,
    force_flag: bool,
    editor_cmd: ?[]const u8,
) !void {
    var files = try collectSourceFiles(allocator, source_dir);
    defer {
        for (files.items) |p| allocator.free(p);
        files.deinit(allocator);
    }

    if (files.items.len == 0) {
        std.debug.print("No installable files found in downloaded source.\n", .{});
        return;
    }

    const manifest_path = try std.fmt.allocPrint(allocator, "/tmp/rice-manifest-{d}.txt", .{fs.getMilliTimestamp()});
    defer allocator.free(manifest_path);
    defer fs.deleteFileAbsolute(manifest_path) catch {};

    try generateManifestFile(allocator, manifest_path, files.items);

    try openInEditorWithCustom(allocator, manifest_path, editor_cmd);

    var remaining = try readManifestFile(allocator, manifest_path);
    defer {
        for (remaining.items) |p| allocator.free(p);
        remaining.deinit(allocator);
    }

    var validated = try validateManifestPaths(allocator, remaining.items, files.items, source_dir);
    defer {
        for (validated.items) |p| allocator.free(p);
        validated.deinit(allocator);
    }

    const selected_count = validated.items.len;
    const discarded_count = files.items.len - selected_count;

    if (selected_count == 0) {
        std.debug.print(
            \\
            \\Rice · Install
            \\
            \\Selected   0
            \\Discarded  {d}
            \\
            \\No files selected for installation.
            \\
        , .{discarded_count});
        return;
    }

    // Resolve destinations and check conflicts
    var dest_paths: std.ArrayList([]u8) = .empty;
    defer {
        for (dest_paths.items) |dp| allocator.free(dp);
        dest_paths.deinit(allocator);
    }

    for (validated.items) |path| {
        var dest_abs: []u8 = undefined;
        if (custom_dest) |cd| {
            const cd_abs = try paths.resolveUserPath(allocator, homeDir, cd);
            defer allocator.free(cd_abs);
            dest_abs = try std.fs.path.join(allocator, &.{ cd_abs, path });
        } else {
            const dest_res = try paths.resolveInstallDestination(allocator, homeDir, path, "", false);
            allocator.free(dest_res.config_path);
            dest_abs = dest_res.abs_path;
        }
        try dest_paths.append(allocator, dest_abs);
    }

    if (!force_flag) {
        for (dest_paths.items) |dest_abs| {
            if (fs.isFileAbsolute(dest_abs)) {
                const prompt = try std.fmt.allocPrint(allocator, "Destination '{s}' already exists.\nOverwrite? [y/N]: ", .{dest_abs});
                defer allocator.free(prompt);
                if (!fs.promptConfirm(prompt)) {
                    std.debug.print("Installation cancelled.\n", .{});
                    return;
                }
            }
        }
    }

    // Install remaining paths
    var installed_count: usize = 0;
    for (validated.items, dest_paths.items) |rel_path, dest_abs| {
        const src_abs = try std.fs.path.join(allocator, &.{ source_dir, rel_path });
        defer allocator.free(src_abs);

        try fs.installPath(allocator, src_abs, dest_abs);
        installed_count += 1;
    }

    printInstallSummary(selected_count, discarded_count, installed_count);
}
