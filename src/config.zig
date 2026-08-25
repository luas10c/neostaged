const std = @import("std");
const json5 = @import("json5.zig");

const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;
const MAX_CONFIG_BYTES: usize = 16 * 1024 * 1024;

const search_places = [_][]const u8{ ".neostaged.json", "neostaged.json", "neostaged.config.json", ".neostagedrc", "package.json", ".neostaged.js", "neostaged.js", "neostaged.config.js", ".neostaged.cjs", "neostaged.cjs", "neostaged.config.cjs", ".neostaged.mjs", "neostaged.mjs", "neostaged.config.mjs" };

const package_json_keys = [_][]const u8{
    "neostaged",
};

pub const LoadedConfig = struct {
    allocator: Allocator,
    path: []u8,
    parsed: std.json.Parsed(JsonValue),
    value: JsonValue,

    pub fn deinit(self: *LoadedConfig) void {
        self.parsed.deinit();
        self.allocator.free(self.path);
        self.* = undefined;
    }
};

pub fn load(
    io: std.Io,
    allocator: Allocator,
    start_dir: []const u8,
    explicit_path: ?[]const u8,
) !LoadedConfig {
    if (explicit_path) |path| {
        // Relative --config paths are interpreted against the run directory,
        // not against the process working directory.
        const resolved = if (std.fs.path.isAbsolute(path))
            path
        else blk: {
            const joined = try std.fs.path.join(allocator, &.{ start_dir, path });
            break :blk joined;
        };
        defer if (resolved.ptr != path.ptr) allocator.free(resolved);

        _ = std.Io.Dir.cwd().statFile(io, resolved, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.ConfigNotFound,
            else => return err,
        };

        return loadFromPath(io, allocator, resolved);
    }

    return searchFrom(io, allocator, start_dir);
}

/// Returns the path of the nearest config file that exists in `dir` (checked
/// in priority order), or null when none of the candidates exist. A
/// package.json only counts when it actually carries a neostaged config.
/// Existence checks are cheap stats; no config content is parsed except a
/// package.json that exists (to honour its optional nature).
pub fn findConfigPathInDir(
    io: std.Io,
    allocator: Allocator,
    dir: []const u8,
) !?[]u8 {
    for (search_places) |file_name| {
        const candidate = try std.fs.path.join(allocator, &.{ dir, file_name });
        errdefer allocator.free(candidate);

        _ = std.Io.Dir.cwd().statFile(io, candidate, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                allocator.free(candidate);
                continue;
            },
            else => return err,
        };

        if (std.mem.eql(u8, file_name, "package.json")) {
            const maybe_loaded = try loadPackageJsonConfig(io, allocator, candidate);

            if (maybe_loaded) |loaded| {
                // Discard the probe result; the caller loads the path again.
                loaded.parsed.deinit();
                allocator.free(loaded.path);
                return candidate;
            }

            allocator.free(candidate);
            continue;
        }

        return candidate;
    }

    return null;
}

pub fn loadFromPath(io: std.Io, allocator: Allocator, path: []const u8) !LoadedConfig {
    const file_name = std.fs.path.basename(path);

    if (std.mem.eql(u8, file_name, "package.json")) {
        return (try loadPackageJsonConfig(io, allocator, path)) orelse error.PackageJsonMissingNeostaged;
    }

    if (isJsonConfig(file_name)) {
        var parsed = try loadJsonFile(io, allocator, path);
        errdefer parsed.deinit();

        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);

        return .{
            .allocator = allocator,
            .path = owned_path,
            .parsed = parsed,
            .value = parsed.value,
        };
    }

    if (isJavascriptConfig(file_name)) {
        var parsed = try loadJavascriptFile(io, allocator, path);
        errdefer parsed.deinit();

        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);

        return .{
            .allocator = allocator,
            .path = owned_path,
            .parsed = parsed,
            .value = parsed.value,
        };
    }

    return error.UnsupportedConfigFile;
}

fn searchFrom(io: std.Io, allocator: Allocator, start_dir: []const u8) !LoadedConfig {
    const found = try findConfigPathInDir(io, allocator, start_dir);
    const found_path = found orelse return error.ConfigNotFound;
    defer allocator.free(found_path);

    return loadFromPath(io, allocator, found_path);
}

fn loadPackageJsonConfig(io: std.Io, allocator: Allocator, path: []const u8) !?LoadedConfig {
    var parsed = try loadJsonFile(io, allocator, path);
    errdefer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.PackageJsonMustBeObject,
    };

    for (package_json_keys) |key| {
        if (object.get(key)) |config_value| {
            const owned_path = try allocator.dupe(u8, path);
            errdefer allocator.free(owned_path);

            return .{
                .allocator = allocator,
                .path = owned_path,
                .parsed = parsed,
                .value = config_value,
            };
        }
    }

    parsed.deinit();
    return null;
}

fn loadJsonFile(
    io: std.Io,
    allocator: Allocator,
    path: []const u8,
) !std.json.Parsed(JsonValue) {
    const contents = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(MAX_CONFIG_BYTES),
    );
    defer allocator.free(contents);

    const file_name = std.fs.path.basename(path);

    if (shouldUseJson5(file_name)) {
        return json5.parse(contents, allocator);
    }

    return std.json.parseFromSlice(
        JsonValue,
        allocator,
        contents,
        .{ .allocate = .alloc_always },
    );
}

fn loadJavascriptFile(io: std.Io, allocator: Allocator, path: []const u8) !std.json.Parsed(JsonValue) {
    const contents = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(MAX_CONFIG_BYTES),
    );
    defer allocator.free(contents);

    const body = try javascriptConfigBody(contents);
    return json5.parse(body, allocator);
}

/// Reduces a JS config file down to the raw object-literal body that can be
/// handed to the JSON5 parser. Understands ESM/CJS export forms, skips any
/// leading comments and `import` statements (e.g. `defineConfig` imported
/// from `neostaged/config`) and unwraps `defineConfig({ ... })` calls.
pub fn javascriptConfigBody(contents: []const u8) ![]const u8 {
    var body = std.mem.trim(u8, contents, " \n\r\t");
    body = skipPrelude(body);
    body = try stripExportPrefix(body);

    body = std.mem.trim(u8, body, " \n\r\t");

    if (body.len != 0 and body[body.len - 1] == ';') {
        body = body[0 .. body.len - 1];
    }

    body = unwrapDefineConfig(body);

    return std.mem.trim(u8, body, " \n\r\t");
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\r' or c == '\t';
}

/// Skips leading whitespace, comments and whole `import ...` statements so
/// that only the exported value (or whatever follows them) remains.
fn skipPrelude(body: []const u8) []const u8 {
    var i: usize = 0;

    while (i < body.len) {
        while (i < body.len and isWhitespace(body[i])) : (i += 1) {}
        if (i == body.len) break;

        const rest = body[i..];

        if (std.mem.startsWith(u8, rest, "//")) {
            while (i < body.len and body[i] != '\n') : (i += 1) {}
            continue;
        }

        if (std.mem.startsWith(u8, rest, "/*")) {
            const close = std.mem.indexOfPos(u8, body, i + 2, "*/") orelse return body[i..];
            i = close + "*/".len;
            continue;
        }

        if (isImportStatement(rest)) {
            i = skipBalancedStatement(body, i);
            continue;
        }

        if (isRequireDestructureStatement(rest)) {
            const end = skipBalancedStatement(body, i);
            // Only swallow the declaration when it really pulls from a
            // module (`const { defineConfig } = require('neostaged/config')`);
            // plain constants are left alone so their misuse still errors
            // loudly downstream.
            if (std.mem.indexOf(u8, body[i..end], "require(") == null) break;
            i = end;
            continue;
        }

        break;
    }

    return body[i..];
}

fn isImportStatement(rest: []const u8) bool {
    if (!std.mem.startsWith(u8, rest, "import")) return false;
    if (rest.len == "import".len) return false;

    return switch (rest["import".len]) {
        ' ', '\n', '\r', '\t', '{', '*', '\'', '"', '(' => true,
        else => false,
    };
}

fn isRequireDestructureStatement(rest: []const u8) bool {
    if (!std.mem.startsWith(u8, rest, "const")) return false;
    if (rest.len == "const".len) return false;

    return isWhitespace(rest["const".len]);
}

/// Consumes one top-level declaration, stopping after its terminating `;`
/// or at the newline that closes it when the semicolon is omitted. Braces,
/// brackets and parentheses are tracked so multi-line statements
/// (`import {\n  defineConfig\n} from '...'`) survive.
fn skipBalancedStatement(body: []const u8, start: usize) usize {
    var i = start;
    var depth: usize = 0;

    while (i < body.len) : (i += 1) {
        switch (body[i]) {
            '{', '(', '[' => depth += 1,
            '}', ')', ']' => {
                if (depth > 0) depth -= 1;
            },
            ';' => {
                if (depth == 0) return i + 1;
            },
            '\n' => {
                if (depth == 0) return i;
            },
            else => {},
        }
    }

    return i;
}

fn stripExportPrefix(body: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, body, "export default")) {
        return body["export default".len..];
    }

    if (std.mem.startsWith(u8, body, "module.exports")) {
        const tail = std.mem.trimStart(u8, body["module.exports".len..], " \n\r\t");

        if (tail.len == 0 or tail[0] != '=') {
            return error.UnsupportedJavascriptConfig;
        }

        return tail[1..];
    }

    return error.UnsupportedJavascriptConfig;
}

/// Rewrites `defineConfig( ... )` down to its argument so configs built with
/// the typed helper from `neostaged/config` parse like plain objects.
fn unwrapDefineConfig(body: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, body, "defineConfig")) return body;

    const opened = std.mem.trimStart(u8, body["defineConfig".len..], " \n\r\t");
    if (opened.len == 0 or opened[0] != '(') return body;

    const closed = std.mem.trimEnd(u8, opened, " \n\r\t");
    if (closed[closed.len - 1] != ')') return body;

    return closed[1 .. closed.len - 1];
}

fn shouldUseJson5(file_name: []const u8) bool {
    return isJsonConfig(file_name);
}

fn isJsonConfig(file_name: []const u8) bool {
    return std.mem.eql(u8, file_name, ".neostaged.json") or
        std.mem.eql(u8, file_name, "neostaged.json") or
        std.mem.eql(u8, file_name, "neostaged.config.json") or
        std.mem.eql(u8, file_name, ".neostagedrc");
}

fn isJavascriptConfig(file_name: []const u8) bool {
    return std.mem.eql(u8, file_name, ".neostaged.js") or
        std.mem.eql(u8, file_name, "neostaged.js") or
        std.mem.eql(u8, file_name, "neostaged.config.js") or
        std.mem.eql(u8, file_name, ".neostaged.cjs") or
        std.mem.eql(u8, file_name, "neostaged.cjs") or
        std.mem.eql(u8, file_name, "neostaged.config.cjs") or
        std.mem.eql(u8, file_name, ".neostaged.mjs") or
        std.mem.eql(u8, file_name, "neostaged.mjs") or
        std.mem.eql(u8, file_name, "neostaged.config.mjs");
}
