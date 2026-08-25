const std = @import("std");

const spinner = @import("spinner.zig");
const ansi = @import("ansi.zig");

pub const State = enum {
    pending,
    success,
    failed,
    skipped,
};

/// Result row: "{prefix}{glyph} {icon} {label} · {note}" with the note
/// rendered inline right after the label.
pub fn print(
    io: std.Io,
    allocator: std.mem.Allocator,
    state: State,
    glyph: []const u8,
    label: []const u8,
    note: []const u8,
    prefix: []const u8,
) !void {
    if (state == .pending) return;

    const raw_icon = switch (state) {
        .success => "✓",
        .failed => "✗",
        .skipped => "○",
        else => unreachable,
    };

    const icon = switch (state) {
        .success => try ansi.green(allocator, raw_icon),
        .failed => try ansi.red(allocator, raw_icon),
        .skipped => try ansi.yellow(allocator, raw_icon),
        else => unreachable,
    };
    defer allocator.free(icon);

    var left_buf: [1024]u8 = undefined;
    const left = std.fmt.bufPrint(&left_buf, "{s}{s} {s} {s}", .{ prefix, glyph, icon, label }) catch
        return error.LabelTooLong;

    if (ansi.enabled) {
        // Repaint over the spinner line, then append the note inline.
        stdoutPrint(io, "\r\x1b[2K{s}", .{left}) catch {};
        if (note.len > 0) {
            const sep = try ansi.gray(allocator, " \u{b7} ");
            defer allocator.free(sep);
            stdoutPrint(io, "{s}{s}", .{ sep, note }) catch {};
        }
        stdoutPrint(io, "\n", .{}) catch {};
    } else {
        if (note.len > 0) {
            try stdoutPrint(io, "{s} \u{b7} {s}\n", .{ left, note });
        } else {
            try stdoutPrint(io, "{s}\n", .{left});
        }
    }
}

pub fn runPendingCapture(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    label: []const u8,
    prefix: []const u8,
) !spinner.CaptureResult {
    return spinner.runCaptureWithSpinner(
        io,
        allocator,
        argv,
        cwd,
        label,
        prefix,
    );
}

fn stdoutPrint(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}
