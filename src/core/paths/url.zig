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

    return try allocator.dupe(u8, s);
}

pub fn isURL(s: []const u8) bool {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    return std.mem.startsWith(u8, trimmed, "http://") or
        std.mem.startsWith(u8, trimmed, "https://") or
        std.mem.startsWith(u8, trimmed, "git://") or
        std.mem.startsWith(u8, trimmed, "ssh://") or
        std.mem.startsWith(u8, trimmed, "git@") or
        std.mem.startsWith(u8, trimmed, "github.com/") or
        std.mem.startsWith(u8, trimmed, "www.github.com/") or
        std.mem.startsWith(u8, trimmed, "raw.githubusercontent.com/") or
        std.mem.startsWith(u8, trimmed, "gitlab.com/") or
        std.mem.startsWith(u8, trimmed, "www.gitlab.com/") or
        std.mem.startsWith(u8, trimmed, "codeberg.org/") or
        std.mem.startsWith(u8, trimmed, "www.codeberg.org/");
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

fn decodePercentEncoding(allocator: Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            const h1 = std.fmt.charToDigit(s[i + 1], 16) catch null;
            const h2 = std.fmt.charToDigit(s[i + 2], 16) catch null;
            if (h1 != null and h2 != null) {
                const byte: u8 = @intCast((h1.? << 4) | h2.?);
                try buf.append(allocator, byte);
                i += 3;
                continue;
            }
        }
        try buf.append(allocator, s[i]);
        i += 1;
    }
    return try allocator.dupe(u8, buf.items);
}

pub fn parseGitHubURL(allocator: Allocator, rawURL: []const u8) !*GitHubURLInfo {
    const trimmed = std.mem.trim(u8, rawURL, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyURL;

    var url_str = trimmed;
    if (std.mem.indexOfAny(u8, url_str, "?#")) |idx| {
        url_str = url_str[0..idx];
    }
    url_str = std.mem.trimEnd(u8, url_str, "/");

    var allocated_url: ?[]u8 = null;
    defer if (allocated_url) |u| allocator.free(u);

    if (std.mem.startsWith(u8, url_str, "github.com/") or
        std.mem.startsWith(u8, url_str, "www.github.com/") or
        std.mem.startsWith(u8, url_str, "raw.githubusercontent.com/") or
        std.mem.startsWith(u8, url_str, "gitlab.com/") or
        std.mem.startsWith(u8, url_str, "www.gitlab.com/") or
        std.mem.startsWith(u8, url_str, "codeberg.org/") or
        std.mem.startsWith(u8, url_str, "www.codeberg.org/"))
    {
        allocated_url = try std.fmt.allocPrint(allocator, "https://{s}", .{url_str});
        url_str = allocated_url.?;
    }

    // 1. Check raw.githubusercontent.com
    const raw_prefixes = [_][]const u8{
        "https://raw.githubusercontent.com/",
        "http://raw.githubusercontent.com/",
    };
    for (raw_prefixes) |p| {
        if (std.mem.startsWith(u8, url_str, p)) {
            const path_part = url_str[p.len..];
            const trimmed_parts = std.mem.trim(u8, path_part, "/");
            var parts: std.ArrayList([]const u8) = .empty;
            defer parts.deinit(allocator);

            var it = std.mem.splitScalar(u8, trimmed_parts, '/');
            while (it.next()) |part| {
                if (part.len > 0) try parts.append(allocator, part);
            }

            if (parts.items.len < 4) return error.InvalidGitHubURL;
            const owner = parts.items[0];
            var repo = parts.items[1];
            if (std.mem.endsWith(u8, repo, ".git")) repo = repo[0 .. repo.len - 4];
            if (owner.len == 0 or repo.len == 0) return error.InvalidGitHubURL;

            const branch = parts.items[2];

            var path_buf: std.ArrayList(u8) = .empty;
            defer path_buf.deinit(allocator);
            for (parts.items[3..], 0..) |part, idx| {
                try path_buf.appendSlice(allocator, part);
                if (idx + 1 < parts.items[3..].len) try path_buf.append(allocator, '/');
            }

            const decoded_path = try decodePercentEncoding(allocator, path_buf.items);
            defer allocator.free(decoded_path);

            const clean_source = try validate.validateSourcePath(allocator, decoded_path);
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
                .url_type = .file,
            };
            return info;
        }
    }

    // 2. Check github.com
    const gh_prefixes = [_][]const u8{
        "https://github.com/",
        "http://github.com/",
        "https://www.github.com/",
        "http://www.github.com/",
    };
    for (gh_prefixes) |p| {
        if (std.mem.startsWith(u8, url_str, p)) {
            const path_part = url_str[p.len..];
            const trimmed_parts = std.mem.trim(u8, path_part, "/");
            var parts: std.ArrayList([]const u8) = .empty;
            defer parts.deinit(allocator);

            var it = std.mem.splitScalar(u8, trimmed_parts, '/');
            while (it.next()) |part| {
                if (part.len > 0) try parts.append(allocator, part);
            }

            if (parts.items.len < 2) return error.InvalidGitHubURL;
            const owner = parts.items[0];
            var repo = parts.items[1];
            if (std.mem.endsWith(u8, repo, ".git")) repo = repo[0 .. repo.len - 4];
            if (owner.len == 0 or repo.len == 0) return error.InvalidGitHubURL;

            var branch: []const u8 = "";
            var url_type: GitHubURLType = .directory;
            var clean_source: []u8 = try allocator.dupe(u8, "");
            errdefer allocator.free(clean_source);
            var base_name: []const u8 = "";

            if (parts.items.len == 2) {
                branch = "";
                url_type = .directory;
            } else if (parts.items.len == 3) {
                const kind = parts.items[2];
                if (std.mem.eql(u8, kind, "tree") or std.mem.eql(u8, kind, "blob") or std.mem.eql(u8, kind, "raw")) {
                    branch = "";
                    url_type = .directory;
                } else {
                    allocator.free(clean_source);
                    return error.UnsupportedGitHubURL;
                }
            } else if (parts.items.len == 4) {
                const kind = parts.items[2];
                branch = parts.items[3];
                if (std.mem.eql(u8, kind, "blob") or std.mem.eql(u8, kind, "raw")) {
                    url_type = .file;
                } else if (std.mem.eql(u8, kind, "tree")) {
                    url_type = .directory;
                } else {
                    allocator.free(clean_source);
                    return error.UnsupportedGitHubURL;
                }
            } else {
                const kind = parts.items[2];
                branch = parts.items[3];
                if (std.mem.eql(u8, kind, "blob") or std.mem.eql(u8, kind, "raw")) {
                    url_type = .file;
                } else if (std.mem.eql(u8, kind, "tree")) {
                    url_type = .directory;
                } else {
                    allocator.free(clean_source);
                    return error.UnsupportedGitHubURL;
                }

                var path_buf: std.ArrayList(u8) = .empty;
                defer path_buf.deinit(allocator);

                for (parts.items[4..], 0..) |part, idx| {
                    try path_buf.appendSlice(allocator, part);
                    if (idx + 1 < parts.items[4..].len) try path_buf.append(allocator, '/');
                }

                const decoded_path = try decodePercentEncoding(allocator, path_buf.items);
                defer allocator.free(decoded_path);

                allocator.free(clean_source);
                clean_source = try validate.validateSourcePath(allocator, decoded_path);

                base_name = std.fs.path.basename(clean_source);
                if (base_name.len == 0 or std.mem.eql(u8, base_name, ".") or std.mem.eql(u8, base_name, "/")) {
                    allocator.free(clean_source);
                    return error.InvalidGitHubPath;
                }
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
    }

    // 3. Check gitlab.com
    const gl_prefixes = [_][]const u8{
        "https://gitlab.com/",
        "http://gitlab.com/",
        "https://www.gitlab.com/",
        "http://www.gitlab.com/",
    };
    for (gl_prefixes) |p| {
        if (std.mem.startsWith(u8, url_str, p)) {
            const path_part = url_str[p.len..];
            const trimmed_parts = std.mem.trim(u8, path_part, "/");
            var parts: std.ArrayList([]const u8) = .empty;
            defer parts.deinit(allocator);

            var it = std.mem.splitScalar(u8, trimmed_parts, '/');
            while (it.next()) |part| {
                if (part.len > 0) try parts.append(allocator, part);
            }

            if (parts.items.len < 2) return error.InvalidGitHubURL;
            const owner = parts.items[0];
            var repo = parts.items[1];
            if (std.mem.endsWith(u8, repo, ".git")) repo = repo[0 .. repo.len - 4];
            if (owner.len == 0 or repo.len == 0) return error.InvalidGitHubURL;

            var branch: []const u8 = "";
            var url_type: GitHubURLType = .directory;
            var clean_source: []u8 = try allocator.dupe(u8, "");
            errdefer allocator.free(clean_source);
            var base_name: []const u8 = "";

            if (parts.items.len == 2) {
                // whole repo
            } else if (parts.items.len >= 5 and std.mem.eql(u8, parts.items[2], "-")) {
                const kind = parts.items[3];
                branch = parts.items[4];
                if (std.mem.eql(u8, kind, "blob") or std.mem.eql(u8, kind, "raw")) {
                    url_type = .file;
                } else if (std.mem.eql(u8, kind, "tree")) {
                    url_type = .directory;
                } else {
                    allocator.free(clean_source);
                    return error.UnsupportedGitHubURL;
                }

                if (parts.items.len > 5) {
                    var path_buf: std.ArrayList(u8) = .empty;
                    defer path_buf.deinit(allocator);

                    for (parts.items[5..], 0..) |part, idx| {
                        try path_buf.appendSlice(allocator, part);
                        if (idx + 1 < parts.items[5..].len) try path_buf.append(allocator, '/');
                    }

                    const decoded_path = try decodePercentEncoding(allocator, path_buf.items);
                    defer allocator.free(decoded_path);

                    allocator.free(clean_source);
                    clean_source = try validate.validateSourcePath(allocator, decoded_path);

                    base_name = std.fs.path.basename(clean_source);
                }
            }

            const info = try allocator.create(GitHubURLInfo);
            info.* = .{
                .repo_url = try std.fmt.allocPrint(allocator, "https://gitlab.com/{s}/{s}.git", .{ owner, repo }),
                .branch = try allocator.dupe(u8, branch),
                .path = clean_source,
                .file_path = try allocator.dupe(u8, clean_source),
                .file_name = try allocator.dupe(u8, base_name),
                .url_type = url_type,
            };
            return info;
        }
    }

    // 4. Check codeberg.org
    const cb_prefixes = [_][]const u8{
        "https://codeberg.org/",
        "http://codeberg.org/",
        "https://www.codeberg.org/",
        "http://www.codeberg.org/",
    };
    for (cb_prefixes) |p| {
        if (std.mem.startsWith(u8, url_str, p)) {
            const path_part = url_str[p.len..];
            const trimmed_parts = std.mem.trim(u8, path_part, "/");
            var parts: std.ArrayList([]const u8) = .empty;
            defer parts.deinit(allocator);

            var it = std.mem.splitScalar(u8, trimmed_parts, '/');
            while (it.next()) |part| {
                if (part.len > 0) try parts.append(allocator, part);
            }

            if (parts.items.len < 2) return error.InvalidGitHubURL;
            const owner = parts.items[0];
            var repo = parts.items[1];
            if (std.mem.endsWith(u8, repo, ".git")) repo = repo[0 .. repo.len - 4];
            if (owner.len == 0 or repo.len == 0) return error.InvalidGitHubURL;

            var branch: []const u8 = "";
            var url_type: GitHubURLType = .directory;
            var clean_source: []u8 = try allocator.dupe(u8, "");
            errdefer allocator.free(clean_source);
            var base_name: []const u8 = "";

            if (parts.items.len == 2) {
                // whole repo
            } else if (parts.items.len >= 5 and (std.mem.eql(u8, parts.items[2], "src") or std.mem.eql(u8, parts.items[2], "raw")) and std.mem.eql(u8, parts.items[3], "branch")) {
                const kind = parts.items[2];
                branch = parts.items[4];
                if (std.mem.eql(u8, kind, "raw")) {
                    url_type = .file;
                } else {
                    url_type = .directory;
                }

                if (parts.items.len > 5) {
                    var path_buf: std.ArrayList(u8) = .empty;
                    defer path_buf.deinit(allocator);

                    for (parts.items[5..], 0..) |part, idx| {
                        try path_buf.appendSlice(allocator, part);
                        if (idx + 1 < parts.items[5..].len) try path_buf.append(allocator, '/');
                    }

                    const decoded_path = try decodePercentEncoding(allocator, path_buf.items);
                    defer allocator.free(decoded_path);

                    allocator.free(clean_source);
                    clean_source = try validate.validateSourcePath(allocator, decoded_path);

                    base_name = std.fs.path.basename(clean_source);
                }
            }

            const info = try allocator.create(GitHubURLInfo);
            info.* = .{
                .repo_url = try std.fmt.allocPrint(allocator, "https://codeberg.org/{s}/{s}.git", .{ owner, repo }),
                .branch = try allocator.dupe(u8, branch),
                .path = clean_source,
                .file_path = try allocator.dupe(u8, clean_source),
                .file_name = try allocator.dupe(u8, base_name),
                .url_type = url_type,
            };
            return info;
        }
    }

    return error.UnsupportedURL;
}
