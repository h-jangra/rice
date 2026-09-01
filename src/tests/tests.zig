const std = @import("std");
const config = @import("../core/config.zig");
const paths = @import("../core/paths.zig");
const fs = @import("../core/fs.zig");
const bin = @import("../core/bin.zig");
const ui = @import("../core/ui.zig");
const git_mod = @import("../core/git.zig");
const cmd_repo = @import("../cmd/repo.zig");
const discovery = @import("../core/install/discovery.zig");

test "ui: spinner basic lifecycle" {
    const allocator = std.testing.allocator;
    const spinner = try ui.Spinner.start(allocator, "Testing loader");
    spinner.updateMessage("Updated testing loader");
    spinner.stop();
}

test "config: normalization and ini parsing" {
    const allocator = std.testing.allocator;

    const norm = try config.normalizeConfigFileEntry(allocator, "  ~/.config/nvim/init.lua  ");
    defer allocator.free(norm);
    try std.testing.expectEqualStrings("~/.config/nvim/init.lua", norm);

    const norm2 = try config.normalizeConfigFileEntry(allocator, ".zshrc");
    defer allocator.free(norm2);
    try std.testing.expectEqualStrings("~/.zshrc", norm2);

    var cfg = config.Config.init(allocator);
    defer cfg.deinit();

    _ = try cfg.addFile("~/.zshrc");
    _ = try cfg.addFile("~/.config/nvim");
    try std.testing.expect(cfg.hasFile("~/.zshrc"));
    try std.testing.expect(cfg.hasFile(".zshrc"));
    try std.testing.expect(!cfg.hasFile("~/.gitconfig"));

    _ = try cfg.addBinary("bat", "sharkdp/bat");
    try std.testing.expectEqualStrings("sharkdp/bat", cfg.binaries.get("bat").?);

    cfg.remote = try allocator.dupe(u8, "https://github.com/test/dotfiles.git");
    cfg.branch = try allocator.dupe(u8, "main");
    try std.testing.expectEqualStrings("main", cfg.branch.?);
}

test "paths: sensitive file detection" {
    try std.testing.expect(paths.detectSensitiveFile("~/.ssh/id_rsa") != null);
    try std.testing.expect(paths.detectSensitiveFile("~/.ssh/id_rsa.pub") == null);
    try std.testing.expect(paths.detectSensitiveFile(".env") != null);
    try std.testing.expect(paths.detectSensitiveFile(".env.example") == null);
    try std.testing.expect(paths.detectSensitiveFile("cert.pem") != null);
    try std.testing.expect(paths.detectSensitiveFile("~/.aws/credentials") != null);
    try std.testing.expect(paths.detectSensitiveFile("~/.docker/config.json") != null);
}

test "paths: github url parsing" {
    const allocator = std.testing.allocator;

    const gh_info1 = try paths.parseGitHubURL(allocator, "https://github.com/h-jangra/rice/blob/main/README.md");
    defer {
        gh_info1.deinit(allocator);
        allocator.destroy(gh_info1);
    }
    try std.testing.expectEqualStrings("https://github.com/h-jangra/rice.git", gh_info1.repo_url);
    try std.testing.expectEqualStrings("main", gh_info1.branch);
    try std.testing.expectEqualStrings("README.md", gh_info1.path);
    try std.testing.expect(gh_info1.isFile());

    const gh_info2 = try paths.parseGitHubURL(allocator, "https://github.com/h-jangra/dots/tree/master/.config/foot");
    defer {
        gh_info2.deinit(allocator);
        allocator.destroy(gh_info2);
    }
    try std.testing.expectEqualStrings("https://github.com/h-jangra/dots.git", gh_info2.repo_url);
    try std.testing.expectEqualStrings("master", gh_info2.branch);
    try std.testing.expectEqualStrings(".config/foot", gh_info2.path);
    try std.testing.expect(gh_info2.isDirectory());

    const gh_info3 = try paths.parseGitHubURL(allocator, "https://github.com/h-jangra/dots/tree/master");
    defer {
        gh_info3.deinit(allocator);
        allocator.destroy(gh_info3);
    }
    try std.testing.expectEqualStrings("https://github.com/h-jangra/dots.git", gh_info3.repo_url);
    try std.testing.expectEqualStrings("master", gh_info3.branch);
    try std.testing.expectEqualStrings("", gh_info3.path);

    const gh_info4 = try paths.parseGitHubURL(allocator, "https://github.com/h-jangra/dots");
    defer {
        gh_info4.deinit(allocator);
        allocator.destroy(gh_info4);
    }
    try std.testing.expectEqualStrings("https://github.com/h-jangra/dots.git", gh_info4.repo_url);
    try std.testing.expectEqualStrings("", gh_info4.path);

    // Test directory from GitHub with tree URL
    const gh_info5 = try paths.parseGitHubURL(allocator, "https://github.com/Darkkal44/qylock/tree/main/themes/last-of-us");
    defer {
        gh_info5.deinit(allocator);
        allocator.destroy(gh_info5);
    }
    try std.testing.expectEqualStrings("https://github.com/Darkkal44/qylock.git", gh_info5.repo_url);
    try std.testing.expectEqualStrings("main", gh_info5.branch);
    try std.testing.expectEqualStrings("themes/last-of-us", gh_info5.path);
    try std.testing.expectEqualStrings("last-of-us", gh_info5.file_name);
    try std.testing.expect(gh_info5.isDirectory());

    // Test URL with query string and trailing slash
    const gh_info6 = try paths.parseGitHubURL(allocator, "https://github.com/Darkkal44/qylock/tree/main/themes/last-of-us/?tab=readme-ov-file#section");
    defer {
        gh_info6.deinit(allocator);
        allocator.destroy(gh_info6);
    }
    try std.testing.expectEqualStrings("https://github.com/Darkkal44/qylock.git", gh_info6.repo_url);
    try std.testing.expectEqualStrings("main", gh_info6.branch);
    try std.testing.expectEqualStrings("themes/last-of-us", gh_info6.path);

    // Test raw.githubusercontent.com URL
    const gh_info7 = try paths.parseGitHubURL(allocator, "https://raw.githubusercontent.com/Darkkal44/qylock/main/themes/last-of-us/theme.conf");
    defer {
        gh_info7.deinit(allocator);
        allocator.destroy(gh_info7);
    }
    try std.testing.expectEqualStrings("https://github.com/Darkkal44/qylock.git", gh_info7.repo_url);
    try std.testing.expectEqualStrings("main", gh_info7.branch);
    try std.testing.expectEqualStrings("themes/last-of-us/theme.conf", gh_info7.path);
    try std.testing.expect(gh_info7.isFile());

    // Test GitLab tree URL
    const gl_info = try paths.parseGitHubURL(allocator, "https://gitlab.com/user/myrepo/-/tree/main/config/foot");
    defer {
        gl_info.deinit(allocator);
        allocator.destroy(gl_info);
    }
    try std.testing.expectEqualStrings("https://gitlab.com/user/myrepo.git", gl_info.repo_url);
    try std.testing.expectEqualStrings("main", gl_info.branch);
    try std.testing.expectEqualStrings("config/foot", gl_info.path);
    try std.testing.expect(gl_info.isDirectory());

    // Test Codeberg URL
    const cb_info = try paths.parseGitHubURL(allocator, "https://codeberg.org/user/dotfiles/src/branch/master/.config/alacritty");
    defer {
        cb_info.deinit(allocator);
        allocator.destroy(cb_info);
    }
    try std.testing.expectEqualStrings("https://codeberg.org/user/dotfiles.git", cb_info.repo_url);
    try std.testing.expectEqualStrings("master", cb_info.branch);
    try std.testing.expectEqualStrings(".config/alacritty", cb_info.path);
    try std.testing.expect(cb_info.isDirectory());

    // Releases should return error so they are routed to direct download
    try std.testing.expectError(error.UnsupportedGitHubURL, paths.parseGitHubURL(allocator, "https://github.com/user/repo/releases/download/v1.0/font.zip"));
}

test "paths: resolve install destination" {
    const allocator = std.testing.allocator;
    const fake_home = "/home/testuser";

    const res1 = try paths.resolveInstallDestination(allocator, fake_home, ".config/foot", "foot", false);
    defer {
        allocator.free(res1.config_path);
        allocator.free(res1.abs_path);
    }
    try std.testing.expectEqualStrings("~/.config/foot", res1.config_path);
    try std.testing.expectEqualStrings("/home/testuser/.config/foot", res1.abs_path);
    try std.testing.expect(!res1.is_outside_home);

    const res2 = try paths.resolveInstallDestination(allocator, fake_home, "~/.config/foot", "foot", false);
    defer {
        allocator.free(res2.config_path);
        allocator.free(res2.abs_path);
    }
    try std.testing.expectEqualStrings("~/.config/foot", res2.config_path);
    try std.testing.expectEqualStrings("/home/testuser/.config/foot", res2.abs_path);
    try std.testing.expect(!res2.is_outside_home);

    const res3 = try paths.resolveInstallDestination(allocator, fake_home, ".", "foo.txt", false);
    defer {
        allocator.free(res3.config_path);
        allocator.free(res3.abs_path);
    }
    try std.testing.expect(std.mem.endsWith(u8, res3.abs_path, "/foo.txt"));

    const res4 = try paths.resolveInstallDestination(allocator, fake_home, ".", "Downloads", false);
    defer {
        allocator.free(res4.config_path);
        allocator.free(res4.abs_path);
    }
    try std.testing.expect(std.mem.endsWith(u8, res4.abs_path, "/Downloads"));

    const res5 = try paths.resolveInstallDestination(allocator, fake_home, "~/Downloads", "sample.txt", false);
    defer {
        allocator.free(res5.config_path);
        allocator.free(res5.abs_path);
    }
    try std.testing.expectEqualStrings("~/Downloads/sample.txt", res5.config_path);
    try std.testing.expectEqualStrings("/home/testuser/Downloads/sample.txt", res5.abs_path);
}

test "paths: repo url normalization" {
    const allocator = std.testing.allocator;

    const n1 = try paths.normalizeRepoURL(allocator, "user/dotfiles");
    defer allocator.free(n1);
    try std.testing.expectEqualStrings("https://github.com/user/dotfiles.git", n1);

    const n2 = try paths.normalizeRepoURL(allocator, "git@github.com:user/dotfiles.git");
    defer allocator.free(n2);
    try std.testing.expectEqualStrings("git@github.com:user/dotfiles.git", n2);
}

test "bin: asset matching" {
    try std.testing.expect(bin.matchAsset("bat-v0.24.0-x86_64-unknown-linux-gnu.tar.gz", "linux", "amd64"));
    try std.testing.expect(!bin.matchAsset("bat-v0.24.0-aarch64-unknown-linux-gnu.tar.gz", "linux", "amd64"));
    try std.testing.expect(bin.matchAsset("bat-v0.24.0-aarch64-unknown-linux-gnu.tar.gz", "linux", "arm64"));
    try std.testing.expect(!bin.matchAsset("bat-v0.24.0-x86_64-apple-darwin.tar.gz", "linux", "amd64"));
    try std.testing.expect(bin.matchAsset("bat-v0.24.0-x86_64-apple-darwin.tar.gz", "darwin", "amd64"));
}

test "fs: html detection and archive check" {
    try std.testing.expect(fs.isHTMLContent("<!DOCTYPE html><html><head></head><body>hello</body></html>"));
    try std.testing.expect(!fs.isHTMLContent("#!/bin/bash\necho hello"));
    try std.testing.expect(fs.isArchive("release.tar.gz"));
    try std.testing.expect(fs.isArchive("release.zip"));
    try std.testing.expect(!fs.isArchive("binary"));
}

test "bin: executable binary detection and candidate filtering" {
    // ELF executable header
    try std.testing.expect(bin.isExecutableBinary("\x7fELF\x02\x01\x01\x00"));
    // Mach-O header
    try std.testing.expect(bin.isExecutableBinary(&[_]u8{ 0xcf, 0xfa, 0xed, 0xfe }));
    // Windows MZ header
    try std.testing.expect(bin.isExecutableBinary("MZ\x90\x00\x03\x00"));
    // Script shebang
    try std.testing.expect(bin.isExecutableBinary("#!/bin/sh\necho hi\n"));
    try std.testing.expect(bin.isExecutableBinary("#!/usr/bin/env python3\n"));
    // Plain source code or text
    try std.testing.expect(!bin.isExecutableBinary("int main() { return 0; }"));
    try std.testing.expect(!bin.isExecutableBinary("fn main() void {}"));

    // Ignored candidate files (source code, docs, licenses)
    try std.testing.expect(bin.isIgnoredCandidate("main.c", false, "main.c"));
    try std.testing.expect(bin.isIgnoredCandidate("main.zig", false, "main.zig"));
    try std.testing.expect(bin.isIgnoredCandidate("main.rs", false, "main.rs"));
    try std.testing.expect(bin.isIgnoredCandidate("LICENSE", false, "LICENSE"));
    try std.testing.expect(bin.isIgnoredCandidate("README.md", false, "README.md"));
    try std.testing.expect(bin.isIgnoredCandidate("doc/file", false, "file"));
    try std.testing.expect(!bin.isIgnoredCandidate("bat", false, "bat"));
    try std.testing.expect(!bin.isIgnoredCandidate("bin/fzf", false, "fzf"));
}

test "bin: parse binary source" {
    const allocator = std.testing.allocator;

    var gh_src = try bin.parseBinarySource(allocator, "sharkdp/bat", "/home/test");
    defer gh_src.deinit(allocator);
    try std.testing.expectEqual(bin.BinarySourceType.github, gh_src.source_type);
    try std.testing.expectEqualStrings("sharkdp", gh_src.owner);
    try std.testing.expectEqualStrings("bat", gh_src.repo);

    var url_src = try bin.parseBinarySource(allocator, "https://github.com/sharkdp/bat/releases/download/v0.24.0/bat.tar.gz", "/home/test");
    defer url_src.deinit(allocator);
    try std.testing.expectEqual(bin.BinarySourceType.url, url_src.source_type);

    try std.testing.expectError(error.InvalidSource, bin.parseBinarySource(allocator, "nonexistent-binary-name-xyz", "/home/test"));
}

test "bin: options with destination" {
    const opts1 = bin.InstallBinOptions{
        .source = "https://github.com/h-jangra/ghost.sh/releases/download/v0.2.0/ghost-x86_64-linux",
        .dest = "/usr/local/bin/ghost/ghost",
    };
    try std.testing.expectEqualStrings("/usr/local/bin/ghost/ghost", opts1.dest);
    try std.testing.expectEqualStrings("https://github.com/h-jangra/ghost.sh/releases/download/v0.2.0/ghost-x86_64-linux", opts1.source);

    const opts2 = bin.InstallBinOptions{
        .source = "sharkdp/bat",
        .dest = ".",
    };
    try std.testing.expectEqualStrings(".", opts2.dest);
}

test "repo: init without remote creates bare repo and empty config" {
    const allocator = std.testing.allocator;

    const fake_home = try std.fmt.allocPrint(allocator, "/tmp/rice-test-home-{d}", .{fs.getMilliTimestamp()});
    defer allocator.free(fake_home);
    try fs.makePath(fake_home);
    defer fs.deleteTreeAbsolute(fake_home) catch {};

    var git = try git_mod.Git.init(allocator, fake_home);
    defer git.deinit();

    try cmd_repo.initCmd(allocator, git, fake_home, &.{});

    try std.testing.expect(git.isBareRepo());
    try std.testing.expect(git.hasCommits());

    const ini_path = try paths.getRiceIniPath(allocator, fake_home);
    defer allocator.free(ini_path);

    const cfg = try config.loadConfig(allocator, ini_path);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }

    try std.testing.expect(cfg.remote == null);
    try std.testing.expectEqualStrings("main", cfg.branch.?);
    try std.testing.expectEqual(@as(usize, 0), cfg.files.items.len);
}

test "repo: init with remote saves remote/branch and only fetches .rice.ini if present" {
    const allocator = std.testing.allocator;

    // 1. Create a remote git repository without .rice.ini
    const fake_remote = try std.fmt.allocPrint(allocator, "/tmp/rice-test-remote-noini-{d}", .{fs.getMilliTimestamp()});
    defer allocator.free(fake_remote);
    try fs.makePath(fake_remote);
    defer fs.deleteTreeAbsolute(fake_remote) catch {};

    try discovery.execGitInDir(allocator, fake_remote, &.{ "init", "-b", "main" });
    try discovery.execGitInDir(allocator, fake_remote, &.{ "config", "user.name", "TestUser" });
    try discovery.execGitInDir(allocator, fake_remote, &.{ "config", "user.email", "test@example.com" });

    // Add a file in the remote repo that is NOT .rice.ini
    const sample_file = try std.fs.path.join(allocator, &.{ fake_remote, "hello.txt" });
    defer allocator.free(sample_file);
    const f = try fs.createFileAbsolute(sample_file, .{});
    try f.writePositionalAll(paths.getProcessIo(), "hello world", 0);
    f.close(paths.getProcessIo());

    try discovery.execGitInDir(allocator, fake_remote, &.{ "add", "hello.txt" });
    try discovery.execGitInDir(allocator, fake_remote, &.{ "commit", "-m", "initial commit" });

    // 2. Initialize rice in a fake home pointing to fake_remote
    const fake_home = try std.fmt.allocPrint(allocator, "/tmp/rice-test-home-remote-{d}", .{fs.getMilliTimestamp()});
    defer allocator.free(fake_home);
    try fs.makePath(fake_home);
    defer fs.deleteTreeAbsolute(fake_home) catch {};

    var git = try git_mod.Git.init(allocator, fake_home);
    defer git.deinit();

    try cmd_repo.initCmd(allocator, git, fake_home, &.{fake_remote});

    try std.testing.expect(git.isBareRepo());
    try std.testing.expect(git.hasCommits());

    const ini_path = try paths.getRiceIniPath(allocator, fake_home);
    defer allocator.free(ini_path);

    const cfg = try config.loadConfig(allocator, ini_path);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }

    // Remote and branch should be saved
    try std.testing.expectEqualStrings(fake_remote, cfg.remote.?);
    try std.testing.expectEqualStrings("main", cfg.branch.?);
    // Files must NOT contain hello.txt (empty because no .rice.ini on remote)
    try std.testing.expectEqual(@as(usize, 0), cfg.files.items.len);

    // Bare repo in fake_home should only have .rice.ini in its HEAD commit, not hello.txt
    var head_files = try git.listRefFiles("HEAD", &.{});
    defer {
        for (head_files.items) |hf| allocator.free(hf);
        head_files.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), head_files.items.len);
    try std.testing.expectEqualStrings(".rice.ini", head_files.items[0]);
}

test "repo: init with remote that has .rice.ini fetches and loads it" {
    const allocator = std.testing.allocator;

    // 1. Create a remote git repository with a .rice.ini
    const fake_remote = try std.fmt.allocPrint(allocator, "/tmp/rice-test-remote-withini-{d}", .{fs.getMilliTimestamp()});
    defer allocator.free(fake_remote);
    try fs.makePath(fake_remote);
    defer fs.deleteTreeAbsolute(fake_remote) catch {};

    try discovery.execGitInDir(allocator, fake_remote, &.{ "init", "-b", "main" });
    try discovery.execGitInDir(allocator, fake_remote, &.{ "config", "user.name", "TestUser" });
    try discovery.execGitInDir(allocator, fake_remote, &.{ "config", "user.email", "test@example.com" });

    const remote_ini = try std.fs.path.join(allocator, &.{ fake_remote, ".rice.ini" });
    defer allocator.free(remote_ini);
    const f = try fs.createFileAbsolute(remote_ini, .{});
    const ini_data =
        \\[files]
        \\~/.config/nvim
        \\~/.zshrc
        \\
        \\[binaries]
        \\bat = sharkdp/bat
        \\
    ;
    try f.writePositionalAll(paths.getProcessIo(), ini_data, 0);
    f.close(paths.getProcessIo());

    try discovery.execGitInDir(allocator, fake_remote, &.{ "add", ".rice.ini" });
    try discovery.execGitInDir(allocator, fake_remote, &.{ "commit", "-m", "add rice.ini" });

    // 2. Initialize rice in a fake home pointing to fake_remote
    const fake_home = try std.fmt.allocPrint(allocator, "/tmp/rice-test-home-withini-{d}", .{fs.getMilliTimestamp()});
    defer allocator.free(fake_home);
    try fs.makePath(fake_home);
    defer fs.deleteTreeAbsolute(fake_home) catch {};

    var git = try git_mod.Git.init(allocator, fake_home);
    defer git.deinit();

    try cmd_repo.initCmd(allocator, git, fake_home, &.{fake_remote});

    const ini_path = try paths.getRiceIniPath(allocator, fake_home);
    defer allocator.free(ini_path);

    const cfg = try config.loadConfig(allocator, ini_path);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }

    try std.testing.expectEqualStrings(fake_remote, cfg.remote.?);
    try std.testing.expectEqualStrings("main", cfg.branch.?);
    try std.testing.expect(cfg.hasFile("~/.config/nvim"));
    try std.testing.expect(cfg.hasFile("~/.zshrc"));
    try std.testing.expect(cfg.binaries.contains("bat"));
}

test "install: direct URL/local archive installation with force flag" {
    const allocator = std.testing.allocator;
    const url_mod = @import("../core/install/url.zig");

    const tmp_test_dir = try std.fmt.allocPrint(allocator, "/tmp/rice-test-url-inst-{d}", .{fs.getMilliTimestamp()});
    defer allocator.free(tmp_test_dir);
    try fs.makePath(tmp_test_dir);
    defer fs.deleteTreeAbsolute(tmp_test_dir) catch {};

    const fake_home = try std.fs.path.join(allocator, &.{ tmp_test_dir, "home" });
    defer allocator.free(fake_home);
    try fs.makePath(fake_home);

    const test_tar_dir = try std.fs.path.join(allocator, &.{ tmp_test_dir, "src_data" });
    defer allocator.free(test_tar_dir);
    try fs.makePath(test_tar_dir);

    const font_file = try std.fs.path.join(allocator, &.{ test_tar_dir, "TestFont-Regular.ttf" });
    defer allocator.free(font_file);
    const ff = try fs.createFileAbsolute(font_file, .{});
    try ff.writePositionalAll(paths.getProcessIo(), "fake-font-data", 0);
    ff.close(paths.getProcessIo());

    const tar_path = try std.fs.path.join(allocator, &.{ tmp_test_dir, "font.tar" });
    defer allocator.free(tar_path);

    const res = try std.process.run(allocator, paths.getProcessIo(), .{
        .argv = &.{ "tar", "-cf", tar_path, "-C", test_tar_dir, "." },
    });
    allocator.free(res.stdout);
    allocator.free(res.stderr);

    const dest_dir = try std.fs.path.join(allocator, &.{ fake_home, ".local", "share", "fonts", "TestFont" });
    defer allocator.free(dest_dir);

    try url_mod.runDirectURLInstall(allocator, fake_home, tar_path, dest_dir, false, true);

    const installed_file = try std.fs.path.join(allocator, &.{ dest_dir, "TestFont-Regular.ttf" });
    defer allocator.free(installed_file);

    const installed_f = try fs.openFileAbsolute(installed_file, .{});
    installed_f.close(paths.getProcessIo());
}

test "install: direct archive installation into existing directory without force flag" {
    const allocator = std.testing.allocator;
    const url_mod = @import("../core/install/url.zig");

    const tmp_test_dir = try std.fmt.allocPrint(allocator, "/tmp/rice-test-url-exist-{d}", .{fs.getMilliTimestamp()});
    defer allocator.free(tmp_test_dir);
    try fs.makePath(tmp_test_dir);
    defer fs.deleteTreeAbsolute(tmp_test_dir) catch {};

    const fake_home = try std.fs.path.join(allocator, &.{ tmp_test_dir, "home" });
    defer allocator.free(fake_home);
    try fs.makePath(fake_home);

    const test_tar_dir = try std.fs.path.join(allocator, &.{ tmp_test_dir, "src_data" });
    defer allocator.free(test_tar_dir);
    try fs.makePath(test_tar_dir);

    const sample_file = try std.fs.path.join(allocator, &.{ test_tar_dir, "sample.txt" });
    defer allocator.free(sample_file);
    const sf = try fs.createFileAbsolute(sample_file, .{});
    try sf.writePositionalAll(paths.getProcessIo(), "sample-data", 0);
    sf.close(paths.getProcessIo());

    const tar_path = try std.fs.path.join(allocator, &.{ tmp_test_dir, "sample.tar" });
    defer allocator.free(tar_path);

    const res = try std.process.run(allocator, paths.getProcessIo(), .{
        .argv = &.{ "tar", "-cf", tar_path, "-C", test_tar_dir, "." },
    });
    allocator.free(res.stdout);
    allocator.free(res.stderr);

    // Create the destination directory beforehand (like ~/Downloads)
    const dest_dir = try std.fs.path.join(allocator, &.{ fake_home, "Downloads" });
    defer allocator.free(dest_dir);
    try fs.makePath(dest_dir);

    // forceFlag = false, dest_dir already exists
    try url_mod.runDirectURLInstall(allocator, fake_home, tar_path, dest_dir, false, false);

    const installed_file = try std.fs.path.join(allocator, &.{ dest_dir, "sample.txt" });
    defer allocator.free(installed_file);

    const installed_f = try fs.openFileAbsolute(installed_file, .{});
    installed_f.close(paths.getProcessIo());
}

test "install: direct file installation into existing directory and dot destination" {
    const allocator = std.testing.allocator;
    const url_mod = @import("../core/install/url.zig");

    const tmp_test_dir = try std.fmt.allocPrint(allocator, "/tmp/rice-test-file-inst-{d}", .{fs.getMilliTimestamp()});
    defer allocator.free(tmp_test_dir);
    try fs.makePath(tmp_test_dir);
    defer fs.deleteTreeAbsolute(tmp_test_dir) catch {};

    const fake_home = try std.fs.path.join(allocator, &.{ tmp_test_dir, "home" });
    defer allocator.free(fake_home);
    try fs.makePath(fake_home);

    const sample_src = try std.fs.path.join(allocator, &.{ tmp_test_dir, "hello.txt" });
    defer allocator.free(sample_src);
    const sf = try fs.createFileAbsolute(sample_src, .{});
    try sf.writePositionalAll(paths.getProcessIo(), "hello world", 0);
    sf.close(paths.getProcessIo());

    // 1. Destination is existing directory ~/Downloads
    const dest_dir = try std.fs.path.join(allocator, &.{ fake_home, "Downloads" });
    defer allocator.free(dest_dir);
    try fs.makePath(dest_dir);

    try url_mod.runDirectURLInstall(allocator, fake_home, sample_src, dest_dir, false, false);

    const target_file1 = try std.fs.path.join(allocator, &.{ dest_dir, "hello.txt" });
    defer allocator.free(target_file1);
    const f1 = try fs.openFileAbsolute(target_file1, .{});
    f1.close(paths.getProcessIo());

    // 2. Destination is "." (current working directory)
    try url_mod.runDirectURLInstall(allocator, fake_home, sample_src, ".", false, false);

    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(paths.getProcessIo(), &cwd_buf);
    const target_file2 = try std.fs.path.join(allocator, &.{ cwd_buf[0..cwd_len], "hello.txt" });
    defer allocator.free(target_file2);
    defer fs.deleteFileAbsolute(target_file2) catch {};

    const f2 = try fs.openFileAbsolute(target_file2, .{});
    f2.close(paths.getProcessIo());
}

