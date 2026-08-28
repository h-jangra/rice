const std = @import("std");
const Allocator = std.mem.Allocator;
const git_mod = @import("../git/mod.zig");
const sparse = @import("sparse.zig");
const bin_cmd = @import("bin_cmd.zig");

pub fn installCmd(allocator: Allocator, git: *git_mod.Git, homeDir: []const u8, args: []const []const u8) !void {
    var bin_mode = false;
    var bin_args = std.ArrayList([]const u8).init(allocator);
    defer bin_args.deinit();

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--bin") or std.mem.eql(u8, arg, "--bins")) {
            bin_mode = true;
        } else if (std.mem.startsWith(u8, arg, "--bin=")) {
            bin_mode = true;
            const val = arg["--bin=".len..];
            if (val.len > 0) try bin_args.append(val);
        } else if (std.mem.startsWith(u8, arg, "--bins=")) {
            bin_mode = true;
            const val = arg["--bins=".len..];
            if (val.len > 0) try bin_args.append(val);
        } else {
            try bin_args.append(arg);
        }
    }

    if (bin_mode) {
        return bin_cmd.runBinInstall(allocator, homeDir, bin_args.items);
    }

    return sparse.installDotfiles(allocator, git, homeDir, args);
}
