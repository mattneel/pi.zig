//! Pure hashline edit application, including conservative boundary and landing
//! repair heuristics ported from upstream's `packages/hashline/src/apply.ts`.

const std = @import("std");
const messages = @import("messages.zig");
const types = @import("types.zig");

const AppliedEdit = types.Edit;

const Balance = struct {
    paren: isize = 0,
    bracket: isize = 0,
    brace: isize = 0,
};

const RepairResult = struct {
    edits: []const AppliedEdit,
    warnings: []const []const u8,
};

fn isReplacementInsert(edit: AppliedEdit) bool {
    return switch (edit) {
        .insert => |value| value.mode == .replacement,
        else => false,
    };
}

fn anchorLine(edit: AppliedEdit) ?usize {
    return switch (edit) {
        .insert => |value| switch (value.cursor) {
            .before_anchor => |anchor| anchor.line,
            .after_anchor => |anchor| anchor.line,
            .bof, .eof => null,
        },
        .delete => |value| value.anchor.line,
        .block => |value| value.anchor.line,
    };
}

fn cloneWithIndex(edit: AppliedEdit, index: usize) AppliedEdit {
    return switch (edit) {
        .insert => |value| blk: {
            var copy = value;
            copy.index = index;
            break :blk .{ .insert = copy };
        },
        .delete => |value| blk: {
            var copy = value;
            copy.index = index;
            break :blk .{ .delete = copy };
        },
        .block => |value| .{ .block = value },
    };
}

fn splitLines(allocator: std.mem.Allocator, text: []const u8) !std.ArrayList([]const u8) {
    var lines: std.ArrayList([]const u8) = .empty;
    var iterator = std.mem.splitScalar(u8, text, '\n');
    while (iterator.next()) |line| try lines.append(allocator, line);
    return lines;
}

fn trailingPhantomLine(file_lines: []const []const u8) usize {
    if (file_lines.len > 1 and file_lines[file_lines.len - 1].len == 0) return file_lines.len;
    return 0;
}

fn prepareEdits(
    allocator: std.mem.Allocator,
    edits: []const types.Edit,
    file_lines: []const []const u8,
) !types.Outcome([]const AppliedEdit) {
    const phantom = trailingPhantomLine(file_lines);
    var prepared: std.ArrayList(AppliedEdit) = .empty;
    for (edits, 0..) |edit, index| {
        switch (edit) {
            .block => return .{ .failure = types.failure(messages.unresolved_block_internal) },
            .delete => |value| {
                if (phantom != 0 and value.anchor.line == phantom) continue;
            },
            else => {},
        }
        const line = anchorLine(edit);
        if (line) |target| {
            if (target < 1 or target > file_lines.len) {
                const message = try messages.lineOutOfBoundsMessage(allocator, target, file_lines.len);
                return .{ .failure = types.failure(message) };
            }
        }
        try prepared.append(allocator, cloneWithIndex(edit, index));
    }
    return .{ .success = try prepared.toOwnedSlice(allocator) };
}

fn isAsciiWhitespace(byte: u8) bool {
    return byte == ' ' or (byte >= '\t' and byte <= '\r');
}

/// Byte width of ECMAScript `\s` at `index`, or zero when the next scalar is
/// not one of the code points matched by JavaScript regular expressions.
///
/// Keep this separate from `isAsciiWhitespace`: upstream deliberately uses an
/// ASCII-only predicate for delimiter balance and indentation, but its closer
/// classifiers are regular expressions and therefore use ECMAScript `\s`.
fn jsRegexWhitespaceWidthAt(text: []const u8, index: usize) usize {
    if (index >= text.len) return 0;
    const byte = text[index];
    if (byte == ' ' or (byte >= '\t' and byte <= '\r')) return 1;
    if (index + 2 <= text.len and byte == 0xc2 and text[index + 1] == 0xa0) return 2; // U+00A0
    if (index + 3 > text.len) return 0;
    const tail = text[index .. index + 3];
    if (std.mem.eql(u8, tail, "\xe1\x9a\x80")) return 3; // U+1680
    if (tail[0] == 0xe2 and tail[1] == 0x80) {
        if (tail[2] >= 0x80 and tail[2] <= 0x8a) return 3; // U+2000..U+200A
        if (tail[2] == 0xa8 or tail[2] == 0xa9 or tail[2] == 0xaf) return 3; // U+2028, U+2029, U+202F
    }
    if (std.mem.eql(u8, tail, "\xe2\x81\x9f")) return 3; // U+205F
    if (std.mem.eql(u8, tail, "\xe3\x80\x80")) return 3; // U+3000
    if (std.mem.eql(u8, tail, "\xef\xbb\xbf")) return 3; // U+FEFF
    return 0;
}

fn jsRegexWhitespaceWidthBefore(text: []const u8, end: usize) usize {
    if (end == 0) return 0;
    const byte = text[end - 1];
    if (byte == ' ' or (byte >= '\t' and byte <= '\r')) return 1;
    if (end >= 2 and text[end - 2] == 0xc2 and byte == 0xa0) return 2;
    if (end < 3) return 0;
    const width = jsRegexWhitespaceWidthAt(text, end - 3);
    return if (width == 3) width else 0;
}

fn trimJsRegexWhitespaceEnd(text: []const u8, start: usize, initial_end: usize) usize {
    var end = initial_end;
    while (end > start) {
        const width = jsRegexWhitespaceWidthBefore(text, end);
        if (width == 0 or width > end - start) break;
        end -= width;
    }
    return end;
}

fn trimJsRegexWhitespaceBounds(text: []const u8) struct { start: usize, end: usize } {
    var start: usize = 0;
    while (start < text.len) {
        const width = jsRegexWhitespaceWidthAt(text, start);
        if (width == 0) break;
        start += width;
    }
    const end = trimJsRegexWhitespaceEnd(text, start, text.len);
    return .{ .start = start, .end = end };
}

fn hasNonWhitespace(text: []const u8) bool {
    for (text) |byte| if (!isAsciiWhitespace(byte)) return true;
    return false;
}

/// Upstream's exported `STRUCTURAL_CLOSER_RE`: bracket-only closing lines.
pub fn isStructuralCloserLine(text: []const u8) bool {
    const bounds = trimJsRegexWhitespaceBounds(text);
    var index = bounds.start;
    var saw_closer = false;
    while (index < bounds.end) : (index += 1) {
        switch (text[index]) {
            ')', ']', '}' => saw_closer = true,
            else => break,
        }
    }
    if (!saw_closer) return false;
    if (index < bounds.end and (text[index] == ';' or text[index] == ',')) index += 1;
    return index == bounds.end;
}

const isStructuralCloser = isStructuralCloserLine;

fn isAsciiLetter(byte: u8) bool {
    return (byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z');
}

fn isJsxNameByte(byte: u8) bool {
    return isAsciiLetter(byte) or (byte >= '0' and byte <= '9') or byte == '_' or byte == '.' or byte == ':' or byte == '-';
}

fn jsxCore(text: []const u8) []const u8 {
    const bounds = trimJsRegexWhitespaceBounds(text);
    var end = bounds.end;
    if (end > bounds.start and (text[end - 1] == ';' or text[end - 1] == ',')) {
        end -= 1;
        end = trimJsRegexWhitespaceEnd(text, bounds.start, end);
    }
    return text[bounds.start..end];
}

fn isJsxCloser(text: []const u8) bool {
    const core = jsxCore(text);
    if (std.mem.eql(u8, core, "</>") or std.mem.eql(u8, core, "/>")) return true;
    if (core.len < 4 or !std.mem.startsWith(u8, core, "</") or core[core.len - 1] != '>') return false;
    if (!isAsciiLetter(core[2])) return false;
    for (core[3 .. core.len - 1]) |byte| if (!isJsxNameByte(byte)) return false;
    return true;
}

fn isStructuralBoundaryCloser(text: []const u8) bool {
    return isStructuralCloser(text) or isJsxCloser(text);
}

fn jsxCloserName(text: []const u8) ?[]const u8 {
    const core = jsxCore(text);
    if (std.mem.eql(u8, core, "</>")) return "";
    if (!isJsxCloser(core) or std.mem.eql(u8, core, "/>")) return null;
    return core[2 .. core.len - 1];
}

const JsxTag = struct {
    name: []const u8,
    closing: bool,
    self_closing: bool,
};

fn isJsxTagStart(text: []const u8, index: usize) bool {
    if (index + 1 >= text.len) return false;
    const next = text[index + 1];
    return next == '>' or next == '/' or isAsciiLetter(next);
}

fn findJsxTagEnd(text: []const u8, start: usize) ?usize {
    var quote: ?u8 = null;
    var braces: usize = 0;
    var index = start + 1;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (quote) |delimiter| {
            if (byte == '\\' and index + 1 < text.len) {
                index += 1;
            } else if (byte == delimiter) {
                quote = null;
            }
            continue;
        }
        if (byte == '"' or byte == '\'' or byte == '`') {
            quote = byte;
        } else if (byte == '{') {
            braces += 1;
        } else if (byte == '}' and braces > 0) {
            braces -= 1;
        } else if (byte == '>' and braces == 0) {
            return index;
        }
    }
    return null;
}

fn parseJsxTag(raw: []const u8) ?JsxTag {
    if (std.mem.eql(u8, raw, "<>")) return .{ .name = "", .closing = false, .self_closing = false };
    if (std.mem.eql(u8, raw, "</>")) return .{ .name = "", .closing = true, .self_closing = false };
    const closing = std.mem.startsWith(u8, raw, "</");
    const name_start: usize = if (closing) 2 else 1;
    var name_end = name_start;
    while (name_end < raw.len and isJsxNameByte(raw[name_end])) name_end += 1;
    if (name_end == name_start) return null;
    const end = trimJsRegexWhitespaceEnd(raw, 0, raw.len);
    return .{
        .name = raw[name_start..name_end],
        .closing = closing,
        .self_closing = !closing and end >= 2 and raw[end - 2] == '/' and raw[end - 1] == '>',
    };
}

fn joinLines(allocator: std.mem.Allocator, lines: []const []const u8) ![]const u8 {
    return std.mem.join(allocator, "\n", lines);
}

fn payloadHasJsxOpenerForEcho(
    allocator: std.mem.Allocator,
    payload_prefix: []const []const u8,
    echo_lines: []const []const u8,
) !bool {
    const text = try joinLines(allocator, payload_prefix);
    var open_tags: std.ArrayList([]const u8) = .empty;
    var search_start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, search_start, '<')) |start| {
        search_start = start + 1;
        if (!isJsxTagStart(text, start)) continue;
        const end = findJsxTagEnd(text, start) orelse break;
        if (parseJsxTag(text[start .. end + 1])) |tag| {
            if (tag.closing) {
                if (open_tags.items.len > 0 and std.mem.eql(u8, open_tags.items[open_tags.items.len - 1], tag.name)) {
                    open_tags.items.len -= 1;
                }
            } else if (!tag.self_closing) {
                try open_tags.append(allocator, tag.name);
            }
        }
        search_start = end + 1;
    }
    for (echo_lines) |line| {
        const name = jsxCloserName(line) orelse continue;
        for (open_tags.items) |open_name| {
            if (std.mem.eql(u8, open_name, name)) return true;
        }
    }
    return false;
}

fn computeDelimiterBalance(lines: []const []const u8) Balance {
    var balance: Balance = .{};
    var in_block_comment = false;
    var quote: ?u8 = null;
    for (lines) |line| {
        var index: usize = 0;
        while (index < line.len) : (index += 1) {
            const byte = line[index];
            if (in_block_comment) {
                if (byte == '*' and index + 1 < line.len and line[index + 1] == '/') {
                    in_block_comment = false;
                    index += 1;
                }
                continue;
            }
            if (quote) |delimiter| {
                if (byte == '\\') {
                    if (index + 1 < line.len) index += 1;
                } else if (byte == delimiter) {
                    quote = null;
                }
                continue;
            }
            if (byte == '"' or byte == '\'' or byte == '`') {
                quote = byte;
                continue;
            }
            if (byte == '/' and index + 1 < line.len and line[index + 1] == '/') break;
            if (byte == '/' and index + 1 < line.len and line[index + 1] == '*') {
                in_block_comment = true;
                index += 1;
                continue;
            }
            switch (byte) {
                '(' => balance.paren += 1,
                ')' => balance.paren -= 1,
                '[' => balance.bracket += 1,
                ']' => balance.bracket -= 1,
                '{' => balance.brace += 1,
                '}' => balance.brace -= 1,
                else => {},
            }
        }
        if (quote == '"' or quote == '\'') quote = null;
    }
    return balance;
}

fn balanceDelta(a: Balance, b: Balance) Balance {
    return .{ .paren = a.paren - b.paren, .bracket = a.bracket - b.bracket, .brace = a.brace - b.brace };
}

fn balanceNegate(value: Balance) Balance {
    return .{ .paren = -value.paren, .bracket = -value.bracket, .brace = -value.brace };
}

fn balanceEqual(a: Balance, b: Balance) bool {
    return a.paren == b.paren and a.bracket == b.bracket and a.brace == b.brace;
}

fn balanceIsZero(value: Balance) bool {
    return value.paren == 0 and value.bracket == 0 and value.brace == 0;
}

fn balanceSum(a: Balance, b: Balance) Balance {
    return .{ .paren = a.paren + b.paren, .bracket = a.bracket + b.bracket, .brace = a.brace + b.brace };
}

fn componentCovers(candidate: isize, target: isize) bool {
    if (target == 0) return true;
    return (candidate > 0) == (target > 0) and @abs(candidate) >= @abs(target);
}

fn balanceCovers(candidate: Balance, target: Balance) bool {
    return componentCovers(candidate.paren, target.paren) and
        componentCovers(candidate.bracket, target.bracket) and
        componentCovers(candidate.brace, target.brace);
}

const ReplacementGroup = struct {
    insert_start: usize,
    insert_end: usize,
    delete_start: usize,
    delete_end: usize,
    payload: []const []const u8,
    start_line: usize,
    end_line: usize,
};

fn findReplacementGroup(
    allocator: std.mem.Allocator,
    edits: []const AppliedEdit,
    start: usize,
) !?ReplacementGroup {
    if (start >= edits.len) return null;
    const first = switch (edits[start]) {
        .insert => |value| value,
        else => return null,
    };
    if (first.mode != .replacement) return null;
    const anchor = switch (first.cursor) {
        .before_anchor => |value| value.line,
        else => return null,
    };
    const source_line = first.source_line;
    var payload: std.ArrayList([]const u8) = .empty;
    var index = start;
    while (index < edits.len) : (index += 1) {
        const insert = switch (edits[index]) {
            .insert => |value| value,
            else => break,
        };
        if (insert.mode != .replacement or insert.source_line != source_line) break;
        const line = switch (insert.cursor) {
            .before_anchor => |value| value.line,
            else => break,
        };
        if (line != anchor) break;
        try payload.append(allocator, insert.text);
    }
    const insert_end = index;
    var expected_line = anchor;
    while (index < edits.len) : (index += 1) {
        const deletion = switch (edits[index]) {
            .delete => |value| value,
            else => break,
        };
        if (deletion.source_line != source_line or deletion.anchor.line != expected_line) break;
        expected_line += 1;
    }
    if (index == insert_end) return null;
    return .{
        .insert_start = start,
        .insert_end = insert_end,
        .delete_start = insert_end,
        .delete_end = index,
        .payload = try payload.toOwnedSlice(allocator),
        .start_line = anchor,
        .end_line = expected_line - 1,
    };
}

fn findDuplicateSuffix(group: ReplacementGroup, file_lines: []const []const u8, delta: Balance) usize {
    if (balanceIsZero(delta)) return 0;
    const max_count = @min(group.payload.len, file_lines.len - group.end_line);
    var count = max_count;
    while (count >= 1) : (count -= 1) {
        var matches = true;
        for (0..count) |offset| {
            if (!std.mem.eql(
                u8,
                group.payload[group.payload.len - count + offset],
                file_lines[group.end_line + offset],
            )) {
                matches = false;
                break;
            }
        }
        if (matches and balanceEqual(computeDelimiterBalance(group.payload[group.payload.len - count ..]), delta)) return count;
    }
    return 0;
}

fn findDuplicatePrefix(group: ReplacementGroup, file_lines: []const []const u8, delta: Balance) usize {
    if (balanceIsZero(delta)) return 0;
    const max_count = @min(group.payload.len, group.start_line - 1);
    var count = max_count;
    while (count >= 1) : (count -= 1) {
        var matches = true;
        for (0..count) |offset| {
            if (!std.mem.eql(
                u8,
                group.payload[offset],
                file_lines[group.start_line - 1 - count + offset],
            )) {
                matches = false;
                break;
            }
        }
        if (matches and balanceEqual(computeDelimiterBalance(group.payload[0..count]), delta)) return count;
    }
    return 0;
}

const BoundaryEcho = struct {
    leading: usize,
    trailing: usize,
};

fn countDuplicateLeadingBoundaryLines(group: ReplacementGroup, file_lines: []const []const u8) usize {
    const max_count = @min(group.payload.len, group.start_line - 1);
    var count = max_count;
    while (count >= 1) : (count -= 1) {
        var matches = true;
        var has_content = false;
        for (0..count) |offset| {
            const line = group.payload[offset];
            if (!std.mem.eql(u8, line, file_lines[group.start_line - 1 - count + offset])) {
                matches = false;
                break;
            }
            has_content = has_content or hasNonWhitespace(line);
        }
        if (matches and has_content) return count;
    }
    return 0;
}

fn countDuplicateTrailingBoundaryLines(group: ReplacementGroup, file_lines: []const []const u8) usize {
    const max_count = @min(group.payload.len, file_lines.len - group.end_line);
    var count = max_count;
    while (count >= 1) : (count -= 1) {
        var matches = true;
        var has_content = false;
        for (0..count) |offset| {
            const line = group.payload[group.payload.len - count + offset];
            if (!std.mem.eql(u8, line, file_lines[group.end_line + offset])) {
                matches = false;
                break;
            }
            has_content = has_content or hasNonWhitespace(line);
        }
        if (matches and has_content) return count;
    }
    return 0;
}

fn findBoundaryEcho(group: ReplacementGroup, file_lines: []const []const u8) ?BoundaryEcho {
    const leading = countDuplicateLeadingBoundaryLines(group, file_lines);
    if (leading == 0) return null;
    const trailing = countDuplicateTrailingBoundaryLines(group, file_lines);
    if (trailing == 0 or leading + trailing >= group.payload.len) return null;

    const leading_balance = computeDelimiterBalance(group.payload[0..leading]);
    const trailing_balance = computeDelimiterBalance(group.payload[group.payload.len - trailing ..]);
    const dropped_balance = balanceDelta(leading_balance, balanceNegate(trailing_balance));
    if (!balanceIsZero(dropped_balance)) {
        const delta = balanceDelta(
            computeDelimiterBalance(group.payload),
            computeDelimiterBalance(file_lines[group.start_line - 1 .. group.end_line]),
        );
        if (!balanceEqual(dropped_balance, delta)) return null;
    }
    return .{ .leading = leading, .trailing = trailing };
}

const OneSidedEcho = struct {
    leading: bool,
    count: usize,
};

fn findOneSidedBoundaryEcho(
    allocator: std.mem.Allocator,
    group: ReplacementGroup,
    file_lines: []const []const u8,
) !?OneSidedEcho {
    const leading = countDuplicateLeadingBoundaryLines(group, file_lines);
    const trailing = countDuplicateTrailingBoundaryLines(group, file_lines);
    if ((leading > 0) == (trailing > 0)) return null;
    const is_leading = leading > 0;
    const count = if (is_leading) leading else trailing;
    if (count >= group.payload.len) return null;
    const echo_lines = if (is_leading)
        group.payload[0..count]
    else
        group.payload[group.payload.len - count ..];
    if (!balanceIsZero(computeDelimiterBalance(echo_lines))) return null;
    if (group.delete_end - group.delete_start <= 1) {
        if (is_leading) return null;
        for (echo_lines) |line| if (!isStructuralBoundaryCloser(line)) return null;
        const payload_prefix = group.payload[0 .. group.payload.len - count];
        if (try payloadHasJsxOpenerForEcho(allocator, payload_prefix, echo_lines)) return null;
    }
    return .{ .leading = is_leading, .count = count };
}

fn concatEdits(
    allocator: std.mem.Allocator,
    first: []const AppliedEdit,
    second: []const AppliedEdit,
) ![]const AppliedEdit {
    var output: std.ArrayList(AppliedEdit) = .empty;
    try output.ensureTotalCapacity(allocator, first.len + second.len);
    try output.appendSlice(allocator, first);
    try output.appendSlice(allocator, second);
    return output.toOwnedSlice(allocator);
}

const RepairSlotKind = enum { edits, candidate };

const RepairSlot = struct {
    kind: RepairSlotKind,
    edits: []const AppliedEdit = &.{},
    warning: ?[]const u8 = null,
    group: ?ReplacementGroup = null,
    inserts: []const AppliedEdit = &.{},
    deletes: []const AppliedEdit = &.{},
    delta: Balance = .{},
};

fn slotPatchDelta(slot: RepairSlot, file_lines: []const []const u8, allocator: std.mem.Allocator) !Balance {
    if (slot.kind == .candidate) return slot.delta;
    var inserted: std.ArrayList([]const u8) = .empty;
    var deleted: std.ArrayList([]const u8) = .empty;
    for (slot.edits) |edit| switch (edit) {
        .insert => |value| try inserted.append(allocator, value.text),
        .delete => |value| try deleted.append(allocator, file_lines[value.anchor.line - 1]),
        .block => unreachable,
    };
    return balanceDelta(computeDelimiterBalance(inserted.items), computeDelimiterBalance(deleted.items));
}

const InsertSide = enum { any, before, after };

fn appendAnchoredInsertTexts(
    allocator: std.mem.Allocator,
    output: *std.ArrayList([]const u8),
    edits: []const AppliedEdit,
    line: usize,
    side: InsertSide,
) !bool {
    for (edits) |edit| {
        const insert = switch (edit) {
            .insert => |value| value,
            else => continue,
        };
        const matches = switch (insert.cursor) {
            .before_anchor => |anchor| anchor.line == line and side != .after,
            .after_anchor => |anchor| anchor.line == line and side != .before,
            .bof, .eof => false,
        };
        if (!matches) continue;
        try output.append(allocator, insert.text);
    }
    return true;
}

fn appendCloserInsertTexts(
    allocator: std.mem.Allocator,
    output: *std.ArrayList([]const u8),
    edits: []const AppliedEdit,
    line: usize,
    side: InsertSide,
) !bool {
    for (edits) |edit| {
        const insert = switch (edit) {
            .insert => |value| value,
            else => continue,
        };
        const matches = switch (insert.cursor) {
            .before_anchor => |anchor| anchor.line == line and side == .before,
            .after_anchor => |anchor| anchor.line == line and side == .after,
            .bof, .eof => false,
        };
        if (!matches) continue;
        if (!isStructuralCloser(insert.text)) return false;
        try output.append(allocator, insert.text);
    }
    return true;
}

fn countPayloadRestatedSuffixHead(payload: []const []const u8, suffix_lines: []const []const u8) usize {
    const max_count = @min(payload.len, suffix_lines.len);
    var count = max_count;
    while (count >= 1) : (count -= 1) {
        var matches = true;
        for (0..count) |offset| {
            if (!std.mem.eql(u8, payload[payload.len - count + offset], suffix_lines[offset])) {
                matches = false;
                break;
            }
        }
        if (matches) return count;
    }
    return 0;
}

fn countProjectedBelowSuffixTail(
    allocator: std.mem.Allocator,
    group: ReplacementGroup,
    file_lines: []const []const u8,
    deleted_lines: []const bool,
    projected: []const AppliedEdit,
    suffix_lines: []const []const u8,
) !usize {
    var below: std.ArrayList([]const u8) = .empty;
    if (!try appendCloserInsertTexts(allocator, &below, projected, group.end_line, .after)) return 0;
    var line = group.end_line + 1;
    while (line <= file_lines.len) : (line += 1) {
        if (!try appendCloserInsertTexts(allocator, &below, projected, line, .before)) break;
        if (!deleted_lines[line]) {
            const text = file_lines[line - 1];
            if (!isStructuralCloser(text)) break;
            try below.append(allocator, text);
        }
        if (!try appendCloserInsertTexts(allocator, &below, projected, line, .after)) break;
    }
    const max_count = @min(below.items.len, suffix_lines.len);
    var count = max_count;
    while (count >= 1) : (count -= 1) {
        var matches = true;
        for (0..count) |offset| {
            if (!std.mem.eql(
                u8,
                below.items[offset],
                suffix_lines[suffix_lines.len - count + offset],
            )) {
                matches = false;
                break;
            }
        }
        if (matches) return count;
    }
    return 0;
}

fn computeProjectedPrefixBalance(
    allocator: std.mem.Allocator,
    group: ReplacementGroup,
    file_lines: []const []const u8,
    deleted_lines: []const bool,
    projected: []const AppliedEdit,
) !Balance {
    var prefix: std.ArrayList([]const u8) = .empty;
    var line: usize = 1;
    while (line < group.start_line) : (line += 1) {
        _ = try appendAnchoredInsertTexts(allocator, &prefix, projected, line, .any);
        if (!deleted_lines[line]) try prefix.append(allocator, file_lines[line - 1]);
    }
    _ = try appendAnchoredInsertTexts(allocator, &prefix, projected, group.start_line, .before);
    try prefix.appendSlice(allocator, group.payload);
    return computeDelimiterBalance(prefix.items);
}

fn prefixCanCoverSuffixClosers(
    allocator: std.mem.Allocator,
    group: ReplacementGroup,
    file_lines: []const []const u8,
    suffix_balance: Balance,
    covered_below_balance: Balance,
    deleted_lines: []const bool,
    projected: []const AppliedEdit,
) !bool {
    const needed_openers = balanceNegate(suffix_balance);
    const prefix_balance = try computeProjectedPrefixBalance(
        allocator,
        group,
        file_lines,
        deleted_lines,
        projected,
    );
    return balanceCovers(balanceSum(prefix_balance, covered_below_balance), needed_openers);
}

fn netDeletedPrefixBalance(
    allocator: std.mem.Allocator,
    group: ReplacementGroup,
    deleted_lines: []const bool,
    projected: []const AppliedEdit,
    file_lines: []const []const u8,
) !Balance {
    var low = group.start_line;
    while (low > 1 and deleted_lines[low - 1]) low -= 1;
    var deleted: std.ArrayList([]const u8) = .empty;
    var inserted: std.ArrayList([]const u8) = .empty;
    var line = low;
    while (line < group.start_line) : (line += 1) {
        try deleted.append(allocator, file_lines[line - 1]);
        _ = try appendAnchoredInsertTexts(allocator, &inserted, projected, line, .any);
    }
    return balanceDelta(computeDelimiterBalance(deleted.items), computeDelimiterBalance(inserted.items));
}

const DroppedSuffixClosers = struct {
    start_line: usize,
    count: usize,
    balance: Balance,
};

fn findDroppedSuffixClosers(
    allocator: std.mem.Allocator,
    group: ReplacementGroup,
    file_lines: []const []const u8,
    delta: Balance,
    remaining_delta: Balance,
    deleted_prefix_balance: Balance,
    deleted_lines: []const bool,
    projected: []const AppliedEdit,
) !?DroppedSuffixClosers {
    var suffix_length: usize = 0;
    const delete_count = group.delete_end - group.delete_start;
    while (suffix_length < delete_count and
        isStructuralCloser(file_lines[group.end_line - suffix_length - 1]))
    {
        suffix_length += 1;
    }
    if (suffix_length == 0) return null;

    const suffix_start_line = group.end_line - suffix_length + 1;
    const suffix_lines = file_lines[group.end_line - suffix_length .. group.end_line];
    const restated_head = countPayloadRestatedSuffixHead(group.payload, suffix_lines);
    const covered_tail = try countProjectedBelowSuffixTail(
        allocator,
        group,
        file_lines,
        deleted_lines,
        projected,
        suffix_lines,
    );
    const keep_start = restated_head;
    const keep_end = suffix_length - covered_tail;
    if (keep_start >= keep_end) return null;

    const kept_lines = suffix_lines[keep_start..keep_end];
    const kept_balance = computeDelimiterBalance(kept_lines);
    const needed_openers = balanceNegate(kept_balance);
    const covered_below_balance = computeDelimiterBalance(suffix_lines[keep_end..]);
    if (!balanceCovers(delta, needed_openers)) return null;
    if (balanceCovers(deleted_prefix_balance, needed_openers)) return null;
    if (!balanceCovers(remaining_delta, needed_openers)) return null;
    if (!try prefixCanCoverSuffixClosers(
        allocator,
        group,
        file_lines,
        kept_balance,
        covered_below_balance,
        deleted_lines,
        projected,
    )) return null;

    return .{
        .start_line = suffix_start_line + keep_start,
        .count = keep_end - keep_start,
        .balance = kept_balance,
    };
}

fn repairReplacementBoundaries(
    allocator: std.mem.Allocator,
    edits: []const AppliedEdit,
    file_lines: []const []const u8,
) !RepairResult {
    var slots: std.ArrayList(RepairSlot) = .empty;
    var index: usize = 0;
    while (index < edits.len) {
        const maybe_group = try findReplacementGroup(allocator, edits, index);
        if (maybe_group == null) {
            try slots.append(allocator, .{ .kind = .edits, .edits = edits[index .. index + 1] });
            index += 1;
            continue;
        }
        const group = maybe_group.?;
        const inserts = edits[group.insert_start..group.insert_end];
        const deletes = edits[group.delete_start..group.delete_end];
        index = group.delete_end;

        if (findBoundaryEcho(group, file_lines)) |echo| {
            const repaired = try concatEdits(
                allocator,
                inserts[echo.leading .. inserts.len - echo.trailing],
                deletes,
            );
            try slots.append(allocator, .{
                .kind = .edits,
                .edits = repaired,
                .warning = try messages.boundaryEchoRepair(allocator, group.start_line, echo.leading, echo.trailing),
            });
            continue;
        }

        const delta = balanceDelta(
            computeDelimiterBalance(group.payload),
            computeDelimiterBalance(file_lines[group.start_line - 1 .. group.end_line]),
        );
        if (balanceIsZero(delta)) {
            if (try findOneSidedBoundaryEcho(allocator, group, file_lines)) |echo| {
                const trimmed = if (echo.leading)
                    inserts[echo.count..]
                else
                    inserts[0 .. inserts.len - echo.count];
                try slots.append(allocator, .{
                    .kind = .edits,
                    .edits = try concatEdits(allocator, trimmed, deletes),
                    .warning = try messages.oneSidedBoundaryEchoRepair(
                        allocator,
                        group.start_line,
                        echo.leading,
                        echo.count,
                    ),
                });
                continue;
            }
            try slots.append(allocator, .{
                .kind = .edits,
                .edits = try concatEdits(allocator, inserts, deletes),
            });
            continue;
        }

        const duplicate_suffix = findDuplicateSuffix(group, file_lines, delta);
        if (duplicate_suffix > 0) {
            const action = try messages.duplicatedTrailingPayloadAction(allocator, duplicate_suffix);
            try slots.append(allocator, .{
                .kind = .edits,
                .edits = try concatEdits(allocator, inserts[0 .. inserts.len - duplicate_suffix], deletes),
                .warning = try messages.delimiterBalanceRepair(allocator, group.start_line, action),
            });
            continue;
        }

        const duplicate_prefix = findDuplicatePrefix(group, file_lines, delta);
        if (duplicate_prefix > 0) {
            const action = try messages.duplicatedLeadingPayloadAction(allocator, duplicate_prefix);
            try slots.append(allocator, .{
                .kind = .edits,
                .edits = try concatEdits(allocator, inserts[duplicate_prefix..], deletes),
                .warning = try messages.delimiterBalanceRepair(allocator, group.start_line, action),
            });
            continue;
        }

        try slots.append(allocator, .{
            .kind = .candidate,
            .group = group,
            .inserts = inserts,
            .deletes = deletes,
            .delta = delta,
        });
    }

    var projected: std.ArrayList(AppliedEdit) = .empty;
    for (slots.items) |slot| {
        if (slot.kind == .candidate) {
            try projected.appendSlice(allocator, slot.inserts);
            try projected.appendSlice(allocator, slot.deletes);
        } else {
            try projected.appendSlice(allocator, slot.edits);
        }
    }

    const deleted_lines = try allocator.alloc(bool, file_lines.len + 1);
    @memset(deleted_lines, false);
    for (projected.items) |edit| switch (edit) {
        .delete => |value| deleted_lines[value.anchor.line] = true,
        else => {},
    };

    var remaining_delta: Balance = .{};
    for (slots.items) |slot| {
        remaining_delta = balanceSum(remaining_delta, try slotPatchDelta(slot, file_lines, allocator));
    }

    var output: std.ArrayList(AppliedEdit) = .empty;
    var warnings: std.ArrayList([]const u8) = .empty;
    for (slots.items) |slot| {
        if (slot.kind == .edits) {
            if (slot.warning) |warning| try warnings.append(allocator, warning);
            try output.appendSlice(allocator, slot.edits);
            continue;
        }
        const group = slot.group.?;
        const deleted_prefix_balance = try netDeletedPrefixBalance(
            allocator,
            group,
            deleted_lines,
            projected.items,
            file_lines,
        );
        const dropped = try findDroppedSuffixClosers(
            allocator,
            group,
            file_lines,
            slot.delta,
            remaining_delta,
            deleted_prefix_balance,
            deleted_lines,
            projected.items,
        );
        if (dropped) |closers| {
            const action = try messages.keptStructuralClosersAction(allocator, closers.count);
            try warnings.append(
                allocator,
                try messages.delimiterBalanceRepair(allocator, group.start_line, action),
            );
            try output.appendSlice(allocator, slot.inserts);
            for (slot.deletes) |edit| {
                const line = switch (edit) {
                    .delete => |value| value.anchor.line,
                    else => unreachable,
                };
                if (line >= closers.start_line and line < closers.start_line + closers.count) continue;
                try output.append(allocator, edit);
            }
            var line = closers.start_line;
            while (line < closers.start_line + closers.count) : (line += 1) deleted_lines[line] = false;
            remaining_delta = balanceSum(remaining_delta, closers.balance);
            continue;
        }
        try output.appendSlice(allocator, slot.inserts);
        try output.appendSlice(allocator, slot.deletes);
    }

    return .{
        .edits = try output.toOwnedSlice(allocator),
        .warnings = if (warnings.items.len == 0) &.{} else try warnings.toOwnedSlice(allocator),
    };
}

fn leadingIndent(line: []const u8) []const u8 {
    var end: usize = 0;
    while (end < line.len and (line[end] == ' ' or line[end] == '\t')) end += 1;
    return line[0..end];
}

fn isIndentDeeper(deeper: []const u8, shallower: []const u8) bool {
    return deeper.len > shallower.len and std.mem.startsWith(u8, deeper, shallower);
}

const AfterInsertGroup = struct {
    anchor: usize,
    source_line: usize,
    members: std.ArrayList(usize),
    block_start: ?usize,
};

fn bodyTargetIndent(
    allocator: std.mem.Allocator,
    group: AfterInsertGroup,
    edits: []const AppliedEdit,
) !?[]const u8 {
    var non_blank: std.ArrayList([]const u8) = .empty;
    for (group.members.items) |member| {
        const text = switch (edits[member]) {
            .insert => |value| value.text,
            else => unreachable,
        };
        if (hasNonWhitespace(text)) try non_blank.append(allocator, text);
    }
    if (non_blank.items.len == 0) return null;
    var all_closers = true;
    for (non_blank.items) |row| all_closers = all_closers and isStructuralCloser(row);
    if (all_closers) return null;

    var target = leadingIndent(non_blank.items[0]);
    for (non_blank.items) |row| {
        const indent = leadingIndent(row);
        if (std.mem.startsWith(u8, indent, target)) continue;
        if (std.mem.startsWith(u8, target, indent)) {
            target = indent;
        } else {
            return null;
        }
    }
    return target;
}

const OutwardLanding = struct {
    line: usize,
    crossed: usize,
};

fn resolveShiftedLanding(
    group: AfterInsertGroup,
    target: []const u8,
    file_lines: []const []const u8,
    targeted_lines: []const bool,
) ?OutwardLanding {
    const anchor_text = file_lines[group.anchor - 1];
    if (!hasNonWhitespace(anchor_text) or !isIndentDeeper(leadingIndent(anchor_text), target)) return null;

    var landing = group.anchor;
    var crossed: usize = 0;
    var line = group.anchor + 1;
    while (line <= file_lines.len) : (line += 1) {
        const text = file_lines[line - 1];
        if (!hasNonWhitespace(text)) continue;
        if (!isStructuralCloser(text)) break;
        const indent = leadingIndent(text);
        if (!std.mem.startsWith(u8, indent, target)) break;
        if (targeted_lines[line]) return null;
        landing = line;
        crossed += 1;
        if (indent.len == target.len) break;
    }
    if (landing == group.anchor) return null;
    return .{ .line = landing, .crossed = crossed };
}

fn resolveInwardLanding(
    group: AfterInsertGroup,
    target: []const u8,
    block_start: usize,
    file_lines: []const []const u8,
    targeted_lines: []const bool,
) ?usize {
    const anchor_text = file_lines[group.anchor - 1];
    if (!hasNonWhitespace(anchor_text) or !isStructuralCloser(anchor_text)) return null;
    if (!isIndentDeeper(target, leadingIndent(anchor_text))) return null;

    var landing = group.anchor;
    var line = group.anchor;
    while (line > block_start) : (line -= 1) {
        const text = file_lines[line - 1];
        if (!hasNonWhitespace(text)) {
            landing = line - 1;
            continue;
        }
        if (!isStructuralCloser(text)) break;
        const indent = leadingIndent(text);
        if (!isIndentDeeper(target, indent)) break;
        if (line != group.anchor and targeted_lines[line]) return null;
        landing = line - 1;
    }
    return if (landing == group.anchor) null else landing;
}

fn repairAfterInsertLandings(
    allocator: std.mem.Allocator,
    edits: []const AppliedEdit,
    file_lines: []const []const u8,
) !RepairResult {
    var groups: std.ArrayList(AfterInsertGroup) = .empty;
    for (edits, 0..) |edit, index| {
        const insert = switch (edit) {
            .insert => |value| value,
            else => continue,
        };
        if (insert.mode == .replacement) continue;
        const anchor = switch (insert.cursor) {
            .after_anchor => |value| value.line,
            else => continue,
        };
        var found: ?usize = null;
        for (groups.items, 0..) |group, group_index| {
            if (group.anchor == anchor and group.source_line == insert.source_line) {
                found = group_index;
                break;
            }
        }
        if (found) |group_index| {
            try groups.items[group_index].members.append(allocator, index);
        } else {
            var members: std.ArrayList(usize) = .empty;
            try members.append(allocator, index);
            try groups.append(allocator, .{
                .anchor = anchor,
                .source_line = insert.source_line,
                .members = members,
                .block_start = insert.block_start,
            });
        }
    }
    if (groups.items.len == 0) return .{ .edits = edits, .warnings = &.{} };

    const targeted_lines = try allocator.alloc(bool, file_lines.len + 1);
    @memset(targeted_lines, false);
    for (edits) |edit| {
        if (anchorLine(edit)) |line| targeted_lines[line] = true;
    }

    const output = try allocator.dupe(AppliedEdit, edits);
    var warnings: std.ArrayList([]const u8) = .empty;
    for (groups.items) |group| {
        const target = try bodyTargetIndent(allocator, group, edits) orelse continue;
        if (resolveShiftedLanding(group, target, file_lines, targeted_lines)) |outward| {
            for (group.members.items) |member| {
                var insert = output[member].insert;
                insert.cursor = .{ .after_anchor = .{ .line = outward.line } };
                output[member] = .{ .insert = insert };
            }
            try warnings.append(
                allocator,
                try messages.afterInsertLandingShiftWarning(
                    allocator,
                    group.anchor,
                    outward.line,
                    outward.crossed,
                ),
            );
            continue;
        }
        const block_start = group.block_start orelse continue;
        const inward = resolveInwardLanding(group, target, block_start, file_lines, targeted_lines) orelse continue;
        for (group.members.items) |member| {
            var insert = output[member].insert;
            insert.cursor = .{ .after_anchor = .{ .line = inward } };
            output[member] = .{ .insert = insert };
        }
        try warnings.append(
            allocator,
            try messages.blockInsertLandingShiftWarning(allocator, block_start, group.anchor, inward),
        );
    }
    return .{
        .edits = output,
        .warnings = if (warnings.items.len == 0) &.{} else try warnings.toOwnedSlice(allocator),
    };
}

fn trackFirstChanged(first_changed: *?usize, line: usize) void {
    if (first_changed.* == null or line < first_changed.*.?) first_changed.* = line;
}

fn insertAtStart(
    allocator: std.mem.Allocator,
    file_lines: *std.ArrayList([]const u8),
    lines: []const []const u8,
) !void {
    if (lines.len == 0) return;
    if (file_lines.items.len == 1 and file_lines.items[0].len == 0) {
        try file_lines.replaceRange(allocator, 0, 1, lines);
    } else {
        try file_lines.insertSlice(allocator, 0, lines);
    }
}

fn insertAtEnd(
    allocator: std.mem.Allocator,
    file_lines: *std.ArrayList([]const u8),
    lines: []const []const u8,
) !?usize {
    if (lines.len == 0) return null;
    if (file_lines.items.len == 1 and file_lines.items[0].len == 0) {
        try file_lines.replaceRange(allocator, 0, 1, lines);
        return 1;
    }
    const has_trailing_newline = file_lines.items.len > 0 and file_lines.items[file_lines.items.len - 1].len == 0;
    const insert_index = if (has_trailing_newline) file_lines.items.len - 1 else file_lines.items.len;
    try file_lines.insertSlice(allocator, insert_index, lines);
    return insert_index + 1;
}

fn applyConcreteEdits(
    allocator: std.mem.Allocator,
    text: []const u8,
    edits: []const AppliedEdit,
    warnings: []const []const u8,
) !types.ApplyResult {
    var file_lines = try splitLines(allocator, text);
    const original_line_count = file_lines.items.len;
    var bof_lines: std.ArrayList([]const u8) = .empty;
    var eof_lines: std.ArrayList([]const u8) = .empty;
    for (edits) |edit| switch (edit) {
        .insert => |value| switch (value.cursor) {
            .bof => try bof_lines.append(allocator, value.text),
            .eof => try eof_lines.append(allocator, value.text),
            else => {},
        },
        else => {},
    };

    var first_changed_line: ?usize = null;
    var line = original_line_count;
    while (line > 0) : (line -= 1) {
        var before: std.ArrayList([]const u8) = .empty;
        var replacement: std.ArrayList([]const u8) = .empty;
        var after: std.ArrayList([]const u8) = .empty;
        var delete_line = false;
        for (edits) |edit| switch (edit) {
            .insert => |value| {
                const target = switch (value.cursor) {
                    .before_anchor => |anchor| anchor.line,
                    .after_anchor => |anchor| anchor.line,
                    .bof, .eof => continue,
                };
                if (target != line) continue;
                if (value.mode == .replacement) {
                    try replacement.append(allocator, value.text);
                } else switch (value.cursor) {
                    .after_anchor => try after.append(allocator, value.text),
                    else => try before.append(allocator, value.text),
                }
            },
            .delete => |value| if (value.anchor.line == line) {
                delete_line = true;
            },
            .block => unreachable,
        };
        if (before.items.len == 0 and replacement.items.len == 0 and after.items.len == 0 and !delete_line) {
            continue;
        }

        const current = file_lines.items[line - 1];
        var new_lines: std.ArrayList([]const u8) = .empty;
        try new_lines.appendSlice(allocator, before.items);
        try new_lines.appendSlice(allocator, replacement.items);
        if (!delete_line) try new_lines.append(allocator, current);
        try new_lines.appendSlice(allocator, after.items);
        try file_lines.replaceRange(allocator, line - 1, 1, new_lines.items);
        trackFirstChanged(&first_changed_line, line);
    }

    if (bof_lines.items.len > 0) {
        try insertAtStart(allocator, &file_lines, bof_lines.items);
        trackFirstChanged(&first_changed_line, 1);
    }
    if (try insertAtEnd(allocator, &file_lines, eof_lines.items)) |changed_line| {
        trackFirstChanged(&first_changed_line, changed_line);
    }

    return .{
        .text = try std.mem.join(allocator, "\n", file_lines.items),
        .first_changed_line = first_changed_line,
        .warnings = warnings,
    };
}

/// Apply concrete line edits to LF-normalized text. Semantic failures are
/// returned as `.failure`; allocation failures remain ordinary Zig errors.
pub fn applyEdits(
    allocator: std.mem.Allocator,
    text: []const u8,
    edits: []const types.Edit,
) !types.Outcome(types.ApplyResult) {
    if (edits.len == 0) {
        return .{ .success = .{
            .text = try allocator.dupe(u8, text),
            .first_changed_line = null,
        } };
    }

    for (edits) |edit| switch (edit) {
        .block => return .{ .failure = types.failure(messages.unresolved_block_internal) },
        else => {},
    };

    const file_lines = try splitLines(allocator, text);
    const prepared = try prepareEdits(allocator, edits, file_lines.items);
    const concrete = switch (prepared) {
        .failure => |failure| return .{ .failure = failure },
        .success => |value| value,
    };
    const boundaries = try repairReplacementBoundaries(allocator, concrete, file_lines.items);
    const landings = try repairAfterInsertLandings(allocator, boundaries.edits, file_lines.items);
    var warnings: std.ArrayList([]const u8) = .empty;
    try warnings.appendSlice(allocator, boundaries.warnings);
    try warnings.appendSlice(allocator, landings.warnings);
    const warning_slice = if (warnings.items.len == 0) &.{} else try warnings.toOwnedSlice(allocator);
    return .{ .success = try applyConcreteEdits(allocator, text, landings.edits, warning_slice) };
}

fn expectApplySuccess(outcome: types.Outcome(types.ApplyResult)) !types.ApplyResult {
    return switch (outcome) {
        .success => |result| result,
        .failure => |failure| {
            std.debug.print("unexpected apply failure: {s}\n", .{failure.message});
            return error.UnexpectedApplyFailure;
        },
    };
}

test "hashline apply: bucket ordering preserves category and payload order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const edits = [_]types.Edit{
        .{ .insert = .{
            .cursor = .{ .after_anchor = .{ .line = 2 } },
            .text = "after",
            .source_line = 1,
            .index = 0,
        } },
        .{ .insert = .{
            .cursor = .{ .before_anchor = .{ .line = 2 } },
            .text = "before",
            .source_line = 2,
            .index = 1,
        } },
        .{ .insert = .{
            .cursor = .{ .before_anchor = .{ .line = 2 } },
            .text = "replacement",
            .source_line = 3,
            .index = 2,
            .mode = .replacement,
        } },
        .{ .delete = .{
            .anchor = .{ .line = 2 },
            .source_line = 3,
            .index = 3,
        } },
    };
    const result = try expectApplySuccess(try applyEdits(arena.allocator(), "a\nb\nc", &edits));
    try std.testing.expectEqualStrings("a\nbefore\nreplacement\nafter\nc", result.text);
    try std.testing.expectEqual(@as(?usize, 2), result.first_changed_line);
}

test "hashline apply: trailing newline phantom deletes are ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const edits = [_]types.Edit{.{ .delete = .{
        .anchor = .{ .line = 3 },
        .source_line = 1,
        .index = 0,
    } }};
    const result = try expectApplySuccess(try applyEdits(arena.allocator(), "a\nb\n", &edits));
    try std.testing.expectEqualStrings("a\nb\n", result.text);
    try std.testing.expectEqual(@as(?usize, null), result.first_changed_line);
}

test "hashline apply: out of range anchor returns exact failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const edits = [_]types.Edit{.{ .insert = .{
        .cursor = .{ .before_anchor = .{ .line = 4 } },
        .text = "x",
        .source_line = 1,
        .index = 0,
    } }};
    const outcome = try applyEdits(arena.allocator(), "a\nb", &edits);
    switch (outcome) {
        .success => return error.ExpectedApplyFailure,
        .failure => |failure| try std.testing.expectEqualStrings(
            "Line 4 does not exist (file has 2 lines)",
            failure.message,
        ),
    }
}

test "hashline apply: two-sided replacement boundary echo is dropped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const edits = [_]types.Edit{
        .{ .insert = .{
            .cursor = .{ .before_anchor = .{ .line = 2 } },
            .text = "func",
            .source_line = 1,
            .index = 0,
            .mode = .replacement,
        } },
        .{ .insert = .{
            .cursor = .{ .before_anchor = .{ .line = 2 } },
            .text = "new",
            .source_line = 1,
            .index = 1,
            .mode = .replacement,
        } },
        .{ .insert = .{
            .cursor = .{ .before_anchor = .{ .line = 2 } },
            .text = "last",
            .source_line = 1,
            .index = 2,
            .mode = .replacement,
        } },
        .{ .delete = .{ .anchor = .{ .line = 2 }, .source_line = 1, .index = 3 } },
        .{ .delete = .{ .anchor = .{ .line = 3 }, .source_line = 1, .index = 4 } },
    };
    const result = try expectApplySuccess(try applyEdits(arena.allocator(), "func\nold-a\nold-b\nlast", &edits));
    try std.testing.expectEqualStrings("func\nnew\nlast", result.text);
    try std.testing.expectEqual(@as(usize, 1), result.warnings.len);
    try std.testing.expectEqualStrings(
        "Auto-repaired a replacement boundary echo at line 2: dropped 1 leading and 1 trailing payload line(s) already present outside the range. Issue the payload as the final desired content for the selected range only — never restate unchanged lines bordering the range.",
        result.warnings[0],
    );
}

test "hashline apply: duplicated structural suffix is removed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const edits = [_]types.Edit{
        .{ .insert = .{
            .cursor = .{ .before_anchor = .{ .line = 2 } },
            .text = "\tsetup2();",
            .source_line = 1,
            .index = 0,
            .mode = .replacement,
        } },
        .{ .insert = .{
            .cursor = .{ .before_anchor = .{ .line = 2 } },
            .text = "\trun2();",
            .source_line = 1,
            .index = 1,
            .mode = .replacement,
        } },
        .{ .insert = .{
            .cursor = .{ .before_anchor = .{ .line = 2 } },
            .text = "});",
            .source_line = 1,
            .index = 2,
            .mode = .replacement,
        } },
        .{ .delete = .{ .anchor = .{ .line = 2 }, .source_line = 1, .index = 3 } },
        .{ .delete = .{ .anchor = .{ .line = 3 }, .source_line = 1, .index = 4 } },
    };
    const result = try expectApplySuccess(try applyEdits(
        arena.allocator(),
        "it('a', () => {\n\tsetup();\n\trun();\n});\nafter();",
        &edits,
    ));
    try std.testing.expectEqualStrings(
        "it('a', () => {\n\tsetup2();\n\trun2();\n});\nafter();",
        result.text,
    );
    try std.testing.expectEqual(@as(usize, 1), result.warnings.len);
    try std.testing.expect(std.mem.indexOf(u8, result.warnings[0], "duplicated trailing payload line(s)") != null);
}

test "hashline apply: missing deleted closer is preserved by second pass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const edits = [_]types.Edit{
        .{ .insert = .{
            .cursor = .{ .before_anchor = .{ .line = 5 } },
            .text = "\tb() {",
            .source_line = 1,
            .index = 0,
            .mode = .replacement,
        } },
        .{ .insert = .{
            .cursor = .{ .before_anchor = .{ .line = 5 } },
            .text = "\t\treturn 2;",
            .source_line = 1,
            .index = 1,
            .mode = .replacement,
        } },
        .{ .insert = .{
            .cursor = .{ .before_anchor = .{ .line = 5 } },
            .text = "\t},",
            .source_line = 1,
            .index = 2,
            .mode = .replacement,
        } },
        .{ .delete = .{ .anchor = .{ .line = 5 }, .source_line = 1, .index = 3 } },
    };
    const result = try expectApplySuccess(try applyEdits(
        arena.allocator(),
        "const handlers = {\n\ta() {\n\t\treturn 1;\n\t},\n};",
        &edits,
    ));
    try std.testing.expectEqualStrings(
        "const handlers = {\n\ta() {\n\t\treturn 1;\n\t},\n\tb() {\n\t\treturn 2;\n\t},\n};",
        result.text,
    );
    try std.testing.expectEqual(@as(usize, 1), result.warnings.len);
    try std.testing.expect(std.mem.indexOf(u8, result.warnings[0], "kept 1 structural closing line(s)") != null);
}

test "hashline apply: removed opener suppresses missing-closer repair" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const edits = [_]types.Edit{
        .{ .delete = .{ .anchor = .{ .line = 1 }, .source_line = 1, .index = 0 } },
        .{ .insert = .{
            .cursor = .{ .before_anchor = .{ .line = 2 } },
            .text = "Text(\"New\")",
            .source_line = 2,
            .index = 1,
            .mode = .replacement,
        } },
        .{ .delete = .{ .anchor = .{ .line = 2 }, .source_line = 2, .index = 2 } },
        .{ .delete = .{ .anchor = .{ .line = 3 }, .source_line = 2, .index = 3 } },
    };
    const result = try expectApplySuccess(try applyEdits(
        arena.allocator(),
        "if enabled {\n\tText(\"Old\")\n}\n\tText(\"Tail\")",
        &edits,
    ));
    try std.testing.expectEqualStrings("Text(\"New\")\n\tText(\"Tail\")", result.text);
    try std.testing.expectEqual(@as(usize, 0), result.warnings.len);
}

test "hashline apply: nested JSX closer echo is preserved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const edits = [_]types.Edit{
        .{ .insert = .{
            .cursor = .{ .before_anchor = .{ .line = 3 } },
            .text = "<section>",
            .source_line = 1,
            .index = 0,
            .mode = .replacement,
        } },
        .{ .insert = .{
            .cursor = .{ .before_anchor = .{ .line = 3 } },
            .text = "new text",
            .source_line = 1,
            .index = 1,
            .mode = .replacement,
        } },
        .{ .insert = .{
            .cursor = .{ .before_anchor = .{ .line = 3 } },
            .text = "</section>",
            .source_line = 1,
            .index = 2,
            .mode = .replacement,
        } },
        .{ .delete = .{ .anchor = .{ .line = 3 }, .source_line = 1, .index = 3 } },
    };
    const result = try expectApplySuccess(try applyEdits(
        arena.allocator(),
        "const view = (\n<section className=\"outer\">\nold text\n</section>\n);",
        &edits,
    ));
    try std.testing.expectEqualStrings(
        "const view = (\n<section className=\"outer\">\n<section>\nnew text\n</section>\n</section>\n);",
        result.text,
    );
    try std.testing.expectEqual(@as(usize, 0), result.warnings.len);
}

test "hashline apply: JSX closer after self-closing payload tag is dropped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const edits = [_]types.Edit{
        .{ .insert = .{
            .cursor = .{ .before_anchor = .{ .line = 3 } },
            .text = "<Foo value={a > b} />",
            .source_line = 1,
            .index = 0,
            .mode = .replacement,
        } },
        .{ .insert = .{
            .cursor = .{ .before_anchor = .{ .line = 3 } },
            .text = "</Foo>",
            .source_line = 1,
            .index = 1,
            .mode = .replacement,
        } },
        .{ .delete = .{ .anchor = .{ .line = 3 }, .source_line = 1, .index = 2 } },
    };
    const result = try expectApplySuccess(try applyEdits(
        arena.allocator(),
        "const view = (\n<Foo>\nold text\n</Foo>\n);",
        &edits,
    ));
    try std.testing.expectEqualStrings(
        "const view = (\n<Foo>\n<Foo value={a > b} />\n</Foo>\n);",
        result.text,
    );
    try std.testing.expectEqual(@as(usize, 1), result.warnings.len);
}

test "hashline apply: unresolved block failure takes precedence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const edits = [_]types.Edit{
        .{ .insert = .{
            .cursor = .{ .before_anchor = .{ .line = 99 } },
            .text = "never",
            .source_line = 1,
            .index = 0,
        } },
        .{ .block = .{
            .anchor = .{ .line = 1 },
            .payloads = &.{"x"},
            .source_line = 2,
            .index = 1,
        } },
    };
    const outcome = try applyEdits(arena.allocator(), "a", &edits);
    switch (outcome) {
        .success => return error.ExpectedApplyFailure,
        .failure => |failure| try std.testing.expectEqualStrings(
            messages.unresolved_block_internal,
            failure.message,
        ),
    }
}

test "hashline apply: outward after-insert landing shift warns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const edits = [_]types.Edit{.{ .insert = .{
        .cursor = .{ .after_anchor = .{ .line = 3 } },
        .text = "    c();",
        .source_line = 1,
        .index = 0,
    } }};
    const file = "function f() {\n    if (x) {\n        a();\n    }\n    b();\n}\n";
    const result = try expectApplySuccess(try applyEdits(arena.allocator(), file, &edits));
    try std.testing.expectEqualStrings(
        "function f() {\n    if (x) {\n        a();\n    }\n    c();\n    b();\n}\n",
        result.text,
    );
    try std.testing.expectEqualStrings(
        "INS.POST 3: body indented shallower than the anchor, so the landing moved past 1 closing line to after line 4. For the deeper position inside the block, re-issue with the body indented to match.",
        result.warnings[0],
    );
}

test "hashline apply: block-lowered after insert shifts inward" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const edits = [_]types.Edit{.{ .insert = .{
        .cursor = .{ .after_anchor = .{ .line = 4 } },
        .text = "        setup();",
        .source_line = 1,
        .index = 0,
        .block_start = 2,
    } }};
    const file = "function f() {\n    afterEach(() => {\n        destroy();\n    });\n}\n";
    const result = try expectApplySuccess(try applyEdits(arena.allocator(), file, &edits));
    try std.testing.expectEqualStrings(
        "function f() {\n    afterEach(() => {\n        destroy();\n        setup();\n    });\n}\n",
        result.text,
    );
    try std.testing.expectEqualStrings(
        "INS.BLK.POST 2: body indented deeper than closing line 4, so it was placed inside the block, after line 3. `INS.BLK.POST` lands AFTER the block at sibling depth — if inside was intended, use plain `INS.POST 4:`.",
        result.warnings[0],
    );
}
