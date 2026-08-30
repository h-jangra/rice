const std = @import("std");

fn getGitVersion(b: *std.Build) []const u8 {
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &[_][]const u8{ "git", "describe", "--tags", "--always" },
    }) catch return "0.1.0";

    defer b.allocator.free(result.stderr);

    if (result.term == .exited and result.term.exited == 0) {
        var trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "v")) {
            trimmed = trimmed[1..];
        }
        if (trimmed.len > 0) {
            return b.allocator.dupe(u8, trimmed) catch "0.1.0";
        }
    }

    b.allocator.free(result.stdout);
    return "0.1.0";
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version_override = b.option([]const u8, "version", "Override version string");
    const raw_version = version_override orelse getGitVersion(b);

    var version_clean = raw_version;
    if (std.mem.startsWith(u8, version_clean, "v")) {
        version_clean = version_clean[1..];
    }

    const options = b.addOptions();
    options.addOption([]const u8, "version", version_clean);

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    module.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "rice",
        .root_module = module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (@hasField(std.Build, "args")) {
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
    } else if (@hasDecl(std.Build.Step.Run, "addPassthruArgs")) {
        run_cmd.addPassthruArgs();
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    test_module.addOptions("build_options", options);

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
