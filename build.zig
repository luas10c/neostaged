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

    const node_include_dir = b.option(
        []const u8,
        "node_include_dir",
        "Path para os headers do Node",
    ) orelse "/usr/include/node";

    const node_lib_path = b.option(
        []const u8,
        "node_lib",
        "Path para node.lib no Windows",
    );

    const addon_module = b.createModule(.{
        .root_source_file = b.path("src/addon.zig"),
        .target = target,
        .optimize = optimize,
    });

    addon_module.addOptions("build_options", options);

    const is_windows = target.result.os.tag == .windows;
    const is_macos = target.result.os.tag == .macos;

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

    addon_module.addIncludePath(.{ .cwd_relative = node_include_dir });

    if (is_windows) {
        if (node_lib_path) |path| {
            addon_module.addObjectFile(.{ .cwd_relative = path });
        } else {
            @panic("Para Windows, passe -Dnode_lib=/caminho/para/node.lib");
        }
    }

    if (is_macos) {
        addon.linker_allow_shlib_undefined = true;
    }

    b.getInstallStep().dependOn(&install_node.step);

    b.installArtifact(app);
    b.installArtifact(addon);
}
