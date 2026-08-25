const std = @import("std");
const ansi = @import("ansi.zig");
const spinner = @import("spinner.zig");

pub const spinner_module = spinner;

pub const TaskState = enum {
    ok,
    failed,
    skipped,
};

pub const TaskTiming = struct {
    label: []const u8,
    file_count: usize,
    ms: ?i64, // null => skipped
    state: TaskState,
};

pub const Tracker = struct {
    staged_files_count: usize = 0,
    executed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
    timings: std.ArrayListUnmanaged(TaskTiming) = .empty,

    pub fn recordTiming(
        self: *Tracker,
        allocator: std.mem.Allocator,
        label: []const u8,
        file_count: usize,
        ms: ?i64,
        state: TaskState,
    ) void {
        const label_copy = allocator.dupe(u8, label) catch return;
        self.timings.append(allocator, .{
            .label = label_copy,
            .file_count = file_count,
            .ms = if (state == .skipped) null else ms,
            .state = state,
        }) catch {
            allocator.free(label_copy);
            return;
        };
    }

    pub fn deinit(self: *Tracker, allocator: std.mem.Allocator) void {
        for (self.timings.items) |item| allocator.free(item.label);
        self.timings.deinit(allocator);
    }

    /// Rail-prefixed timings table: every task, status, duration and a bar
    /// relative to the slowest one. The rail cap (footer) is printed by the
    /// pipeline afterwards.
    pub fn renderTimingsTable(
        self: *Tracker,
        io: std.Io,
        allocator: std.mem.Allocator,
    ) !void {
        if (self.timings.items.len == 0) return;

        // Blank rail line + title.
        if (ansi.enabled) {
            const bar = try ansi.gray(allocator, "\u{2502}");
            defer allocator.free(bar);
            try stdoutPrint(io, "{s}\n", .{bar});

            const rail = try ansi.gray(allocator, "\u{2502} ");
            defer allocator.free(rail);
            const title = try ansi.bold(allocator, "\u{23F1} timings");
            defer allocator.free(title);
            try stdoutPrint(io, "{s}{s}\n", .{ rail, title });

            const header_plain = try tableHeader(allocator);
            defer allocator.free(header_plain);
            const header = try ansi.gray(allocator, header_plain);
            defer allocator.free(header);
            try stdoutPrint(io, "{s}\n", .{header});
        } else {
            try stdoutPrint(io, "\u{2502}\n", .{});
            try stdoutPrint(io, "\u{2502} \u{23F1} timings\n", .{});
            const header_plain0 = try tableHeader(allocator);
            defer allocator.free(header_plain0);
            try stdoutPrint(io, "{s}\n", .{header_plain0});
        }

        for (self.timings.items) |t| {
            const dur_str: []const u8 = if (t.ms) |ms| try fmtDuration(allocator, ms) else "-";
            defer if (t.ms != null) allocator.free(@constCast(dur_str));

            const files_str = try std.fmt.allocPrint(allocator, "{d}", .{t.file_count});
            defer allocator.free(files_str);

            const status_raw = switch (t.state) {
                .ok => "\u{2713} ok",
                .failed => "\u{2717} fail",
                .skipped => "\u{25CB} skip",
            };
            const status_styled: ?[]const u8 = if (ansi.enabled) switch (t.state) {
                .ok => try ansi.green(allocator, status_raw),
                .failed => try ansi.red(allocator, status_raw),
                .skipped => try ansi.yellow(allocator, status_raw),
            } else null;
            defer if (status_styled) |s| allocator.free(s);
            const status_txt = status_styled orelse status_raw;

            // Name column.
            const name_col: usize = 30;
            const name_clipped = utf8Truncate(t.label, name_col);
            const name_pad = name_col -| visibleLen(name_clipped);

            const files_pad: usize = @min(5 -| visibleLen(files_str), 5);

            if (ansi.enabled) {
                const lead = try ansi.gray(allocator, "\u{2502}   ");
                stdoutPrint(io, "{s}", .{lead}) catch {};
                allocator.free(lead);
            } else {
                stdoutPrint(io, "\u{2502}   ", .{}) catch {};
            }
            stdoutPrint(io, "{s}", .{name_clipped}) catch {};
            var p: usize = 0;
            while (p < name_pad) : (p += 1) stdoutPrint(io, " ", .{}) catch {};
            stdoutPrint(io, "  ", .{}) catch {};

            p = 0;
            while (p < files_pad) : (p += 1) stdoutPrint(io, " ", .{}) catch {};
            stdoutPrint(io, "{s}  ", .{files_str}) catch {};

            stdoutPrint(io, "{s: <9}  ", .{status_txt}) catch {};
            stdoutPrint(io, "{s: >7}\n", .{dur_str}) catch {};
        }
    }
};

/// Column header aligned with the row renderer below.
fn tableHeader(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}   {s: <30}  {s: >5}  {s: <9}  {s: >7}", .{
        "\u{2502}", "TASK", "FILES", "STATUS", "DURATION",
    });
}

fn fmtDuration(allocator: std.mem.Allocator, ms: i64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}ms", .{ms});
}

fn visibleLen(bytes: []const u8) usize {
    return spinner.visibleLen(bytes);
}

fn utf8Truncate(input: []const u8, max: usize) []const u8 {
    var end: usize = 0;
    while (end < input.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(input[end]) catch 1;
        if (end + seq_len > input.len or end + seq_len > max) break;
        end += seq_len;
    }
    return input[0..end];
}

fn stdoutPrint(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}
