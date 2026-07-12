//! Stateful, line-oriented tokenizer for the hashline patch language.
//!
//! Token text is copied into the tokenizer's caller-provided allocator. A
//! tokenizer is therefore normally backed by the parse arena; returned tokens
//! remain valid for that arena's lifetime.

const std = @import("std");
const format = @import("format.zig");
const messages = @import("messages.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

pub const BlockTarget = union(enum) {
    replace: types.ParsedRange,
    block: types.Anchor,
    delete: types.ParsedRange,
    delete_block: types.Anchor,
    insert_before: types.Anchor,
    insert_after: types.Anchor,
    insert_after_block: types.Anchor,
    rem,
    move: []const u8,
    bof,
    eof,
};

pub const Token = union(enum) {
    blank: usize,
    envelope_begin: usize,
    envelope_end: usize,
    abort: usize,
    header: Header,
    op_block: OpBlock,
    payload_literal: Text,
    raw: Text,

    pub const Header = struct {
        line_num: usize,
        path: []const u8,
        file_hash: ?format.FileHash = null,
    };

    pub const OpBlock = struct {
        line_num: usize,
        target: BlockTarget,
    };

    pub const Text = struct {
        line_num: usize,
        text: []const u8,
    };

    pub fn lineNum(self: Token) usize {
        return switch (self) {
            .blank => |line| line,
            .envelope_begin => |line| line,
            .envelope_end => |line| line,
            .abort => |line| line,
            .header => |value| value.line_num,
            .op_block => |value| value.line_num,
            .payload_literal => |value| value.line_num,
            .raw => |value| value.line_num,
        };
    }
};

const NumberScan = struct {
    line: usize,
    next_index: usize,
};

const RangeScan = struct {
    range: types.ParsedRange,
    next_index: usize,
};

const TargetScan = struct {
    target: BlockTarget,
    next_index: usize,
};

const HeaderScan = struct {
    path: []const u8,
    file_hash: ?format.FileHash = null,
};

fn isWhitespace(byte: u8) bool {
    return byte == ' ' or (byte >= '\t' and byte <= '\r');
}

fn skipWhitespace(line: []const u8, initial: usize, end: usize) usize {
    var index = initial;
    while (index < end and isWhitespace(line[index])) index += 1;
    return index;
}

fn trimEndIndex(line: []const u8) usize {
    var end = line.len;
    while (end > 0 and isWhitespace(line[end - 1])) end -= 1;
    return end;
}

fn markerLineEquals(line: []const u8, marker: []const u8) bool {
    const end = trimEndIndex(line);
    return end == marker.len and std.mem.eql(u8, line[0..end], marker);
}

fn scanLineNumber(line: []const u8, initial: usize, end: usize) ?NumberScan {
    if (initial >= end or line[initial] < '1' or line[initial] > '9') return null;
    var value: usize = 0;
    var index = initial;
    while (index < end and std.ascii.isDigit(line[index])) : (index += 1) {
        const digit: usize = line[index] - '0';
        if (value > (std.math.maxInt(usize) - digit) / 10) return null;
        value = value * 10 + digit;
    }
    return .{ .line = value, .next_index = index };
}

fn scanRangeSeparator(line: []const u8, initial: usize, end: usize) ?usize {
    var index = initial;
    var consumed = false;
    while (index < end) {
        if (isWhitespace(line[index]) or line[index] == '-') {
            index += 1;
            consumed = true;
            continue;
        }
        if (std.mem.startsWith(u8, line[index..end], "…")) {
            index += "…".len;
            consumed = true;
            continue;
        }
        if (line[index] == '.' and index + 1 < end and (line[index + 1] == '.' or line[index + 1] == '=')) {
            index += 2;
            consumed = true;
            continue;
        }
        break;
    }
    if (!consumed or index >= end or line[index] < '1' or line[index] > '9') return null;
    return index;
}

fn scanHeaderRange(
    line: []const u8,
    initial: usize,
    end: usize,
    allow_single: bool,
) ?RangeScan {
    const number_start = skipWhitespace(line, initial, end);
    const start = scanLineNumber(line, number_start, end) orelse return null;
    const after_first = scanRangeSeparator(line, start.next_index, end) orelse {
        if (!allow_single) return null;
        return .{
            .range = .{ .start = .{ .line = start.line }, .end = .{ .line = start.line } },
            .next_index = skipWhitespace(line, start.next_index, end),
        };
    };
    const finish = scanLineNumber(line, after_first, end) orelse return null;
    return .{
        .range = .{ .start = .{ .line = start.line }, .end = .{ .line = finish.line } },
        .next_index = skipWhitespace(line, finish.next_index, end),
    };
}

fn scanKeyword(line: []const u8, index: usize, end: usize, keyword: []const u8) ?usize {
    if (!std.mem.startsWith(u8, line[index..end], keyword)) return null;
    const next = index + keyword.len;
    if (next < end and !isWhitespace(line[next]) and line[next] != ':' and line[next] != '.') return null;
    return next;
}

fn skipStrayDot(line: []const u8, initial: usize, end: usize) usize {
    if (initial < end and line[initial] == '.') {
        const after = skipWhitespace(line, initial + 1, end);
        if (after == end or line[after] == ':') return after;
    }
    return initial;
}

fn consumeOptionalColon(line: []const u8, initial: usize, end: usize) usize {
    var index = skipWhitespace(line, initial, end);
    index = skipStrayDot(line, index, end);
    return if (index < end and line[index] == ':') skipWhitespace(line, index + 1, end) else index;
}

fn scanInsertTarget(line: []const u8, initial: usize, end: usize) ?TargetScan {
    if (initial >= end or line[initial] != '.') return null;
    const cursor = skipWhitespace(line, initial + 1, end);
    if (scanKeyword(line, cursor, end, format.insert_before)) |keyword_end| {
        const anchor = scanLineNumber(line, skipWhitespace(line, keyword_end, end), end) orelse return null;
        return .{
            .target = .{ .insert_before = .{ .line = anchor.line } },
            .next_index = consumeOptionalColon(line, anchor.next_index, end),
        };
    }
    if (scanKeyword(line, cursor, end, format.insert_after)) |keyword_end| {
        const anchor = scanLineNumber(line, skipWhitespace(line, keyword_end, end), end) orelse return null;
        return .{
            .target = .{ .insert_after = .{ .line = anchor.line } },
            .next_index = consumeOptionalColon(line, anchor.next_index, end),
        };
    }
    if (scanKeyword(line, cursor, end, format.insert_head)) |keyword_end| {
        return .{ .target = .bof, .next_index = consumeOptionalColon(line, keyword_end, end) };
    }
    if (scanKeyword(line, cursor, end, format.insert_tail)) |keyword_end| {
        return .{ .target = .eof, .next_index = consumeOptionalColon(line, keyword_end, end) };
    }
    return null;
}

fn unquotePath(path: []const u8) []const u8 {
    if (path.len < 2) return path;
    const first = path[0];
    if ((first == '"' or first == '\'') and path[path.len - 1] == first) return path[1 .. path.len - 1];
    return path;
}

fn scanMoveDest(line: []const u8, initial: usize, end: usize) ?[]const u8 {
    const cursor = skipWhitespace(line, initial, end);
    if (cursor >= end) return null;
    if (line[cursor] == '"' or line[cursor] == '\'') {
        const quote = line[cursor];
        var index = cursor + 1;
        while (index < end) {
            if (line[index] == '\\' and index + 1 < end) {
                index += 2;
                continue;
            }
            if (line[index] == quote) {
                const after = skipWhitespace(line, index + 1, end);
                return if (after == end) unquotePath(line[cursor .. index + 1]) else null;
            }
            index += 1;
        }
        return null;
    }
    return unquotePath(std.mem.trim(u8, line[cursor..end], " \t\n\r\x0b\x0c"));
}

fn scanHunkAnchor(line: []const u8, start: usize, end: usize) ?TargetScan {
    const cursor = skipWhitespace(line, start, end);

    if (scanKeyword(line, cursor, end, format.rem_keyword)) |keyword_end| {
        const next = skipWhitespace(line, keyword_end, end);
        if (next != end) return null;
        return .{ .target = .rem, .next_index = next };
    }
    if (scanKeyword(line, cursor, end, format.move_keyword)) |keyword_end| {
        const dest = scanMoveDest(line, keyword_end, end) orelse return null;
        if (dest.len == 0) return null;
        return .{ .target = .{ .move = dest }, .next_index = end };
    }
    if (scanKeyword(line, cursor, end, format.replace_block_keyword)) |keyword_end| {
        const anchor = scanLineNumber(line, skipWhitespace(line, keyword_end, end), end) orelse return null;
        return .{
            .target = .{ .block = .{ .line = anchor.line } },
            .next_index = consumeOptionalColon(line, anchor.next_index, end),
        };
    }
    if (scanKeyword(line, cursor, end, format.replace_keyword)) |keyword_end| {
        const range = scanHeaderRange(line, keyword_end, end, true) orelse return null;
        return .{
            .target = .{ .replace = range.range },
            .next_index = consumeOptionalColon(line, range.next_index, end),
        };
    }
    if (scanKeyword(line, cursor, end, format.delete_block_keyword)) |keyword_end| {
        const anchor = scanLineNumber(line, skipWhitespace(line, keyword_end, end), end) orelse return null;
        var next = skipWhitespace(line, anchor.next_index, end);
        next = skipStrayDot(line, next, end);
        if (next < end and line[next] == ':') return null;
        return .{ .target = .{ .delete_block = .{ .line = anchor.line } }, .next_index = next };
    }
    if (scanKeyword(line, cursor, end, format.delete_keyword)) |keyword_end| {
        const range = scanHeaderRange(line, keyword_end, end, true) orelse return null;
        var next = skipWhitespace(line, range.next_index, end);
        next = skipStrayDot(line, next, end);
        if (next < end and line[next] == ':') return null;
        return .{ .target = .{ .delete = range.range }, .next_index = next };
    }
    if (scanKeyword(line, cursor, end, format.insert_after_block_keyword)) |keyword_end| {
        const anchor = scanLineNumber(line, skipWhitespace(line, keyword_end, end), end) orelse return null;
        return .{
            .target = .{ .insert_after_block = .{ .line = anchor.line } },
            .next_index = consumeOptionalColon(line, anchor.next_index, end),
        };
    }
    if (scanKeyword(line, cursor, end, format.insert_keyword)) |keyword_end| {
        return scanInsertTarget(line, keyword_end, end);
    }
    return null;
}

fn tryParseHunkHeader(line: []const u8) ?BlockTarget {
    const end = trimEndIndex(line);
    const start = skipWhitespace(line, 0, end);
    if (start >= end) return null;
    const scan = scanHunkAnchor(line, start, end) orelse return null;
    if (scan.next_index != end) return null;
    return scan.target;
}

fn upperHex(byte: u8) u8 {
    return if (byte >= 'a' and byte <= 'f') byte - ('a' - 'A') else byte;
}

fn tryParseHeader(line: []const u8) ?HeaderScan {
    if (!std.mem.startsWith(u8, line, format.file_prefix)) return null;
    const end = trimEndIndex(line);
    if (format.file_prefix.len + format.file_suffix.len >= end) return null;
    if (!std.mem.endsWith(u8, line[0..end], format.file_suffix)) return null;
    const body_end = end - format.file_suffix.len;

    var path_end = body_end;
    var file_hash: ?format.FileHash = null;
    if (body_end >= format.file_hash_length + 1) {
        const hash_start = body_end - format.file_hash_length - 1;
        if (hash_start >= format.file_prefix.len and line[hash_start] == '#') {
            var all_hex = true;
            for (line[hash_start + 1 .. body_end]) |byte| {
                if (!std.ascii.isHex(byte)) {
                    all_hex = false;
                    break;
                }
            }
            if (all_hex) {
                path_end = hash_start;
                var hash: format.FileHash = undefined;
                for (line[hash_start + 1 .. body_end], 0..) |byte, index| hash[index] = upperHex(byte);
                file_hash = hash;
            }
        }
    }
    for (line[format.file_prefix.len..path_end]) |byte| if (byte == '#') return null;
    if (path_end == format.file_prefix.len) return null;
    return .{ .path = line[format.file_prefix.len..path_end], .file_hash = file_hash };
}

fn cloneTarget(allocator: Allocator, target: BlockTarget) Allocator.Error!BlockTarget {
    return switch (target) {
        .move => |dest| .{ .move = try allocator.dupe(u8, dest) },
        else => target,
    };
}

fn classifyLine(allocator: Allocator, line: []const u8, line_num: usize) Allocator.Error!Token {
    if (line.len == 0) return .{ .blank = line_num };
    if (markerLineEquals(line, messages.begin_patch_marker)) return .{ .envelope_begin = line_num };
    if (markerLineEquals(line, messages.end_patch_marker)) return .{ .envelope_end = line_num };
    if (markerLineEquals(line, messages.abort_marker)) return .{ .abort = line_num };
    if (line[0] == '[') {
        if (tryParseHeader(line)) |header| {
            return .{ .header = .{
                .line_num = line_num,
                .path = try allocator.dupe(u8, header.path),
                .file_hash = header.file_hash,
            } };
        }
    }
    const lead = skipWhitespace(line, 0, line.len);
    const is_hunk_lead = std.mem.startsWith(u8, line[lead..], format.replace_keyword) or
        std.mem.startsWith(u8, line[lead..], format.delete_keyword) or
        std.mem.startsWith(u8, line[lead..], format.insert_keyword) or
        std.mem.startsWith(u8, line[lead..], format.rem_keyword) or
        std.mem.startsWith(u8, line[lead..], format.move_keyword);
    if (is_hunk_lead) {
        if (tryParseHunkHeader(line)) |target| {
            return .{ .op_block = .{ .line_num = line_num, .target = try cloneTarget(allocator, target) } };
        }
    }
    if (line[0] == '+') {
        return .{ .payload_literal = .{ .line_num = line_num, .text = try allocator.dupe(u8, line[1..]) } };
    }
    return .{ .raw = .{ .line_num = line_num, .text = try allocator.dupe(u8, line) } };
}

pub fn splitHashlineLines(allocator: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    if (text.len == 0) {
        const lines = try allocator.alloc([]const u8, 1);
        lines[0] = "";
        return lines;
    }
    var lines: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    for (text, 0..) |byte, index| {
        if (byte != '\n') continue;
        const end = if (index > start and text[index - 1] == '\r') index - 1 else index;
        try lines.append(allocator, text[start..end]);
        start = index + 1;
    }
    if (start < text.len) {
        const end = if (text.len > start and text[text.len - 1] == '\r') text.len - 1 else text.len;
        try lines.append(allocator, text[start..end]);
    }
    return lines.toOwnedSlice(allocator);
}

pub fn parseLid(allocator: Allocator, raw: []const u8, line_num: usize) Allocator.Error!types.Outcome(types.Anchor) {
    const end = trimEndIndex(raw);
    const number_start = skipWhitespace(raw, 0, end);
    const number = scanLineNumber(raw, number_start, end);
    if (number == null or skipWhitespace(raw, if (number) |n| n.next_index else number_start, end) != end) {
        return .{ .failure = types.failure(try messages.expectedLineNumberMessage(allocator, line_num, raw)) };
    }
    return .{ .success = .{ .line = number.?.line } };
}

pub const Tokenizer = struct {
    allocator: Allocator,
    buffer: std.ArrayList(u8) = .empty,
    next_line_num: usize = 1,
    closed: bool = false,

    pub const Error = Allocator.Error || error{TokenizerClosed};

    pub fn init(allocator: Allocator) Tokenizer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Tokenizer) void {
        self.buffer.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn feed(self: *Tokenizer, chunk: []const u8) Error![]const Token {
        if (self.closed) return error.TokenizerClosed;
        if (chunk.len == 0) return self.allocator.alloc(Token, 0);
        try self.buffer.appendSlice(self.allocator, chunk);
        return self.drainCompleteLines();
    }

    pub fn end(self: *Tokenizer) Allocator.Error![]const Token {
        if (self.closed) return self.allocator.alloc(Token, 0);
        self.closed = true;
        if (self.buffer.items.len == 0) return self.allocator.alloc(Token, 0);
        var stop = self.buffer.items.len;
        if (stop > 0 and self.buffer.items[stop - 1] == '\r') stop -= 1;
        const tokens = try self.allocator.alloc(Token, 1);
        tokens[0] = try classifyLine(self.allocator, self.buffer.items[0..stop], self.next_line_num);
        self.next_line_num += 1;
        self.buffer.clearRetainingCapacity();
        return tokens;
    }

    pub fn reset(self: *Tokenizer) void {
        self.buffer.clearRetainingCapacity();
        self.next_line_num = 1;
        self.closed = false;
    }

    pub fn tokenizeAll(self: *Tokenizer, text: []const u8) Error![]const Token {
        self.reset();
        const first = try self.feed(text);
        const last = try self.end();
        if (last.len == 0) return first;
        var tokens: std.ArrayList(Token) = .empty;
        try tokens.appendSlice(self.allocator, first);
        try tokens.appendSlice(self.allocator, last);
        return tokens.toOwnedSlice(self.allocator);
    }

    pub fn tokenize(self: *Tokenizer, line: []const u8, line_num: usize) Allocator.Error!Token {
        return classifyLine(self.allocator, line, line_num);
    }

    pub fn isOp(_: *const Tokenizer, line: []const u8) bool {
        return tryParseHunkHeader(line) != null;
    }

    pub fn isHeader(_: *const Tokenizer, line: []const u8) bool {
        return tryParseHeader(line) != null;
    }

    pub fn isEnvelopeMarker(_: *const Tokenizer, line: []const u8) bool {
        return markerLineEquals(line, messages.begin_patch_marker) or
            markerLineEquals(line, messages.end_patch_marker) or
            markerLineEquals(line, messages.abort_marker);
    }

    fn drainCompleteLines(self: *Tokenizer) Allocator.Error![]const Token {
        var tokens: std.ArrayList(Token) = .empty;
        var start: usize = 0;
        var index: usize = 0;
        while (index < self.buffer.items.len) : (index += 1) {
            if (self.buffer.items[index] != '\n') continue;
            const stop = if (index > start and self.buffer.items[index - 1] == '\r') index - 1 else index;
            try tokens.append(self.allocator, try classifyLine(
                self.allocator,
                self.buffer.items[start..stop],
                self.next_line_num,
            ));
            self.next_line_num += 1;
            start = index + 1;
        }
        if (start > 0) {
            const remaining = self.buffer.items.len - start;
            std.mem.copyForwards(u8, self.buffer.items[0..remaining], self.buffer.items[start..]);
            self.buffer.items.len = remaining;
        }
        return tokens.toOwnedSlice(self.allocator);
    }
};

test "hashline: tokenizer recognizes canonical and lenient hunk headers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tokenizer = Tokenizer.init(arena.allocator());
    defer tokenizer.deinit();

    const cases = [_][]const u8{
        "SWAP 2.=3:",   "SWAP 2-3:",
        "SWAP 2…3:",
        "SWAP 2 3:",    "SWAP 2..3:",
        "INS.POST 2.:", "INS.HEAD.:",
        "DEL 2.=3.",    "SWAP.BLK 2:",
        "DEL.BLK 2",    "INS.BLK.POST 2:",
    };
    for (cases) |line| try std.testing.expect(tokenizer.isOp(line));
}

test "hashline: tokenizer streams CRLF lines and uppercases section tags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tokenizer = Tokenizer.init(arena.allocator());
    defer tokenizer.deinit();

    const first = try tokenizer.feed("[dir with spaces/a.ts#1a2b]\r\nSWAP 2");
    try std.testing.expectEqual(@as(usize, 1), first.len);
    const header = first[0].header;
    try std.testing.expectEqualStrings("dir with spaces/a.ts", header.path);
    try std.testing.expectEqualStrings("1A2B", &header.file_hash.?);
    const second = try tokenizer.feed(".=2:\r\n+x");
    try std.testing.expectEqual(@as(usize, 1), second.len);
    try std.testing.expect(second[0] == .op_block);
    const last = try tokenizer.end();
    try std.testing.expectEqualStrings("x", last[0].payload_literal.text);
}
