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
            i += 2;
            while (i + 1 < input.len) {
                if (input[i] == '*' and input[i + 1] == '/') {
                    i += 2;
                    break;
                }
                i += 1;
            }
            continue;
        }

        // Trailing comma before } or ]
        if (input[i] == ',') {
            var j = i + 1;
            j = skipJson5Whitespace(input, j);
            if (j < input.len and (input[j] == '}' or input[j] == ']')) {
                i += 1;
                continue;
            }
        }

        // Unquoted object key: after { or , (with optional whitespace), a bare identifier
        // We detect: we're at a position where an identifier char starts and we're in key position.
        // Simpler: if current char is identifier-start and not a digit, and context expects a key.
        // Strategy: scan ahead — if identifier followed by optional-ws then ':', it's an unquoted key.
        if (isIdentStart(input[i])) {
            if (tryUnquotedKey(input, i)) |key_end| {
                try out.append(alloc, '"');
                try out.appendSlice(alloc, input[i..key_end]);
                try out.append(alloc, '"');
                i = key_end;
                continue;
            }
        }

        // Numbers: Infinity, NaN, +Infinity, +NaN, -Infinity, -NaN, +digits, hex, leading/trailing dot
        if (input[i] == 'I' and matchSlice(input, i, "Infinity")) {
            try out.appendSlice(alloc, "1e999");
            i += "Infinity".len;
            continue;
        }
        if (input[i] == 'N' and matchSlice(input, i, "NaN")) {
            // JSON has no NaN — emit null as closest representable (or a string hack)
            // Per JSON5 spec, NaN is unrepresentable in JSON; we emit a sentinel float string
            // that std.json won't parse as float. Best option: keep as string token won't work.
            // We use the trick: emit a number string the parser accepts, then note in parse().
            // Actually std.json parses numbers as integer/float — emit "null" so caller gets .null.
            try out.appendSlice(alloc, "null");
            i += "NaN".len;
            continue;
        }

        // +Infinity / +NaN / +digits / +.digits
        if (input[i] == '+') {
            const rest = input[i + 1 ..];
            if (matchSlice(rest, 0, "Infinity")) {
                try out.appendSlice(alloc, "1e999");
                i += 1 + "Infinity".len;
                continue;
            }
            if (matchSlice(rest, 0, "NaN")) {
                try out.appendSlice(alloc, "null");
                i += 1 + "NaN".len;
                continue;
            }
            // +digits or +.digits → strip the + and emit the full number token
            if (rest.len > 0 and (std.ascii.isDigit(rest[0]) or rest[0] == '.')) {
                i += 1; // skip +
                // emit full number token from new i
                var j = i;
                while (j < input.len and isNumberChar(input[j])) j += 1;
                // fix leading dot: .5 → 0.5
                if (input[i] == '.') try out.append(alloc, '0');
                // fix trailing dot: 3. → 3.0
                if (j > i and input[j - 1] == '.') {
                    try out.appendSlice(alloc, input[i..j]);
                    try out.append(alloc, '0');
                } else {
                    try out.appendSlice(alloc, input[i..j]);
                }
                i = j;
                continue;
            } else {
                try out.append(alloc, input[i]);
                i += 1;
                continue;
            }
        }

        // -Infinity / -NaN
        if (input[i] == '-' and i + 1 < input.len) {
            if (matchSlice(input, i + 1, "Infinity")) {
                try out.appendSlice(alloc, "-1e999");
                i += 1 + "Infinity".len;
                continue;
            }
            if (matchSlice(input, i + 1, "NaN")) {
                try out.appendSlice(alloc, "null");
                i += 1 + "NaN".len;
                continue;
            }
        }

        // Hex numbers: 0x... / 0X...
        if (input[i] == '0' and i + 1 < input.len and (input[i + 1] == 'x' or input[i + 1] == 'X')) {
            var j = i + 2;
            while (j < input.len and isHexDigit(input[j])) j += 1;
            const hex_str = input[i + 2 .. j];
            const val = try std.fmt.parseInt(u64, hex_str, 16);
            var tmp_buf: [32]u8 = undefined;
            const dec = std.fmt.bufPrint(&tmp_buf, "{d}", .{val}) catch unreachable;
            try out.appendSlice(alloc, dec);
            i = j;
            continue;
        }

        // -0x... negative hex
        if (input[i] == '-' and i + 1 < input.len and input[i + 1] == '0' and
            i + 2 < input.len and (input[i + 2] == 'x' or input[i + 2] == 'X'))
        {
            var j = i + 3;
            while (j < input.len and isHexDigit(input[j])) j += 1;
            const hex_str = input[i + 3 .. j];
            const val = try std.fmt.parseInt(u64, hex_str, 16);
            var tmp_buf: [33]u8 = undefined;
            const dec = std.fmt.bufPrint(&tmp_buf, "-{d}", .{val}) catch unreachable;
            try out.appendSlice(alloc, dec);
            i = j;
            continue;
        }

        // Leading decimal point: .digits → 0.digits
        if (input[i] == '.' and i + 1 < input.len and std.ascii.isDigit(input[i + 1])) {
            try out.append(alloc, '0');
            // emit . and rest of number
            var j = i;
            while (j < input.len and (std.ascii.isDigit(input[j]) or input[j] == '.' or
                input[j] == 'e' or input[j] == 'E' or input[j] == '+' or input[j] == '-')) j += 1;
            try out.appendSlice(alloc, input[i..j]);
            i = j;
            continue;
        }

        // Negative leading decimal: -.digits → -0.digits
        if (input[i] == '-' and i + 1 < input.len and input[i + 1] == '.' and
            i + 2 < input.len and std.ascii.isDigit(input[i + 2]))
        {
            try out.appendSlice(alloc, "-0");
            i += 1; // skip -, then emit .digits normally
            // fall through to emit .digits
            var j = i;
            while (j < input.len and (std.ascii.isDigit(input[j]) or input[j] == '.' or
                input[j] == 'e' or input[j] == 'E' or input[j] == '+' or input[j] == '-')) j += 1;
            try out.appendSlice(alloc, input[i..j]);
            i = j;
            continue;
        }

        // Trailing decimal point: digits. → digits.0
        // Also handles normal integers/floats by emitting the full token.
        if (std.ascii.isDigit(input[i]) or
            (input[i] == '-' and i + 1 < input.len and std.ascii.isDigit(input[i + 1])))
        {
            // scan full number token
            var j = i;
            if (input[j] == '-') j += 1;
            while (j < input.len and std.ascii.isDigit(input[j])) j += 1;
            // optional fractional part
            if (j < input.len and input[j] == '.') {
                j += 1;
                while (j < input.len and std.ascii.isDigit(input[j])) j += 1;
            }
            // optional exponent
            if (j < input.len and (input[j] == 'e' or input[j] == 'E')) {
                j += 1;
                if (j < input.len and (input[j] == '+' or input[j] == '-')) j += 1;
                while (j < input.len and std.ascii.isDigit(input[j])) j += 1;
            }
            // trailing dot? (e.g. "1.") → append "0"
            const tok = input[i..j];
            try out.appendSlice(alloc, tok);
            if (tok.len >= 2 and tok[tok.len - 1] == '.') {
                try out.append(alloc, '0');
            }
            i = j;
            continue;
        }

        try out.append(alloc, input[i]);
        i += 1;
    }

    return out.toOwnedSlice(alloc);
}

/// Emit a double-quoted string, handling \<newline> line continuations.
/// Returns new position after closing quote.
fn emitDoubleString(input: []const u8, start: usize, out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) !usize {
    var i = start;
    try out.append(alloc, '"');
    i += 1;
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            const next = input[i + 1];
            if (next == '\n') {
                // line continuation: skip both chars
                i += 2;
                continue;
            }
            if (next == '\r') {
                // \r\n continuation
                i += 2;
                if (i < input.len and input[i] == '\n') i += 1;
                continue;
            }
            // \v: emit \u000B (vertical tab)
            if (next == 'v') {
                try out.appendSlice(alloc, "\\u000B");
                i += 2;
                continue;
            }
            // \0: emit \u0000 (null)
            if (next == '0') {
                try out.appendSlice(alloc, "\\u0000");
                i += 2;
                continue;
            }
            try out.append(alloc, '\\');
            try out.append(alloc, next);
            i += 2;
        } else if (input[i] == '"') {
            try out.append(alloc, '"');
            i += 1;
            break;
        } else {
            try out.append(alloc, input[i]);
            i += 1;
        }
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
            if (next == '\n') {
                i += 2;
                continue;
            }
            if (next == '\r') {
                i += 2;
                if (i < input.len and input[i] == '\n') i += 1;
                continue;
            }
            if (next == 'v') {
                try out.appendSlice(alloc, "\\u000B");
                i += 2;
                continue;
            }
            if (next == '0') {
                try out.appendSlice(alloc, "\\u0000");
                i += 2;
                continue;
            }
            try out.append(alloc, '\\');
            try out.append(alloc, next);
            i += 2;
        } else if (input[i] == '\'') {
            try out.append(alloc, '"');
            i += 1;
            break;
        } else if (input[i] == '"') {
            try out.append(alloc, '\\');
            try out.append(alloc, '"');
            i += 1;
        } else {
            try out.append(alloc, input[i]);
            i += 1;
        }
    }
    return i;
}

/// If input[pos..] starts with an unquoted identifier followed by optional whitespace
/// then ':', return the end position of the identifier (exclusive). Otherwise null.
fn tryUnquotedKey(input: []const u8, pos: usize) ?usize {
    if (pos >= input.len or !isIdentStart(input[pos])) return null;
    var j = pos + 1;
    while (j < input.len and isIdentCont(input[j])) j += 1;
    // skip whitespace
    var k = j;
    while (k < input.len and isAsciiWhitespace(input[k])) k += 1;
    if (k < input.len and input[k] == ':') return j;
    return null;
}

fn skipJson5Whitespace(input: []const u8, start: usize) usize {
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
