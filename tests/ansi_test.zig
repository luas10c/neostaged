const std = @import("std");

const ansi = @import("lib").ansi;

// Snapshot of the public style surface: any accidental change to a code
// breaks terminal rendering everywhere at once, so pin them here.
test "ansi color codes are stable" {
    ansi.enabled = true;
    defer ansi.enabled = true;

    const cases = [_]struct {
        expected_code: u8,
        apply: *const fn (std.mem.Allocator, []const u8) anyerror![]u8,
    }{
        .{ .expected_code = 30 + 2, .apply = ansi.green },
        .{ .expected_code = 30 + 1, .apply = ansi.red },
        .{ .expected_code = 30 + 3, .apply = ansi.yellow },
        .{ .expected_code = 30 + 4, .apply = ansi.blue },
        .{ .expected_code = 90, .apply = ansi.gray },
        .{ .expected_code = 96, .apply = ansi.cyan },
        .{ .expected_code = 97, .apply = ansi.white },
        .{ .expected_code = 95, .apply = ansi.purple },
    };

    for (cases) |case| {
        const out = try case.apply(std.testing.allocator, "x");
        defer std.testing.allocator.free(out);

        var want_buf: [32]u8 = undefined;
        const want = try std.fmt.bufPrint(&want_buf, "\x1b[{d}mx\x1b[0m", .{case.expected_code});
        try std.testing.expectEqualStrings(want, out);
    }
}

test "ansi bold and accent compose multiple codes" {
    ansi.enabled = true;
    defer ansi.enabled = true;

    const bold = try ansi.bold(std.testing.allocator, "hi");
    defer std.testing.allocator.free(bold);
    try std.testing.expectEqualStrings("\x1b[1mhi\x1b[0m", bold);

    const accent = try ansi.accent(std.testing.allocator, "hi");
    defer std.testing.allocator.free(accent);
    try std.testing.expectEqualStrings("\x1b[1;36mhi\x1b[0m", accent);
}

test "ansi disabled emits value unchanged" {
    ansi.enabled = false;
    defer ansi.enabled = true;

    const fns = [_]struct {
        apply: *const fn (std.mem.Allocator, []const u8) anyerror![]u8,
    }{
        .{ .apply = ansi.green },  .{ .apply = ansi.red },
        .{ .apply = ansi.yellow }, .{ .apply = ansi.blue },
        .{ .apply = ansi.gray },   .{ .apply = ansi.cyan },
        .{ .apply = ansi.white },  .{ .apply = ansi.purple },
        .{ .apply = ansi.bold },   .{ .apply = ansi.accent },
    };

    for (fns) |entry| {
        const out = try entry.apply(std.testing.allocator, "plain");
        defer std.testing.allocator.free(out);
        try std.testing.expectEqualStrings("plain", out);
    }
}
