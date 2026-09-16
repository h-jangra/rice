const std = @import("std");
const Allocator = std.mem.Allocator;
const git_mod = @import("../../core/git.zig");
const paths = @import("../../core/paths.zig");
const config = @import("../../core/config.zig");
const fs = @import("../../core/fs.zig");

pub fn loadConfigOrDefault(allocator: Allocator, homeDir: []const u8) !*config.Config {
    const ini_path = try paths.getRiceIniPath(allocator, homeDir);
    defer allocator.free(ini_path);
    return config.loadConfigOrDefault(allocator, ini_path);
}

pub fn loadConfigOrExit(allocator: Allocator, homeDir: []const u8) !*config.Config {
    return loadConfigOrDefault(allocator, homeDir);
}

pub fn addCmd(allocator: Allocator, git: *git_mod.Git, homeDir: []const u8, args: []const []const u8) !void {
    if (args.len < 1) {
        std.debug.print("Error: path required.\nUsage: rice add <path>...\n", .{});
        return error.PathRequired;
    }

    var cfg = try loadConfigOrDefault(allocator, homeDir);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }

    var git_paths_to_stage: std.ArrayList([]const u8) = .empty;
    defer {
        for (git_paths_to_stage.items) |p| allocator.free(p);
        git_paths_to_stage.deinit(allocator);
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
        if (fs.openFileAbsolute(res.abs_path, .{})) |f| {
            f.close(paths.getProcessIo());
            exists = true;
        } else |_| {
            if (fs.openDirAbsolute(res.abs_path, .{})) |d| {
                var dir = d;
                dir.close(paths.getProcessIo());
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

        try git_paths_to_stage.append(allocator, try allocator.dupe(u8, res.git_path));
        std.debug.print("Added '{s}' to rice tracking.\n", .{res.config_path});
    }

    if (git_paths_to_stage.items.len == 0) return error.NoPathsStaged;

    const ini_path = try paths.getRiceIniPath(allocator, homeDir);
    defer allocator.free(ini_path);

    const has_ini = fs.isFileAbsolute(ini_path);
    if (added_count > 0 and has_ini) {
        try config.saveConfig(allocator, ini_path, cfg);
    }

    var stage_all: std.ArrayList([]const u8) = .empty;
    defer stage_all.deinit(allocator);
    if (has_ini) try stage_all.append(allocator, ".rice.ini");
    for (git_paths_to_stage.items) |p| try stage_all.append(allocator, p);

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

    var cfg = try loadConfigOrDefault(allocator, homeDir);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }

    const has_in_cfg = cfg.hasFile(res.config_path);
    var has_in_git = false;
    if (git.listTrackedFiles(&.{res.git_path})) |tf| {
        var tf_mut = tf;
        defer {
            for (tf_mut.items) |item| allocator.free(item);
            tf_mut.deinit(allocator);
        }
        if (tf_mut.items.len > 0) has_in_git = true;
    } else |_| {}

    if (!has_in_cfg and !has_in_git) {
        std.debug.print("Error: path '{s}' is not tracked by rice\n", .{res.config_path});

        const raw_arg = std.mem.trim(u8, args[0], " \t\r\n");
        const bin_name = std.fs.path.basename(raw_arg);
        if (bin_name.len > 0) {
            var is_binary = cfg.binaries.contains(bin_name);
            if (!is_binary) {
                const bin_file_p = std.fs.path.join(allocator, &.{ homeDir, ".local", "bin", bin_name }) catch null;
                if (bin_file_p) |bfp| {
                    defer allocator.free(bfp);
                    if (fs.openFileAbsolute(bfp, .{})) |f| {
                        f.close(paths.getProcessIo());
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

    if (has_in_cfg) {
        _ = cfg.removeFile(res.config_path);
        if (fs.isFileAbsolute(ini_path)) {
            try config.saveConfig(allocator, ini_path, cfg);
        }
    }

    try git.removeCached(&.{res.git_path});
    if (fs.isFileAbsolute(ini_path)) {
        try git.add(&.{".rice.ini"});
    }

    std.debug.print("Removed '{s}' from rice tracking (working tree file preserved).\n", .{res.config_path});
}

pub fn listCmd(allocator: Allocator, homeDir: []const u8) !void {
    var cfg = try loadConfigOrDefault(allocator, homeDir);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }

    if (cfg.files.items.len > 0) {
        for (cfg.files.items) |f| std.debug.print("{s}\n", .{f});
        return;
    }

    var git = git_mod.Git.init(allocator, homeDir) catch return;
    defer git.deinit();

    if (git.getAllGitTrackedFiles()) |files| {
        var f_mut = files;
        defer {
            for (f_mut.items) |p| allocator.free(p);
            f_mut.deinit(allocator);
        }
        for (f_mut.items) |f| {
            if (std.mem.eql(u8, f, ".rice.ini")) continue;
            std.debug.print("~/{s}\n", .{f});
        }
    } else |_| {}
}

pub fn statusCmd(allocator: Allocator, git: *git_mod.Git, homeDir: []const u8, args: []const []const u8) !void {
    if (!git.isBareRepo()) {
        std.debug.print("Error: bare repository {s} not found or invalid.\n", .{git.rice_dir});
        return error.BareRepoInvalid;
    }

    var show_all = false;
    var user_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (user_paths.items) |p| allocator.free(p);
        user_paths.deinit(allocator);
    }

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--all")) {
            show_all = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            show_all = true;
        } else {
            const trimmed = std.mem.trim(u8, arg, " \t\r\n");
            if (trimmed.len > 0) try user_paths.append(allocator, try allocator.dupe(u8, trimmed));
        }
    }

    var path_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (path_list.items) |p| allocator.free(p);
        path_list.deinit(allocator);
    }

    var seen_paths = std.StringHashMap(void).init(allocator);
    defer seen_paths.deinit();

    if (user_paths.items.len > 0) {
        for (user_paths.items) |up| {
            if (std.mem.eql(u8, up, ".rice.ini")) {
                if (!seen_paths.contains(".rice.ini")) {
                    try seen_paths.put(".rice.ini", {});
                    try path_list.append(allocator, try allocator.dupe(u8, ".rice.ini"));
                }
            } else if (paths.resolvePath(allocator, homeDir, up)) |res| {
                var r = res;
                defer r.deinit(allocator);
                if (!seen_paths.contains(r.git_path)) {
                    try seen_paths.put(r.git_path, {});
                    try path_list.append(allocator, try allocator.dupe(u8, r.git_path));
                }
            } else |_| {}
        }
    } else {
        var cfg = try loadConfigOrDefault(allocator, homeDir);
        defer {
            cfg.deinit();
            allocator.destroy(cfg);
        }

        const ini_path = try paths.getRiceIniPath(allocator, homeDir);
        defer allocator.free(ini_path);

        if (fs.isFileAbsolute(ini_path)) {
            try seen_paths.put(".rice.ini", {});
            try path_list.append(allocator, try allocator.dupe(u8, ".rice.ini"));
        }

        for (cfg.files.items) |f| {
            if (paths.gitPath(allocator, homeDir, f)) |gp| {
                if (!seen_paths.contains(gp)) {
                    try seen_paths.put(gp, {});
                    try path_list.append(allocator, gp);
                } else {
                    allocator.free(gp);
                }
            } else |_| {}
        }

        if (git.listIndexFiles()) |idx_files| {
            var if_mut = idx_files;
            defer {
                for (if_mut.items) |p| allocator.free(p);
                if_mut.deinit(allocator);
            }
            for (if_mut.items) |f| {
                if (!seen_paths.contains(f)) {
                    try seen_paths.put(f, {});
                    try path_list.append(allocator, try allocator.dupe(u8, f));
                }
            }
        } else |_| {}
    }

    std.debug.print("Rice status\n\n", .{});

    if (path_list.items.len == 0 and !git.hasCommits()) {
        std.debug.print("  Clean\n    No changes detected\n", .{});
        return;
    }

    var cmd_args: std.ArrayList([]const u8) = .empty;
    defer cmd_args.deinit(allocator);
    try cmd_args.appendSlice(allocator, &.{ "status", "--porcelain", "-u", "--" });
    for (path_list.items) |p| try cmd_args.append(allocator, p);

    const raw_status = git.output(cmd_args.items) catch "";
    defer allocator.free(raw_status);

    var modified: std.ArrayList([]const u8) = .empty;
    defer {
        for (modified.items) |m| allocator.free(m);
        modified.deinit(allocator);
    }
    var untracked: std.ArrayList([]const u8) = .empty;
    defer {
        for (untracked.items) |u| allocator.free(u);
        untracked.deinit(allocator);
    }
    var deleted: std.ArrayList([]const u8) = .empty;
    defer {
        for (deleted.items) |d| allocator.free(d);
        deleted.deinit(allocator);
    }
    var staged: std.ArrayList([]const u8) = .empty;
    defer {
        for (staged.items) |s| allocator.free(s);
        staged.deinit(allocator);
    }

    var staged_seen = std.StringHashMap(void).init(allocator);
    defer staged_seen.deinit();
    var modified_seen = std.StringHashMap(void).init(allocator);
    defer modified_seen.deinit();
    var untracked_seen = std.StringHashMap(void).init(allocator);
    defer untracked_seen.deinit();
    var deleted_seen = std.StringHashMap(void).init(allocator);
    defer deleted_seen.deinit();

    if (raw_status.len > 0) {
        var lines = std.mem.splitScalar(u8, raw_status, '\n');
        while (lines.next()) |line| {
            const clean = std.mem.trim(u8, line, " \r\t");
            if (clean.len < 3) continue;

            const code_x = line[0];
            const code_y = line[1];
            var rel = std.mem.trim(u8, line[2..], " \r\t");
            if (std.mem.indexOf(u8, rel, " -> ")) |arrow| {
                rel = rel[arrow + 4 ..];
            }
            if (std.mem.startsWith(u8, rel, "\"") and std.mem.endsWith(u8, rel, "\"") and rel.len >= 2) {
                rel = rel[1 .. rel.len - 1];
            }

            const disp = if (std.mem.eql(u8, rel, ".rice.ini"))
                try allocator.dupe(u8, "~/.rice.ini")
            else
                try std.fmt.allocPrint(allocator, "~/{s}", .{rel});
            defer allocator.free(disp);

            // Staged changes: code_x is not ' ' and not '?'
            if (code_x != ' ' and code_x != '?') {
                if (!staged_seen.contains(disp)) {
                    const owned = try allocator.dupe(u8, disp);
                    try staged_seen.put(owned, {});
                    try staged.append(allocator, owned);
                }
            }

            // Unstaged modified: code_y is 'M' or 'T'
            if (code_y == 'M' or code_y == 'T') {
                if (!modified_seen.contains(disp)) {
                    const owned = try allocator.dupe(u8, disp);
                    try modified_seen.put(owned, {});
                    try modified.append(allocator, owned);
                }
            }

            // Unstaged deleted: code_y == 'D'
            if (code_y == 'D') {
                if (!deleted_seen.contains(disp)) {
                    const owned = try allocator.dupe(u8, disp);
                    try deleted_seen.put(owned, {});
                    try deleted.append(allocator, owned);
                }
            }

            // Untracked: code_x is '?' and code_y is '?'
            if (code_x == '?' and code_y == '?') {
                if (!untracked_seen.contains(disp)) {
                    const owned = try allocator.dupe(u8, disp);
                    try untracked_seen.put(owned, {});
                    try untracked.append(allocator, owned);
                }
            }
        }
    }

    if (!show_all) {
        if (staged.items.len == 0) {
            std.debug.print("  Clean\n    No staged changes detected\n", .{});
        } else {
            std.debug.print("  Staged\n", .{});
            for (staged.items) |p| std.debug.print("    {s}\n", .{p});
        }

        const unstaged_count = modified.items.len + untracked.items.len + deleted.items.len;
        if (unstaged_count > 0) {
            std.debug.print("\n  Tip: {d} unstaged change(s) present. Use 'rice status -a' to view all.\n", .{unstaged_count});
        }
        return;
    }

    const has_changes = (staged.items.len > 0 or modified.items.len > 0 or untracked.items.len > 0 or deleted.items.len > 0);

    if (!has_changes) {
        std.debug.print("  Clean\n    No changes detected\n", .{});
        return;
    }

    if (staged.items.len > 0) {
        std.debug.print("  Staged\n", .{});
        for (staged.items) |p| std.debug.print("    {s}\n", .{p});
        std.debug.print("\n", .{});
    }

    if (modified.items.len > 0) {
        std.debug.print("  Modified\n", .{});
        for (modified.items) |p| std.debug.print("    {s}\n", .{p});
        std.debug.print("\n", .{});
    }

    if (untracked.items.len > 0) {
        std.debug.print("  Untracked\n", .{});
        for (untracked.items) |p| std.debug.print("    {s}\n", .{p});
        std.debug.print("\n", .{});
    }

    if (deleted.items.len > 0) {
        std.debug.print("  Deleted\n", .{});
        for (deleted.items) |p| std.debug.print("    {s}\n", .{p});
        std.debug.print("\n", .{});
    }
}

pub fn diffCmd(allocator: Allocator, git: *git_mod.Git, homeDir: []const u8, args: []const []const u8) !void {
    var cfg = try loadConfigOrDefault(allocator, homeDir);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }

    var list: std.ArrayList([]const u8) = .empty;
    defer {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    }

    if (args.len > 0 and std.mem.trim(u8, args[0], " \t\r\n").len > 0) {
        var res = try paths.resolvePath(allocator, homeDir, args[0]);
        defer res.deinit(allocator);

        var is_tracked = std.mem.eql(u8, res.git_path, ".rice.ini") or cfg.hasFile(res.config_path);
        if (!is_tracked) {
            if (git.listTrackedFiles(&.{res.git_path})) |tf| {
                var tf_mut = tf;
                defer {
                    for (tf_mut.items) |item| allocator.free(item);
                    tf_mut.deinit(allocator);
                }
                if (tf_mut.items.len > 0) is_tracked = true;
            } else |_| {}
        }

        if (!is_tracked) {
            std.debug.print("Error: path '{s}' is not tracked by rice\n", .{res.config_path});
            return error.PathNotTracked;
        }
        try list.append(allocator, try allocator.dupe(u8, res.git_path));
    } else {
        const ini_path = try paths.getRiceIniPath(allocator, homeDir);
        defer allocator.free(ini_path);
        if (fs.isFileAbsolute(ini_path)) {
            try list.append(allocator, try allocator.dupe(u8, ".rice.ini"));
        }
        for (cfg.files.items) |f| {
            if (paths.gitPath(allocator, homeDir, f)) |gp| {
                try list.append(allocator, gp);
            } else |_| {}
        }
        if (git.listIndexFiles()) |idx_files| {
            var if_mut = idx_files;
            defer {
                for (if_mut.items) |p| allocator.free(p);
                if_mut.deinit(allocator);
            }
            for (if_mut.items) |f| {
                var already = false;
                for (list.items) |existing| {
                    if (std.mem.eql(u8, existing, f)) {
                        already = true;
                        break;
                    }
                }
                if (!already) try list.append(allocator, try allocator.dupe(u8, f));
            }
        } else |_| {}
    }

    try git.diff(list.items);
}

