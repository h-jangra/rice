pub const sync = @import("sync/mod.zig");

pub const commit = sync.commit;
pub const pull = sync.pull;
pub const branch = sync.branch;
pub const restore = sync.restore;

pub const parseCommitMessage = sync.parseCommitMessage;
pub const stageTrackedFiles = sync.stageTrackedFiles;
pub const generateAutoCommitMessage = sync.generateAutoCommitMessage;
pub const commitCmd = sync.commitCmd;
pub const pushCmd = sync.pushCmd;

pub const pullCmd = sync.pullCmd;

pub const switchCmd = sync.switchCmd;
pub const branchesCmd = sync.branchesCmd;

pub const restoreCmd = sync.restoreCmd;
pub const discardCmd = sync.discardCmd;

