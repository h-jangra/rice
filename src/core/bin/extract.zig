const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = @import("../fs.zig");
const paths = @import("../paths/mod.zig");

pub fn isExecutableBinary(data: []const u8) bool {
    if (data.len >= 4 and std.mem.eql(u8, data[0..4], "\x7fELF")) return true;
    if (data.len >= 2 and std.mem.eql(u8, data[0..2], "MZ")) return true;
    if (data.len >= 4 and (std.mem.eql(u8, data[0..4], &.{ 0xfe, 0xed, 0xfa, 0xce }) or
        std.mem.eql(u8, data[0..4], &.{ 0xfe, 0xed, 0xfa, 0xcf }) or
        std.mem.eql(u8, data[0..4], &.{ 0xce, 0xfa, 0xed, 0xfe }) or
        std.mem.eql(u8, data[0..4], &.{ 0xcf, 0xfa, 0xed, 0xfe }) or
        std.mem.eql(u8, data[0..4], &.{ 0xca, 0xfe, 0xba, 0xbe }) or
        std.mem.eql(u8, data[0..4], &.{ 0xbe, 0xba, 0xfe, 0xca })))
    {
        return true;
    }
    if (data.len >= 2 and std.mem.eql(u8, data[0..2], "#!")) {
        const sample = data[0..@min(data.len, 256)];
        const interpreters = [_][]const u8{ "sh", "bash", "python", "node", "perl", "ruby", "env" };
        for (interpreters) |interp| {
            if (std.mem.indexOf(u8, sample, interp) != null) return true;
        }
    }
    return false;
}

pub fn isIgnoredCandidate(relPath: []const u8, is_dir: bool, base_name: []const u8) bool {
    if (is_dir) return true;

    var lower_base_buf: [256]u8 = undefined;
    const base = if (base_name.len <= 256) blk: {
        for (base_name, 0..) |c, i| lower_base_buf[i] = std.ascii.toLower(c);
        break :blk lower_base_buf[0..base_name.len];
    } else base_name;

    const ignored_exts = [_][]const u8{
        ".md",     ".txt",  ".1",    ".json", ".yaml", ".yml",
        ".toml",   ".rst",  ".html", ".htm",  ".man",  ".pdf",
        ".png",    ".jpg",  ".jpeg", ".gif",  ".svg",  ".bash",
        ".zsh",    ".fish", ".ps1",  ".sig",  ".asc",  ".sha256",
        ".sha512", ".c",    ".h",    ".cpp",  ".hpp",  ".cc",
        ".rs",     ".go",   ".zig",  ".java", ".py",   ".rb",
        ".js",     ".ts",   ".css",  ".scss", ".xml",  ".csv",
        ".lock",   ".mod",  ".sum",
    };
    for (ignored_exts) |ext| {
        if (std.mem.endsWith(u8, base, ext)) return true;
    }

    const doc_prefixes = [_][]const u8{ "license", "licence", "readme", "changelog", "changes", "contributing", "authors", "copying" };
    for (doc_prefixes) |p| {
        if (std.mem.startsWith(u8, base, p)) return true;
    }

    var it = std.mem.splitScalar(u8, relPath, '/');
    while (it.next()) |part| {
        if (std.ascii.eqlIgnoreCase(part, "autocomplete") or
            std.ascii.eqlIgnoreCase(part, "completions") or
            std.ascii.eqlIgnoreCase(part, "completion") or
            std.ascii.eqlIgnoreCase(part, "doc") or
            std.ascii.eqlIgnoreCase(part, "docs") or
            std.ascii.eqlIgnoreCase(part, "man"))
        {
            return true;
        }
    }

    return false;
}

pub fn matchCandidateName(candPath: []const u8, target: []const u8) bool {
    if (target.len == 0) return false;
    const base = std.fs.path.basename(candPath);
    if (std.ascii.eqlIgnoreCase(base, target)) return true;

    var buf: [256]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "{s}.exe", .{target})) |target_exe| {
        if (std.ascii.eqlIgnoreCase(base, target_exe)) return true;
    } else |_| {}

    if (std.mem.endsWith(u8, base, ".exe")) {
        const no_exe = base[0 .. base.len - 4];
        if (std.ascii.eqlIgnoreCase(no_exe, target)) return true;
    }

    return false;
}

fn collectCandidates(allocator: Allocator, root_dir: []const u8, rel_sub_path: []const u8, candidates: *std.ArrayList([]u8)) !void {
    const full_dir = if (rel_sub_path.len == 0)
        try allocator.dupe(u8, root_dir)
    else
        try std.fs.path.join(allocator, &.{ root_dir, rel_sub_path });
    defer allocator.free(full_dir);

    var dir = fs.openDirAbsolute(full_dir, .{ .iterate = true }) catch return;
    defer dir.close(paths.getProcessIo());

    var it = dir.iterate();
    while (try it.next(paths.getProcessIo())) |entry| {
        const child_rel = if (rel_sub_path.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fs.path.join(allocator, &.{ rel_sub_path, entry.name });
        defer allocator.free(child_rel);

        if (entry.kind == .directory) {
            try collectCandidates(allocator, root_dir, child_rel, candidates);
        } else {
            const base = std.fs.path.basename(child_rel);
            if (!isIgnoredCandidate(child_rel, false, base)) {
                const full = try std.fs.path.join(allocator, &.{ root_dir, child_rel });
                try candidates.append(allocator, full);
            }
        }
    }
}

pub fn findExecutable(allocator: Allocator, extractDir: []const u8, customName: []const u8, fallbackName: []const u8) ![]u8 {
    var candidates: std.ArrayList([]u8) = .empty;
    defer {
        for (candidates.items) |c| allocator.free(c);
        candidates.deinit(allocator);
    }

    try collectCandidates(allocator, extractDir, "", &candidates);

    if (candidates.items.len == 0) return error.NoExecutableFoundInArchive;

    for ([_][]const u8{ customName, fallbackName }) |name| {
        if (name.len > 0) {
            for (candidates.items) |c| {
                if (matchCandidateName(c, name)) return allocator.dupe(u8, c);
            }
        }
    }

    var exec_candidates: std.ArrayList([]u8) = .empty;
    defer exec_candidates.deinit(allocator);

    for (candidates.items) |c| {
        var is_exec = false;
        if (fs.openFileAbsolute(c, .{})) |f| {
            defer f.close(paths.getProcessIo());
            if (f.stat(paths.getProcessIo())) |st| {
                if ((@intFromEnum(st.permissions) & 0o111) != 0) is_exec = true;
            } else |_| {}
            if (!is_exec) {
                var header: [512]u8 = undefined;
                const n = f.readPositional(paths.getProcessIo(), &.{&header}, 0) catch 0;
                if (isExecutableBinary(header[0..n])) is_exec = true;
            }
        } else |_| {}
        if (is_exec) try exec_candidates.append(allocator, c);
    }

    if (exec_candidates.items.len == 1) return allocator.dupe(u8, exec_candidates.items[0]);
    if (candidates.items.len == 1) return allocator.dupe(u8, candidates.items[0]);

    return error.MultipleBinariesFound;
}

pub fn formatBinaryTree(allocator: Allocator, archiveName: []const u8, paths_list: []const []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "  ");
    try buf.appendSlice(allocator, archiveName);
    try buf.appendSlice(allocator, "\n");

    for (paths_list, 0..) |p, i| {
        const is_last = (i + 1 == paths_list.len);
        const connector = if (is_last) "└── " else "├── ";
        const item_line = try std.fmt.allocPrint(allocator, "  {s}[{d}] {s}\n", .{ connector, i + 1, p });
        defer allocator.free(item_line);
        try buf.appendSlice(allocator, item_line);
    }
    return buf.toOwnedSlice(allocator);
}

pub fn promptBinarySelection(allocator: Allocator, archiveName: []const u8, binaries: []const []const u8) ![]const u8 {
    if (binaries.len == 0) return error.NoExecutablesFound;
    if (binaries.len == 1) return binaries[0];

    const tree = try formatBinaryTree(allocator, archiveName, binaries);
    defer allocator.free(tree);

    std.debug.print("\nFound {d} executables in {s}:\n\n{s}\n", .{ binaries.len, archiveName, tree });

    while (true) {
        std.debug.print("Select binary to install [1-{d}]: ", .{binaries.len});
        var line_buf: [128]u8 = undefined;
        const n = std.Io.File.stdin().readStreaming(paths.getProcessIo(), &.{&line_buf}) catch return error.ReadFailed;
        if (n > 0) {
            const trimmed = std.mem.trim(u8, line_buf[0..n], " \t\r\n");
            const choice = std.fmt.parseInt(usize, trimmed, 10) catch {
                std.debug.print("Invalid selection \"{s}\", please enter a number between 1 and {d}\n", .{ trimmed, binaries.len });
                continue;
            };
            if (choice >= 1 and choice <= binaries.len) {
                return binaries[choice - 1];
            }
            std.debug.print("Invalid selection \"{s}\", please enter a number between 1 and {d}\n", .{ trimmed, binaries.len });
        }
    }
}

