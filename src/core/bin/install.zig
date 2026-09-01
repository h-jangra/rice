const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const paths = @import("../paths/mod.zig");
const config = @import("../config.zig");
const fs = @import("../fs.zig");
const source = @import("source.zig");
const release = @import("release.zig");
const extract = @import("extract.zig");
const ui = @import("../ui.zig");

pub const InstallBinOptions = struct {
    source: []const u8 = "",
    tag: []const u8 = "",
    name: []const u8 = "",
    dest: []const u8 = "",
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

    const tmp_dir_path = try std.fmt.allocPrint(allocator, "/tmp/rice-bin-{d}", .{fs.getMilliTimestamp()});
    defer allocator.free(tmp_dir_path);
    try fs.makePath(tmp_dir_path);
    defer fs.deleteTreeAbsolute(tmp_dir_path) catch {};

    var asset_name: []u8 = undefined;
    var repo_name: []u8 = undefined;
    var data: []u8 = undefined;

    const goos = if (builtin.os.tag == .linux) "linux" else if (builtin.os.tag == .macos) "darwin" else if (builtin.os.tag == .windows) "windows" else "linux";
    const goarch = if (builtin.cpu.arch == .x86_64) "amd64" else if (builtin.cpu.arch == .aarch64) "arm64" else "amd64";

    switch (src.source_type) {
        .local => {
            asset_name = try allocator.dupe(u8, std.fs.path.basename(src.path));
            repo_name = try allocator.dupe(u8, "");
            const f = fs.openFileAbsolute(src.path, .{}) catch |err| {
                if (err == error.IsDir) {
                    std.debug.print("Error: path is a directory, expected executable file or archive: {s}\n", .{src.path});
                } else if (err == error.FileNotFound) {
                    std.debug.print("Error: local file not found: {s}\n", .{src.path});
                } else {
                    std.debug.print("Error opening local file {s}: {s}\n", .{ src.path, @errorName(err) });
                }
                return err;
            };
            f.close(paths.getProcessIo());
            data = try std.Io.Dir.cwd().readFileAlloc(paths.getProcessIo(), src.path, allocator, .limited(100 * 1024 * 1024));
        },
        .url => {
            var url_clean = src.url;
            if (std.mem.indexOfScalar(u8, url_clean, '?')) |idx| url_clean = url_clean[0..idx];
            asset_name = try allocator.dupe(u8, std.fs.path.basename(url_clean));
            repo_name = try allocator.dupe(u8, "");
            const dl_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, "download" });
            defer allocator.free(dl_path);

            {
                const sp_msg = try std.fmt.allocPrint(allocator, "Downloading {s}...", .{asset_name});
                defer allocator.free(sp_msg);
                const spinner = try ui.Spinner.start(allocator, sp_msg);
                defer spinner.stop();

                fs.downloadWithCurl(allocator, src.url, dl_path) catch |err| {
                    std.debug.print("Error: failed to download binary from {s}\n", .{src.url});
                    return err;
                };
            }
            data = try std.Io.Dir.cwd().readFileAlloc(paths.getProcessIo(), dl_path, allocator, .limited(100 * 1024 * 1024));
        },
        .github => {
            repo_name = try allocator.dupe(u8, src.repo);

            var gh_asset = blk: {
                const fetch_msg = try std.fmt.allocPrint(allocator, "Fetching release info for {s}/{s}...", .{ src.owner, src.repo });
                defer allocator.free(fetch_msg);
                const fetch_sp = try ui.Spinner.start(allocator, fetch_msg);
                defer fetch_sp.stop();

                break :blk release.fetchGitHubReleaseAsset(allocator, src.owner, src.repo, opts.tag, goos, goarch) catch |err| {
                    if (err == error.NoMatchingAssetFound) {
                        std.debug.print("Error: no matching release asset found for {s}/{s} on {s}/{s}.\n", .{ src.owner, src.repo, goos, goarch });
                    } else if (err == error.NoAssetsInRelease) {
                        std.debug.print("Error: release contains no download assets for {s}/{s}.\n", .{ src.owner, src.repo });
                    } else if (err != error.GitHubApiFailed) {
                        std.debug.print("Error: failed to fetch release asset for {s}/{s}: {s}\n", .{ src.owner, src.repo, @errorName(err) });
                    }
                    return err;
                };
            };
            defer gh_asset.deinit(allocator);

            asset_name = try allocator.dupe(u8, gh_asset.name);
            const dl_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, "download" });
            defer allocator.free(dl_path);

            {
                const dl_msg = try std.fmt.allocPrint(allocator, "Downloading {s}...", .{gh_asset.name});
                defer allocator.free(dl_msg);
                const dl_sp = try ui.Spinner.start(allocator, dl_msg);
                defer dl_sp.stop();

                fs.downloadWithCurl(allocator, gh_asset.download_url, dl_path) catch |err| {
                    std.debug.print("Error: failed to download asset from {s}\n", .{gh_asset.download_url});
                    return err;
                };
            }
            data = try std.Io.Dir.cwd().readFileAlloc(paths.getProcessIo(), dl_path, allocator, .limited(100 * 1024 * 1024));
        },
    }
    defer {
        allocator.free(asset_name);
        allocator.free(repo_name);
        allocator.free(data);
    }

    if (fs.isHTMLContent(data)) {
        std.debug.print("Error: downloaded content is HTML, not an executable binary or archive.\n", .{});
        return error.DownloadedFileIsHTML;
    }

    var binary_path: []u8 = undefined;

    if (fs.isArchive(asset_name) or fs.isArchiveData(data)) {
        const extract_dir = try std.fs.path.join(allocator, &.{ tmp_dir_path, "extracted" });
        defer allocator.free(extract_dir);
        try fs.makePath(extract_dir);

        {
            const ext_msg = try std.fmt.allocPrint(allocator, "Extracting {s}...", .{asset_name});
            defer allocator.free(ext_msg);
            const ext_sp = try ui.Spinner.start(allocator, ext_msg);
            defer ext_sp.stop();

            fs.extractArchive(allocator, data, asset_name, extract_dir) catch |err| {
                std.debug.print("Error: failed to extract archive {s}: {s}\n", .{ asset_name, @errorName(err) });
                return err;
            };
        }

        if (extract.findExecutable(allocator, extract_dir, opts.name, repo_name)) |bp| {
            binary_path = bp;
        } else |err| {
            if (err == error.MultipleBinariesFound) {
                var cands: std.ArrayList([]const u8) = .empty;
                defer {
                    for (cands.items) |c| allocator.free(c);
                    cands.deinit(allocator);
                }
                var extract_cand_dir = try fs.openDirAbsolute(extract_dir, .{ .iterate = true });
                defer extract_cand_dir.close(paths.getProcessIo());
                var it = extract_cand_dir.iterate();
                while (try it.next(paths.getProcessIo())) |entry| {
                    if (!extract.isIgnoredCandidate(entry.name, entry.kind == .directory, entry.name)) {
                        try cands.append(allocator, try allocator.dupe(u8, entry.name));
                    }
                }

                const sel = extract.promptBinarySelection(allocator, asset_name, cands.items) catch |perr| {
                    std.debug.print("Error: no executable selected: {s}\n", .{@errorName(perr)});
                    return perr;
                };
                binary_path = try std.fs.path.join(allocator, &.{ extract_dir, sel });
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
        binary_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, raw_name });
        const f = try fs.createFileAbsolute(binary_path, .{ .permissions = @enumFromInt(0o755) });
        try f.writePositionalAll(paths.getProcessIo(), data, 0);
        f.close(paths.getProcessIo());
    }
    defer allocator.free(binary_path);

    const bin_f = try fs.openFileAbsolute(binary_path, .{});
    defer bin_f.close(paths.getProcessIo());
    const bin_data = try std.Io.Dir.cwd().readFileAlloc(paths.getProcessIo(), binary_path, allocator, .limited(100 * 1024 * 1024));
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
        if (bin_f.stat(paths.getProcessIo())) |st| {
            if ((@intFromEnum(st.permissions) & 0o111) != 0 and !is_candidate_ignored) {
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

    var final_path: []u8 = undefined;
    errdefer allocator.free(final_path);

    if (opts.dest.len > 0) {
        const dest_abs = paths.resolveUserPath(allocator, homeDir, opts.dest) catch |err| {
            std.debug.print("Error resolving destination path \"{s}\": {s}\n", .{ opts.dest, @errorName(err) });
            return err;
        };
        defer allocator.free(dest_abs);

        var is_dir = false;
        if (std.mem.endsWith(u8, opts.dest, "/") or std.mem.endsWith(u8, opts.dest, "\\") or
            std.mem.eql(u8, opts.dest, ".") or std.mem.eql(u8, opts.dest, "..") or
            std.mem.eql(u8, opts.dest, "./") or std.mem.eql(u8, opts.dest, ".\\") or
            std.mem.eql(u8, opts.dest, "../") or std.mem.eql(u8, opts.dest, "..\\"))
        {
            is_dir = true;
        } else if (fs.isDirAbsolute(dest_abs)) {
            is_dir = true;
        }

        if (is_dir) {
            final_path = try std.fs.path.join(allocator, &.{ dest_abs, bin_name });
        } else {
            final_path = try allocator.dupe(u8, dest_abs);
            bin_name = std.fs.path.basename(final_path);
            if (builtin.os.tag != .windows and std.mem.endsWith(u8, bin_name, ".exe")) {
                bin_name = bin_name[0 .. bin_name.len - 4];
            }
        }
    } else {
        const bin_dir = try std.fs.path.join(allocator, &.{ homeDir, ".local", "bin" });
        defer allocator.free(bin_dir);
        final_path = try std.fs.path.join(allocator, &.{ bin_dir, bin_name });
    }

    paths.validateBinaryName(bin_name) catch |err| {
        std.debug.print("Error: invalid binary name \"{s}\": {s}\n", .{ bin_name, @errorName(err) });
        return err;
    };

    std.debug.print("Installing...\n", .{});

    const parent_dir = std.fs.path.dirname(final_path) orelse ".";
    var use_sudo = false;

    fs.makePath(parent_dir) catch |err| {
        if ((err == error.AccessDenied or err == error.PermissionDenied) and builtin.os.tag != .windows) {
            const prompt = try std.fmt.allocPrint(allocator, "Permission denied creating directory '{s}'. Elevate with sudo? [y/N]: ", .{parent_dir});
            defer allocator.free(prompt);
            if (fs.promptConfirm(prompt)) {
                use_sudo = true;
            } else {
                std.debug.print("Installation cancelled.\n", .{});
                return error.PermissionDenied;
            }
        } else {
            std.debug.print("Error creating directory '{s}': {s}\n", .{ parent_dir, @errorName(err) });
            return err;
        }
    };

    if (use_sudo) {
        fs.sudoInstallPath(allocator, binary_path, final_path, true) catch |err| {
            std.debug.print("Error installing binary with sudo: {s}\n", .{@errorName(err)});
            return err;
        };
    } else {
        const staging_path = try std.fmt.allocPrint(allocator, "{s}/.rice-tmp-{d}", .{ parent_dir, fs.getMilliTimestamp() });
        defer allocator.free(staging_path);

        var st_f_opt: ?std.Io.File = null;
        if (fs.createFileAbsolute(staging_path, .{ .permissions = @enumFromInt(0o755) })) |f| {
            st_f_opt = f;
        } else |err| {
            if ((err == error.AccessDenied or err == error.PermissionDenied) and builtin.os.tag != .windows) {
                const prompt = try std.fmt.allocPrint(allocator, "Permission denied writing to '{s}'. Elevate with sudo? [y/N]: ", .{final_path});
                defer allocator.free(prompt);
                if (fs.promptConfirm(prompt)) {
                    fs.sudoInstallPath(allocator, binary_path, final_path, true) catch |serr| {
                        std.debug.print("Error installing binary with sudo: {s}\n", .{@errorName(serr)});
                        return serr;
                    };
                    use_sudo = true;
                } else {
                    std.debug.print("Installation cancelled.\n", .{});
                    return error.PermissionDenied;
                }
            } else {
                std.debug.print("Error creating temporary file in '{s}': {s}\n", .{ parent_dir, @errorName(err) });
                return err;
            }
        }

        if (st_f_opt) |st_f| {
            var file = st_f;
            try file.writePositionalAll(paths.getProcessIo(), bin_data, 0);
            file.close(paths.getProcessIo());
            defer fs.deleteFileAbsolute(staging_path) catch {};

            fs.deleteFileAbsolute(final_path) catch {};
            fs.renameAbsolute(staging_path, final_path) catch {
                fs.copyFile(staging_path, final_path) catch |err| {
                    if ((err == error.AccessDenied or err == error.PermissionDenied) and builtin.os.tag != .windows) {
                        const prompt = try std.fmt.allocPrint(allocator, "Permission denied installing binary to '{s}'. Elevate with sudo? [y/N]: ", .{final_path});
                        defer allocator.free(prompt);
                        if (fs.promptConfirm(prompt)) {
                            fs.sudoInstallPath(allocator, binary_path, final_path, true) catch |serr| {
                                std.debug.print("Error installing binary with sudo: {s}\n", .{@errorName(serr)});
                                return serr;
                            };
                            use_sudo = true;
                        } else {
                            std.debug.print("Installation cancelled.\n", .{});
                            return error.PermissionDenied;
                        }
                    } else {
                        std.debug.print("Error installing binary to '{s}': {s}\n", .{ final_path, @errorName(err) });
                        return err;
                    }
                };
            };

            if (builtin.os.tag != .windows and !use_sudo) {
                if (fs.openFileAbsolute(final_path, .{})) |final_f| {
                    final_f.setPermissions(paths.getProcessIo(), @enumFromInt(0o755)) catch {};
                    final_f.close(paths.getProcessIo());
                } else |_| {}
            }
        }
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

