//! Upstream patcher, file-operation, and recovery corpus port.

const std = @import("std");
const format = @import("format.zig");
const fs_mod = @import("fs.zig");
const input = @import("input.zig");
const messages = @import("messages.zig");
const parser = @import("parser.zig");
const patcher_mod = @import("patcher.zig");
const recovery_mod = @import("recovery.zig");
const snapshots = @import("snapshots.zig");
const types = @import("types.zig");

const path = "a.ts";

fn taggedInput(
    allocator: std.mem.Allocator,
    target: []const u8,
    tag: []const u8,
    body: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(allocator, "[{s}#{s}]\n{s}", .{ target, tag, body });
}

fn expectApplySuccess(outcome: types.Outcome(patcher_mod.ApplyResult)) !patcher_mod.ApplyResult {
    return switch (outcome) {
        .success => |result| result,
        .failure => |failure| {
            std.debug.print("unexpected patch failure: {s}\n", .{failure.message});
            return error.UnexpectedPatchFailure;
        },
    };
}

fn expectApplyFailure(outcome: types.Outcome(patcher_mod.ApplyResult)) !types.Failure {
    return switch (outcome) {
        .failure => |failure| failure,
        .success => return error.ExpectedPatchFailure,
    };
}

fn expectSectionSuccess(outcome: types.Outcome(input.PatchSection)) !input.PatchSection {
    return switch (outcome) {
        .success => |section| section,
        .failure => |failure| {
            std.debug.print("unexpected section parse failure: {s}\n", .{failure.message});
            return error.UnexpectedParseFailure;
        },
    };
}

fn expectParseSuccess(outcome: types.Outcome(parser.ParseResult)) !parser.ParseResult {
    return switch (outcome) {
        .success => |result| result,
        .failure => |failure| {
            std.debug.print("unexpected body parse failure: {s}\n", .{failure.message});
            return error.UnexpectedParseFailure;
        },
    };
}

fn expectParseFailure(outcome: types.Outcome(parser.ParseResult)) !types.Failure {
    return switch (outcome) {
        .failure => |failure| failure,
        .success => return error.ExpectedParseFailure,
    };
}

fn warningPresent(warnings: []const []const u8, expected: []const u8) bool {
    for (warnings) |warning| if (std.mem.eql(u8, warning, expected)) return true;
    return false;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

const PolicyFs = struct {
    memory: fs_mod.InMemoryFs,
    allow_recovery: bool = true,
    block_all_preflights: bool = false,
    blocked_preflight_path: ?[]const u8 = null,
    failed_write_path: ?[]const u8 = null,
    dynamic_error_message: ?[]const u8 = null,
    preflight_count: usize = 0,
    last_preflight_path: ?[]const u8 = null,

    fn init(allocator: std.mem.Allocator) PolicyFs {
        return .{ .memory = fs_mod.InMemoryFs.init(allocator) };
    }

    fn deinit(self: *PolicyFs) void {
        self.memory.deinit();
        self.* = undefined;
    }

    fn fs(self: *PolicyFs) fs_mod.Fs {
        return .{ .context = self, .vtable = &vtable };
    }

    fn read(context: *anyopaque, allocator: std.mem.Allocator, target: []const u8) ![]u8 {
        const self: *PolicyFs = @ptrCast(@alignCast(context));
        return self.memory.fs().read(allocator, target);
    }

    fn write(context: *anyopaque, allocator: std.mem.Allocator, target: []const u8, content: []const u8) ![]u8 {
        const self: *PolicyFs = @ptrCast(@alignCast(context));
        if (self.failed_write_path) |failed| {
            if (std.mem.eql(u8, failed, target)) return error.AdapterWriteFailure;
        }
        return self.memory.fs().write(allocator, target, content);
    }

    fn exists(context: *anyopaque, target: []const u8) !bool {
        const self: *PolicyFs = @ptrCast(@alignCast(context));
        return self.memory.fs().exists(target);
    }

    fn rename(context: *anyopaque, from: []const u8, to: []const u8, content: ?[]const u8) !void {
        const self: *PolicyFs = @ptrCast(@alignCast(context));
        return self.memory.fs().rename(from, to, content);
    }

    fn delete(context: *anyopaque, target: []const u8) !void {
        const self: *PolicyFs = @ptrCast(@alignCast(context));
        return self.memory.fs().delete(target);
    }

    fn canonicalPath(context: *anyopaque, allocator: std.mem.Allocator, target: []const u8) ![]u8 {
        const self: *PolicyFs = @ptrCast(@alignCast(context));
        return self.memory.fs().canonicalPath(allocator, target);
    }

    fn preflight(context: *anyopaque, target: []const u8, _: ?types.FileOp) !void {
        const self: *PolicyFs = @ptrCast(@alignCast(context));
        self.preflight_count += 1;
        self.last_preflight_path = target;
        if (self.block_all_preflights) return error.WriteGateReadOnly;
        if (self.blocked_preflight_path) |blocked| {
            if (std.mem.eql(u8, blocked, target)) return error.WriteGateReadOnly;
        }
    }

    fn allowRecovery(context: *anyopaque, _: []const u8, _: []const u8) bool {
        const self: *PolicyFs = @ptrCast(@alignCast(context));
        return self.allow_recovery;
    }

    fn errorMessage(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        err: anyerror,
    ) std.mem.Allocator.Error![]const u8 {
        const self: *PolicyFs = @ptrCast(@alignCast(context));
        return allocator.dupe(u8, self.dynamic_error_message orelse @errorName(err));
    }

    const vtable: fs_mod.Fs.VTable = .{
        .read = read,
        .write = write,
        .exists = exists,
        .rename = rename,
        .delete = delete,
        .canonical_path = canonicalPath,
        .preflight_write = preflight,
        .allow_tag_path_recovery = allowRecovery,
        .error_message = errorMessage,
    };
};

fn parsedEdits(allocator: std.mem.Allocator, body: []const u8) ![]const types.Edit {
    const parsed = try expectParseSuccess(try parser.parsePatch(allocator, body));
    return parsed.edits;
}

fn lines(allocator: std.mem.Allocator, rows: []const []const u8) ![]const u8 {
    const joined = try std.mem.join(allocator, "\n", rows);
    return std.mem.concat(allocator, u8, &.{ joined, "\n" });
}

// patcher.test.ts — 27/27

test "hashline: patcher.test.ts: requires a snapshot store at construction" {
    var found_required_pointer = false;
    inline for (@typeInfo(patcher_mod.Options).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "snapshot_store")) {
            found_required_pointer = field.type == *snapshots.SnapshotStore;
        }
    }
    try std.testing.expect(found_required_pointer);
}

test "hashline: patcher.test.ts: applies when section tag is live content hash" {
    var memory = fs_mod.InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    try memory.put(path, "before\n");
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record(path, "before\n", null);
    var patcher = patcher_mod.Patcher.init(.{ .fs = memory.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try expectApplySuccess(try patcher.applyText(
        arena.allocator(),
        try taggedInput(arena.allocator(), path, &tag, "SWAP 1.=1:\n+after"),
    ));
    try std.testing.expectEqual(patcher_mod.Operation.update, result.sections[0].op);
    try std.testing.expect(!std.mem.eql(u8, &tag, &result.sections[0].file_hash));
    try std.testing.expectEqualStrings("after\n", memory.get(path).?);
}

test "hashline: patcher.test.ts: restores a UTF-8 BOM hidden by text decoding" {
    var memory = fs_mod.InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    try memory.put(path, "\xEF\xBB\xBFusing A;\n");
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record(path, "using A;\n", null);
    var patcher = patcher_mod.Patcher.init(.{ .fs = memory.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try expectApplySuccess(try patcher.applyText(
        arena.allocator(),
        try taggedInput(arena.allocator(), path, &tag, "SWAP 1.=1:\n+using B;"),
    ));
    try std.testing.expectEqualStrings("\xEF\xBB\xBFusing B;\n", memory.get(path).?);
}

test "hashline: patcher.test.ts: validates any anchor from content hash without recorded snapshot" {
    const content = "l1\nl2\nl3\nl4\nl5\n";
    var memory = fs_mod.InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    try memory.put(path, content);
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = format.computeFileHash(content);
    try std.testing.expect(store.byHash(path, &tag) == null);
    var patcher = patcher_mod.Patcher.init(.{ .fs = memory.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try expectApplySuccess(try patcher.applyText(
        arena.allocator(),
        try taggedInput(arena.allocator(), path, &tag, "SWAP 3.=3:\n+L3"),
    ));
    try std.testing.expectEqualStrings("l1\nl2\nL3\nl4\nl5\n", memory.get(path).?);
}

test "hashline: patcher.test.ts: normalizes lowercase section tags while parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const section = try expectSectionSuccess(try input.Patch.parseSingle(
        arena.allocator(),
        "[a.ts#1a2b]\nSWAP 1.=1:\n+after",
        .{},
    ));
    try std.testing.expectEqualStrings("1A2B", &section.file_hash.?);
}

test "hashline: patcher.test.ts: recognized stale version reports file changed mismatch" {
    var memory = fs_mod.InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    try memory.put(path, "drifted\n");
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record(path, "before\n", null);
    var patcher = patcher_mod.Patcher.init(.{ .fs = memory.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const failure = try expectApplyFailure(try patcher.applyText(
        arena.allocator(),
        try taggedInput(arena.allocator(), path, &tag, "SWAP 1.=1:\n+after"),
    ));
    try std.testing.expectEqual(types.FailureKind.mismatch, failure.kind);
    try std.testing.expect(contains(failure.message, "file changed between read and edit"));
    try std.testing.expect(contains(failure.message, "Section is bound to #"));
    try std.testing.expectEqualStrings("drifted\n", memory.get(path).?);
}

test "hashline: patcher.test.ts: unrecorded tag reports not from this session" {
    const content = "current\n";
    var memory = fs_mod.InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    try memory.put(path, content);
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const live = format.computeFileHash(content);
    const bogus = if (std.mem.eql(u8, &live, "FFFF")) "0000" else "FFFF";
    var patcher = patcher_mod.Patcher.init(.{ .fs = memory.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const failure = try expectApplyFailure(try patcher.applyText(
        arena.allocator(),
        try taggedInput(arena.allocator(), path, bogus, "SWAP 1.=1:\n+after"),
    ));
    try std.testing.expect(contains(failure.message, "hash #FFFF is not from this session"));
    try std.testing.expect(contains(failure.message, "never invent the tag"));
    try std.testing.expect(contains(failure.message, "current file hashes to #"));
    try std.testing.expectEqualStrings(content, memory.get(path).?);
}

test "hashline: patcher.test.ts: live content wins against a retained colliding snapshot" {
    const snapshot_text = "line one 263\nline two 4471\n";
    const live_text = "line one 410\nline two 6970\n";
    var memory = fs_mod.InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    try memory.put(path, live_text);
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record(path, snapshot_text, &.{ 1, 2 });
    try std.testing.expectEqualStrings(&tag, &format.computeFileHash(live_text));
    var patcher = patcher_mod.Patcher.init(.{ .fs = memory.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try expectApplySuccess(try patcher.applyText(
        arena.allocator(),
        try taggedInput(arena.allocator(), path, &tag, "SWAP 2.=2:\n+edited live"),
    ));
    try std.testing.expectEqualStrings("line one 410\nedited live\n", memory.get(path).?);
}

test "hashline: patcher.test.ts: rejects hashless head tail insert" {
    var memory = fs_mod.InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    try memory.put(path, "a\nb\n");
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    var patcher = patcher_mod.Patcher.init(.{ .fs = memory.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const failure = try expectApplyFailure(try patcher.applyText(arena.allocator(), "[a.ts]\nINS.TAIL:\n+c"));
    try std.testing.expect(contains(failure.message, "Missing hashline snapshot tag"));
    try std.testing.expect(contains(failure.message, "use the write tool"));
    try std.testing.expectEqualStrings("a\nb\n", memory.get(path).?);
}

test "hashline: patcher.test.ts: rejects hashless anchored edit" {
    var memory = fs_mod.InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    try memory.put(path, "a\nb\n");
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    var patcher = patcher_mod.Patcher.init(.{ .fs = memory.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const failure = try expectApplyFailure(try patcher.applyText(arena.allocator(), "[a.ts]\nSWAP 1.=1:\n+X"));
    try std.testing.expect(contains(failure.message, "Missing hashline snapshot tag"));
}

test "hashline: patcher.test.ts: tagged edit rejects missing target file" {
    var memory = fs_mod.InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    var patcher = patcher_mod.Patcher.init(.{ .fs = memory.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const failure = try expectApplyFailure(try patcher.applyText(
        arena.allocator(),
        "[ghost.ts#1A2B]\nINS.TAIL:\n+c",
    ));
    try std.testing.expectEqual(types.FailureKind.not_found, failure.kind);
    try std.testing.expect(contains(failure.message, "File not found"));
    try std.testing.expect(contains(failure.message, "write tool"));
}

test "hashline: patcher.test.ts: stale head tail insert applies with warning" {
    const content = "a\nb\n";
    var memory = fs_mod.InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    try memory.put(path, content);
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const live = format.computeFileHash(content);
    const stale = if (std.mem.eql(u8, &live, "0000")) "FFFF" else "0000";
    var patcher = patcher_mod.Patcher.init(.{ .fs = memory.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try expectApplySuccess(try patcher.applyText(
        arena.allocator(),
        try taggedInput(arena.allocator(), path, stale, "INS.TAIL:\n+c"),
    ));
    try std.testing.expectEqualStrings("a\nb\nc\n", memory.get(path).?);
    try std.testing.expect(warningPresent(result.sections[0].warnings, messages.headtail_drift_warning));
}

test "hashline: patcher.test.ts: live head tail insert does not warn" {
    const content = "a\nb\n";
    var memory = fs_mod.InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    try memory.put(path, content);
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record(path, content, null);
    var patcher = patcher_mod.Patcher.init(.{ .fs = memory.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try expectApplySuccess(try patcher.applyText(
        arena.allocator(),
        try taggedInput(arena.allocator(), path, &tag, "INS.TAIL:\n+c"),
    ));
    try std.testing.expect(!warningPresent(result.sections[0].warnings, messages.headtail_drift_warning));
}

test "hashline: patcher.test.ts: rejects anchor on line never displayed" {
    const content = "l1\nl2\nl3\nl4\nl5\n";
    var memory = fs_mod.InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    try memory.put(path, content);
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record(path, content, &.{ 1, 2 });
    var patcher = patcher_mod.Patcher.init(.{ .fs = memory.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const failure = try expectApplyFailure(try patcher.applyText(
        arena.allocator(),
        try taggedInput(arena.allocator(), path, &tag, "SWAP 4.=4:\n+L4"),
    ));
    try std.testing.expect(contains(failure.message, "never displayed (it showed"));
    try std.testing.expectEqualStrings(content, memory.get(path).?);
}

test "hashline: patcher.test.ts: applies anchor on displayed line" {
    const content = "l1\nl2\nl3\nl4\nl5\n";
    var memory = fs_mod.InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    try memory.put(path, content);
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record(path, content, &.{ 1, 2 });
    var patcher = patcher_mod.Patcher.init(.{ .fs = memory.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try expectApplySuccess(try patcher.applyText(
        arena.allocator(),
        try taggedInput(arena.allocator(), path, &tag, "SWAP 2.=2:\n+L2"),
    ));
    try std.testing.expectEqualStrings("l1\nL2\nl3\nl4\nl5\n", memory.get(path).?);
}

test "hashline: patcher.test.ts: repeated reads fuse and widen seen-line coverage" {
    const content = "l1\nl2\nl3\nl4\nl5\n";
    var memory = fs_mod.InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    try memory.put(path, content);
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record(path, content, &.{ 1, 2 });
    _ = try store.record(path, content, &.{ 4, 5 });
    var patcher = patcher_mod.Patcher.init(.{ .fs = memory.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try expectApplySuccess(try patcher.applyText(
        arena.allocator(),
        try taggedInput(arena.allocator(), path, &tag, "SWAP 4.=4:\n+L4"),
    ));
    try std.testing.expectEqualStrings("l1\nl2\nl3\nL4\nl5\n", memory.get(path).?);
}

test "hashline: patcher.test.ts: rejection reveals content and same-tag retry succeeds" {
    const content = "l1\nl2\nl3\nl4\nl5\n";
    var memory = fs_mod.InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    try memory.put(path, content);
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record(path, content, &.{ 1, 2 });
    var patcher = patcher_mod.Patcher.init(.{ .fs = memory.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const patch_text = try taggedInput(arena.allocator(), path, &tag, "SWAP 4.=4:\n+L4");
    const failure = try expectApplyFailure(try patcher.applyText(arena.allocator(), patch_text));
    try std.testing.expect(contains(failure.message, "Actual file content at those lines:"));
    try std.testing.expect(contains(failure.message, "4:l4"));
    _ = try expectApplySuccess(try patcher.applyText(arena.allocator(), patch_text));
    try std.testing.expectEqualStrings("l1\nl2\nl3\nL4\nl5\n", memory.get(path).?);
}

test "hashline: patcher.test.ts: over-cap reveal stays anchored across retries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var content_builder: std.ArrayList(u8) = .empty;
    for (1..201) |line_number| try content_builder.print(arena.allocator(), "l{d}\n", .{line_number});
    const content = try content_builder.toOwnedSlice(arena.allocator());
    var body_builder: std.ArrayList(u8) = .empty;
    for (100..160) |line_number| {
        if (body_builder.items.len > 0) try body_builder.append(arena.allocator(), '\n');
        try body_builder.print(arena.allocator(), "DEL {d}", .{line_number});
    }
    const body = try body_builder.toOwnedSlice(arena.allocator());
    var memory = fs_mod.InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    try memory.put(path, content);
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record(path, content, &.{1});
    var patcher = patcher_mod.Patcher.init(.{ .fs = memory.fs(), .snapshot_store = &store });
    const patch_text = try taggedInput(arena.allocator(), path, &tag, body);
    const first = try expectApplyFailure(try patcher.applyText(arena.allocator(), patch_text));
    try std.testing.expect(contains(first.message, "first 40 unseen line(s)"));
    try std.testing.expect(contains(first.message, "100:l100"));
    try std.testing.expect(contains(first.message, "139:l139"));
    try std.testing.expect(!contains(first.message, "140:l140"));
    try std.testing.expect(contains(first.message, "a.ts:100-159"));
    const retry = try expectApplyFailure(try patcher.applyText(arena.allocator(), patch_text));
    try std.testing.expect(contains(retry.message, "100:l100"));
    try std.testing.expect(contains(retry.message, "139:l139"));
    try std.testing.expect(!contains(retry.message, "140:l140"));
    try std.testing.expectEqualStrings(content, memory.get(path).?);
}

test "hashline: patcher.test.ts: wide reveal clips columns and never opens retry gate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const wide = try arena.allocator().alloc(u8, 4096);
    @memset(wide, 'a');
    const content = try std.mem.concat(arena.allocator(), u8, &.{ "l1\n", wide, "\nl3\nl4\n" });
    var memory = fs_mod.InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    try memory.put(path, content);
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record(path, content, &.{1});
    var patcher = patcher_mod.Patcher.init(.{ .fs = memory.fs(), .snapshot_store = &store });
    const patch_text = try taggedInput(arena.allocator(), path, &tag, "SWAP 2.=3:\n+X\n+Y");
    const prefix = try arena.allocator().alloc(u8, 512);
    @memset(prefix, 'a');
    const expected_preview = try std.mem.concat(arena.allocator(), u8, &.{ "2:", prefix, "…" });
    const too_wide = try arena.allocator().alloc(u8, 513);
    @memset(too_wide, 'a');
    const first = try expectApplyFailure(try patcher.applyText(arena.allocator(), patch_text));
    try std.testing.expect(contains(first.message, "first 2 unseen line(s)"));
    try std.testing.expect(contains(first.message, expected_preview));
    try std.testing.expect(!contains(first.message, too_wide));
    try std.testing.expect(contains(first.message, "3:l3"));
    try std.testing.expect(contains(first.message, "a.ts:2-3"));
    const retry = try expectApplyFailure(try patcher.applyText(arena.allocator(), patch_text));
    try std.testing.expect(contains(retry.message, expected_preview));
    try std.testing.expectEqualStrings(content, memory.get(path).?);
}

test "hashline: patcher.test.ts: absent seen-line provenance allows edit" {
    const content = "l1\nl2\nl3\nl4\nl5\n";
    var memory = fs_mod.InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    try memory.put(path, content);
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record(path, content, null);
    var patcher = patcher_mod.Patcher.init(.{ .fs = memory.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try expectApplySuccess(try patcher.applyText(
        arena.allocator(),
        try taggedInput(arena.allocator(), path, &tag, "SWAP 4.=4:\n+L4"),
    ));
}

test "hashline: patcher.test.ts: tag recovery redirects bare filename to full path" {
    const nested = "pkg/test/file.ts";
    const content = "one\ntwo\nthree\n";
    var memory = fs_mod.InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    try memory.put(nested, content);
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record(nested, content, null);
    var patcher = patcher_mod.Patcher.init(.{ .fs = memory.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try expectApplySuccess(try patcher.applyText(
        arena.allocator(),
        try taggedInput(arena.allocator(), "file.ts", &tag, "SWAP 2.=2:\n+TWO"),
    ));
    try std.testing.expectEqualStrings(nested, result.sections[0].path);
    try std.testing.expectEqualStrings("one\nTWO\nthree\n", memory.get(nested).?);
    try std.testing.expect(contains(result.sections[0].warnings[0], "does not exist"));
    try std.testing.expect(contains(result.sections[0].warnings[0], nested));
}

test "hashline: patcher integration: tag recovery rejects a normalized relative escape" {
    const escaped = "safe/../../outside/file.ts";
    const content = "one\ntwo\nthree\n";
    var memory = fs_mod.InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    try memory.put(escaped, content);
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record(escaped, content, null);
    var patcher = patcher_mod.Patcher.init(.{
        .fs = memory.fs(),
        .snapshot_store = &store,
        .cwd = ".",
    });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const failure = try expectApplyFailure(try patcher.applyText(
        arena.allocator(),
        try taggedInput(arena.allocator(), "file.ts", &tag, "SWAP 2.=2:\n+TWO"),
    ));
    try std.testing.expectEqual(types.FailureKind.not_found, failure.kind);
    try std.testing.expectEqualStrings(content, memory.get(escaped).?);
}

test "hashline: patcher.test.ts: tag recovery declines filename mismatch" {
    const nested = "pkg/test/file.ts";
    const content = "one\ntwo\nthree\n";
    var memory = fs_mod.InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    try memory.put(nested, content);
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record(nested, content, null);
    var patcher = patcher_mod.Patcher.init(.{ .fs = memory.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const failure = try expectApplyFailure(try patcher.applyText(
        arena.allocator(),
        try taggedInput(arena.allocator(), "other.ts", &tag, "SWAP 2.=2:\n+TWO"),
    ));
    try std.testing.expectEqual(types.FailureKind.not_found, failure.kind);
    try std.testing.expectEqualStrings(content, memory.get(nested).?);
}

test "hashline: patcher.test.ts: tag recovery declines unknown retained tag" {
    const nested = "pkg/test/file.ts";
    const content = "one\ntwo\nthree\n";
    var memory = fs_mod.InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    try memory.put(nested, content);
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record(nested, content, null);
    const bogus = if (std.mem.eql(u8, &tag, "FFFF")) "0000" else "FFFF";
    var patcher = patcher_mod.Patcher.init(.{ .fs = memory.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const failure = try expectApplyFailure(try patcher.applyText(
        arena.allocator(),
        try taggedInput(arena.allocator(), "file.ts", bogus, "SWAP 2.=2:\n+TWO"),
    ));
    try std.testing.expectEqual(types.FailureKind.not_found, failure.kind);
}

test "hashline: patcher.test.ts: tag recovery declines ambiguous filename and tag" {
    const content = "one\ntwo\nthree\n";
    var memory = fs_mod.InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    try memory.put("a/file.ts", content);
    try memory.put("b/file.ts", content);
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record("a/file.ts", content, null);
    _ = try store.record("b/file.ts", content, null);
    var patcher = patcher_mod.Patcher.init(.{ .fs = memory.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const failure = try expectApplyFailure(try patcher.applyText(
        arena.allocator(),
        try taggedInput(arena.allocator(), "file.ts", &tag, "SWAP 2.=2:\n+TWO"),
    ));
    try std.testing.expectEqual(types.FailureKind.not_found, failure.kind);
    try std.testing.expectEqualStrings(content, memory.get("a/file.ts").?);
    try std.testing.expectEqualStrings(content, memory.get("b/file.ts").?);
}

test "hashline: patcher.test.ts: filesystem may refuse tag path recovery" {
    const nested = "pkg/test/file.ts";
    const content = "one\ntwo\nthree\n";
    var policy = PolicyFs.init(std.testing.allocator);
    defer policy.deinit();
    policy.allow_recovery = false;
    try policy.memory.put(nested, content);
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record(nested, content, null);
    var patcher = patcher_mod.Patcher.init(.{ .fs = policy.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const failure = try expectApplyFailure(try patcher.applyText(
        arena.allocator(),
        try taggedInput(arena.allocator(), "file.ts", &tag, "SWAP 2.=2:\n+TWO"),
    ));
    try std.testing.expectEqual(types.FailureKind.not_found, failure.kind);
    try std.testing.expectEqualStrings(content, policy.memory.get(nested).?);
}

test "hashline: patcher.test.ts: write gate runs on recovered target" {
    const nested = "pkg/test/file.ts";
    const content = "one\ntwo\nthree\n";
    var policy = PolicyFs.init(std.testing.allocator);
    defer policy.deinit();
    policy.blocked_preflight_path = "file.ts";
    try policy.memory.put(nested, content);
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record(nested, content, null);
    var patcher = patcher_mod.Patcher.init(.{ .fs = policy.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try expectApplySuccess(try patcher.applyText(
        arena.allocator(),
        try taggedInput(arena.allocator(), "file.ts", &tag, "SWAP 2.=2:\n+TWO"),
    ));
    try std.testing.expectEqualStrings(nested, result.sections[0].path);
    try std.testing.expectEqualStrings(nested, policy.last_preflight_path.?);
    try std.testing.expectEqualStrings("one\nTWO\nthree\n", policy.memory.get(nested).?);
}

test "hashline: patcher.test.ts: unrecoverable authored path hits write gate before not found" {
    var policy = PolicyFs.init(std.testing.allocator);
    defer policy.deinit();
    policy.block_all_preflights = true;
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    var patcher = patcher_mod.Patcher.init(.{ .fs = policy.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const failure = try expectApplyFailure(try patcher.applyText(
        arena.allocator(),
        "[file.ts#ABCD]\nSWAP 1.=1:\n+X",
    ));
    try std.testing.expectEqual(types.FailureKind.io, failure.kind);
    try std.testing.expectEqualStrings("WriteGateReadOnly", failure.message);
    try std.testing.expectEqualStrings("file.ts", policy.last_preflight_path.?);
}

// file-ops.test.ts — 5/5

test "hashline: file-ops.test.ts: parses REM and rejects line ops in same section" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try expectParseSuccess(try parser.parsePatch(arena.allocator(), "REM"));
    try std.testing.expect(parsed.file_op.? == .rem);
    const failure = try expectParseFailure(try parser.parsePatch(
        arena.allocator(),
        "SWAP 1.=1:\n+one\nREM",
    ));
    try std.testing.expect(contains(failure.message, "REM"));
    try std.testing.expect(contains(failure.message, "line ops"));
}

test "hashline: file-ops.test.ts: parses MV with normalized destination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const section = try expectSectionSuccess(try input.Patch.parseSingle(
        arena.allocator(),
        "[src/old.ts#AB12]\nMV src/new.ts",
        .{},
    ));
    switch (section.file_op.?) {
        .move => |dest| try std.testing.expectEqualStrings("src/new.ts", dest),
        .rem => return error.ExpectedMove,
    }
}

test "hashline: file-ops.test.ts: deletes tagged file with REM" {
    const source = "one\ntwo\nthree\n";
    var memory = fs_mod.InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    try memory.put("src/old.ts", source);
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record("src/old.ts", source, null);
    var patcher = patcher_mod.Patcher.init(.{ .fs = memory.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try expectApplySuccess(try patcher.applyText(
        arena.allocator(),
        try taggedInput(arena.allocator(), "src/old.ts", &tag, "REM"),
    ));
    try std.testing.expectEqual(patcher_mod.Operation.delete, result.sections[0].op);
    try std.testing.expect(memory.get("src/old.ts") == null);
    try std.testing.expect(store.byHash("src/old.ts", &tag) == null);
}

test "hashline: file-ops.test.ts: moves file without content edits and preserves provenance" {
    const source = "one\ntwo\nthree\n";
    var memory = fs_mod.InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    try memory.put("src/old.ts", source);
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record("src/old.ts", source, &.{ 1, 2 });
    var patcher = patcher_mod.Patcher.init(.{ .fs = memory.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try expectApplySuccess(try patcher.applyText(
        arena.allocator(),
        try taggedInput(arena.allocator(), "src/old.ts", &tag, "MV src/new.ts"),
    ));
    try std.testing.expectEqual(patcher_mod.Operation.update, result.sections[0].op);
    try std.testing.expectEqualStrings("src/new.ts", result.sections[0].move_dest.?);
    try std.testing.expect(memory.get("src/old.ts") == null);
    try std.testing.expectEqualStrings(source, memory.get("src/new.ts").?);
    const moved = store.byHash("src/new.ts", &tag).?;
    try std.testing.expect(moved.hasSeenLine(1));
    try std.testing.expect(moved.hasSeenLine(2));
    try std.testing.expect(store.byHash("src/old.ts", &tag) == null);
}

test "hashline: file-ops.test.ts: applies line edits before moving updated content" {
    const source = "one\ntwo\nthree\n";
    var memory = fs_mod.InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    try memory.put("src/old.ts", source);
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record("src/old.ts", source, null);
    var patcher = patcher_mod.Patcher.init(.{ .fs = memory.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try expectApplySuccess(try patcher.applyText(
        arena.allocator(),
        try taggedInput(arena.allocator(), "src/old.ts", &tag, "SWAP 2.=2:\n+TWO\nMV src/new.ts"),
    ));
    try std.testing.expectEqualStrings("src/new.ts", result.sections[0].move_dest.?);
    try std.testing.expect(memory.get("src/old.ts") == null);
    try std.testing.expectEqualStrings("one\nTWO\nthree\n", memory.get("src/new.ts").?);
    const expected = format.computeFileHash("one\nTWO\nthree\n");
    try std.testing.expectEqualStrings(&expected, &result.sections[0].file_hash);
    try std.testing.expectEqualStrings(&expected, &store.head("src/new.ts").?.hash);
}

// recovery-session-chain.test.ts — 9/9

test "hashline: recovery-session-chain.test.ts: refuses replay when anchor content diverges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const previous = try lines(arena.allocator(), &.{ "L1", "L2", "L3", "L4", "L5", "L6", "L7", "L8", "L9", "L10" });
    const current = try lines(arena.allocator(), &.{ "L1", "L2", "L3", "L4", "L5-CHANGED", "L6", "L7", "L8", "L9", "L10" });
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record("/tmp/recovery.ts", previous, null);
    _ = try store.record("/tmp/recovery.ts", current, null);
    var recovery = recovery_mod.Recovery.init(&store);
    try std.testing.expect((try recovery.tryRecover(arena.allocator(), .{
        .path = "/tmp/recovery.ts",
        .current_text = current,
        .file_hash = &tag,
        .edits = try parsedEdits(arena.allocator(), "SWAP 5.=5:\n+L5-MODEL"),
    })) == null);
}

test "hashline: recovery-session-chain.test.ts: replays when every anchor content is unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const previous = try lines(arena.allocator(), &.{ "L1", "L2", "L3", "L4", "L5", "L6", "L7", "L8", "L9", "L10" });
    const current = try lines(arena.allocator(), &.{ "L1", "L2", "L3", "L4", "L5-CHANGED", "L6", "L7", "L8", "L9", "L10" });
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record("/tmp/recovery.ts", previous, null);
    _ = try store.record("/tmp/recovery.ts", current, null);
    var recovery = recovery_mod.Recovery.init(&store);
    const result = (try recovery.tryRecover(arena.allocator(), .{
        .path = "/tmp/recovery.ts",
        .current_text = current,
        .file_hash = &tag,
        .edits = try parsedEdits(arena.allocator(), "SWAP 3.=3:\n+L3-MODEL"),
    })).?;
    try std.testing.expect(contains(result.text, "L3-MODEL"));
    try std.testing.expect(contains(result.text, "L5-CHANGED"));
    try std.testing.expect(warningPresent(result.warnings, messages.recovery_session_replay_warning));
}

test "hashline: recovery-session-chain.test.ts: remaps stale anchor shifted by insertion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const previous = try lines(arena.allocator(), &.{ "L1", "L2", "L3", "L4", "L5", "L6" });
    const current = try lines(arena.allocator(), &.{ "L1", "L2", "INSERTED", "L3", "L4", "L5", "L6" });
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record("/tmp/recovery.ts", previous, null);
    _ = try store.record("/tmp/recovery.ts", current, null);
    var recovery = recovery_mod.Recovery.init(&store);
    const result = (try recovery.tryRecover(arena.allocator(), .{
        .path = "/tmp/recovery.ts",
        .current_text = current,
        .file_hash = &tag,
        .edits = try parsedEdits(arena.allocator(), "SWAP 5.=5:\n+L5-MODEL"),
    })).?;
    try std.testing.expectEqualStrings("L1\nL2\nINSERTED\nL3\nL4\nL5-MODEL\nL6\n", result.text);
    try std.testing.expect(warningPresent(result.warnings, messages.recovery_line_remap_warning));
}

test "hashline: recovery-session-chain.test.ts: remaps stale anchor shifted by deletion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const previous = try lines(arena.allocator(), &.{ "L1", "L2", "L3", "L4", "L5", "L6" });
    const current = try lines(arena.allocator(), &.{ "L1", "L3", "L4", "L5", "L6" });
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record("/tmp/recovery.ts", previous, null);
    _ = try store.record("/tmp/recovery.ts", current, null);
    var recovery = recovery_mod.Recovery.init(&store);
    const result = (try recovery.tryRecover(arena.allocator(), .{
        .path = "/tmp/recovery.ts",
        .current_text = current,
        .file_hash = &tag,
        .edits = try parsedEdits(arena.allocator(), "SWAP 5.=5:\n+L5-MODEL"),
    })).?;
    try std.testing.expectEqualStrings("L1\nL3\nL4\nL5-MODEL\nL6\n", result.text);
    try std.testing.expect(warningPresent(result.warnings, messages.recovery_line_remap_warning));
}

test "hashline: recovery-session-chain.test.ts: refuses duplicate line remap when context changed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const previous = try lines(arena.allocator(), &.{ "start", "DUP", "mid", "DUP", "tail" });
    const current = try lines(arena.allocator(), &.{ "start", "mid", "DUP", "CHANGED", "tail" });
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record("/tmp/recovery.ts", previous, null);
    _ = try store.record("/tmp/recovery.ts", current, null);
    var recovery = recovery_mod.Recovery.init(&store);
    try std.testing.expect((try recovery.tryRecover(arena.allocator(), .{
        .path = "/tmp/recovery.ts",
        .current_text = current,
        .file_hash = &tag,
        .edits = try parsedEdits(arena.allocator(), "SWAP 4.=4:\n+MODEL"),
    })) == null);
}

test "hashline: recovery-session-chain.test.ts: refuses unique line remap when following context changed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const previous = try lines(arena.allocator(), &.{ "L1", "L2", "L3", "L4", "T", "L6" });
    const current = try lines(arena.allocator(), &.{ "X", "L1", "L2", "L3", "L4", "T", "T_CHANGED", "L6" });
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record("/tmp/recovery.ts", previous, null);
    _ = try store.record("/tmp/recovery.ts", current, null);
    var recovery = recovery_mod.Recovery.init(&store);
    try std.testing.expect((try recovery.tryRecover(arena.allocator(), .{
        .path = "/tmp/recovery.ts",
        .current_text = current,
        .file_hash = &tag,
        .edits = try parsedEdits(arena.allocator(), "SWAP 5.=5:\n+MODEL"),
    })) == null);
}

test "hashline: recovery-session-chain.test.ts: duplicate range remaps when context matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const previous = try lines(arena.allocator(), &.{ "alpha", "DUP", "beta", "DUP", "omega" });
    const current = try lines(arena.allocator(), &.{ "alpha", "INSERTED", "DUP", "beta", "DUP", "omega" });
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record("/tmp/recovery.ts", previous, null);
    _ = try store.record("/tmp/recovery.ts", current, null);
    var recovery = recovery_mod.Recovery.init(&store);
    const result = (try recovery.tryRecover(arena.allocator(), .{
        .path = "/tmp/recovery.ts",
        .current_text = current,
        .file_hash = &tag,
        .edits = try parsedEdits(arena.allocator(), "SWAP 3.=4:\n+B-MODEL\n+MODEL"),
    })).?;
    try std.testing.expectEqualStrings("alpha\nINSERTED\nDUP\nB-MODEL\nMODEL\nomega\n", result.text);
    try std.testing.expect(warningPresent(result.warnings, messages.recovery_line_remap_warning));
}

test "hashline: recovery-session-chain.test.ts: colliding tag uses most recently retained text" {
    const older = "line one 263\nline two 4471\n";
    const newer = "line one 410\nline two 6970\n";
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record("/tmp/recovery.ts", older, null);
    _ = try store.record("/tmp/recovery.ts", newer, null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recovery = recovery_mod.Recovery.init(&store);
    const result = (try recovery.tryRecover(arena.allocator(), .{
        .path = "/tmp/recovery.ts",
        .current_text = newer ++ "drifted trailer\n",
        .file_hash = &tag,
        .edits = try parsedEdits(arena.allocator(), "SWAP 2.=2:\n+model payload"),
    })).?;
    try std.testing.expectEqualStrings("line one 410\nmodel payload\ndrifted trailer\n", result.text);
}

test "hashline: recovery-session-chain.test.ts: single retained text with tag still recovers" {
    const previous = "line one 263\nline two 4471\n";
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record("/tmp/recovery.ts", previous, null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recovery = recovery_mod.Recovery.init(&store);
    const result = (try recovery.tryRecover(arena.allocator(), .{
        .path = "/tmp/recovery.ts",
        .current_text = previous ++ "drifted trailer\n",
        .file_hash = &tag,
        .edits = try parsedEdits(arena.allocator(), "SWAP 2.=2:\n+model payload"),
    })).?;
    try std.testing.expectEqualStrings("line one 263\nmodel payload\ndrifted trailer\n", result.text);
}

// Relevant core-contracts.test.ts Patcher/preflight/recovery cases.

test "hashline: core-contracts.test.ts: preflights every section before committing batch" {
    var policy = PolicyFs.init(std.testing.allocator);
    defer policy.deinit();
    try policy.memory.put("a.ts", "aaa\n");
    try policy.memory.put("b.ts", "bbb\n");
    policy.blocked_preflight_path = "b.ts";
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const a_tag = try store.record("a.ts", "aaa\n", null);
    const b_tag = try store.record("b.ts", "bbb\n", null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const patch_text = try std.fmt.allocPrint(
        arena.allocator(),
        "[a.ts#{s}]\nSWAP 1.=1:\n+AAA\n[b.ts#{s}]\nSWAP 1.=1:\n+BBB",
        .{ &a_tag, &b_tag },
    );
    var patcher = patcher_mod.Patcher.init(.{ .fs = policy.fs(), .snapshot_store = &store });
    const failure = try expectApplyFailure(try patcher.applyText(arena.allocator(), patch_text));
    try std.testing.expectEqualStrings("WriteGateReadOnly", failure.message);
    try std.testing.expectEqualStrings("aaa\n", policy.memory.get("a.ts").?);
    try std.testing.expectEqualStrings("bbb\n", policy.memory.get("b.ts").?);
}

test "hashline: core-contracts.test.ts: recovery returns null when no strategy can land" {
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const previous = "alpha\nbeta\ngamma\ndelta\nepsilon";
    const tag = try store.record("/tmp/recovery.ts", previous, null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recovery = recovery_mod.Recovery.init(&store);
    try std.testing.expect((try recovery.tryRecover(arena.allocator(), .{
        .path = "/tmp/recovery.ts",
        .current_text = "totally\nunrelated\ncontent\nhere\nnow\n",
        .file_hash = &tag,
        .edits = try parsedEdits(arena.allocator(), "SWAP 2.=2:\n+BETA-MODEL"),
    })) == null);
}

test "hashline: core-contracts.test.ts: recovers from older in-session snapshot after file advanced" {
    const previous = "L1\nL2\nL3\nL4\nL5\nL6\nL7\nL8\nL9\nL10\n";
    const advanced = "L1\nL2-EDITED\nL3\nL4\nL5\nL6\nL7\nL8\nL9\nL10\n";
    const current = advanced ++ "TRAILER\n";
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record("/tmp/recovery.ts", previous, null);
    _ = try store.record("/tmp/recovery.ts", advanced, null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recovery = recovery_mod.Recovery.init(&store);
    const result = (try recovery.tryRecover(arena.allocator(), .{
        .path = "/tmp/recovery.ts",
        .current_text = current,
        .file_hash = &tag,
        .edits = try parsedEdits(arena.allocator(), "SWAP 10.=10:\n+L10-EDITED"),
    })).?;
    try std.testing.expect(contains(result.text, "L10-EDITED"));
    try std.testing.expect(contains(result.text, "L2-EDITED"));
    try std.testing.expect(contains(result.text, "TRAILER"));
}

test "hashline: patcher integration: duplicate canonical paths are rejected before commit" {
    var policy = PolicyFs.init(std.testing.allocator);
    defer policy.deinit();
    try policy.memory.put("same.ts", "one\n");
    try policy.memory.put("a/../same.ts", "two\n");
    const first_tag = format.computeFileHash("one\n");
    const second_tag = format.computeFileHash("two\n");
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    var patcher = patcher_mod.Patcher.init(.{ .fs = policy.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const patch_text = try std.fmt.allocPrint(
        arena.allocator(),
        "[same.ts#{s}]\nSWAP 1.=1:\n+ONE\n[a/../same.ts#{s}]\nSWAP 1.=1:\n+TWO",
        .{ &first_tag, &second_tag },
    );
    const failure = try expectApplyFailure(try patcher.applyText(arena.allocator(), patch_text));
    try std.testing.expectEqualStrings(
        "Multiple hashline sections resolve to the same file (same.ts and a/../same.ts). Merge their ops under one header before applying.",
        failure.message,
    );
    try std.testing.expectEqualStrings("one\n", policy.memory.get("same.ts").?);
    try std.testing.expectEqualStrings("two\n", policy.memory.get("a/../same.ts").?);
}

test "hashline: patcher integration: aggregate commit failure lists applied and unapplied files" {
    var policy = PolicyFs.init(std.testing.allocator);
    defer policy.deinit();
    try policy.memory.put("a.ts", "a\n");
    try policy.memory.put("b.ts", "b\n");
    try policy.memory.put("c.ts", "c\n");
    policy.failed_write_path = "b.ts";
    policy.dynamic_error_message = "disk full at b.ts";
    const a_tag = format.computeFileHash("a\n");
    const b_tag = format.computeFileHash("b\n");
    const c_tag = format.computeFileHash("c\n");
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    var patcher = patcher_mod.Patcher.init(.{ .fs = policy.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const patch_text = try std.fmt.allocPrint(
        arena.allocator(),
        "[a.ts#{s}]\nSWAP 1.=1:\n+A\n[b.ts#{s}]\nSWAP 1.=1:\n+B\n[c.ts#{s}]\nSWAP 1.=1:\n+C",
        .{ &a_tag, &b_tag, &c_tag },
    );
    const failure = try expectApplyFailure(try patcher.applyText(arena.allocator(), patch_text));
    try std.testing.expectEqual(types.FailureKind.io, failure.kind);
    try std.testing.expectEqualStrings(
        "Error editing b.ts: disk full at b.ts\n" ++
            "Files already applied: a.ts.\n" ++
            "Files NOT applied: c.ts; re-read the affected files and re-issue only the failed and unapplied files.",
        failure.message,
    );
    try std.testing.expectEqualStrings("A\n", policy.memory.get("a.ts").?);
    try std.testing.expectEqualStrings("b\n", policy.memory.get("b.ts").?);
    try std.testing.expectEqualStrings("c\n", policy.memory.get("c.ts").?);
}
