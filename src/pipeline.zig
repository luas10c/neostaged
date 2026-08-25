const std = @import("std");
const build_options = @import("build_options");

const config = @import("config.zig");
const status = @import("status.zig");
const ansi = @import("ansi.zig");
const glob = @import("glob.zig");
const git = @import("git.zig");
const spinner = @import("spinner.zig");
const summary = @import("summary.zig");

const files_placeholder = "{files}";
const nofiles_placeholder = "{nofiles}";

pub const CliOptions = struct {
    cwd: []const u8,
    config: ?[]const u8,
    list: bool,
    color: bool,
    /// Create a backup snapshot before running tasks and restore it on failure.
    stash: bool = true,
    /// Revert task modifications when tasks fail. With stash disabled, the
    /// working tree is left as-is instead.
    revert: bool = true,
    /// Do not fail when tasks undo every staged change (empty commit).
    allow_empty: bool = false,
};

const Config = struct {
    ignores: [][]const u8,
    entries: []ConfigEntry,

    fn deinit(self: Config, allocator: std.mem.Allocator) void {
        for (self.ignores) |ignore_pattern| allocator.free(ignore_pattern);
        allocator.free(self.ignores);

        for (self.entries) |entry| {
            allocator.free(entry.pattern);
            for (entry.commands) |command| allocator.free(command);
            allocator.free(entry.commands);
        }
        allocator.free(self.entries);
    }
};

const ConfigEntry = struct {
    pattern: []const u8,
    commands: [][]const u8,
};

const ExecutionTask = struct {
    pattern: []const u8,
    files: [][]const u8,
    commands: [][]const u8,

    fn deinit(self: ExecutionTask, allocator: std.mem.Allocator) void {
        for (self.files) |file| allocator.free(file);
        allocator.free(self.files);
    }
};

const ConfigExecutionGroup = struct {
    config_path: []const u8,
    config_dir: []const u8,
    loaded_config: config.LoadedConfig,
    parsed_config: Config,
    files: [][]const u8,

    fn deinit(self: *ConfigExecutionGroup, allocator: std.mem.Allocator) void {
        allocator.free(self.config_path);
        allocator.free(self.config_dir);
        for (self.files) |file| allocator.free(file);
        allocator.free(self.files);
        self.parsed_config.deinit(allocator);
        self.loaded_config.deinit();
    }
};

/// Cache mapping an absolute directory to the nearest config file path found
/// walking up from it (or null when none exists up to the repo root).
/// Keys and non-null values are owned by the map.
const NearestConfigCache = std.StringHashMapUnmanaged(?[]const u8);

/// Inline error space: shows the failing output right below its row.
fn printErrorSpace(io: std.Io, allocator: std.mem.Allocator, message: []const u8) void {
    const max_lines: usize = 6;
    var it = std.mem.splitScalar(u8, message, '\n');
    var n: usize = 0;
    while (it.next()) |raw_line| {
        if (n >= max_lines) {
            if (ansi.enabled) {
                const styled = ansi.gray(allocator, "\u{2506} \u{2026}") catch return;
                defer allocator.free(styled);
                stdoutPrint(io, "\u{2502}     {s}\n", .{styled}) catch {};
            } else {
                stdoutPrint(io, "\u{2502}     \u{2506} \u{2026}\n", .{}) catch {};
            }
            break;
        }
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        n += 1;
        const clipped = utf8Truncate(line, spinner.termWidth() -| 10);
        if (ansi.enabled) {
            const printed = std.fmt.allocPrint(allocator, "\u{2506} {s}", .{clipped}) catch return;
            defer allocator.free(printed);
            const styled = ansi.gray(allocator, printed) catch return;
            defer allocator.free(styled);
            stdoutPrint(io, "\u{2502}     {s}\n", .{styled}) catch {};
        } else {
            stdoutPrint(io, "\u{2502}     \u{2506} {s}\n", .{clipped}) catch {};
        }
    }
}

/// Full-width horizontal rule
pub fn run(io: std.Io, allocator: std.mem.Allocator, options: CliOptions) !void {
    ansi.enabled = options.color;
    if (std.c.getenv("NEOSTAGED_DBG") != null) dbg_on = true;

    const start_ts = std.Io.Timestamp.now(io, .awake);
    var tracker = summary.Tracker{};
    defer tracker.deinit(allocator);

    const repo_root = gitRepoRoot(io, allocator, options.cwd) catch |err| {
        switch (err) {
            error.GitRepoRootFailed => {
                try stderrPrint(io,
                    \\failed at git repo root: not inside a git repository.
                    \\Run this command inside a git repository or pass --cwd PATH.
                    \\
                , .{});
                return error.GitRepoRootFailed;
            },
            else => {
                try stderrPrint(io, "failed at git repo root: {s}\n", .{@errorName(err)});
                return err;
            },
        }
    };
    defer allocator.free(repo_root);

    const branch_name = git.currentBranch(io, allocator, repo_root) catch null;
    defer if (branch_name) |b| allocator.free(b);

    const staged_files = gitStagedFiles(io, allocator, repo_root) catch |err| {
        try stderrPrint(io, "failed at git staged files: {s}\n", .{@errorName(err)});
        return err;
    };
    defer {
        for (staged_files) |file| allocator.free(file);
        allocator.free(staged_files);
    }

    tracker.staged_files_count = staged_files.len;

    if (options.list) {
        for (staged_files) |file| {
            try stdoutPrint(io, "{s}\n", .{file});
        }
        return;
    }

    if (staged_files.len == 0) {
        try stdoutPrint(io, "No staged files found.\n", .{});
        return;
    }

    const groups = buildConfigExecutionGroups(
        io,
        allocator,
        repo_root,
        options,
        staged_files,
    ) catch |err| {
        if (err == error.ConfigNotFound) {
            if (options.config) |explicit| {
                try stderrPrint(io, "configuration file not found: {s}\n", .{explicit});
                return error.AlreadyReported;
            }

            try stderrPrint(io,
                \\failed at config load: no configuration file found.
                \\Expected one of:
                \\  .neostaged.json
                \\  neostaged.json
                \\  neostaged.config.json
                \\  .neostagedrc
                \\  package.json
                \\  .neostaged.js
                \\  neostaged.js
                \\  neostaged.config.js
                \\  .neostaged.cjs
                \\  neostaged.cjs
                \\  neostaged.config.cjs
                \\  .neostaged.mjs
                \\  neostaged.mjs
                \\  neostaged.config.mjs
                \\
            , .{});
            return error.AlreadyReported;
        }

        try stderrPrint(io, "failed at config load: {s}\n", .{@errorName(err)});
        return err;
    };

    defer {
        for (groups) |*group| group.deinit(allocator);
        allocator.free(groups);
    }

    var failed: ?Failure = null;
    // Single ownership point: freed on every exit path, including early errors.
    defer if (failed) |failure| failure.deinit(allocator);

    var backup: ?git.Backup = null;
    var hid_partial = false;
    var partial_files: [][]const u8 = &.{};
    var hidden_partials: []git.HiddenPartial = &.{};

    if (options.stash) {
        backup = git.createBackup(io, allocator, repo_root) catch |err| blk: {
            try stderrPrint(io, "⚠ could not create backup snapshot: {s}\n", .{@errorName(err)});
            break :blk null;
        };
    }

    partial_files = git.detectPartiallyStaged(io, allocator, repo_root, staged_files) catch blk: {
        try stderrPrint(io, "⚠ could not detect partially staged files; their unstaged changes may be committed\n", .{});
        break :blk &.{};
    };
    defer {
        for (partial_files) |file| allocator.free(file);
        if (partial_files.len > 0) allocator.free(partial_files);
    }
    defer {
        for (hidden_partials) |item| item.deinit(allocator);
        if (hidden_partials.len > 0) allocator.free(hidden_partials);
    }

    if (partial_files.len > 0) {
        const snapshotted = blk: {
            hidden_partials = git.snapshotPartiallyStaged(io, allocator, repo_root, partial_files) catch |err| {
                try stderrPrint(io, "⚠ could not snapshot unstaged changes: {s}\n", .{@errorName(err)});
                break :blk false;
            };
            break :blk true;
        };

        const hidden = blk: {
            git.discardWorktreeChanges(io, allocator, repo_root, partial_files) catch |err| {
                try stderrPrint(io, "⚠ could not hide unstaged changes: {s}\n", .{@errorName(err)});
                break :blk false;
            };
            break :blk true;
        };

        hid_partial = snapshotted and hidden;
    }

    {
        const ver_str = try std.fmt.allocPrint(allocator, "v{s}", .{build_options.version});
        defer allocator.free(ver_str);
        const staged_str = try std.fmt.allocPrint(allocator, "{d} staged", .{staged_files.len});
        defer allocator.free(staged_str);

        if (ansi.enabled) {
            const diamond = try ansi.purple(allocator, "\u{25C6}");
            defer allocator.free(diamond);
            const title = try ansi.bold(allocator, "neostaged");
            defer allocator.free(title);
            const ver_gray = try ansi.gray(allocator, ver_str);
            defer allocator.free(ver_gray);

            try stdoutPrint(io, "{s} {s} {s}", .{ diamond, title, ver_gray });
            if (branch_name) |b| {
                const branch_cyan = try ansi.cyan(allocator, try std.fmt.allocPrint(allocator, "\u{2387} {s}", .{b}));
                defer allocator.free(branch_cyan);
                const dot = try ansi.gray(allocator, "\u{b7}");
                defer allocator.free(dot);
                try stdoutPrint(io, " {s} {s}", .{ dot, branch_cyan });
            }
            const dot2 = try ansi.gray(allocator, "\u{b7}");
            defer allocator.free(dot2);
            const staged_gray = try ansi.gray(allocator, staged_str);
            defer allocator.free(staged_gray);
            try stdoutPrint(io, " {s} {s}\n", .{ dot2, staged_gray });
        } else {
            if (branch_name) |b| {
                try stdoutPrint(io, "\u{25C6} neostaged {s} \u{b7} \u{2387} {s} \u{b7} {s}\n", .{ ver_str, b, staged_str });
            } else {
                try stdoutPrint(io, "\u{25C6} neostaged {s} \u{b7} {s}\n", .{ ver_str, staged_str });
            }
        }
        try printRailBlank(io, allocator);
    }

    for (groups) |group| {
        const rel_config_path = try std.fs.path.relative(
            allocator,
            repo_root,
            null,
            repo_root,
            group.config_path,
        );
        defer allocator.free(rel_config_path);

        const plan = buildExecutionPlan(allocator, group.parsed_config, group.files) catch |err| {
            try stderrPrint(io, "failed at execution plan: {s}\n", .{@errorName(err)});
            return err;
        };
        defer {
            for (plan) |task| task.deinit(allocator);
            allocator.free(plan);
        }

        const count_str = try std.fmt.allocPrint(allocator, "{d} {s} \u{b7} {d} {s}", .{
            group.files.len,
            fileLabel(group.files.len),
            plan.len,
            if (plan.len == 1) "pattern" else "patterns",
        });
        defer allocator.free(count_str);

        if (ansi.enabled) {
            const rail = try ansi.gray(allocator, "\u{2502} ");
            defer allocator.free(rail);
            const diamond = try ansi.cyan(allocator, "\u{25C8}");
            defer allocator.free(diamond);
            const styled_path = try ansi.bold(allocator, rel_config_path);
            defer allocator.free(styled_path);
            const sep_gray = try ansi.gray(allocator, " \u{2014} ");
            defer allocator.free(sep_gray);
            const count_cyan = try ansi.cyan(allocator, count_str);
            defer allocator.free(count_cyan);

            try stdoutPrint(io, "{s}{s} {s}{s}{s}\n", .{ rail, diamond, styled_path, sep_gray, count_cyan });
        } else {
            try stdoutPrint(io, "\u{2502} \u{25C8} {s} \u{2014} {s}\n", .{ rel_config_path, count_str });
        }
        try printRailBlank(io, allocator);

        for (plan) |task| {
            if (ansi.enabled) {
                const rail = try ansi.gray(allocator, "\u{2502} ");
                defer allocator.free(rail);
                const arrow = try ansi.blue(allocator, "\u{25B8}");
                defer allocator.free(arrow);
                const pattern_bold = try ansi.bold(allocator, task.pattern);
                defer allocator.free(pattern_bold);
                const task_count_str = try std.fmt.allocPrint(allocator, "{d} {s}", .{ task.files.len, fileLabel(task.files.len) });
                defer allocator.free(task_count_str);
                const styled_task_count = try ansi.gray(allocator, task_count_str);

                try stdoutPrint(io, "{s}{s} {s} \u{b7} {s}\n", .{ rail, arrow, pattern_bold, styled_task_count });
            } else {
                try stdoutPrint(io, "\u{2502} \u{25B8} {s} \u{b7} {d} {s}\n", .{ task.pattern, task.files.len, fileLabel(task.files.len) });
            }

            // Command rows hang from the rail: "|   glyph label ... note".
            const tree_prefix = if (ansi.enabled)
                try ansi.gray(allocator, "\u{2502}  ")
            else
                try allocator.dupe(u8, "\u{2502}  ");

            for (task.commands) |command| {
                const rendered_command = try renderCommand(allocator, command, task.files);
                defer allocator.free(rendered_command);

                const display_command = try summarizeCommand(allocator, command);
                defer allocator.free(display_command);

                var spin_prefix_buf: [80]u8 = undefined;
                const spin_prefix = std.fmt.bufPrint(&spin_prefix_buf, "{s}", .{tree_prefix}) catch tree_prefix;

                if (task.files.len == 0) {
                    tracker.skipped += 1;
                    const skip_str = try std.fmt.allocPrint(allocator, "skipped ({d} {s})", .{ task.files.len, fileLabel(task.files.len) });
                    defer allocator.free(skip_str);
                    const suffix = if (ansi.enabled) try ansi.yellow(allocator, skip_str) else try allocator.dupe(u8, skip_str);
                    defer allocator.free(suffix);
                    try status.print(io, allocator, .skipped, "", display_command, suffix, tree_prefix);
                    tracker.recordTiming(allocator, display_command, 0, null, .skipped);
                    continue;
                }

                const result = try runShellCommand(io, allocator, rendered_command, group.config_dir, display_command, spin_prefix);
                defer result.deinit(allocator);

                tracker.executed += 1;
                dbgLog(result.ok, result.stderr, result.stdout);

                if (result.ok) {
                    const files_str = try std.fmt.allocPrint(allocator, "{d} {s}", .{ task.files.len, fileLabel(task.files.len) });
                    defer allocator.free(files_str);
                    const dur_str = try fmtDuration(allocator, result.elapsed_ms);
                    defer allocator.free(dur_str);
                    var note_buf: [128]u8 = undefined;
                    const note = std.fmt.bufPrint(&note_buf, "{s} \u{b7} {s}", .{ files_str, dur_str }) catch dur_str;
                    const suffix = if (ansi.enabled) try ansi.gray(allocator, note) else try allocator.dupe(u8, note);

                    try status.print(io, allocator, .success, "", display_command, suffix, tree_prefix);
                    tracker.recordTiming(allocator, display_command, task.files.len, result.elapsed_ms, .ok);
                } else {
                    tracker.failed += 1;

                    if (failed) |*previous| previous.deinit(allocator);
                    failed = try Failure.init(allocator, task.pattern, display_command, result.stderr, result.stdout);

                    const fail_note: []const u8 = switch (result.term) {
                        .exited => |code| try std.fmt.allocPrint(allocator, "failed \u{b7} exit {d}", .{code}),
                        .signal => |sig| try std.fmt.allocPrint(allocator, "failed \u{b7} signal {d}", .{@intFromEnum(sig)}),
                        else => try allocator.dupe(u8, "failed"),
                    };
                    defer allocator.free(@constCast(fail_note));
                    const suffix = if (ansi.enabled) try ansi.red(allocator, fail_note) else try allocator.dupe(u8, fail_note);
                    defer allocator.free(suffix);

                    try status.print(io, allocator, .failed, "", display_command, suffix, tree_prefix);
                    printErrorSpace(io, allocator, if (result.stderr.len > 0) result.stderr else result.stdout);
                    tracker.recordTiming(allocator, display_command, task.files.len, result.elapsed_ms, .failed);
                    break;
                }
            }
        }

        try printRailBlank(io, allocator);
    }

    if (tracker.failed == 0) {
        dbgMark("M1-pre-add");
        try applyChanges(io, allocator, repo_root, staged_files);
        dbgMark("M2-post-add");

        if (hid_partial) {
            const restored = git.restoreHiddenPartials(io, allocator, repo_root, hidden_partials) catch false;
            if (!restored) {
                try stderrPrint(io,
                    \\✖ the unstaged changes of partially staged files conflict with
                    \\  the modifications made by tasks; aborting so nothing is
                    \\  committed. Nothing was lost — resolve the files manually.
                    \\
                , .{});
                revertToOriginalState(io, allocator, repo_root, options, backup);
                railCapOnly(io, allocator);
                return error.CommandFailed;
            }
        }

        const empty_commit = !options.allow_empty and
            (git.indexIsEmptyAgainstHead(io, allocator, repo_root) catch |err| blk: {
                try stderrPrint(io, "⚠ could not check for empty commit: {s}\n", .{@errorName(err)});
                break :blk false;
            });

        if (empty_commit) {
            try stderrPrint(io,
                \\✖ tasks reverted every staged change; the commit would be empty.
                \\  Use --allow-empty to allow an empty commit.
                \\
            , .{});
            revertToOriginalState(io, allocator, repo_root, options, backup);
            railCapOnly(io, allocator);
            return error.CommandFailed;
        }

        dbgMark("M3-post-emptycheck");
        if (backup != null) git.dropBackup(io, allocator, repo_root);
        dbgMark("M4-post-drop");

        const end_ts = std.Io.Timestamp.now(io, .awake);
        const elapsed_ms = start_ts.durationTo(end_ts).toMilliseconds();
        const time_str = try fmtDuration(allocator, elapsed_ms);
        defer allocator.free(time_str);

        try printRailBlank(io, allocator);

        {
            const counts = try std.fmt.allocPrint(allocator, "done in {s} \u{b7} {d} ok \u{b7} {d} failed \u{b7} {d} skipped", .{
                time_str,
                tracker.executed -| tracker.failed,
                tracker.failed,
                tracker.skipped,
            });
            defer allocator.free(counts);
            if (ansi.enabled) {
                const tee = try ansi.gray(allocator, "\u{251C}\u{2500} ");
                defer allocator.free(tee);
                const check = try ansi.green(allocator, "\u{2713}");
                defer allocator.free(check);
                const rest_gray = try ansi.gray(allocator, counts);
                defer allocator.free(rest_gray);
                try stdoutPrint(io, "{s}{s} {s}\n", .{ tee, check, rest_gray });
            } else {
                try stdoutPrint(io, "\u{251C}\u{2500} \u{2713} {s}\n", .{counts});
            }
        }

        try tracker.renderTimingsTable(io, allocator);

        {
            var ops: std.ArrayListUnmanaged(u8) = .empty;
            defer ops.deinit(allocator);
            try ops.appendSlice(allocator, "staged \u{2713}");
            if (hid_partial) try ops.appendSlice(allocator, " \u{b7} unstaged restored \u{2713}");
            if (backup != null) try ops.appendSlice(allocator, " \u{b7} backup cleaned \u{2713}");

            if (ansi.enabled) {
                const corner = try ansi.gray(allocator, "\u{2570}\u{2500} ");
                defer allocator.free(corner);
                const ops_gray = try ansi.gray(allocator, ops.items);
                defer allocator.free(ops_gray);
                try stdoutPrint(io, "{s}{s}\n", .{ corner, ops_gray });
            } else {
                try stdoutPrint(io, "\u{2570}\u{2500} {s}\n", .{ops.items});
            }
        }
        return;
    }

    revertToOriginalState(io, allocator, repo_root, options, backup);

    // Rail close for failure path.
    try printRailBlank(io, allocator);

    {
        const fail_str = try std.fmt.allocPrint(allocator, "{d} of {d} {s} failed", .{
            tracker.failed,
            tracker.executed,
            if (tracker.executed == 1) "task" else "tasks",
        });
        defer allocator.free(fail_str);
        if (ansi.enabled) {
            const tee = try ansi.gray(allocator, "\u{251C}\u{2500} ");
            defer allocator.free(tee);
            const cross = try ansi.red(allocator, "\u{2717}");
            defer allocator.free(cross);
            const rest_red = try ansi.red(allocator, fail_str);
            defer allocator.free(rest_red);
            try stdoutPrint(io, "{s}{s} {s}\n", .{ tee, cross, rest_red });
        } else {
            try stdoutPrint(io, "\u{251C}\u{2500} \u{2717} {s}\n", .{fail_str});
        }
    }

    if (failed) |failure| {
        if (ansi.enabled) {
            const rail = try ansi.gray(allocator, "\u{2502}");
            defer allocator.free(rail);
            const pattern_str = try ansi.bold(allocator, failure.pattern);
            defer allocator.free(pattern_str);
            const cmd_str = try ansi.gray(allocator, failure.command);
            defer allocator.free(cmd_str);

            var msg_it = std.mem.splitScalar(u8, failure.message, '\n');
            var first = true;
            while (msg_it.next()) |raw_line| {
                const line = std.mem.trim(u8, raw_line, " \t\r");
                if (line.len == 0) continue;
                if (first) {
                    const clipped = utf8Truncate(line, spinner.termWidth() -| 16);
                    try stdoutPrint(io, "{s}   \u{2717} {s} \u{2192} {s}\n", .{ rail, pattern_str, cmd_str });
                    try stdoutPrint(io, "{s}     \u{2514} {s}\n", .{ rail, clipped });
                    first = false;
                } else {
                    const clipped = utf8Truncate(line, spinner.termWidth() -| 10);
                    try stdoutPrint(io, "{s}       {s}\n", .{ rail, clipped });
                }
            }
        } else {
            var msg_it = std.mem.splitScalar(u8, failure.message, '\n');
            var first = true;
            while (msg_it.next()) |raw_line| {
                const line = std.mem.trim(u8, raw_line, " \t\r");
                if (line.len == 0) continue;
                if (first) {
                    try stdoutPrint(io, "\u{2502}   \u{2717} {s} \u{2192} {s}\n", .{ failure.pattern, failure.command });
                    try stdoutPrint(io, "\u{2502}     \u{2514} {s}\n", .{line});
                    first = false;
                } else {
                    try stdoutPrint(io, "\u{2502}       {s}\n", .{line});
                }
            }
        }
    }

    {
        var ops: std.ArrayListUnmanaged(u8) = .empty;
        defer ops.deinit(allocator);
        if (backup != null and options.revert) {
            try ops.appendSlice(allocator, "\u{21ba} reverted \u{2713}");
            if (hid_partial) try ops.appendSlice(allocator, " \u{b7} unstaged restored \u{2713}");
        } else if (backup != null) {
            try ops.appendSlice(allocator, "\u{26a0} backup kept \u{b7} drop: git update-ref -d refs/neostaged/backup");
        }

        if (ops.items.len == 0) {
            if (ansi.enabled) {
                const corner = try ansi.gray(allocator, "\u{2570}\u{2500}");
                defer allocator.free(corner);
                try stdoutPrint(io, "{s}\n", .{corner});
            } else {
                try stdoutPrint(io, "\u{2570}\u{2500}\n", .{});
            }
        } else if (ansi.enabled) {
            const corner = try ansi.gray(allocator, "\u{2570}\u{2500} ");
            defer allocator.free(corner);
            const ops_gray = try ansi.gray(allocator, ops.items);
            defer allocator.free(ops_gray);
            try stdoutPrint(io, "{s}{s}\n", .{ corner, ops_gray });
        } else {
            try stdoutPrint(io, "\u{2570}\u{2500} {s}\n", .{ops.items});
        }
    }

    try stderrPrint(io, "\nAborting commit.\n", .{});
    return error.CommandFailed;
}

/// Best-effort return to the pre-run state after failures or empty commits.
fn revertToOriginalState(
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    options: CliOptions,
    backup: ?git.Backup,
) void {
    if (!options.revert) {
        if (backup != null) {
            stderrPrint(io,
                \\⚠ working tree left as modified (--no-revert).
                \\  Backup available at {s}; drop it when done with:
                \\  git update-ref -d {s}
                \\
            , .{ git.backup_ref, git.backup_ref }) catch {};
        }
        return;
    }

    if (backup) |b| {
        // Discard task modifications, then bring back the original state
        // (including the previously staged content and any hidden dirt —
        // the snapshot was taken before anything was hidden).
        const reset = runCapture(io, allocator, &.{ "git", "reset", "--hard", "HEAD" }, repo_root) catch |err| {
            stderrPrint(io, "✖ failed to revert ({s}); backup kept at {s} ({s})\n", .{ @errorName(err), git.backup_ref, b.hash }) catch {};
            return;
        };
        defer reset.deinit(allocator);

        git.applyBackup(io, allocator, repo_root) catch {
            stderrPrint(io,
                \\✖ failed to restore original state automatically.
                \\  Your changes are safe in the backup; recover manually with:
                \\  git reset --hard HEAD && git stash apply --index {s}
                \\  then remove it with: git update-ref -d {s}
                \\
            , .{ git.backup_ref, git.backup_ref }) catch {};
            return;
        };

        stderrPrint(io, "↩ reverted to the original state from {s}\n", .{git.backup_ref}) catch {};
        git.dropBackup(io, allocator, repo_root);
        return;
    }
}

const Failure = struct {
    pattern: []const u8,
    command: []const u8,
    message: []const u8,

    fn init(
        allocator: std.mem.Allocator,
        pattern: []const u8,
        command: []const u8,
        stderr: []const u8,
        stdout: []const u8,
    ) !Failure {
        const raw = if (std.mem.trim(u8, stderr, " \n\r\t").len > 0) stderr else stdout;
        const message = std.mem.trim(u8, raw, " \n\r\t");

        return .{
            .pattern = try allocator.dupe(u8, pattern),
            .command = try allocator.dupe(u8, command),
            .message = try allocator.dupe(u8, if (message.len == 0) "command failed" else message),
        };
    }

    fn deinit(self: Failure, allocator: std.mem.Allocator) void {
        allocator.free(self.pattern);
        allocator.free(self.command);
        allocator.free(self.message);
    }
};

fn gitRepoRoot(io: std.Io, allocator: std.mem.Allocator, cwd: []const u8) ![]const u8 {
    const result = try runCapture(io, allocator, &[_][]const u8{
        "git",
        "rev-parse",
        "--show-toplevel",
    }, cwd);
    defer result.deinit(allocator);

    if (result.term != .exited or result.term.exited != 0) {
        try stderrPrint(io, "failed to locate git repository root: {s}\n", .{std.mem.trim(u8, result.stderr, " \n\r\t")});
        return error.GitRepoRootFailed;
    }

    return try allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \n\r\t"));
}

fn gitStagedFiles(io: std.Io, allocator: std.mem.Allocator, repo_root: []const u8) ![][]const u8 {
    const result = try runCapture(io, allocator, &[_][]const u8{
        "git",
        "-c",
        "core.quotePath=false",
        "diff",
        "--cached",
        "--name-only",
        "--diff-filter=ACMR",
        "-z",
    }, repo_root);
    defer result.deinit(allocator);

    if (result.term != .exited or result.term.exited != 0) {
        try stderrPrint(io, "failed to read staged files: {s}\n", .{std.mem.trim(u8, result.stderr, " \n\r\t")});
        return error.GitStagedFilesFailed;
    }

    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (files.items) |file| allocator.free(file);
        files.deinit(allocator);
    }

    var entries = std.mem.splitScalar(u8, result.stdout, 0);
    while (entries.next()) |entry| {
        if (entry.len == 0) continue;
        try files.append(allocator, try allocator.dupe(u8, entry));
    }

    return try files.toOwnedSlice(allocator);
}

fn isIgnored(ignores: [][]const u8, file: []const u8) bool {
    for (ignores) |ignore_pattern| {
        if (glob.match(ignore_pattern, file)) return true;
    }
    return false;
}

fn buildExecutionPlan(
    allocator: std.mem.Allocator,
    cfg: Config,
    staged_files: [][]const u8,
) ![]ExecutionTask {
    var tasks: std.ArrayListUnmanaged(ExecutionTask) = .empty;
    errdefer {
        for (tasks.items) |task| task.deinit(allocator);
        tasks.deinit(allocator);
    }

    for (cfg.entries) |entry| {
        var matched_files: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (matched_files.items) |file| allocator.free(file);
            matched_files.deinit(allocator);
        }

        for (staged_files) |file| {
            if (isIgnored(cfg.ignores, file)) continue;

            if (glob.match(entry.pattern, file)) {
                try matched_files.append(allocator, try allocator.dupe(u8, file));
            }
        }

        try tasks.append(allocator, .{
            .pattern = entry.pattern,
            .files = try matched_files.toOwnedSlice(allocator),
            .commands = entry.commands,
        });
    }

    return try tasks.toOwnedSlice(allocator);
}

fn renderCommand(
    allocator: std.mem.Allocator,
    command: []const u8,
    files: [][]const u8,
) ![]const u8 {
    // {nofiles}: run the command as-is, without appending matched files.
    if (std.mem.indexOf(u8, command, nofiles_placeholder)) |_| {
        const stripped = try replaceAll(allocator, command, nofiles_placeholder, "");
        defer allocator.free(stripped);
        return try allocator.dupe(u8, std.mem.trim(u8, stripped, " \n\r\t"));
    }

    const quoted_files = try quoteFiles(allocator, files);

    if (std.mem.indexOf(u8, command, files_placeholder)) |_| {
        defer allocator.free(quoted_files);
        return try replaceAll(allocator, command, files_placeholder, quoted_files);
    }

    // No placeholder: append the files automatically so commands like
    // "eslint" receive the matched staged files as arguments.
    return try std.mem.join(allocator, " ", &.{ command, quoted_files });
}

fn quoteFiles(allocator: std.mem.Allocator, files: [][]const u8) ![]const u8 {
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (parts.items) |part| allocator.free(part);
        parts.deinit(allocator);
    }

    for (files) |file| {
        try parts.append(allocator, try shellQuote(allocator, file));
    }

    return try std.mem.join(allocator, " ", parts.items);
}

fn summarizeCommand(
    allocator: std.mem.Allocator,
    command: []const u8,
) ![]const u8 {
    const max_display_len: usize = 80;

    const with_files = try replaceAll(allocator, command, files_placeholder, "<files>");
    defer allocator.free(with_files);

    // Hide the {nofiles} marker from the displayed label.
    var owned_display: ?[]const u8 = null;
    defer if (owned_display) |value| allocator.free(value);

    const raw = if (std.mem.indexOf(u8, with_files, nofiles_placeholder)) |_| blk: {
        const stripped = try replaceAll(allocator, with_files, nofiles_placeholder, "");
        owned_display = stripped;
        break :blk @as([]const u8, std.mem.trim(u8, stripped, " \n\r\t"));
    } else @as([]const u8, with_files);

    var base: []const u8 = raw;
    var owned_base: ?[]const u8 = null;
    defer if (owned_base) |value| allocator.free(value);

    if (base.len > max_display_len) {
        const truncated = utf8Truncate(base, max_display_len - 1);
        owned_base = try std.fmt.allocPrint(allocator, "{s}\u{2026}", .{truncated});
        base = owned_base.?;
    }

    return try allocator.dupe(u8, base);
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

const CommandResult = struct {
    ok: bool,
    stdout: []const u8,
    stderr: []const u8,
    elapsed_ms: i64,
    term: @FieldType(std.process.RunResult, "term"),

    fn deinit(self: CommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn runShellCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    command: []const u8,
    cwd: []const u8,
    label: []const u8,
    prefix: []const u8,
) !CommandResult {
    const argv = if (isWindows())
        &[_][]const u8{ "cmd", "/C", command }
    else
        &[_][]const u8{ "sh", "-c", command };

    const result = try status.runPendingCapture(io, allocator, argv, cwd, label, prefix);
    return .{
        .ok = result.term == .exited and result.term.exited == 0,
        .stdout = result.stdout,
        .stderr = result.stderr,
        .elapsed_ms = result.elapsed_ms,
        .term = result.term,
    };
}

fn applyChanges(io: std.Io, allocator: std.mem.Allocator, cwd: []const u8, files: [][]const u8) !void {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, "git");
    try argv.append(allocator, "add");
    try argv.append(allocator, "--");
    for (files) |file| try argv.append(allocator, file);

    const result = try runCapture(io, allocator, argv.items, cwd);
    defer result.deinit(allocator);

    if (result.term != .exited or result.term.exited != 0) {
        try stderrPrint(io, "failed at git add: {s}\n", .{std.mem.trim(u8, result.stderr, " \n\r\t")});
        return error.GitAddFailed;
    }
}

fn shellQuote(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (isWindows()) {
        const escaped = try replaceAll(allocator, value, "\"", "\\\"");
        defer allocator.free(escaped);
        return try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
    }

    const escaped = try replaceAll(allocator, value, "'", "'\"'\"'");
    defer allocator.free(escaped);
    return try std.fmt.allocPrint(allocator, "'{s}'", .{escaped});
}

fn parseIgnores(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged([]const u8),
    value: std.json.Value,
) !void {
    switch (value) {
        .string => |str| {
            if (str.len > 0) {
                try out.append(allocator, try allocator.dupe(u8, str));
            }
        },
        .array => |array| {
            for (array.items) |item| {
                switch (item) {
                    .string => |str| {
                        if (str.len > 0) {
                            try out.append(allocator, try allocator.dupe(u8, str));
                        }
                    },
                    else => {},
                }
            }
        },
        else => {},
    }
}

fn ConfigFromJson(allocator: std.mem.Allocator, value: std.json.Value) !Config {
    const root = switch (value) {
        .object => |object| object,
        else => return error.ConfigMustBeObject,
    };

    var ignores: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (ignores.items) |item| allocator.free(item);
        ignores.deinit(allocator);
    }

    if (root.get("ignores")) |raw_ignores| {
        try parseIgnores(allocator, &ignores, raw_ignores);
    }

    const object = if (root.get("tasks")) |tasks|
        switch (tasks) {
            .object => |tasks_object| tasks_object,
            else => return error.TasksMustBeObject,
        }
    else
        root;

    if (ignores.items.len == 0) {
        if (object.get("ignores")) |raw_ignores| {
            try parseIgnores(allocator, &ignores, raw_ignores);
        }
    }

    var entries: std.ArrayListUnmanaged(ConfigEntry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.pattern);
            for (entry.commands) |command| allocator.free(command);
            allocator.free(entry.commands);
        }
        entries.deinit(allocator);
    }

    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "ignores")) continue;

        const commands = try parseCommands(allocator, entry.value_ptr.*);
        errdefer {
            for (commands) |command| allocator.free(command);
            allocator.free(commands);
        }

        if (commands.len == 0) {
            return error.EmptyCommandList;
        }

        const pattern = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(pattern);

        try entries.append(allocator, .{
            .pattern = pattern,
            .commands = commands,
        });
    }

    if (entries.items.len == 0) {
        return error.ConfigMustDefineEntries;
    }

    return .{
        .ignores = try ignores.toOwnedSlice(allocator),
        .entries = try entries.toOwnedSlice(allocator),
    };
}

fn parseCommands(allocator: std.mem.Allocator, value: std.json.Value) ![][]const u8 {
    switch (value) {
        .string => |command| {
            return try dupeCommandStrings(allocator, &.{command});
        },
        .array => |array| {
            var strings: std.ArrayListUnmanaged([]const u8) = .empty;
            errdefer strings.deinit(allocator);

            for (array.items) |item| {
                if (item != .string) return error.CommandEntriesMustBeStrings;
                try strings.append(allocator, item.string);
            }

            return try dupeCommandStrings(allocator, strings.items);
        },
        else => return error.ExpectedStringOrArray,
    }
}

fn dupeCommandStrings(allocator: std.mem.Allocator, raw_commands: []const []const u8) ![][]const u8 {
    var commands: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (commands.items) |command| allocator.free(command);
        commands.deinit(allocator);
    }

    for (raw_commands) |raw| {
        if (std.mem.trim(u8, raw, " \n\r\t").len == 0) {
            return error.EmptyCommandString;
        }

        try commands.append(allocator, try allocator.dupe(u8, raw));
    }

    return try commands.toOwnedSlice(allocator);
}

fn replaceAll(
    allocator: std.mem.Allocator,
    haystack: []const u8,
    needle: []const u8,
    replacement: []const u8,
) ![]const u8 {
    if (needle.len == 0) return try allocator.dupe(u8, haystack);

    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        try result.appendSlice(allocator, rest[0..index]);
        try result.appendSlice(allocator, replacement);
        rest = rest[index + needle.len ..];
    }
    try result.appendSlice(allocator, rest);

    return try result.toOwnedSlice(allocator);
}

fn runCapture(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) !git.CaptureResult {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
    }) catch |err| {
        try stderrPrint(io, "failed to run \"{s}\": {s}\n", .{ argv[0], @errorName(err) });
        return err;
    };

    return git.CaptureResult{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .term = result.term,
    };
}

fn stdoutPrint(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

fn stderrPrint(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buf);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

fn isWindows() bool {
    return @import("builtin").os.tag == .windows;
}

fn fileLabel(count: usize) []const u8 {
    return if (count == 1) "file" else "files";
}

/// Blank continuation line of the left rail.
fn printRailBlank(io: std.Io, allocator: std.mem.Allocator) !void {
    if (ansi.enabled) {
        const bar = try ansi.gray(allocator, "\u{2502}");
        defer allocator.free(bar);
        try stdoutPrint(io, "{s}\n", .{bar});
    } else {
        try stdoutPrint(io, "\u{2502}\n", .{});
    }
}

/// Close the rail when bailing out through an early error path.
fn railCapOnly(io: std.Io, allocator: std.mem.Allocator) void {
    if (ansi.enabled) {
        const cap = ansi.gray(allocator, "\u{2570}\u{2500}") catch return;
        defer allocator.free(cap);
        stdoutPrint(io, "{s}\n", .{cap}) catch {};
    } else {
        stdoutPrint(io, "\u{2570}\u{2500}\n", .{}) catch {};
    }
}

var dbg_on = false;

extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;

pub fn dbgErrName(name: []const u8) void {
    const O_W: c_int = 1;
    const O_C: c_int = 64;
    const O_A: c_int = 1024;
    const fd = open("/tmp/opencode/dbg.log", O_W | O_C | O_A, 0o644);
    if (fd < 0) return;
    _ = write(fd, "ERRNAME=", 8);
    _ = write(fd, name.ptr, name.len);
    _ = write(fd, "\n", 1);
    _ = close(fd);
}

fn dbgMark(tag: []const u8) void {
    if (!dbg_on) return;
    const O_W: c_int = 1;
    const O_C: c_int = 64;
    const O_A: c_int = 1024;
    const fd = open("/tmp/opencode/dbg.log", O_W | O_C | O_A, 0o644);
    if (fd < 0) return;
    _ = write(fd, tag.ptr, tag.len);
    _ = write(fd, "\n", 1);
    _ = close(fd);
}

fn dbgLog(ok: bool, stderr_bytes: []const u8, stdout_bytes: []const u8) void {
    if (!dbg_on) return;
    const O_W: c_int = 1;
    const O_C: c_int = 64;
    const O_A: c_int = 1024;
    const fd = open("/tmp/opencode/dbg.log", O_W | O_C | O_A, 0o644);
    if (fd < 0) return;
    defer _ = close(fd);
    _ = write(fd, "OK=", 3);
    _ = write(fd, if (ok) "1" else "0", 1);
    _ = write(fd, "\n", 1);
    if (!ok) {
        _ = write(fd, "ERR:", 4);
        _ = write(fd, stderr_bytes.ptr, @min(stderr_bytes.len, 140));
        _ = write(fd, "\nOUT:", 5);
        _ = write(fd, stdout_bytes.ptr, @min(stdout_bytes.len, 140));
        _ = write(fd, "\n---\n", 5);
    }
}

fn fmtDuration(allocator: std.mem.Allocator, ms: i64) ![]const u8 {
    if (ms >= 1000) {
        return std.fmt.allocPrint(allocator, "{d:.1}s", .{@as(f64, @floatFromInt(ms)) / 1000.0});
    }
    return std.fmt.allocPrint(allocator, "{d}ms", .{ms});
}

/// Horizontal rule with embedded label + optional right text.
// ---- v4 panel helpers ----

fn boxTop(io: std.Io, allocator: std.mem.Allocator) !void {
    try boxEdge(io, allocator, "\u{256D}", "\u{256E}");
}

fn boxBottom(io: std.Io, allocator: std.mem.Allocator) !void {
    try boxEdge(io, allocator, "\u{2570}", "\u{256F}");
}

fn boxEdge(io: std.Io, allocator: std.mem.Allocator, left_char: []const u8, right_char: []const u8) !void {
    const width = spinner.termWidth();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    if (ansi.enabled) {
        const g1 = try ansi.gray(allocator, left_char);
        defer allocator.free(g1);
        try out.appendSlice(allocator, g1);
    } else left_char_copy: {
        try out.appendSlice(allocator, left_char);
        break :left_char_copy;
    }
    var i: usize = 2;
    while (i < width -| 4) : (i += 1) try out.appendSlice(allocator, "\u{2500}");
    if (ansi.enabled) {
        const g2 = try ansi.gray(allocator, right_char);
        defer allocator.free(g2);
        try out.appendSlice(allocator, g2);
    } else {
        try out.appendSlice(allocator, right_char);
    }
    try stdoutPrint(io, "{s}\n", .{out.items});
}

/// "│   content<pad>│" padded panel row.
fn boxRow(io: std.Io, allocator: std.mem.Allocator, styled_content: []const u8, visible: usize) !void {
    const width = spinner.termWidth();
    const used = @min(visible + 6, width); // 3-space lead + both border bars
    const pad = width -| used;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    if (ansi.enabled) {
        const bar = try ansi.gray(allocator, "\u{2502}");
        defer allocator.free(bar);
        try out.appendSlice(allocator, bar);
    } else {
        try out.appendSlice(allocator, "|");
    }
    try out.appendSlice(allocator, "   ");
    try out.appendSlice(allocator, styled_content);
    var i: usize = 0;
    while (i < pad) : (i += 1) try out.appendSlice(allocator, " ");
    if (ansi.enabled) {
        const bar = try ansi.gray(allocator, "\u{2502}");
        defer allocator.free(bar);
        try out.appendSlice(allocator, bar);
    } else {
        try out.appendSlice(allocator, "|");
    }
    try stdoutPrint(io, "{s}\n", .{out.items});
}

/// Duration meter ▐████░░░▌ scaled against a 1s ceiling.
fn durationBar(allocator: std.mem.Allocator, ms: i64) ![]const u8 {
    const cells: usize = 14;
    const filled: usize = @intFromFloat(@min(@as(f64, @floatFromInt(ms)) / 1000.0, 1.0) * @as(f64, @floatFromInt(cells)));

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "\u{2596}");
    var i: usize = 0;
    while (i < cells) : (i += 1) {
        if (ansi.enabled and i < filled) {
            const blk = try ansi.green(allocator, "\u{2588}");
            defer allocator.free(blk);
            try out.appendSlice(allocator, blk);
        } else {
            try out.appendSlice(allocator, "\u{2591}");
        }
    }
    try out.appendSlice(allocator, "\u{259f}");
    return out.toOwnedSlice(allocator);
}

fn buildConfigExecutionGroups(
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    options: CliOptions,
    staged_files: [][]const u8,
) ![]ConfigExecutionGroup {
    var groups: std.ArrayListUnmanaged(ConfigExecutionGroup) = .empty;
    errdefer {
        for (groups.items) |*group| group.deinit(allocator);
        groups.deinit(allocator);
    }

    if (options.config) |_| {
        var loaded_config = try config.load(io, allocator, options.cwd, options.config);
        errdefer loaded_config.deinit();

        var group = try createGroup(allocator, repo_root, loaded_config, staged_files);
        errdefer group.deinit(allocator);

        try groups.append(allocator, group);

        return try groups.toOwnedSlice(allocator);
    }

    var nearest_cache: NearestConfigCache = .empty;
    defer freeNearestCache(&nearest_cache, allocator);

    for (staged_files) |file| {
        const absolute_file = try std.fs.path.join(allocator, &.{ repo_root, file });
        defer allocator.free(absolute_file);

        const file_dir = std.fs.path.dirname(absolute_file) orelse repo_root;

        // Files whose directory chain has no configuration are ignored, like
        // lint-staged: only fail when no staged file resolves to any config.
        const resolved = try resolveNearestCached(io, allocator, repo_root, file_dir, &nearest_cache);
        const config_path = resolved orelse continue;

        if (findConfigGroup(groups.items, config_path)) |index| {
            const rel_file = try fileRelativeToConfigDir(allocator, repo_root, groups.items[index].config_dir, file);
            defer allocator.free(rel_file);

            var files: std.ArrayListUnmanaged([]const u8) = .empty;
            defer files.deinit(allocator);

            try files.appendSlice(allocator, groups.items[index].files);
            try files.append(allocator, try allocator.dupe(u8, rel_file));

            allocator.free(groups.items[index].files);
            groups.items[index].files = try files.toOwnedSlice(allocator);

            continue;
        }

        var loaded_config = try config.loadFromPath(io, allocator, config_path);
        errdefer loaded_config.deinit();

        var single_file: [1][]const u8 = undefined;
        single_file[0] = file;
        var group = try createGroup(allocator, repo_root, loaded_config, single_file[0..1]);
        errdefer group.deinit(allocator);

        try groups.append(allocator, group);
    }

    if (groups.items.len == 0) return error.ConfigNotFound;

    return try groups.toOwnedSlice(allocator);
}

fn createGroup(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    loaded_config: config.LoadedConfig,
    staged_files: [][]const u8,
) !ConfigExecutionGroup {
    const parsed_config = try ConfigFromJson(allocator, loaded_config.value);
    errdefer parsed_config.deinit(allocator);

    const config_path = try allocator.dupe(u8, loaded_config.path);
    errdefer allocator.free(config_path);

    const config_dir = try allocator.dupe(u8, std.fs.path.dirname(loaded_config.path) orelse repo_root);
    errdefer allocator.free(config_dir);

    const files = try duplicateFilesRelativeToConfigDir(allocator, repo_root, config_dir, staged_files);
    errdefer {
        for (files) |file| allocator.free(file);
        allocator.free(files);
    }

    return .{
        .config_path = config_path,
        .config_dir = config_dir,
        .loaded_config = loaded_config,
        .parsed_config = parsed_config,
        .files = files,
    };
}

fn resolveNearestCached(
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    dir: []const u8,
    cache: *NearestConfigCache,
) !?[]const u8 {
    if (cache.get(dir)) |cached| return cached;

    const found = try config.findConfigPathInDir(io, allocator, dir);

    const resolved: ?[]const u8 = blk: {
        if (found) |path| break :blk path;

        if (std.mem.eql(u8, dir, repo_root)) break :blk null;

        const parent = std.fs.path.dirname(dir) orelse break :blk null;
        if (parent.len < repo_root.len) break :blk null;

        break :blk try resolveNearestCached(io, allocator, repo_root, parent, cache);
    };

    const owned_dir = try allocator.dupe(u8, dir);
    errdefer allocator.free(owned_dir);

    const owned_value: ?[]const u8 = if (resolved) |value| try allocator.dupe(u8, value) else null;
    errdefer if (owned_value) |value| allocator.free(value);

    try cache.put(allocator, owned_dir, owned_value);

    return owned_value;
}

fn freeNearestCache(cache: *NearestConfigCache, allocator: std.mem.Allocator) void {
    var iterator = cache.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        if (entry.value_ptr.*) |value| allocator.free(value);
    }
    cache.deinit(allocator);
}

fn findConfigGroup(groups: []ConfigExecutionGroup, path: []const u8) ?usize {
    for (groups, 0..) |group, index| {
        if (std.mem.eql(u8, group.config_path, path)) return index;
    }

    return null;
}

fn duplicateFilesRelativeToConfigDir(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    config_dir: []const u8,
    staged_files: [][]const u8,
) ![][]const u8 {
    const files = try allocator.alloc([]const u8, staged_files.len);
    errdefer allocator.free(files);

    var initialized: usize = 0;
    errdefer {
        for (files[0..initialized]) |file| allocator.free(file);
    }

    for (staged_files, 0..) |file, index| {
        files[index] = try fileRelativeToConfigDir(allocator, repo_root, config_dir, file);
        initialized += 1;
    }

    return files;
}

fn fileRelativeToConfigDir(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    config_dir: []const u8,
    staged_file: []const u8,
) ![]const u8 {
    const absolute_file = try std.fs.path.join(allocator, &.{ repo_root, staged_file });
    defer allocator.free(absolute_file);

    return try std.fs.path.relative(
        allocator,
        repo_root,
        null,
        config_dir,
        absolute_file,
    );
}
