const std = @import("std");

/// Single source of truth for the package version.
const build_zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSmall,
    });

    const version = build_zon.version;

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const addon_module = b.createModule(.{
        .root_source_file = b.path("src/addon.zig"),
        .target = target,
        .optimize = optimize,
    });

    addon_module.link_libc = true;

    addon_module.addOptions("build_options", options);

    const target_str = b.option([]const u8, "target_name", "target name") orelse "unknown";

    const addon = b.addLibrary(.{
        .name = b.fmt("neostaged-{s}", .{target_str}),
        .linkage = .dynamic,
        .root_module = addon_module,
    });

    if (target.result.os.tag == .windows) {
        const node_lib_path = b.option(
            []const u8,
            "node_lib",
            "Path para node.lib no Windows",
        );

        if (node_lib_path) |path| {
            addon_module.addObjectFile(.{ .cwd_relative = path });
        } else {
            @panic("Para Windows, passe -Dnode_lib=/caminho/para/node.lib");
        }
    }

    if (target.result.os.tag == .macos) {
        addon.linker_allow_shlib_undefined = true;
    }

    const install_node = b.addInstallFileWithDir(
        addon.getEmittedBin(),
        .prefix,
        b.fmt("neostaged-{s}.node", .{target_str}),
    );

    b.getInstallStep().dependOn(&install_node.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("tests/all_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    // spinner.zig declares libc externs (fork, ioctl, poll...).
    test_module.link_libc = true;

    // Suites under tests/ reach every implementation module through one
    // barrel import ("lib"), keeping each file in a single compilation module.
    const lib_test_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_test_module.link_libc = true;

    test_module.addImport("lib", lib_test_module);

    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
