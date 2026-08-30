const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const paths = @import("../paths/mod.zig");
const config = @import("../config.zig");
const git_mod = @import("../git/mod.zig");
const fs = @import("../fs.zig");
const discovery = @import("discovery.zig");
const url = @import("url.zig");
const ui = @import("../ui.zig");

pub fn defaultBranch() []const u8 {
    if (builtin.os.tag == .windows) return "windows";
    return "main";
}

pub fn printInstallUsage() void {
    std.debug.print(
        \\Usage:
        \\  rice install [--repo <url>] [-b|--branch <branch>] [-f|--force]
        \\  rice install <name> [--repo <url>] [-b|--branch <branch>] [--contents|-C]
        \\  rice install <source> <destination> [--repo <url>] [-b|--branch <branch>] [--contents|-C]
        \\  rice install <github-url> [destination] [--contents|-C]
        \\  rice install --bin <source> [destination] [--tag <tag>] [--name <name>] [--save]
        \\
        \\Examples:
        \\  rice install --repo https://github.com/user/dotfiles -b main
        \\  rice install --repo user/dotfiles
        \\  rice install nvim
        \\  rice install nvim -b main
        \\  rice install --bin sharkdp/bat
        \\  rice install --bin sharkdp/bat /usr/local/bin
        \\  rice install --bin junegunn/fzf --save
        \\  rice install tmux --repo https://github.com/user/dotfiles
        \\  rice install config/tmux ~/.config/tmux --repo https://github.com/webpro/dotfiles
        \\  rice install .zshrc ~/.zshrc --repo https://github.com/user/dotfiles
        \\  rice install https://github.com/user/repo/blob/main/path/file.txt ~/Downloads
        \\  rice install https://github.com/user/repo/releases/download/v1.0/font.zip ~/.local/share/fonts
        \\  rice install https://github.com/dharmx/walls/tree/main/wave ~/Downloads
        \\  rice install https://github.com/user/dotfiles/tree/master/.config/foot .config/foot
        \\  rice install --contents https://github.com/dharmx/walls/tree/main/wave ~/Downloads
        \\
    , .{});
}

pub fn printInstallHelp() void {
    std.debug.print(
        \\Usage:
        \\  rice install [--repo <url>] [-b|--branch <branch>] [-f|--force]
        \\  rice install <name> [--repo <url>] [-b|--branch <branch>] [--contents|-C]
        \\  rice install <source> <destination> [--repo <url>] [-b|--branch <branch>] [--contents|-C]
        \\  rice install <github-url> [destination] [--contents|-C]
        \\  rice install --bin <source> [destination] [--tag <tag>] [--name <name>] [--save]
        \\
        \\Aliases:
        \\  rice i
        \\
        \\Options:
        \\  --bin, --bins       Install executable binary (defaults to ~/.local/bin or custom destination)
        \\  -r, --repo <url>    Remote repository URL (defaults to ~/.rice.ini repo)
        \\  -b, --branch <name> Branch name (default: main on unix, windows on windows)
        \\  -C, --contents      Extract directory contents directly into destination
        \\  -f, --force, -y     Overwrite existing files without confirmation prompts
        \\
        \\Examples:
        \\  rice install --repo https://github.com/h-jangra/dots -b master
        \\  rice install nvim
        \\  rice install nvim -b main
        \\  rice install --bin sharkdp/bat
        \\  rice install --bin sharkdp/bat /usr/local/bin
        \\  rice install --bin junegunn/fzf --save
        \\  rice install tmux --repo https://github.com/user/dotfiles
        \\  rice install config/tmux ~/.config/tmux --repo https://github.com/webpro/dotfiles
        \\  rice install .zshrc ~/.zshrc --repo https://github.com/user/dotfiles
        \\  rice install https://github.com/user/repo/blob/main/path/file.txt ~/Downloads
        \\  rice install https://github.com/user/repo/releases/download/v1.0/font.zip ~/.local/share/fonts
        \\  rice install https://github.com/dharmx/walls/tree/main/wave ~/Downloads
        \\  rice install https://github.com/h-jangra/dots/tree/master/.config/foot .config/foot
        \\  rice install --contents https://github.com/dharmx/walls/tree/main/wave ~/Downloads
        \\
    , .{});
}

const InstallItem = struct {
    repo_path: []u8,
    config_path: []u8,
    abs_path: []u8,
    is_outside: bool,

    fn deinit(self: *InstallItem, allocator: Allocator) void {
        allocator.free(self.repo_path);
        allocator.free(self.config_path);
        allocator.free(self.abs_path);
    }
};

pub fn installDotfiles(allocator: Allocator, git: *git_mod.Git, homeDir: []const u8, args: []const []const u8) !void {
    var repo_flag: ?[]const u8 = null;
    var branch_flag: ?[]const u8 = null;
    var contents_flag = false;
    var force_flag = false;
    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--repo") or std.mem.eql(u8, arg, "-r")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: -r/--repo requires a URL argument.\n", .{});
                return error.InvalidArgs;
            }
            repo_flag = std.mem.trim(u8, args[i + 1], " \t\r\n");
            i += 1;
        } else if (std.mem.startsWith(u8, arg, "--repo=")) {
            repo_flag = std.mem.trim(u8, arg["--repo=".len..], " \t\r\n");
        } else if (std.mem.startsWith(u8, arg, "-r=")) {
            repo_flag = std.mem.trim(u8, arg["-r=".len..], " \t\r\n");
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
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-y") or std.mem.eql(u8, arg, "--yes")) {
            force_flag = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printInstallHelp();
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Error: unknown flag \"{s}\"\n\n", .{arg});
            printInstallUsage();
            return error.UnknownFlag;
        } else {
            try positional.append(allocator, arg);
        }
    }

    if (positional.items.len > 2) {
        std.debug.print("Error: too many arguments provided\n\n", .{});
        printInstallUsage();
        return error.TooManyArgs;
    }

    var items: std.ArrayList(InstallItem) = .empty;
    defer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }

    var repo_url: ?[]u8 = null;
    defer if (repo_url) |r| allocator.free(r);
    var branch_url: ?[]u8 = null;
    defer if (branch_url) |b| allocator.free(b);
    var needs_remote_discovery: ?[]const u8 = null;

    if (positional.items.len == 1) {
        const raw = positional.items[0];
        if (paths.isURL(raw)) {
            if (paths.parseGitHubURL(allocator, raw)) |gh_info| {
                defer {
                    gh_info.deinit(allocator);
                    allocator.destroy(gh_info);
                }
                repo_url = try allocator.dupe(u8, gh_info.repo_url);
                if (gh_info.branch.len > 0) branch_url = try allocator.dupe(u8, gh_info.branch);

                if (gh_info.path.len > 0) {
                    if (contents_flag and gh_info.isFile()) {
                        std.debug.print("Error: --contents can only be used with directory sources.\n", .{});
                        return error.ContentsOnlyWithDirs;
                    }
                    const item_name = if (!contents_flag) gh_info.file_name else "";
                    const dest = try paths.resolveInstallDestination(allocator, homeDir, ".", item_name, contents_flag);
                    try items.append(allocator, .{
                        .repo_path = try allocator.dupe(u8, gh_info.path),
                        .config_path = dest.config_path,
                        .abs_path = dest.abs_path,
                        .is_outside = dest.is_outside_home,
                    });
                }
            } else |_| {
                return url.runDirectURLInstall(allocator, homeDir, raw, ".", contents_flag);
            }
        } else {
            needs_remote_discovery = raw;
        }
    } else if (positional.items.len == 2) {
        const raw_src = positional.items[0];
        const raw_dst = positional.items[1];

        if (paths.isURL(raw_src)) {
            if (paths.parseGitHubURL(allocator, raw_src)) |gh_info| {
                defer {
                    gh_info.deinit(allocator);
                    allocator.destroy(gh_info);
                }
                repo_url = try allocator.dupe(u8, gh_info.repo_url);
                if (gh_info.branch.len > 0) branch_url = try allocator.dupe(u8, gh_info.branch);

                if (gh_info.path.len > 0) {
                    if (contents_flag and gh_info.isFile()) {
                        std.debug.print("Error: --contents can only be used with directory sources.\n", .{});
                        return error.ContentsOnlyWithDirs;
                    }
                    const item_name = if (!contents_flag) gh_info.file_name else "";
                    const dest = try paths.resolveInstallDestination(allocator, homeDir, raw_dst, item_name, contents_flag);
                    try items.append(allocator, .{
                        .repo_path = try allocator.dupe(u8, gh_info.path),
                        .config_path = dest.config_path,
                        .abs_path = dest.abs_path,
                        .is_outside = dest.is_outside_home,
                    });
                }
            } else |_| {
                return url.runDirectURLInstall(allocator, homeDir, raw_src, raw_dst, contents_flag);
            }
        } else {
            const clean_src = try paths.validateSourcePath(allocator, raw_src);
            defer allocator.free(clean_src);
            const item_name = if (!contents_flag) std.fs.path.basename(clean_src) else "";
            const dest = try paths.resolveInstallDestination(allocator, homeDir, raw_dst, item_name, contents_flag);
            try items.append(allocator, .{
                .repo_path = try allocator.dupe(u8, clean_src),
                .config_path = dest.config_path,
                .abs_path = dest.abs_path,
                .is_outside = dest.is_outside_home,
            });
        }
    }

    var final_repo: ?[]u8 = null;

    defer if (final_repo) |r| allocator.free(r);

    if (repo_flag) |rf| {
        final_repo = try paths.normalizeRepoURL(allocator, rf);
    } else if (repo_url) |ru| {
        final_repo = try allocator.dupe(u8, ru);
    }

    var final_branch: ?[]u8 = null;
    defer if (final_branch) |b| allocator.free(b);

    if (branch_flag) |bf| {
        final_branch = try allocator.dupe(u8, bf);
    } else if (branch_url) |bu| {
        final_branch = try allocator.dupe(u8, bu);
    }

    if (final_repo == null or final_branch == null) {
        const ini_path = try paths.getRiceIniPath(allocator, homeDir);
        defer allocator.free(ini_path);
        if (config.loadConfig(allocator, ini_path)) |cfg| {
            defer {
                cfg.deinit();
                allocator.destroy(cfg);
            }
            if (final_repo == null and cfg.remote != null) {
                final_repo = try paths.normalizeRepoURL(allocator, cfg.remote.?);
            }
            if (final_branch == null and cfg.branch != null and cfg.branch.?.len > 0) {
                final_branch = try allocator.dupe(u8, cfg.branch.?);
            }
        } else |_| {}
    }

    if (git.isBareRepo()) {
        if (final_repo == null) {
            if (git.getRemote()) |r| {
                final_repo = try paths.normalizeRepoURL(allocator, r);
            } else |_| {}
        }
        if (final_branch == null) {
            if (git.getCurrentBranch()) |cur_b| {
                final_branch = cur_b;
            } else |_| {}
        }
    }

    var branch_str = if (final_branch) |b| b else defaultBranch();

    if (final_repo == null or final_repo.?.len == 0) {
        if (positional.items.len == 2) {
            std.debug.print("Error: no repository configured. Use:\n  rice install <source> <destination> --repo <repository>\n", .{});
        } else {
            std.debug.print("Error: no repository configured. Use:\n  rice install <name> --repo <repository>\n", .{});
        }
        return error.NoRepoConfigured;
    }

    const tmp_dir_path = try std.fmt.allocPrint(allocator, "/tmp/rice-install-{d}", .{fs.getMilliTimestamp()});
    defer allocator.free(tmp_dir_path);
    try fs.makePath(tmp_dir_path);
    defer fs.deleteTreeAbsolute(tmp_dir_path) catch {};

    try discovery.execGitInDir(allocator, tmp_dir_path, &.{ "init" });
    try discovery.execGitInDir(allocator, tmp_dir_path, &.{ "remote", "add", "origin", final_repo.? });

    var fetch_success = false;
    {
        const fetch_msg = try std.fmt.allocPrint(allocator, "Fetching {s} (branch: {s})...", .{ final_repo.?, branch_str });
        defer allocator.free(fetch_msg);
        const fetch_sp = try ui.Spinner.start(allocator, fetch_msg);
        defer fetch_sp.stop();

        if (discovery.execGitInDirQuiet(allocator, tmp_dir_path, &.{ "fetch", "--filter=blob:none", "--depth=1", "origin", branch_str })) |_| {
            fetch_success = true;
        } else |_| {
            if (discovery.execGitInDirQuiet(allocator, tmp_dir_path, &.{ "fetch", "--depth=1", "origin", branch_str })) |_| {
                fetch_success = true;
            } else |_| {}
        }

        if (!fetch_success and final_branch == null) {
            const fallbacks = [_][]const u8{ "main", "master", "HEAD" };
            for (fallbacks) |fb| {
                if (std.mem.eql(u8, fb, branch_str)) continue;
                if (discovery.execGitInDirQuiet(allocator, tmp_dir_path, &.{ "fetch", "--filter=blob:none", "--depth=1", "origin", fb })) |_| {
                    fetch_success = true;
                    branch_str = fb;
                    break;
                } else |_| {
                    if (discovery.execGitInDirQuiet(allocator, tmp_dir_path, &.{ "fetch", "--depth=1", "origin", fb })) |_| {
                        fetch_success = true;
                        branch_str = fb;
                        break;
                    } else |_| {}
                }
            }
        }
    }

    if (!fetch_success) {
        std.debug.print("Error: failed to fetch branch '{s}' from {s}\n", .{ branch_str, final_repo.? });
        return error.GitFetchFailed;
    }

    if (needs_remote_discovery) |name| {
        const resolved = try discovery.resolveRemoteConfig(allocator, tmp_dir_path, branch_str, name);
        const dest = try paths.resolveInstallDestination(allocator, homeDir, resolved.dest_config_path, "", contents_flag);
        try items.append(allocator, .{
            .repo_path = resolved.repo_path,
            .config_path = dest.config_path,
            .abs_path = dest.abs_path,
            .is_outside = dest.is_outside_home,
        });
        allocator.free(resolved.dest_config_path);
    }

    var has_remote_ini = false;
    if (items.items.len == 0) {
        if (discovery.runGitInDirQuiet(allocator, tmp_dir_path, &.{ "cat-file", "-e", "FETCH_HEAD:.rice.ini" }, true)) |out| {
            allocator.free(out);
            has_remote_ini = true;
        } else |_| {}

        if (has_remote_ini) {
            try discovery.execGitInDir(allocator, tmp_dir_path, &.{ "sparse-checkout", "init", "--no-cone" });
            try discovery.execGitInDir(allocator, tmp_dir_path, &.{ "sparse-checkout", "set", "--no-cone", ".rice.ini" });
            try discovery.execGitInDir(allocator, tmp_dir_path, &.{ "checkout", "--detach", "FETCH_HEAD" });

            const remote_ini_p = try std.fs.path.join(allocator, &.{ tmp_dir_path, ".rice.ini" });
            defer allocator.free(remote_ini_p);

            const remote_cfg = try config.loadConfig(allocator, remote_ini_p);
            defer {
                remote_cfg.deinit();
                allocator.destroy(remote_cfg);
            }

            for (remote_cfg.files.items) |f| {
                var repo_p = f;
                if (std.mem.startsWith(u8, repo_p, "~/")) repo_p = repo_p[2..];
                const dest = try paths.resolveInstallDestination(allocator, homeDir, f, "", contents_flag);
                try items.append(allocator, .{
                    .repo_path = try allocator.dupe(u8, repo_p),
                    .config_path = dest.config_path,
                    .abs_path = dest.abs_path,
                    .is_outside = dest.is_outside_home,
                });
            }
        } else {
            _ = discovery.execGitInDir(allocator, tmp_dir_path, &.{ "sparse-checkout", "disable" }) catch {};
            try discovery.execGitInDir(allocator, tmp_dir_path, &.{ "checkout", "--detach", "FETCH_HEAD" });

            const ls_out = try discovery.runGitInDir(allocator, tmp_dir_path, &.{ "ls-tree", "-r", "--name-only", "FETCH_HEAD" });
            defer allocator.free(ls_out);

            var it = std.mem.splitScalar(u8, ls_out, '\n');
            while (it.next()) |line| {
                const tr = std.mem.trim(u8, line, " \t\r\n");
                if (tr.len == 0) continue;
                if (std.mem.startsWith(u8, tr, ".git") or std.mem.startsWith(u8, tr, ".github")) continue;
                if (std.mem.eql(u8, tr, "README.md") or std.mem.eql(u8, tr, "LICENSE")) continue;

                const dest = try paths.resolveInstallDestination(allocator, homeDir, tr, "", contents_flag);
                try items.append(allocator, .{
                    .repo_path = try allocator.dupe(u8, tr),
                    .config_path = dest.config_path,
                    .abs_path = dest.abs_path,
                    .is_outside = dest.is_outside_home,
                });
            }
        }
    }

    if (items.items.len == 0) {
        std.debug.print("No dotfiles found to install.\n", .{});
        return;
    }

    var sparse_args: std.ArrayList([]const u8) = .empty;
    defer sparse_args.deinit(allocator);
    try sparse_args.appendSlice(allocator, &.{ "sparse-checkout", "set", "--no-cone" });
    if (has_remote_ini) try sparse_args.append(allocator, ".rice.ini");
    for (items.items) |item| try sparse_args.append(allocator, item.repo_path);

    {
        const dl_msg = try std.fmt.allocPrint(allocator, "Downloading from {s}...", .{final_repo.?});
        defer allocator.free(dl_msg);
        const dl_sp = try ui.Spinner.start(allocator, dl_msg);
        defer dl_sp.stop();

        try discovery.execGitInDir(allocator, tmp_dir_path, &.{ "sparse-checkout", "init", "--no-cone" });
        try discovery.execGitInDir(allocator, tmp_dir_path, sparse_args.items);
        try discovery.execGitInDir(allocator, tmp_dir_path, &.{ "checkout", "--detach", "FETCH_HEAD" });
    }

    if (!force_flag) {
        for (items.items) |item| {
            var conflict = false;
            if (fs.openFileAbsolute(item.abs_path, .{})) |f| {
                f.close(paths.getProcessIo());
                conflict = true;
            } else |_| {
                if (fs.openDirAbsolute(item.abs_path, .{})) |d| {
                    var dir = d;
                    dir.close(paths.getProcessIo());
                    conflict = true;
                } else |_| {}
            }
            if (conflict) {
                const prompt = try std.fmt.allocPrint(allocator, "Destination '{s}' already exists.\nOverwrite? [y/N]: ", .{item.abs_path});
                defer allocator.free(prompt);
                if (!fs.promptConfirm(prompt)) {
                    std.debug.print("Installation cancelled.\n", .{});
                    return;
                }
            }
        }
    }

    var installed_count: usize = 0;
    for (items.items) |item| {
        const src_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, item.repo_path });
        defer allocator.free(src_path);

        var is_dir = false;
        var exists = false;
        if (fs.openDirAbsolute(src_path, .{})) |d| {
            var dir = d;
            dir.close(paths.getProcessIo());
            is_dir = true;
            exists = true;
        } else |_| {
            if (fs.openFileAbsolute(src_path, .{})) |f| {
                f.close(paths.getProcessIo());
                exists = true;
            } else |_| {}
        }

        if (!exists) {
            std.debug.print("  [!] Skipping '{s}' (not found in remote repository)\n", .{item.config_path});
            continue;
        }

        if (contents_flag and !is_dir) {
            std.debug.print("Error: --contents can only be used with directory sources.\n", .{});
            return error.ContentsOnlyWithDirs;
        }

        if (contents_flag) {
            try fs.makePath(item.abs_path);
            var dir = try fs.openDirAbsolute(src_path, .{ .iterate = true });
            defer dir.close(paths.getProcessIo());
            var it = dir.iterate();
            while (try it.next(paths.getProcessIo())) |entry| {
                const sc = try std.fs.path.join(allocator, &.{ src_path, entry.name });
                defer allocator.free(sc);
                const dc = try std.fs.path.join(allocator, &.{ item.abs_path, entry.name });
                defer allocator.free(dc);
                try fs.copyPath(allocator, sc, dc);
            }
        } else {
            fs.installPath(allocator, src_path, item.abs_path) catch |err| {
                if (err == error.AccessDenied or err == error.PermissionDenied) {
                    std.debug.print("Error: permission denied writing to '{s}'. Try running with sudo or check permissions.\n", .{item.abs_path});
                } else {
                    std.debug.print("Error installing '{s}' to '{s}': {s}\n", .{ item.config_path, item.abs_path, @errorName(err) });
                }
                return err;
            };
        }

        if (items.items.len > 1) {
            std.debug.print("  [✓] Installed {s}\n", .{item.config_path});
        } else {
            std.debug.print("Successfully installed '{s}' to {s}\n", .{ item.config_path, item.abs_path });
        }
        installed_count += 1;
    }

    if (items.items.len > 1) {
        std.debug.print("\nSuccessfully installed {d} dotfile path(s) from {s} (branch: {s})\n", .{ installed_count, final_repo.?, branch_str });
    }
}
