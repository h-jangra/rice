const std = @import("std");
const Allocator = std.mem.Allocator;
const git_mod = @import("../../core/git/mod.zig");
const paths = @import("../../core/paths/mod.zig");
const config = @import("../../core/config.zig");
const fs = @import("../../core/fs.zig");

pub fn editCmd(allocator: Allocator, homeDir: []const u8, args: []const []const u8) !void {
    if (args.len > 0) {
        std.debug.print("Error: rice edit does not accept arguments.\nUsage: rice edit\n", .{});
        return error.InvalidArgs;
    }

    const ini_path = try paths.getRiceIniPath(allocator, homeDir);
    defer allocator.free(ini_path);

    var exists = false;
    if (fs.openFileAbsolute(ini_path, .{})) |f| {
        f.close(paths.getProcessIo());
        exists = true;
    } else |_| {}

    if (!exists) {
        std.debug.print("Error: ~/.rice.ini not found. Run 'rice init <remote>' first.\n", .{});
        return error.FileNotFound;
    }

    var editor_str: []const u8 = "vi";
    var allocated_ed: ?[]u8 = null;
    defer if (allocated_ed) |ed| allocator.free(ed);

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

    var it = std.mem.splitScalar(u8, editor_str, ' ');
    var cmd_list: std.ArrayList([]const u8) = .empty;
    defer cmd_list.deinit(allocator);

    while (it.next()) |part| {
        if (part.len > 0) try cmd_list.append(allocator, part);
    }
    if (cmd_list.items.len == 0) {
        try cmd_list.append(allocator, "vi");
    }
    try cmd_list.append(allocator, ini_path);

    var env_map = try std.process.Environ.createMap(env, allocator);
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

pub fn doctorCmd(allocator: Allocator, git: *git_mod.Git, homeDir: []const u8) !void {
    std.debug.print("Rice Doctor\n===========\n", .{});
    var issues: usize = 0;

    if (git_mod.verifyGitInstalled(allocator)) |gp| {
        defer allocator.free(gp);
        std.debug.print("[✓] Git executable found ({s})\n", .{gp});
    } else |_| {
        std.debug.print("[✗] Git executable not found in PATH\n", .{});
        issues += 1;
    }

    var bare_exists = false;
    if (fs.openDirAbsolute(git.rice_dir, .{})) |d| {
        var dir = d;
        dir.close(paths.getProcessIo());
        bare_exists = true;
    } else |_| {}

    if (!bare_exists) {
        std.debug.print("[✗] Bare repository directory (~/.rice) does not exist\n", .{});
        issues += 1;
    } else if (!git.isBareRepo()) {
        std.debug.print("[✗] Directory {s} is not a valid bare Git repository\n", .{git.rice_dir});
        issues += 1;
    } else {
        std.debug.print("[✓] Bare repository is valid ({s})\n", .{git.rice_dir});
    }

    const ini_path = try paths.getRiceIniPath(allocator, homeDir);
    defer allocator.free(ini_path);

    var cfg_opt: ?*config.Config = null;
    if (config.loadConfig(allocator, ini_path)) |c| {
        cfg_opt = c;
        std.debug.print("[✓] Configuration file exists and is valid ({s})\n", .{ini_path});
    } else |err| {
        if (err == error.FileNotFound) {
            std.debug.print("[✗] Configuration file (~/.rice.ini) does not exist\n", .{});
        } else {
            std.debug.print("[✗] Configuration file (~/.rice.ini) has invalid format: {s}\n", .{@errorName(err)});
        }
        issues += 1;
    }
    defer {
        if (cfg_opt) |c| {
            c.deinit();
            allocator.destroy(c);
        }
    }

    if (git.isBareRepo()) {
        if (git.getRemote()) |rurl| {
            defer allocator.free(rurl);
            if (rurl.len > 0) {
                std.debug.print("[✓] Git remote 'origin' is configured ({s})\n", .{rurl});
                if (cfg_opt) |cfg| {
                    if (cfg.remote) |cr| {
                        if (!std.mem.eql(u8, cr, rurl)) {
                            std.debug.print("[✗] Remote in .rice.ini ({s}) differs from Git origin ({s})\n", .{ cr, rurl });
                            issues += 1;
                        }
                    }
                }
            } else {
                std.debug.print("[✗] Git remote 'origin' is not configured\n", .{});
                issues += 1;
            }
        } else |_| {
            std.debug.print("[✗] Git remote 'origin' is not configured\n", .{});
            issues += 1;
        }
    }

    if (cfg_opt) |cfg| {
        var invalid_paths: usize = 0;
        var sensitive_paths: usize = 0;
        for (cfg.files.items) |f| {
            if (paths.validateManagedPath(allocator, homeDir, f)) {} else |_| {
                std.debug.print("[✗] Invalid managed path '{s}'\n", .{f});
                invalid_paths += 1;
                issues += 1;
            }
            if (paths.detectSensitiveFile(f)) |warn| {
                std.debug.print("[!] Sensitive file tracked '{s}': {s}\n", .{ f, warn });
                sensitive_paths += 1;
            }
        }
        if (invalid_paths == 0) {
            std.debug.print("[✓] All {d} managed path(s) in [files] are valid and within $HOME\n", .{cfg.files.items.len});
        }
        if (sensitive_paths > 0) {
            std.debug.print("    Tip: Verify sensitive files do not contain private credentials before pushing.\n", .{});
        }
    }

    std.debug.print("-----------\n", .{});
    if (issues == 0) {
        std.debug.print("Everything looks healthy!\n", .{});
    } else {
        std.debug.print("Doctor found {d} issue(s).\n", .{issues});
        return error.DoctorFoundIssues;
    }
}

