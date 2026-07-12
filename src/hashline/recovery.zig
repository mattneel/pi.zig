//! Stale snapshot recovery: strict patch merge, unchanged-line remap, then
//! guarded non-head session replay.

const std = @import("std");
const apply = @import("apply.zig");
const diff = @import("diff.zig");
const messages = @import("messages.zig");
const snapshots = @import("snapshots.zig");
const types = @import("types.zig");

pub const Args = struct {
    path: []const u8,
    current_text: []const u8,
    file_hash: []const u8,
    edits: []const types.Edit,
};

pub const Result = struct {
    text: []const u8,
    first_changed_line: ?usize,
    warnings: []const []const u8,
};

pub const RecoveryArgs = Args;
pub const RecoveryResult = Result;

pub const Recovery = struct {
    store: *snapshots.SnapshotStore,

    pub fn init(store: *snapshots.SnapshotStore) Recovery {
        return .{ .store = store };
    }

    /// Attempt the upstream recovery ladder in order. Semantic apply failures
    /// decline the current strategy; allocation failures propagate.
    pub fn tryRecover(
        self: *Recovery,
        allocator: std.mem.Allocator,
        args: Args,
    ) !?Result {
        const snapshot = self.store.byHash(args.path, args.file_hash) orelse return null;
        const head = self.store.head(args.path);
        const is_head = head != null and head.? == snapshot;
        const patch_warning = if (is_head)
            messages.recovery_external_warning
        else
            messages.recovery_session_chain_warning;

        if (try applyEditsToSnapshot(
            allocator,
            snapshot.text,
            args.current_text,
            args.edits,
            patch_warning,
        )) |merged| return merged;

        if (try replayRemappedAnchorsOnCurrent(
            allocator,
            snapshot.text,
            args.current_text,
            args.edits,
        )) |remapped| return remapped;

        if (!is_head) {
            return replaySessionChainOnCurrent(
                allocator,
                snapshot.text,
                args.current_text,
                args.edits,
            );
        }
        return null;
    }
};

fn applyEditsToSnapshot(
    allocator: std.mem.Allocator,
    previous_text: []const u8,
    current_text: []const u8,
    edits: []const types.Edit,
    recovery_warning: []const u8,
) !?Result {
    const outcome = try apply.applyEdits(allocator, previous_text, edits);
    const applied = switch (outcome) {
        .failure => return null,
        .success => |result| result,
    };
    if (std.mem.eql(u8, applied.text, previous_text)) return null;

    const patch = try diff.createStructuredPatch(allocator, previous_text, applied.text, 3);
    const merged = (try diff.applyStructuredPatch(allocator, current_text, patch)) orelse return null;
    if (std.mem.eql(u8, merged, current_text)) return null;

    const first_changed_line = findFirstChangedLine(current_text, merged) orelse applied.first_changed_line;
    const warnings = if (first_changed_line != null)
        try prependWarning(allocator, recovery_warning, applied.warnings)
    else
        try allocator.dupe([]const u8, applied.warnings);
    return .{
        .text = merged,
        .first_changed_line = first_changed_line,
        .warnings = warnings,
    };
}

fn collectAnchorLines(
    allocator: std.mem.Allocator,
    edits: []const types.Edit,
) ![]usize {
    var lines: std.ArrayList(usize) = .empty;
    for (edits) |edit| if (edit.anchor()) |anchor| try lines.append(allocator, anchor.line);
    return lines.toOwnedSlice(allocator);
}

fn verifyAnchorContent(
    allocator: std.mem.Allocator,
    previous_text: []const u8,
    current_text: []const u8,
    edits: []const types.Edit,
) !bool {
    const anchors = try collectAnchorLines(allocator, edits);
    if (anchors.len == 0) return true;
    const previous_lines = try diff.splitLines(allocator, previous_text);
    const current_lines = try diff.splitLines(allocator, current_text);
    for (anchors) |line| {
        if (line < 1 or line > previous_lines.len or line > current_lines.len) return false;
        if (!std.mem.eql(u8, previous_lines[line - 1], current_lines[line - 1])) return false;
    }
    return true;
}

fn duplicatedValues(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
) !std.StringHashMapUnmanaged(void) {
    var counts: std.StringHashMapUnmanaged(usize) = .empty;
    defer counts.deinit(allocator);
    for (lines) |line| {
        const entry = try counts.getOrPut(allocator, line);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }
    var duplicated: std.StringHashMapUnmanaged(void) = .empty;
    var iterator = counts.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* >= 2) try duplicated.put(allocator, entry.key_ptr.*, {});
    }
    return duplicated;
}

fn validateRemappedAnchorContext(
    allocator: std.mem.Allocator,
    previous_text: []const u8,
    current_text: []const u8,
    line_map: diff.LineMap,
    edits: []const types.Edit,
) !bool {
    const previous_lines = try diff.splitLines(allocator, previous_text);
    const current_lines = try diff.splitLines(allocator, current_text);
    var anchor_lines = try collectAnchorLines(allocator, edits);
    if (anchor_lines.len == 0) return true;
    std.mem.sort(usize, anchor_lines, {}, std.sort.asc(usize));
    const unique_len = deduplicateSorted(anchor_lines);
    anchor_lines = anchor_lines[0..unique_len];

    var duplicated_previous = try duplicatedValues(allocator, previous_lines);
    defer duplicated_previous.deinit(allocator);
    var duplicated_current = try duplicatedValues(allocator, current_lines);
    defer duplicated_current.deinit(allocator);

    var run_start_index: usize = 0;
    while (run_start_index < anchor_lines.len) {
        var run_end_index = run_start_index;
        while (run_end_index + 1 < anchor_lines.len and
            anchor_lines[run_end_index + 1] == anchor_lines[run_end_index] + 1)
        {
            run_end_index += 1;
        }
        const run_start = anchor_lines[run_start_index];
        const run_end = anchor_lines[run_end_index];
        const before: ?usize = if (run_start > 1 and run_start - 1 <= previous_lines.len) run_start - 1 else null;
        const after: ?usize = if (run_end < previous_lines.len) run_end + 1 else null;

        for (anchor_lines[run_start_index .. run_end_index + 1]) |line| {
            const mapped = line_map.get(line) orelse return false;
            if (line > previous_lines.len or mapped > current_lines.len) return false;
            const duplicated = duplicated_previous.contains(previous_lines[line - 1]) or
                duplicated_current.contains(current_lines[mapped - 1]);
            if (duplicated) {
                var checked = false;
                if (before) |neighbor| {
                    checked = true;
                    if (!mapsAtRelativePosition(line_map, neighbor, line, mapped)) return false;
                }
                if (after) |neighbor| {
                    checked = true;
                    if (!mapsAtRelativePosition(line_map, neighbor, line, mapped)) return false;
                }
                if (!checked) return false;
            } else if (after) |neighbor| {
                if (!mapsAtRelativePosition(line_map, neighbor, line, mapped)) return false;
            } else if (before) |neighbor| {
                if (!mapsAtRelativePosition(line_map, neighbor, line, mapped)) return false;
            } else {
                return false;
            }
        }
        run_start_index = run_end_index + 1;
    }
    return true;
}

fn mapsAtRelativePosition(
    line_map: diff.LineMap,
    context_line: usize,
    anchor_line: usize,
    mapped_anchor: usize,
) bool {
    const mapped_context = line_map.get(context_line) orelse return false;
    if (context_line < anchor_line) {
        const distance = anchor_line - context_line;
        return mapped_anchor >= distance and mapped_context == mapped_anchor - distance;
    }
    const distance = context_line - anchor_line;
    return mapped_context == std.math.add(usize, mapped_anchor, distance) catch return false;
}

fn remapEditsToCurrent(
    allocator: std.mem.Allocator,
    previous_text: []const u8,
    current_text: []const u8,
    edits: []const types.Edit,
) !?[]const types.Edit {
    const line_map = try diff.buildLineMap(allocator, previous_text, current_text);
    if (!try validateRemappedAnchorContext(allocator, previous_text, current_text, line_map, edits)) return null;
    var offsets: std.ArrayList(isize) = .empty;
    var remapped: std.ArrayList(types.Edit) = .empty;

    for (edits) |edit| switch (edit) {
        .delete => |value| {
            var copy = value;
            copy.anchor.line = (try mapLine(&offsets, allocator, line_map, value.anchor.line)) orelse return null;
            try remapped.append(allocator, .{ .delete = copy });
        },
        .block => |value| {
            var copy = value;
            copy.anchor.line = (try mapLine(&offsets, allocator, line_map, value.anchor.line)) orelse return null;
            try remapped.append(allocator, .{ .block = copy });
        },
        .insert => |value| {
            var copy = value;
            if (value.block_start) |block_start| {
                copy.block_start = (try mapLine(&offsets, allocator, line_map, block_start)) orelse return null;
            }
            copy.cursor = switch (value.cursor) {
                .bof => .bof,
                .eof => .eof,
                .before_anchor => |anchor| .{ .before_anchor = .{
                    .line = (try mapLine(&offsets, allocator, line_map, anchor.line)) orelse return null,
                } },
                .after_anchor => |anchor| .{ .after_anchor = .{
                    .line = (try mapLine(&offsets, allocator, line_map, anchor.line)) orelse return null,
                } },
            };
            try remapped.append(allocator, .{ .insert = copy });
        },
    };

    if (offsets.items.len == 0 or offsets.items[0] == 0) return null;
    const expected_offset = offsets.items[0];
    for (offsets.items[1..]) |offset| if (offset != expected_offset) return null;
    return @as(?[]const types.Edit, try remapped.toOwnedSlice(allocator));
}

fn mapLine(
    offsets: *std.ArrayList(isize),
    allocator: std.mem.Allocator,
    line_map: diff.LineMap,
    line: usize,
) !?usize {
    const mapped = line_map.get(line) orelse return null;
    const mapped_signed = std.math.cast(isize, mapped) orelse return null;
    const line_signed = std.math.cast(isize, line) orelse return null;
    try offsets.append(allocator, mapped_signed - line_signed);
    return mapped;
}

fn replayRemappedAnchorsOnCurrent(
    allocator: std.mem.Allocator,
    previous_text: []const u8,
    current_text: []const u8,
    edits: []const types.Edit,
) !?Result {
    const remapped = (try remapEditsToCurrent(allocator, previous_text, current_text, edits)) orelse return null;
    const outcome = try apply.applyEdits(allocator, current_text, remapped);
    const applied = switch (outcome) {
        .failure => return null,
        .success => |result| result,
    };
    if (std.mem.eql(u8, applied.text, current_text)) return null;
    return .{
        .text = applied.text,
        .first_changed_line = applied.first_changed_line,
        .warnings = try prependWarning(allocator, messages.recovery_line_remap_warning, applied.warnings),
    };
}

fn replaySessionChainOnCurrent(
    allocator: std.mem.Allocator,
    previous_text: []const u8,
    current_text: []const u8,
    edits: []const types.Edit,
) !?Result {
    if (lineCount(previous_text) != lineCount(current_text)) return null;
    if (!try verifyAnchorContent(allocator, previous_text, current_text, edits)) return null;
    const outcome = try apply.applyEdits(allocator, current_text, edits);
    const applied = switch (outcome) {
        .failure => return null,
        .success => |result| result,
    };
    if (std.mem.eql(u8, applied.text, current_text)) return null;
    return .{
        .text = applied.text,
        .first_changed_line = applied.first_changed_line,
        .warnings = try prependWarning(allocator, messages.recovery_session_replay_warning, applied.warnings),
    };
}

fn prependWarning(
    allocator: std.mem.Allocator,
    warning: []const u8,
    existing: []const []const u8,
) ![]const []const u8 {
    const warnings = try allocator.alloc([]const u8, existing.len + 1);
    warnings[0] = warning;
    @memcpy(warnings[1..], existing);
    return warnings;
}

fn findFirstChangedLine(a: []const u8, b: []const u8) ?usize {
    if (std.mem.eql(u8, a, b)) return null;
    var a_lines = std.mem.splitScalar(u8, a, '\n');
    var b_lines = std.mem.splitScalar(u8, b, '\n');
    var line: usize = 1;
    while (true) : (line += 1) {
        const a_line = a_lines.next();
        const b_line = b_lines.next();
        if (a_line == null or b_line == null) return line;
        if (!std.mem.eql(u8, a_line.?, b_line.?)) return line;
    }
}

fn lineCount(text: []const u8) usize {
    var count: usize = 1;
    for (text) |byte| if (byte == '\n') {
        count += 1;
    };
    return count;
}

fn deduplicateSorted(values: []usize) usize {
    if (values.len == 0) return 0;
    var write: usize = 1;
    for (values[1..]) |value| {
        if (value == values[write - 1]) continue;
        values[write] = value;
        write += 1;
    }
    return write;
}

fn replacementEdits(line: usize, text: []const u8) [2]types.Edit {
    return .{
        .{ .insert = .{
            .cursor = .{ .before_anchor = .{ .line = line } },
            .text = text,
            .source_line = 1,
            .index = 0,
            .mode = .replacement,
        } },
        .{ .delete = .{
            .anchor = .{ .line = line },
            .source_line = 1,
            .index = 1,
        } },
    };
}

fn rangeReplacementEdits(start: usize, first: []const u8, second: []const u8) [4]types.Edit {
    return .{
        .{ .insert = .{
            .cursor = .{ .before_anchor = .{ .line = start } },
            .text = first,
            .source_line = 1,
            .index = 0,
            .mode = .replacement,
        } },
        .{ .insert = .{
            .cursor = .{ .before_anchor = .{ .line = start + 1 } },
            .text = second,
            .source_line = 1,
            .index = 1,
            .mode = .replacement,
        } },
        .{ .delete = .{
            .anchor = .{ .line = start },
            .source_line = 1,
            .index = 2,
        } },
        .{ .delete = .{
            .anchor = .{ .line = start + 1 },
            .source_line = 1,
            .index = 3,
        } },
    };
}

test "hashline recovery: strict snapshot patch preserves external drift" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = snapshots.SnapshotStore.init(arena.allocator(), .{});
    defer store.deinit();
    const path = "/tmp/recovery.ts";
    const previous = "L1\nL2\nL3\nL4\nL5\nL6\n";
    const tag = try store.record(path, previous, null);
    const edits = replacementEdits(3, "L3-MODEL");
    var recovery = Recovery.init(&store);
    const result = (try recovery.tryRecover(arena.allocator(), .{
        .path = path,
        .current_text = previous ++ "TRAILER\n",
        .file_hash = &tag,
        .edits = &edits,
    })).?;
    try std.testing.expect(std.mem.indexOf(u8, result.text, "L3-MODEL") != null);
    try std.testing.expect(std.mem.endsWith(u8, result.text, "TRAILER\n"));
    try std.testing.expectEqualStrings(messages.recovery_external_warning, result.warnings[0]);
}

test "hashline recovery: colliding tag resolves the most-recent retained text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = snapshots.SnapshotStore.init(arena.allocator(), .{});
    defer store.deinit();
    const path = "/tmp/recovery.ts";
    const older = "line one 263\nline two 4471\n";
    const newer = "line one 410\nline two 6970\n";
    const tag = try store.record(path, older, null);
    const colliding_tag = try store.record(path, newer, null);
    try std.testing.expectEqualStrings(&tag, &colliding_tag);
    const edits = replacementEdits(2, "model payload");
    var recovery = Recovery.init(&store);
    const result = (try recovery.tryRecover(arena.allocator(), .{
        .path = path,
        .current_text = newer ++ "drifted trailer\n",
        .file_hash = &tag,
        .edits = &edits,
    })).?;
    try std.testing.expectEqualStrings(
        "line one 410\nmodel payload\ndrifted trailer\n",
        result.text,
    );
    try std.testing.expectEqualStrings(messages.recovery_external_warning, result.warnings[0]);
}

test "hashline recovery: remaps one consistent nonzero insertion offset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = snapshots.SnapshotStore.init(arena.allocator(), .{});
    defer store.deinit();
    const path = "/tmp/recovery.ts";
    const previous = "L1\nL2\nL3\nL4\nL5\nL6\n";
    const current = "L1\nL2\nINSERTED\nL3\nL4\nL5\nL6\n";
    const tag = try store.record(path, previous, null);
    _ = try store.record(path, current, null);
    const edits = replacementEdits(5, "L5-MODEL");
    var recovery = Recovery.init(&store);
    const result = (try recovery.tryRecover(arena.allocator(), .{
        .path = path,
        .current_text = current,
        .file_hash = &tag,
        .edits = &edits,
    })).?;
    try std.testing.expectEqualStrings("L1\nL2\nINSERTED\nL3\nL4\nL5-MODEL\nL6\n", result.text);
    try std.testing.expectEqualStrings(messages.recovery_line_remap_warning, result.warnings[0]);
}

test "hashline recovery: remaps one consistent nonzero deletion offset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = snapshots.SnapshotStore.init(arena.allocator(), .{});
    defer store.deinit();
    const path = "/tmp/recovery.ts";
    const previous = "L1\nL2\nL3\nL4\nL5\nL6\n";
    const current = "L1\nL3\nL4\nL5\nL6\n";
    const tag = try store.record(path, previous, null);
    _ = try store.record(path, current, null);
    const edits = replacementEdits(5, "L5-MODEL");
    var recovery = Recovery.init(&store);
    const result = (try recovery.tryRecover(arena.allocator(), .{
        .path = path,
        .current_text = current,
        .file_hash = &tag,
        .edits = &edits,
    })).?;
    try std.testing.expectEqualStrings("L1\nL3\nL4\nL5-MODEL\nL6\n", result.text);
    try std.testing.expectEqualStrings(messages.recovery_line_remap_warning, result.warnings[0]);
}

test "hashline recovery: duplicate-line remap requires surrounding context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = snapshots.SnapshotStore.init(arena.allocator(), .{});
    defer store.deinit();
    const path = "/tmp/recovery.ts";
    const previous = "start\nDUP\nmid\nDUP\ntail\n";
    const current = "start\nmid\nDUP\nCHANGED\ntail\n";
    const tag = try store.record(path, previous, null);
    _ = try store.record(path, current, null);
    const edits = replacementEdits(4, "MODEL");
    var recovery = Recovery.init(&store);
    try std.testing.expect((try recovery.tryRecover(arena.allocator(), .{
        .path = path,
        .current_text = current,
        .file_hash = &tag,
        .edits = &edits,
    })) == null);
}

test "hashline recovery: unique-line remap requires following context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = snapshots.SnapshotStore.init(arena.allocator(), .{});
    defer store.deinit();
    const path = "/tmp/recovery.ts";
    const previous = "L1\nL2\nL3\nL4\nT\nL6\n";
    const current = "X\nL1\nL2\nL3\nL4\nT\nT_CHANGED\nL6\n";
    const tag = try store.record(path, previous, null);
    _ = try store.record(path, current, null);
    const edits = replacementEdits(5, "MODEL");
    var recovery = Recovery.init(&store);
    try std.testing.expect((try recovery.tryRecover(arena.allocator(), .{
        .path = path,
        .current_text = current,
        .file_hash = &tag,
        .edits = &edits,
    })) == null);
}

test "hashline recovery: duplicate range remaps when both neighbor contexts match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = snapshots.SnapshotStore.init(arena.allocator(), .{});
    defer store.deinit();
    const path = "/tmp/recovery.ts";
    const previous = "alpha\nDUP\nbeta\nDUP\nomega\n";
    const current = "alpha\nINSERTED\nDUP\nbeta\nDUP\nomega\n";
    const tag = try store.record(path, previous, null);
    _ = try store.record(path, current, null);
    const edits = rangeReplacementEdits(3, "B-MODEL", "MODEL");
    var recovery = Recovery.init(&store);
    const result = (try recovery.tryRecover(arena.allocator(), .{
        .path = path,
        .current_text = current,
        .file_hash = &tag,
        .edits = &edits,
    })).?;
    try std.testing.expectEqualStrings("alpha\nINSERTED\nDUP\nB-MODEL\nMODEL\nomega\n", result.text);
    try std.testing.expectEqualStrings(messages.recovery_line_remap_warning, result.warnings[0]);
}

test "hashline recovery: guarded non-head session replay preserves prior edit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = snapshots.SnapshotStore.init(arena.allocator(), .{});
    defer store.deinit();
    const path = "/tmp/recovery.ts";
    const previous = "L1\nL2\nL3\nL4\nL5\nL6\nL7\nL8\nL9\nL10\n";
    const current = "L1\nL2\nL3\nL4\nL5-CHANGED\nL6\nL7\nL8\nL9\nL10\n";
    const tag = try store.record(path, previous, null);
    _ = try store.record(path, current, null);
    const edits = replacementEdits(3, "L3-MODEL");
    var recovery = Recovery.init(&store);
    const result = (try recovery.tryRecover(arena.allocator(), .{
        .path = path,
        .current_text = current,
        .file_hash = &tag,
        .edits = &edits,
    })).?;
    try std.testing.expect(std.mem.indexOf(u8, result.text, "L3-MODEL") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "L5-CHANGED") != null);
    try std.testing.expectEqualStrings(messages.recovery_session_replay_warning, result.warnings[0]);
}

test "hashline recovery: refuses replay when anchor content changed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = snapshots.SnapshotStore.init(arena.allocator(), .{});
    defer store.deinit();
    const path = "/tmp/recovery.ts";
    const previous = "L1\nL2\nL3\nL4\nL5\nL6\nL7\n";
    const current = "L1\nL2\nL3\nL4\nL5-CHANGED\nL6\nL7\n";
    const tag = try store.record(path, previous, null);
    _ = try store.record(path, current, null);
    const edits = replacementEdits(5, "L5-MODEL");
    var recovery = Recovery.init(&store);
    try std.testing.expect((try recovery.tryRecover(arena.allocator(), .{
        .path = path,
        .current_text = current,
        .file_hash = &tag,
        .edits = &edits,
    })) == null);
}
