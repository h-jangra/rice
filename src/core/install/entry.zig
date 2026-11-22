const std = @import("std");
const Allocator = std.mem.Allocator;
const git_mod = @import("../git.zig");
const paths = @import("../paths.zig");
const sparse = @import("sparse.zig");
const bin_cmd = @import("bin_cmd.zig");

pub const SourceInput = struct {
    args: std.ArrayList([]const u8),

    pub fn deinit(self: *SourceInput, allocator: Allocator) void {
        for (self.args.items) |a| allocator.free(a);
        self.args.deinit(allocator);
    }
};

fn appendSourceLine(allocator: Allocator, sources: *std.ArrayList(SourceInput), raw_line: []const u8) !void {
    const trimmed = std.mem.trim(u8, raw_line, " \t\r\n");
    if (trimmed.len == 0) return;
    if (trimmed[0] == '#') return;

    var src: SourceInput = .{ .args = .empty };
    errdefer src.deinit(allocator);

    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    while (it.next()) |tok| {
        try src.args.append(allocator, try allocator.dupe(u8, tok));
    }
    if (src.args.items.len == 0) {
        src.deinit(allocator);
        return;
    }
    try sources.append(allocator, src);
}

pub fn parseMultilineSources(allocator: Allocator, input: []const u8) !std.ArrayList(SourceInput) {
    var sources: std.ArrayList(SourceInput) = .empty;
    errdefer {
        for (sources.items) |*s| s.deinit(allocator);
        sources.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |raw_line| {
        try appendSourceLine(allocator, &sources, raw_line);
    }

    return sources;
}

pub fn readMultilineSources(allocator: Allocator, reader: anytype) !std.ArrayList(SourceInput) {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(allocator);
    var read_buf: [4096]u8 = undefined;

    while (true) {
        const n = reader.readStreaming(paths.getProcessIo(), &.{&read_buf}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        try data.appendSlice(allocator, read_buf[0..n]);
    }

    return parseMultilineSources(allocator, data.items);
}

pub fn runInteractiveSourceInput(allocator: Allocator, git: *git_mod.Git, homeDir: []const u8) anyerror!void {
    std.debug.print(
        \\Enter sources, one per line. Ctrl+D to install, Ctrl+C to cancel.
        \\
    , .{});

    var sources = try readMultilineSources(allocator, std.Io.File.stdin());
    defer {
        for (sources.items) |*s| s.deinit(allocator);
        sources.deinit(allocator);
    }

    if (sources.items.len == 0) {
        std.debug.print("\nNo sources entered. Nothing to install.\n", .{});
        return;
    }

    var installed: usize = 0;
    var failed: usize = 0;

    for (sources.items, 0..) |src, idx| {
        std.debug.print("\n[{d}/{d}] {s}\n", .{ idx + 1, sources.items.len, src.args.items[0] });
        installCmd(allocator, git, homeDir, src.args.items) catch |err| {
            failed += 1;
            std.debug.print("  [!] Failed: {s}\n", .{@errorName(err)});
            continue;
        };
        installed += 1;
    }

    std.debug.print(
        \\
        \\Rice · Install
        \\
        \\Sources    {d}
        \\Installed  {d}
        \\Failed     {d}
        \\
    , .{ sources.items.len, installed, failed });
}

pub fn installCmd(allocator: Allocator, git: *git_mod.Git, homeDir: []const u8, args: []const []const u8) !void {
    if (args.len == 0) {
        return runInteractiveSourceInput(allocator, git, homeDir);
    }

    var bin_mode = false;
    var bin_args: std.ArrayList([]const u8) = .empty;
    defer bin_args.deinit(allocator);

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--bin") or std.mem.eql(u8, arg, "--bins")) {
            bin_mode = true;
        } else if (std.mem.startsWith(u8, arg, "--bin=")) {
            bin_mode = true;
            const val = arg["--bin=".len..];
            if (val.len > 0) try bin_args.append(allocator, val);
        } else if (std.mem.startsWith(u8, arg, "--bins=")) {
            bin_mode = true;
            const val = arg["--bins=".len..];
            if (val.len > 0) try bin_args.append(allocator, val);
        } else {
            try bin_args.append(allocator, arg);
        }
    }

    if (bin_mode) {
        return bin_cmd.runBinInstall(allocator, homeDir, bin_args.items);
    }

    return sparse.installDotfiles(allocator, git, homeDir, args);
}
