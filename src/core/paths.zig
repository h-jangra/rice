pub const paths = @import("paths/mod.zig");

pub const clean = paths.clean;
pub const resolve = paths.resolve;
pub const validate = paths.validate;
pub const url = paths.url;

pub const toSlashOwned = paths.toSlashOwned;
pub const cleanPath = paths.cleanPath;

pub const setProcessIo = paths.setProcessIo;
pub const setProcessEnviron = paths.setProcessEnviron;
pub const getProcessIo = paths.getProcessIo;
pub const getProcessEnviron = paths.getProcessEnviron;
pub const getHomeDir = paths.getHomeDir;
pub const getRiceDir = paths.getRiceDir;
pub const getRiceIniPath = paths.getRiceIniPath;
pub const resolveUserPath = paths.resolveUserPath;
pub const ResolvedPaths = paths.ResolvedPaths;
pub const resolvePath = paths.resolvePath;
pub const configPath = paths.configPath;
pub const absolutePath = paths.absolutePath;
pub const gitPath = paths.gitPath;
pub const InstallDestResult = paths.InstallDestResult;
pub const resolveInstallDestination = paths.resolveInstallDestination;

pub const validateManagedPath = paths.validateManagedPath;
pub const validateSourcePath = paths.validateSourcePath;
pub const detectSensitiveFile = paths.detectSensitiveFile;
pub const validateBinaryName = paths.validateBinaryName;

pub const normalizeRepoURL = paths.normalizeRepoURL;
pub const isURL = paths.isURL;
pub const GitHubURLType = paths.GitHubURLType;
pub const GitHubURLInfo = paths.GitHubURLInfo;
pub const parseGitHubURL = paths.parseGitHubURL;

