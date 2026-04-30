const std = @import("std");

const spinner = @import("spinner.zig");
const ansi = @import("ansi.zig");

pub const State = enum {
    pending,
    success,
    failed,
    skipped,
};

pub fn print(
    io: std.Io,
    allocator: std.mem.Allocator,
    state: State,
    label: []const u8,
    suffix: []const u8,
) !void {
    if (state == .pending) return;

    const raw_icon = switch (state) {
        .success => "✔",
        .failed => "✖",
        .skipped => "⏭",
        else => unreachable,
    };

    const icon = switch (state) {
        .success => try ansi.green(allocator, raw_icon),
        .failed => try ansi.red(allocator, raw_icon),
        .skipped => try ansi.yellow(allocator, raw_icon),
        else => unreachable,
    };
    defer allocator.free(icon);

    const trimmed = trimPrefix(label);

    try stdoutPrint(
        io,
        "\r\x1b[2K{s} {s}{s}\n",
        .{ icon, trimmed, suffix },
    );
}

pub fn runPendingCapture(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    label: []const u8,
) !spinner.CaptureResult {
    return spinner.runCaptureWithSpinner(
        io,
        allocator,
        argv,
        cwd,
        label,
    );
}

fn stdoutPrint(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

fn trimPrefix(label: []const u8) []const u8 {
    if (std.mem.startsWith(u8, label, "│  ")) {
        return label["│  ".len..];
    }

    if (std.mem.startsWith(u8, label, "   ")) {
        return label[3..];
    }

    return label;
}
