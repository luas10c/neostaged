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
    allocator: Allocator,
    start_dir: []const u8,
    explicit_path: ?[]const u8,
) !LoadedConfig {
    if (explicit_path) |path| return loadFromPath(allocator, path);
    return searchFrom(allocator, start_dir);
}

pub fn loadNearest(
    allocator: Allocator,
    repo_root: []const u8,
    file_path: []const u8,
) !LoadedConfig {
    const full_file_path = try std.fs.path.join(allocator, &.{ repo_root, file_path });
    defer allocator.free(full_file_path);

    const file_dir = std.fs.path.dirname(full_file_path) orelse repo_root;

    var current = try allocator.dupe(u8, file_dir);
    defer allocator.free(current);

    while (true) {
        if (searchFrom(allocator, current)) |loaded| {
            return loaded;
        } else |err| switch (err) {
            error.ConfigNotFound => {},
            else => return err,
        }

        if (std.mem.eql(u8, current, repo_root)) break;

        const parent = std.fs.path.dirname(current) orelse break;

        if (parent.len < repo_root.len) break;

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }

    return error.ConfigNotFound;
}

fn searchFrom(allocator: Allocator, start_dir: []const u8) !LoadedConfig {
    for (search_places) |file_name| {
        const candidate = try std.fs.path.join(allocator, &.{ start_dir, file_name });
        defer allocator.free(candidate);

        if (std.mem.eql(u8, file_name, "package.json")) {
            const maybe_config = loadPackageJsonConfig(allocator, candidate) catch |err| switch (err) {
                error.FileNotFound,
                error.NotDir,
                => continue,
                else => return err,
            };

            if (maybe_config) |config| return config;
            continue;
        }

        const config = loadFromPath(allocator, candidate) catch |err| switch (err) {
            error.FileNotFound,
            error.NotDir,
            => continue,
            else => return err,
        };

        return config;
    }

    return error.ConfigNotFound;
}

fn loadFromPath(allocator: Allocator, path: []const u8) !LoadedConfig {
    const file_name = std.fs.path.basename(path);

    if (std.mem.eql(u8, file_name, "package.json")) {
        return (try loadPackageJsonConfig(allocator, path)) orelse error.PackageJsonMissingNeostaged;
    }

    if (isJsonConfig(file_name)) {
        var parsed = try loadJsonFile(allocator, path);
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
        var parsed = try loadJavascriptFile(allocator, path);
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

fn loadPackageJsonConfig(allocator: Allocator, path: []const u8) !?LoadedConfig {
    var parsed = try loadJsonFile(allocator, path);
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
    allocator: Allocator,
    path: []const u8,
) !std.json.Parsed(JsonValue) {
    const io = std.Io.Threaded.global_single_threaded.io();

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

fn loadJavascriptFile(allocator: Allocator, path: []const u8) !std.json.Parsed(JsonValue) {
    const io = std.Io.Threaded.global_single_threaded.io();

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

fn javascriptConfigBody(contents: []const u8) ![]const u8 {
    var body = std.mem.trim(u8, contents, " \n\r\t");

    if (std.mem.startsWith(u8, body, "export default")) {
        body = body["export default".len..];
    } else if (std.mem.startsWith(u8, body, "module.exports")) {
        body = body["module.exports".len..];
        body = std.mem.trimStart(u8, body, " \n\r\t");

        if (body.len == 0 or body[0] != '=') {
            return error.UnsupportedJavascriptConfig;
        }

        body = body[1..];
    } else {
        return error.UnsupportedJavascriptConfig;
    }

    body = std.mem.trim(u8, body, " \n\r\t");

    if (body.len != 0 and body[body.len - 1] == ';') {
        body = body[0 .. body.len - 1];
    }

    return std.mem.trim(u8, body, " \n\r\t");
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
