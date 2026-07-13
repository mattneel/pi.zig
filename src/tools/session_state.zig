//! Per-session state shared by the essential coding tools.
//!
//! `SessionState` owns its cwd, optional home path, snapshot history, and
//! no-op guard. Tool declarations borrow a pointer to the state, so callers
//! must keep it at a stable address until the registry and agent session are
//! finished.

const std = @import("std");
const hashline = @import("../hashline/hashline.zig");
const fs_real = @import("fs_real.zig");

const Allocator = std.mem.Allocator;

pub const EditMode = enum {
    hashline,
};

pub const Settings = struct {
    edit_mode: EditMode = .hashline,
    read_default_limit: usize = 300,
    read_line_numbers: bool = false,
    output_max_columns: usize = 768,
    edit_fuzzy_match: bool = true,
    edit_fuzzy_threshold: f64 = 0.8,
    block_auto_generated: bool = true,
    has_edit_tool: bool = true,
    shell: ?[]const u8 = null,
};

pub const FileDisplayMode = struct {
    hash_lines: bool,
    line_numbers: bool,
};

pub const InitOptions = struct {
    cwd: []const u8,
    home: ?[]const u8 = null,
    settings: Settings = .{},
};

const NoopEntry = struct {
    payload_hash: u64,
    count: usize,
};

pub const NoopRecord = struct {
    count: usize,
    escalate: bool,
};

pub const noop_hard_limit = 3;
pub const snapshot_max_bytes = 4 * 1024 * 1024;

pub const SessionState = struct {
    allocator: Allocator,
    io: std.Io,
    cwd: []u8,
    home: ?[]u8,
    settings: Settings,
    snapshots: hashline.SnapshotStore,
    snapshot_mutex: std.Io.Mutex = .init,
    real_fs: fs_real.RealFs,
    noop_entries: std.StringHashMapUnmanaged(NoopEntry) = .empty,

    pub fn init(allocator: Allocator, io: std.Io, options: InitOptions) !SessionState {
        const cwd = try std.fs.path.resolve(allocator, &.{options.cwd});
        errdefer allocator.free(cwd);
        const home = if (options.home) |value| try std.fs.path.resolve(allocator, &.{value}) else null;
        errdefer if (home) |value| allocator.free(value);
        return .{
            .allocator = allocator,
            .io = io,
            .cwd = cwd,
            .home = home,
            .settings = options.settings,
            .snapshots = hashline.SnapshotStore.init(allocator, .{}),
            .real_fs = fs_real.RealFs.init(io, cwd, home),
        };
    }

    pub fn deinit(self: *SessionState) void {
        var iterator = self.noop_entries.iterator();
        while (iterator.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.noop_entries.deinit(self.allocator);
        self.snapshots.deinit();
        if (self.home) |home| self.allocator.free(home);
        self.allocator.free(self.cwd);
        self.* = undefined;
    }

    pub fn displayMode(self: *const SessionState, raw: bool, immutable: bool) FileDisplayMode {
        const hash_lines = !raw and !immutable and self.settings.has_edit_tool and self.settings.edit_mode == .hashline;
        return .{
            .hash_lines = hash_lines,
            .line_numbers = !raw and (hash_lines or self.settings.read_line_numbers),
        };
    }

    pub fn recordReadSnapshot(
        self: *SessionState,
        io: std.Io,
        canonical_path: []const u8,
        normalized_text: []const u8,
        seen_lines: ?[]const usize,
    ) !?hashline.FileHash {
        if (normalized_text.len > snapshot_max_bytes) return null;
        self.snapshot_mutex.lockUncancelable(io);
        defer self.snapshot_mutex.unlock(io);
        return try self.snapshots.record(canonical_path, normalized_text, seen_lines);
    }

    pub fn recordNoop(self: *SessionState, canonical_path: []const u8, payload: []const u8) !NoopRecord {
        const payload_hash = std.hash.XxHash64.hash(0, payload);
        if (self.noop_entries.getPtr(canonical_path)) |entry| {
            entry.count = if (entry.payload_hash == payload_hash) entry.count + 1 else 1;
            entry.payload_hash = payload_hash;
            return .{ .count = entry.count, .escalate = entry.count >= noop_hard_limit };
        }
        const owned_path = try self.allocator.dupe(u8, canonical_path);
        errdefer self.allocator.free(owned_path);
        try self.noop_entries.put(self.allocator, owned_path, .{ .payload_hash = payload_hash, .count = 1 });
        return .{ .count = 1, .escalate = false };
    }

    pub fn resetNoop(self: *SessionState, canonical_path: []const u8) void {
        const removed = self.noop_entries.fetchRemove(canonical_path) orelse return;
        self.allocator.free(removed.key);
    }
};

test "session state file display mode matches hashline precedence" {
    var state = try SessionState.init(std.testing.allocator, std.testing.io, .{ .cwd = "." });
    defer state.deinit();
    try std.testing.expectEqual(FileDisplayMode{ .hash_lines = true, .line_numbers = true }, state.displayMode(false, false));
    try std.testing.expectEqual(FileDisplayMode{ .hash_lines = false, .line_numbers = false }, state.displayMode(true, false));
    try std.testing.expectEqual(FileDisplayMode{ .hash_lines = false, .line_numbers = false }, state.displayMode(false, true));
}

test "session state no-op guard escalates the third identical payload" {
    var state = try SessionState.init(std.testing.allocator, std.testing.io, .{ .cwd = "." });
    defer state.deinit();
    try std.testing.expect(!(try state.recordNoop("a", "same")).escalate);
    try std.testing.expect(!(try state.recordNoop("a", "same")).escalate);
    try std.testing.expect((try state.recordNoop("a", "same")).escalate);
    try std.testing.expectEqual(@as(usize, 1), (try state.recordNoop("a", "different")).count);
}
