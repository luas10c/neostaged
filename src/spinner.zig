const std = @import("std");
const builtin = @import("builtin");
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

const frame_interval_ms: i32 = 80;
const can_animate = builtin.os.tag != .windows;

const WNOHANG: c_int = 1;
const O_RDONLY: c_int = 0;

pub const Theme = struct {
    name: []const u8,
    glyphs: []const []const u8,
};

pub const themes = [_]Theme{
    .{ .name = "dots", .glyphs = &.{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" } },
    .{ .name = "sparkle", .glyphs = &.{ "✦", "✧", "✶", "✴", "✹", "✴", "✶", "✧" } },
    .{ .name = "breathe", .glyphs = &.{ "◦", "○", "◯", "○" } },
    .{ .name = "beat", .glyphs = &.{ "○", "◎", "◉", "●", "◉", "◎" } },
    .{ .name = "throb", .glyphs = &.{ "▪", "◆", "◼", "◆" } },
    .{ .name = "fade", .glyphs = &.{ "◌", "◦", "○", "◉", "●", "◉", "○", "◦" } },
    .{ .name = "bars", .glyphs = &.{ " ", "▃", "▄", "▅", "▆", "▇", "█", "▇", "▆", "▅", "▄", "▃" } },
    .{ .name = "dense", .glyphs = &.{ "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" } },
    .{ .name = "moon", .glyphs = &.{ "◐", "◓", "◑", "◒" } },
    .{ .name = "arc", .glyphs = &.{ "◜", "◝", "◞", "◟" } },
    .{ .name = "bounce", .glyphs = &.{ "▟", "▙", "▖", "▘", "▝", "▗" } },
    .{ .name = "arrow", .glyphs = &.{ "↑", "↗", "→", "↘", "↓", "↙", "←", "↖" } },
    .{ .name = "diamond", .glyphs = &.{ "◇", "◈", "◆", "◈" } },
};

pub const RGB = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const ColorMode = union(enum) {
    solid: RGB,
    rainbow,
};

/// Default spinner color: #26a1c0 (RGB: 38, 161, 192)
pub const default_color: RGB = .{ .r = 38, .g = 161, .b = 192 };

pub var g_color_mode: ColorMode = .{ .solid = default_color };

const rainbow_palette = [_]RGB{
    .{ .r = 255, .g = 99, .b = 132 },
    .{ .r = 255, .g = 206, .b = 86 },
    .{ .r = 75, .g = 192, .b = 192 },
    .{ .r = 54, .g = 162, .b = 235 },
    .{ .r = 153, .g = 102, .b = 255 },
    .{ .r = 255, .g = 159, .b = 64 },
};

pub fn parseHexColor(hex: []const u8) ?RGB {
    const s = if (hex.len > 0 and hex[0] == '#') hex[1..] else hex;
    if (s.len != 6) return null;
    const r = std.fmt.parseInt(u8, s[0..2], 16) catch return null;
    const g = std.fmt.parseInt(u8, s[2..4], 16) catch return null;
    const b = std.fmt.parseInt(u8, s[4..6], 16) catch return null;
    return .{ .r = r, .g = g, .b = b };
}

/// Default theme used when NEOSTAGED_SPINNER env var is not specified.
pub const default_theme_name: []const u8 = "fade";

var g_theme: *const Theme = &themes[0];
var g_palette_index: usize = 0;

fn selectTheme() void {
    const name_raw = if (std.c.getenv("NEOSTAGED_SPINNER")) |env|
        std.mem.span(env)
    else
        default_theme_name;

    for (&themes) |*theme| {
        if (std.mem.eql(u8, theme.name, name_raw)) {
            g_theme = theme;
            return;
        }
    }
    g_theme = &themes[0];
}

fn selectColor() void {
    if (std.c.getenv("NEOSTAGED_SPINNER_COLOR")) |env| {
        const val = std.mem.span(env);
        if (std.mem.eql(u8, val, "rainbow") or std.mem.eql(u8, val, "arcoiris")) {
            g_color_mode = .rainbow;
            return;
        }
        if (parseHexColor(val)) |rgb| {
            g_color_mode = .{ .solid = rgb };
            return;
        }
    }
    g_color_mode = .{ .solid = default_color };
}

/// Terminal width in columns (falls back to 80 when unavailable).
pub fn termWidth() usize {
    if (comptime builtin.os.tag == .windows) return 80;

    const Winsize = extern struct { row: u16, col: u16, x: u16, y: u16 };
    var ws: Winsize = .{ .row = 0, .col = 0, .x = 0, .y = 0 };
    const rc = ioctl(1, TIOCGWINSZ, &ws);
    if (rc == 0 and ws.col >= 40) return @intCast(ws.col);
    return 80;
}

const TIOCGWINSZ: c_ulong = 0x5413;

extern "c" fn ioctl(fd: c_int, request: c_ulong, arg: *anyopaque) c_int;

/// Display columns occupied by `bytes`, skipping ANSI escape sequences.
pub fn visibleLen(bytes: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == 0x1b) {
            i += 1;
            if (i < bytes.len and bytes[i] == '[') {
                // CSI sequence: parameters/intermediates then a final byte.
                i += 1;
                while (i < bytes.len and bytes[i] >= 0x20 and bytes[i] <= 0x3f) i += 1;
                if (i < bytes.len and bytes[i] >= 0x40 and bytes[i] <= 0x7e) i += 1;
            } else if (i < bytes.len) {
                // Two-character escape (e.g. ESC M).
                i += 1;
            }
            continue;
        }
        const l = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1;
        i += l;
        count += 1;
    }
    return count;
}

/// Repaints one full line: left content, space padding, right-aligned text.
pub fn printAlignedLine(io: std.Io, left: []const u8, left_visible: usize, right: []const u8) void {
    const width = termWidth();
    const used = @min(left_visible, width);
    const gap = (width -| used) -| (@min(visibleLen(right) + 2, width));

    // Compose the ENTIRE line into one buffer and emit it through the same
    // io writer as everything else — mixing channels clobbers file offsets.
    var buf: [1400]u8 = undefined;
    var pos: usize = 0;

    const put = struct {
        fn put(dst: []u8, p: *usize, src: []const u8) void {
            if (src.len == 0 or p.* + src.len > dst.len) return;
            @memcpy(dst[p.* .. p.* + src.len], src);
            p.* += src.len;
        }
    }.put;

    put(&buf, &pos, "\r\x1b[2K");
    put(&buf, &pos, left);
    var i: usize = 0;
    while (i < gap and pos < buf.len) : (i += 1) {
        buf[pos] = ' ';
        pos += 1;
    }
    if (pos + 2 <= buf.len) {
        buf[pos] = ' ';
        buf[pos + 1] = ' ';
        pos += 2;
    }
    put(&buf, &pos, right);

    stdoutPrint(io, "{s}", .{buf[0..pos]}) catch {};
}

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

extern "c" fn fork() c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn _exit(code: c_int) noreturn;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn dup2(old_fd: c_int, new_fd: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_int) c_int;
extern "c" fn chdir(path: [*:0]const u8) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;

const Timespec = extern struct {
    sec: c_long,
    nsec: c_long,
};

extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;

fn wifExited(status: c_int) bool {
    return (status & 0x7f) == 0;
}

fn wexitStatus(status: c_int) u8 {
    return @intCast((status >> 8) & 0xff);
}

fn wifSignaled(status: c_int) bool {
    return ((status & 0x7f) + 1) >> 1 > 0;
}

fn wtermSig(status: c_int) u8 {
    return @intCast(status & 0x7f);
}

pub fn runCaptureWithSpinner(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    label: []const u8,
    prefix: []const u8,
) !CaptureResult {
    const started = std.Io.Timestamp.now(io, .awake);

    if (ansi.enabled and can_animate) {
        if (animateSpawn(io, allocator, argv, cwd, label, prefix)) |result| {
            return result;
        } else |_| {}
    }

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

const PollState = struct {
    out_pipe: [2]c_int,
    err_pipe: [2]c_int,
    pid: c_int,
};

fn closePipe(pipe_fds: [2]c_int) void {
    _ = close(pipe_fds[0]);
    _ = close(pipe_fds[1]);
}

fn animateSpawn(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    label: []const u8,
    prefix: []const u8,
) !CaptureResult {
    const started = std.Io.Timestamp.now(io, .awake);
    const start_ms = started.toMilliseconds();

    selectTheme();
    selectColor();
    g_palette_index = 0;

    var argv_z = try allocator.alloc(?[*:0]const u8, argv.len + 1);
    for (argv, 0..) |arg, i| argv_z[i] = (try allocator.dupeZ(u8, arg)).ptr;
    argv_z[argv.len] = null;

    const cwd_z = try allocator.dupeZ(u8, cwd);

    var out_pipe: [2]c_int = undefined;
    var err_pipe: [2]c_int = undefined;
    if (pipe(&out_pipe) != 0) return error.PipeFailed;
    if (pipe(&err_pipe) != 0) {
        closePipe(out_pipe);
        return error.PipeFailed;
    }

    const devnull = open("/dev/null", O_RDONLY, 0);

    const pid = fork();
    if (pid < 0) {
        closePipe(out_pipe);
        closePipe(err_pipe);
        if (devnull >= 0) _ = close(devnull);
        return error.SpawnFailed;
    }

    if (pid == 0) {
        _ = close(out_pipe[0]);
        _ = close(err_pipe[0]);
        _ = dup2(out_pipe[1], 1);
        _ = dup2(err_pipe[1], 2);
        if (devnull >= 0) _ = dup2(devnull, 0);
        _ = chdir(cwd_z.ptr);
        _ = execvp(argv_z[0].?, @ptrCast(argv_z.ptr));
        _exit(127);
    }

    _ = close(out_pipe[1]);
    _ = close(err_pipe[1]);
    if (devnull >= 0) _ = close(devnull);

    const state = PollState{
        .out_pipe = out_pipe,
        .err_pipe = err_pipe,
        .pid = pid,
    };
    defer {
        _ = close(state.out_pipe[0]);
        _ = close(state.err_pipe[0]);
    }

    var colored: [frames.len][]const u8 = undefined;
    var frames_ok = true;
    defer if (frames_ok) {
        for (&colored) |frame| allocator.free(frame);
    };
    for (frames, 0..) |frame, i| {
        colored[i] = ansi.cyan(allocator, frame) catch {
            frames_ok = false;
            break;
        };
    }

    stdoutPrint(io, "\x1b[?25l", .{}) catch {}; // hide cursor

    var out_buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out_buf.deinit(allocator);
    var err_buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer err_buf.deinit(allocator);

    var wstatus: c_int = 0;
    var reaped = false;
    var rendered = false;
    var frame_index: usize = 0;

    while (!reaped) {
        const wait_result = waitpid(pid, &wstatus, WNOHANG);
        if (wait_result == pid) {
            reaped = true;
            break;
        }

        drawFrame(io, colored, &frames_ok, label, prefix, &rendered, &frame_index, start_ms);

        var pollfds = [_]std.posix.pollfd{
            .{ .fd = state.out_pipe[0], .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = state.err_pipe[0], .events = std.posix.POLL.IN, .revents = 0 },
        };
        const n = std.posix.poll(&pollfds, 0) catch 0;
        if (n > 0) {
            if ((pollfds[0].revents & std.posix.POLL.IN) != 0) {
                _ = drainFd(state.out_pipe[0], allocator, &out_buf);
            }
            if ((pollfds[1].revents & std.posix.POLL.IN) != 0) {
                _ = drainFd(state.err_pipe[0], allocator, &err_buf);
            }
        }

        sleepTick();
    }

    var out_dead = false;
    var err_dead = false;
    while (!out_dead or !err_dead) {
        var pollfds = [_]std.posix.pollfd{
            .{ .fd = if (out_dead) -1 else state.out_pipe[0], .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = if (err_dead) -1 else state.err_pipe[0], .events = std.posix.POLL.IN, .revents = 0 },
        };
        const live_count: usize = @as(usize, if (out_dead) 0 else 1) + @as(usize, if (err_dead) 0 else 1);
        if (live_count == 0) break;

        const n = std.posix.poll(pollfds[0..live_count], 50) catch 0;
        if (n == 0) continue;

        if (!out_dead and (pollfds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
            if (!drainFd(state.out_pipe[0], allocator, &out_buf)) out_dead = true;
        }
        if (!err_dead and (pollfds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
            if (!drainFd(state.err_pipe[0], allocator, &err_buf)) err_dead = true;
        }
    }

    if (rendered) stdoutPrint(io, "\r\x1b[2K", .{}) catch {};
    stdoutPrint(io, "\x1b[?25h", .{}) catch {};

    const finished = std.Io.Timestamp.now(io, .awake);

    const term: @FieldType(std.process.RunResult, "term") = if (wifExited(wstatus))
        .{ .exited = wexitStatus(wstatus) }
    else if (wifSignaled(wstatus))
        .{ .signal = @enumFromInt(wtermSig(wstatus)) }
    else
        .{ .unknown = 0 };

    return .{
        .stdout = try out_buf.toOwnedSlice(allocator),
        .stderr = try err_buf.toOwnedSlice(allocator),
        .term = term,
        .elapsed_ms = started.durationTo(finished).toMilliseconds(),
    };
}

fn drawFrame(
    io: std.Io,
    colored: [frames.len][]const u8,
    frames_ok: *bool,
    label: []const u8,
    prefix: []const u8,
    rendered: *bool,
    frame_index: *usize,
    start_ms: i64,
) void {
    _ = colored;
    _ = frames_ok;
    _ = rendered;

    const glyphs = g_theme.glyphs;
    const frame = glyphs[frame_index.* % glyphs.len];

    const rgb = switch (g_color_mode) {
        .solid => |c| c,
        .rainbow => rainbow_palette[g_palette_index % rainbow_palette.len],
    };
    frame_index.* += 1;
    g_palette_index +%= 1;

    // Live elapsed time on the right edge while the task runs.
    const now_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    const elapsed_s = @as(f64, @floatFromInt(now_ms - start_ms)) / 1000.0;

    var left_buf: [1024]u8 = undefined;
    const left = std.fmt.bufPrint(&left_buf, "{s} \x1b[38;2;{d};{d};{d}m{s}\x1b[0m {s}", .{
        prefix,
        rgb.r,
        rgb.g,
        rgb.b,
        frame,
        label,
    }) catch return;

    var right_buf: [32]u8 = undefined;
    const right = std.fmt.bufPrint(&right_buf, "{d:.1}s", .{elapsed_s}) catch return;

    printAlignedLine(io, left, visibleLen(left), right);
}

fn drainFd(fd: c_int, allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8)) bool {
    var chunk: [4096]u8 = undefined;
    const n = read(fd, &chunk, chunk.len);
    if (n <= 0) return false;
    buf.appendSlice(allocator, chunk[0..@intCast(n)]) catch return false;
    return true;
}

fn sleepTick() void {
    const req = Timespec{
        .sec = 0,
        .nsec = @intCast(frame_interval_ms * std.time.ns_per_ms),
    };
    _ = nanosleep(&req, null);
}

fn stdoutPrint(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

fn stderrPrint(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buf);
    writer.interface.print(fmt, args) catch return;
    writer.interface.flush() catch return;
}
