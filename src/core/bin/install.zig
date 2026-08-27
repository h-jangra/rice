const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const paths = @import("../paths/mod.zig");
const config = @import("../config.zig");
const fs = @import("../fs.zig");
const source = @import("source.zig");
const release = @import("release.zig");
const extract = @import("extract.zig");

pub const InstallBinOptions = struct {
    source: []const u8 = "",
    tag: []const u8 = "",
    name: []const u8 = "",
    save: bool = false,
};

pub fn installBinary(allocator: Allocator, opts: InstallBinOptions, homeDir: []const u8) ![]u8 {
    var src = source.parseBinarySource(allocator, opts.source, homeDir) catch |err| {
        if (err == error.LocalFileNotFound) {
            std.debug.print("Error: local file \"{s}\" not found.\n", .{opts.source});
        } else if (err == error.LocalPathIsDirectory) {
            std.debug.print("Error: local path \"{s}\" is a directory, not an executable file or archive.\n", .{opts.source});
        } else if (err == error.InvalidSource) {
            std.debug.print("Error: invalid binary source \"{s}\". Expected a GitHub repository (e.g. user/repo), URL, or local executable path.\n", .{opts.source});
        } else {
            std.debug.print("Error: failed to parse source \"{s}\": {s}\n", .{ opts.source, @errorName(err) });
        }
        return err;
    };
    defer src.deinit(allocator);

    const tmp_dir_path = try std.fmt.allocPrint(allocator, "/tmp/rice-bin-{d}", .{std.time.milliTimestamp()});
    defer allocator.free(tmp_dir_path);
    try std.fs.cwd().makePath(tmp_dir_path);
    defer std.fs.deleteTreeAbsolute(tmp_dir_path) catch {};

    var asset_name: []u8 = undefined;
    var repo_name: []u8 = undefined;
    var data: []u8 = undefined;

    const goos = if (builtin.os.tag == .linux) "linux" else if (builtin.os.tag == .macos) "darwin" else if (builtin.os.tag == .windows) "windows" else "linux";
    const goarch = if (builtin.cpu.arch == .x86_64) "amd64" else if (builtin.cpu.arch == .aarch64) "arm64" else "amd64";

    switch (src.source_type) {
        .local => {
            asset_name = try allocator.dupe(u8, std.fs.path.basename(src.path));
            repo_name = try allocator.dupe(u8, "");
            const f = std.fs.openFileAbsolute(src.path, .{}) catch |err| {
                if (err == error.IsDir) {
                    std.debug.print("Error: path is a directory, expected executable file or archive: {s}\n", .{src.path});
                } else if (err == error.FileNotFound) {
                    std.debug.print("Error: local file not found: {s}\n", .{src.path});
                } else {
                    std.debug.print("Error opening local file {s}: {s}\n", .{ src.path, @errorName(err) });
                }
                return err;
            };
            defer f.close();
            data = try f.readToEndAlloc(allocator, 100 * 1024 * 1024);
        },
        .url => {
            var url_clean = src.url;
            if (std.mem.indexOfScalar(u8, url_clean, '?')) |idx| {
                url_clean = url_clean[0..idx];
            }
            asset_name = try allocator.dupe(u8, std.fs.path.basename(url_clean));
            repo_name = try allocator.dupe(u8, "");
            const dl_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp_dir_path, "download" });
            defer allocator.free(dl_path);

            std.debug.print("Downloading...\n", .{});
            fs.downloadWithCurl(allocator, src.url, dl_path) catch |err| {
                std.debug.print("Error: failed to download binary from {s}\n", .{src.url});
                return err;
            };
            const f = try std.fs.openFileAbsolute(dl_path, .{});
            defer f.close();
            data = try f.readToEndAlloc(allocator, 100 * 1024 * 1024);
        },
        .github => {
            repo_name = try allocator.dupe(u8, src.repo);
            var gh_asset = release.fetchGitHubReleaseAsset(allocator, src.owner, src.repo, opts.tag, goos, goarch) catch |err| {
                if (err == error.NoMatchingAssetFound) {
                    std.debug.print("Error: no matching release asset found for {s}/{s} on {s}/{s}.\n", .{ src.owner, src.repo, goos, goarch });
                } else if (err == error.NoAssetsInRelease) {
                    std.debug.print("Error: release contains no download assets for {s}/{s}.\n", .{ src.owner, src.repo });
                } else if (err == error.GitHubApiFailed) {
                    // error already printed by fetchGitHubReleaseAsset
                } else {
                    std.debug.print("Error: failed to fetch release asset for {s}/{s}: {s}\n", .{ src.owner, src.repo, @errorName(err) });
                }
                return err;
            };
            defer gh_asset.deinit(allocator);

            asset_name = try allocator.dupe(u8, gh_asset.name);
            const dl_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp_dir_path, "download" });
            defer allocator.free(dl_path);

            std.debug.print("Downloading...\n", .{});
            fs.downloadWithCurl(allocator, gh_asset.download_url, dl_path) catch |err| {
                std.debug.print("Error: failed to download asset from {s}\n", .{gh_asset.download_url});
                return err;
            };
            const f = try std.fs.openFileAbsolute(dl_path, .{});
            defer f.close();
            data = try f.readToEndAlloc(allocator, 100 * 1024 * 1024);
        },
    }
    defer allocator.free(asset_name);
    defer allocator.free(repo_name);
    defer allocator.free(data);

    if (fs.isHTMLContent(data)) {
        std.debug.print("Error: downloaded content is HTML, not an executable binary or archive.\n", .{});
        return error.DownloadedFileIsHTML;
    }

    var binary_path: []u8 = undefined;

    if (fs.isArchive(asset_name) or fs.isArchiveData(data)) {
        std.debug.print("Finding executable...\n", .{});
        const extract_dir = try std.fs.path.join(allocator, &[_][]const u8{ tmp_dir_path, "extracted" });
        defer allocator.free(extract_dir);
        try std.fs.cwd().makePath(extract_dir);
        fs.extractArchive(allocator, data, asset_name, extract_dir) catch |err| {
            std.debug.print("Error: failed to extract archive {s}: {s}\n", .{ asset_name, @errorName(err) });
            return err;
        };

        if (extract.findExecutable(allocator, extract_dir, opts.name, repo_name)) |bp| {
            binary_path = bp;
        } else |err| {
            if (err == error.MultipleBinariesFound) {
                // Interactive selection
                var dir = try std.fs.openDirAbsolute(extract_dir, .{ .iterate = true });
                defer dir.close();
                var walker = try dir.walk(allocator);
                defer walker.deinit();

                var cands = std.ArrayList([]const u8).init(allocator);
                defer {
                    for (cands.items) |c| allocator.free(c);
                    cands.deinit();
                }

                while (try walker.next()) |entry| {
                    if (!extract.isIgnoredCandidate(entry.path, entry.kind == .directory, std.fs.path.basename(entry.path))) {
                        try cands.append(try allocator.dupe(u8, entry.path));
                    }
                }

                const sel = extract.promptBinarySelection(allocator, asset_name, cands.items) catch |perr| {
                    std.debug.print("Error: no executable selected: {s}\n", .{@errorName(perr)});
                    return perr;
                };
                binary_path = try std.fs.path.join(allocator, &[_][]const u8{ extract_dir, sel });
            } else if (err == error.NoExecutableFoundInArchive) {
                std.debug.print("Error: no executable binary found in archive {s}.\n", .{asset_name});
                return err;
            } else {
                std.debug.print("Error finding executable in archive: {s}\n", .{@errorName(err)});
                return err;
            }
        }
    } else {
        if (extract.isIgnoredCandidate(asset_name, false, std.fs.path.basename(asset_name))) {
            std.debug.print("Error: source file \"{s}\" is not an executable binary or archive.\n", .{asset_name});
            return error.NotAnExecutable;
        }
        var raw_name = opts.name;
        if (raw_name.len == 0) raw_name = repo_name;
        if (raw_name.len == 0) raw_name = asset_name;
        binary_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp_dir_path, raw_name });
        const f = try std.fs.createFileAbsolute(binary_path, .{ .mode = 0o755 });
        try f.writeAll(data);
        f.close();
    }
    defer allocator.free(binary_path);

    // Validate that the resolved binary is actually an executable / suitable binary
    const bin_f = try std.fs.openFileAbsolute(binary_path, .{});
    defer bin_f.close();
    const bin_data = try bin_f.readToEndAlloc(allocator, 100 * 1024 * 1024);
    defer allocator.free(bin_data);

    if (bin_data.len == 0) {
        std.debug.print("Error: target binary file is empty.\n", .{});
        return error.EmptyBinaryFile;
    }

    if (fs.isHTMLContent(bin_data)) {
        std.debug.print("Error: binary content is HTML.\n", .{});
        return error.DownloadedFileIsHTML;
    }

    const is_candidate_ignored = extract.isIgnoredCandidate(binary_path, false, std.fs.path.basename(binary_path));
    var is_executable = extract.isExecutableBinary(bin_data);
    if (!is_executable) {
        if (bin_f.stat()) |st| {
            if ((st.mode & 0o111) != 0 and !is_candidate_ignored) {
                is_executable = true;
            }
        } else |_| {}
    }

    if (!is_executable) {
        std.debug.print("Error: file \"{s}\" is not an executable binary.\n", .{std.fs.path.basename(binary_path)});
        return error.NotAnExecutable;
    }

    var bin_name: []const u8 = opts.name;
    if (bin_name.len == 0) {
        bin_name = std.fs.path.basename(binary_path);
        if (builtin.os.tag != .windows and std.mem.endsWith(u8, bin_name, ".exe")) {
            bin_name = bin_name[0 .. bin_name.len - 4];
        }
        if (bin_name.len == 0 and repo_name.len > 0) {
            bin_name = repo_name;
        }
    }

    paths.validateBinaryName(bin_name) catch |err| {
        std.debug.print("Error: invalid binary name \"{s}\": {s}\n", .{ bin_name, @errorName(err) });
        return err;
    };

    std.debug.print("Installing...\n", .{});

    const bin_dir = try std.fs.path.join(allocator, &[_][]const u8{ homeDir, ".local", "bin" });
    defer allocator.free(bin_dir);
    try std.fs.cwd().makePath(bin_dir);

    const final_path = try std.fs.path.join(allocator, &[_][]const u8{ bin_dir, bin_name });
    errdefer allocator.free(final_path);

    const staging_path = try std.fmt.allocPrint(allocator, "{s}/.rice-tmp-{d}", .{ bin_dir, std.time.milliTimestamp() });
    defer allocator.free(staging_path);

    const st_f = try std.fs.createFileAbsolute(staging_path, .{ .mode = 0o755 });
    try st_f.writeAll(bin_data);
    st_f.close();
    defer std.fs.deleteFileAbsolute(staging_path) catch {};

    std.fs.deleteFileAbsolute(final_path) catch {};
    std.fs.renameAbsolute(staging_path, final_path) catch {
        try fs.copyFile(staging_path, final_path);
    };

    // Chmod 0755 on platforms that support executable bit
    if (builtin.os.tag != .windows) {
        const final_f = try std.fs.openFileAbsolute(final_path, .{});
        try final_f.chmod(0o755);
        final_f.close();
    }

    if (opts.save) {
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

        _ = try cfg.addBinary(bin_name, opts.source);
        _ = config.saveConfig(allocator, ini_path, cfg) catch {};
    }

    return final_path;
}
