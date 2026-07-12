//! Prefix recovery for payloads copied from hashline read/search output.
//!
//! Returned line slices borrow their input, except `hashlineParseText`, whose
//! slices point into caller-allocator storage. The intended caller is an arena
//! scoped to one parse/tool invocation.

const std = @import("std");
const format = @import("format.zig");

const PrefixStats = struct {
    non_empty: usize = 0,
    header_count: usize = 0,
    hash_prefix_count: usize = 0,
    diff_plus_hash_prefix_count: usize = 0,
    diff_plus_count: usize = 0,
};

fn isWhitespace(byte: u8) bool {
    return byte == ' ' or (byte >= '\t' and byte <= '\r');
}

fn skipWhitespace(line: []const u8, initial: usize) usize {
    var index = initial;
    while (index < line.len and isWhitespace(line[index])) index += 1;
    return index;
}

fn trimEndIndex(line: []const u8) usize {
    var end = line.len;
    while (end > 0 and isWhitespace(line[end - 1])) end -= 1;
    return end;
}

fn leadingHashlinePrefixEnd(line: []const u8, require_plus: bool) ?usize {
    var index = skipWhitespace(line, 0);
    if (std.mem.startsWith(u8, line[index..], ">>>")) {
        index += 3;
    } else if (std.mem.startsWith(u8, line[index..], ">>")) {
        index += 2;
    }
    index = skipWhitespace(line, index);

    const has_marker = index < line.len and (line[index] == '+' or line[index] == '*' or line[index] == '-');
    if (require_plus and (!has_marker or line[index] != '+')) return null;
    if (has_marker) {
        index += 1;
        index = skipWhitespace(line, index);
    }

    const digit_start = index;
    while (index < line.len and std.ascii.isDigit(line[index])) index += 1;
    if (index == digit_start or index >= line.len or line[index] != ':') return null;
    return index + 1;
}

fn isHeader(line: []const u8) bool {
    const start = skipWhitespace(line, 0);
    const end = trimEndIndex(line);
    if (end <= start + 2 or line[start] != '[' or line[end - 1] != ']') return false;
    const body = line[start + 1 .. end - 1];
    if (body.len <= format.file_hash_length + 1) return false;
    const hash_at = body.len - format.file_hash_length - 1;
    if (body[hash_at] != '#') return false;
    if (std.mem.indexOfScalar(u8, body[0..hash_at], '#') != null) return false;
    for (body[hash_at + 1 ..]) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn isDiffPlus(line: []const u8) bool {
    return line.len > 0 and line[0] == '+' and (line.len == 1 or line[1] != '+');
}

fn jsWhitespaceLenAt(text: []const u8, index: usize) usize {
    if (index >= text.len) return 0;
    return switch (text[index]) {
        ' ', '\t', '\n', '\r', '\x0b', '\x0c' => 1,
        0xC2 => if (index + 1 < text.len and text[index + 1] == 0xA0) 2 else 0,
        0xE1 => if (index + 2 < text.len and
            text[index + 1] == 0x9A and text[index + 2] == 0x80) 3 else 0,
        0xE2 => if (index + 2 >= text.len) 0 else switch (text[index + 1]) {
            0x80 => if ((text[index + 2] >= 0x80 and text[index + 2] <= 0x8A) or
                text[index + 2] == 0xA8 or text[index + 2] == 0xA9 or
                text[index + 2] == 0xAF) 3 else 0,
            0x81 => if (text[index + 2] == 0x9F) 3 else 0,
            else => 0,
        },
        0xE3 => if (index + 2 < text.len and
            text[index + 1] == 0x80 and text[index + 2] == 0x80) 3 else 0,
        0xEF => if (index + 2 < text.len and
            text[index + 1] == 0xBB and text[index + 2] == 0xBF) 3 else 0,
        else => 0,
    };
}

fn digitsEnd(text: []const u8, start: usize) ?usize {
    var index = start;
    while (index < text.len and std.ascii.isDigit(text[index])) index += 1;
    return if (index == start) null else index;
}

fn isAsciiWord(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn hasAsciiWordBoundary(text: []const u8, index: usize) bool {
    const before_word = index > 0 and isAsciiWord(text[index - 1]);
    const after_word = index < text.len and isAsciiWord(text[index]);
    return before_word != after_word;
}

fn hasUseDirective(text: []const u8, start: usize) bool {
    var index = start;
    while (index + "Use :".len <= text.len) : (index += 1) {
        if (!std.mem.startsWith(u8, text[index..], "Use :") or
            !hasAsciiWordBoundary(text, index)) continue;
        var digit_start = index + "Use :".len;
        if (digit_start < text.len and text[digit_start] == 'L') digit_start += 1;
        if (digitsEnd(text, digit_start) != null) return true;
    }
    return false;
}

fn isReadTruncationNotice(line: []const u8) bool {
    if (line.len < 2 or line[0] != '[') return false;

    if (std.mem.startsWith(u8, line, "[Showing lines ")) {
        var index: usize = "[Showing lines ".len;
        index = digitsEnd(line, index) orelse return false;
        if (index >= line.len or line[index] != '-') return false;
        index = digitsEnd(line, index + 1) orelse return false;
        if (!std.mem.startsWith(u8, line[index..], " of ")) return false;
        index = digitsEnd(line, index + " of ".len) orelse return false;
        return hasAsciiWordBoundary(line, index) and hasUseDirective(line, index);
    }

    var index: usize = 1;
    index = digitsEnd(line, index) orelse return false;
    if (!std.mem.startsWith(u8, line[index..], " more line")) return false;
    index += " more line".len;
    if (index < line.len and line[index] == 's') index += 1;
    if (!std.mem.startsWith(u8, line[index..], " in ")) return false;
    const target_start = index + " in ".len;
    if (target_start >= line.len or jsWhitespaceLenAt(line, target_start) != 0) return false;

    // `(file|\S+)\b` can backtrack within the non-whitespace target. Test
    // each code-point boundary so punctuation-bearing targets behave like
    // the JavaScript regexp without treating UTF-8 continuation bytes as
    // candidate boundaries.
    var target_end = target_start;
    while (target_end < line.len and jsWhitespaceLenAt(line, target_end) == 0) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(line[target_end]) catch 1;
        target_end += @min(sequence_len, line.len - target_end);
        if (hasAsciiWordBoundary(line, target_end) and hasUseDirective(line, target_end)) return true;
    }
    return false;
}

fn collectStats(lines: []const []const u8) PrefixStats {
    var stats: PrefixStats = .{};
    for (lines) |line| {
        if (line.len == 0) continue;
        if (isReadTruncationNotice(line)) continue;
        if (isHeader(line)) {
            stats.non_empty += 1;
            stats.header_count += 1;
            continue;
        }
        stats.non_empty += 1;
        if (leadingHashlinePrefixEnd(line, false) != null) stats.hash_prefix_count += 1;
        if (leadingHashlinePrefixEnd(line, true) != null) stats.diff_plus_hash_prefix_count += 1;
        if (isDiffPlus(line)) stats.diff_plus_count += 1;
    }
    return stats;
}

fn stripLeadingHashlinePrefixes(line: []const u8) []const u8 {
    var result = line;
    while (leadingHashlinePrefixEnd(result, false)) |end| result = result[end..];
    return result;
}

/// Strip at most one leading `N:`/`>>>N:`/`+N:` prefix.
pub fn stripOneLeadingHashlinePrefix(line: []const u8) []const u8 {
    const end = leadingHashlinePrefixEnd(line, false) orelse return line;
    return line[end..];
}

/// Opportunistically strip a uniform hashline/diff prefix scheme.
pub fn stripNewLinePrefixes(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    const stats = collectStats(lines);
    if (stats.non_empty == 0) return allocator.dupe([]const u8, lines);

    const content_count = stats.non_empty - stats.header_count;
    const strip_hash = content_count > 0 and stats.hash_prefix_count == content_count;
    const strip_plus = !strip_hash and
        stats.diff_plus_hash_prefix_count == 0 and
        stats.diff_plus_count > 0 and
        stats.diff_plus_count * 2 >= stats.non_empty;
    if (!strip_hash and !strip_plus and stats.diff_plus_hash_prefix_count == 0) {
        return allocator.dupe([]const u8, lines);
    }

    var output: std.ArrayList([]const u8) = .empty;
    for (lines) |line| {
        if (isReadTruncationNotice(line) or (strip_hash and isHeader(line))) continue;
        if (strip_hash) {
            try output.append(allocator, stripLeadingHashlinePrefixes(line));
        } else if (strip_plus) {
            try output.append(allocator, if (isDiffPlus(line)) line[1..] else line);
        } else if (stats.diff_plus_hash_prefix_count > 0 and leadingHashlinePrefixEnd(line, true) != null) {
            try output.append(allocator, stripOneLeadingHashlinePrefix(line));
        } else {
            try output.append(allocator, line);
        }
    }
    return output.toOwnedSlice(allocator);
}

/// Strictly strip hashline prefixes only when every content line carries one.
pub fn stripHashlinePrefixes(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    const stats = collectStats(lines);
    if (stats.non_empty == 0) return allocator.dupe([]const u8, lines);
    const content_count = stats.non_empty - stats.header_count;
    if (content_count == 0 or stats.hash_prefix_count != content_count) {
        return allocator.dupe([]const u8, lines);
    }

    var output: std.ArrayList([]const u8) = .empty;
    for (lines) |line| {
        if (isReadTruncationNotice(line) or isHeader(line)) continue;
        try output.append(allocator, stripLeadingHashlinePrefixes(line));
    }
    return output.toOwnedSlice(allocator);
}

/// Normalize a multiline pasted payload and recover its raw text rows.
pub fn hashlineParseText(
    allocator: std.mem.Allocator,
    edit: ?[]const u8,
) std.mem.Allocator.Error![]const []const u8 {
    const source = edit orelse return allocator.alloc([]const u8, 0);
    const without_final_lf = if (std.mem.endsWith(u8, source, "\n")) source[0 .. source.len - 1] else source;
    var normalized: std.ArrayList(u8) = .empty;
    for (without_final_lf) |byte| {
        if (byte != '\r') try normalized.append(allocator, byte);
    }
    const owned = try normalized.toOwnedSlice(allocator);
    var rows: std.ArrayList([]const u8) = .empty;
    var iterator = std.mem.splitScalar(u8, owned, '\n');
    while (iterator.next()) |line| try rows.append(allocator, line);
    return stripNewLinePrefixes(allocator, rows.items);
}

test "hashline: prefixes strip one copied read prefix without corrupting nested digits" {
    try std.testing.expectEqualStrings("42:hello", stripOneLeadingHashlinePrefix("2:42:hello"));
    try std.testing.expectEqualStrings("literal", stripOneLeadingHashlinePrefix(">>> + 12:literal"));
}

test "hashline: prefixes strip uniform numbered rows and header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = [_][]const u8{ "[a.ts#1A2B]", "1:one", "2:two" };
    const stripped = try stripHashlinePrefixes(arena.allocator(), &rows);
    try std.testing.expectEqual(@as(usize, 2), stripped.len);
    try std.testing.expectEqualStrings("one", stripped[0]);
    try std.testing.expectEqualStrings("two", stripped[1]);
}

test "hashline regression 9: read truncation notices require the exact range target and Use anchor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const invalid_rows = [_][]const u8{
        "[3 more lines in file. Use : next]",
        "1:one",
        "2:two",
    };
    const preserved = try stripNewLinePrefixes(arena.allocator(), &invalid_rows);
    try std.testing.expectEqual(@as(usize, invalid_rows.len), preserved.len);
    for (invalid_rows, preserved) |expected, actual| try std.testing.expectEqualStrings(expected, actual);

    const valid_rows = [_][]const u8{
        "[Showing lines 1-2 of 5. Use :L3 to continue]",
        "1:one",
        "2:two",
    };
    const stripped = try stripNewLinePrefixes(arena.allocator(), &valid_rows);
    try std.testing.expectEqual(@as(usize, 2), stripped.len);
    try std.testing.expectEqualStrings("one", stripped[0]);
    try std.testing.expectEqualStrings("two", stripped[1]);
}
