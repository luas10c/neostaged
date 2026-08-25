const std = @import("std");

const pipeline = @import("pipeline.zig");

const napi_env = ?*opaque {};
const napi_value = ?*opaque {};
const napi_callback_info = ?*opaque {};

const napi_valuetype = enum(c_int) {
    undefined = 0,
    null = 1,
    boolean = 2,
    number = 3,
    string = 4,
    symbol = 5,
    object = 6,
    function = 7,
    external = 8,
    bigint = 9,
};

extern fn napi_create_function(
    env: napi_env,
    name: [*c]const u8,
    length: usize,
    cb: *const fn (napi_env, napi_callback_info) callconv(.c) napi_value,
    data: ?*anyopaque,
    result: *napi_value,
) c_int;

extern fn napi_get_cb_info(
    env: napi_env,
    info: napi_callback_info,
    argc: *usize,
    argv: [*]napi_value,
    this_arg: ?*napi_value,
    data: ?*?*anyopaque,
) c_int;

extern fn napi_get_named_property(
    env: napi_env,
    object: napi_value,
    name: [*c]const u8,
    result: *napi_value,
) c_int;

extern fn napi_typeof(
    env: napi_env,
    value: napi_value,
    result: *napi_valuetype,
) c_int;

extern fn napi_get_value_bool(
    env: napi_env,
    value: napi_value,
    result: *bool,
) c_int;

extern fn napi_get_value_string_utf8(
    env: napi_env,
    value: napi_value,
    buf: ?[*]u8,
    bufsize: usize,
    result: *usize,
) c_int;

extern fn napi_get_undefined(
    env: napi_env,
    result: *napi_value,
) c_int;

extern fn napi_get_boolean(
    env: napi_env,
    value: bool,
    result: *napi_value,
) c_int;

extern fn napi_throw_error(
    env: napi_env,
    code: [*c]const u8,
    msg: [*c]const u8,
) c_int;

extern fn napi_set_named_property(
    env: napi_env,
    object: napi_value,
    name: [*c]const u8,
    value: napi_value,
) c_int;

/// Errors that escape pipeline.run without having been reported to the user
/// (bad JS options). Everything else is either printed by the pipeline to
/// stderr or is pointless to report (e.g. broken pipe), so run() resolves to
/// `false` instead of throwing into JS.
fn throwsToJs(err: anyerror) bool {
    return switch (err) {
        error.InvalidArguments,
        error.MissingOptions,
        error.InvalidOptionType,
        => true,
        else => false,
    };
}

fn run(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var undefined_value: napi_value = null;
    _ = napi_get_undefined(env, &undefined_value);

    const succeeded = runInner(env, info) catch |err| blk: {
        pipeline.dbgErrName(@errorName(err));
        if (!throwsToJs(err)) break :blk false;

        const allocator = std.heap.smp_allocator;
        const msg = std.fmt.allocPrintSentinel(
            allocator,
            "neostaged failed: {s}",
            .{@errorName(err)},
            0,
        ) catch {
            _ = napi_throw_error(env, null, "neostaged failed");
            break :blk false;
        };

        _ = napi_throw_error(env, null, msg.ptr);
        allocator.free(msg);
        break :blk false;
    };

    if (!succeeded) return undefined_value;

    var bool_value: napi_value = null;
    _ = napi_get_boolean(env, true, &bool_value);
    return bool_value;
}

fn runInner(env: napi_env, info: napi_callback_info) !bool {
    var argc: usize = 1;
    var argv: [1]napi_value = .{null};

    if (napi_get_cb_info(env, info, &argc, &argv, null, null) != 0) {
        return error.InvalidArguments;
    }

    if (argc < 1 or argv[0] == null) {
        return error.MissingOptions;
    }

    const allocator = std.heap.smp_allocator;

    const cwd = try getOptionalString(env, argv[0], "cwd") orelse try allocator.dupe(u8, ".");
    defer allocator.free(cwd);

    const config_arg = try getOptionalString(env, argv[0], "config") orelse try allocator.dupe(u8, "");
    defer allocator.free(config_arg);

    const config: ?[]const u8 = if (config_arg.len > 0) config_arg else null;

    const list = try getOptionalBool(env, argv[0], "list") orelse false;
    const color = try getOptionalBool(env, argv[0], "color") orelse false;

    const stash = try getOptionalBool(env, argv[0], "stash") orelse true;
    const revert = try getOptionalBool(env, argv[0], "revert") orelse true;
    const allow_empty = try getOptionalBool(env, argv[0], "allow_empty") orelse false;

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();

    try pipeline.run(threaded_io.io(), allocator, .{
        .cwd = cwd,
        .config = config,
        .list = list,
        .color = color,
        .stash = stash,
        .revert = revert,
        .allow_empty = allow_empty,
    });

    return true;
}

fn getOptionalBool(env: napi_env, object: napi_value, name: [*c]const u8) !?bool {
    var value: napi_value = null;
    if (napi_get_named_property(env, object, name, &value) != 0) return null;

    var value_type: napi_valuetype = undefined;
    if (napi_typeof(env, value, &value_type) != 0) return null;

    if (value_type == .undefined or value_type == .null) return null;
    if (value_type != .boolean) return error.InvalidOptionType;

    var out: bool = false;
    if (napi_get_value_bool(env, value, &out) != 0) return error.InvalidOptionType;
    return out;
}

/// Returns an exactly-sized copy of the property string. The extra scratch
/// buffer is always freed with its full allocation length so that size-class
/// allocators (e.g. std.heap.smp_allocator) see a matching free.
fn getOptionalString(env: napi_env, object: napi_value, name: [*c]const u8) !?[]const u8 {
    var value: napi_value = null;
    if (napi_get_named_property(env, object, name, &value) != 0) return null;

    var value_type: napi_valuetype = undefined;
    if (napi_typeof(env, value, &value_type) != 0) return null;

    if (value_type == .undefined or value_type == .null) return null;
    if (value_type != .string) return error.InvalidOptionType;

    var len: usize = 0;
    if (napi_get_value_string_utf8(env, value, null, 0, &len) != 0) {
        return error.InvalidOptionType;
    }

    if (len == 0) {
        return try std.heap.smp_allocator.dupe(u8, "");
    }

    const buf = try std.heap.smp_allocator.alloc(u8, len + 1);
    defer std.heap.smp_allocator.free(buf);

    var written: usize = 0;
    if (napi_get_value_string_utf8(env, value, buf.ptr, buf.len, &written) != 0) {
        return error.InvalidOptionType;
    }

    return try std.heap.smp_allocator.dupe(u8, buf[0..written]);
}

export fn napi_register_module_v1(
    env: napi_env,
    exports: napi_value,
) callconv(.c) napi_value {
    var fn_value: napi_value = null;

    _ = napi_create_function(
        env,
        "run",
        3,
        run,
        null,
        &fn_value,
    );

    _ = napi_set_named_property(
        env,
        exports,
        "run",
        fn_value,
    );

    return exports;
}
