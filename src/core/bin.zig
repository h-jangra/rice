pub const bin = @import("bin/mod.zig");

pub const source = bin.source;
pub const release = bin.release;
pub const extract = bin.extract;
pub const install = bin.install;

pub const BinarySourceType = bin.BinarySourceType;
pub const BinarySource = bin.BinarySource;
pub const parseBinarySource = bin.parseBinarySource;

pub const matchAsset = bin.matchAsset;
pub const GitHubReleaseAsset = bin.GitHubReleaseAsset;
pub const fetchGitHubReleaseAsset = bin.fetchGitHubReleaseAsset;

pub const isExecutableBinary = bin.isExecutableBinary;
pub const isIgnoredCandidate = bin.isIgnoredCandidate;
pub const matchCandidateName = bin.matchCandidateName;
pub const findExecutable = bin.findExecutable;
pub const formatBinaryTree = bin.formatBinaryTree;
pub const promptBinarySelection = bin.promptBinarySelection;

pub const InstallBinOptions = bin.InstallBinOptions;
pub const installBinary = bin.installBinary;

