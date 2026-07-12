//! Byte-exact stale-snapshot diagnostics with anchored line context.

const std = @import("std");
const messages = @import("messages.zig");
const types = @import("types.zig");

pub const Details = struct {
    path: ?[]const u8 = null,
    expected_file_hash: []const u8,
    actual_file_hash: []const u8,
    file_lines: []const []const u8,
    anchor_lines: []const usize = &.{},
    /// False means the expected tag was never retained for this path in the
    /// current session. True means it names a known snapshot that drifted.
    hash_recognized: bool = true,
};

pub const MismatchDetails = Details;

pub fn formatFullAnchorRequirement(
    allocator: std.mem.Allocator,
    raw: ?[]const u8,
) ![]const u8 {
    return messages.fullAnchorRequirementMessage(allocator, raw);
}

pub fn parseTag(
    allocator: std.mem.Allocator,
    ref: []const u8,
) !types.Outcome(types.Anchor) {
    var index: usize = 0;
    while (index < ref.len and isWhitespace(ref[index])) index += 1;
    while (index < ref.len and switch (ref[index]) {
        '>', '+', '-', '*' => true,
        else => false,
    }) : (index += 1) {}
    while (index < ref.len and isWhitespace(ref[index])) index += 1;
    const digit_start = index;
    while (index < ref.len and std.ascii.isDigit(ref[index])) index += 1;
    if (digit_start == index) {
        return .{ .failure = types.failure(try messages.invalidLineReferenceMessage(allocator, ref)) };
    }
    const digit_end = index;
    if (index < ref.len and ref[index] == ':') {
        index = ref.len;
    } else {
        while (index < ref.len and isWhitespace(ref[index])) index += 1;
    }
    if (index != ref.len) {
        return .{ .failure = types.failure(try messages.invalidLineReferenceMessage(allocator, ref)) };
    }
    const line = std.fmt.parseInt(usize, ref[digit_start..digit_end], 10) catch {
        return .{ .failure = types.failure(try messages.invalidLineReferenceMessage(allocator, ref)) };
    };
    if (line < 1) {
        return .{ .failure = types.failure(try messages.lineNumberMinimumMessage(allocator, line, ref)) };
    }
    return .{ .success = .{ .line = line } };
}

pub fn validateLineRef(
    allocator: std.mem.Allocator,
    ref: types.Anchor,
    file_lines: []const []const u8,
) !types.Outcome(void) {
    if (ref.line < 1 or ref.line > file_lines.len) {
        return .{ .failure = types.failure(try messages.lineOutOfBoundsMessage(
            allocator,
            ref.line,
            file_lines.len,
        )) };
    }
    return .{ .success = {} };
}

fn isWhitespace(byte: u8) bool {
    return byte == ' ' or (byte >= '\t' and byte <= '\r');
}

/// Zig carries semantic failures as values rather than custom error objects;
/// this struct preserves the upstream mismatch fields alongside its rendered
/// model-facing message.
pub const MismatchError = struct {
    path: ?[]const u8,
    expected_file_hash: []const u8,
    actual_file_hash: []const u8,
    file_lines: []const []const u8,
    anchor_lines: []const usize,
    hash_recognized: bool,
    message: []const u8,

    pub fn init(allocator: std.mem.Allocator, details: Details) !MismatchError {
        return .{
            .path = details.path,
            .expected_file_hash = details.expected_file_hash,
            .actual_file_hash = details.actual_file_hash,
            .file_lines = details.file_lines,
            .anchor_lines = details.anchor_lines,
            .hash_recognized = details.hash_recognized,
            .message = try formatMessage(allocator, details),
        };
    }

    pub fn displayMessage(self: MismatchError) []const u8 {
        return self.message;
    }

    pub fn asFailure(self: MismatchError) types.Failure {
        return types.failureKind(.mismatch, self.message);
    }
};

pub fn formatMessage(allocator: std.mem.Allocator, details: Details) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    const base = if (details.hash_recognized)
        try messages.mismatchRecognizedMessage(
            allocator,
            details.path,
            details.expected_file_hash,
            details.actual_file_hash,
        )
    else
        try messages.mismatchUnrecognizedMessage(
            allocator,
            details.path,
            details.expected_file_hash,
            details.actual_file_hash,
        );
    try output.appendSlice(allocator, base);

    const context = try messages.formatAnchoredContext(allocator, details.anchor_lines, details.file_lines);
    if (context.len > 0) {
        try output.appendSlice(allocator, "\n\n");
        for (context, 0..) |row, index| {
            if (index > 0) try output.append(allocator, '\n');
            try output.appendSlice(allocator, row);
        }
    }
    return output.toOwnedSlice(allocator);
}

pub fn makeFailure(allocator: std.mem.Allocator, details: Details) !types.Failure {
    return (try MismatchError.init(allocator, details)).asFailure();
}

test "hashline mismatch: recognized drift text and context are byte exact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rendered = try formatMessage(arena.allocator(), .{
        .path = "src/a.ts",
        .expected_file_hash = "1A2B",
        .actual_file_hash = "3C4D",
        .file_lines = &.{ "l1", "l2", "l3", "l4", "l5" },
        .anchor_lines = &.{4},
    });
    try std.testing.expectEqualStrings(
        "Edit rejected for src/a.ts: file changed between read and edit.\n" ++
            "Section is bound to #1A2B, but the current file hashes to #3C4D. If a prior edit in this session modified this file, copy the [path#newhash] header from that edit's response; otherwise re-read the file with `read` to refresh the tag before retrying.\n\n" ++
            " 2:l2\n 3:l3\n*4:l4\n 5:l5",
        rendered,
    );
}

test "hashline mismatch: unrecognized tag text is byte exact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rendered = try formatMessage(arena.allocator(), .{
        .path = "src/a.ts",
        .expected_file_hash = "FFFF",
        .actual_file_hash = "3C4D",
        .file_lines = &.{"current"},
        .hash_recognized = false,
    });
    try std.testing.expectEqualStrings(
        "Edit rejected for src/a.ts: hash #FFFF is not from this session.\n" ++
            "The current file hashes to #3C4D. Re-read the file with `read` to copy a current [path#tag] header — never invent the tag and never reuse one from a prior session.",
        rendered,
    );
}

test "hashline mismatch: anchor helper exports match upstream" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings(
        "a bare line number from read/search output plus the section header content-hash tag " ++
            "(for example [src/foo.ts#1A2B] and line \"160\") Received \"bad\".",
        try formatFullAnchorRequirement(allocator, "bad"),
    );
    const parsed = try parseTag(allocator, " >*42:body");
    try std.testing.expectEqual(@as(usize, 42), parsed.success.line);
    const invalid = try parseTag(allocator, "nope");
    try std.testing.expectEqualStrings(
        "Invalid line reference. Expected a bare line number from read/search output plus the section header content-hash tag " ++
            "(for example [src/foo.ts#1A2B] and line \"160\") Received \"nope\"..",
        invalid.failure.message,
    );
    const out_of_bounds = try validateLineRef(allocator, .{ .line = 3 }, &.{ "a", "b" });
    try std.testing.expectEqualStrings("Line 3 does not exist (file has 2 lines)", out_of_bounds.failure.message);
}
