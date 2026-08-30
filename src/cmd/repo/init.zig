const std = @import("std");
const Allocator = std.mem.Allocator;
const git_mod = @import("../../core/git/mod.zig");
const paths = @import("../../core/paths/mod.zig");
const config = @import("../../core/config.zig");
const fs = @import("../../core/fs.zig");

pub fn initCmd(allocator: Allocator, git: *git_mod.Git, homeDir: []const u8, args: []const []const u8) !void {
    var remote_url: ?[]const u8 = null;
    if (args.len > 0) remote_url = std.mem.trim(u8, args[0], " \t\r\n");

    try git.initBare();

    if (remote_url) |rurl| {
        if (rurl.len > 0) {
            git.setRemote(rurl) catch |err| {
                std.debug.print("Error: failed to set remote origin: {s}\n", .{@errorName(err)});
                return err;
            };
        }
    }

    const ini_path = try paths.getRiceIniPath(allocator, homeDir);
    defer allocator.free(ini_path);

    var cfg = config.loadConfig(allocator, ini_path) catch blk: {
        const new_c = try allocator.create(config.Config);
        new_c.* = config.Config.init(allocator);
        break :blk new_c;
    };
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }

    if (remote_url) |rurl| {
        if (rurl.len > 0) {
            if (cfg.remote) |r| allocator.free(r);
            cfg.remote = try paths.normalizeRepoURL(allocator, rurl);
        }
    }

    try config.saveConfig(allocator, ini_path, cfg);

    if (remote_url != null and remote_url.?.len > 0 and (git.fetch() catch null) != null and !git.hasCommits()) {
        var default_branch: ?[]const u8 = null;
        for ([_][]const u8{ "origin/main", "origin/master" }) |b| {
            if (git.output(&.{ "rev-parse", "--verify", b })) |out| {
                allocator.free(out);
                default_branch = if (std.mem.startsWith(u8, b, "origin/")) b["origin/".len..] else b;
                break;
            } else |_| {}
        }

        if (default_branch == null) {
            if (git.output(&.{ "symbolic-ref", "--short", "refs/remotes/origin/HEAD" })) |symref| {
                defer allocator.free(symref);
                if (symref.len > 0) {
                    default_branch = if (std.mem.startsWith(u8, symref, "origin/")) symref["origin/".len..] else symref;
                }
            } else |_| {
                if (git.output(&.{ "rev-parse", "--verify", "FETCH_HEAD" })) |out| {
                    allocator.free(out);
                    default_branch = "main";
                } else |_| {}
            }
        }

        if (default_branch) |db| {
            const remote_ref = try std.fmt.allocPrint(allocator, "origin/{s}", .{db});
            defer allocator.free(remote_ref);

            if (git.output(&.{ "rev-parse", "--verify", remote_ref })) |out| {
                allocator.free(out);
                const sym_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{db});
                defer allocator.free(sym_ref);
                _ = git.run(&.{ "symbolic-ref", "HEAD", sym_ref }) catch {};
                _ = git.run(&.{ "update-ref", sym_ref, remote_ref }) catch {};
                const upstream_arg = try std.fmt.allocPrint(allocator, "--set-upstream-to={s}", .{remote_ref});
                defer allocator.free(upstream_arg);
                _ = git.run(&.{ "branch", upstream_arg, db }) catch {};

                if (git.getHEADFileContent(".rice.ini")) |ini_bytes| {
                    defer allocator.free(ini_bytes);
                    if (ini_bytes.len > 0) {
                        if (fs.createFileAbsolute(ini_path, .{ .permissions = @enumFromInt(0o644) })) |f| {
                            var file = f;
                            file.writePositionalAll(paths.getProcessIo(), ini_bytes, 0) catch {};
                            file.close(paths.getProcessIo());
                        } else |_| {}
                    }
                } else |_| {
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

                if (cfg.branch) |b| allocator.free(b);
                cfg.branch = try allocator.dupe(u8, db);
                try config.saveConfig(allocator, ini_path, cfg);

                std.debug.print("Initialized bare repository in {s}\nRemote origin configured: {s}\nConnected to remote branch '{s}'\nCreated configuration in {s}\n", .{
                    git.rice_dir,
                    remote_url.?,
                    db,
                    ini_path,
                });
                return;
            } else |_| {}
        }
    }

    try git.add(&.{".rice.ini"});

    if (!git.hasCommits()) {
        _ = git.commit("Initialize rice dotfiles repository") catch {};
    }

    std.debug.print("Initialized bare repository in {s}\n", .{git.rice_dir});
    if (remote_url) |rurl| {
        if (rurl.len > 0) {
            std.debug.print("Remote origin configured: {s}\n", .{rurl});
        }
    }
    std.debug.print("Created configuration in {s}\n", .{ini_path});
}

