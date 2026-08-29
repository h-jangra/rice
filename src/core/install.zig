pub const install = @import("install/mod.zig");

pub const url = install.url;
pub const discovery = install.discovery;
pub const sparse = install.sparse;
pub const bin_cmd = install.bin_cmd;
pub const entry = install.entry;

pub const defaultBranch = install.defaultBranch;
pub const printInstallUsage = install.printInstallUsage;
pub const printInstallHelp = install.printInstallHelp;
pub const installDotfiles = install.installDotfiles;

pub const printBinHelp = install.printBinHelp;
pub const runBinInstall = install.runBinInstall;
pub const runBinList = install.runBinList;
pub const runBinRemove = install.runBinRemove;
pub const binCmd = install.binCmd;

pub const installCmd = install.installCmd;

pub const runDirectURLInstall = install.runDirectURLInstall;

pub const DiscoveredCandidate = install.DiscoveredCandidate;
pub const generateDiscoveryCandidates = install.generateDiscoveryCandidates;
pub const ResolvedRemoteConfig = install.ResolvedRemoteConfig;
pub const resolveRemoteConfig = install.resolveRemoteConfig;

