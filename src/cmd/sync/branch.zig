const std = @import("std");
const Allocator = std.mem.Allocator;
const git_mod = @import("../../core/git/mod.zig");
const paths = @import("../../core/paths/mod.zig");
const config = @import("../../core/config.zig");
const fs = @import("../../core/fs.zig");

pub fn switchCmd(allocator: Allocator, git: *git_mod.Git, homeDir: []const u8, args: []const []const u8) !void {
    if (!git.isBareRepo()) {
        std.debug.print("Error: bare repository {s} not found or invalid.\n", .{git.rice_dir});
        return error.BareRepoInvalid;
    }

    if (args.len == 0) {
        std.debug.print("Error: branch name required.\nUsage: rice switch [-c|--create] [-f|--force] [-m|--merge] <branch>\n", .{});
        return error.BranchNameRequired;
    }

    var create_new = false;
    var force = false;
    var merge = false;
    var branch_name: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.trim(u8, args[i], " \t\r\n");
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--create") or std.mem.eql(u8, arg, "-b")) {
            create_new = true;
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                branch_name = std.mem.trim(u8, args[i + 1], " \t\r\n");
                i += 1;
            }
        } else if (std.mem.startsWith(u8, arg, "-c=")) {
            branch_name = std.mem.trim(u8, arg["-c=".len..], " \t\r\n");
            create_new = true;
        } else if (std.mem.startsWith(u8, arg, "--create=")) {
            branch_name = std.mem.trim(u8, arg["--create=".len..], " \t\r\n");
            create_new = true;
        } else if (std.mem.startsWith(u8, arg, "-b=")) {
            branch_name = std.mem.trim(u8, arg["-b=".len..], " \t\r\n");
            create_new = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--merge")) {
            merge = true;
        } else if (!std.mem.startsWith(u8, arg, "-") and branch_name == null) {
            branch_name = arg;
        }
    }

    if (branch_name == null or branch_name.?.len == 0) {
        std.debug.print("Error: branch name required.\nUsage: rice switch [-c|--create] [-f|--force] [-m|--merge] <branch>\n", .{});
        return error.BranchNameRequired;
    }

    const cur_branch = git.getCurrentBranch() catch "";
    defer allocator.free(cur_branch);

    if (!create_new and std.mem.eql(u8, cur_branch, branch_name.?) and !force and !merge) {
        std.debug.print("Already on branch '{s}'\n", .{branch_name.?});
        return;
    }

    try git.switchBranch(branch_name.?, create_new, force, merge);

    if (create_new) {
        std.debug.print("Switched to a new branch '{s}'\n", .{branch_name.?});
    } else {
        std.debug.print("Switched to branch '{s}'\n", .{branch_name.?});
    }

    const ini_path = try paths.getRiceIniPath(allocator, homeDir);
    defer allocator.free(ini_path);

    var existing_remote: ?[]const u8 = null;
    if (config.loadConfig(allocator, ini_path)) |old_cfg| {
        if (old_cfg.remote) |r| existing_remote = try allocator.dupe(u8, r);
        old_cfg.deinit();
        allocator.destroy(old_cfg);
    } else |_| {
        if (git.getRemote()) |r| existing_remote = r else |_| {}
    }
    defer if (existing_remote) |r| allocator.free(r);

    var cfg: *config.Config = undefined;
    if (git.getHEADFileContent(".rice.ini")) |ini_bytes| {
        defer allocator.free(ini_bytes);
        if (ini_bytes.len > 0) {
            if (fs.createFileAbsolute(ini_path, .{ .permissions = @enumFromInt(0o644) })) |f| {
                var file = f;
                file.writePositionalAll(paths.getProcessIo(), ini_bytes, 0) catch {};
                file.close(paths.getProcessIo());
            } else |_| {}
            cfg = config.loadConfig(allocator, ini_path) catch blk: {
                const new_c = try allocator.create(config.Config);
                new_c.* = config.Config.init(allocator);
                break :blk new_c;
            };
        } else {
            cfg = try allocator.create(config.Config);
            cfg.* = config.Config.init(allocator);
        }
    } else |_| {
        cfg = try allocator.create(config.Config);
        cfg.* = config.Config.init(allocator);

        if (git.listRefFiles("HEAD", &.{})) |head_files| {
            var hf_mut = head_files;
            defer {
                for (hf_mut.items) |hf| allocator.free(hf);
                hf_mut.deinit(allocator);
            }
            for (hf_mut.items) |hf| {
                if (std.mem.eql(u8, hf, ".rice.ini")) continue;
                const conf_p = try std.fmt.allocPrint(allocator, "~/{s}", .{hf});
                defer allocator.free(conf_p);
                _ = cfg.addFile(conf_p) catch {};
            }
        } else |_| {}
    }
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }

    if (cfg.remote == null and existing_remote != null) {
        cfg.remote = try allocator.dupe(u8, existing_remote.?);
    }

    if (cfg.branch) |b| allocator.free(b);
    cfg.branch = try allocator.dupe(u8, branch_name.?);

    try config.saveConfig(allocator, ini_path, cfg);
}

pub fn branchesCmd(allocator: Allocator, git: *git_mod.Git, args: []const []const u8) !void {
    if (!git.isBareRepo()) {
        std.debug.print("Error: bare repository {s} not found or invalid.\n", .{git.rice_dir});
        return error.BareRepoInvalid;
    }

    const out = try git.branchList(args);
    defer allocator.free(out);

    if (out.len == 0) {
        std.debug.print("No branches found.\n", .{});
        return;
    }

    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        const clean = std.mem.trimEnd(u8, line, "\r");
        if (std.mem.trim(u8, clean, " \t").len > 0) std.debug.print("{s}\n", .{clean});
    }
}

