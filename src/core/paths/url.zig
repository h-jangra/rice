const std = @import("std");
const Allocator = std.mem.Allocator;
const validate = @import("validate.zig");

pub fn normalizeRepoURL(allocator: Allocator, raw: []const u8) ![]u8 {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len == 0) return allocator.dupe(u8, "");

    const prefixes = [_][]const u8{ "http://", "https://", "ssh://", "git://", "file://", "git@", "/", "./", "../", "~/", ".\\", "..\\", "~\\", "\\" };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, s, p)) return allocator.dupe(u8, s);
    }

    var clean_s = s;
    if (std.mem.startsWith(u8, clean_s, "github.com/")) {
        clean_s = clean_s["github.com/".len..];
    } else if (std.mem.startsWith(u8, clean_s, "www.github.com/")) {
        clean_s = clean_s["www.github.com/".len..];
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

    if (std.mem.startsWith(u8, s, "github.com/") or std.mem.startsWith(u8, s, "www.github.com/")) {
        return std.fmt.allocPrint(allocator, "https://{s}", .{s});
    }

    return allocator.dupe(u8, s);
}

pub fn isURL(s: []const u8) bool {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    const prefixes = [_][]const u8{
        "http://", "https://", "git://", "ssh://", "git@",
        "github.com/", "www.github.com/", "raw.githubusercontent.com/",
        "gitlab.com/", "www.gitlab.com/", "codeberg.org/", "www.codeberg.org/",
    };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, trimmed, p)) return true;
    }
    return false;
}

pub const GitHubURLType = enum { file, directory };

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

    pub fn isDirectory(self: *const GitHubURLInfo) bool { return self.url_type == .directory; }
    pub fn isFile(self: *const GitHubURLInfo) bool { return self.url_type == .file; }
};

fn decodePercentEncoding(allocator: Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            const h1 = std.fmt.charToDigit(s[i + 1], 16) catch null;
            const h2 = std.fmt.charToDigit(s[i + 2], 16) catch null;
            if (h1 != null and h2 != null) {
                try buf.append(allocator, @as(u8, @intCast((h1.? << 4) | h2.?)));
                i += 3;
                continue;
            }
        }
        try buf.append(allocator, s[i]);
        i += 1;
    }
    return allocator.dupe(u8, buf.items);
}

fn buildUrlInfo(allocator: Allocator, repo_url: []u8, branch: []const u8, path_parts: []const []const u8, url_type: GitHubURLType) !*GitHubURLInfo {
    errdefer allocator.free(repo_url);
    var clean_path: []u8 = undefined;
    var base_name: []const u8 = "";

    if (path_parts.len > 0) {
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(allocator);
        for (path_parts, 0..) |part, idx| {
            try joined.appendSlice(allocator, part);
            if (idx + 1 < path_parts.len) try joined.append(allocator, '/');
        }

        const decoded = try decodePercentEncoding(allocator, joined.items);
        defer allocator.free(decoded);

        clean_path = try validate.validateSourcePath(allocator, decoded);
        base_name = std.fs.path.basename(clean_path);
        if (base_name.len == 0 or std.mem.eql(u8, base_name, ".") or std.mem.eql(u8, base_name, "/")) {
            allocator.free(clean_path);
            return error.InvalidGitHubPath;
        }
    } else {
        clean_path = try allocator.dupe(u8, "");
    }
    errdefer allocator.free(clean_path);

    const info = try allocator.create(GitHubURLInfo);
    info.* = .{
        .repo_url = repo_url,
        .branch = try allocator.dupe(u8, branch),
        .path = clean_path,
        .file_path = try allocator.dupe(u8, clean_path),
        .file_name = try allocator.dupe(u8, base_name),
        .url_type = url_type,
    };
    return info;
}

fn stripPrefixes(url: []const u8, prefixes: []const []const u8) ?[]const u8 {
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, url, p)) return url[p.len..];
    }
    return null;
}

pub fn parseGitHubURL(allocator: Allocator, rawURL: []const u8) !*GitHubURLInfo {
    const trimmed = std.mem.trim(u8, rawURL, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyURL;

    var url_str = trimmed;
    if (std.mem.indexOfAny(u8, url_str, "?#")) |idx| url_str = url_str[0..idx];
    url_str = std.mem.trimEnd(u8, url_str, "/");

    // 1. Check raw.githubusercontent.com
    if (stripPrefixes(url_str, &.{ "https://raw.githubusercontent.com/", "http://raw.githubusercontent.com/", "raw.githubusercontent.com/" })) |rest| {
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(allocator);
        var it = std.mem.splitScalar(u8, std.mem.trim(u8, rest, "/"), '/');
        while (it.next()) |p| { if (p.len > 0) try parts.append(allocator, p); }

        if (parts.items.len < 4) return error.InvalidGitHubURL;
        var repo = parts.items[1];
        if (std.mem.endsWith(u8, repo, ".git")) repo = repo[0 .. repo.len - 4];
        if (parts.items[0].len == 0 or repo.len == 0) return error.InvalidGitHubURL;

        const repo_url = try std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}.git", .{ parts.items[0], repo });
        return buildUrlInfo(allocator, repo_url, parts.items[2], parts.items[3..], .file);
    }

    // 2. Check github.com
    if (stripPrefixes(url_str, &.{ "https://github.com/", "http://github.com/", "https://www.github.com/", "http://www.github.com/", "github.com/", "www.github.com/" })) |rest| {
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(allocator);
        var it = std.mem.splitScalar(u8, std.mem.trim(u8, rest, "/"), '/');
        while (it.next()) |p| { if (p.len > 0) try parts.append(allocator, p); }

        if (parts.items.len < 2) return error.InvalidGitHubURL;
        var repo = parts.items[1];
        if (std.mem.endsWith(u8, repo, ".git")) repo = repo[0 .. repo.len - 4];
        if (parts.items[0].len == 0 or repo.len == 0) return error.InvalidGitHubURL;

        const repo_url = try std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}.git", .{ parts.items[0], repo });

        if (parts.items.len == 2) {
            return buildUrlInfo(allocator, repo_url, "", parts.items[2..2], .directory);
        }
        const kind = parts.items[2];
        if (!std.mem.eql(u8, kind, "tree") and !std.mem.eql(u8, kind, "blob") and !std.mem.eql(u8, kind, "raw")) {
            allocator.free(repo_url);
            return error.UnsupportedGitHubURL;
        }
        if (parts.items.len == 3) {
            return buildUrlInfo(allocator, repo_url, "", parts.items[3..3], .directory);
        }
        const utype: GitHubURLType = if (std.mem.eql(u8, kind, "tree")) .directory else .file;
        return buildUrlInfo(allocator, repo_url, parts.items[3], parts.items[4..], utype);
    }

    // 3. Check gitlab.com
    if (stripPrefixes(url_str, &.{ "https://gitlab.com/", "http://gitlab.com/", "https://www.gitlab.com/", "http://www.gitlab.com/", "gitlab.com/", "www.gitlab.com/" })) |rest| {
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(allocator);
        var it = std.mem.splitScalar(u8, std.mem.trim(u8, rest, "/"), '/');
        while (it.next()) |p| { if (p.len > 0) try parts.append(allocator, p); }

        if (parts.items.len < 2) return error.InvalidGitHubURL;
        var repo = parts.items[1];
        if (std.mem.endsWith(u8, repo, ".git")) repo = repo[0 .. repo.len - 4];
        if (parts.items[0].len == 0 or repo.len == 0) return error.InvalidGitHubURL;

        const repo_url = try std.fmt.allocPrint(allocator, "https://gitlab.com/{s}/{s}.git", .{ parts.items[0], repo });

        if (parts.items.len == 2) {
            return buildUrlInfo(allocator, repo_url, "", parts.items[2..2], .directory);
        }
        if (parts.items.len >= 5 and std.mem.eql(u8, parts.items[2], "-")) {
            const kind = parts.items[3];
            if (!std.mem.eql(u8, kind, "tree") and !std.mem.eql(u8, kind, "blob") and !std.mem.eql(u8, kind, "raw")) {
                allocator.free(repo_url);
                return error.UnsupportedGitHubURL;
            }
            const utype: GitHubURLType = if (std.mem.eql(u8, kind, "tree")) .directory else .file;
            return buildUrlInfo(allocator, repo_url, parts.items[4], parts.items[5..], utype);
        }
        allocator.free(repo_url);
        return error.UnsupportedGitHubURL;
    }

    // 4. Check codeberg.org
    if (stripPrefixes(url_str, &.{ "https://codeberg.org/", "http://codeberg.org/", "https://www.codeberg.org/", "http://www.codeberg.org/", "codeberg.org/", "www.codeberg.org/" })) |rest| {
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(allocator);
        var it = std.mem.splitScalar(u8, std.mem.trim(u8, rest, "/"), '/');
        while (it.next()) |p| { if (p.len > 0) try parts.append(allocator, p); }

        if (parts.items.len < 2) return error.InvalidGitHubURL;
        var repo = parts.items[1];
        if (std.mem.endsWith(u8, repo, ".git")) repo = repo[0 .. repo.len - 4];
        if (parts.items[0].len == 0 or repo.len == 0) return error.InvalidGitHubURL;

        const repo_url = try std.fmt.allocPrint(allocator, "https://codeberg.org/{s}/{s}.git", .{ parts.items[0], repo });

        if (parts.items.len == 2) {
            return buildUrlInfo(allocator, repo_url, "", parts.items[2..2], .directory);
        }
        if (parts.items.len >= 5 and (std.mem.eql(u8, parts.items[2], "src") or std.mem.eql(u8, parts.items[2], "raw")) and std.mem.eql(u8, parts.items[3], "branch")) {
            const utype: GitHubURLType = if (std.mem.eql(u8, parts.items[2], "raw")) .file else .directory;
            return buildUrlInfo(allocator, repo_url, parts.items[4], parts.items[5..], utype);
        }
        allocator.free(repo_url);
        return error.UnsupportedGitHubURL;
    }

    return error.UnsupportedURL;
}

