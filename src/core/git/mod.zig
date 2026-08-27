pub const exec = @import("exec.zig");
pub const repo = @import("repo.zig");
pub const status = @import("status.zig");
pub const branch = @import("branch.zig");

pub const Git = repo.Git;
pub const verifyGitInstalled = exec.verifyGitInstalled;
