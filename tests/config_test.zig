const std = @import("std");

const config = @import("lib").config;
const json5 = @import("lib").json5;

const bodyOf = config.javascriptConfigBody;

test "plain export default object" {
    const body = try bodyOf(
        \\export default {
        \\  tasks: {
        \\    '**/*.ts': ['eslint --fix']
        \\  }
        \\}
    );

    try std.testing.expectEqualStrings(
        "{\n  tasks: {\n    '**/*.ts': ['eslint --fix']\n  }\n}",
        body,
    );
}

test "module.exports object with trailing semicolon" {
    const body = try bodyOf("module.exports = { '*.js': 'eslint --fix' };");

    try std.testing.expectEqualStrings("{ '*.js': 'eslint --fix' }", body);
}

test "defineConfig call from neostaged/config" {
    const body = try bodyOf(
        \\import { defineConfig } from 'neostaged/config'
        \\
        \\export default defineConfig({
        \\   ignores: [],
        \\   tasks: {
        \\      '**/*.ts': []
        \\   }
        \\})
    );

    try std.testing.expectEqualStrings(
        "{\n   ignores: [],\n   tasks: {\n      '**/*.ts': []\n   }\n}",
        body,
    );
}

test "defineConfig import without semicolon and call with trailing semicolon" {
    const body = try bodyOf(
        \\import { defineConfig } from "neostaged/config"
        \\
        \\export default defineConfig({ tasks: { '*': 'true' } });
    );

    try std.testing.expectEqualStrings("{ tasks: { '*': 'true' } }", body);
}

test "multiline import statement" {
    const body = try bodyOf(
        \\import {
        \\  defineConfig
        \\} from 'neostaged/config';
        \\
        \\export default defineConfig({ ignores: ['**/dist/**'] })
    );

    try std.testing.expectEqualStrings("{ ignores: ['**/dist/**'] }", body);
}

test "comments before export" {
    const body = try bodyOf(
        \\// neostaged config
        \\/* block comment */
        \\export default { '*': 'true' }
    );

    try std.testing.expectEqualStrings("{ '*': 'true' }", body);
}

test "require destructure and module.exports defineConfig" {
    const body = try bodyOf(
        \\const { defineConfig } = require('neostaged/config')
        \\
        \\module.exports = defineConfig({ tasks: { '*.md': 'prettier --write' } });
    );

    try std.testing.expectEqualStrings("{ tasks: { '*.md': 'prettier --write' } }", body);
}

test "plain const declaration is not swallowed" {
    try std.testing.expectError(
        error.UnsupportedJavascriptConfig,
        bodyOf(
            \\const tasks = { '*': 'true' }
            \\
            \\export default tasks
        ),
    );
}

test "require indirection leaves identifier for json5 to reject" {
    const body = try bodyOf(
        \\const config = require('./other-config.js')
        \\
        \\module.exports = config
    );

    try std.testing.expectEqualStrings("config", body);
}

test "missing export prefix fails" {
    try std.testing.expectError(error.UnsupportedJavascriptConfig, bodyOf("{ '*': 'true' }"));
}

test "defineConfig body parses as json5" {
    const contents =
        \\import { defineConfig } from 'neostaged/config'
        \\
        \\export default defineConfig({
        \\  ignores: [
        \\    '**/*.min.js', // build output
        \\  ],
        \\  tasks: {
        \\    '**/*.{js,ts}': ['eslint --fix'],
        \\    '*.css': 'stylelint --fix',
        \\  },
        \\})
    ;

    var parsed = try json5.parse(try bodyOf(contents), std.testing.allocator);
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expect(root.get("ignores").? == .array);
    try std.testing.expectEqual(@as(usize, 1), root.get("ignores").?.array.items.len);

    const tasks = root.get("tasks").?.object;
    try std.testing.expect(tasks.get("**/*.{js,ts}") != null);
    try std.testing.expect(tasks.get("**/*.{js,ts}").? == .array);
}
