//! Hashline format primitives and the content-derived file tag.

const std = @import("std");
const types = @import("types.zig");

pub const file_prefix = "[";
pub const file_suffix = "]";
pub const payload_replace = "+";
pub const replace_keyword = "SWAP";
pub const delete_keyword = "DEL";
pub const insert_keyword = "INS";
pub const insert_before = "PRE";
pub const insert_after = "POST";
pub const insert_head = "HEAD";
pub const insert_tail = "TAIL";
pub const replace_block_keyword = "SWAP.BLK";
pub const delete_block_keyword = "DEL.BLK";
pub const insert_after_block_keyword = "INS.BLK.POST";
pub const rem_keyword = "REM";
pub const move_keyword = "MV";
pub const header_colon = ":";
pub const file_hash_separator = "#";
pub const range_separator = ".=";
pub const line_body_separator = ":";
pub const file_hash_length = 4;
pub const file_hash_examples = [_][]const u8{ "1A2B", "3C4D", "9F3E" };

pub const FileHash = [file_hash_length]u8;

/// Hash normalization is exactly upstream's `/[ \t\r]+(?=\n|$)/g`:
/// trailing spaces, tabs, and carriage returns are removed from every line,
/// including the final line, while newlines and all other bytes remain intact.
pub fn computeFileHash(text: []const u8) FileHash {
    var hasher = std.hash.XxHash32.init(0);
    var line_start: usize = 0;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] != '\n') continue;
        var end = index;
        while (end > line_start and isHashTrailingWhitespace(text[end - 1])) end -= 1;
        hasher.update(text[line_start..end]);
        hasher.update("\n");
        line_start = index + 1;
    }
    var end = text.len;
    while (end > line_start and isHashTrailingWhitespace(text[end - 1])) end -= 1;
    hasher.update(text[line_start..end]);

    const low16: u16 = @truncate(hasher.final());
    var out: FileHash = undefined;
    _ = std.fmt.bufPrint(&out, "{X:0>4}", .{low16}) catch unreachable;
    return out;
}

pub fn describeAnchorExamples(
    allocator: std.mem.Allocator,
    line_prefix: []const u8,
) std.mem.Allocator.Error![]u8 {
    if (line_prefix.len == 0) return allocator.dupe(u8, "\"160\", \"42\", \"7\"");
    const shortened = if (line_prefix.len > 1) line_prefix[0 .. line_prefix.len - 1] else "4";
    return std.fmt.allocPrint(
        allocator,
        "\"{s}\", \"{s}2\", \"7\"",
        .{ line_prefix, shortened },
    );
}

fn isHashTrailingWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r';
}

pub fn formatReplaceHeader(allocator: std.mem.Allocator, start: usize, end: usize) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s} {d}{s}{d}{s}", .{
        replace_keyword,
        start,
        range_separator,
        end,
        header_colon,
    });
}

pub fn formatDeleteHeader(allocator: std.mem.Allocator, start: usize, end: usize) ![]u8 {
    if (start == end) return std.fmt.allocPrint(allocator, "{s} {d}", .{ delete_keyword, start });
    return std.fmt.allocPrint(allocator, "{s} {d}{s}{d}", .{ delete_keyword, start, range_separator, end });
}

pub fn formatInsertHeader(allocator: std.mem.Allocator, cursor: types.Cursor) ![]u8 {
    return switch (cursor) {
        .before_anchor => |anchor| std.fmt.allocPrint(allocator, "{s}.{s} {d}{s}", .{
            insert_keyword,
            insert_before,
            anchor.line,
            header_colon,
        }),
        .after_anchor => |anchor| std.fmt.allocPrint(allocator, "{s}.{s} {d}{s}", .{
            insert_keyword,
            insert_after,
            anchor.line,
            header_colon,
        }),
        .bof => allocator.dupe(u8, insert_keyword ++ "." ++ insert_head ++ header_colon),
        .eof => allocator.dupe(u8, insert_keyword ++ "." ++ insert_tail ++ header_colon),
    };
}

pub fn formatHashlineHeader(allocator: std.mem.Allocator, path: []const u8, hash: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "[{s}#{s}]", .{ path, hash });
}

pub fn formatNumberedLine(allocator: std.mem.Allocator, line_number: usize, line: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d}:{s}", .{ line_number, line });
}

pub fn formatNumberedLines(allocator: std.mem.Allocator, text: []const u8, start_line: usize) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    var iterator = std.mem.splitScalar(u8, text, '\n');
    var line_number = start_line;
    while (iterator.next()) |line| : (line_number += 1) {
        if (output.items.len > 0) try output.append(allocator, '\n');
        try output.print(allocator, "{d}:{s}", .{ line_number, line });
    }
    return output.toOwnedSlice(allocator);
}

test "hashline format: xxHash32 tag and trailing whitespace normalization" {
    const a = computeFileHash("line one 263\nline two 4471\n");
    const b = computeFileHash("line one 410\nline two 6970\n");
    try std.testing.expectEqualStrings("1D84", &a);
    try std.testing.expectEqualStrings(&a, &b);

    const plain = computeFileHash("a\nb\n");
    const crlf = computeFileHash("a \t\r\nb\t\r\n");
    try std.testing.expectEqualStrings(&plain, &crlf);
}

test "hashline format: empty and final-line normalization" {
    const empty = computeFileHash("");
    const spaces = computeFileHash(" \t\r");
    try std.testing.expectEqualStrings(&empty, &spaces);

    const no_newline = computeFileHash("a");
    const trimmed = computeFileHash("a \t\r");
    try std.testing.expectEqualStrings(&no_newline, &trimmed);
}

test "hashline format: upstream normalization edge vectors" {
    const cases = [_]struct { text: []const u8, expected: []const u8 }{
        .{ .text = "", .expected = "5D05" },
        .{ .text = "\n", .expected = "D352" },
        .{ .text = "a", .expected = "7456" },
        .{ .text = "a\n", .expected = "9585" },
        .{ .text = "a \n", .expected = "9585" },
        .{ .text = "a\r\n", .expected = "9585" },
        .{ .text = "a\n\n", .expected = "4F66" },
        .{ .text = "a\t\r\nb  \r\n", .expected = "9A46" },
    };
    for (cases) |case| {
        const actual = computeFileHash(case.text);
        try std.testing.expectEqualStrings(case.expected, &actual);
    }
}

test "hashline format: describeAnchorExamples matches upstream" {
    const allocator = std.testing.allocator;
    const defaults = try describeAnchorExamples(allocator, "");
    defer allocator.free(defaults);
    try std.testing.expectEqualStrings("\"160\", \"42\", \"7\"", defaults);
    const prefixed = try describeAnchorExamples(allocator, "119");
    defer allocator.free(prefixed);
    try std.testing.expectEqualStrings("\"119\", \"112\", \"7\"", prefixed);
    const single = try describeAnchorExamples(allocator, "7");
    defer allocator.free(single);
    try std.testing.expectEqualStrings("\"7\", \"42\", \"7\"", single);
}
