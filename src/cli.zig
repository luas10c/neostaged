const std = @import("std");
const builtin = @import("builtin");

const pipeline = @import("pipeline.zig");

pub fn main(init: std.process.Init) void {
    if (builtin.mode == .Debug) {
        var gpa = std.heap.DebugAllocator(.{}){};
        defer _ = gpa.deinit();

        runMain(init, gpa.allocator());
    } else {
        runMain(init, std.heap.smp_allocator);
    }
}

fn runMain(init: std.process.Init, allocator: std.mem.Allocator) void {
    tryMain(init.io, allocator, init.minimal.args) catch |err| {
        if (builtin.mode == .Debug) {
            std.debug.print("{s}\n", .{@errorName(err)});
        }

        std.process.exit(1);
    };
}

fn tryMain(
    io: std.Io,
    allocator: std.mem.Allocator,
    raw_args: anytype,
) !void {
    var cwd_arg: ?[]const u8 = null;
    var config_arg: ?[]const u8 = null;
    var list = false;

    var args = raw_args.iterate();
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--cwd")) {
            cwd_arg = args.next() orelse return error.MissingCwdValue;
        } else if (std.mem.eql(u8, arg, "--config")) {
            config_arg = args.next() orelse return error.MissingConfigValue;
        } else if (std.mem.eql(u8, arg, "--list")) {
            list = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            std.debug.print("neostaged\n", .{});
            return;
        } else {
            return error.UnknownArgument;
        }
    }

    const cwd = try resolveCwd(allocator, cwd_arg);
    defer allocator.free(cwd);

    const config = try resolveConfigPath(allocator, config_arg);
    defer if (config) |path| allocator.free(path);

    try pipeline.run(io, allocator, .{
        .cwd = cwd,
        .config = config,
        .list = list,
    });
}

fn resolveCwd(
    allocator: std.mem.Allocator,
    cwd: ?[]const u8,
) ![]const u8 {
    if (cwd) |path| {
        return try allocator.dupe(u8, path);
    }

    return try allocator.dupe(u8, ".");
}

fn resolveConfigPath(
    allocator: std.mem.Allocator,
    config: ?[]const u8,
) !?[]const u8 {
    if (config) |path| {
        return try allocator.dupe(u8, path);
    }

    return null;
}

fn printHelp() void {
    std.debug.print(
        \\neostaged
        \\
        \\Run commands against staged files
        \\
        \\Options:
        \\  --cwd PATH       Run neostaged from a specific directory
        \\  --config PATH    Use a specific neostaged config file
        \\  --list           Print the staged files and exit
        \\  -h, --help       Print help
        \\  -V, --version    Print version
        \\
    , .{});
}
