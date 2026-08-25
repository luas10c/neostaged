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

test "glob brace expansion" {
    try std.testing.expect(glob.match("**/*.{js,ts}", "src/index.js"));
    try std.testing.expect(glob.match("**/*.{js,ts}", "src/index.ts"));
    try std.testing.expect(glob.match("**/*.{js,ts}", "deep/nested/path/app.ts"));
    try std.testing.expect(!glob.match("**/*.{js,ts}", "src/index.css"));
    try std.testing.expect(!glob.match("**/*.{js,ts}", "src/index.json"));

    try std.testing.expect(glob.match("*.{js,ts,tsx}", "app.tsx"));
    try std.testing.expect(glob.match("*.{js,ts,tsx}", "app.js"));
    try std.testing.expect(glob.match("*.{js,ts,tsx}", "app.ts"));
    try std.testing.expect(!glob.match("*.{js,ts,tsx}", "app.jsx"));

    try std.testing.expect(glob.match("src/{components,utils}/*.{js,ts}", "src/components/button.ts"));
    try std.testing.expect(glob.match("src/{components,utils}/*.{js,ts}", "src/utils/format.js"));
    try std.testing.expect(!glob.match("src/{components,utils}/*.{js,ts}", "src/views/main.js"));

    try std.testing.expect(glob.match("**/*.{js, ts}", "src/index.ts")); // whitespace handling
}
