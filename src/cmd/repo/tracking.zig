const std = @import("std");
const Allocator = std.mem.Allocator;
const git_mod = @import("../../core/git/mod.zig");
const paths = @import("../../core/paths/mod.zig");
const config = @import("../../core/config.zig");

pub fn loadConfigOrExit(allocator: Allocator, homeDir: []const u8) !*config.Config {
    const ini_path = try paths.getRiceIniPath(allocator, homeDir);
    defer allocator.free(ini_path);

    return config.loadConfig(allocator, ini_path) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("Error: ~/.rice.ini not found. Run 'rice init [remote]' first.\n", .{});
        } else {
            std.debug.print("Error: failed to load configuration: {s}\n", .{@errorName(err)});
        }
        return err;
    };
}

pub fn addCmd(allocator: Allocator, git: *git_mod.Git, homeDir: []const u8, args: []const []const u8) !void {
    if (args.len < 1) {
        std.debug.print("Error: path required.\nUsage: rice add <path>...\n", .{});
        return error.PathRequired;
    }

    var cfg = try loadConfigOrExit(allocator, homeDir);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }

    var git_paths_to_stage = std.ArrayList([]const u8).init(allocator);
    defer {
        for (git_paths_to_stage.items) |p| allocator.free(p);
        git_paths_to_stage.deinit();
    }

    var added_count: usize = 0;

    for (args) |arg| {
        const trimmed = std.mem.trim(u8, arg, " \t\r\n");
        if (trimmed.len == 0) continue;

        var res = paths.resolvePath(allocator, homeDir, trimmed) catch |err| {
            std.debug.print("Error: {s}\n", .{@errorName(err)});
            continue;
        };
        defer res.deinit(allocator);

        var exists = false;
        if (std.fs.openFileAbsolute(res.abs_path, .{})) |f| {
            f.close();
            exists = true;
        } else |_| {
            if (std.fs.openDirAbsolute(res.abs_path, .{})) |d| {
                var dir = d;
                dir.close();
                exists = true;
            } else |_| {}
        }

        if (!exists) {
            std.debug.print("Error: path does not exist: {s}\n", .{res.abs_path});
            continue;
        }

        if (paths.detectSensitiveFile(res.config_path)) |warning| {
            std.debug.print("Warning: '{s}' appears to be a {s}. Make sure you don't commit secrets to remote!\n", .{ res.config_path, warning });
        }

        if (try cfg.addFile(res.config_path)) {
            added_count += 1;
        }

        try git_paths_to_stage.append(try allocator.dupe(u8, res.git_path));
        std.debug.print("Added '{s}' to rice tracking.\n", .{res.config_path});
    }

    if (git_paths_to_stage.items.len == 0) return error.NoPathsStaged;

    const ini_path = try paths.getRiceIniPath(allocator, homeDir);
    defer allocator.free(ini_path);

    if (added_count > 0) {
        try config.saveConfig(allocator, ini_path, cfg);
    }

    var stage_all = std.ArrayList([]const u8).init(allocator);
    defer stage_all.deinit();
    try stage_all.append(".rice.ini");
    for (git_paths_to_stage.items) |p| try stage_all.append(p);

    try git.add(stage_all.items);
}

pub fn removeCmd(allocator: Allocator, git: *git_mod.Git, homeDir: []const u8, args: []const []const u8) !void {
    if (args.len < 1 or std.mem.trim(u8, args[0], " \t\r\n").len == 0) {
        std.debug.print("Error: path required.\nUsage: rice remove <path>\n", .{});
        return error.PathRequired;
    }

    var res = try paths.resolvePath(allocator, homeDir, args[0]);
    defer res.deinit(allocator);

    const ini_path = try paths.getRiceIniPath(allocator, homeDir);
    defer allocator.free(ini_path);

    var cfg = try loadConfigOrExit(allocator, homeDir);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }

    if (!cfg.hasFile(res.config_path)) {
        std.debug.print("Error: path '{s}' is not tracked in {s}\n", .{ res.config_path, ini_path });

        const raw_arg = std.mem.trim(u8, args[0], " \t\r\n");
        const bin_name = std.fs.path.basename(raw_arg);
        if (bin_name.len > 0) {
            var is_binary = cfg.binaries.contains(bin_name);
            if (!is_binary) {
                const bin_file_p = std.fs.path.join(allocator, &[_][]const u8{ homeDir, ".local", "bin", bin_name }) catch null;
                if (bin_file_p) |bfp| {
                    defer allocator.free(bfp);
                    if (std.fs.openFileAbsolute(bfp, .{})) |f| {
                        f.close();
                        is_binary = true;
                    } else |_| {}
                }
            }
            if (is_binary) {
                std.debug.print("Hint: '{s}' appears to be a binary. Did you mean 'rice bin remove {s}'?\n", .{ bin_name, bin_name });
            }
        }

        return error.PathNotTracked;
    }

    _ = cfg.removeFile(res.config_path);
    try config.saveConfig(allocator, ini_path, cfg);

    try git.removeCached(&[_][]const u8{res.git_path});
    try git.add(&[_][]const u8{".rice.ini"});

    std.debug.print("Removed '{s}' from rice tracking (working tree file preserved).\n", .{res.config_path});
}

pub fn listCmd(allocator: Allocator, homeDir: []const u8) !void {
    var cfg = try loadConfigOrExit(allocator, homeDir);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }

    for (cfg.files.items) |f| {
        std.debug.print("{s}\n", .{f});
    }
}

pub fn statusCmd(allocator: Allocator, git: *git_mod.Git, homeDir: []const u8) !void {
    var cfg = try loadConfigOrExit(allocator, homeDir);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }

    var list = std.ArrayList([]const u8).init(allocator);
    defer {
        for (list.items) |p| allocator.free(p);
        list.deinit();
    }
    try list.append(try allocator.dupe(u8, ".rice.ini"));

    for (cfg.files.items) |f| {
        if (paths.gitPath(allocator, homeDir, f)) |gp| {
            try list.append(gp);
        } else |_| {}
    }

    try git.status(list.items);
}

pub fn diffCmd(allocator: Allocator, git: *git_mod.Git, homeDir: []const u8, args: []const []const u8) !void {
    var cfg = try loadConfigOrExit(allocator, homeDir);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }

    var list = std.ArrayList([]const u8).init(allocator);
    defer {
        for (list.items) |p| allocator.free(p);
        list.deinit();
    }

    if (args.len > 0 and std.mem.trim(u8, args[0], " \t\r\n").len > 0) {
        var res = try paths.resolvePath(allocator, homeDir, args[0]);
        defer res.deinit(allocator);

        if (!std.mem.eql(u8, res.git_path, ".rice.ini") and !cfg.hasFile(res.config_path)) {
            std.debug.print("Error: path '{s}' is not tracked by rice\n", .{res.config_path});
            return error.PathNotTracked;
        }
        try list.append(try allocator.dupe(u8, res.git_path));
    } else {
        try list.append(try allocator.dupe(u8, ".rice.ini"));
        for (cfg.files.items) |f| {
            if (paths.gitPath(allocator, homeDir, f)) |gp| {
                try list.append(gp);
            } else |_| {}
        }
    }

    try git.diff(list.items);
}
