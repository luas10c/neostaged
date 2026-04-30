const std = @import("std");

fn color(allocator: std.mem.Allocator, code: u8, value: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "\x1b[{d}m{s}\x1b[0m",
        .{ code, value },
    );
}

fn style(allocator: std.mem.Allocator, codes: []const u8, value: []const u8) ![]u8 {
    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    for (codes, 0..) |code, i| {
        if (i > 0) {
            buf[pos] = ';';
            pos += 1;
        }
        const s = std.fmt.bufPrint(buf[pos..], "{d}", .{code}) catch "";
        pos += s.len;
    }
    return std.fmt.allocPrint(allocator, "\x1b[{s}m{s}\x1b[0m", .{ buf[0..pos], value });
}

pub fn yellow(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    return color(allocator, 33, value);
}

pub fn purple(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    return color(allocator, 95, value);
}

pub fn red(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    return color(allocator, 31, value);
}

pub fn blue(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    return color(allocator, 34, value);
}

pub fn white(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    return color(allocator, 97, value);
}

pub fn cyan(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    return color(allocator, 96, value);
}

pub fn green(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    return color(allocator, 32, value);
}

pub fn gray(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    return color(allocator, 90, value);
}

pub fn bold(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    return style(allocator, &.{1}, value);
}

pub fn accent(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    return style(allocator, &.{ 1, 36 }, value);
}
