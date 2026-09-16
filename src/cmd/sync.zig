pub const commit = @import("sync/commit.zig");
pub const pull = @import("sync/pull.zig");
pub const branch = @import("sync/branch.zig");
pub const restore = @import("sync/restore.zig");

pub const parseCommitMessage = commit.parseCommitMessage;
pub const generateAutoCommitMessage = commit.generateAutoCommitMessage;
pub const commitCmd = commit.commitCmd;
pub const pushCmd = commit.pushCmd;

pub const pullCmd = pull.pullCmd;

pub const switchCmd = branch.switchCmd;
pub const branchesCmd = branch.branchesCmd;

pub const restoreCmd = restore.restoreCmd;
pub const discardCmd = restore.discardCmd;


