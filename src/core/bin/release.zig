const std = @import("std");
const Allocator = std.mem.Allocator;
const paths = @import("../paths/mod.zig");

pub fn matchAsset(name: []const u8, target_os: []const u8, target_arch: []const u8) bool {
    var lower_buf: [256]u8 = undefined;
    const n = if (name.len <= 256) blk: {
        for (name, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
        break :blk lower_buf[0..name.len];
    } else name;

    const ignored_exts = [_][]const u8{ ".sha256", ".sha512", ".sig", ".asc", ".txt", ".md", ".deb", ".rpm", ".apk" };
    for (ignored_exts) |ext| {
        if (std.mem.endsWith(u8, n, ext)) return false;
    }

    if (std.mem.indexOf(u8, n, "checksum") != null or std.mem.indexOf(u8, n, "source") != null) {
        return false;
    }

    const os_match = (std.mem.indexOf(u8, n, target_os) != null) or
        (std.mem.eql(u8, target_os, "darwin") and std.mem.indexOf(u8, n, "macos") != null);
    if (!os_match) return false;

    const arch_match = (std.mem.indexOf(u8, n, target_arch) != null) or
        (std.mem.eql(u8, target_arch, "amd64") and std.mem.indexOf(u8, n, "x86_64") != null) or
        (std.mem.eql(u8, target_arch, "arm64") and std.mem.indexOf(u8, n, "aarch64") != null);

    return arch_match;
}

pub const GitHubReleaseAsset = struct {
    name: []u8,
    download_url: []u8,

    pub fn deinit(self: *GitHubReleaseAsset, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.download_url);
    }
};

pub fn fetchGitHubReleaseAsset(allocator: Allocator, owner: []const u8, repo: []const u8, tag: []const u8, target_os: []const u8, target_arch: []const u8) !GitHubReleaseAsset {
    const api_url = if (tag.len > 0)
        try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/{s}/releases/tags/{s}", .{ owner, repo, tag })
    else
        try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/{s}/releases/latest", .{ owner, repo });
    defer allocator.free(api_url);

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.appendSlice(allocator, &[_][]const u8{ "curl", "-fsSL", "-H", "Accept: application/vnd.github.v3+json", "-H", "User-Agent: rice-bin" });

    var token_header: ?[]u8 = null;
    defer if (token_header) |th| allocator.free(th);
    if (std.process.Environ.getAlloc(paths.getProcessEnviron(), allocator, "GITHUB_TOKEN")) |tok| {
        defer allocator.free(tok);
        if (tok.len > 0) {
            token_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{tok});
            try args.appendSlice(allocator, &[_][]const u8{ "-H", token_header.? });
        }
    } else |_| {}

    try args.append(allocator, api_url);

    const res = try std.process.run(allocator, paths.getProcessIo(), .{
        .argv = args.items,
    });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    if (res.term != .exited or res.term.exited != 0) {
        std.debug.print("failed to fetch release from GitHub for {s}/{s}: {s}\n", .{ owner, repo, res.stderr });
        return error.GitHubApiFailed;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, res.stdout, .{}) catch return error.GitHubJsonParseFailed;
    defer parsed.deinit();

    if (parsed.value != .object) return error.GitHubJsonParseFailed;
    const assets_val = parsed.value.object.get("assets") orelse return error.NoAssetsInRelease;
    if (assets_val != .array) return error.NoAssetsInRelease;

    for (assets_val.array.items) |item| {
        if (item != .object) continue;
        const name_val = item.object.get("name") orelse continue;
        const url_val = item.object.get("browser_download_url") orelse continue;
        if (name_val != .string or url_val != .string) continue;

        if (matchAsset(name_val.string, target_os, target_arch)) {
            return GitHubReleaseAsset{
                .name = try allocator.dupe(u8, name_val.string),
                .download_url = try allocator.dupe(u8, url_val.string),
            };
        }
    }

    return error.NoMatchingAssetFound;
}
