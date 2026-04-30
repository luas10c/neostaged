const std = @import("std");

pub fn match(pattern: []const u8, text: []const u8) bool {
    return matchInner(pattern, text);
}

fn matchInner(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return text.len == 0;

    if (std.mem.startsWith(u8, pattern, "**/")) {
        if (matchInner(pattern[3..], text)) return true;

        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '/' and matchInner(pattern[3..], text[i + 1 ..])) {
                return true;
            }
        }

        return false;
    }

    if (std.mem.startsWith(u8, pattern, "**")) {
        if (matchInner(pattern[2..], text)) return true;

        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (matchInner(pattern[2..], text[i + 1 ..])) return true;
        }

        return false;
    }

    if (pattern[0] == '*') {
        if (matchInner(pattern[1..], text)) return true;

        var i: usize = 0;
        while (i < text.len and text[i] != '/') : (i += 1) {
            if (matchInner(pattern[1..], text[i + 1 ..])) return true;
        }

        return false;
    }

    if (text.len == 0) return false;

    if (pattern[0] == '?') {
        return text[0] != '/' and matchInner(pattern[1..], text[1..]);
    }

    if (pattern[0] == '\\') {
        if (pattern.len < 2) return text[0] == '\\' and matchInner(pattern[1..], text[1..]);
        return pattern[1] == text[0] and matchInner(pattern[2..], text[1..]);
    }

    if (pattern[0] == '[') {
        if (matchCharClass(pattern, text[0])) |result| {
            return result.matched and matchInner(pattern[result.next_pattern_index..], text[1..]);
        }
    }

    if (pattern[0] == text[0]) {
        return matchInner(pattern[1..], text[1..]);
    }

    return false;
}

const CharClassResult = struct {
    matched: bool,
    next_pattern_index: usize,
};

fn matchCharClass(pattern: []const u8, char: u8) ?CharClassResult {
    if (char == '/') return null;

    var i: usize = 1;
    var negated = false;

    if (i < pattern.len and (pattern[i] == '!' or pattern[i] == '^')) {
        negated = true;
        i += 1;
    }

    var matched = false;
    var has_content = false;

    while (i < pattern.len) {
        if (pattern[i] == ']' and has_content) {
            return .{
                .matched = if (negated) !matched else matched,
                .next_pattern_index = i + 1,
            };
        }

        const start = pattern[i];
        has_content = true;

        if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
            const end = pattern[i + 2];

            if (start <= char and char <= end) matched = true;
            i += 3;
            continue;
        }

        if (start == char) matched = true;
        i += 1;
    }

    return null;
}

test "glob basic wildcards" {
    try std.testing.expect(match("*.zig", "main.zig"));
    try std.testing.expect(!match("*.zig", "src/main.zig"));
    try std.testing.expect(match("src/**/*.zig", "src/foo/bar.zig"));
    try std.testing.expect(match("file?.txt", "file1.txt"));
}

test "glob character classes" {
    try std.testing.expect(match("file[123].txt", "file1.txt"));
    try std.testing.expect(match("file[a-z].txt", "filex.txt"));
    try std.testing.expect(!match("file[a-z].txt", "file9.txt"));
    try std.testing.expect(match("file[!0-9].txt", "filex.txt"));
    try std.testing.expect(!match("file[!0-9].txt", "file7.txt"));
}

test "glob escaping" {
    try std.testing.expect(match("file\\*.txt", "file*.txt"));
    try std.testing.expect(!match("file\\*.txt", "file123.txt"));
}
