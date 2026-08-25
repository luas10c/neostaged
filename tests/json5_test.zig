const std = @import("std");

const json5 = @import("lib").json5;

const parse = json5.parse;

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
