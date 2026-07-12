const std = @import("std");
const apply_mod = @import("apply.zig");
const block = @import("block.zig");
const format = @import("format.zig");
const fs_mod = @import("fs.zig");
const input = @import("input.zig");
const parser = @import("parser.zig");
const patcher_mod = @import("patcher.zig");
const snapshots = @import("snapshots.zig");
const types = @import("types.zig");

const path = "x.ts";
const block_text = "function x() {\n  if (y) {\n  }\n}\n";

fn stubResolver(request: types.BlockResolverRequest) ?types.BlockSpan {
    return .{ .start = request.line, .end = request.line + 1 };
}

fn nullResolver(_: types.BlockResolverRequest) ?types.BlockSpan {
    return null;
}

fn singleLineResolver(request: types.BlockResolverRequest) ?types.BlockSpan {
    return .{ .start = request.line, .end = request.line };
}

fn closerOnlyResolver(request: types.BlockResolverRequest) ?types.BlockSpan {
    return if (request.line == 2) .{ .start = 2, .end = 3 } else null;
}

fn parseOrFail(allocator: std.mem.Allocator, diff: []const u8) !parser.ParseResult {
    const outcome = try parser.parsePatch(allocator, diff);
    return switch (outcome) {
        .success => |result| result,
        .failure => |failure| {
            std.debug.print("unexpected parse failure: {s}\n", .{failure.message});
            return error.UnexpectedParseFailure;
        },
    };
}

fn parseSectionOrFail(allocator: std.mem.Allocator, patch_text: []const u8) !input.PatchSection {
    const outcome = try input.Patch.parseSingle(allocator, patch_text, .{});
    return switch (outcome) {
        .success => |section| section,
        .failure => |failure| {
            std.debug.print("unexpected section parse failure: {s}\n", .{failure.message});
            return error.UnexpectedSectionParseFailure;
        },
    };
}

fn resolveOrFail(
    allocator: std.mem.Allocator,
    edits: []const types.Edit,
    text: []const u8,
    resolver: ?types.BlockResolver,
    options: block.ResolveOptions,
) !block.ResolveResult {
    const outcome = try block.resolveBlockEdits(allocator, edits, text, path, resolver, options);
    return switch (outcome) {
        .success => |result| result,
        .failure => |failure| {
            std.debug.print("unexpected resolve failure: {s}\n", .{failure.message});
            return error.UnexpectedResolveFailure;
        },
    };
}

fn applyOrFail(allocator: std.mem.Allocator, text: []const u8, edits: []const types.Edit) !types.ApplyResult {
    const outcome = try apply_mod.applyEdits(allocator, text, edits);
    return switch (outcome) {
        .success => |result| result,
        .failure => |failure| {
            std.debug.print("unexpected apply failure: {s}\n", .{failure.message});
            return error.UnexpectedApplyFailure;
        },
    };
}

fn fullApply(
    allocator: std.mem.Allocator,
    text: []const u8,
    diff: []const u8,
    resolver: ?types.BlockResolver,
) !types.ApplyResult {
    const parsed = try parseOrFail(allocator, diff);
    const resolved = try resolveOrFail(allocator, parsed.edits, text, resolver, .{});
    var applied = try applyOrFail(allocator, text, resolved.edits);
    if (parsed.warnings.len != 0 or resolved.warnings.len != 0) {
        var warnings: std.ArrayList([]const u8) = .empty;
        try warnings.appendSlice(allocator, parsed.warnings);
        try warnings.appendSlice(allocator, resolved.warnings);
        try warnings.appendSlice(allocator, applied.warnings);
        applied.warnings = try warnings.toOwnedSlice(allocator);
    }
    return applied;
}

fn partialApply(
    allocator: std.mem.Allocator,
    text: []const u8,
    diff: []const u8,
    resolver: ?types.BlockResolver,
) !types.ApplyResult {
    const parsed_outcome = try parser.parsePatchStreaming(allocator, diff);
    const parsed = switch (parsed_outcome) {
        .success => |result| result,
        .failure => return error.UnexpectedPartialParseFailure,
    };
    const resolved = try resolveOrFail(allocator, parsed.edits, text, resolver, .{ .on_unresolved = .drop });
    return applyOrFail(allocator, text, resolved.edits);
}

fn expectResolveFailure(
    allocator: std.mem.Allocator,
    edits: []const types.Edit,
    text: []const u8,
    resolver: ?types.BlockResolver,
    options: block.ResolveOptions,
) !types.Failure {
    const outcome = try block.resolveBlockEdits(allocator, edits, text, path, resolver, options);
    return switch (outcome) {
        .failure => |failure| failure,
        .success => error.ExpectedResolveFailure,
    };
}

fn expectPatcherSuccess(outcome: types.Outcome(patcher_mod.ApplyResult)) !patcher_mod.ApplyResult {
    return switch (outcome) {
        .success => |result| result,
        .failure => |failure| {
            std.debug.print("unexpected patcher failure: {s}\n", .{failure.message});
            return error.UnexpectedPatcherFailure;
        },
    };
}

fn warningContains(warnings: []const []const u8, needle: []const u8) bool {
    for (warnings) |warning| if (std.mem.indexOf(u8, warning, needle) != null) return true;
    return false;
}

fn expectConcreteEditsEqual(left: []const types.Edit, right: []const types.Edit) !void {
    try std.testing.expectEqual(left.len, right.len);
    for (left, right) |a, b| switch (a) {
        .insert => |a_insert| switch (b) {
            .insert => |b_insert| {
                try std.testing.expectEqual(a_insert.cursor, b_insert.cursor);
                try std.testing.expectEqualStrings(a_insert.text, b_insert.text);
                try std.testing.expectEqual(a_insert.mode, b_insert.mode);
            },
            else => return error.EditKindMismatch,
        },
        .delete => |a_delete| switch (b) {
            .delete => |b_delete| try std.testing.expectEqual(a_delete.anchor.line, b_delete.anchor.line),
            else => return error.EditKindMismatch,
        },
        .block => return error.UnexpectedDeferredBlock,
    };
}

test "hashline: block parses `SWAP.BLK N:` into a single deferred block edit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parseOrFail(arena.allocator(), "SWAP.BLK 2:\n+A\n+B");
    try std.testing.expectEqual(@as(usize, 1), parsed.edits.len);
    const edit = parsed.edits[0].block;
    try std.testing.expectEqual(@as(usize, 2), edit.anchor.line);
    try std.testing.expectEqual(@as(usize, 2), edit.payloads.len);
    try std.testing.expectEqualStrings("A", edit.payloads[0]);
    try std.testing.expectEqualStrings("B", edit.payloads[1]);
}

test "hashline: block still parses a literal `SWAP N.=M:` range (distinct from `SWAP.BLK`)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parseOrFail(arena.allocator(), "SWAP 2.=3:\n+A");
    var saw_delete = false;
    for (parsed.edits) |edit| switch (edit) {
        .block => return error.UnexpectedBlockEdit,
        .delete => saw_delete = true,
        else => {},
    };
    try std.testing.expect(saw_delete);
}

test "hashline: block rejects a `SWAP.BLK N:` hunk with no body row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const outcome = try parser.parsePatch(arena.allocator(), "SWAP.BLK 2:");
    try std.testing.expect(std.mem.indexOf(u8, outcome.failure.message, "`SWAP.BLK N:` needs at least one") != null);
}

test "hashline: block expands a block edit exactly like the equivalent `SWAP start.=end:`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const block_edits = (try parseOrFail(allocator, "SWAP.BLK 2:\n+A\n+B")).edits;
    const resolved = try resolveOrFail(
        allocator,
        block_edits,
        "ignored",
        types.BlockResolver.fromFunction(stubResolver),
        .{},
    );
    const concrete = (try parseOrFail(allocator, "SWAP 2.=3:\n+A\n+B")).edits;
    try std.testing.expect(!block.hasBlockEdit(resolved.edits));
    try expectConcreteEditsEqual(resolved.edits, concrete);
}

test "hashline: block returns the input untouched when there are no block edits (fast path)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const edits = (try parseOrFail(arena.allocator(), "SWAP 1.=1:\n+X")).edits;
    const resolved = try resolveOrFail(
        arena.allocator(),
        edits,
        "ignored",
        types.BlockResolver.fromFunction(stubResolver),
        .{},
    );
    try std.testing.expectEqual(@intFromPtr(edits.ptr), @intFromPtr(resolved.edits.ptr));
}

test "hashline: block throws (default) when no resolver is wired" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const edits = (try parseOrFail(arena.allocator(), "SWAP.BLK 2:\n+X")).edits;
    const failure = try expectResolveFailure(arena.allocator(), edits, "ignored", null, .{});
    try std.testing.expect(std.mem.indexOf(u8, failure.message, "not available here") != null);
}

test "hashline: block drops an unresolvable block edit in `drop` mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const edits = (try parseOrFail(arena.allocator(), "SWAP.BLK 2:\n+X")).edits;
    const resolved = try resolveOrFail(
        arena.allocator(),
        edits,
        "ignored",
        types.BlockResolver.fromFunction(nullResolver),
        .{ .on_unresolved = .drop },
    );
    try std.testing.expectEqual(@as(usize, 0), resolved.edits.len);
}

test "hashline: block throws a block-unresolved error in `throw` mode when the resolver returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const edits = (try parseOrFail(arena.allocator(), "SWAP.BLK 7:\n+X")).edits;
    const failure = try expectResolveFailure(
        arena.allocator(),
        edits,
        "ignored",
        types.BlockResolver.fromFunction(nullResolver),
        .{},
    );
    try std.testing.expect(std.mem.indexOf(u8, failure.message, "could not resolve a syntactic block beginning on line 7") != null);
}

test "hashline: block includes a nearby-context preview in the block-unresolved error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const edits = (try parseOrFail(arena.allocator(), "SWAP.BLK 3:\n+X")).edits;
    const failure = try expectResolveFailure(
        arena.allocator(),
        edits,
        "alpha\nbravo\ncharlie\ndelta\necho\nfoxtrot",
        types.BlockResolver.fromFunction(nullResolver),
        .{},
    );
    try std.testing.expect(std.mem.indexOf(u8, failure.message, " 1:alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, failure.message, "*3:charlie") != null);
    try std.testing.expect(std.mem.indexOf(u8, failure.message, " 5:echo") != null);
    try std.testing.expect(std.mem.indexOf(u8, failure.message, "foxtrot") == null);
}

test "hashline: block omits the context preview when the anchor line is out of range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const edits = (try parseOrFail(arena.allocator(), "SWAP.BLK 9:\n+X")).edits;
    const failure = try expectResolveFailure(
        arena.allocator(),
        edits,
        "only\ntwo",
        types.BlockResolver.fromFunction(nullResolver),
        .{},
    );
    try std.testing.expect(std.mem.indexOf(u8, failure.message, "beginning on line 9") != null);
    try std.testing.expect(std.mem.indexOf(u8, failure.message, "\n\n") == null);
}

test "hashline: block fires onResolved with the resolved span for replace and delete blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const replace = try resolveOrFail(
        allocator,
        (try parseOrFail(allocator, "SWAP.BLK 2:\n+A\n+B")).edits,
        "ignored",
        types.BlockResolver.fromFunction(stubResolver),
        .{},
    );
    const deletion = try resolveOrFail(
        allocator,
        (try parseOrFail(allocator, "DEL.BLK 5")).edits,
        "ignored",
        types.BlockResolver.fromFunction(stubResolver),
        .{},
    );
    try std.testing.expectEqual(types.BlockResolution{ .anchor_line = 2, .start = 2, .end = 3, .op = .replace }, replace.resolutions[0]);
    try std.testing.expectEqual(types.BlockResolution{ .anchor_line = 5, .start = 5, .end = 6, .op = .delete }, deletion.resolutions[0]);
}

test "hashline: block does not fire onResolved for a dropped unresolvable block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const resolved = try resolveOrFail(
        allocator,
        (try parseOrFail(allocator, "SWAP.BLK 2:\n+X")).edits,
        "ignored",
        types.BlockResolver.fromFunction(nullResolver),
        .{ .on_unresolved = .drop },
    );
    try std.testing.expectEqual(@as(usize, 0), resolved.resolutions.len);
}

test "hashline: block rejects a `SWAP.BLK` that resolves to a single line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const failure = try expectResolveFailure(
        allocator,
        (try parseOrFail(allocator, "SWAP.BLK 2:\n+X")).edits,
        "a\nb\nc",
        types.BlockResolver.fromFunction(singleLineResolver),
        .{},
    );
    try std.testing.expect(std.mem.indexOf(u8, failure.message, "resolved a single-line block") != null);
}

test "hashline: block rejects an `INS.BLK.POST` that resolves to a single line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const failure = try expectResolveFailure(
        allocator,
        (try parseOrFail(allocator, "INS.BLK.POST 2:\n+X")).edits,
        "a\nb\nc",
        types.BlockResolver.fromFunction(singleLineResolver),
        .{},
    );
    try std.testing.expect(std.mem.indexOf(u8, failure.message, "single-line block") != null);
}

test "hashline: block drops a single-line block resolution on the lenient preview path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const resolved = try resolveOrFail(
        allocator,
        (try parseOrFail(allocator, "SWAP.BLK 2:\n+X")).edits,
        "a\nb\nc",
        types.BlockResolver.fromFunction(singleLineResolver),
        .{ .on_unresolved = .drop },
    );
    try std.testing.expectEqual(@as(usize, 0), resolved.edits.len);
}

test "hashline: block applyTo resolves a block edit and matches the equivalent `replace`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const block_result = try fullApply(allocator, block_text, "SWAP.BLK 2:\n+  if (y || z) {\n+  }", types.BlockResolver.fromFunction(stubResolver));
    const replace_result = try fullApply(allocator, block_text, "SWAP 2.=3:\n+  if (y || z) {\n+  }", null);
    try std.testing.expectEqualStrings("function x() {\n  if (y || z) {\n  }\n}\n", block_result.text);
    try std.testing.expectEqualStrings(replace_result.text, block_result.text);
}

test "hashline: block applyTo throws when a block edit has no resolver" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parsed = try parseOrFail(allocator, "SWAP.BLK 2:\n+X");
    const failure = try expectResolveFailure(allocator, parsed.edits, block_text, null, .{});
    try std.testing.expect(std.mem.indexOf(u8, failure.message, "no block resolver configured") != null);
}

test "hashline: block applyPartialTo drops an unresolvable block edit instead of throwing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try partialApply(arena.allocator(), block_text, "SWAP.BLK 2:\n+X", null);
    try std.testing.expectEqualStrings(block_text, result.text);
}

test "hashline: block applies a block edit on the hash-match path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var memory = fs_mod.InMemoryFs.init(allocator);
    defer memory.deinit();
    try memory.put(path, block_text);
    var store = snapshots.SnapshotStore.init(allocator, .{});
    defer store.deinit();
    const tag = try store.record(path, block_text, null);
    var patcher = patcher_mod.Patcher.init(.{
        .fs = memory.fs(),
        .snapshot_store = &store,
        .block_resolver = types.BlockResolver.fromFunction(stubResolver),
    });
    const patch_text = try std.fmt.allocPrint(allocator, "[{s}#{s}]\nSWAP.BLK 2:\n+  if (y || z) {{\n+  }}", .{ path, tag });
    const result = try expectPatcherSuccess(try patcher.applyText(allocator, patch_text));
    try std.testing.expectEqual(patcher_mod.Operation.update, result.sections[0].op);
    try std.testing.expectEqualStrings("function x() {\n  if (y || z) {\n  }\n}\n", memory.get(path).?);
}

test "hashline: block surfaces the resolved span on the section result (hash-match path)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var memory = fs_mod.InMemoryFs.init(allocator);
    defer memory.deinit();
    try memory.put(path, block_text);
    var store = snapshots.SnapshotStore.init(allocator, .{});
    defer store.deinit();
    const tag = try store.record(path, block_text, null);
    var patcher = patcher_mod.Patcher.init(.{
        .fs = memory.fs(),
        .snapshot_store = &store,
        .block_resolver = types.BlockResolver.fromFunction(stubResolver),
    });
    const patch_text = try std.fmt.allocPrint(allocator, "[{s}#{s}]\nSWAP.BLK 2:\n+  if (y || z) {{\n+  }}", .{ path, tag });
    const result = try expectPatcherSuccess(try patcher.applyText(allocator, patch_text));
    try std.testing.expectEqual(@as(usize, 1), result.sections[0].block_resolutions.len);
    try std.testing.expectEqual(
        types.BlockResolution{ .anchor_line = 2, .start = 2, .end = 3, .op = .replace },
        result.sections[0].block_resolutions[0],
    );
}

test "hashline: block resolves against the tagged snapshot and recovers onto drifted content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const snapshot_text = "line0\nline1\nline2\nline3\nline4\n";
    const live_text = "line0\nline1\nline2\nline3\nline4\nline5\n";
    var memory = fs_mod.InMemoryFs.init(allocator);
    defer memory.deinit();
    try memory.put(path, live_text);
    var store = snapshots.SnapshotStore.init(allocator, .{});
    defer store.deinit();
    const tag = try store.record(path, snapshot_text, null);
    var patcher = patcher_mod.Patcher.init(.{
        .fs = memory.fs(),
        .snapshot_store = &store,
        .block_resolver = types.BlockResolver.fromFunction(stubResolver),
    });
    const patch_text = try std.fmt.allocPrint(allocator, "[{s}#{s}]\nSWAP.BLK 2:\n+NEW", .{ path, tag });
    const result = try expectPatcherSuccess(try patcher.applyText(allocator, patch_text));
    try std.testing.expectEqual(patcher_mod.Operation.update, result.sections[0].op);
    try std.testing.expectEqualStrings("line0\nNEW\nline3\nline4\nline5\n", memory.get(path).?);
    try std.testing.expect(warningContains(result.sections[0].warnings, "Recovered"));
    try std.testing.expectEqual(@as(usize, 0), result.sections[0].block_resolutions.len);
}

test "hashline: block rejects a block edit whose tag was never recorded for this path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const live_text = "line0\nline1\nline2\n";
    var memory = fs_mod.InMemoryFs.init(allocator);
    defer memory.deinit();
    try memory.put(path, live_text);
    var store = snapshots.SnapshotStore.init(allocator, .{});
    defer store.deinit();
    var patcher = patcher_mod.Patcher.init(.{
        .fs = memory.fs(),
        .snapshot_store = &store,
        .block_resolver = types.BlockResolver.fromFunction(stubResolver),
    });
    const live = format.computeFileHash(live_text);
    const bogus = if (std.mem.eql(u8, &live, "FFFF")) "0000" else "FFFF";
    const patch_text = try std.fmt.allocPrint(allocator, "[{s}#{s}]\nSWAP.BLK 2:\n+NEW", .{ path, bogus });
    const outcome = try patcher.applyText(allocator, patch_text);
    try std.testing.expectEqual(types.FailureKind.mismatch, outcome.failure.kind);
    try std.testing.expectEqualStrings(live_text, memory.get(path).?);
}

test "hashline: block throws a block-unresolved error when the resolver returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var memory = fs_mod.InMemoryFs.init(allocator);
    defer memory.deinit();
    try memory.put(path, block_text);
    var store = snapshots.SnapshotStore.init(allocator, .{});
    defer store.deinit();
    const tag = try store.record(path, block_text, null);
    var patcher = patcher_mod.Patcher.init(.{
        .fs = memory.fs(),
        .snapshot_store = &store,
        .block_resolver = types.BlockResolver.fromFunction(nullResolver),
    });
    const patch_text = try std.fmt.allocPrint(allocator, "[{s}#{s}]\nSWAP.BLK 2:\n+X", .{ path, tag });
    const outcome = try patcher.applyText(allocator, patch_text);
    try std.testing.expect(std.mem.indexOf(u8, outcome.failure.message, "could not resolve a syntactic block") != null);
    try std.testing.expectEqualStrings(block_text, memory.get(path).?);
}

test "hashline: block parses `DEL.BLK N` into a block edit with no payloads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parseOrFail(arena.allocator(), "DEL.BLK 2");
    try std.testing.expectEqual(@as(usize, 1), parsed.edits.len);
    const edit = parsed.edits[0].block;
    try std.testing.expectEqual(@as(usize, 2), edit.anchor.line);
    try std.testing.expectEqual(@as(usize, 0), edit.payloads.len);
}

test "hashline: block rejects body rows under `DEL.BLK N`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const outcome = try parser.parsePatch(arena.allocator(), "DEL.BLK 2\n+X");
    try std.testing.expect(std.mem.indexOf(u8, outcome.failure.message, "`DEL.BLK N` does not take body rows") != null);
}

test "hashline: block resolveBlockEdits expands a delete-block edit into pure deletes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const resolved = try resolveOrFail(
        allocator,
        (try parseOrFail(allocator, "DEL.BLK 2")).edits,
        "ignored",
        types.BlockResolver.fromFunction(stubResolver),
        .{},
    );
    try std.testing.expectEqual(@as(usize, 2), resolved.edits.len);
    try std.testing.expectEqual(@as(usize, 2), resolved.edits[0].delete.anchor.line);
    try std.testing.expectEqual(@as(usize, 3), resolved.edits[1].delete.anchor.line);
}

test "hashline: block applyTo deletes the resolved block span" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try fullApply(
        arena.allocator(),
        block_text,
        "DEL.BLK 2",
        types.BlockResolver.fromFunction(stubResolver),
    );
    try std.testing.expectEqualStrings("function x() {\n}\n", result.text);
}

test "hashline: block applyPartialTo drops an unresolvable delete-block edit instead of throwing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try partialApply(arena.allocator(), block_text, "DEL.BLK 2", null);
    try std.testing.expectEqualStrings(block_text, result.text);
}

test "hashline: block Patcher applies a delete-block edit on the hash-match path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var memory = fs_mod.InMemoryFs.init(allocator);
    defer memory.deinit();
    try memory.put(path, block_text);
    var store = snapshots.SnapshotStore.init(allocator, .{});
    defer store.deinit();
    const tag = try store.record(path, block_text, null);
    var patcher = patcher_mod.Patcher.init(.{
        .fs = memory.fs(),
        .snapshot_store = &store,
        .block_resolver = types.BlockResolver.fromFunction(stubResolver),
    });
    const patch_text = try std.fmt.allocPrint(allocator, "[{s}#{s}]\nDEL.BLK 2", .{ path, tag });
    const result = try expectPatcherSuccess(try patcher.applyText(allocator, patch_text));
    try std.testing.expectEqual(patcher_mod.Operation.update, result.sections[0].op);
    try std.testing.expectEqualStrings("function x() {\n}\n", memory.get(path).?);
}

test "hashline: block parses `INS.BLK.POST N:` into a deferred block edit with insert mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parseOrFail(arena.allocator(), "INS.BLK.POST 2:\n+A\n+B");
    try std.testing.expectEqual(@as(usize, 1), parsed.edits.len);
    const edit = parsed.edits[0].block;
    try std.testing.expectEqual(@as(usize, 2), edit.anchor.line);
    try std.testing.expectEqual(@as(usize, 2), edit.payloads.len);
    try std.testing.expectEqual(types.BlockMode.insert_after, edit.mode.?);
}

test "hashline: block still parses a literal `INS.POST N:` anchor (distinct from `INS.BLK.POST`)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parseOrFail(arena.allocator(), "INS.POST 2:\n+A");
    try std.testing.expect(!block.hasBlockEdit(parsed.edits));
}

test "hashline: block rejects an `INS.BLK.POST N:` hunk with no body row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const outcome = try parser.parsePatch(arena.allocator(), "INS.BLK.POST 2:");
    try std.testing.expect(std.mem.indexOf(u8, outcome.failure.message, "`INS` needs at least one") != null);
}

test "hashline: block resolveBlockEdits expands to the equivalent `insert after end:` lowering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const block_edits = (try parseOrFail(allocator, "INS.BLK.POST 2:\n+A\n+B")).edits;
    const resolved = try resolveOrFail(
        allocator,
        block_edits,
        "ignored",
        types.BlockResolver.fromFunction(stubResolver),
        .{},
    );
    const concrete = (try parseOrFail(allocator, "INS.POST 3:\n+A\n+B")).edits;
    try std.testing.expect(!block.hasBlockEdit(resolved.edits));
    try expectConcreteEditsEqual(resolved.edits, concrete);
}

test "hashline: block fires onResolved with op insert_after" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const resolved = try resolveOrFail(
        allocator,
        (try parseOrFail(allocator, "INS.BLK.POST 2:\n+A")).edits,
        "ignored",
        types.BlockResolver.fromFunction(stubResolver),
        .{},
    );
    try std.testing.expectEqual(@as(usize, 1), resolved.resolutions.len);
    try std.testing.expectEqual(
        types.BlockResolution{ .anchor_line = 2, .start = 2, .end = 3, .op = .insert_after },
        resolved.resolutions[0],
    );
}

test "hashline: block lowers an unresolvable anchor to plain `INS.POST N:` with a warning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const resolved = try resolveOrFail(
        allocator,
        (try parseOrFail(allocator, "INS.BLK.POST 7:\n+X")).edits,
        "ignored",
        types.BlockResolver.fromFunction(nullResolver),
        .{},
    );
    const concrete = (try parseOrFail(allocator, "INS.POST 7:\n+X")).edits;
    try expectConcreteEditsEqual(resolved.edits, concrete);
    try std.testing.expectEqual(@as(usize, 1), resolved.warnings.len);
    try std.testing.expect(std.mem.indexOf(u8, resolved.warnings[0], "applied as plain `INS.POST 7:`") != null);
}

test "hashline: block lowers `INS.BLK.POST` even when no resolver is wired" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const resolved = try resolveOrFail(
        allocator,
        (try parseOrFail(allocator, "INS.BLK.POST 2:\n+X")).edits,
        "ignored",
        null,
        .{},
    );
    const concrete = (try parseOrFail(allocator, "INS.POST 2:\n+X")).edits;
    try expectConcreteEditsEqual(resolved.edits, concrete);
    try std.testing.expectEqual(@as(usize, 1), resolved.warnings.len);
}

test "hashline: block lowers a closing-delimiter anchor to plain `INS.POST N:` with a warning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try fullApply(
        arena.allocator(),
        block_text,
        "INS.BLK.POST 3:\n+  done();",
        types.BlockResolver.fromFunction(closerOnlyResolver),
    );
    try std.testing.expectEqualStrings("function x() {\n  if (y) {\n  }\n  done();\n}\n", result.text);
    try std.testing.expect(warningContains(result.warnings, "applied as plain `INS.POST 3:`"));
}

test "hashline: block lowers an unresolvable blank-line anchor to plain `INS.POST N:` instead of failing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try fullApply(
        arena.allocator(),
        "### Changed\n\n- old entry\n",
        "INS.BLK.POST 2:\n+- new entry",
        types.BlockResolver.fromFunction(nullResolver),
    );
    try std.testing.expectEqualStrings("### Changed\n\n- new entry\n- old entry\n", result.text);
    try std.testing.expect(warningContains(result.warnings, "could not resolve a syntactic block"));
    try std.testing.expect(warningContains(result.warnings, "applied as plain `INS.POST 2:`"));
}

test "hashline: block Patcher surfaces the closer-anchor lowering warning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var memory = fs_mod.InMemoryFs.init(allocator);
    defer memory.deinit();
    try memory.put(path, block_text);
    var store = snapshots.SnapshotStore.init(allocator, .{});
    defer store.deinit();
    const tag = try store.record(path, block_text, null);
    var patcher = patcher_mod.Patcher.init(.{
        .fs = memory.fs(),
        .snapshot_store = &store,
        .block_resolver = types.BlockResolver.fromFunction(closerOnlyResolver),
    });
    const patch_text = try std.fmt.allocPrint(allocator, "[{s}#{s}]\nINS.BLK.POST 3:\n+  done();", .{ path, tag });
    const result = try expectPatcherSuccess(try patcher.applyText(allocator, patch_text));
    try std.testing.expectEqualStrings("function x() {\n  if (y) {\n  }\n  done();\n}\n", memory.get(path).?);
    try std.testing.expect(warningContains(result.sections[0].warnings, "applied as plain `INS.POST 3:`"));
}

test "hashline: block applyTo inserts the body after the resolved block's last line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try fullApply(
        arena.allocator(),
        block_text,
        "INS.BLK.POST 2:\n+  done();",
        types.BlockResolver.fromFunction(stubResolver),
    );
    try std.testing.expectEqualStrings("function x() {\n  if (y) {\n  }\n  done();\n}\n", result.text);
}

test "hashline: block Patcher applies an insert-after-block edit and surfaces the resolution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var memory = fs_mod.InMemoryFs.init(allocator);
    defer memory.deinit();
    try memory.put(path, block_text);
    var store = snapshots.SnapshotStore.init(allocator, .{});
    defer store.deinit();
    const tag = try store.record(path, block_text, null);
    var patcher = patcher_mod.Patcher.init(.{
        .fs = memory.fs(),
        .snapshot_store = &store,
        .block_resolver = types.BlockResolver.fromFunction(stubResolver),
    });
    const patch_text = try std.fmt.allocPrint(allocator, "[{s}#{s}]\nINS.BLK.POST 2:\n+  done();", .{ path, tag });
    const result = try expectPatcherSuccess(try patcher.applyText(allocator, patch_text));
    try std.testing.expectEqual(patcher_mod.Operation.update, result.sections[0].op);
    try std.testing.expectEqualStrings("function x() {\n  if (y) {\n  }\n  done();\n}\n", memory.get(path).?);
    try std.testing.expectEqual(@as(usize, 1), result.sections[0].block_resolutions.len);
    try std.testing.expectEqual(
        types.BlockResolution{ .anchor_line = 2, .start = 2, .end = 3, .op = .insert_after },
        result.sections[0].block_resolutions[0],
    );
}
