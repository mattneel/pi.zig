//! Expansion of deferred block edits through an injected resolver.

const std = @import("std");
const apply = @import("apply.zig");
const messages = @import("messages.zig");
const types = @import("types.zig");

pub const BlockResolver = types.BlockResolver;
pub const BlockSpan = types.BlockSpan;
pub const BlockResolution = types.BlockResolution;

pub const UnresolvedMode = enum {
    fail,
    drop,
};

pub const ResolveOptions = struct {
    on_unresolved: UnresolvedMode = .fail,
};

pub const ResolveResult = struct {
    edits: []const types.Edit,
    resolutions: []const types.BlockResolution = &.{},
    warnings: []const []const u8 = &.{},
};

pub fn hasBlockEdit(edits: []const types.Edit) bool {
    for (edits) |edit| if (edit == .block) return true;
    return false;
}

pub fn resolveBlockEdits(
    allocator: std.mem.Allocator,
    edits: []const types.Edit,
    text: []const u8,
    path: []const u8,
    resolver: ?types.BlockResolver,
    options: ResolveOptions,
) !types.Outcome(ResolveResult) {
    if (!hasBlockEdit(edits)) return .{ .success = .{ .edits = edits } };

    var resolved: std.ArrayList(types.Edit) = .empty;
    var resolutions: std.ArrayList(types.BlockResolution) = .empty;
    var warnings: std.ArrayList([]const u8) = .empty;
    var synth_index: usize = 0;
    const file_lines = try splitLines(allocator, text);

    for (edits) |edit| switch (edit) {
        .insert, .delete => try resolved.append(allocator, edit),
        .block => |block_edit| {
            const op: types.BlockResolutionOp = if (block_edit.mode == .insert_after)
                .insert_after
            else if (block_edit.payloads.len == 0)
                .delete
            else
                .replace;
            const span = if (resolver) |active| active.resolve(.{
                .path = path,
                .text = text,
                .line = block_edit.anchor.line,
            }) else null;
            if (span == null) {
                if (op == .insert_after) {
                    const anchor_text = if (block_edit.anchor.line >= 1 and block_edit.anchor.line <= file_lines.len)
                        file_lines[block_edit.anchor.line - 1]
                    else
                        null;
                    const warning = if (anchor_text != null and apply.isStructuralCloserLine(anchor_text.?))
                        try messages.insertAfterBlockCloserLoweredWarning(allocator, block_edit.anchor.line)
                    else
                        try messages.insertAfterBlockUnresolvedLoweredWarning(allocator, block_edit.anchor.line);
                    try warnings.append(allocator, warning);
                    for (block_edit.payloads) |payload| {
                        try resolved.append(allocator, .{ .insert = .{
                            .cursor = .{ .after_anchor = block_edit.anchor },
                            .text = payload,
                            .source_line = block_edit.source_line,
                            .index = synth_index,
                        } });
                        synth_index += 1;
                    }
                    continue;
                }
                if (options.on_unresolved == .drop) continue;
                const detail = if (resolver == null)
                    messages.block_resolver_unavailable
                else
                    try messages.blockUnresolvedMessage(allocator, block_edit.anchor.line, op, file_lines);
                return .{ .failure = .{
                    .message = try messages.lineMessage(allocator, block_edit.source_line, detail),
                } };
            }
            const concrete = span.?;
            if (concrete.start == concrete.end) {
                if (options.on_unresolved == .drop) continue;
                const detail = try messages.blockSingleLineMessage(allocator, block_edit.anchor.line, op);
                return .{ .failure = .{
                    .message = try messages.lineMessage(allocator, block_edit.source_line, detail),
                } };
            }
            try resolutions.append(allocator, .{
                .anchor_line = block_edit.anchor.line,
                .start = concrete.start,
                .end = concrete.end,
                .op = op,
            });
            if (op == .insert_after) {
                for (block_edit.payloads) |payload| {
                    try resolved.append(allocator, .{ .insert = .{
                        .cursor = .{ .after_anchor = .{ .line = concrete.end } },
                        .text = payload,
                        .source_line = block_edit.source_line,
                        .index = synth_index,
                        .block_start = concrete.start,
                    } });
                    synth_index += 1;
                }
                continue;
            }
            for (block_edit.payloads) |payload| {
                try resolved.append(allocator, .{ .insert = .{
                    .cursor = .{ .before_anchor = .{ .line = concrete.start } },
                    .text = payload,
                    .source_line = block_edit.source_line,
                    .index = synth_index,
                    .mode = .replacement,
                } });
                synth_index += 1;
            }
            if (concrete.start <= concrete.end) {
                for (concrete.start..concrete.end + 1) |line| {
                    try resolved.append(allocator, .{ .delete = .{
                        .anchor = .{ .line = line },
                        .source_line = block_edit.source_line,
                        .index = synth_index,
                    } });
                    synth_index += 1;
                }
            }
        },
    };

    return .{ .success = .{
        .edits = try resolved.toOwnedSlice(allocator),
        .resolutions = try resolutions.toOwnedSlice(allocator),
        .warnings = try warnings.toOwnedSlice(allocator),
    } };
}

fn splitLines(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var iterator = std.mem.splitScalar(u8, text, '\n');
    while (iterator.next()) |line| try lines.append(allocator, line);
    return lines.toOwnedSlice(allocator);
}

fn twoLineResolver(request: types.BlockResolverRequest) ?types.BlockSpan {
    return .{ .start = request.line, .end = request.line + 1 };
}

fn nullResolver(_: types.BlockResolverRequest) ?types.BlockSpan {
    return null;
}

test "hashline block.test.ts: expands SWAP.BLK exactly like a concrete replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const edits = [_]types.Edit{.{ .block = .{
        .anchor = .{ .line = 2 },
        .payloads = &.{ "A", "B" },
        .source_line = 1,
        .index = 0,
    } }};
    const outcome = try resolveBlockEdits(
        arena.allocator(),
        &edits,
        "a\nb\nc",
        "x.ts",
        types.BlockResolver.fromFunction(twoLineResolver),
        .{},
    );
    const result = outcome.success;
    try std.testing.expectEqual(@as(usize, 4), result.edits.len);
    try std.testing.expectEqual(@as(usize, 1), result.resolutions.len);
    try std.testing.expectEqual(types.BlockResolutionOp.replace, result.resolutions[0].op);
}

test "hashline block.test.ts: no resolver rejects SWAP.BLK and drop mode omits it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const edits = [_]types.Edit{.{ .block = .{
        .anchor = .{ .line = 2 },
        .payloads = &.{"X"},
        .source_line = 1,
        .index = 0,
    } }};
    const failed = try resolveBlockEdits(arena.allocator(), &edits, "a\nb\nc", "x.ts", null, .{});
    try std.testing.expect(std.mem.indexOf(u8, failed.failure.message, "not available here") != null);
    const dropped = try resolveBlockEdits(arena.allocator(), &edits, "a\nb\nc", "x.ts", null, .{ .on_unresolved = .drop });
    try std.testing.expectEqual(@as(usize, 0), dropped.success.edits.len);
}

test "hashline block.test.ts: unresolved INS.BLK.POST lowers with warning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const edits = [_]types.Edit{.{ .block = .{
        .anchor = .{ .line = 2 },
        .payloads = &.{"X"},
        .mode = .insert_after,
        .source_line = 1,
        .index = 0,
    } }};
    const outcome = try resolveBlockEdits(
        arena.allocator(),
        &edits,
        "a\nb\nc",
        "x.ts",
        types.BlockResolver.fromFunction(nullResolver),
        .{},
    );
    try std.testing.expectEqual(@as(usize, 1), outcome.success.edits.len);
    try std.testing.expectEqual(@as(usize, 1), outcome.success.warnings.len);
    try std.testing.expect(std.mem.indexOf(u8, outcome.success.warnings[0], "applied as plain `INS.POST 2:`") != null);
}

test "hashline block: Unicode whitespace after a closer selects the closer-specific lowering warning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const edits = [_]types.Edit{.{ .block = .{
        .anchor = .{ .line = 2 },
        .payloads = &.{"X"},
        .mode = .insert_after,
        .source_line = 1,
        .index = 0,
    } }};
    const outcome = try resolveBlockEdits(
        arena.allocator(),
        &edits,
        "if (x) {\n}\xc2\xa0\nafter();",
        "x.ts",
        types.BlockResolver.fromFunction(nullResolver),
        .{},
    );
    try std.testing.expectEqual(@as(usize, 1), outcome.success.warnings.len);
    try std.testing.expect(std.mem.indexOf(u8, outcome.success.warnings[0], "anchors on a closing delimiter") != null);
}
