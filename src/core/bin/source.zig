const std = @import("std");
const Allocator = std.mem.Allocator;

pub const BinarySourceType = enum {
    github,
    url,
    local,
};

pub const BinarySource = struct {
    source_type: BinarySourceType,
    owner: []const u8 = "",
    repo: []const u8 = "",
    url: []const u8 = "",
    path: []const u8 = "",

    pub fn deinit(self: *BinarySource, allocator: Allocator) void {
        if (self.owner.len > 0) allocator.free(self.owner);
        if (self.repo.len > 0) allocator.free(self.repo);
        if (self.url.len > 0) allocator.free(self.url);
        if (self.path.len > 0) allocator.free(self.path);
    }
};

fn tryExtractGitHubOwnerRepo(s: []const u8) ?struct { owner: []const u8, repo: []const u8 } {
    var path_part = s;
    const gh_prefixes = [_][]const u8{ "https://github.com/", "http://github.com/", "https://www.github.com/", "http://www.github.com/", "github.com/" };
    for (gh_prefixes) |p| {
        if (std.mem.startsWith(u8, path_part, p)) {
            path_part = path_part[p.len..];
            break;
        }
    }
    const clean_pp = std.mem.trim(u8, path_part, "/");
    var it = std.mem.splitScalar(u8, clean_pp, '/');
    const owner = it.next() orelse return null;
    const repo = it.next() orelse return null;
    if (it.next() != null) return null;
    if (owner.len == 0 or repo.len == 0) return null;
    if (std.mem.indexOfAny(u8, owner, " \t\r\n\\:") != null or std.mem.indexOfAny(u8, repo, " \t\r\n\\:") != null) return null;
    if (std.mem.eql(u8, owner, ".") or std.mem.eql(u8, owner, "..")) return null;

    var repo_clean = repo;
    if (std.mem.endsWith(u8, repo_clean, ".git")) {
        repo_clean = repo_clean[0 .. repo_clean.len - 4];
    }
    return .{ .owner = owner, .repo = repo_clean };
}

const paths = @import("../paths/mod.zig");
const fs = @import("../fs.zig");

pub fn parseBinarySource(allocator: Allocator, source: []const u8, homeDir: []const u8) !BinarySource {
    const s = std.mem.trim(u8, source, " \t\r\n");
    if (s.len == 0) return error.SourceRequired;

    const local_prefixes = [_][]const u8{ "./", "../", "/", "~/", ".\\", "..\\", "~\\" };
    var is_local_prefix = false;
    for (local_prefixes) |lp| {
        if (std.mem.startsWith(u8, s, lp)) {
            is_local_prefix = true;
            break;
        }
    }

    if (is_local_prefix) {
        const resolved = try paths.resolveUserPath(allocator, homeDir, s);
        errdefer allocator.free(resolved);

        const file = fs.openFileAbsolute(resolved, .{}) catch |err| {
            allocator.free(resolved);
            if (err == error.IsDir) return error.LocalPathIsDirectory;
            if (err == error.FileNotFound) return error.LocalFileNotFound;
            return err;
        };
        file.close(paths.getProcessIo());

        return BinarySource{
            .source_type = .local,
            .path = resolved,
        };
    }

    if (paths.resolveUserPath(allocator, homeDir, s)) |resolved| {
        if (fs.openFileAbsolute(resolved, .{})) |f| {
            f.close(paths.getProcessIo());
            return BinarySource{
                .source_type = .local,
                .path = resolved,
            };
        } else |err| {
            allocator.free(resolved);
            if (err == error.IsDir) return error.LocalPathIsDirectory;
        }
    } else |_| {}

    if (tryExtractGitHubOwnerRepo(s)) |gh| {
        return BinarySource{
            .source_type = .github,
            .owner = try allocator.dupe(u8, gh.owner),
            .repo = try allocator.dupe(u8, gh.repo),
        };
    }

    if (std.mem.startsWith(u8, s, "http://") or std.mem.startsWith(u8, s, "https://")) {
        return BinarySource{
            .source_type = .url,
            .url = try allocator.dupe(u8, s),
        };
    }

    return error.InvalidSource;
}
