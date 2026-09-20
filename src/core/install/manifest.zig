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
        \\#
        \\# Delete lines you do not want to install.
        \\# To customize destination path / rename a file:
        \\#   <source_path> -> <destination_path>
        \\#   <source_path> : <destination_path>
        \\#
        \\# You can also edit the line to just the target filename (if unique in source):
        \\#   NotoSerif-Regular.ttf
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

pub const ManifestItem = struct {
    src_path: []const u8,
    dst_path: []const u8,

    pub fn deinit(self: ManifestItem, allocator: Allocator) void {
        allocator.free(self.src_path);
        allocator.free(self.dst_path);
    }
};

fn checkPathTraversal(path: []const u8) !void {
    if (path.len == 0) return error.PathTraversal;
    if (std.fs.path.isAbsolute(path) or path[0] == '/' or path[0] == '\\' or path[0] == '~') {
        std.debug.print("Error: invalid manifest entry '{s}': path traversal not allowed\n", .{path});
        return error.PathTraversal;
    }
    if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') {
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
}

fn resolveSource(
    original_paths: []const []const u8,
    orig_map: *const std.StringHashMap(void),
    raw_src: []const u8,
) ![]const u8 {
    if (orig_map.contains(raw_src)) {
        return raw_src;
    }

    var matched: ?[]const u8 = null;
    var match_count: usize = 0;

    for (original_paths) |p| {
        const base = std.fs.path.basename(p);
        const is_basename = std.mem.eql(u8, base, raw_src);
        const is_suffix = std.mem.endsWith(u8, p, raw_src) and
            (p.len == raw_src.len or p[p.len - raw_src.len - 1] == '/' or p[p.len - raw_src.len - 1] == '\\');

        if (is_basename or is_suffix) {
            matched = p;
            match_count += 1;
        }
    }

    if (match_count == 1) {
        return matched.?;
    } else if (match_count > 1) {
        std.debug.print("Error: ambiguous manifest entry '{s}': matches multiple files in source\n", .{raw_src});
        return error.InvalidManifestEntry;
    } else {
        std.debug.print("Error: invalid manifest entry '{s}': path was not in downloaded source\n", .{raw_src});
        return error.InvalidManifestEntry;
    }
}

const SplitResult = struct {
    src_part: []const u8,
    dst_part: ?[]const u8,
};

fn splitManifestLine(line: []const u8, orig_map: *const std.StringHashMap(void)) SplitResult {
    if (std.mem.indexOf(u8, line, "->")) |idx| {
        return .{
            .src_part = std.mem.trim(u8, line[0..idx], " \t\r\n"),
            .dst_part = std.mem.trim(u8, line[idx + 2 ..], " \t\r\n"),
        };
    }

    if (std.mem.indexOf(u8, line, " as ")) |idx| {
        return .{
            .src_part = std.mem.trim(u8, line[0..idx], " \t\r\n"),
            .dst_part = std.mem.trim(u8, line[idx + 4 ..], " \t\r\n"),
        };
    }

    if (std.mem.indexOf(u8, line, " = ")) |idx| {
        return .{
            .src_part = std.mem.trim(u8, line[0..idx], " \t\r\n"),
            .dst_part = std.mem.trim(u8, line[idx + 3 ..], " \t\r\n"),
        };
    }

    if (!orig_map.contains(line)) {
        if (std.mem.indexOfScalar(u8, line, ':')) |idx| {
            return .{
                .src_part = std.mem.trim(u8, line[0..idx], " \t\r\n"),
                .dst_part = std.mem.trim(u8, line[idx + 1 ..], " \t\r\n"),
            };
        }
    }

    return .{
        .src_part = line,
        .dst_part = null,
    };
}

pub fn validateManifestPaths(
    allocator: Allocator,
    remaining_paths: []const []const u8,
    original_paths: []const []const u8,
    source_dir: []const u8,
) !std.ArrayList(ManifestItem) {
    var orig_map = std.StringHashMap(void).init(allocator);
    defer orig_map.deinit();
    for (original_paths) |p| {
        try orig_map.put(p, {});
    }

    var seen_dst_map = std.StringHashMap([]const u8).init(allocator);
    defer seen_dst_map.deinit();

    var valid_list: std.ArrayList(ManifestItem) = .empty;
    errdefer {
        for (valid_list.items) |item| item.deinit(allocator);
        valid_list.deinit(allocator);
    }

    for (remaining_paths) |path| {
        if (path.len == 0) continue;

        const split_res = splitManifestLine(path, &orig_map);
        const raw_src = split_res.src_part;
        if (raw_src.len == 0) {
            std.debug.print("Error: invalid manifest entry '{s}': source path cannot be empty\n", .{path});
            return error.InvalidManifestEntry;
        }

        // 1. Path traversal check on source path
        try checkPathTraversal(raw_src);

        // 2. Resolve source path against downloaded source files
        const resolved_src = try resolveSource(original_paths, &orig_map, raw_src);

        // 3. Filesystem check: must exist in source_dir and be a file
        const full_src = try std.fs.path.join(allocator, &.{ source_dir, resolved_src });
        defer allocator.free(full_src);

        if (!fs.isFileAbsolute(full_src)) {
            std.debug.print("Error: invalid manifest entry '{s}': file does not exist in temporary download\n", .{resolved_src});
            return error.InvalidManifestEntry;
        }

        // 4. Resolve destination path
        var final_dst: []u8 = undefined;
        if (split_res.dst_part) |raw_dst| {
            if (raw_dst.len == 0) {
                std.debug.print("Error: invalid manifest entry '{s}': destination path cannot be empty\n", .{path});
                return error.InvalidManifestEntry;
            }
            if (std.mem.eql(u8, raw_dst, ".") or std.mem.eql(u8, raw_dst, "./") or std.mem.eql(u8, raw_dst, ".\\")) {
                final_dst = try allocator.dupe(u8, std.fs.path.basename(resolved_src));
            } else if (std.mem.endsWith(u8, raw_dst, "/") or std.mem.endsWith(u8, raw_dst, "\\")) {
                final_dst = try std.fs.path.join(allocator, &.{ raw_dst, std.fs.path.basename(resolved_src) });
            } else {
                final_dst = try allocator.dupe(u8, raw_dst);
            }
        } else {
            if (std.mem.eql(u8, path, resolved_src)) {
                final_dst = try allocator.dupe(u8, resolved_src);
            } else {
                final_dst = try allocator.dupe(u8, path);
            }
        }
        errdefer allocator.free(final_dst);

        // 5. Path traversal check on destination path
        checkPathTraversal(final_dst) catch |err| {
            allocator.free(final_dst);
            return err;
        };

        // 6. Deduplication and collision check
        if (seen_dst_map.get(final_dst)) |existing_src| {
            if (std.mem.eql(u8, existing_src, resolved_src)) {
                allocator.free(final_dst);
                continue;
            } else {
                std.debug.print("Error: duplicate destination '{s}' in manifest\n", .{final_dst});
                allocator.free(final_dst);
                return error.InvalidManifestEntry;
            }
        }
        try seen_dst_map.put(final_dst, resolved_src);

        try valid_list.append(allocator, .{
            .src_path = try allocator.dupe(u8, resolved_src),
            .dst_path = final_dst,
        });
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
        for (validated.items) |item| item.deinit(allocator);
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

    // Resolve absolute destinations and check conflicts
    var dest_paths: std.ArrayList([]u8) = .empty;
    defer {
        for (dest_paths.items) |dp| allocator.free(dp);
        dest_paths.deinit(allocator);
    }

    for (validated.items) |item| {
        var dest_abs: []u8 = undefined;
        if (custom_dest) |cd| {
            const cd_abs = try paths.resolveUserPath(allocator, homeDir, cd);
            defer allocator.free(cd_abs);
            // item.dst_path may be the same as src_path (no rename) or a custom name/path
            dest_abs = try std.fs.path.join(allocator, &.{ cd_abs, item.dst_path });
        } else {
            const dest_res = try paths.resolveInstallDestination(allocator, homeDir, item.dst_path, "", false);
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
    for (validated.items, dest_paths.items) |item, dest_abs| {
        const src_abs = try std.fs.path.join(allocator, &.{ source_dir, item.src_path });
        defer allocator.free(src_abs);

        try fs.installPath(allocator, src_abs, dest_abs);
        installed_count += 1;
    }

    printInstallSummary(selected_count, discarded_count, installed_count);
}
