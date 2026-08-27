pub const source = @import("source.zig");
pub const release = @import("release.zig");
pub const extract = @import("extract.zig");
pub const install = @import("install.zig");

pub const BinarySourceType = source.BinarySourceType;
pub const BinarySource = source.BinarySource;
pub const parseBinarySource = source.parseBinarySource;

pub const matchAsset = release.matchAsset;
pub const GitHubReleaseAsset = release.GitHubReleaseAsset;
pub const fetchGitHubReleaseAsset = release.fetchGitHubReleaseAsset;

pub const isExecutableBinary = extract.isExecutableBinary;
pub const isIgnoredCandidate = extract.isIgnoredCandidate;
pub const matchCandidateName = extract.matchCandidateName;
pub const findExecutable = extract.findExecutable;
pub const formatBinaryTree = extract.formatBinaryTree;
pub const promptBinarySelection = extract.promptBinarySelection;

pub const InstallBinOptions = install.InstallBinOptions;
pub const installBinary = install.installBinary;
