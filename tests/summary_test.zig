const std = @import("std");

const ansi = @import("lib").ansi;
const summary = @import("lib").summary;

test "recordTiming stores label copy, file count and duration" {
    var tracker = summary.Tracker{};
    defer tracker.deinit(std.testing.allocator);

    tracker.recordTiming(std.testing.allocator, "eslint --fix", 3, 1200, .ok);

    try std.testing.expectEqual(@as(usize, 1), tracker.timings.items.len);
    const entry = tracker.timings.items[0];
    try std.testing.expectEqualStrings("eslint --fix", entry.label);
    try std.testing.expectEqual(@as(usize, 3), entry.file_count);
    try std.testing.expectEqual(@as(i64, 1200), entry.ms.?);
    try std.testing.expect(entry.state == .ok);
}

test "recordTiming forces ms to null for skipped tasks" {
    var tracker = summary.Tracker{};
    defer tracker.deinit(std.testing.allocator);

    // Even with a duration supplied, skipped rows must not carry one.
    tracker.recordTiming(std.testing.allocator, "gen", 0, 5, .skipped);

    const entry = tracker.timings.items[0];
    try std.testing.expect(entry.ms == null);
    try std.testing.expect(entry.state == .skipped);
}

test "tracker counters start at zero and recordTiming appends in order" {
    var tracker = summary.Tracker{};
    defer tracker.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), tracker.executed);
    try std.testing.expectEqual(@as(usize, 0), tracker.failed);
    try std.testing.expectEqual(@as(usize, 0), tracker.skipped);
    try std.testing.expectEqual(@as(usize, 0), tracker.staged_files_count);

    tracker.recordTiming(std.testing.allocator, "first", 1, 10, .ok);
    tracker.recordTiming(std.testing.allocator, "second", 2, 20, .failed);
    tracker.recordTiming(std.testing.allocator, "third", 0, null, .skipped);

    try std.testing.expectEqual(@as(usize, 3), tracker.timings.items.len);
    try std.testing.expectEqualStrings("first", tracker.timings.items[0].label);
    try std.testing.expectEqualStrings("second", tracker.timings.items[1].label);
    try std.testing.expectEqualStrings("third", tracker.timings.items[2].label);
}

test "renderTimingsTable is a no-op without entries" {
    var tracker = summary.Tracker{};
    defer tracker.deinit(std.testing.allocator);

    // Returns before touching any output stream: safe under the build
    // runner, whose stdout carries its control protocol.
    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded_io.deinit();

    try tracker.renderTimingsTable(threaded_io.io(), std.testing.allocator);
}
