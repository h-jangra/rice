const std = @import("std");
const Allocator = std.mem.Allocator;
const paths = @import("core/paths.zig");
const git_mod = @import("core/git.zig");
const config = @import("core/config.zig");
const cmd_repo = @import("cmd/repo.zig");
const cmd_sync = @import("cmd/sync.zig");
const install_mod = @import("core/install.zig");
const build_options = @import("build_options");

pub const Version = build_options.version;

const command_help_map = std.StaticStringMap([]const u8).initComptime(.{
    .{
        "init",
        \\Usage: rice init [remote]
        \\
        \\Initialize a new bare Git repository in ~/.rice, optionally configure the origin
        \\remote, create ~/.rice.ini, and connect to remote or create an initial commit.
        \\
        \\Examples:
        \\  rice init
        \\  rice init git@github.com:username/dotfiles.git
        \\  rice init https://github.com/username/dotfiles
    },
    .{
        "add",
        \\Usage: rice add <path>...
        \\Aliases: rice a
        \\
        \\Track and stage files or directories within $HOME in ~/.rice.ini and Git.
        \\
        \\Examples:
        \\  rice add ~/.config/nvim
        \\  rice add ~/.config/nvim ~/.gitconfig ~/.zshrc
        \\  rice a ~/.gitconfig
    },
    .{
        "remove",
        \\Usage: rice remove <path>
        \\Aliases: rice rm
        \\
        \\Untrack a path from Git and remove it from ~/.rice.ini.
        \\The file on disk in $HOME is preserved.
        \\
        \\Examples:
        \\  rice remove ~/.gitconfig
        \\  rice rm ~/.config/nvim
    },
    .{
        "list",
        \\Usage: rice list
        \\Aliases: rice ls
        \\
        \\List all managed paths recorded in ~/.rice.ini.
    },
    .{
        "status",
        \\Usage: rice status
        \\Aliases: rice st
        \\
        \\Show Git status restricted to tracked paths in ~/.rice.ini.
    },
    .{
        "diff",
        \\Usage: rice diff [path]
        \\Aliases: rice d
        \\
        \\Show Git diff for all managed paths or a specific tracked path.
        \\
        \\Examples:
        \\  rice diff
        \\  rice d ~/.config/nvim
    },
    .{
        "commit",
        \\Usage: rice commit [-m|--message] [message]
        \\Aliases: rice c
        \\
        \\Stage ~/.rice.ini and all tracked paths, then commit changes.
        \\If a message is omitted, an automatic commit message is generated based on staged files.
        \\
        \\Examples:
        \\  rice commit
        \\  rice commit "feat: update nvim config"
        \\  rice commit -m "feat: update nvim config"
        \\  rice c -m "fix: update alias in bashrc"
    },
    .{
        "push",
        \\Usage: rice push [-m|--message] [message]
        \\Aliases: rice p
        \\
        \\Push committed changes to origin remote repository, automatically committing
        \\uncommitted tracked changes (with an optional custom message) if needed and
        \\printing the pushed commit message.
        \\
        \\Examples:
        \\  rice push
        \\  rice push -m "feat: update dotfiles"
        \\  rice p -m "sync dots"
    },
    .{
        "pull",
        \\Usage: rice pull [-f|--force]
        \\Aliases: rice pl
        \\
        \\Safely fetch and merge changes from origin. Aborts if remote changes
        \\conflict with uncommitted local modifications in $HOME.
        \\
        \\Options:
        \\  -f, --force    Force pull and overwrite local conflicting files with remote version
    },
    .{
        "switch",
        \\Usage:
        \\  rice switch <branch>
        \\  rice switch -c <branch>
        \\
        \\Aliases:
        \\  rice sw, rice checkout, rice co
        \\
        \\Switch to an existing branch or create and switch to a new branch (-c).
        \\
        \\Examples:
        \\  rice switch windows
        \\  rice switch -c personal-theme
        \\  rice sw main
    },
    .{
        "branches",
        \\Usage: rice branch [flags]
        \\Aliases: rice branches, rice br
        \\
        \\Flags:
        \\  -a, --all        List both local and remote-tracking branches
        \\  -r, --remotes    List remote-tracking branches
        \\
        \\Examples:
        \\  rice branch
        \\  rice branch -a
        \\  rice branches
    },
    .{
        "restore",
        \\Usage:
        \\  rice restore
        \\  rice restore --bins
        \\
        \\Aliases:
        \\  rice rs
        \\
        \\Restore managed files from repository HEAD into $HOME, or reinstall binaries
        \\declared in ~/.rice.ini [binaries] with --bins.
        \\
        \\Options:
        \\  --bins    Reinstall all binaries declared in ~/.rice.ini [binaries]
    },
    .{
        "discard",
        \\Usage:
        \\  rice discard [path...] [-f|--force]
        \\
        \\Aliases:
        \\  rice dis
        \\
        \\Discard uncommitted local changes to tracked dotfiles in $HOME, restoring them
        \\to the version in repository HEAD.
        \\
        \\Options:
        \\  -f, --force    Force discard local changes without confirmation prompt
        \\
        \\Examples:
        \\  rice discard
        \\  rice discard ~/.zshrc
        \\  rice discard ~/.config/nvim
        \\  rice dis ~/.gitconfig
    },
    .{
        "install",
        \\Usage:
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
        \\  --repo <url>        Remote repository URL (defaults to ~/.rice.ini repo)
        \\  -b, --branch <name> Branch name (default: main on unix, windows on windows)
        \\  --contents, -C      Extract directory contents directly into destination
        \\
        \\Examples:
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
        \\  rice install --contents https://github.com/dharmx/walls/tree/main/wave ~/Downloads
    },
    .{
        "edit",
        \\Usage: rice edit
        \\Aliases: rice e
        \\
        \\Open ~/.rice.ini in $EDITOR (or vi by default).
    },
    .{
        "doctor",
        \\Usage: rice doctor
        \\
        \\Validate Git installation, bare repository integrity, ~/.rice.ini configuration,
        \\and managed path safety.
    },
});

fn resolveAlias(cmd_name: []const u8) []const u8 {
    const alias_map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "a", "add" },
        .{ "rm", "remove" },
        .{ "ls", "list" },
        .{ "st", "status" },
        .{ "d", "diff" },
        .{ "c", "commit" },
        .{ "p", "push" },
        .{ "pl", "pull" },
        .{ "sw", "switch" },
        .{ "checkout", "switch" },
        .{ "co", "switch" },
        .{ "branch", "branches" },
        .{ "br", "branches" },
        .{ "rs", "restore" },
        .{ "dis", "discard" },
        .{ "i", "install" },
        .{ "e", "edit" },
    });
    return alias_map.get(cmd_name) orelse cmd_name;
}

pub fn printCompactUsage() void {
    std.debug.print("rice {s} — A minimal dotfile and repository manager\n\n", .{Version});
    std.debug.print(
        \\Usage: rice <command> [arguments]
        \\
        \\Repository:
        \\  init [remote]        Initialize bare repository
        \\  add, a <path>...     Track paths
        \\  remove, rm <path>    Untrack a path
        \\  list, ls             List managed paths
        \\  status, st           Show repository status
        \\  diff, d [path]       Show changes
        \\
        \\Branch & Sync:
        \\  commit, c [msg]      Commit changes (supports -m)
        \\  push, p [msg]        Push to origin (supports -m)
        \\  pull, pl             Pull changes safely
        \\  switch, sw <branch>  Switch or create branch (-c)
        \\  branches, br         List repository branches
        \\  restore, rs          Restore files (--bins)
        \\  discard, dis [path]  Discard local changes
        \\
        \\Install & Binaries:
        \\  install, i <source>  Install dotfiles or binaries (-b)
        \\  bin [install] <src>  Download/install release binaries
        \\
        \\Other:
        \\  edit, e              Open configuration
        \\  doctor               Check repository health
        \\  version, -v          Show version information
        \\
        \\Run 'rice --help' for detailed usage and examples.
        \\
    , .{});
}

pub fn printDetailedHelp() void {
    std.debug.print("rice {s} — A minimal dotfile and repository manager\n\n", .{Version});
    std.debug.print(
        \\Usage: rice <command> [arguments]
        \\
        \\Repository Commands:
        \\  init [remote]          Initialize bare repository in ~/.rice and configure origin
        \\  add, a <path>...       Track and stage file(s) or director(ies) in ~/.rice.ini
        \\  remove, rm <path>      Untrack a path (preserves working tree file on disk)
        \\  list, ls               List all managed paths recorded in ~/.rice.ini
        \\  status, st             Show Git status restricted to managed paths
        \\  diff, d [path]         Show changes in managed files (or a specific path)
        \\
        \\Branch & Sync Commands:
        \\  commit, c [message]    Stage .rice.ini and all managed paths, then commit (supports -m)
        \\  push, p [message]      Push to origin remote, committing uncommitted changes (supports -m)
        \\  pull, pl               Safely pull changes from origin (aborts on conflict)
        \\  switch, sw <branch>    Switch to an existing branch or create a new one (-c)
        \\  branches, br           List all local and remote branches
        \\  restore, rs [--bins]   Restore managed dotfiles or install declared binaries
        \\  discard, dis [path]    Discard local uncommitted changes in managed file(s)
        \\
        \\Install Commands:
        \\  install, i <source> [destination] [flags]
        \\      Selectively download and install dotfiles using sparse checkouts, or
        \\      install release binaries with --bin.
        \\
        \\      Flags:
        \\        --bin, --bins       Install executable binary (defaults to ~/.local/bin or custom destination)
        \\        --repo <url>        Remote repository URL (defaults to ~/.rice.ini repo)
        \\        --branch <branch>   Branch to install from (default: main / windows)
        \\        --contents, -C      Extract directory contents directly into destination
        \\
        \\Binary Commands:
        \\  bin [install] <source> [destination] [--tag <tag>] [--name <name>] [--save]
        \\      Download and install CLI binaries from GitHub releases, URLs, or local files.
        \\
        \\  bin list
        \\      List binaries recorded in ~/.rice.ini [binaries] and their status.
        \\
        \\  bin remove <name>
        \\      Remove an installed binary from ~/.local/bin.
        \\
        \\Other Commands:
        \\  edit, e                Open ~/.rice.ini in $EDITOR
        \\  doctor                 Validate Git, bare repository, and config health
        \\  version, -v            Show version information
        \\  help, -h               Show help for rice or a specific command
        \\
        \\Examples:
        \\  # Initialize and push dotfiles
        \\  rice init git@github.com:username/dotfiles.git
        \\  rice add ~/.config/nvim ~/.gitconfig
        \\  rice commit -m "feat: initial dotfiles"
        \\  rice push
        \\
        \\  # Manage branches
        \\  rice branches
        \\  rice switch windows
        \\  rice switch -c personal-theme
        \\
        \\  # Restore dotfiles on a new machine
        \\  git clone --bare git@github.com:username/dotfiles.git ~/.rice
        \\  rice restore
        \\  rice restore --bins
        \\
        \\  # Install dotfiles from remote repositories
        \\  rice install nvim
        \\  rice install tmux --repo https://github.com/user/dotfiles
        \\  rice install config/tmux ~/.config/tmux --repo https://github.com/webpro/dotfiles
        \\  rice install https://github.com/user/dotfiles/blob/main/.zshrc ~/.zshrc
        \\  rice install --contents https://github.com/user/dotfiles/tree/main/wallpapers ~/Pictures
        \\
        \\  # Install binaries
        \\  rice install --bin sharkdp/bat
        \\  rice bin sharkdp/bat
        \\  rice bin sharkdp/bat /usr/local/bin
        \\  rice bin install junegunn/fzf --save
        \\  rice bin starship/starship --tag v1.18.0
        \\  rice bin https://github.com/h-jangra/ghost.sh/releases/download/v0.2.0/ghost-x86_64-linux /usr/local/bin/ghost/ghost
        \\  rice bin https://example.com/tool.tar.gz .
        \\  rice bin ./tool --name mytool
        \\  rice bin list
        \\  rice bin remove bat
        \\
    , .{});
}

pub fn printCommandHelp(cmd_name: []const u8) void {
    if (std.mem.eql(u8, cmd_name, "bin")) {
        install_mod.printBinHelp();
        return;
    }
    if (std.mem.eql(u8, cmd_name, "version") or std.mem.eql(u8, cmd_name, "-v") or std.mem.eql(u8, cmd_name, "--version")) {
        std.debug.print("rice {s}\n", .{Version});
        return;
    }
    const resolved = resolveAlias(cmd_name);
    if (command_help_map.get(resolved)) |help_text| {
        std.debug.print("{s}\n", .{help_text});
        return;
    }
    std.debug.print("Error: unknown command \"{s}\"\n\n", .{cmd_name});
    printCompactUsage();
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    paths.setProcessIo(init.io);
    paths.setProcessEnviron(init.minimal.environ);

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(allocator);

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();

    while (it.next()) |arg| try args_list.append(allocator, arg);
    const args = args_list.items;

    if (args.len < 2) {
        printCompactUsage();
        std.process.exit(1);
    }

    const command = args[1];
    const cmd_args = args[2..];

    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "h")) {
        if (cmd_args.len > 0) {
            printCommandHelp(cmd_args[0]);
        } else {
            printDetailedHelp();
        }
        std.process.exit(0);
    }

    if (cmd_args.len > 0 and (std.mem.eql(u8, cmd_args[0], "--help") or std.mem.eql(u8, cmd_args[0], "-h"))) {
        printCommandHelp(command);
        std.process.exit(0);
    }

    if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "-v") or std.mem.eql(u8, command, "--version")) {
        std.debug.print("rice {s}\n", .{Version});
        std.process.exit(0);
    }

    const home_dir = paths.getHomeDir(allocator) catch |err| {
        std.debug.print("Error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer allocator.free(home_dir);

    var git = git_mod.Git.init(allocator, home_dir) catch |err| {
        std.debug.print("Error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer git.deinit();

    const resolved_cmd = resolveAlias(command);

    if (std.mem.eql(u8, resolved_cmd, "init")) {
        cmd_repo.initCmd(allocator, git, home_dir, cmd_args) catch std.process.exit(1);
    } else if (std.mem.eql(u8, resolved_cmd, "add")) {
        cmd_repo.addCmd(allocator, git, home_dir, cmd_args) catch std.process.exit(1);
    } else if (std.mem.eql(u8, resolved_cmd, "remove")) {
        cmd_repo.removeCmd(allocator, git, home_dir, cmd_args) catch std.process.exit(1);
    } else if (std.mem.eql(u8, resolved_cmd, "list")) {
        cmd_repo.listCmd(allocator, home_dir) catch std.process.exit(1);
    } else if (std.mem.eql(u8, resolved_cmd, "status")) {
        cmd_repo.statusCmd(allocator, git, home_dir) catch std.process.exit(1);
    } else if (std.mem.eql(u8, resolved_cmd, "diff")) {
        cmd_repo.diffCmd(allocator, git, home_dir, cmd_args) catch std.process.exit(1);
    } else if (std.mem.eql(u8, resolved_cmd, "commit")) {
        cmd_sync.commitCmd(allocator, git, home_dir, cmd_args) catch std.process.exit(1);
    } else if (std.mem.eql(u8, resolved_cmd, "push")) {
        cmd_sync.pushCmd(allocator, git, home_dir, cmd_args) catch std.process.exit(1);
    } else if (std.mem.eql(u8, resolved_cmd, "pull")) {
        cmd_sync.pullCmd(allocator, git, home_dir, cmd_args) catch std.process.exit(1);
    } else if (std.mem.eql(u8, resolved_cmd, "switch")) {
        cmd_sync.switchCmd(allocator, git, home_dir, cmd_args) catch std.process.exit(1);
    } else if (std.mem.eql(u8, resolved_cmd, "branches")) {
        cmd_sync.branchesCmd(allocator, git, cmd_args) catch std.process.exit(1);
    } else if (std.mem.eql(u8, resolved_cmd, "restore")) {
        cmd_sync.restoreCmd(allocator, git, home_dir, cmd_args) catch std.process.exit(1);
    } else if (std.mem.eql(u8, resolved_cmd, "discard")) {
        cmd_sync.discardCmd(allocator, git, home_dir, cmd_args) catch std.process.exit(1);
    } else if (std.mem.eql(u8, resolved_cmd, "install")) {
        install_mod.installCmd(allocator, git, home_dir, cmd_args) catch std.process.exit(1);
    } else if (std.mem.eql(u8, command, "bin")) {
        install_mod.binCmd(allocator, home_dir, cmd_args) catch std.process.exit(1);
    } else if (std.mem.eql(u8, resolved_cmd, "edit")) {
        cmd_repo.editCmd(allocator, home_dir, cmd_args) catch std.process.exit(1);
    } else if (std.mem.eql(u8, resolved_cmd, "doctor")) {
        cmd_repo.doctorCmd(allocator, git, home_dir) catch std.process.exit(1);
    } else {
        std.debug.print("Error: unknown command \"{s}\"\n\n", .{command});
        printCompactUsage();
        std.process.exit(1);
    }
}

test {
    _ = @import("tests/tests.zig");
}
