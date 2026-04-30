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

fn run(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var result: napi_value = null;
    _ = napi_get_undefined(env, &result);

    runInner(env, info) catch |err| {
        const msg = std.fmt.allocPrintSentinel(
            std.heap.smp_allocator,
            "neostaged failed: {s}",
            .{@errorName(err)},
            0,
        ) catch "neostaged failed";

        if (msg.len != "neostaged failed".len) {
            defer std.heap.smp_allocator.free(msg);
        }

        _ = napi_throw_error(env, null, msg.ptr);
        return result;
    };

    return result;
}

fn runInner(env: napi_env, info: napi_callback_info) !void {
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

    const config = try getOptionalString(env, argv[0], "config");
    defer if (config) |value| allocator.free(value);

    const list = try getOptionalBool(env, argv[0], "list") orelse false;

    var threaded_io: std.Io.Threaded = .init_single_threaded;
    defer threaded_io.deinit();

    const io = threaded_io.io();

    try pipeline.run(io, allocator, .{
        .cwd = cwd,
        .config = config,
        .list = list,
    });
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

    const buf = try std.heap.smp_allocator.alloc(u8, len + 1);
    errdefer std.heap.smp_allocator.free(buf);

    var written: usize = 0;
    if (napi_get_value_string_utf8(env, value, buf.ptr, buf.len, &written) != 0) {
        return error.InvalidOptionType;
    }

    return buf[0..written];
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
