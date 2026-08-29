const std = @import("std");
const config = @import("../core/config.zig");
const paths = @import("../core/paths.zig");
const fs = @import("../core/fs.zig");
const bin = @import("../core/bin.zig");
const ui = @import("../core/ui.zig");

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
