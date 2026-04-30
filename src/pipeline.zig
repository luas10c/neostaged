const std = @import("std");
const build_options = @import("build_options");

const config = @import("config.zig");
const status = @import("status.zig");
const ansi = @import("ansi.zig");
const glob = @import("glob.zig");

const files_placeholder = "{files}";

pub const CliOptions = struct {
    cwd: []const u8,
    config: ?[]const u8,
    list: bool,
};

const Config = struct {
    entries: []ConfigEntry,

    fn deinit(self: Config, allocator: std.mem.Allocator) void {
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

pub fn run(io: std.Io, allocator: std.mem.Allocator, options: CliOptions) !void {
    const start_ts = std.Io.Timestamp.now(io, .awake);
    var summary = RunSummary{};

    try stdoutPrint(io,
        \\✔ neostaged v{s}
        \\
        \\Running tasks for staged files...
        \\
        \\
    , .{build_options.version});

    const repo_root = gitRepoRoot(io, allocator, options.cwd) catch |err| {
        switch (err) {
            error.GitRepoRootFailed,
            error.OutOfMemory,
            => {
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

    const staged_files = gitStagedFiles(io, allocator, repo_root) catch |err| {
        try stderrPrint(io, "failed at git staged files: {s}\n", .{@errorName(err)});
        return err;
    };
    defer {
        for (staged_files) |file| allocator.free(file);
        allocator.free(staged_files);
    }

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
        allocator,
        repo_root,
        options,
        staged_files,
    ) catch |err| {
        if (err == error.ConfigNotFound) {
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

    for (groups) |group| {
        const rel_config_path = try std.fs.path.relative(
            allocator,
            repo_root,
            null,
            repo_root,
            group.config_path,
        );
        defer allocator.free(rel_config_path);

        try stdoutPrint(io, "???? {s} — {d} {s}\n", .{
            rel_config_path,
            group.files.len,
            fileLabel(group.files.len),
        });

        const plan = buildExecutionPlan(allocator, group.parsed_config, group.files) catch |err| {
            try stderrPrint(io, "failed at execution plan: {s}\n", .{@errorName(err)});
            return err;
        };
        defer {
            for (plan) |task| task.deinit(allocator);
            allocator.free(plan);
        }

        for (plan, 0..) |task, task_index| {
            const task_last = task_index + 1 == plan.len;
            const task_branch = if (task_last) "└─" else "├─";
            const task_prefix = if (task_last) "   " else "│  ";

            try stdoutPrint(io, "{s} {s}\n", .{ task_branch, task.pattern });

            for (task.commands, 0..) |command, command_index| {
                const command_last = command_index + 1 == task.commands.len;
                const command_branch = if (command_last) "└─" else "├─";

                const rendered_command = try renderCommand(allocator, command, task.files);
                defer allocator.free(rendered_command);

                const display_command = try summarizeCommand(allocator, command, task.files.len);
                defer allocator.free(display_command);

                const label = try std.fmt.allocPrint(
                    allocator,
                    "{s}{s} {s}",
                    .{ task_prefix, command_branch, display_command },
                );
                defer allocator.free(label);

                if (task.files.len == 0) {
                    summary.skipped += 1;
                    try status.print(io, allocator, .skipped, label, " skipped");
                    continue;
                }

                const result = try runShellCommand(io, allocator, rendered_command, group.config_dir, label);
                defer result.deinit(allocator);

                summary.executed += 1;

                if (result.ok) {
                    const suffix = try std.fmt.allocPrint(
                        allocator,
                        " formatted {d} {s} ({d}ms)",
                        .{ task.files.len, fileLabel(task.files.len), result.elapsed_ms },
                    );
                    defer allocator.free(suffix);

                    try status.print(io, allocator, .success, label, suffix);
                } else {
                    summary.failed += 1;
                    failed = try Failure.init(allocator, task.pattern, display_command, result.stderr, result.stdout);
                    try status.print(io, allocator, .failed, label, " failed");
                    break;
                }
            }

            try stdoutPrint(io, "\n", .{});
        }
    }

    if (summary.failed == 0) {
        try applyChanges(io, allocator, repo_root, staged_files);

        const end_ts = std.Io.Timestamp.now(io, .awake);
        const elapsed_ms = start_ts.durationTo(end_ts).toMilliseconds();

        try stdoutPrint(io,
            \\✔ applied changes
            \\✔ cleaned up
            \\
            \\Done in {d}ms
            \\
        , .{elapsed_ms});
        return;
    }

    defer if (failed) |*failure| failure.deinit(allocator);

    try stdoutPrint(io,
        \\✖ Some tasks failed
        \\
        \\Summary:
        \\  • {d} tasks executed
        \\  • {d} failed
        \\  • {d} skipped
        \\
    , .{ summary.executed, summary.failed, summary.skipped });

    if (failed) |failure| {
        try stdoutPrint(io,
            \\Failed:
            \\  {s} → {s}
            \\  └─ {s}
            \\
            \\Aborting commit.
            \\
        , .{ failure.pattern, failure.command, failure.message });
    }

    return error.CommandFailed;
}

const RunSummary = struct {
    executed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
};

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
        "diff",
        "--cached",
        "--name-only",
        "--diff-filter=ACMR",
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

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \n\r\t");
        if (trimmed.len == 0) continue;
        try files.append(allocator, try allocator.dupe(u8, trimmed));
    }

    return try files.toOwnedSlice(allocator);
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
    if (std.mem.indexOf(u8, command, files_placeholder)) |_| {
        const quoted_files = try quoteFiles(allocator, files);
        defer allocator.free(quoted_files);
        return try replaceAll(allocator, command, files_placeholder, quoted_files);
    }

    return try allocator.dupe(u8, command);
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
    file_count: usize,
) ![]const u8 {
    const max_display_len: usize = 80;

    const suffix = if (file_count == 1)
        try allocator.dupe(u8, " (1 file)")
    else
        try std.fmt.allocPrint(allocator, " ({d} files)", .{file_count});
    defer allocator.free(suffix);

    const replaced = try replaceAll(allocator, command, files_placeholder, "<files>");
    defer allocator.free(replaced);

    const available_len = if (max_display_len > suffix.len)
        max_display_len - suffix.len
    else
        0;

    var base: []const u8 = replaced;
    var owned_base: ?[]const u8 = null;
    defer if (owned_base) |value| allocator.free(value);

    if (base.len > available_len and available_len > 0) {
        owned_base = try std.fmt.allocPrint(
            allocator,
            "{s}…",
            .{base[0 .. available_len - 1]},
        );
        base = owned_base.?;
    }

    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ base, suffix });
}

const CommandResult = struct {
    ok: bool,
    stdout: []const u8,
    stderr: []const u8,
    elapsed_ms: i64,

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
) !CommandResult {
    const argv = if (isWindows())
        &[_][]const u8{ "cmd", "/C", command }
    else
        &[_][]const u8{ "sh", "-c", command };

    const result = try status.runPendingCapture(io, allocator, argv, cwd, label);
    return .{
        .ok = result.term == .exited and result.term.exited == 0,
        .stdout = result.stdout,
        .stderr = result.stderr,
        .elapsed_ms = result.elapsed_ms,
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

fn ConfigFromJson(allocator: std.mem.Allocator, value: std.json.Value) !Config {
    const root = switch (value) {
        .object => |object| object,
        else => return error.ConfigMustBeObject,
    };

    const object = if (root.get("tasks")) |tasks|
        switch (tasks) {
            .object => |tasks_object| tasks_object,
            else => return error.TasksMustBeObject,
        }
    else
        root;

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
        .entries = try entries.toOwnedSlice(allocator),
    };
}

fn parseCommands(allocator: std.mem.Allocator, value: std.json.Value) ![][]const u8 {
    switch (value) {
        .string => |command| {
            const commands = try allocator.alloc([]const u8, 1);
            errdefer allocator.free(commands);

            commands[0] = try parseCommandString(allocator, command);
            errdefer allocator.free(commands[0]);

            return commands;
        },
        .array => |array| {
            var commands: std.ArrayListUnmanaged([]const u8) = .empty;
            errdefer {
                for (commands.items) |command| allocator.free(command);
                commands.deinit(allocator);
            }

            for (array.items) |item| {
                const command = switch (item) {
                    .string => |string| string,
                    else => return error.CommandEntriesMustBeStrings,
                };

                try commands.append(allocator, try parseCommandString(allocator, command));
            }

            return try commands.toOwnedSlice(allocator);
        },
        else => return error.ExpectedStringOrArray,
    }
}

fn parseCommandString(allocator: std.mem.Allocator, command: []const u8) ![]const u8 {
    if (std.mem.trim(u8, command, " \n\r\t").len == 0) {
        return error.EmptyCommandString;
    }

    return try allocator.dupe(u8, command);
}

fn globMatch(pattern: []const u8, text: []const u8) bool {
    return globMatchInner(pattern, text);
}

fn globMatchInner(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return text.len == 0;

    if (std.mem.startsWith(u8, pattern, "**/")) {
        if (globMatchInner(pattern[3..], text)) return true;

        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '/' and globMatchInner(pattern[3..], text[i + 1 ..])) {
                return true;
            }
        }

        return false;
    }

    if (std.mem.startsWith(u8, pattern, "**")) {
        if (globMatchInner(pattern[2..], text)) return true;

        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (globMatchInner(pattern[2..], text[i + 1 ..])) return true;
        }

        return false;
    }

    if (pattern[0] == '*') {
        if (globMatchInner(pattern[1..], text)) return true;

        var i: usize = 0;
        while (i < text.len and text[i] != '/') : (i += 1) {
            if (globMatchInner(pattern[1..], text[i + 1 ..])) return true;
        }

        return false;
    }

    if (text.len == 0) return false;

    if (pattern[0] == '?') {
        return text[0] != '/' and globMatchInner(pattern[1..], text[1..]);
    }

    if (pattern[0] == text[0]) {
        return globMatchInner(pattern[1..], text[1..]);
    }

    return false;
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

const CaptureResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    term: @FieldType(std.process.RunResult, "term"),

    fn deinit(self: CaptureResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn runCapture(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) !CaptureResult {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
    });

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .term = result.term,
    };
}

fn colorsEnabled() bool {
    return true;
}

const ColorFn = fn (std.mem.Allocator, []const u8) anyerror![]u8;

fn printCommandFailureTerm(io: std.Io, term: std.process.Child.Term) !void {
    switch (term) {
        .exited => |code| {
            try stderrPrint(io, "command exited with status {d}\n", .{code});
        },
        .signal => |signal| {
            try stderrPrint(io, "command terminated by signal {d}\n", .{signal});
        },
        else => {
            try stderrPrint(io, "command failed: {any}\n", .{term});
        },
    }
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

fn formatFileCount(n: usize) []const u8 {
    return if (n == 1) "file" else "files";
}

fn fileLabel(count: usize) []const u8 {
    return if (count == 1) "file" else "files";
}

fn buildConfigExecutionGroups(
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
        var loaded_config = try config.load(allocator, options.cwd, options.config);
        errdefer loaded_config.deinit();

        const parsed_config = try ConfigFromJson(allocator, loaded_config.value);
        errdefer parsed_config.deinit(allocator);

        const config_path = try allocator.dupe(u8, loaded_config.path);
        errdefer allocator.free(config_path);

        const config_dir = try allocator.dupe(u8, std.fs.path.dirname(loaded_config.path) orelse repo_root);
        errdefer allocator.free(config_dir);

        const files = try duplicateFilesRelativeToConfigDir(
            allocator,
            repo_root,
            config_dir,
            staged_files,
        );
        errdefer {
            for (files) |file| allocator.free(file);
            allocator.free(files);
        }

        try groups.append(allocator, .{
            .config_path = config_path,
            .config_dir = config_dir,
            .loaded_config = loaded_config,
            .parsed_config = parsed_config,
            .files = files,
        });

        return try groups.toOwnedSlice(allocator);
    }

    for (staged_files) |file| {
        var loaded_config = try config.loadNearest(allocator, repo_root, file);
        errdefer loaded_config.deinit();

        if (findConfigGroup(groups.items, loaded_config.path)) |index| {
            const config_dir = groups.items[index].config_dir;
            const rel_file = try fileRelativeToConfigDir(allocator, repo_root, config_dir, file);
            errdefer allocator.free(rel_file);

            var files: std.ArrayListUnmanaged([]const u8) = .empty;
            defer files.deinit(allocator);

            try files.appendSlice(allocator, groups.items[index].files);
            try files.append(allocator, rel_file);

            allocator.free(groups.items[index].files);
            groups.items[index].files = try files.toOwnedSlice(allocator);

            loaded_config.deinit();
            continue;
        }

        const parsed_config = try ConfigFromJson(allocator, loaded_config.value);
        errdefer parsed_config.deinit(allocator);

        const config_path = try allocator.dupe(u8, loaded_config.path);
        errdefer allocator.free(config_path);

        const config_dir = try allocator.dupe(u8, std.fs.path.dirname(loaded_config.path) orelse repo_root);
        errdefer allocator.free(config_dir);

        const files = try allocator.alloc([]const u8, 1);
        errdefer allocator.free(files);

        files[0] = try fileRelativeToConfigDir(allocator, repo_root, config_dir, file);
        errdefer allocator.free(files[0]);

        try groups.append(allocator, .{
            .config_path = config_path,
            .config_dir = config_dir,
            .loaded_config = loaded_config,
            .parsed_config = parsed_config,
            .files = files,
        });
    }

    if (groups.items.len == 0) return error.ConfigNotFound;

    return try groups.toOwnedSlice(allocator);
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
