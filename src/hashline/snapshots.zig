//! Bounded in-memory full-file snapshot history used by recovery.

const std = @import("std");
const format = @import("format.zig");

pub const default_max_paths = 30;
pub const default_max_versions_per_path = 4;
pub const default_max_total_bytes = 64 * 1024 * 1024;

pub const Snapshot = struct {
    path: []const u8,
    text: []u8,
    hash: format.FileHash,
    recorded_at: u64,
    seen_lines: ?std.AutoHashMapUnmanaged(usize, void) = null,

    fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        if (self.seen_lines) |*seen| seen.deinit(allocator);
        self.* = undefined;
    }

    pub fn hasSeenLine(self: *const Snapshot, line: usize) bool {
        const seen = self.seen_lines orelse return false;
        return seen.contains(line);
    }
};

const PathHistory = struct {
    path: []u8,
    versions: std.ArrayList(Snapshot) = .empty,
    last_access: u64,

    fn cost(self: *const PathHistory) usize {
        var total: usize = 1;
        for (self.versions.items) |snapshot| total += utf16CodeUnits(snapshot.text);
        return total;
    }

    fn deinit(self: *PathHistory, allocator: std.mem.Allocator) void {
        for (self.versions.items) |*snapshot| snapshot.deinit(allocator);
        self.versions.deinit(allocator);
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const Options = struct {
    max_paths: usize = default_max_paths,
    max_versions_per_path: usize = default_max_versions_per_path,
    max_total_bytes: usize = default_max_total_bytes,
};

/// Owned LRU snapshot store. Returned snapshot pointers remain valid until the
/// next mutating store operation; callers should consume them immediately.
pub const SnapshotStore = struct {
    allocator: std.mem.Allocator,
    histories: std.ArrayList(PathHistory) = .empty,
    max_paths: usize,
    max_versions_per_path: usize,
    max_total_bytes: usize,
    clock: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, options: Options) SnapshotStore {
        return .{
            .allocator = allocator,
            .max_paths = options.max_paths,
            .max_versions_per_path = options.max_versions_per_path,
            .max_total_bytes = options.max_total_bytes,
        };
    }

    pub fn deinit(self: *SnapshotStore) void {
        self.clear();
        self.histories.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn head(self: *SnapshotStore, path: []const u8) ?*Snapshot {
        const index = self.findHistory(path) orelse return null;
        self.touch(&self.histories.items[index]);
        if (self.histories.items[index].versions.items.len == 0) return null;
        return &self.histories.items[index].versions.items[0];
    }

    pub fn byHash(self: *SnapshotStore, path: []const u8, hash: []const u8) ?*Snapshot {
        const index = self.findHistory(path) orelse return null;
        self.touch(&self.histories.items[index]);
        for (self.histories.items[index].versions.items) |*snapshot| {
            if (std.mem.eql(u8, &snapshot.hash, hash)) return snapshot;
        }
        return null;
    }

    pub fn byContent(self: *SnapshotStore, path: []const u8, full_text: []const u8) ?*Snapshot {
        const index = self.findHistory(path) orelse return null;
        self.touch(&self.histories.items[index]);
        for (self.histories.items[index].versions.items) |*snapshot| {
            if (std.mem.eql(u8, snapshot.text, full_text)) return snapshot;
        }
        return null;
    }

    pub fn findByHash(
        self: *SnapshotStore,
        allocator: std.mem.Allocator,
        hash: []const u8,
    ) ![]const *Snapshot {
        var matches: std.ArrayList(*Snapshot) = .empty;
        // lru-cache iterates most-recently-used paths first. Preserve that order
        // without mutating recency during enumeration.
        const indices = try allocator.alloc(usize, self.histories.items.len);
        for (indices, 0..) |*slot, index| slot.* = index;
        std.mem.sort(usize, indices, self, struct {
            fn newer(store: *SnapshotStore, a: usize, b: usize) bool {
                return store.histories.items[a].last_access > store.histories.items[b].last_access;
            }
        }.newer);
        for (indices) |index| {
            for (self.histories.items[index].versions.items) |*snapshot| {
                if (std.mem.eql(u8, &snapshot.hash, hash)) try matches.append(allocator, snapshot);
            }
        }
        return matches.toOwnedSlice(allocator);
    }

    pub fn record(
        self: *SnapshotStore,
        path: []const u8,
        full_text: []const u8,
        seen_lines: ?[]const usize,
    ) !format.FileHash {
        const hash = format.computeFileHash(full_text);
        const history_index = self.findHistory(path) orelse try self.addHistory(path);
        var history = &self.histories.items[history_index];
        self.touch(history);

        for (history.versions.items, 0..) |*snapshot, index| {
            if (!std.mem.eql(u8, &snapshot.hash, &hash) or !std.mem.eql(u8, snapshot.text, full_text)) continue;
            snapshot.recorded_at = self.clock;
            try mergeSeenLines(self.allocator, snapshot, seen_lines);
            if (index != 0) {
                const promoted = history.versions.orderedRemove(index);
                try history.versions.insert(self.allocator, 0, promoted);
            }
            self.enforceLimits();
            return hash;
        }

        var snapshot: Snapshot = .{
            .path = history.path,
            .text = try self.allocator.dupe(u8, full_text),
            .hash = hash,
            .recorded_at = self.clock,
        };
        errdefer snapshot.deinit(self.allocator);
        try mergeSeenLines(self.allocator, &snapshot, seen_lines);
        try history.versions.insert(self.allocator, 0, snapshot);

        while (history.versions.items.len > self.max_versions_per_path) {
            var removed = history.versions.pop().?;
            removed.deinit(self.allocator);
        }
        self.enforceLimits();
        return hash;
    }

    pub fn recordSeenLines(
        self: *SnapshotStore,
        path: []const u8,
        hash: []const u8,
        lines: []const usize,
    ) !void {
        const snapshot = self.byHash(path, hash) orelse return;
        try mergeSeenLines(self.allocator, snapshot, lines);
    }

    pub fn invalidate(self: *SnapshotStore, path: []const u8) void {
        const index = self.findHistory(path) orelse return;
        var removed = self.histories.orderedRemove(index);
        removed.deinit(self.allocator);
    }

    pub fn relocate(self: *SnapshotStore, from: []const u8, to: []const u8) !void {
        if (std.mem.eql(u8, from, to)) return;
        const source_index = self.findHistory(from) orelse return;
        if (self.findHistory(to)) |original_dest_index| {
            const source_version_count = self.histories.items[source_index].versions.items.len;
            const dest_version_count = self.histories.items[original_dest_index].versions.items.len;
            var merged: std.ArrayList(Snapshot) = .empty;
            try merged.ensureTotalCapacity(self.allocator, source_version_count + dest_version_count);

            var source = self.histories.orderedRemove(source_index);
            const dest_index = original_dest_index - @intFromBool(source_index < original_dest_index);
            var dest = &self.histories.items[dest_index];
            for (source.versions.items) |snapshot| {
                if (!containsHash(merged.items, &snapshot.hash)) merged.appendAssumeCapacity(snapshot) else {
                    var duplicate = snapshot;
                    duplicate.deinit(self.allocator);
                }
            }
            source.versions.clearRetainingCapacity();
            for (dest.versions.items) |snapshot| {
                if (!containsHash(merged.items, &snapshot.hash)) merged.appendAssumeCapacity(snapshot) else {
                    var duplicate = snapshot;
                    duplicate.deinit(self.allocator);
                }
            }
            dest.versions.clearRetainingCapacity();
            source.versions.deinit(self.allocator);
            self.allocator.free(source.path);
            dest.versions.deinit(self.allocator);
            dest.versions = merged;
            for (dest.versions.items) |*snapshot| snapshot.path = dest.path;
            while (dest.versions.items.len > self.max_versions_per_path) {
                var removed = dest.versions.pop().?;
                removed.deinit(self.allocator);
            }
            self.touch(dest);
        } else {
            const next_path = try self.allocator.dupe(u8, to);
            var source = self.histories.orderedRemove(source_index);
            self.allocator.free(source.path);
            source.path = next_path;
            for (source.versions.items) |*snapshot| snapshot.path = source.path;
            self.touch(&source);
            self.histories.appendAssumeCapacity(source);
        }
        self.enforceLimits();
    }

    pub fn clear(self: *SnapshotStore) void {
        for (self.histories.items) |*history| history.deinit(self.allocator);
        self.histories.clearRetainingCapacity();
    }

    fn findHistory(self: *const SnapshotStore, path: []const u8) ?usize {
        for (self.histories.items, 0..) |history, index| {
            if (std.mem.eql(u8, history.path, path)) return index;
        }
        return null;
    }

    fn addHistory(self: *SnapshotStore, path: []const u8) !usize {
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        self.clock +%= 1;
        try self.histories.append(self.allocator, .{
            .path = owned_path,
            .last_access = self.clock,
        });
        return self.histories.items.len - 1;
    }

    fn touch(self: *SnapshotStore, history: *PathHistory) void {
        self.clock +%= 1;
        history.last_access = self.clock;
    }

    fn totalCost(self: *const SnapshotStore) usize {
        var total: usize = 0;
        for (self.histories.items) |*history| total += history.cost();
        return total;
    }

    fn enforceLimits(self: *SnapshotStore) void {
        // `lru-cache` refuses an entry whose own calculated size exceeds the
        // global ceiling. It does not evict unrelated histories in an attempt
        // to make that intrinsically-oversized entry fit. Remove such entries
        // before applying ordinary path-count/global-LRU eviction.
        var oversized_index: usize = 0;
        while (oversized_index < self.histories.items.len) {
            if (self.histories.items[oversized_index].cost() <= self.max_total_bytes) {
                oversized_index += 1;
                continue;
            }
            var removed = self.histories.orderedRemove(oversized_index);
            removed.deinit(self.allocator);
        }
        while (self.histories.items.len > self.max_paths or self.totalCost() > self.max_total_bytes) {
            if (self.histories.items.len == 0) return;
            var oldest_index: usize = 0;
            var oldest_tick = self.histories.items[0].last_access;
            for (self.histories.items[1..], 1..) |history, index| {
                if (history.last_access < oldest_tick) {
                    oldest_tick = history.last_access;
                    oldest_index = index;
                }
            }
            var removed = self.histories.orderedRemove(oldest_index);
            removed.deinit(self.allocator);
        }
    }
};

fn mergeSeenLines(
    allocator: std.mem.Allocator,
    snapshot: *Snapshot,
    lines: ?[]const usize,
) !void {
    const source = lines orelse return;
    if (snapshot.seen_lines == null) snapshot.seen_lines = .{};
    for (source) |line| try snapshot.seen_lines.?.put(allocator, line, {});
}

fn containsHash(snapshots: []const Snapshot, hash: []const u8) bool {
    for (snapshots) |snapshot| if (std.mem.eql(u8, &snapshot.hash, hash)) return true;
    return false;
}

/// JavaScript's `String.length` counts UTF-16 code units; upstream's option is
/// named `maxTotalBytes` but its actual LRU accounting uses that metric.
fn utf16CodeUnits(text: []const u8) usize {
    var units: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(text[index]) catch {
            index += 1;
            units += 1;
            continue;
        };
        if (index + sequence_len > text.len) {
            units += text.len - index;
            break;
        }
        const codepoint = std.unicode.utf8Decode(text[index .. index + sequence_len]) catch {
            index += 1;
            units += 1;
            continue;
        };
        units += if (codepoint > 0xFFFF) 2 else 1;
        index += sequence_len;
    }
    return units;
}

fn exerciseRelocateAllocationFailures(allocator: std.mem.Allocator) !void {
    var store = SnapshotStore.init(allocator, .{});
    defer store.deinit();
    _ = try store.record("source.ts", "source-v1", &.{1});
    _ = try store.record("source.ts", "source-v2", &.{2});
    _ = try store.record("dest.ts", "dest-v1", &.{1});
    try store.relocate("source.ts", "dest.ts");
}

test "hashline snapshots: relocate is allocation-failure safe" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseRelocateAllocationFailures,
        .{},
    );
}

test "hashline snapshots: full content, fusion, history, and collisions" {
    var store = SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const path = "/tmp/a.ts";
    const collide_a = "line one 263\nline two 4471\n";
    const collide_b = "line one 410\nline two 6970\n";
    const first = try store.record(path, collide_a, &.{1});
    const same = try store.record(path, collide_a, &.{2});
    try std.testing.expectEqualStrings(&first, &same);
    try std.testing.expect(store.head(path).?.hasSeenLine(1));
    try std.testing.expect(store.head(path).?.hasSeenLine(2));

    const collision = try store.record(path, collide_b, &.{2});
    try std.testing.expectEqualStrings(&first, &collision);
    try std.testing.expectEqualStrings(collide_b, store.byHash(path, &first).?.text);
    try std.testing.expectEqualStrings(collide_a, store.byContent(path, collide_a).?.text);
}

test "hashline snapshots: path LRU, version cap, global ceiling, and relocate" {
    var store = SnapshotStore.init(std.testing.allocator, .{
        .max_paths = 2,
        .max_versions_per_path = 2,
        .max_total_bytes = 20,
    });
    defer store.deinit();
    const a1 = try store.record("a", "A1\n", &.{1});
    _ = try store.record("a", "A2\n", null);
    _ = try store.record("a", "A3\n", null);
    try std.testing.expect(store.byHash("a", &a1) == null);
    _ = try store.record("b", "B\n", null);
    try store.relocate("b", "c");
    try std.testing.expect(store.head("b") == null);
    try std.testing.expect(store.head("c") != null);

    // An individual history larger than the ceiling is immediately evicted.
    _ = try store.record("huge", "012345678901234567890123", null);
    try std.testing.expect(store.head("huge") == null);
}

test "hashline snapshots: an oversized replacement evicts only its own path history" {
    var store = SnapshotStore.init(std.testing.allocator, .{
        .max_total_bytes = 12,
    });
    defer store.deinit();

    _ = try store.record("a.ts", "A\n", null);
    const b_tag = try store.record("b.ts", "B\n", &.{1});

    _ = try store.record("a.ts", "01234567890123456789", null);

    try std.testing.expect(store.head("a.ts") == null);
    const retained = store.byHash("b.ts", &b_tag).?;
    try std.testing.expectEqualStrings("B\n", retained.text);
    try std.testing.expect(retained.hasSeenLine(1));
}

test "hashline snapshots.test.ts: derives the tag from whole-file content" {
    var store = SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const text = "L1\nL2\nL3\n";
    const tag = try store.record("/tmp/__hashline-snapshots__.ts", text, null);
    const expected = format.computeFileHash(text);
    try std.testing.expectEqualStrings(&expected, &tag);
}

test "hashline snapshots.test.ts: fuses repeated reads of identical content onto one tag" {
    var store = SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const path = "/tmp/__hashline-snapshots__.ts";
    const text = "alpha\nbeta\ngamma\n";
    const first = try store.record(path, text, null);
    const second = try store.record(path, text, null);
    try std.testing.expectEqualStrings(&first, &second);
    try std.testing.expectEqualStrings(text, store.byHash(path, &first).?.text);
}

test "hashline snapshots.test.ts: mints a new tag and retains the prior version" {
    var store = SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const path = "/tmp/__hashline-snapshots__.ts";
    const v1 = "one\ntwo\n";
    const v2 = "one\ntwo\nthree\n";
    const tag1 = try store.record(path, v1, null);
    const tag2 = try store.record(path, v2, null);
    try std.testing.expect(!std.mem.eql(u8, &tag1, &tag2));
    try std.testing.expectEqualStrings(v1, store.byHash(path, &tag1).?.text);
    try std.testing.expectEqualStrings(v2, store.head(path).?.text);
}

test "hashline snapshots.test.ts: promotes a re-observed older version back to head" {
    var store = SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const path = "/tmp/__hashline-snapshots__.ts";
    const tag1 = try store.record(path, "x\n", null);
    _ = try store.record(path, "y\n", null);
    const repeated = try store.record(path, "x\n", null);
    try std.testing.expectEqualStrings(&tag1, &repeated);
    try std.testing.expectEqualStrings(&tag1, &store.head(path).?.hash);
}

test "hashline snapshots.test.ts: bounds per-path history" {
    var store = SnapshotStore.init(std.testing.allocator, .{ .max_versions_per_path = 2 });
    defer store.deinit();
    const path = "/tmp/__hashline-snapshots__.ts";
    const tag_a = try store.record(path, "A\n", null);
    const tag_b = try store.record(path, "B\n", null);
    const tag_c = try store.record(path, "C\n", null);
    try std.testing.expect(store.byHash(path, &tag_a) == null);
    try std.testing.expectEqualStrings("B\n", store.byHash(path, &tag_b).?.text);
    try std.testing.expectEqualStrings("C\n", store.byHash(path, &tag_c).?.text);
}

test "hashline snapshots.test.ts: bounds tracked paths with LRU eviction" {
    var store = SnapshotStore.init(std.testing.allocator, .{ .max_paths = 1 });
    defer store.deinit();
    const tag = try store.record("/tmp/a.ts", "first\n", null);
    _ = try store.record("/tmp/b.ts", "second\n", null);
    try std.testing.expect(store.byHash("/tmp/a.ts", &tag) == null);
}

test "hashline snapshots.test.ts: rejects cross-path lookups" {
    var store = SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record("/tmp/a.ts", "shared\n", null);
    try std.testing.expect(store.byHash("/tmp/b.ts", &tag) == null);
}

test "hashline snapshots.test.ts: invalidate drops one path and clear drops everything" {
    var store = SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag_a = try store.record("/tmp/a.ts", "A\n", null);
    const tag_b = try store.record("/tmp/b.ts", "B\n", null);
    store.invalidate("/tmp/a.ts");
    try std.testing.expect(store.byHash("/tmp/a.ts", &tag_a) == null);
    try std.testing.expect(store.byHash("/tmp/b.ts", &tag_b) != null);
    store.clear();
    try std.testing.expect(store.byHash("/tmp/b.ts", &tag_b) == null);
}

test "hashline snapshots.test.ts: relocate moves history and read provenance" {
    var store = SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record("/tmp/a.ts", "A\n", &.{1});
    try store.relocate("/tmp/a.ts", "/tmp/dest.ts");
    try std.testing.expect(store.byHash("/tmp/a.ts", &tag) == null);
    const moved = store.byHash("/tmp/dest.ts", &tag).?;
    try std.testing.expectEqualStrings("A\n", moved.text);
    try std.testing.expect(moved.hasSeenLine(1));
}

test "hashline snapshots.test.ts: findByHash returns every retained match across paths" {
    var store = SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record("/tmp/a.ts", "shared\n", null);
    _ = try store.record("/tmp/b.ts", "shared\n", null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const matches = try store.findByHash(arena.allocator(), &tag);
    try std.testing.expectEqual(@as(usize, 2), matches.len);
}

test "hashline snapshots.test.ts: keeps colliding texts separate with separate seenLines" {
    var store = SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const path = "/tmp/a.ts";
    const a = "line one 263\nline two 4471\n";
    const b = "line one 410\nline two 6970\n";
    const tag_a = try store.record(path, a, &.{1});
    const tag_b = try store.record(path, b, &.{2});
    try std.testing.expectEqualStrings(&tag_a, &tag_b);
    try std.testing.expect(store.byContent(path, a).?.hasSeenLine(1));
    try std.testing.expect(!store.byContent(path, a).?.hasSeenLine(2));
    try std.testing.expect(store.byContent(path, b).?.hasSeenLine(2));
    try std.testing.expectEqualStrings(b, store.byHash(path, &tag_a).?.text);
}

test "hashline snapshots.test.ts: identical reads of one collider still fuse" {
    var store = SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const path = "/tmp/a.ts";
    const a = "line one 263\nline two 4471\n";
    const b = "line one 410\nline two 6970\n";
    const first = try store.record(path, a, &.{1});
    const again = try store.record(path, a, &.{2});
    try std.testing.expectEqualStrings(&first, &again);
    try std.testing.expect(store.byContent(path, a).?.hasSeenLine(1));
    try std.testing.expect(store.byContent(path, a).?.hasSeenLine(2));
    try std.testing.expect(store.byContent(path, b) == null);
}
