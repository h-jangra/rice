const std = @import("std");
const Allocator = std.mem.Allocator;
const clean = @import("clean.zig");
const resolve = @import("resolve.zig");

pub fn validateManagedPath(allocator: Allocator, homeDir: []const u8, config_p: []const u8) !void {
    const trimmed = std.mem.trim(u8, config_p, " \t\r\n");
    if (trimmed.len == 0) return error.ManagedPathEmpty;
    if (!std.mem.startsWith(u8, trimmed, "~/")) return error.ManagedPathMustStartWithTildeSlash;

    var res = try resolve.resolvePath(allocator, homeDir, trimmed);
    defer res.deinit(allocator);

    if (!std.mem.eql(u8, res.config_path, trimmed)) return error.ManagedPathNotNormalized;
}

pub fn validateSourcePath(allocator: Allocator, source: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len == 0) return error.SourcePathEmpty;
    if (std.mem.startsWith(u8, trimmed, "/") or std.mem.startsWith(u8, trimmed, "\\") or std.fs.path.isAbsolute(trimmed)) {
        return error.SourcePathMustBeRelative;
    }
    if (std.mem.startsWith(u8, trimmed, "~")) return error.SourcePathCannotUseTilde;

    const slash = try clean.toSlashOwned(allocator, trimmed);
    defer allocator.free(slash);

    const clean_p = try clean.cleanPath(allocator, slash);
    if (std.mem.eql(u8, clean_p, ".") or clean_p.len == 0) {
        allocator.free(clean_p);
        return error.InvalidSourcePath;
    }
    if (std.mem.eql(u8, clean_p, "..") or std.mem.startsWith(u8, clean_p, "../")) {
        allocator.free(clean_p);
        return error.SourcePathEscapesRepoRoot;
    }
    return clean_p;
}

pub fn detectSensitiveFile(path_str: []const u8) ?[]const u8 {
    const base = std.fs.path.basename(path_str);
    var lower_base_buf: [256]u8 = undefined;
    const lower_base = if (base.len <= 256) blk: {
        for (base, 0..) |c, i| lower_base_buf[i] = std.ascii.toLower(c);
        break :blk lower_base_buf[0..base.len];
    } else base;

    var lower_path_buf: [1024]u8 = undefined;
    const lower_path = if (path_str.len <= 1024) blk: {
        for (path_str, 0..) |c, i| lower_path_buf[i] = if (c == '\\') '/' else std.ascii.toLower(c);
        break :blk lower_path_buf[0..path_str.len];
    } else path_str;

    if (std.mem.startsWith(u8, lower_path, ".ssh/") or std.mem.indexOf(u8, lower_path, "/.ssh/") != null or std.mem.startsWith(u8, lower_path, "~/.ssh/")) {
        if ((std.mem.startsWith(u8, lower_base, "id_") and !std.mem.endsWith(u8, lower_base, ".pub")) or
            std.mem.eql(u8, lower_base, "id_rsa") or std.mem.eql(u8, lower_base, "id_ed25519") or
            std.mem.eql(u8, lower_base, "id_ecdsa") or std.mem.eql(u8, lower_base, "id_dsa"))
        {
            return "SSH private key";
        }
    }

    if (std.mem.eql(u8, lower_base, ".env") or (std.mem.startsWith(u8, lower_base, ".env.") and
        !std.mem.endsWith(u8, lower_base, ".example") and !std.mem.endsWith(u8, lower_base, ".sample") and
        !std.mem.endsWith(u8, lower_base, ".template")))
    {
        return "Environment file containing potential secrets";
    }

    const secret_exts = [_][]const u8{ ".pem", ".key", ".p12", ".pfx", ".kdbx" };
    for (secret_exts) |ext| {
        if (std.mem.endsWith(u8, lower_base, ext)) return "Private certificate / key / keystore file";
    }

    if (std.mem.startsWith(u8, lower_path, ".gnupg/") or std.mem.indexOf(u8, lower_path, "/.gnupg/") != null or std.mem.startsWith(u8, lower_path, "~/.gnupg/")) {
        if (std.mem.endsWith(u8, lower_base, ".key") or std.mem.eql(u8, lower_base, "secring.gpg") or std.mem.indexOf(u8, lower_base, "private") != null) {
            return "GPG private key";
        }
    }

    if (std.mem.indexOf(u8, lower_path, ".aws/credentials") != null or std.mem.indexOf(u8, lower_path, ".docker/config.json") != null) {
        return "Cloud / Container authentication credentials";
    }

    return null;
}

pub fn validateBinaryName(name: []const u8) !void {
    if (name.len == 0) return error.BinaryNameEmpty;
    if (std.mem.indexOfAny(u8, name, "/\\ \t\n\r") != null) return error.BinaryNameContainsInvalidChars;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or std.mem.startsWith(u8, name, "..")) {
        return error.BinaryNameInvalid;
    }
}

