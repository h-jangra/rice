const std = @import("std");
const Allocator = std.mem.Allocator;
const git_mod = @import("../../core/git/mod.zig");
const paths = @import("../../core/paths/mod.zig");
const config = @import("../../core/config.zig");
const fs = @import("../../core/fs.zig");
const bin_mod = @import("../../core/bin/mod.zig");
const repo = @import("../repo/mod.zig");

pub fn restoreCmd(allocator: Allocator, git: *git_mod.Git, homeDir: []const u8, args: []const []const u8) !void {
    if (args.len > 0 and (std.mem.eql(u8, args[0], "--bins") or std.mem.eql(u8, args[0], "-b") or std.mem.eql(u8, args[0], "--bin"))) {
        const ini_path = try paths.getRiceIniPath(allocator, homeDir);
        defer allocator.free(ini_path);

        const cfg = config.loadConfig(allocator, ini_path) catch {
            std.debug.print("No binaries configured in ~/.rice.ini to restore.\n", .{});
            return;
        };
        defer {
            cfg.deinit();
            allocator.destroy(cfg);
        }

        if (cfg.binaries.count() == 0) {
            std.debug.print("No binaries configured in ~/.rice.ini to restore.\n", .{});
            return;
        }

        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(allocator);

        var it = cfg.binaries.keyIterator();
        while (it.next()) |entry| try keys.append(allocator, entry.*);

        std.mem.sort([]const u8, keys.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        var failures: usize = 0;
        for (keys.items, 0..) |name, idx| {
            const src = cfg.binaries.get(name).?;
            std.debug.print("[{d}/{d}] Restoring binary {s} ({s})...\n", .{ idx + 1, keys.items.len, name, src });

            if (bin_mod.installBinary(allocator, .{ .source = src, .name = name }, homeDir)) |inst_p| {
                defer allocator.free(inst_p);
                std.debug.print("Successfully restored '{s}' to {s}\n", .{ name, inst_p });
            } else |err| {
                std.debug.print("Error installing {s}: {s}\n", .{ name, @errorName(err) });
                failures += 1;
            }
        }

        if (failures > 0) {
            std.debug.print("{d} binary restore(s) failed.\n", .{failures});
            return error.BinaryRestoreFailed;
        }

        std.debug.print("Successfully restored {d} binary/binaries from ~/.rice.ini.\n", .{keys.items.len});
        return;
    }

    if (!git.isBareRepo()) {
        std.debug.print("Error: bare repository {s} not found or invalid.\n", .{git.rice_dir});
        return error.BareRepoInvalid;
    }

    if (!git.hasCommits()) {
        std.debug.print("Error: repository HEAD has no commits to restore from.\n", .{});
        return error.NoCommits;
    }

    const ini_path = try paths.getRiceIniPath(allocator, homeDir);
    defer allocator.free(ini_path);

    var ini_exists = false;
    if (fs.openFileAbsolute(ini_path, .{})) |f| {
        f.close(paths.getProcessIo());
        ini_exists = true;
    } else |_| {}

    if (!ini_exists) {
        if (git.getHEADFileContent(".rice.ini")) |ini_bytes| {
            defer allocator.free(ini_bytes);
            const file = try fs.createFileAbsolute(ini_path, .{ .permissions = @enumFromInt(0o644) });
            try file.writePositionalAll(paths.getProcessIo(), ini_bytes, 0);
            file.close(paths.getProcessIo());
            std.debug.print("Restored {s} from repository HEAD.\n", .{ini_path});
        } else |_| {
            std.debug.print("Error: ~/.rice.ini not found on disk or in repository HEAD.\n", .{});
            return error.FileNotFound;
        }
    }

    var cfg = try config.loadConfig(allocator, ini_path);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }

    if (cfg.files.items.len == 0) {
        std.debug.print("No managed files listed in ~/.rice.ini to restore.\n", .{});
        return;
    }

    var git_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (git_paths.items) |gp| allocator.free(gp);
        git_paths.deinit(allocator);
    }

    for (cfg.files.items) |f| {
        if (paths.gitPath(allocator, homeDir, f)) |gp| {
            try git_paths.append(allocator, gp);
        } else |_| {}
    }

    var tracked_files = try git.listTrackedFiles(git_paths.items);
    defer {
        for (tracked_files.items) |tf| allocator.free(tf);
        tracked_files.deinit(allocator);
    }

    if (tracked_files.items.len == 0) {
        std.debug.print("No matching files found in repository HEAD for managed paths.\n", .{});
        return;
    }

    var conflicts: std.ArrayList([]const u8) = .empty;
    defer {
        for (conflicts.items) |c| allocator.free(c);
        conflicts.deinit(allocator);
    }

    for (tracked_files.items) |rel_file| {
        const full_p = try std.fs.path.join(allocator, &.{ homeDir, rel_file });
        defer allocator.free(full_p);

        if (fs.openFileAbsolute(full_p, .{})) |f| {
            defer f.close(paths.getProcessIo());
            const local_bytes = std.Io.Dir.cwd().readFileAlloc(paths.getProcessIo(), full_p, allocator, .limited(50 * 1024 * 1024)) catch continue;
            defer allocator.free(local_bytes);

            if (git.getHEADFileContent(rel_file) catch null) |repo_bytes| {
                defer allocator.free(repo_bytes);
                if (!std.mem.eql(u8, local_bytes, repo_bytes)) {
                    try conflicts.append(allocator, try allocator.dupe(u8, rel_file));
                }
            }
        } else |_| {}
    }

    if (conflicts.items.len > 0) {
        std.debug.print("The following local file(s) exist and differ from the repository:\n", .{});
        for (conflicts.items) |c| std.debug.print("  {s}\n", .{c});
        if (!fs.promptConfirm("\nRestoring will overwrite these local file(s). Continue? [y/N]: ")) {
            std.debug.print("Restore cancelled.\n", .{});
            return;
        }
        for (conflicts.items) |c| {
            const full_p = try std.fs.path.join(allocator, &.{ homeDir, c });
            defer allocator.free(full_p);
            if (fs.backupFile(allocator, full_p)) |bak| {
                defer allocator.free(bak);
                std.debug.print("Backed up '{s}' to {s}\n", .{ c, std.fs.path.basename(bak) });
            } else |_| {}
        }
    }

    var checkout_args: std.ArrayList([]const u8) = .empty;
    defer checkout_args.deinit(allocator);
    try checkout_args.append(allocator, ".rice.ini");
    for (git_paths.items) |gp| try checkout_args.append(allocator, gp);

    try git.checkoutHEAD(checkout_args.items);

    std.debug.print("Successfully restored {d} managed path(s) from repository.\n", .{cfg.files.items.len});
}

pub fn discardCmd(allocator: Allocator, git: *git_mod.Git, homeDir: []const u8, args: []const []const u8) !void {
    if (!git.isBareRepo()) {
        std.debug.print("Error: bare repository {s} not found or invalid.\n", .{git.rice_dir});
        return error.BareRepoInvalid;
    }

    if (!git.hasCommits()) {
        std.debug.print("Error: repository HEAD has no commits to discard changes from.\n", .{});
        return error.NoCommits;
    }

    var cfg = try repo.loadConfigOrExit(allocator, homeDir);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }

    var force = false;
    var path_args: std.ArrayList([]const u8) = .empty;
    defer path_args.deinit(allocator);

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else {
            try path_args.append(allocator, arg);
        }
    }

    var target_git_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (target_git_paths.items) |gp| allocator.free(gp);
        target_git_paths.deinit(allocator);
    }

    if (path_args.items.len == 0) {
        try target_git_paths.append(allocator, try allocator.dupe(u8, ".rice.ini"));
        for (cfg.files.items) |f| {
            if (paths.gitPath(allocator, homeDir, f)) |gp| {
                try target_git_paths.append(allocator, gp);
            } else |_| {}
        }
    } else {
        for (path_args.items) |arg| {
            if (std.mem.eql(u8, arg, ".rice.ini")) {
                try target_git_paths.append(allocator, try allocator.dupe(u8, ".rice.ini"));
                continue;
            }

            var res = try paths.resolvePath(allocator, homeDir, arg);
            defer res.deinit(allocator);

            var is_managed = cfg.hasFile(res.config_path);
            if (!is_managed) {
                for (cfg.files.items) |managed| {
                    if (std.mem.startsWith(u8, res.config_path, managed) and res.config_path.len > managed.len and res.config_path[managed.len] == '/') {
                        is_managed = true;
                        break;
                    }
                }
            }

            if (!is_managed) {
                if (git.listTrackedFiles(&.{res.git_path})) |tf| {
                    var tf_mut = tf;
                    defer {
                        for (tf_mut.items) |item| allocator.free(item);
                        tf_mut.deinit(allocator);
                    }
                    if (tf_mut.items.len > 0) is_managed = true;
                } else |_| {}
            }

            if (!is_managed) {
                std.debug.print("Error: path '{s}' is not tracked by rice\n", .{res.config_path});
                return error.PathNotTracked;
            }

            try target_git_paths.append(allocator, try allocator.dupe(u8, res.git_path));
        }
    }

    var modified_git_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (modified_git_paths.items) |gp| allocator.free(gp);
        modified_git_paths.deinit(allocator);
    }
    var modified_display_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (modified_display_paths.items) |dp| allocator.free(dp);
        modified_display_paths.deinit(allocator);
    }

    for (target_git_paths.items) |gp| {
        if (git.output(&.{ "diff", "HEAD", "--", gp })) |diff_out| {
            defer allocator.free(diff_out);
            if (diff_out.len > 0) {
                try modified_git_paths.append(allocator, try allocator.dupe(u8, gp));
                if (std.mem.eql(u8, gp, ".rice.ini")) {
                    try modified_display_paths.append(allocator, try allocator.dupe(u8, "~/.rice.ini"));
                } else {
                    try modified_display_paths.append(allocator, try std.fmt.allocPrint(allocator, "~/{s}", .{gp}));
                }
            }
        } else |_| {}
    }

    if (modified_git_paths.items.len == 0) {
        std.debug.print("No local changes to discard.\n", .{});
        return;
    }

    var unique_git_paths: std.ArrayList([]const u8) = .empty;
    defer unique_git_paths.deinit(allocator);
    var unique_display_paths: std.ArrayList([]const u8) = .empty;
    defer unique_display_paths.deinit(allocator);

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (modified_git_paths.items, 0..) |gp, idx| {
        if (!seen.contains(gp)) {
            try seen.put(gp, {});
            try unique_git_paths.append(allocator, gp);
            try unique_display_paths.append(allocator, modified_display_paths.items[idx]);
        }
    }

    if (!force) {
        std.debug.print("The following local file(s) have uncommitted changes that will be discarded:\n", .{});
        for (unique_display_paths.items) |dp| {
            std.debug.print("  {s}\n", .{dp});
        }
        if (!fs.promptConfirm("\nDiscard local changes? [y/N]: ")) {
            std.debug.print("Discard cancelled.\n", .{});
            return;
        }
    }

    try git.checkoutHEAD(unique_git_paths.items);
    std.debug.print("Successfully discarded local changes in {d} path(s).\n", .{unique_git_paths.items.len});
}

