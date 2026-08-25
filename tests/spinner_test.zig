const std = @import("std");

const spinner = @import("lib").spinner;

test "visibleLen counts ascii, utf8 codepoints and skips ansi escapes" {
    try std.testing.expectEqual(@as(usize, 0), spinner.visibleLen(""));
    try std.testing.expectEqual(@as(usize, 5), spinner.visibleLen("hello"));

    // Multi-byte characters count as one display column each.
    try std.testing.expectEqual(@as(usize, 2), spinner.visibleLen("áé"));
    try std.testing.expectEqual(@as(usize, 1), spinner.visibleLen("\u{2502}")); // │
    try std.testing.expectEqual(@as(usize, 1), spinner.visibleLen("\u{2713}")); // ✓
    try std.testing.expectEqual(@as(usize, 3), spinner.visibleLen("a✓b"));

    // ANSI escape sequences occupy no columns.
    try std.testing.expectEqual(@as(usize, 1), spinner.visibleLen("\x1b[32mA\x1b[0m"));
    try std.testing.expectEqual(@as(usize, 3), spinner.visibleLen("\x1b[1;36mabc\x1b[0m"));
    try std.testing.expectEqual(@as(usize, 2), spinner.visibleLen("\u{2502}\x1b[90mx\x1b[0m"));
}

test "visibleLen matches codepoint count for plain text" {
    // ASCII: columns == bytes.
    const ascii = "sleep 0.25 - 10 files";
    try std.testing.expectEqual(ascii.len, spinner.visibleLen(ascii));

    // "·" is one display column despite being two UTF-8 bytes.
    const sample = "sleep 0.25 · 10 files";
    try std.testing.expectEqual(@as(usize, 21), spinner.visibleLen(sample));
}

test "spinner themes are well formed" {
    try std.testing.expect(spinner.themes.len > 0);

    for (spinner.themes) |theme| {
        try std.testing.expect(theme.name.len > 0);
        try std.testing.expect(theme.glyphs.len > 0);
        for (theme.glyphs) |glyph| {
            try std.testing.expect(glyph.len > 0);
        }
    }

    // Theme names must stay unique so NEOSTAGED_SPINNER stays unambiguous.
    for (spinner.themes, 0..) |a, i| {
        for (spinner.themes[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
        }
    }
}

test "spinner frames are non-empty" {
    try std.testing.expect(spinner.frames.len > 0);
    for (spinner.frames) |frame| {
        try std.testing.expect(frame.len > 0);
    }
}

test "termWidth always reports a sane minimum" {
    // Falls back to 80 when the ioctl is unavailable (CI, pipes).
    try std.testing.expect(spinner.termWidth() >= 40);
}
