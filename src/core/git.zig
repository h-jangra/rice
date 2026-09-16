pub const exec = @import("git/exec.zig");
pub const repo = @import("git/repo.zig");
pub const status = @import("git/status.zig");
pub const branch = @import("git/branch.zig");

pub const Git = repo.Git;
pub const verifyGitInstalled = exec.verifyGitInstalled;

