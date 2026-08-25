const std = @import("std");

/// Sanitize JSON5 input into valid JSON, then parse with std.json.
pub fn sanitize(input: []const u8, alloc: std.mem.Allocator) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < input.len) {
        // Unicode whitespace (multi-byte): U+00A0, U+2028, U+2029 → space
        if (matchUtf8(input, i, "\xC2\xA0")) { // NBSP
            try out.append(alloc, ' ');
            i += 2;
            continue;
        }
        if (matchUtf8(input, i, "\xE2\x80\xA8") or // LINE SEPARATOR
            matchUtf8(input, i, "\xE2\x80\xA9")) // PARAGRAPH SEPARATOR
        {
            try out.append(alloc, ' ');
            i += 3;
            continue;
        }

        // Double-quoted string: copy verbatim but handle \<newline> continuation.
        if (input[i] == '"') {
            i = try emitDoubleString(input, i, &out, alloc);
            continue;
        }

        // Single-quoted string → double-quoted JSON string.
        if (input[i] == '\'') {
            i = try emitSingleString(input, i, &out, alloc);
            continue;
        }

        // Line comment //
        if (input[i] == '/' and i + 1 < input.len and input[i + 1] == '/') {
            while (i < input.len and input[i] != '\n') i += 1;
            if (i < input.len) i += 1; // consume the newline too
            continue;
        }

        // Block comment /* */
        if (input[i] == '/' and i + 1 < input.len and input[i + 1] == '*') {
            i = skipBlockComment(input, i);
            continue;
        }

        // Trailing comma before } or ]
        if (input[i] == ',') {
            var j = i + 1;
            j = skipJson5Ignorable(input, j);
            if (j < input.len and (input[j] == '}' or input[j] == ']')) {
                i += 1;
                continue;
            }
        }

        // Unquoted object key: identifier followed by optional whitespace then ':'
        if (isIdentStart(input[i])) {
            if (tryUnquotedKey(input, i)) |key_end| {
                try out.append(alloc, '"');
                try out.appendSlice(alloc, input[i..key_end]);
                try out.append(alloc, '"');
                i = key_end;
                continue;
            }
        }

        // Numbers: Infinity, NaN, ±Infinity, ±NaN
        if (try matchNumberKeyword(input, i, "Infinity", &out, alloc)) continue;
        if (try matchNumberKeyword(input, i, "NaN", &out, alloc)) continue;

        // +/- prefixed numbers
        if (input[i] == '+' or input[i] == '-') {
            const negative = input[i] == '-';
            const rest = input[i + 1 ..];

            if (matchSlice(rest, 0, "Infinity") or matchSlice(rest, 0, "NaN")) {
                if (negative) try out.append(alloc, '-');
                if (matchSlice(rest, 0, "Infinity")) {
                    try out.appendSlice(alloc, "1e999");
                    i += 1 + "Infinity".len;
                } else {
                    try out.appendSlice(alloc, "null");
                    i += 1 + "NaN".len;
                }
                continue;
            }

            if (rest.len > 0 and rest[0] == '0' and rest.len > 1 and isHexPrefix(rest)) {
                var j: usize = i + 3;
                while (j < input.len and isHexDigit(input[j])) j += 1;
                try emitHexNumber(alloc, &out, input[i + 3 .. j], negative);
                i = j;
                continue;
            }

            if (rest.len > 0 and (std.ascii.isDigit(rest[0]) or rest[0] == '.')) {
                const number_start = i + 1;
                var j = number_start;
                while (j < input.len and isNumberChar(input[j])) j += 1;

                if (negative) try out.append(alloc, '-');
                try emitNumberToken(alloc, &out, input[number_start..j]);

                i = j;
                continue;
            }

            // Bare '+'/'-' outside any number context: keep verbatim.
            try out.append(alloc, input[i]);
            i += 1;
            continue;
        }

        // Hex numbers without sign: 0x...
        if (isHexPrefixAt(input, i)) {
            var j = i + 2;
            while (j < input.len and isHexDigit(input[j])) j += 1;
            try emitHexNumber(alloc, &out, input[i + 2 .. j], false);
            i = j;
            continue;
        }

        // Numbers (including leading/trailing dot fixes like .5 → 0.5, 1. → 1.0)
        if (std.ascii.isDigit(input[i]) or
            (input[i] == '.' and i + 1 < input.len and std.ascii.isDigit(input[i + 1])))
        {
            var j = i;
            while (j < input.len and isNumberChar(input[j])) j += 1;

            try emitNumberToken(alloc, &out, input[i..j]);
            i = j;
            continue;
        }

        try out.append(alloc, input[i]);
        i += 1;
    }

    return out.toOwnedSlice(alloc);
}

fn isHexPrefix(input: []const u8) bool {
    return input[0] == '0' and input.len > 1 and (input[1] == 'x' or input[1] == 'X');
}

fn isHexPrefixAt(input: []const u8, pos: usize) bool {
    return pos + 1 < input.len and input[pos] == '0' and
        (input[pos + 1] == 'x' or input[pos + 1] == 'X');
}

fn matchNumberKeyword(
    input: []const u8,
    pos: usize,
    keyword: []const u8,
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
) !bool {
    if (!matchSlice(input, pos, keyword)) return false;

    if (std.mem.eql(u8, keyword, "Infinity")) {
        try out.appendSlice(alloc, "1e999");
    } else {
        try out.appendSlice(alloc, "null");
    }

    return true;
}

/// Emits a normalized JSON number token: fixes leading/trailing dots.
fn emitNumberToken(
    alloc: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    token: []const u8,
) !void {
    if (token.len == 0) return;

    if (token[0] == '.') try out.append(alloc, '0');

    try out.appendSlice(alloc, token);

    if (token[token.len - 1] == '.') try out.append(alloc, '0');
}

fn emitHexNumber(
    alloc: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    hex_str: []const u8,
    negative: bool,
) !void {
    const value: u128 = std.fmt.parseInt(u64, hex_str, 16) catch |err| switch (err) {
        error.Overflow => std.fmt.parseInt(u128, hex_str, 16) catch {
            return error.HexNumberOutOfRange;
        },
        else => return err,
    };

    var tmp_buf: [48]u8 = undefined;
    const dec = if (negative)
        std.fmt.bufPrint(&tmp_buf, "-{d}", .{value}) catch unreachable
    else
        std.fmt.bufPrint(&tmp_buf, "{d}", .{value}) catch unreachable;

    try out.appendSlice(alloc, dec);
}

/// Writes `c` as part of a JSON string body, escaping what JSON forbids raw.
fn emitStringChar(
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    c: u8,
) !void {
    switch (c) {
        0x08 => try out.appendSlice(alloc, "\\b"),
        0x09 => try out.appendSlice(alloc, "\\t"),
        0x0A => try out.appendSlice(alloc, "\\n"),
        0x0C => try out.appendSlice(alloc, "\\f"),
        0x0D => try out.appendSlice(alloc, "\\r"),
        else => {
            if (c < 0x20) {
                var tmp: [6]u8 = undefined;
                const esc = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable;
                try out.appendSlice(alloc, esc);
            } else {
                try out.append(alloc, c);
            }
        },
    }
}

/// Handles the shared escape machinery after a backslash inside a string.
/// Newline continuations (\ + LF / CRLF) are handled by the callers.
/// Returns true when the escape was consumed; false when the caller should
/// treat the backslash literally (invalid escape sequences stay verbatim so
/// the final JSON parser reports them).
fn consumeStringEscape(
    input: []const u8,
    backslash_pos: usize,
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
) !bool {
    if (backslash_pos + 1 >= input.len) return false;
    const next = input[backslash_pos + 1];

    switch (next) {
        'v' => {
            try out.appendSlice(alloc, "\\u000B");
            return true;
        },
        '0' => {
            try out.appendSlice(alloc, "\\u0000");
            return true;
        },
        'x' => {
            if (backslash_pos + 3 < input.len) {
                const hi = hexValue(input[backslash_pos + 2]);
                const lo = hexValue(input[backslash_pos + 3]);
                if (hi != null and lo != null) {
                    try emitStringChar(out, alloc, hi.? * 16 + lo.?);
                    return true;
                }
            }
            return false;
        },
        else => return false,
    }
}

fn skipBlockComment(input: []const u8, start: usize) usize {
    var i = start + 2;
    while (i + 1 < input.len) : (i += 1) {
        if (input[i] == '*' and input[i + 1] == '/') {
            return i + 2;
        }
    }
    return input.len;
}

/// Emit a double-quoted string, handling escapes, line continuations,
/// \xNN sequences and raw control characters.
/// Returns new position after closing quote.
fn emitDoubleString(input: []const u8, start: usize, out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) !usize {
    var i = start;
    try out.append(alloc, '"');
    i += 1;
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            const next = input[i + 1];

            if (next == '\n' or next == '\r') {
                // line continuation: skip backslash + newline(s)
                i += 2;
                if (next == '\r' and i < input.len and input[i] == '\n') i += 1;
                continue;
            }

            if (try consumeStringEscape(input, i, out, alloc)) {
                i += if (input[i + 1] == 'x') 4 else 2;
                continue;
            }

            try out.append(alloc, '\\');
            try out.append(alloc, next);
            i += 2;
            continue;
        }

        if (input[i] == '"') {
            try out.append(alloc, '"');
            i += 1;
            break;
        }

        if (input[i] < 0x20) {
            // Raw control character: JSON forbids it raw, escape it.
            try emitStringChar(out, alloc, input[i]);
            i += 1;
            continue;
        }

        try out.append(alloc, input[i]);
        i += 1;
    }
    return i;
}

/// Emit a single-quoted string as a double-quoted JSON string.
/// Returns new position after closing quote.
fn emitSingleString(input: []const u8, start: usize, out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) !usize {
    var i = start;
    try out.append(alloc, '"');
    i += 1; // skip opening '
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            const next = input[i + 1];

            if (next == '\'') {
                try out.append(alloc, '\'');
                i += 2;
                continue;
            }

            if (next == '\n' or next == '\r') {
                i += 2;
                if (next == '\r' and i < input.len and input[i] == '\n') i += 1;
                continue;
            }

            if (try consumeStringEscape(input, i, out, alloc)) {
                i += if (input[i + 1] == 'x') 4 else 2;
                continue;
            }

            try out.append(alloc, '\\');
            try out.append(alloc, next);
            i += 2;
            continue;
        }

        if (input[i] == '\'') {
            try out.append(alloc, '"');
            i += 1;
            break;
        }

        if (input[i] == '"') {
            try out.appendSlice(alloc, "\\\"");
            i += 1;
            continue;
        }

        if (input[i] < 0x20) {
            try emitStringChar(out, alloc, input[i]);
            i += 1;
            continue;
        }

        try out.append(alloc, input[i]);
        i += 1;
    }
    return i;
}

/// If input[pos..] starts with an unquoted identifier followed by optional whitespace
/// then ':', return the end position of the identifier (exclusive). Otherwise null.
fn tryUnquotedKey(input: []const u8, pos: usize) ?usize {
    if (pos >= input.len or !isIdentStart(input[pos])) return null;
    var j = pos + 1;
    while (j < input.len and isIdentCont(input[j])) j += 1;
    // skip whitespace and comments
    var k = j;
    while (k < input.len) {
        if (isAsciiWhitespace(input[k])) {
            k += 1;
            continue;
        }
        if (input[k] == '/' and k + 1 < input.len and input[k + 1] == '/') {
            while (k < input.len and input[k] != '\n') k += 1;
            continue;
        }
        if (input[k] == '/' and k + 1 < input.len and input[k + 1] == '*') {
            k = skipBlockComment(input, k);
            continue;
        }
        break;
    }
    if (k < input.len and input[k] == ':') return j;
    return null;
}

fn skipJson5Ignorable(input: []const u8, start: usize) usize {
    var i = start;
    while (i < input.len) {
        if (isAsciiWhitespace(input[i])) {
            i += 1;
            continue;
        }
        // NBSP
        if (matchUtf8(input, i, "\xC2\xA0")) {
            i += 2;
            continue;
        }
        // LS / PS
        if (matchUtf8(input, i, "\xE2\x80\xA8") or matchUtf8(input, i, "\xE2\x80\xA9")) {
            i += 3;
            continue;
        }
        // Line comment //
        if (input[i] == '/' and i + 1 < input.len and input[i + 1] == '/') {
            while (i < input.len and input[i] != '\n') i += 1;
            continue;
        }
        // Block comment
        if (input[i] == '/' and i + 1 < input.len and input[i + 1] == '*') {
            i = skipBlockComment(input, i);
            continue;
        }
        break;
    }
    return i;
}

fn matchUtf8(input: []const u8, pos: usize, seq: []const u8) bool {
    if (pos + seq.len > input.len) return false;
    return std.mem.eql(u8, input[pos .. pos + seq.len], seq);
}

fn matchSlice(input: []const u8, pos: usize, needle: []const u8) bool {
    return matchUtf8(input, pos, needle);
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
}

fn isIdentCont(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

fn isAsciiWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn isNumberChar(c: u8) bool {
    return std.ascii.isDigit(c) or c == '.' or c == 'e' or c == 'E' or c == '+' or c == '-';
}

/// Parse JSON5 input into a std.json.Value.
/// Caller owns the returned Parsed value and must call `.deinit()`.
pub fn parse(input: []const u8, alloc: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
    const clean = try sanitize(input, alloc);
    defer alloc.free(clean);

    return std.json.parseFromSlice(std.json.Value, alloc, clean, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

test "sanitize single quotes, comments, trailing comma, unquoted keys" {
    const parsed = try parse(
        \\{
        \\  // comment
        \\  '**/*.zig': ['eslint --fix', /* inline */ 'prettier --write'], // trailing
        \\}
    , std.testing.allocator);
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
}

test "sanitize hex and unicode escapes" {
    const parsed = try parse("{ 'a': '\\x41\\u00e9' }", std.testing.allocator);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Aé", parsed.value.object.get("a").?.string);
}

test "sanitize numbers" {
    const parsed = try parse("{ a: .5, b: 0xFF, c: 1., d: -.25 }", std.testing.allocator);
    defer parsed.deinit();

    const object = parsed.value.object;
    try std.testing.expectEqual(@as(f64, 0.5), object.get("a").?.float);
    try std.testing.expectEqual(@as(f64, 255.0), @as(f64, @floatFromInt(object.get("b").?.integer)));
    try std.testing.expectEqual(@as(f64, 1.0), object.get("c").?.float);
    try std.testing.expectEqual(@as(f64, -0.25), object.get("d").?.float);
}
