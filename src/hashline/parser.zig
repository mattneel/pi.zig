//! Token-driven parser that lowers hashline hunks into concrete edits.
//!
//! All result slices and dynamic diagnostics are allocated by the caller. The
//! intended ownership model is an arena scoped to one parse/apply operation.

const std = @import("std");
const messages = @import("messages.zig");
const prefixes = @import("prefixes.zig");
const tokenizer_mod = @import("tokenizer.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Token = tokenizer_mod.Token;
const BlockTarget = tokenizer_mod.BlockTarget;

pub const ParseResult = struct {
    edits: []const types.Edit,
    file_op: ?types.FileOp = null,
    warnings: []const []const u8 = &.{},
};

const PayloadRow = struct {
    text: []const u8,
    line_num: usize,
    bare: bool = false,
};

const Pending = struct {
    target: BlockTarget,
    line_num: usize,
    payloads: std.ArrayList(PayloadRow) = .empty,
    deferred_blanks: std.ArrayList(PayloadRow) = .empty,
};

const PendingComment = struct {
    line_num: usize,
    text: []const u8,
};

const ExecError = Allocator.Error || error{InvalidPatch};

fn trimStart(text: []const u8) []const u8 {
    return std.mem.trimStart(u8, text, " \t\n\r\x0b\x0c");
}

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\n\r\x0b\x0c");
}

/// Byte length of the ECMAScript `WhiteSpace`/`LineTerminator` code point at
/// `index`, or zero when the next code point is not matched by JavaScript
/// `\s`. Contamination detection mirrors upstream JavaScript regular
/// expressions and deliberately does not reuse the parser's ASCII payload
/// trimming rules.
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

fn trimJsStart(text: []const u8) []const u8 {
    var index: usize = 0;
    while (true) {
        const length = jsWhitespaceLenAt(text, index);
        if (length == 0) break;
        index += length;
    }
    return text[index..];
}

fn skipJsWhitespace(text: []const u8, initial: usize) usize {
    var index = initial;
    while (true) {
        const length = jsWhitespaceLenAt(text, index);
        if (length == 0) break;
        index += length;
    }
    return index;
}

fn positiveIntegerEnd(text: []const u8, start: usize) ?usize {
    if (start >= text.len or text[start] < '1' or text[start] > '9') return null;
    var index = start + 1;
    while (index < text.len and std.ascii.isDigit(text[index])) index += 1;
    return index;
}

fn isSkippableCommentLine(line: []const u8) bool {
    return std.mem.startsWith(u8, trimStart(line), "#");
}

fn isBareLineHeader(text: []const u8) bool {
    const integer_end = positiveIntegerEnd(text, 0) orelse return false;
    return skipJsWhitespace(text, integer_end) == text.len;
}

fn bareRangeClassLenAt(text: []const u8, index: usize) usize {
    if (index >= text.len) return 0;
    if (text[index] == ' ' or text[index] == '-' or text[index] == '.' or text[index] == '=') return 1;
    return if (std.mem.startsWith(u8, text[index..], "…")) "…".len else 0;
}

fn parseBareRange(text: []const u8) ?struct { start: []const u8, end: []const u8 } {
    const first_end = positiveIntegerEnd(text, 0) orelse return null;

    // `\s*[-. …=]+\s*` has overlapping ASCII-space membership. Enumerate
    // the possible start/end of the character-class run to preserve regex
    // backtracking without admitting a tab as the sole separator.
    var class_start = first_end;
    while (true) {
        var class_end = class_start;
        while (true) {
            const length = bareRangeClassLenAt(text, class_end);
            if (length == 0) break;
            class_end += length;

            const second_start = skipJsWhitespace(text, class_end);
            const second_end = positiveIntegerEnd(text, second_start) orelse continue;
            const suffix = skipJsWhitespace(text, second_end);
            if (suffix == text.len or
                (suffix + 1 == text.len and text[suffix] == ':'))
            {
                return .{
                    .start = text[0..first_end],
                    .end = text[second_start..second_end],
                };
            }
        }
        const whitespace_len = jsWhitespaceLenAt(text, class_start);
        if (whitespace_len == 0) return null;
        class_start += whitespace_len;
    }
}

fn isDeleteWithColon(text: []const u8) bool {
    if (!std.mem.startsWith(u8, text, "DEL")) return false;
    const number_start = skipJsWhitespace(text, "DEL".len);
    if (number_start == "DEL".len) return false;
    const first_end = positiveIntegerEnd(text, number_start) orelse return false;

    // Optional-range-absent branch.
    const colon = skipJsWhitespace(text, first_end);
    if (colon < text.len and text[colon] == ':') return true;

    // Optional range: `\s*(?:\.\.|\.=|-|…|\s)\s*[1-9]\d*`.
    // Enumerating separator starts supplies the backtracking needed when the
    // separator itself is whitespace.
    var separator_start = first_end;
    while (true) {
        const separators = [_][]const u8{ "..", ".=", "-", "…" };
        for (separators) |separator| {
            if (!std.mem.startsWith(u8, text[separator_start..], separator)) continue;
            const second_start = skipJsWhitespace(text, separator_start + separator.len);
            const second_end = positiveIntegerEnd(text, second_start) orelse continue;
            const range_colon = skipJsWhitespace(text, second_end);
            if (range_colon < text.len and text[range_colon] == ':') return true;
        }
        const separator_len = jsWhitespaceLenAt(text, separator_start);
        if (separator_len > 0) {
            const second_start = skipJsWhitespace(text, separator_start + separator_len);
            if (positiveIntegerEnd(text, second_start)) |second_end| {
                const range_colon = skipJsWhitespace(text, second_end);
                if (range_colon < text.len and text[range_colon] == ':') return true;
            }
            separator_start += separator_len;
            continue;
        }
        return false;
    }
}

fn unifiedRangeEnd(text: []const u8, start: usize) ?usize {
    var index = start;
    if (index < text.len and (text[index] == '-' or text[index] == '+')) index += 1;
    const first_start = index;
    while (index < text.len and std.ascii.isDigit(text[index])) index += 1;
    if (index == first_start or index >= text.len or text[index] != ',') return null;
    index += 1;
    const second_start = index;
    while (index < text.len and std.ascii.isDigit(text[index])) index += 1;
    return if (index == second_start) null else index;
}

/// Exact prefix match for `/^@@\s+[-+]?\d+,\d+\s+[-+]?\d+,\d+\s+@@/`.
/// The caller supplies the same anchored view used upstream: trim-started in
/// parser contamination detection and trim-ended in top-level input parsing.
pub fn isUnifiedDiffHeader(text: []const u8) bool {
    if (!std.mem.startsWith(u8, text, "@@")) return false;
    var index: usize = "@@".len;
    const first_start = skipJsWhitespace(text, index);
    if (first_start == index) return false;
    index = unifiedRangeEnd(text, first_start) orelse return false;
    const second_start = skipJsWhitespace(text, index);
    if (second_start == index) return false;
    index = unifiedRangeEnd(text, second_start) orelse return false;
    const suffix = skipJsWhitespace(text, index);
    return suffix > index and std.mem.startsWith(u8, text[suffix..], "@@");
}

fn isBareLiteralValue(text: []const u8) bool {
    var value = trim(text);
    if (value.len > 0 and value[value.len - 1] == ',') value = trim(value[0 .. value.len - 1]);
    if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and value[value.len - 1] == value[0]) {
        return std.mem.indexOfScalar(u8, value[1 .. value.len - 1], value[0]) == null;
    }
    var index: usize = 0;
    if (index < value.len and (value[index] == '-' or value[index] == '+')) index += 1;
    const integer_start = index;
    while (index < value.len and std.ascii.isDigit(value[index])) index += 1;
    if (index == integer_start) return false;
    if (index < value.len and value[index] == '.') {
        index += 1;
        const fraction_start = index;
        while (index < value.len and std.ascii.isDigit(value[index])) index += 1;
        if (index == fraction_start) return false;
    }
    return index == value.len;
}

pub const Executor = struct {
    allocator: Allocator,
    edits: std.ArrayList(types.Edit) = .empty,
    warnings: std.ArrayList([]const u8) = .empty,
    edit_index: usize = 0,
    pending: ?Pending = null,
    file_op: ?types.FileOp = null,
    terminated: bool = false,
    skippable_comments: std.ArrayList(PendingComment) = .empty,
    failure_message: ?[]const u8 = null,

    pub fn init(allocator: Allocator) Executor {
        return .{ .allocator = allocator };
    }

    fn invalid(self: *Executor, message: []const u8) ExecError {
        self.failure_message = message;
        return error.InvalidPatch;
    }

    fn hasWarning(self: *const Executor, warning: []const u8) bool {
        for (self.warnings.items) |existing| if (std.mem.eql(u8, existing, warning)) return true;
        return false;
    }

    fn addBareWarning(self: *Executor) Allocator.Error!void {
        if (!self.hasWarning(messages.bare_body_auto_piped_warning)) {
            try self.warnings.append(self.allocator, messages.bare_body_auto_piped_warning);
        }
    }

    fn discardPendingSkippableComments(self: *Executor) void {
        self.skippable_comments.clearRetainingCapacity();
    }

    fn consumePendingSkippableComments(self: *Executor) ExecError!void {
        if (self.skippable_comments.items.len == 0) return;
        for (self.skippable_comments.items) |comment| try self.handleRaw(comment.text, comment.line_num);
        self.skippable_comments.clearRetainingCapacity();
    }

    pub fn feed(self: *Executor, token: Token) ExecError!void {
        if (self.terminated) return;
        switch (token) {
            .envelope_begin => {
                try self.consumePendingSkippableComments();
            },
            .envelope_end => {
                try self.consumePendingSkippableComments();
                self.terminated = true;
            },
            .abort => self.terminated = true,
            .header => {
                try self.consumePendingSkippableComments();
                try self.flushPending();
            },
            .blank => |line_num| {
                try self.consumePendingSkippableComments();
                try self.handleBlank("", line_num);
            },
            .payload_literal => |row| {
                try self.consumePendingSkippableComments();
                try self.handleLiteralPayload(row.text, row.line_num);
            },
            .raw => |row| {
                if (self.pending == null and isSkippableCommentLine(row.text)) {
                    try self.skippable_comments.append(self.allocator, .{ .line_num = row.line_num, .text = row.text });
                    return;
                }
                try self.consumePendingSkippableComments();
                try self.handleRaw(row.text, row.line_num);
            },
            .op_block => |op| {
                self.discardPendingSkippableComments();
                switch (op.target) {
                    .replace => |range| try self.validateRangeOrder(range, op.line_num),
                    .delete => |range| try self.validateRangeOrder(range, op.line_num),
                    else => {},
                }
                switch (op.target) {
                    .rem => {
                        try self.flushPending();
                        try self.setFileOp(.rem, op.line_num);
                    },
                    .move => |dest| {
                        try self.flushPending();
                        try self.setFileOp(.{ .move = dest }, op.line_num);
                    },
                    else => {
                        try self.flushPending();
                        self.pending = .{ .target = op.target, .line_num = op.line_num };
                    },
                }
            },
        }
    }

    pub fn end(self: *Executor) ExecError!ParseResult {
        try self.consumePendingSkippableComments();
        try self.flushPending();
        try self.validateFileOp();
        try self.validateNoOverlappingDeletes();
        return .{ .edits = self.edits.items, .file_op = self.file_op, .warnings = self.warnings.items };
    }

    pub fn endStreaming(self: *Executor) ExecError!ParseResult {
        try self.consumePendingSkippableComments();
        if (self.pending) |pending| {
            const tag = std.meta.activeTag(pending.target);
            if (pending.payloads.items.len > 0 or tag == .delete or tag == .delete_block) {
                try self.flushPending();
            } else {
                self.pending = null;
            }
        }
        try self.validateFileOp();
        try self.validateNoOverlappingDeletes();
        return .{ .edits = self.edits.items, .file_op = self.file_op, .warnings = self.warnings.items };
    }

    fn validateRangeOrder(self: *Executor, range: types.ParsedRange, line_num: usize) ExecError!void {
        if (range.end.line < range.start.line) {
            return self.invalid(try messages.invertedRangeMessage(
                self.allocator,
                line_num,
                range.start.line,
                range.end.line,
            ));
        }
    }

    fn setFileOp(self: *Executor, file_op: types.FileOp, line_num: usize) ExecError!void {
        if (self.file_op != null) {
            return self.invalid(try messages.duplicateFileOpMessage(self.allocator, line_num));
        }
        if (file_op == .rem and self.edits.items.len > 0) {
            return self.invalid(try messages.lineMessage(self.allocator, line_num, messages.rem_takes_no_body));
        }
        self.file_op = file_op;
    }

    fn validateFileOp(self: *Executor) ExecError!void {
        if (self.file_op) |op| {
            if (op == .rem and self.edits.items.len > 0) {
                return self.invalid(messages.rem_cannot_combine);
            }
        }
    }

    fn validateNoOverlappingDeletes(self: *Executor) ExecError!void {
        for (self.edits.items, 0..) |candidate, index| {
            if (candidate != .delete) continue;
            const anchor_line = candidate.delete.anchor.line;
            var first_line = candidate.delete.source_line;
            var second_line: ?usize = null;
            for (self.edits.items[index + 1 ..]) |other| {
                if (other != .delete or other.delete.anchor.line != anchor_line or
                    other.delete.source_line == candidate.delete.source_line) continue;
                const low = @min(first_line, other.delete.source_line);
                const high = @max(first_line, other.delete.source_line);
                first_line = low;
                second_line = if (second_line) |existing| @min(existing, high) else high;
            }
            if (second_line) |second| {
                return self.invalid(try messages.overlappingHunkMessage(
                    self.allocator,
                    second,
                    anchor_line,
                    first_line,
                ));
            }
        }
    }

    fn handleLiteralPayload(self: *Executor, text: []const u8, line_num: usize) ExecError!void {
        if (self.pending == null) {
            if (self.file_op != null) return self.invalid(try messages.lineMessage(self.allocator, line_num, messages.move_takes_no_body));
            return self.invalid(try messages.orphanLiteralPayloadMessage(self.allocator, line_num, text));
        }
        var pending = &self.pending.?;
        switch (pending.target) {
            .delete => return self.invalid(try messages.lineMessage(self.allocator, line_num, messages.delete_takes_no_body)),
            .delete_block => return self.invalid(try messages.lineMessage(self.allocator, line_num, messages.delete_block_takes_no_body)),
            else => {},
        }
        try self.commitDeferredBlanks(pending);
        try pending.payloads.append(self.allocator, .{ .text = text, .line_num = line_num });
    }

    fn detectContamination(self: *Executor, text: []const u8) ExecError!?[]const u8 {
        // Every upstream contamination regex is anchored against this one
        // trim-start-only view. Preserve it unchanged for diagnostics so
        // trailing whitespace remains inside interpolated backticks/quotes.
        const value = trimJsStart(text);
        if (value.len == 0) return null;
        const sentinels = [_][]const u8{
            "*** Update File:", "*** Add File:", "*** Delete File:", "*** Move to:",
        };
        for (sentinels) |sentinel| {
            if (!std.mem.startsWith(u8, value, sentinel)) continue;
            return try messages.applyPatchSentinelMessage(self.allocator, value);
        }
        if (isUnifiedDiffHeader(value)) {
            return messages.parser_unified_diff_header;
        }
        if (std.mem.startsWith(u8, value, "@@")) {
            return try messages.atAtHeaderMessage(self.allocator, value);
        }
        if (isDeleteWithColon(value)) {
            return messages.delete_colon_rejected;
        }
        if (isBareLineHeader(value)) {
            return try messages.bareLineHeaderMessage(self.allocator, value);
        }
        if (parseBareRange(value)) |range| {
            return try messages.bareRangeHeaderMessage(self.allocator, value, range.start, range.end);
        }
        return null;
    }

    fn handleRaw(self: *Executor, text: []const u8, line_num: usize) ExecError!void {
        if (try self.detectContamination(text)) |contamination| {
            return self.invalid(try messages.lineMessage(self.allocator, line_num, contamination));
        }
        if (self.file_op != null) return self.invalid(try messages.lineMessage(self.allocator, line_num, messages.move_takes_no_body));
        if (self.pending) |*pending| {
            if (trim(text).len == 0) return self.handleBlank(text, line_num);
            switch (pending.target) {
                .delete => return self.invalid(try messages.lineMessage(self.allocator, line_num, messages.delete_takes_no_body)),
                .delete_block => return self.invalid(try messages.lineMessage(self.allocator, line_num, messages.delete_block_takes_no_body)),
                else => {},
            }
            if (trimStart(text).len > 0 and trimStart(text)[0] == '-') {
                return self.invalid(try messages.lineMessage(self.allocator, line_num, messages.minus_row_rejected));
            }
            try self.addBareWarning();
            try self.commitDeferredBlanks(pending);
            try pending.payloads.append(self.allocator, .{ .text = text, .line_num = line_num, .bare = true });
            return;
        }
        if (trim(text).len == 0) return;
        return self.invalid(try messages.orphanRawPayloadMessage(self.allocator, line_num, text));
    }

    fn handleBlank(self: *Executor, text: []const u8, line_num: usize) ExecError!void {
        if (self.pending) |*pending| {
            switch (pending.target) {
                .delete, .delete_block => return,
                else => {},
            }
            if (pending.payloads.items.len == 0) return;
            try pending.deferred_blanks.append(self.allocator, .{ .text = text, .line_num = line_num, .bare = true });
        }
    }

    fn commitDeferredBlanks(self: *Executor, pending: *Pending) Allocator.Error!void {
        if (pending.deferred_blanks.items.len == 0) return;
        try self.addBareWarning();
        try pending.payloads.appendSlice(self.allocator, pending.deferred_blanks.items);
        pending.deferred_blanks.clearRetainingCapacity();
    }

    fn stripBarePrefixesIfUniform(_: *Executor, payloads: []PayloadRow) void {
        var saw_bare = false;
        var all_literal_values = true;
        for (payloads) |row| {
            if (!row.bare or trim(row.text).len == 0) continue;
            saw_bare = true;
            const stripped = prefixes.stripOneLeadingHashlinePrefix(row.text);
            if (stripped.ptr == row.text.ptr and stripped.len == row.text.len) return;
            all_literal_values = all_literal_values and isBareLiteralValue(stripped);
        }
        if (!saw_bare or all_literal_values) return;
        for (payloads) |*row| {
            if (row.bare and trim(row.text).len > 0) row.text = prefixes.stripOneLeadingHashlinePrefix(row.text);
        }
    }

    fn pushInsert(
        self: *Executor,
        cursor: types.Cursor,
        text: []const u8,
        line_num: usize,
        mode: ?types.InsertMode,
    ) Allocator.Error!void {
        try self.edits.append(self.allocator, .{ .insert = .{
            .cursor = cursor,
            .text = text,
            .source_line = line_num,
            .index = self.edit_index,
            .mode = mode,
        } });
        self.edit_index += 1;
    }

    fn pushDelete(self: *Executor, anchor: types.Anchor, line_num: usize) Allocator.Error!void {
        try self.edits.append(self.allocator, .{ .delete = .{
            .anchor = anchor,
            .source_line = line_num,
            .index = self.edit_index,
        } });
        self.edit_index += 1;
    }

    fn pushBlock(
        self: *Executor,
        anchor: types.Anchor,
        payloads: []const PayloadRow,
        line_num: usize,
        mode: ?types.BlockMode,
    ) Allocator.Error!void {
        const texts = try self.allocator.alloc([]const u8, payloads.len);
        for (payloads, texts) |payload, *text| text.* = payload.text;
        try self.edits.append(self.allocator, .{ .block = .{
            .anchor = anchor,
            .payloads = texts,
            .mode = mode,
            .source_line = line_num,
            .index = self.edit_index,
        } });
        self.edit_index += 1;
    }

    fn expandDeletes(self: *Executor, range: types.ParsedRange, line_num: usize) Allocator.Error!void {
        var line = range.start.line;
        while (true) {
            try self.pushDelete(.{ .line = line }, line_num);
            if (line == range.end.line) break;
            line += 1;
        }
    }

    fn emitPayloadRows(
        self: *Executor,
        cursor: types.Cursor,
        payloads: []const PayloadRow,
        line_num: usize,
        mode: ?types.InsertMode,
    ) Allocator.Error!void {
        for (payloads) |payload| try self.pushInsert(cursor, payload.text, line_num, mode);
    }

    fn flushPending(self: *Executor) ExecError!void {
        const pending = self.pending orelse return;
        self.stripBarePrefixesIfUniform(pending.payloads.items);
        self.pending = null;
        switch (pending.target) {
            .delete => |range| try self.expandDeletes(range, pending.line_num),
            .delete_block => |anchor| try self.pushBlock(anchor, &.{}, pending.line_num, null),
            .block => |anchor| {
                if (pending.payloads.items.len == 0) {
                    return self.invalid(try messages.lineMessage(self.allocator, pending.line_num, messages.empty_block));
                }
                try self.pushBlock(anchor, pending.payloads.items, pending.line_num, null);
            },
            .insert_after_block => |anchor| {
                if (pending.payloads.items.len == 0) {
                    return self.invalid(try messages.lineMessage(self.allocator, pending.line_num, messages.empty_insert));
                }
                try self.pushBlock(anchor, pending.payloads.items, pending.line_num, .insert_after);
            },
            .replace => |range| {
                if (pending.payloads.items.len == 0) {
                    try self.expandDeletes(range, pending.line_num);
                    return;
                }
                const cursor: types.Cursor = .{ .before_anchor = range.start };
                try self.emitPayloadRows(cursor, pending.payloads.items, pending.line_num, .replacement);
                try self.expandDeletes(range, pending.line_num);
            },
            .insert_before => |anchor| {
                if (pending.payloads.items.len == 0) return self.invalid(try messages.lineMessage(self.allocator, pending.line_num, messages.empty_insert));
                try self.emitPayloadRows(.{ .before_anchor = anchor }, pending.payloads.items, pending.line_num, null);
            },
            .insert_after => |anchor| {
                if (pending.payloads.items.len == 0) return self.invalid(try messages.lineMessage(self.allocator, pending.line_num, messages.empty_insert));
                try self.emitPayloadRows(.{ .after_anchor = anchor }, pending.payloads.items, pending.line_num, null);
            },
            .bof => {
                if (pending.payloads.items.len == 0) return self.invalid(try messages.lineMessage(self.allocator, pending.line_num, messages.empty_insert));
                try self.emitPayloadRows(.bof, pending.payloads.items, pending.line_num, null);
            },
            .eof => {
                if (pending.payloads.items.len == 0) return self.invalid(try messages.lineMessage(self.allocator, pending.line_num, messages.empty_insert));
                try self.emitPayloadRows(.eof, pending.payloads.items, pending.line_num, null);
            },
            .rem, .move => unreachable,
        }
    }
};

fn consumeTokens(executor: *Executor, tokens: []const Token) ExecError!void {
    for (tokens) |token| try executor.feed(token);
}

fn invalidOutcome(executor: *const Executor) types.Outcome(ParseResult) {
    return .{ .failure = types.failure(executor.failure_message orelse messages.invalid_hashline_patch) };
}

fn parsePatchMode(
    allocator: Allocator,
    diff: []const u8,
    streaming: bool,
) Allocator.Error!types.Outcome(ParseResult) {
    var tokenizer = tokenizer_mod.Tokenizer.init(allocator);
    defer tokenizer.deinit();
    var executor = Executor.init(allocator);

    const first = tokenizer.feed(diff) catch |err| switch (err) {
        error.TokenizerClosed => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
    consumeTokens(&executor, first) catch |err| switch (err) {
        error.InvalidPatch => return invalidOutcome(&executor),
        error.OutOfMemory => return error.OutOfMemory,
    };
    const final = try tokenizer.end();
    consumeTokens(&executor, final) catch |err| switch (err) {
        error.InvalidPatch => return invalidOutcome(&executor),
        error.OutOfMemory => return error.OutOfMemory,
    };
    const result = if (streaming) executor.endStreaming() else executor.end();
    return .{ .success = result catch |err| switch (err) {
        error.InvalidPatch => return invalidOutcome(&executor),
        error.OutOfMemory => return error.OutOfMemory,
    } };
}

pub fn parsePatch(allocator: Allocator, diff: []const u8) Allocator.Error!types.Outcome(ParseResult) {
    return parsePatchMode(allocator, diff, false);
}

pub fn parsePatchStreaming(allocator: Allocator, diff: []const u8) Allocator.Error!types.Outcome(ParseResult) {
    return parsePatchMode(allocator, diff, true);
}

fn expectSuccess(outcome: types.Outcome(ParseResult)) !ParseResult {
    return switch (outcome) {
        .success => |result| result,
        .failure => |failure| {
            std.debug.print("unexpected parse failure: {s}\n", .{failure.message});
            return error.TestUnexpectedResult;
        },
    };
}

fn expectFailure(outcome: types.Outcome(ParseResult)) !types.Failure {
    return switch (outcome) {
        .failure => |failure| failure,
        .success => error.TestUnexpectedResult,
    };
}

test "hashline: parser lowers canonical and lenient replacement ranges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_][]const u8{
        "SWAP 2.=3:\n+X", "SWAP 2-3:\n+X",
        "SWAP 2…3:\n+X",
        "SWAP 2 3:\n+X",  "SWAP 2..3:\n+X",
        "SWAP 2.=3\n+X",
    };
    for (cases) |diff| {
        const result = try expectSuccess(try parsePatch(arena.allocator(), diff));
        try std.testing.expectEqual(@as(usize, 3), result.edits.len);
        try std.testing.expect(result.edits[0] == .insert);
        try std.testing.expectEqual(types.InsertMode.replacement, result.edits[0].insert.mode.?);
        try std.testing.expectEqual(@as(usize, 2), result.edits[1].delete.anchor.line);
        try std.testing.expectEqual(@as(usize, 3), result.edits[2].delete.anchor.line);
    }
}

test "hashline: parser auto-pipes uniform copied prefixes but preserves numeric maps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const copied = try expectSuccess(try parsePatch(arena.allocator(), "SWAP 2.=3:\n2:foo\n\n3:bar"));
    try std.testing.expectEqualStrings("foo", copied.edits[0].insert.text);
    try std.testing.expectEqualStrings("", copied.edits[1].insert.text);
    try std.testing.expectEqualStrings("bar", copied.edits[2].insert.text);
    try std.testing.expectEqualStrings(messages.bare_body_auto_piped_warning, copied.warnings[0]);

    const mapping = try expectSuccess(try parsePatch(arena.allocator(), "SWAP 2.=3:\n1: \"one\",\n2: \"two\","));
    try std.testing.expectEqualStrings("1: \"one\",", mapping.edits[0].insert.text);
    try std.testing.expectEqualStrings("2: \"two\",", mapping.edits[1].insert.text);
}

test "hashline: parser exact rejection strings cover delete body range order and overlap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const delete_body = try expectFailure(try parsePatch(arena.allocator(), "DEL 2\n+X"));
    try std.testing.expectEqualStrings(
        try messages.lineMessage(arena.allocator(), 2, messages.delete_takes_no_body),
        delete_body.message,
    );
    const inverted = try expectFailure(try parsePatch(arena.allocator(), "DEL 4.=2"));
    try std.testing.expectEqualStrings(try messages.invertedRangeMessage(arena.allocator(), 1, 4, 2), inverted.message);
    const overlap = try expectFailure(try parsePatch(
        arena.allocator(),
        "SWAP 2.=4:\n+X\nSWAP 3.=5:\n+Y",
    ));
    try std.testing.expectEqualStrings(try messages.overlappingHunkMessage(arena.allocator(), 3, 3, 1), overlap.message);
}

test "hashline: parser streaming drops trailing empty replacement and flushes it before another hunk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const trailing = try expectSuccess(try parsePatchStreaming(arena.allocator(), "SWAP 5.=5:\n"));
    try std.testing.expectEqual(@as(usize, 0), trailing.edits.len);
    const before_next = try expectSuccess(try parsePatchStreaming(arena.allocator(), "SWAP 2.=2:\nINS.TAIL:\n"));
    try std.testing.expectEqual(@as(usize, 1), before_next.edits.len);
    try std.testing.expectEqual(@as(usize, 2), before_next.edits[0].delete.anchor.line);
}

test "hashline: parser supports deferred block and file operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const block = try expectSuccess(try parsePatch(arena.allocator(), "SWAP.BLK 2:\n+A\n+B"));
    try std.testing.expectEqual(@as(usize, 1), block.edits.len);
    try std.testing.expectEqual(@as(usize, 2), block.edits[0].block.anchor.line);
    try std.testing.expectEqualStrings("B", block.edits[0].block.payloads[1]);
    const rem = try expectSuccess(try parsePatch(arena.allocator(), "REM"));
    try std.testing.expect(rem.file_op.? == .rem);
    const move = try expectSuccess(try parsePatch(arena.allocator(), "SWAP 1:\n+X\nMV \"new path.ts\""));
    try std.testing.expectEqualStrings("new path.ts", move.file_op.?.move);
}

test "hashline: parser leniency preserves literal payload forms and blank-row boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const explicit = try expectSuccess(try parsePatch(
        arena.allocator(),
        "SWAP 2.=2:\n+3:keep\n+- item\n+  - nested\n++plus",
    ));
    try std.testing.expectEqualStrings("3:keep", explicit.edits[0].insert.text);
    try std.testing.expectEqualStrings("- item", explicit.edits[1].insert.text);
    try std.testing.expectEqualStrings("  - nested", explicit.edits[2].insert.text);
    try std.testing.expectEqualStrings("+plus", explicit.edits[3].insert.text);
    try std.testing.expectEqual(@as(usize, 0), explicit.warnings.len);

    const mixed = try expectSuccess(try parsePatch(arena.allocator(), "SWAP 2.=3:\n3:keep\nplain"));
    try std.testing.expectEqualStrings("3:keep", mixed.edits[0].insert.text);
    try std.testing.expectEqualStrings("plain", mixed.edits[1].insert.text);

    const blanks = try expectSuccess(try parsePatch(
        arena.allocator(),
        "SWAP 2.=2:\nfoo\n\nbar\n\nSWAP 4.=4:\nbaz",
    ));
    try std.testing.expectEqualStrings("foo", blanks.edits[0].insert.text);
    try std.testing.expectEqualStrings("", blanks.edits[1].insert.text);
    try std.testing.expectEqualStrings("bar", blanks.edits[2].insert.text);
    try std.testing.expectEqualStrings("baz", blanks.edits[4].insert.text);
}

test "hashline: parser rejects contamination and malformed verb-less headers byte exactly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const single = try expectFailure(try parsePatch(arena.allocator(), "2\n+B"));
    try std.testing.expectEqualStrings(
        try messages.lineMessage(arena.allocator(), 1, try messages.bareLineHeaderMessage(arena.allocator(), "2")),
        single.message,
    );
    const range = try expectFailure(try parsePatch(arena.allocator(), "2 3\n+X"));
    try std.testing.expectEqualStrings(
        try messages.lineMessage(
            arena.allocator(),
            1,
            try messages.bareRangeHeaderMessage(arena.allocator(), "2 3", "2", "3"),
        ),
        range.message,
    );
    const delete_colon = try expectFailure(try parsePatch(arena.allocator(), "DEL 2:\n+X"));
    try std.testing.expectEqualStrings(
        try messages.lineMessage(arena.allocator(), 1, messages.delete_colon_rejected),
        delete_colon.message,
    );
    const sentinel = try expectFailure(try parsePatch(arena.allocator(), "*** Update File: a.ts\nSWAP 2.=2:\n+X"));
    try std.testing.expectEqualStrings(
        try messages.lineMessage(
            arena.allocator(),
            1,
            try messages.applyPatchSentinelMessage(arena.allocator(), "*** Update File: a.ts"),
        ),
        sentinel.message,
    );
    const unified = try expectFailure(try parsePatch(arena.allocator(), "@@ -1,3 +1,3 @@\nSWAP 2.=2:\n+X"));
    try std.testing.expectEqualStrings(
        try messages.lineMessage(arena.allocator(), 1, messages.parser_unified_diff_header),
        unified.message,
    );
}

test "hashline regression 5: DEL colon contamination is a prefix match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const failure = try expectFailure(try parsePatch(
        arena.allocator(),
        "SWAP 2.=2:\n+x\nDEL 3: cleanup note",
    ));
    try std.testing.expectEqualStrings(
        try messages.lineMessage(arena.allocator(), 3, messages.delete_colon_rejected),
        failure.message,
    );
}

test "hashline regression 6: bare range separator and colon trailing-space shape is exact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tab = try expectSuccess(try parsePatch(arena.allocator(), "SWAP 2.=2:\n2\t3"));
    try std.testing.expectEqualStrings("2\t3", tab.edits[0].insert.text);
    try std.testing.expectEqualStrings(messages.bare_body_auto_piped_warning, tab.warnings[0]);

    const colon_spaces = try expectSuccess(try parsePatch(arena.allocator(), "SWAP 2.=2:\n2-3:  "));
    try std.testing.expectEqualStrings("2-3:  ", colon_spaces.edits[0].insert.text);
    try std.testing.expectEqualStrings(messages.bare_body_auto_piped_warning, colon_spaces.warnings[0]);
}

test "hashline regression 7: unified diff contamination uses the exact numeric prefix shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const numeric = try expectFailure(try parsePatch(
        arena.allocator(),
        "@@ -12,5 +12,7 @@ export function parse() {",
    ));
    try std.testing.expectEqualStrings(
        try messages.lineMessage(arena.allocator(), 1, messages.parser_unified_diff_header),
        numeric.message,
    );

    const malformed_text = "@@ x,y -a +b @@";
    const malformed = try expectFailure(try parsePatch(arena.allocator(), malformed_text));
    try std.testing.expectEqualStrings(
        try messages.lineMessage(
            arena.allocator(),
            1,
            try messages.atAtHeaderMessage(arena.allocator(), malformed_text),
        ),
        malformed.message,
    );
}

test "hashline regression 11: contamination diagnostics preserve trimStart-only trailing whitespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const line = try expectFailure(try parsePatch(arena.allocator(), "2 "));
    try std.testing.expectEqualStrings(
        "line 1: hunk headers need a verb. Use `SWAP 2 .=2 :` to replace, or `DEL 2 ` to delete.",
        line.message,
    );
    const unicode_trim_start = try expectFailure(try parsePatch(arena.allocator(), "\u{202f}2 "));
    try std.testing.expectEqualStrings(line.message, unicode_trim_start.message);

    const range = try expectFailure(try parsePatch(arena.allocator(), "2-3 "));
    try std.testing.expectEqualStrings(
        "line 1: bare range hunk header \"2-3 \" is not valid. Hunk headers need a verb: write `SWAP 2.=3:` or `DEL 2.=3`.",
        range.message,
    );

    const at_at_value = "@@ malformed  ";
    const at_at = try expectFailure(try parsePatch(arena.allocator(), "  @@ malformed  "));
    try std.testing.expectEqualStrings(
        try messages.lineMessage(
            arena.allocator(),
            1,
            try messages.atAtHeaderMessage(arena.allocator(), at_at_value),
        ),
        at_at.message,
    );

    const sentinel_value = "*** Update File: a.ts  ";
    const sentinel = try expectFailure(try parsePatch(arena.allocator(), "\t*** Update File: a.ts  "));
    try std.testing.expectEqualStrings(
        try messages.lineMessage(
            arena.allocator(),
            1,
            try messages.applyPatchSentinelMessage(arena.allocator(), sentinel_value),
        ),
        sentinel.message,
    );
}

test "hashline: parser rejects minus and orphan payload rows with exact steering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const minus = try expectFailure(try parsePatch(arena.allocator(), "SWAP 2.=2:\n-old\n+new"));
    try std.testing.expectEqualStrings(try messages.lineMessage(arena.allocator(), 2, messages.minus_row_rejected), minus.message);
    const explicit = try expectFailure(try parsePatch(arena.allocator(), "+const X = 1;\nSWAP 2.=2:"));
    try std.testing.expectEqualStrings(
        try messages.orphanLiteralPayloadMessage(arena.allocator(), 1, "const X = 1;"),
        explicit.message,
    );
}

test "hashline: parser empty and abort semantics match the corpus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const replacement = try expectSuccess(try parsePatch(arena.allocator(), "SWAP 2.=2:"));
    try std.testing.expectEqual(@as(usize, 1), replacement.edits.len);
    try std.testing.expectEqual(@as(usize, 2), replacement.edits[0].delete.anchor.line);
    const empty_insert = try expectFailure(try parsePatch(arena.allocator(), "INS.TAIL:"));
    try std.testing.expectEqualStrings(try messages.lineMessage(arena.allocator(), 1, messages.empty_insert), empty_insert.message);
    const empty_block = try expectFailure(try parsePatch(arena.allocator(), "SWAP.BLK 2:"));
    try std.testing.expectEqualStrings(try messages.lineMessage(arena.allocator(), 1, messages.empty_block), empty_block.message);

    const aborted = try expectSuccess(try parsePatch(
        arena.allocator(),
        "*** Begin Patch\nINS.POST 1:\n+HELLO\n*** Abort\nINS.POST 99:\n+never\n*** End Patch",
    ));
    try std.testing.expectEqual(@as(usize, 1), aborted.edits.len);
    try std.testing.expectEqualStrings("HELLO", aborted.edits[0].insert.text);
    try std.testing.expectEqual(@as(usize, 0), aborted.warnings.len);
}

test "hashline: parser file-op constraints are exact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rem_after_edit = try expectFailure(try parsePatch(arena.allocator(), "SWAP 1.=1:\n+one\nREM"));
    try std.testing.expectEqualStrings(try messages.lineMessage(arena.allocator(), 3, messages.rem_takes_no_body), rem_after_edit.message);
    const two_ops = try expectFailure(try parsePatch(arena.allocator(), "MV b.ts\nMV c.ts"));
    try std.testing.expectEqualStrings(
        try messages.duplicateFileOpMessage(arena.allocator(), 2),
        two_ops.message,
    );
}
