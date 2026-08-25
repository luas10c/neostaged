const std = @import("std");

pub fn match(pattern: []const u8, text: []const u8) bool {
    if (findFirstBraceGroup(pattern)) |group| {
        const prefix = pattern[0..group.open_idx];
        const suffix = pattern[group.close_idx + 1 ..];
        const inner = pattern[group.open_idx + 1 .. group.close_idx];

        var it = std.mem.splitScalar(u8, inner, ',');
        while (it.next()) |raw_alt| {
            const alt = std.mem.trim(u8, raw_alt, " ");
            var buf: [1024]u8 = undefined;
            const total_len = prefix.len + alt.len + suffix.len;

            if (total_len <= buf.len) {
                @memcpy(buf[0..prefix.len], prefix);
                @memcpy(buf[prefix.len .. prefix.len + alt.len], alt);
                @memcpy(buf[prefix.len + alt.len .. total_len], suffix);
                if (match(buf[0..total_len], text)) return true;
            } else {
                const sub_pattern = std.fmt.allocPrint(std.heap.page_allocator, "{s}{s}{s}", .{ prefix, alt, suffix }) catch continue;
                defer std.heap.page_allocator.free(sub_pattern);
                if (match(sub_pattern, text)) return true;
            }
        }
        return false;
    }

    return matchInner(pattern, text);
}

const BraceGroup = struct {
    open_idx: usize,
    close_idx: usize,
};

fn findFirstBraceGroup(pattern: []const u8) ?BraceGroup {
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '\\') {
            i += 1;
            continue;
        }

        if (pattern[i] == '{') {
            const open_idx = i;
            var depth: usize = 1;
            var has_comma = false;
            i += 1;

            while (i < pattern.len) : (i += 1) {
                if (pattern[i] == '\\') {
                    i += 1;
                    continue;
                }
                if (pattern[i] == '{') {
                    depth += 1;
                } else if (pattern[i] == '}') {
                    depth -= 1;
                    if (depth == 0) {
                        if (has_comma) {
                            return BraceGroup{ .open_idx = open_idx, .close_idx = i };
                        }
                        break;
                    }
                } else if (pattern[i] == ',' and depth == 1) {
                    has_comma = true;
                }
            }
        }
    }
    return null;
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
