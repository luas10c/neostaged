const std = @import("std");

const glob = @import("lib").glob;

test "glob basic wildcards" {
    try std.testing.expect(glob.match("*.zig", "main.zig"));
    try std.testing.expect(!glob.match("*.zig", "src/main.zig"));
    try std.testing.expect(glob.match("src/**/*.zig", "src/foo/bar.zig"));
    try std.testing.expect(glob.match("file?.txt", "file1.txt"));
}

test "glob character classes" {
    try std.testing.expect(glob.match("file[123].txt", "file1.txt"));
    try std.testing.expect(glob.match("file[a-z].txt", "filex.txt"));
    try std.testing.expect(!glob.match("file[a-z].txt", "file9.txt"));
    try std.testing.expect(glob.match("file[!0-9].txt", "filex.txt"));
    try std.testing.expect(!glob.match("file[!0-9].txt", "file7.txt"));
}

test "glob escaping" {
    try std.testing.expect(glob.match("file\\*.txt", "file*.txt"));
    try std.testing.expect(!glob.match("file\\*.txt", "file123.txt"));
}
