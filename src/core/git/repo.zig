const std = @import("std");
const Allocator = std.mem.Allocator;
const paths = @import("../paths/mod.zig");
const exec = @import("exec.zig");
const git_status = @import("status.zig");
const branch = @import("branch.zig");

pub const Git = struct {
    allocator: Allocator,
    home_dir: []u8,
    rice_dir: []u8,

    pub fn init(allocator: Allocator, home_dir: []const u8) !*Git {
        const g = try allocator.create(Git);
        g.* = .{
            .allocator = allocator,
            .home_dir = try allocator.dupe(u8, home_dir),
            .rice_dir = try paths.getRiceDir(allocator, home_dir),
        };
        return g;
    }

    pub fn deinit(self: *Git) void {
        self.allocator.free(self.home_dir);
        self.allocator.free(self.rice_dir);
        self.allocator.destroy(self);
    }

    pub fn run(self: *const Git, args: []const []const u8) !void {
        return exec.execRun(self.allocator, self.rice_dir, self.home_dir, args, true);
    }

    pub fn output(self: *const Git, args: []const []const u8) ![]u8 {
        return exec.execOutput(self.allocator, self.rice_dir, self.home_dir, args, true);
    }

    pub fn outputBytes(self: *const Git, args: []const []const u8) ![]u8 {
        return exec.execOutputBytes(self.allocator, self.rice_dir, self.home_dir, args, true);
    }

    pub fn bareRun(self: *const Git, args: []const []const u8) !void {
        return exec.execRun(self.allocator, self.rice_dir, self.home_dir, args, false);
    }

    pub fn bareOutput(self: *const Git, args: []const []const u8) ![]u8 {
        return exec.execOutput(self.allocator, self.rice_dir, self.home_dir, args, false);
    }

    pub fn initBare(self: *const Git) !void {
        const argv = [_][]const u8{ "git", "init", "--bare", self.rice_dir };
        var child = try std.process.spawn(paths.getProcessIo(), .{
            .argv = &argv,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        });
        const term = try child.wait(paths.getProcessIo());
        if (term != .exited or term.exited != 0) return error.GitInitFailed;

        _ = self.bareRun(&[_][]const u8{ "config", "status.showUntrackedFiles", "no" }) catch {};
        _ = self.bareRun(&[_][]const u8{ "symbolic-ref", "HEAD", "refs/heads/main" }) catch {};

        const exclude_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ self.rice_dir, "info" });
        defer self.allocator.free(exclude_dir);
        try std.Io.Dir.cwd().createDirPath(paths.getProcessIo(), exclude_dir);

        const exclude_path = try std.fs.path.join(self.allocator, &[_][]const u8{ exclude_dir, "exclude" });
        defer self.allocator.free(exclude_path);

        const file = try std.Io.Dir.cwd().createFile(paths.getProcessIo(), exclude_path, .{ .permissions = @enumFromInt(0o644) });
        defer file.close(paths.getProcessIo());
        try file.writePositionalAll(paths.getProcessIo(), ".rice\n.rice/\n", 0);
    }

    pub fn isBareRepo(self: *const Git) bool {
        if (self.bareOutput(&[_][]const u8{ "rev-parse", "--is-bare-repository" })) |out| {
            defer self.allocator.free(out);
            return std.mem.eql(u8, out, "true");
        } else |_| {
            return false;
        }
    }

    pub fn hasCommits(self: *const Git) bool {
        if (self.output(&[_][]const u8{ "rev-parse", "--verify", "HEAD" })) |out| {
            self.allocator.free(out);
            return true;
        } else |_| {
            return false;
        }
    }

    pub fn getCurrentBranch(self: *const Git) ![]u8 {
        return branch.getCurrentBranch(self.allocator, self.rice_dir, self.home_dir);
    }

    pub fn setRemote(self: *const Git, raw_url: []const u8) !void {
        const norm = try paths.normalizeRepoURL(self.allocator, raw_url);
        defer self.allocator.free(norm);

        if (self.output(&[_][]const u8{ "remote", "get-url", "origin" })) |out| {
            self.allocator.free(out);
            return self.run(&[_][]const u8{ "remote", "set-url", "origin", norm });
        } else |_| {
            return self.run(&[_][]const u8{ "remote", "add", "origin", norm });
        }
    }

    pub fn getRemote(self: *const Git) ![]u8 {
        return self.output(&[_][]const u8{ "remote", "get-url", "origin" });
    }

    pub fn add(self: *const Git, files: []const []const u8) !void {
        if (files.len == 0) return;
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);
        try args.append(self.allocator, "add");
        try args.append(self.allocator, "--");
        for (files) |f| {
            try args.append(self.allocator, f);
        }
        try self.run(args.items);
    }

    pub fn addUpdate(self: *const Git, files: []const []const u8) !void {
        if (files.len == 0) return;
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);
        try args.append(self.allocator, "add");
        try args.append(self.allocator, "-u");
        try args.append(self.allocator, "--");
        for (files) |f| {
            try args.append(self.allocator, f);
        }
        try self.run(args.items);
    }

    pub fn removeCached(self: *const Git, files: []const []const u8) !void {
        if (files.len == 0) return;
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);
        try args.append(self.allocator, "rm");
        try args.append(self.allocator, "--cached");
        try args.append(self.allocator, "-r");
        try args.append(self.allocator, "--ignore-unmatch");
        try args.append(self.allocator, "--");
        for (files) |f| {
            try args.append(self.allocator, f);
        }
        try self.run(args.items);
    }

    pub fn commit(self: *const Git, msg: []const u8) !void {
        try self.run(&[_][]const u8{ "commit", "-m", msg });
    }

    pub fn push(self: *const Git) !void {
        if (self.getCurrentBranch()) |cur_branch| {
            defer self.allocator.free(cur_branch);
            if (cur_branch.len > 0 and !std.mem.eql(u8, cur_branch, "HEAD")) {
                if (self.run(&[_][]const u8{ "push", "-u", "origin", cur_branch })) {
                    return;
                } else |_| {}
            }
        } else |_| {}

        if (self.run(&[_][]const u8{ "push", "origin", "HEAD" })) {
            return;
        } else |_| {
            return self.run(&[_][]const u8{"push"});
        }
    }

    pub fn fetch(self: *const Git) !void {
        return self.run(&[_][]const u8{ "fetch", "origin" });
    }

    pub fn merge(self: *const Git, ref: []const u8) !void {
        if (self.run(&[_][]const u8{ "merge", "--ff-only", ref })) {
            return;
        } else |_| {
            return self.run(&[_][]const u8{ "merge", ref, "-m", "Merge remote-tracking branch into dotfiles" });
        }
    }

    pub fn status(self: *const Git, files: []const []const u8) !void {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);
        try args.append(self.allocator, "status");
        try args.append(self.allocator, "--");
        if (files.len == 0) {
            try args.append(self.allocator, ".rice.ini");
        } else {
            for (files) |f| try args.append(self.allocator, f);
        }
        try self.run(args.items);
    }

    pub fn diff(self: *const Git, files: []const []const u8) !void {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);
        try args.append(self.allocator, "diff");
        if (!self.hasCommits()) {
            try args.append(self.allocator, "--cached");
        } else {
            try args.append(self.allocator, "HEAD");
        }
        try args.append(self.allocator, "--");
        if (files.len == 0) {
            try args.append(self.allocator, ".rice.ini");
        } else {
            for (files) |f| try args.append(self.allocator, f);
        }
        try self.run(args.items);
    }

    pub fn listRefFiles(self: *const Git, ref: []const u8, paths_filter: []const []const u8) !std.ArrayList([]u8) {
        return git_status.listRefFiles(self.allocator, self.rice_dir, self.home_dir, ref, paths_filter);
    }

    pub fn listTrackedFiles(self: *const Git, paths_filter: []const []const u8) !std.ArrayList([]u8) {
        if (!self.hasCommits() or paths_filter.len == 0) {
            return .empty;
        }
        return self.listRefFiles("HEAD", paths_filter);
    }

    pub fn listIndexFiles(self: *const Git) !std.ArrayList([]u8) {
        return git_status.listIndexFiles(self.allocator, self.rice_dir, self.home_dir);
    }

    pub fn getAllGitTrackedFiles(self: *const Git) !std.ArrayList([]u8) {
        return git_status.getAllGitTrackedFiles(self.allocator, self.rice_dir, self.home_dir, self.hasCommits());
    }

    pub fn getRefFileContent(self: *const Git, ref: []const u8, relPath: []const u8) ![]u8 {
        const spec = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ ref, relPath });
        defer self.allocator.free(spec);
        return self.outputBytes(&[_][]const u8{ "show", spec });
    }

    pub fn getHEADFileContent(self: *const Git, relPath: []const u8) ![]u8 {
        return self.getRefFileContent("HEAD", relPath);
    }

    pub fn checkoutHEAD(self: *const Git, files: []const []const u8) !void {
        if (files.len == 0) return;
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);
        try args.append(self.allocator, "checkout");
        try args.append(self.allocator, "HEAD");
        try args.append(self.allocator, "--");
        for (files) |f| try args.append(self.allocator, f);
        try self.run(args.items);
    }

    pub fn switchBranch(self: *const Git, branch_raw: []const u8, create: bool, force: bool, merge_flag: bool) !void {
        return branch.switchBranch(self.allocator, self.rice_dir, self.home_dir, branch_raw, create, force, merge_flag, self.hasCommits());
    }

    pub fn branchList(self: *const Git, args: []const []const u8) ![]u8 {
        return branch.branchList(self.allocator, self.rice_dir, self.home_dir, args);
    }
};
