const std = @import("std");
const ansi = @import("ansi.zig");

pub const frames = [_][]const u8{
    "⠋",
    "⠙",
    "⠹",
    "⠸",
    "⠼",
    "⠴",
    "⠦",
    "⠧",
    "⠇",
    "⠏",
};

pub const CaptureResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    term: @FieldType(std.process.RunResult, "term"),
    elapsed_ms: i64,

    pub fn deinit(self: CaptureResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

const ThreadState = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    result: ?CaptureResult = null,
    err: ?anyerror = null,
};

const AnimationState = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    label: []const u8,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    rendered_line: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub fn runCaptureWithSpinner(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    label: []const u8,
) !CaptureResult {
    var state = ThreadState{
        .io = io,
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
    };

    var animation_state = AnimationState{
        .io = io,
        .allocator = allocator,
        .label = label,
    };

    try stdoutPrint(io, "\x1b[?25l", .{});
    defer stdoutPrint(io, "\x1b[?25h", .{}) catch {};

    const capture_thread = try std.Thread.spawn(.{}, captureThread, .{&state});
    const animation_thread = try std.Thread.spawn(.{}, animationThread, .{ io, &animation_state });

    while (!state.done.load(.acquire)) {
        try io.sleep(.fromMilliseconds(0), .awake);
    }

    animation_state.done.store(true, .release);

    capture_thread.join();
    animation_thread.join();

    if (animation_state.rendered_line.load(.acquire)) {
        try stdoutPrint(io, "\r\x1b[2K", .{});
    }

    if (state.err) |err| return err;
    return state.result.?;
}

fn animationThread(io: std.Io, state: *AnimationState) !void {
    var i: usize = 0;

    while (!state.done.load(.acquire)) {
        const frame = frames[i % frames.len];

        const colored = ansi.cyan(state.allocator, frame) catch return;
        defer state.allocator.free(colored);

        if (state.rendered_line.load(.acquire)) {
            stdoutPrint(state.io, "\r{s}", .{colored}) catch return;
        } else {
            stdoutPrint(state.io, "\r\x1b[2K{s} {s}", .{ colored, state.label }) catch return;
            state.rendered_line.store(true, .release);
        }

        i += 1;

        try io.sleep(.fromMilliseconds(80), .awake);
    }
}

fn captureThread(state: *ThreadState) void {
    state.result = runCapture(
        state.io,
        state.allocator,
        state.argv,
        state.cwd,
    ) catch |err| {
        state.err = err;
        state.done.store(true, .release);
        return;
    };

    state.done.store(true, .release);
}

fn runCapture(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: []const u8,
) !CaptureResult {
    const started = std.Io.Timestamp.now(io, .awake);

    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
    });

    const finished = std.Io.Timestamp.now(io, .awake);

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .term = result.term,
        .elapsed_ms = started.durationTo(finished).toMilliseconds(),
    };
}

fn stdoutPrint(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}
