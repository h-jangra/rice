const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const paths = @import("../paths/mod.zig");
const config = @import("../config.zig");
const git_mod = @import("../git/mod.zig");
const fs = @import("../fs.zig");
const discovery = @import("discovery.zig");
const url = @import("url.zig");

pub fn defaultBranch() []const u8 {
    if (builtin.os.tag == .windows) return "windows";
    return "main";
}

pub fn printInstallUsage() void {
    const stderr = std.io.getStdErr().writer();
    stderr.writeAll(
        \\Usage:
        \\  rice install <name> [--repo <url>] [-b|--branch <branch>] [--contents|-C]
        \\  rice install <source> <destination> [--repo <url>] [-b|--branch <branch>] [--contents|-C]
        \\  rice install <github-url> <destination> [--contents|-C]
        \\  rice install --bin <source> [--tag <tag>] [--name <name>] [--save]
        \\
        \\Examples:
        \\  rice install nvim
        \\  rice install nvim -b main
        \\  rice install --bin sharkdp/bat
        \\  rice install --bin junegunn/fzf --save
        \\  rice install tmux --repo https://github.com/user/dotfiles
        \\  rice install config/tmux ~/.config/tmux --repo https://github.com/webpro/dotfiles
        \\  rice install .zshrc ~/.zshrc --repo https://github.com/user/dotfiles
        \\  rice install https://github.com/user/repo/blob/main/path/file.txt ~/Downloads
        \\  rice install https://github.com/user/repo/releases/download/v1.0/font.zip ~/.local/share/fonts
        \\  rice install https://github.com/dharmx/walls/tree/main/wave ~/Downloads
        \\  rice install --contents https://github.com/dharmx/walls/tree/main/wave ~/Downloads
        \\
    ) catch {};
}

pub fn printInstallHelp() void {
    const stdout = std.io.getStdOut().writer();
    stdout.writeAll(
        \\Usage:
        \\  rice install <name> [--repo <url>] [-b|--branch <branch>] [--contents|-C]
        \\  rice install <source> <destination> [--repo <url>] [-b|--branch <branch>] [--contents|-C]
        \\  rice install <github-url> <destination> [--contents|-C]
        \\  rice install --bin <source> [--tag <tag>] [--name <name>] [--save]
        \\
        \\Aliases:
        \\  rice i
        \\
        \\Options:
        \\  --bin, --bins       Install executable binary to ~/.local/bin
        \\  --repo <url>        Remote repository URL (defaults to ~/.rice.ini repo)
        \\  -b, --branch <name> Branch name (default: main on unix, windows on windows)
        \\  --contents, -C      Extract directory contents directly into destination
        \\
        \\Examples:
        \\  rice install nvim
        \\  rice install nvim -b main
        \\  rice install --bin sharkdp/bat
        \\  rice install -b junegunn/fzf --save
        \\  rice install tmux --repo https://github.com/user/dotfiles
        \\  rice install config/tmux ~/.config/tmux --repo https://github.com/webpro/dotfiles
        \\  rice install .zshrc ~/.zshrc --repo https://github.com/user/dotfiles
        \\  rice install https://github.com/user/repo/blob/main/path/file.txt ~/Downloads
        \\  rice install https://github.com/user/repo/releases/download/v1.0/font.zip ~/.local/share/fonts
        \\  rice install https://github.com/dharmx/walls/tree/main/wave ~/Downloads
        \\  rice install --contents https://github.com/dharmx/walls/tree/main/wave ~/Downloads
        \\
    ) catch {};
}

fn confirmPrompt(prompt: []const u8) bool {
    std.debug.print("{s}", .{prompt});
    const stdin = std.io.getStdIn().reader();
    var buf: [128]u8 = undefined;
    if (stdin.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        if (line) |l| {
            const trimmed = std.mem.trim(u8, l, " \t\r\n");
            return std.ascii.eqlIgnoreCase(trimmed, "y") or std.ascii.eqlIgnoreCase(trimmed, "yes");
        }
    } else |_| {}
    return false;
}

pub fn installDotfiles(allocator: Allocator, git: *git_mod.Git, homeDir: []const u8, args: []const []const u8) !void {
    var repo_flag: ?[]const u8 = null;
    var branch_flag: ?[]const u8 = null;
    var contents_flag = false;
    var positional = std.ArrayList([]const u8).init(allocator);
    defer positional.deinit();

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--repo")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --repo requires a URL argument.\n", .{});
                return error.InvalidArgs;
            }
            repo_flag = std.mem.trim(u8, args[i + 1], " \t\r\n");
            i += 1;
        } else if (std.mem.startsWith(u8, arg, "--repo=")) {
            repo_flag = std.mem.trim(u8, arg["--repo=".len..], " \t\r\n");
        } else if (std.mem.eql(u8, arg, "--branch") or std.mem.eql(u8, arg, "-b")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: -b/--branch requires a branch name argument.\n", .{});
                return error.InvalidArgs;
            }
            branch_flag = std.mem.trim(u8, args[i + 1], " \t\r\n");
            i += 1;
        } else if (std.mem.startsWith(u8, arg, "--branch=")) {
            branch_flag = std.mem.trim(u8, arg["--branch=".len..], " \t\r\n");
        } else if (std.mem.startsWith(u8, arg, "-b=")) {
            branch_flag = std.mem.trim(u8, arg["-b=".len..], " \t\r\n");
        } else if (std.mem.eql(u8, arg, "--contents") or std.mem.eql(u8, arg, "-C")) {
            contents_flag = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printInstallHelp();
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Error: unknown flag \"{s}\"\n\n", .{arg});
            printInstallUsage();
            return error.UnknownFlag;
        } else {
            try positional.append(arg);
        }
    }

    if (positional.items.len == 0) {
        std.debug.print("Error: target name or source and destination required.\n", .{});
        printInstallUsage();
        return error.InvalidArgs;
    }

    if (positional.items.len > 2) {
        std.debug.print("Error: too many arguments provided\n\n", .{});
        printInstallUsage();
        return error.TooManyArgs;
    }

    var target_repo_path: []u8 = undefined;
    var target_config_path: []u8 = undefined;
    var dest_path: []u8 = undefined;
    var repo_url: ?[]u8 = null;
    defer if (repo_url) |r| allocator.free(r);
    var branch_url: ?[]u8 = null;
    defer if (branch_url) |b| allocator.free(b);
    var is_outside_home = false;

    if (positional.items.len == 2) {
        const raw_src = positional.items[0];
        const raw_dst = positional.items[1];

        if (paths.isURL(raw_src)) {
            if (paths.parseGitHubURL(allocator, raw_src)) |gh_info| {
                defer {
                    gh_info.deinit(allocator);
                    allocator.destroy(gh_info);
                }

                if (contents_flag and gh_info.isFile()) {
                    std.debug.print("Error: --contents can only be used with directory sources.\n", .{});
                    return error.ContentsOnlyWithDirs;
                }

                const item_name = if (!contents_flag) gh_info.file_name else "";
                const dest_res = try paths.resolveInstallDestination(allocator, homeDir, raw_dst, item_name, contents_flag);

                target_repo_path = try allocator.dupe(u8, gh_info.path);
                target_config_path = dest_res.config_path;
                dest_path = dest_res.abs_path;
                is_outside_home = dest_res.is_outside_home;
                repo_url = try allocator.dupe(u8, gh_info.repo_url);
                branch_url = try allocator.dupe(u8, gh_info.branch);
            } else |_| {
                return url.runDirectURLInstall(allocator, homeDir, raw_src, raw_dst, contents_flag);
            }
        } else {
            const clean_src = try paths.validateSourcePath(allocator, raw_src);
            defer allocator.free(clean_src);

            const item_name = if (!contents_flag) std.fs.path.basename(clean_src) else "";
            const dest_res = try paths.resolveInstallDestination(allocator, homeDir, raw_dst, item_name, contents_flag);

            target_repo_path = try allocator.dupe(u8, clean_src);
            target_config_path = dest_res.config_path;
            dest_path = dest_res.abs_path;
            is_outside_home = dest_res.is_outside_home;
        }
    } else {
        const raw_src = positional.items[0];
        if (paths.isURL(raw_src)) {
            return url.runDirectURLInstall(allocator, homeDir, raw_src, ".", contents_flag);
        }
    }

    var branch_allocated: ?[]u8 = null;
    defer if (branch_allocated) |b| allocator.free(b);

    var branch: []const u8 = "";
    if (branch_flag) |bf| {
        branch = bf;
    } else if (branch_url) |bu| {
        branch = bu;
    }

    if (repo_flag) |rf| {
        if (repo_url) |r| allocator.free(r);
        repo_url = try paths.normalizeRepoURL(allocator, rf);
    }
    if (repo_url == null or branch.len == 0) {
        const ini_path = try paths.getRiceIniPath(allocator, homeDir);
        defer allocator.free(ini_path);
        if (config.loadConfig(allocator, ini_path)) |cfg| {
            defer {
                cfg.deinit();
                allocator.destroy(cfg);
            }
            if (repo_url == null and cfg.remote != null) {
                repo_url = try paths.normalizeRepoURL(allocator, cfg.remote.?);
            }
            if (branch.len == 0 and cfg.branch != null and cfg.branch.?.len > 0) {
                branch_allocated = try allocator.dupe(u8, cfg.branch.?);
                branch = branch_allocated.?;
            }
        } else |_| {}
    }

    if (git.isBareRepo()) {
        if (repo_url == null) {
            if (git.getRemote()) |r| {
                repo_url = try paths.normalizeRepoURL(allocator, r);
            } else |_| {}
        }
        if (branch.len == 0) {
            if (git.getCurrentBranch()) |cur_b| {
                branch_allocated = cur_b;
                branch = cur_b;
            } else |_| {}
        }
    }

    if (branch.len == 0) {
        branch = defaultBranch();
    }

    if (repo_url == null or repo_url.?.len == 0) {
        if (positional.items.len == 2) {
            std.debug.print("Error: no repository configured. Use:\n  rice install <source> <destination> --repo <repository>\n", .{});
        } else {
            std.debug.print("Error: no repository configured. Use:\n  rice install <name> --repo <repository>\n", .{});
        }
        return error.NoRepoConfigured;
    }

    if (is_outside_home) {
        const p_prompt = try std.fmt.allocPrint(allocator, "Destination '{s}' is outside home directory ({s}).\nProceed? [y/N]: ", .{ dest_path, homeDir });
        defer allocator.free(p_prompt);
        if (!confirmPrompt(p_prompt)) {
            std.debug.print("Installation cancelled.\n", .{});
            return;
        }
    }

    const tmp_dir_path = try std.fmt.allocPrint(allocator, "/tmp/rice-install-{d}", .{std.time.milliTimestamp()});
    defer allocator.free(tmp_dir_path);
    try std.fs.cwd().makePath(tmp_dir_path);
    defer std.fs.deleteTreeAbsolute(tmp_dir_path) catch {};

    _ = try discovery.runGitInDir(allocator, tmp_dir_path, &[_][]const u8{"init"});
    _ = try discovery.runGitInDir(allocator, tmp_dir_path, &[_][]const u8{ "remote", "add", "origin", repo_url.? });

    if (discovery.runGitInDir(allocator, tmp_dir_path, &[_][]const u8{ "fetch", "--filter=blob:none", "--depth=1", "origin", branch })) |f_out| {
        allocator.free(f_out);
    } else |_| {
        _ = try discovery.runGitInDir(allocator, tmp_dir_path, &[_][]const u8{ "fetch", "--depth=1", "origin", branch });
    }

    if (positional.items.len == 1) {
        const name = positional.items[0];
        const resolved = try discovery.resolveRemoteConfig(allocator, tmp_dir_path, branch, name);
        target_repo_path = resolved.repo_path;
        target_config_path = resolved.dest_config_path;

        var dest_rel = target_config_path;
        if (std.mem.startsWith(u8, dest_rel, "~/")) dest_rel = dest_rel[2..];
        dest_path = try std.fs.path.join(allocator, &[_][]const u8{ homeDir, dest_rel });
    }

    _ = try discovery.runGitInDir(allocator, tmp_dir_path, &[_][]const u8{ "sparse-checkout", "init", "--no-cone" });
    _ = try discovery.runGitInDir(allocator, tmp_dir_path, &[_][]const u8{ "sparse-checkout", "set", "--no-cone", target_repo_path });
    _ = try discovery.runGitInDir(allocator, tmp_dir_path, &[_][]const u8{ "checkout", "--detach", "FETCH_HEAD" });

    const downloaded_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp_dir_path, target_repo_path });
    defer allocator.free(downloaded_path);

    var is_dir = false;
    if (std.fs.openDirAbsolute(downloaded_path, .{})) |d| {
        var dir = d;
        dir.close();
        is_dir = true;
    } else |_| {}

    if (contents_flag and !is_dir) {
        std.debug.print("Error: --contents can only be used with directory sources.\n", .{});
        return error.ContentsOnlyWithDirs;
    }

    var has_conflict = false;
    if (std.fs.openFileAbsolute(dest_path, .{})) |f| {
        f.close();
        has_conflict = true;
    } else |_| {
        if (std.fs.openDirAbsolute(dest_path, .{})) |d| {
            var dir = d;
            dir.close();
            has_conflict = true;
        } else |_| {}
    }

    if (has_conflict) {
        const p_prompt = try std.fmt.allocPrint(allocator, "Destination '{s}' already exists.\nOverwrite? [y/N]: ", .{dest_path});
        defer allocator.free(p_prompt);
        if (!confirmPrompt(p_prompt)) {
            std.debug.print("Installation cancelled.\n", .{});
            return;
        }
    }

    if (contents_flag) {
        try std.fs.cwd().makePath(dest_path);
        var dir = try std.fs.openDirAbsolute(downloaded_path, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            const sc = try std.fs.path.join(allocator, &[_][]const u8{ downloaded_path, entry.name });
            defer allocator.free(sc);
            const dc = try std.fs.path.join(allocator, &[_][]const u8{ dest_path, entry.name });
            defer allocator.free(dc);
            try fs.copyPath(allocator, sc, dc);
        }
    } else {
        try fs.installPath(allocator, downloaded_path, dest_path);
    }

    if (git.isBareRepo()) {
        if (paths.gitPath(allocator, homeDir, target_config_path)) |gp| {
            defer allocator.free(gp);
            _ = git.add(&[_][]const u8{gp}) catch {};
        } else |_| {}
    }

    std.debug.print("Successfully installed '{s}' to {s}\n", .{ target_config_path, dest_path });
}
