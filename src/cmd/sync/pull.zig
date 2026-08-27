const std = @import("std");
const Allocator = std.mem.Allocator;
const git_mod = @import("../../core/git/mod.zig");
const paths = @import("../../core/paths/mod.zig");
const config = @import("../../core/config.zig");
const fs = @import("../../core/fs.zig");

pub fn pullCmd(allocator: Allocator, git: *git_mod.Git, homeDir: []const u8, args: []const []const u8) !void {
    if (!git.isBareRepo()) {
        std.debug.print("Error: bare repository {s} not found or invalid.\n", .{git.rice_dir});
        return error.BareRepoInvalid;
    }

    var force = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "--force")) {
            force = true;
            break;
        }
    }

    git.fetch() catch |err| {
        std.debug.print("Error: failed to fetch from origin: {s}\n", .{@errorName(err)});
        return err;
    };

    const remote_head = git.output(&[_][]const u8{ "rev-parse", "FETCH_HEAD" }) catch {
        std.debug.print("Error: failed to resolve remote changes from FETCH_HEAD.\n", .{});
        return error.FetchHeadNotFound;
    };
    defer allocator.free(remote_head);

    const ini_path = try paths.getRiceIniPath(allocator, homeDir);
    defer allocator.free(ini_path);

    if (git.hasCommits()) {
        const local_head = git.output(&[_][]const u8{ "rev-parse", "HEAD" }) catch "";
        defer allocator.free(local_head);

        if (std.mem.eql(u8, local_head, remote_head)) {
            std.debug.print("Already up to date.\n", .{});
            return;
        }

        const diff_raw = git.output(&[_][]const u8{ "diff", "--name-only", "HEAD", "FETCH_HEAD" }) catch "";
        defer allocator.free(diff_raw);

        var conflicts = std.ArrayList([]const u8).init(allocator);
        defer {
            for (conflicts.items) |c| allocator.free(c);
            conflicts.deinit();
        }

        var ini_has_local_mods = false;

        if (diff_raw.len > 0) {
            var lines = std.mem.splitScalar(u8, diff_raw, '\n');
            while (lines.next()) |line| {
                const rel_file = std.mem.trim(u8, line, " \t\r");
                if (rel_file.len == 0) continue;

                const full_p = try std.fs.path.join(allocator, &[_][]const u8{ homeDir, rel_file });
                defer allocator.free(full_p);

                if (std.fs.openFileAbsolute(full_p, .{})) |f| {
                    defer f.close();
                    const local_bytes = f.readToEndAlloc(allocator, 50 * 1024 * 1024) catch continue;
                    defer allocator.free(local_bytes);

                    if (git.getHEADFileContent(rel_file)) |head_bytes| {
                        defer allocator.free(head_bytes);
                        if (!std.mem.eql(u8, local_bytes, head_bytes)) {
                            if (std.mem.eql(u8, rel_file, ".rice.ini")) {
                                ini_has_local_mods = true;
                            } else {
                                try conflicts.append(try allocator.dupe(u8, rel_file));
                            }
                        }
                    } else |_| {
                        if (std.mem.eql(u8, rel_file, ".rice.ini")) {
                            ini_has_local_mods = true;
                        } else {
                            try conflicts.append(try allocator.dupe(u8, rel_file));
                        }
                    }
                } else |_| {}
            }
        }

        if (conflicts.items.len > 0 and !force) {
            std.debug.print("Error: incoming remote changes conflict with local uncommitted modifications in:\n", .{});
            for (conflicts.items) |c| {
                std.debug.print("  {s}\n", .{c});
            }
            std.debug.print("\nPull aborted to prevent overwriting your local files.\nOptions:\n  - Commit your local changes: rice commit <message>\n  - Review changes:            rice diff\n  - Discard local changes:     rice restore\n  - Force pull (overwrite):    rice pull -f\n", .{});
            return error.PullConflict;
        }

        if (force) {
            for (conflicts.items) |c| {
                const full_p = try std.fs.path.join(allocator, &[_][]const u8{ homeDir, c });
                defer allocator.free(full_p);
                if (fs.backupFile(allocator, full_p)) |bak| {
                    defer allocator.free(bak);
                    std.debug.print("Backed up '{s}' to {s}\n", .{ c, std.fs.path.basename(bak) });
                } else |_| {}
                _ = git.checkoutHEAD(&[_][]const u8{c}) catch {};
            }
        }

        var local_cfg: ?*config.Config = null;
        if (ini_has_local_mods) {
            local_cfg = config.loadConfig(allocator, ini_path) catch null;
            _ = git.checkoutHEAD(&[_][]const u8{".rice.ini"}) catch {};
        }
        defer if (local_cfg) |lc| {
            lc.deinit();
            allocator.destroy(lc);
        };

        if (git.merge("FETCH_HEAD")) {} else |err| {
            if (force) {
                _ = git.run(&[_][]const u8{ "reset", "--hard", "FETCH_HEAD" }) catch |r_err| {
                    std.debug.print("Error: failed to force merge remote changes: {s}\n", .{@errorName(r_err)});
                    return r_err;
                };
            } else {
                std.debug.print("Error: failed to merge remote changes: {s}\n", .{@errorName(err)});
                return err;
            }
        }

        if (git.getHEADFileContent(".rice.ini")) |ini_bytes| {
            defer allocator.free(ini_bytes);
            if (ini_bytes.len > 0) {
                const file = std.fs.createFileAbsolute(ini_path, .{ .mode = 0o644 }) catch null;
                if (file) |f| {
                    f.writeAll(ini_bytes) catch {};
                    f.close();
                }
            }
        } else |_| {}
    } else {
        var incoming_files = git.listRefFiles("FETCH_HEAD", &[_][]const u8{}) catch std.ArrayList([]u8).init(allocator);
        defer {
            for (incoming_files.items) |f| allocator.free(f);
            incoming_files.deinit();
        }

        var conflicts = std.ArrayList([]const u8).init(allocator);
        defer {
            for (conflicts.items) |c| allocator.free(c);
            conflicts.deinit();
        }

        for (incoming_files.items) |rel_file| {
            if (std.mem.eql(u8, rel_file, ".rice.ini")) continue;
            const full_p = try std.fs.path.join(allocator, &[_][]const u8{ homeDir, rel_file });
            defer allocator.free(full_p);

            if (std.fs.openFileAbsolute(full_p, .{})) |f| {
                defer f.close();
                const local_bytes = f.readToEndAlloc(allocator, 50 * 1024 * 1024) catch continue;
                defer allocator.free(local_bytes);

                if (git.getRefFileContent("FETCH_HEAD", rel_file)) |remote_bytes| {
                    defer allocator.free(remote_bytes);
                    if (!std.mem.eql(u8, local_bytes, remote_bytes)) {
                        try conflicts.append(try allocator.dupe(u8, rel_file));
                    }
                } else |_| {}
            } else |_| {}
        }

        if (conflicts.items.len > 0 and !force) {
            std.debug.print("Error: incoming remote changes conflict with local uncommitted modifications in:\n", .{});
            for (conflicts.items) |c| {
                std.debug.print("  {s}\n", .{c});
            }
            std.debug.print("\nPull aborted to prevent overwriting your local files.\nOptions:\n  - Review changes:            rice diff\n  - Discard local changes:     rice restore\n  - Force pull (overwrite):    rice pull -f\n", .{});
            return error.PullConflict;
        }

        if (force) {
            for (conflicts.items) |c| {
                const full_p = try std.fs.path.join(allocator, &[_][]const u8{ homeDir, c });
                defer allocator.free(full_p);
                if (fs.backupFile(allocator, full_p)) |bak| {
                    defer allocator.free(bak);
                    std.debug.print("Backed up '{s}' to {s}\n", .{ c, std.fs.path.basename(bak) });
                } else |_| {}
            }
        }

        var branch = git.getCurrentBranch() catch try allocator.dupe(u8, "main");
        defer allocator.free(branch);
        if (branch.len == 0 or std.mem.eql(u8, branch, "HEAD")) {
            allocator.free(branch);
            branch = try allocator.dupe(u8, "main");
        }

        const symref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch});
        defer allocator.free(symref);
        _ = git.run(&[_][]const u8{ "symbolic-ref", "HEAD", symref }) catch {};
        _ = git.run(&[_][]const u8{ "update-ref", symref, "FETCH_HEAD" }) catch {};
        const upstream_arg = try std.fmt.allocPrint(allocator, "--set-upstream-to=origin/{s}", .{branch});
        defer allocator.free(upstream_arg);
        _ = git.run(&[_][]const u8{ "branch", upstream_arg, branch }) catch {};

        if (git.getHEADFileContent(".rice.ini")) |ini_bytes| {
            defer allocator.free(ini_bytes);
            if (ini_bytes.len > 0) {
                const file = std.fs.createFileAbsolute(ini_path, .{ .mode = 0o644 }) catch null;
                if (file) |f| {
                    f.writeAll(ini_bytes) catch {};
                    f.close();
                }
            }
        } else |_| {}
    }

    std.debug.print("Successfully pulled and updated dotfiles from origin.\n", .{});
}
