const std = @import("std");
const Allocator = std.mem.Allocator;
const validate = @import("validate.zig");

pub fn normalizeRepoURL(allocator: Allocator, raw: []const u8) ![]u8 {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len == 0) return try allocator.dupe(u8, "");

    const prefixes = [_][]const u8{ "http://", "https://", "ssh://", "git://", "file://", "git@" };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, s, p)) return try allocator.dupe(u8, s);
    }

    const path_prefixes = [_][]const u8{ "/", "./", "../", "~/", ".\\", "..\\", "~\\", "\\" };
    for (path_prefixes) |p| {
        if (std.mem.startsWith(u8, s, p)) return try allocator.dupe(u8, s);
    }

    var clean_s = s;
    if (std.mem.startsWith(u8, clean_s, "github.com/")) {
        clean_s = clean_s["github.com/".len..];
    }
    const trimmed_path = std.mem.trim(u8, clean_s, "/");
    var it = std.mem.splitScalar(u8, trimmed_path, '/');
    const owner = it.next();
    const repo = it.next();
    const extra = it.next();

    if (owner != null and repo != null and extra == null and
        owner.?.len > 0 and repo.?.len > 0 and
        !std.mem.eql(u8, owner.?, ".") and !std.mem.eql(u8, owner.?, "..") and
        std.mem.indexOfAny(u8, owner.?, " \t\r\n\\:") == null and
        std.mem.indexOfAny(u8, repo.?, " \t\r\n\\:") == null)
    {
        var repo_clean = repo.?;
        if (std.mem.endsWith(u8, repo_clean, ".git")) {
            repo_clean = repo_clean[0 .. repo_clean.len - 4];
        }
        return std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}.git", .{ owner.?, repo_clean });
    }

    if (std.mem.startsWith(u8, s, "github.com/")) {
        return std.fmt.allocPrint(allocator, "https://{s}", .{s});
    }

    return try allocator.dupe(u8, s);
}

pub fn isURL(s: []const u8) bool {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    return std.mem.startsWith(u8, trimmed, "http://") or
        std.mem.startsWith(u8, trimmed, "https://") or
        std.mem.startsWith(u8, trimmed, "github.com/");
}

pub const GitHubURLType = enum {
    file,
    directory,
};

pub const GitHubURLInfo = struct {
    repo_url: []u8,
    branch: []u8,
    path: []u8,
    file_path: []u8,
    file_name: []u8,
    url_type: GitHubURLType,

    pub fn deinit(self: *GitHubURLInfo, allocator: Allocator) void {
        allocator.free(self.repo_url);
        allocator.free(self.branch);
        allocator.free(self.path);
        allocator.free(self.file_path);
        allocator.free(self.file_name);
    }

    pub fn isDirectory(self: *const GitHubURLInfo) bool {
        return self.url_type == .directory;
    }

    pub fn isFile(self: *const GitHubURLInfo) bool {
        return self.url_type == .file;
    }
};

pub fn parseGitHubURL(allocator: Allocator, rawURL: []const u8) !*GitHubURLInfo {
    const trimmed = std.mem.trim(u8, rawURL, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyURL;

    var url_str = trimmed;
    var allocated_url: ?[]u8 = null;
    defer if (allocated_url) |u| allocator.free(u);

    if (std.mem.startsWith(u8, url_str, "github.com/")) {
        allocated_url = try std.fmt.allocPrint(allocator, "https://{s}", .{url_str});
        url_str = allocated_url.?;
    }

    const prefixes = [_][]const u8{ "https://github.com/", "http://github.com/", "https://www.github.com/", "http://www.github.com/" };
    var path_part: ?[]const u8 = null;
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, url_str, p)) {
            path_part = url_str[p.len..];
            break;
        }
    }
    if (path_part == null) return error.UnsupportedURL;

    const trimmed_parts = std.mem.trim(u8, path_part.?, "/");
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    var it = std.mem.splitScalar(u8, trimmed_parts, '/');
    while (it.next()) |p| {
        if (p.len > 0) try parts.append(allocator, p);
    }

    if (parts.items.len < 5) return error.InvalidGitHubURL;

    const owner = parts.items[0];
    var repo = parts.items[1];
    if (std.mem.endsWith(u8, repo, ".git")) {
        repo = repo[0 .. repo.len - 4];
    }
    const kind = parts.items[2];
    const branch = parts.items[3];

    if (owner.len == 0 or repo.len == 0 or branch.len == 0) return error.InvalidGitHubURL;

    const url_type: GitHubURLType = if (std.mem.eql(u8, kind, "blob"))
        .file
    else if (std.mem.eql(u8, kind, "tree"))
        .directory
    else
        return error.UnsupportedGitHubURL;

    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(allocator);

    for (parts.items[4..], 0..) |part, idx| {
        try path_buf.appendSlice(allocator, part);
        if (idx + 1 < parts.items[4..].len) try path_buf.append(allocator, '/');
    }

    const clean_source = try validate.validateSourcePath(allocator, path_buf.items);
    errdefer allocator.free(clean_source);

    const base_name = std.fs.path.basename(clean_source);
    if (base_name.len == 0 or std.mem.eql(u8, base_name, ".") or std.mem.eql(u8, base_name, "/")) {
        allocator.free(clean_source);
        return error.InvalidGitHubPath;
    }

    const info = try allocator.create(GitHubURLInfo);
    info.* = .{
        .repo_url = try std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}.git", .{ owner, repo }),
        .branch = try allocator.dupe(u8, branch),
        .path = clean_source,
        .file_path = try allocator.dupe(u8, clean_source),
        .file_name = try allocator.dupe(u8, base_name),
        .url_type = url_type,
    };
    return info;
}
