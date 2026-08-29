const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const paths = @import("../paths/mod.zig");
const config = @import("../config.zig");
const bin_mod = @import("../bin/mod.zig");
const sparse = @import("sparse.zig");
const fs = @import("../fs.zig");

pub fn printBinHelp() void {
    std.debug.print(
        \\Usage:
        \\  rice bin [install] <source> [--tag <tag>] [--name <name>] [--save]
        \\  rice bin list
        \\  rice bin remove <name>
        \\
        \\Aliases:
        \\  rice install -b <source>
        \\
        \\Examples:
        \\  rice bin sharkdp/bat
        \\  rice bin install sharkdp/bat
        \\  rice bin junegunn/fzf --save
        \\  rice bin starship/starship --tag v1.18.0
        \\  rice install -b sharkdp/bat
        \\  rice bin https://example.com/tool.tar.gz
        \\  rice bin ./tool --name mytool
        \\  rice bin list
        \\  rice bin remove bat
        \\
    , .{});
}

pub fn runBinInstall(allocator: Allocator, homeDir: []const u8, args: []const []const u8) !void {
    var opts = bin_mod.InstallBinOptions{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--tag")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --tag requires a tag argument.\n", .{});
                return error.InvalidArgs;
            }
            opts.tag = std.mem.trim(u8, args[i + 1], " \t\r\n");
            i += 1;
        } else if (std.mem.startsWith(u8, arg, "--tag=")) {
            opts.tag = std.mem.trim(u8, arg["--tag=".len..], " \t\r\n");
        } else if (std.mem.eql(u8, arg, "--name")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --name requires a name argument.\n", .{});
                return error.InvalidArgs;
            }
            opts.name = std.mem.trim(u8, args[i + 1], " \t\r\n");
            i += 1;
        } else if (std.mem.startsWith(u8, arg, "--name=")) {
            opts.name = std.mem.trim(u8, arg["--name=".len..], " \t\r\n");
        } else if (std.mem.eql(u8, arg, "--save")) {
            opts.save = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printBinHelp();
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Error: unknown flag \"{s}\"\n\n", .{arg});
            printBinHelp();
            return error.UnknownFlag;
        } else if (opts.source.len == 0) {
            opts.source = arg;
        } else {
            std.debug.print("Error: too many arguments provided.\n\n", .{});
            printBinHelp();
            return error.TooManyArgs;
        }
    }

    if (opts.source.len == 0) {
        std.debug.print("Error: source repository, URL, or file path required.\n", .{});
        printBinHelp();
        return error.SourceRequired;
    }

    const final_path = try bin_mod.installBinary(allocator, opts, homeDir);
    defer allocator.free(final_path);

    std.debug.print("Successfully installed '{s}' to {s}\n", .{ std.fs.path.basename(final_path), final_path });
}

pub fn runBinList(allocator: Allocator, homeDir: []const u8) !void {
    const ini_path = try paths.getRiceIniPath(allocator, homeDir);
    defer allocator.free(ini_path);

    const cfg = config.loadConfig(allocator, ini_path) catch {
        std.debug.print("No binaries configured in ~/.rice.ini\n", .{});
        return;
    };
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }

    if (cfg.binaries.count() == 0) {
        std.debug.print("No binaries configured in ~/.rice.ini\n", .{});
        return;
    }

    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(allocator);

    var it = cfg.binaries.iterator();
    while (it.next()) |entry| {
        try keys.append(allocator, entry.key_ptr.*);
    }

    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    const bin_dir = try std.fs.path.join(allocator, &[_][]const u8{ homeDir, ".local", "bin" });
    defer allocator.free(bin_dir);

    for (keys.items) |name| {
        var status: []const u8 = "missing";
        const bin_p = try std.fs.path.join(allocator, &[_][]const u8{ bin_dir, name });
        defer allocator.free(bin_p);

        if (fs.openFileAbsolute(bin_p, .{})) |f| {
            f.close(paths.getProcessIo());
            status = "installed";
        } else |_| {}

        std.debug.print("{s:<10}{s}\n", .{ name, status });
    }
}

pub fn runBinRemove(allocator: Allocator, homeDir: []const u8, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Error: binary name required.\n", .{});
        printBinHelp();
        return error.BinaryNameRequired;
    }

    const name = std.mem.trim(u8, args[0], " \t\r\n");
    try paths.validateBinaryName(name);

    const bin_dir = try std.fs.path.join(allocator, &[_][]const u8{ homeDir, ".local", "bin" });
    defer allocator.free(bin_dir);

    const target_file = try std.fs.path.join(allocator, &[_][]const u8{ bin_dir, name });
    defer allocator.free(target_file);

    var exists = false;
    if (fs.openFileAbsolute(target_file, .{})) |f| {
        f.close(paths.getProcessIo());
        exists = true;
    } else |_| {}

    if (!exists) {
        std.debug.print("Error: binary \"{s}\" not found in {s}\n", .{ name, bin_dir });
        return error.BinaryNotFound;
    }

    try fs.deleteFileAbsolute(target_file);
    std.debug.print("Removed '{s}' from {s}\n", .{ name, bin_dir });
}

pub fn binCmd(allocator: Allocator, homeDir: []const u8, args: []const []const u8) !void {
    if (args.len == 0) {
        printBinHelp();
        return error.InvalidArgs;
    }

    const subcmd = args[0];
    if (std.mem.eql(u8, subcmd, "install") or std.mem.eql(u8, subcmd, "i")) {
        return runBinInstall(allocator, homeDir, args[1..]);
    } else if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
        return runBinList(allocator, homeDir);
    } else if (std.mem.eql(u8, subcmd, "remove") or std.mem.eql(u8, subcmd, "rm")) {
        return runBinRemove(allocator, homeDir, args[1..]);
    } else if (std.mem.eql(u8, subcmd, "help") or std.mem.eql(u8, subcmd, "-h") or std.mem.eql(u8, subcmd, "--help")) {
        printBinHelp();
    } else {
        return runBinInstall(allocator, homeDir, args);
    }
}
