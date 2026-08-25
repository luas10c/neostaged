//! Git plumbing for safe task execution: backup snapshots, hiding of
//! partially-staged changes, and restoration helpers.

const std = @import("std");

pub const backup_ref = "refs/neostaged/backup";

fn gitRun(
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    argv: []const []const u8,
) !CaptureResult {
    var full_argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer full_argv.deinit(allocator);

    try full_argv.append(allocator, "git");
    try full_argv.appendSlice(allocator, argv);

    const result = std.process.run(allocator, io, .{
        .argv = full_argv.items,
        .cwd = .{ .path = repo_root },
    }) catch |err| {
        return err;
    };

    return CaptureResult{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .term = result.term,
    };
}

pub const CaptureResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    term: @FieldType(std.process.RunResult, "term"),

    pub fn deinit(self: CaptureResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }

    pub fn ok(self: CaptureResult) bool {
        return self.term == .exited and self.term.exited == 0;
    }
};

/// Current branch short name, or null when detached/unavailable.
pub fn currentBranch(io: std.Io, allocator: std.mem.Allocator, repo_root: []const u8) !?[]const u8 {
    const result = try gitRun(io, allocator, repo_root, &.{ "rev-parse", "--abbrev-ref", "HEAD" });
    defer result.deinit(allocator);

    if (!result.ok()) return null;

    const name = std.mem.trim(u8, result.stdout, " \n\r\t");
    if (name.len == 0 or std.mem.eql(u8, name, "HEAD")) return null;

    return try allocator.dupe(u8, name);
}

/// Snapshot of index + worktree stored under a dedicated ref, away from the
/// user's personal stash stack. Returns null when there is nothing to back up.
pub fn createBackup(io: std.Io, allocator: std.mem.Allocator, repo_root: []const u8) !?Backup {
    const created = try gitRun(io, allocator, repo_root, &.{ "stash", "create", "neostaged automatic backup" });
    defer created.deinit(allocator);

    const hash = std.mem.trim(u8, created.stdout, " \n\r\t");
    if (!created.ok() or hash.len == 0) return null;

    const owned_hash = try allocator.dupe(u8, hash);
    errdefer allocator.free(owned_hash);

    const stored = try gitRun(io, allocator, repo_root, &.{ "update-ref", backup_ref, owned_hash });
    defer stored.deinit(allocator);

    if (!stored.ok()) return error.BackupStoreFailed;

    return .{ .hash = owned_hash };
}

pub const Backup = struct {
    hash: []const u8,

    pub fn deinit(self: Backup, allocator: std.mem.Allocator) void {
        allocator.free(self.hash);
    }
};

/// Restores index and worktree from the backup snapshot.
pub fn applyBackup(io: std.Io, allocator: std.mem.Allocator, repo_root: []const u8) !void {
    // Prefer restoring the staged/unstaged split; fall back to plain apply.
    var result = try gitRun(io, allocator, repo_root, &.{ "stash", "apply", "--index", backup_ref });
    defer result.deinit(allocator);

    if (!result.ok()) {
        result.deinit(allocator);
        result = try gitRun(io, allocator, repo_root, &.{ "stash", "apply", backup_ref });
    }

    if (!result.ok()) return error.BackupApplyFailed;
}

pub fn dropBackup(io: std.Io, allocator: std.mem.Allocator, repo_root: []const u8) void {
    const dropped = gitRun(io, allocator, repo_root, &.{ "update-ref", "-d", backup_ref }) catch return;
    dropped.deinit(allocator);
}

/// Files that are both staged and carry additional unstaged modifications.
pub fn detectPartiallyStaged(
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    staged_files: [][]const u8,
) ![][]const u8 {
    const unstaged = try gitRun(io, allocator, repo_root, &.{ "diff", "--name-only", "-z" });
    defer unstaged.deinit(allocator);

    if (!unstaged.ok()) return error.DetectPartialFailed;

    var modified = std.StringHashMapUnmanaged(void).empty;
    defer modified.deinit(allocator);

    var entries = std.mem.splitScalar(u8, unstaged.stdout, 0);
    while (entries.next()) |entry| {
        if (entry.len == 0) continue;
        try modified.put(allocator, entry, {});
    }

    var partial: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (partial.items) |file| allocator.free(file);
        partial.deinit(allocator);
    }

    for (staged_files) |file| {
        if (modified.contains(file)) {
            try partial.append(allocator, try allocator.dupe(u8, file));
        }
    }

    return try partial.toOwnedSlice(allocator);
}

/// Snapshot needed to restore one partially staged file later through a
/// three-way merge: the staged blob (merge base) and the original worktree
/// content (theirs), both stored safely in the object database.
pub const HiddenPartial = struct {
    path: []const u8,
    base_blob: []const u8,
    theirs_blob: []const u8,

    pub fn deinit(self: HiddenPartial, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.base_blob);
        allocator.free(self.theirs_blob);
    }
};

/// Snapshots each file's original worktree content into the object database
/// and records the staged blob as merge base.
pub fn snapshotPartiallyStaged(
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    partial_files: [][]const u8,
) ![]HiddenPartial {
    var hidden: std.ArrayListUnmanaged(HiddenPartial) = .empty;
    errdefer {
        for (hidden.items) |item| item.deinit(allocator);
        hidden.deinit(allocator);
    }

    for (partial_files) |file| {
        const theirs = try gitRun(io, allocator, repo_root, &.{ "hash-object", "-w", "--", file });
        defer theirs.deinit(allocator);

        const spec = try stagedBlobSpec(allocator, file);
        defer allocator.free(spec);

        const base = try gitRun(io, allocator, repo_root, &.{ "rev-parse", "--verify", spec });
        defer base.deinit(allocator);

        if (!theirs.ok() or !base.ok()) return error.SnapshotFailed;

        const theirs_oid = try allocator.dupe(u8, std.mem.trim(u8, theirs.stdout, " \n\r\t"));
        errdefer allocator.free(theirs_oid);

        const base_oid = try allocator.dupe(u8, std.mem.trim(u8, base.stdout, " \n\r\t"));
        errdefer allocator.free(base_oid);

        try hidden.append(allocator, .{
            .path = try allocator.dupe(u8, file),
            .base_blob = base_oid,
            .theirs_blob = theirs_oid,
        });
    }

    return try hidden.toOwnedSlice(allocator);
}

fn stagedBlobSpec(allocator: std.mem.Allocator, file: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, ":{s}", .{file});
}

/// Resets worktree copies of `files` to their staged (index) content.
pub fn discardWorktreeChanges(
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    files: [][]const u8,
) !void {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.appendSlice(allocator, &.{ "checkout", "--" });
    try argv.appendSlice(allocator, files);

    const result = try gitRun(io, allocator, repo_root, argv.items);
    defer result.deinit(allocator);

    if (!result.ok()) return error.CheckoutFailed;
}

/// Three-way merges each hidden file back onto the task-modified worktree
/// copy. Returns false when any file conflicts; conflicting files are left
/// untouched so the caller can abort without losing anything.
pub fn restoreHiddenPartials(
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    hidden: []HiddenPartial,
) !bool {
    for (hidden) |item| {
        mergeOne(io, allocator, repo_root, item) catch |err| switch (err) {
            error.MergeConflict => return false,
            else => return err,
        };
    }
    return true;
}

fn mergeOne(
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    item: HiddenPartial,
) !void {
    const abs_file = try std.fs.path.join(allocator, &.{ repo_root, item.path });
    defer allocator.free(abs_file);

    const ours_bytes = std.Io.Dir.cwd().readFileAlloc(io, abs_file, allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return, // deleted by tasks: nothing to merge into
        else => return err,
    };
    defer allocator.free(ours_bytes);

    const base_bytes = try catBlob(io, allocator, repo_root, item.base_blob);
    defer allocator.free(base_bytes);
    const theirs_bytes = try catBlob(io, allocator, repo_root, item.theirs_blob);
    defer allocator.free(theirs_bytes);

    // Tasks left this file untouched: the original worktree content is the
    // answer outright — no merge (and no trouble with binary files).
    if (std.mem.eql(u8, ours_bytes, base_bytes)) {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = abs_file, .data = theirs_bytes });
        return;
    }

    // Tasks rewrote exactly what the user had in the worktree: keep tasks' result.
    if (std.mem.eql(u8, ours_bytes, theirs_bytes)) {
        return;
    }

    const tmp_ours = try std.fmt.allocPrint(allocator, "{s}.neostaged-ours", .{abs_file});
    defer allocator.free(tmp_ours);
    const tmp_base = try std.fmt.allocPrint(allocator, "{s}.neostaged-base", .{abs_file});
    defer allocator.free(tmp_base);
    const tmp_theirs = try std.fmt.allocPrint(allocator, "{s}.neostaged-theirs", .{abs_file});
    defer allocator.free(tmp_theirs);

    defer {
        std.Io.Dir.cwd().deleteFile(io, tmp_ours) catch {};
        std.Io.Dir.cwd().deleteFile(io, tmp_base) catch {};
        std.Io.Dir.cwd().deleteFile(io, tmp_theirs) catch {};
    }

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_ours, .data = ours_bytes });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_base, .data = base_bytes });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_theirs, .data = theirs_bytes });

    const merge = try gitRun(io, allocator, repo_root, &.{
        "merge-file",
        "-L",
        "current",
        "-L",
        "staged",
        "-L",
        "unstaged",
        "--",
        tmp_ours,
        tmp_base,
        tmp_theirs,
    });
    defer merge.deinit(allocator);

    if (merge.term != .exited or merge.term.exited != 0) return error.MergeConflict;

    // Merge succeeded: replace the worktree file with the merged result.
    const merged_bytes = try std.Io.Dir.cwd().readFileAlloc(io, tmp_ours, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(merged_bytes);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = abs_file, .data = merged_bytes });
}

fn catBlob(io: std.Io, allocator: std.mem.Allocator, repo_root: []const u8, blob: []const u8) ![]u8 {
    const result = try gitRun(io, allocator, repo_root, &.{ "cat-file", "blob", blob });

    if (!result.ok()) {
        result.deinit(allocator);
        return error.CatFileFailed;
    }

    return @constCast(result.stdout);
}

/// True when the index holds no changes relative to HEAD, meaning every
/// originally staged change was undone.
pub fn indexIsEmptyAgainstHead(
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
) !bool {
    const result = try gitRun(io, allocator, repo_root, &.{ "diff", "--cached", "--quiet", "HEAD" });
    defer result.deinit(allocator);

    if (result.term != .exited) return error.DiffFailed;

    return switch (result.term.exited) {
        0 => true,
        1 => false,
        else => error.DiffFailed,
    };
}
