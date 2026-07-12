//! Pure model-facing rendering for a committed hashline section.

const std = @import("std");
const diff = @import("diff.zig");
const diff_preview = @import("diff_preview.zig");
const messages = @import("messages.zig");
const types = @import("types.zig");

pub fn renderAppliedSection(
    allocator: std.mem.Allocator,
    header: []const u8,
    before: []const u8,
    after: []const u8,
    block_resolutions: []const types.BlockResolution,
    move_dest: ?[]const u8,
    warnings: []const []const u8,
) ![]const u8 {
    const numbered = try diff.buildNumberedDiff(allocator, before, after, 2);
    const preview = try diff_preview.buildCompactDiffPreview(allocator, numbered.diff, .{});
    var output: std.ArrayList(u8) = .empty;
    try output.appendSlice(allocator, header);
    for (block_resolutions) |resolution| {
        try output.append(allocator, '\n');
        try output.appendSlice(allocator, try messages.blockResolutionEchoMessage(allocator, resolution));
    }
    if (move_dest) |dest| {
        try output.append(allocator, '\n');
        try output.appendSlice(allocator, try messages.movedToMessage(allocator, dest));
    }
    if (preview.preview.len > 0) try output.print(allocator, "\n{s}", .{preview.preview});
    if (warnings.len > 0) {
        try output.appendSlice(allocator, messages.warnings_block_header);
        for (warnings, 0..) |warning, index| {
            if (index > 0) try output.append(allocator, '\n');
            try output.appendSlice(allocator, warning);
        }
    }
    return output.toOwnedSlice(allocator);
}

pub fn renderDeletedSection(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return messages.deletedSectionMessage(allocator, path);
}

pub fn noChangeDiagnostic(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return messages.noChangeDiagnosticMessage(allocator, path);
}

test "hashline render: header block echo preview and warnings ordering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rendered = try renderAppliedSection(
        arena.allocator(),
        "[x.ts#ABCD]",
        "a\nb\n",
        "a\nB\n",
        &.{.{ .anchor_line = 2, .start = 2, .end = 3, .op = .insert_after }},
        null,
        &.{"careful"},
    );
    try std.testing.expectEqualStrings(
        "[x.ts#ABCD]\nINS.BLK.POST 2 → resolved lines 2-3 (2 lines); body lands after line 3\n1:a\n2:B\n\nWarnings:\ncareful",
        rendered,
    );
}
