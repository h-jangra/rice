pub const commit = @import("commit.zig");
pub const pull = @import("pull.zig");
pub const branch = @import("branch.zig");
pub const restore = @import("restore.zig");

pub const parseCommitMessage = commit.parseCommitMessage;
pub const stageTrackedFiles = commit.stageTrackedFiles;
pub const generateAutoCommitMessage = commit.generateAutoCommitMessage;
pub const commitCmd = commit.commitCmd;
pub const pushCmd = commit.pushCmd;

pub const pullCmd = pull.pullCmd;

pub const switchCmd = branch.switchCmd;
pub const branchesCmd = branch.branchesCmd;

pub const restoreCmd = restore.restoreCmd;
pub const discardCmd = restore.discardCmd;
