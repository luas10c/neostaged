const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSmall,
    });

    const version = "0.1.0";

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const app = b.addExecutable(.{ .name = "neostaged", .root_module = root_module });

    app.root_module.addOptions("build_options", options);

    const addon_module = b.createModule(.{
        .root_source_file = b.path("src/addon.zig"),
        .target = target,
        .optimize = optimize,
    });

    addon_module.addOptions("build_options", options);

    addon_module.addIncludePath(.{ .cwd_relative = "/usr/include/node" });

    const target_str = b.option([]const u8, "target_name", "target name") orelse "unknown";

    const addon = b.addLibrary(.{
        .name = b.fmt("neostaged-{s}", .{target_str}),
        .linkage = .dynamic,
        .root_module = addon_module,
    });

    const install_node = b.addInstallFileWithDir(
        addon.getEmittedBin(),
        .prefix,
        b.fmt("neostaged-{s}.node", .{target_str}),
    );

    b.getInstallStep().dependOn(&install_node.step);

    b.installArtifact(app);
    b.installArtifact(addon);
}
