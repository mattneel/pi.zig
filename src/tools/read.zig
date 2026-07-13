//! Local file and directory reader for the essential tool registry.

const std = @import("std");
const approval = @import("../core/approval.zig");
const tool_api = @import("../core/tool.zig");
const hashline = @import("../hashline/hashline.zig");
const output = @import("output.zig");
const session_state = @import("session_state.zig");
const fs_real = @import("fs_real.zig");

const Allocator = std.mem.Allocator;
const SessionState = session_state.SessionState;

const RANGE_LEADING_CONTEXT_LINES = 1;
const RANGE_TRAILING_CONTEXT_LINES = 3;
const MAX_LINES = output.DEFAULT_MAX_LINES;
const MAX_BYTES = output.DEFAULT_MAX_BYTES;

pub const description = @embedFile("../prompts/tools/read.md");
pub const input_schema =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Local path. Inline :<selector> is accepted."},"selector":{"type":"string","description":"selector without a leading colon"}},"required":["path"],"additionalProperties":false}
;

pub const tool: tool_api.Tool = .{
    .name = "read",
    .description = description,
    .input_schema = input_schema,
    .concurrency = .{ .mode = .shared },
    .approval = .{ .tier = approval.ToolTier.read },
    .intent = .{ .mode = .require },
    .vtable = &vtable,
};

const vtable: tool_api.VTable = .{ .execute = execute };

const Range = struct {
    start: usize,
    end: ?usize,
};

const Selector = struct {
    raw: bool = false,
    explicit: bool = false,
    ranges: []const Range,
    requested_ranges: []const Range,
};

const SelectedLine = struct {
    number: usize,
    text: []const u8,
};

const ScanResult = struct {
    lines: []const SelectedLine,
    total_lines: usize,
    total_bytes: usize,
    selected_lines: usize,
    collected_bytes: usize,
    stopped_by_byte_limit: bool,
    first_line_bytes: ?usize,
    first_line_preview: ?[]const u8,
    snapshot_text: ?[]const u8,
};

fn execute(
    raw_context: ?*anyopaque,
    io: std.Io,
    arena: Allocator,
    input: std.json.Value,
    on_update: ?tool_api.OnUpdate,
    cancel: *const tool_api.CancelToken,
) anyerror!tool_api.ToolOutcome {
    const state: *SessionState = @ptrCast(@alignCast(raw_context.?));
    const object = if (input == .object) input.object else return errorText(arena, "read input must be an object");
    const path_value = object.get("path") orelse return errorText(arena, "read requires a string path");
    if (path_value != .string or path_value.string.len == 0) return errorText(arena, "read requires a string path");
    try cancel.check();

    var path = path_value.string;
    var selector_text: ?[]const u8 = null;
    if (object.get("selector")) |value| {
        if (value != .string) return errorText(arena, "read selector must be a string");
        selector_text = std.mem.trimStart(u8, value.string, ":");
    } else {
        const split = splitInlineSelector(path);
        if (split.selector == null or !(try literalPathExists(state, io, arena, path))) {
            path = split.path;
            selector_text = split.selector;
        }
    }

    if (unsupportedSurface(path)) |surface| {
        return textOutcome(arena, try std.fmt.allocPrint(
            arena,
            "Unsupported in this build: read supports local text files and directories only; {s} is not available.",
            .{surface},
        ));
    }

    var selector_error: ?[]const u8 = null;
    const parsed = parseSelector(arena, selector_text, &selector_error) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSelector => return errorText(arena, selector_error orelse "Invalid selector."),
    };

    const absolute = state.real_fs.resolve(arena, path) catch |err| {
        return errorText(arena, try std.fmt.allocPrint(arena, "Cannot resolve path '{s}': {s}", .{ path, @errorName(err) }));
    };
    const stat = std.Io.Dir.cwd().statFile(io, absolute, .{}) catch |err| {
        return errorText(arena, try std.fmt.allocPrint(arena, "Cannot read '{s}': {s}", .{ path, @errorName(err) }));
    };
    if (stat.kind == .directory) return readDirectory(io, arena, absolute, parsed, on_update);
    if (stat.kind != .file) {
        return textOutcome(arena, "Unsupported in this build: read supports regular local text files and directories only.");
    }
    return readFile(state, io, arena, absolute, parsed, on_update, cancel);
}

fn parseSelector(arena: Allocator, raw_selector: ?[]const u8, error_message: *?[]const u8) !Selector {
    const raw = raw_selector orelse {
        const ranges = try arena.dupe(Range, &.{.{ .start = 1, .end = null }});
        return .{ .ranges = ranges, .requested_ranges = ranges };
    };
    if (raw.len == 0) {
        const ranges = try arena.dupe(Range, &.{.{ .start = 1, .end = null }});
        return .{ .ranges = ranges, .requested_ranges = ranges };
    }

    var raw_mode = false;
    var range_text: ?[]const u8 = null;
    var parts = std.mem.splitScalar(u8, raw, ':');
    var part_count: usize = 0;
    while (parts.next()) |part| {
        part_count += 1;
        if (std.ascii.eqlIgnoreCase(part, "raw")) {
            if (raw_mode) return invalidSelector(arena, raw, error_message);
            raw_mode = true;
        } else if (part.len != 0 and range_text == null) {
            range_text = part;
        } else {
            return invalidSelector(arena, raw, error_message);
        }
    }
    if (part_count > 2 or (part_count == 2 and (!raw_mode or range_text == null))) return invalidSelector(arena, raw, error_message);
    if (range_text == null) {
        if (!raw_mode) return invalidSelector(arena, raw, error_message);
        const ranges = try arena.dupe(Range, &.{.{ .start = 1, .end = null }});
        return .{ .raw = true, .explicit = true, .ranges = ranges, .requested_ranges = ranges };
    }

    var ranges: std.ArrayList(Range) = .empty;
    var chunks = std.mem.splitScalar(u8, range_text.?, ',');
    while (chunks.next()) |chunk| {
        if (chunk.len == 0) return invalidSelector(arena, raw, error_message);
        try ranges.append(arena, try parseRangeChunk(arena, chunk, error_message));
    }
    if (ranges.items.len == 0) return invalidSelector(arena, raw, error_message);
    std.mem.sort(Range, ranges.items, {}, struct {
        fn lessThan(_: void, a: Range, b: Range) bool {
            return a.start < b.start;
        }
    }.lessThan);
    var merged: std.ArrayList(Range) = .empty;
    for (ranges.items) |range| {
        if (merged.items.len == 0) {
            try merged.append(arena, range);
            continue;
        }
        const last = &merged.items[merged.items.len - 1];
        if (last.end == null) continue;
        if (range.start <= last.end.? +| 1) {
            if (range.end == null or range.end.? > last.end.?) last.end = range.end;
        } else {
            try merged.append(arena, range);
        }
    }

    const requested_ranges = try arena.dupe(Range, merged.items);
    if (!raw_mode) {
        for (merged.items) |*range| {
            if (range.start > 1) range.start -= RANGE_LEADING_CONTEXT_LINES;
            if (range.end) |end| range.end = end +| RANGE_TRAILING_CONTEXT_LINES;
        }
        mergeExpandedRanges(merged.items);
    }
    return .{
        .raw = raw_mode,
        .explicit = true,
        .ranges = try compactRanges(arena, merged.items),
        .requested_ranges = requested_ranges,
    };
}

fn parseRangeChunk(arena: Allocator, chunk: []const u8, error_message: *?[]const u8) !Range {
    var normalized = chunk;
    if (normalized.len > 0 and (normalized[0] == 'L' or normalized[0] == 'l')) normalized = normalized[1..];
    if (normalized.len == 0) return invalidSelector(arena, chunk, error_message);
    var digit_end: usize = 0;
    while (digit_end < normalized.len and std.ascii.isDigit(normalized[digit_end])) digit_end += 1;
    if (digit_end == 0) return invalidSelector(arena, chunk, error_message);
    const start = std.fmt.parseInt(usize, normalized[0..digit_end], 10) catch return invalidSelector(arena, chunk, error_message);
    if (start == 0) {
        error_message.* = "Line selector 0 is invalid; lines are 1-indexed. Use :1.";
        return error.InvalidSelector;
    }
    if (digit_end == normalized.len) return .{ .start = start, .end = null };

    const rest = normalized[digit_end..];
    const separator_len: usize = if (std.mem.startsWith(u8, rest, "..")) 2 else 1;
    const separator = rest[0];
    if (separator != '-' and separator != '+' and !std.mem.startsWith(u8, rest, "..")) return invalidSelector(arena, chunk, error_message);
    var rhs_text = rest[separator_len..];
    if (rhs_text.len > 0 and (rhs_text[0] == 'L' or rhs_text[0] == 'l')) rhs_text = rhs_text[1..];
    if (rhs_text.len == 0) {
        if (separator == '+') {
            error_message.* = try std.fmt.allocPrint(arena, "Invalid range {d}+0: count must be >= 1.", .{start});
            return error.InvalidSelector;
        }
        return .{ .start = start, .end = null };
    }
    for (rhs_text) |byte| if (!std.ascii.isDigit(byte)) return invalidSelector(arena, chunk, error_message);
    const rhs = std.fmt.parseInt(usize, rhs_text, 10) catch return invalidSelector(arena, chunk, error_message);
    if (separator == '+') {
        if (rhs < 1) {
            error_message.* = try std.fmt.allocPrint(arena, "Invalid range {d}+{d}: count must be >= 1.", .{ start, rhs });
            return error.InvalidSelector;
        }
        return .{ .start = start, .end = start +| rhs - 1 };
    }
    if (rhs < start) {
        error_message.* = try std.fmt.allocPrint(arena, "Invalid range {d}-{d}: end must be >= start.", .{ start, rhs });
        return error.InvalidSelector;
    }
    return .{ .start = start, .end = rhs };
}

fn invalidSelector(arena: Allocator, selector: []const u8, error_message: *?[]const u8) error{ InvalidSelector, OutOfMemory } {
    error_message.* = try std.fmt.allocPrint(
        arena,
        "Invalid selector ':{s}'. Use :N, :N-M, :N+K, :N- (open-ended), a comma-separated list of ranges, :raw, or a range combined with raw (e.g. :raw:50-100).",
        .{selector},
    );
    return error.InvalidSelector;
}

fn mergeExpandedRanges(ranges: []Range) void {
    if (ranges.len < 2) return;
    var write_index: usize = 0;
    for (ranges[1..]) |range| {
        const last = &ranges[write_index];
        if (last.end == null or range.start <= last.end.? +| 1) {
            if (last.end != null and (range.end == null or range.end.? > last.end.?)) last.end = range.end;
        } else {
            write_index += 1;
            ranges[write_index] = range;
        }
    }
    if (write_index + 1 < ranges.len) ranges[write_index + 1].start = 0;
}

fn compactRanges(arena: Allocator, ranges: []const Range) ![]const Range {
    var length = ranges.len;
    for (ranges, 0..) |range, index| if (index > 0 and range.start == 0) {
        length = index;
        break;
    };
    return arena.dupe(Range, ranges[0..length]);
}

fn readFile(
    state: *SessionState,
    io: std.Io,
    arena: Allocator,
    absolute: []const u8,
    selector: Selector,
    on_update: ?tool_api.OnUpdate,
    cancel: *const tool_api.CancelToken,
) !tool_api.ToolOutcome {
    const max_lines = selectionLineLimit(state, selector);
    const max_bytes = @max(MAX_BYTES, max_lines *| 512);
    const display_mode = state.displayMode(selector.raw, false);
    const scan = scanFile(io, arena, absolute, selector.ranges, max_lines, max_bytes, cancel) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return err;
        return errorText(arena, try std.fmt.allocPrint(arena, "Cannot read '{s}': {s}", .{ absolute, @errorName(err) }));
    };

    if (scan.lines.len == 0 and selector.ranges.len == 1 and selector.ranges[0].start > scan.total_lines) {
        const requested = selector.ranges[0].start + if (!selector.raw and selector.ranges[0].start > 1) @as(usize, RANGE_LEADING_CONTEXT_LINES) else 0;
        const suggestion = if (scan.total_lines == 0)
            "The file is empty."
        else
            try std.fmt.allocPrint(arena, "Use :1 to read from the start, or :{d} to read the last line.", .{scan.total_lines});
        return textOutcome(arena, try std.fmt.allocPrint(
            arena,
            "Line {d} is beyond end of file ({d} lines total). {s}",
            .{ requested, scan.total_lines, suggestion },
        ));
    }
    if (scan.lines.len == 0 and scan.stopped_by_byte_limit) {
        const line_number = selector.ranges[0].start;
        const line_size = try output.formatBytes(arena, scan.first_line_bytes orelse scan.total_bytes);
        const limit_size = try output.formatBytes(arena, max_bytes);
        const preview = scan.first_line_preview orelse "";
        if (!display_mode.hash_lines and preview.len != 0) {
            if (display_mode.line_numbers) {
                return textOutcome(arena, try std.fmt.allocPrint(arena, "{d}|{s}", .{ line_number, preview }));
            }
            return textOutcome(arena, preview);
        }
        if (preview.len == 0) return textOutcome(arena, try std.fmt.allocPrint(
            arena,
            "[Line {d} is {s}, exceeds {s} limit. Unable to display a valid UTF-8 snippet.]",
            .{ line_number, line_size, limit_size },
        ));
        return textOutcome(arena, try std.fmt.allocPrint(
            arena,
            "[Line {d} is {s}, exceeds {s} limit. Hashline output requires full lines; cannot emit an editable numbered preview for a truncated line.]",
            .{ line_number, line_size, limit_size },
        ));
    }

    var seen: std.ArrayList(usize) = .empty;
    var plain: std.ArrayList(u8) = .empty;
    var rendered: std.ArrayList(u8) = .empty;
    var line_numbers: std.json.Array = .init(arena);
    const first_line: usize = if (scan.lines.len > 0) scan.lines[0].number else 1;
    var previous: ?usize = null;
    for (scan.lines) |line| {
        if (previous) |number| if (line.number > number + 1) {
            if (plain.items.len != 0) try plain.append(arena, '\n');
            try plain.appendSlice(arena, "…");
            try line_numbers.append(.null);
            if (rendered.items.len != 0) try rendered.append(arena, '\n');
            try rendered.appendSlice(arena, "…");
        };
        if (plain.items.len != 0) try plain.append(arena, '\n');
        var display_text = line.text;
        var clipped = false;
        if (!selector.raw and state.settings.output_max_columns > 0 and display_text.len > state.settings.output_max_columns) {
            const keep = utf8Prefix(display_text, state.settings.output_max_columns -| "…".len);
            display_text = try std.mem.concat(arena, u8, &.{ display_text[0..keep], "…" });
            clipped = true;
        }
        try plain.appendSlice(arena, display_text);
        try line_numbers.append(.{ .integer = @intCast(line.number) });
        if (rendered.items.len != 0) try rendered.append(arena, '\n');
        if (selector.raw) {
            try rendered.appendSlice(arena, display_text);
        } else if (display_mode.hash_lines) {
            try rendered.print(arena, "{d}:{s}", .{ line.number, display_text });
        } else if (display_mode.line_numbers) {
            try rendered.print(arena, "{d}|{s}", .{ line.number, display_text });
        } else {
            try rendered.appendSlice(arena, display_text);
        }
        if (!clipped) try seen.append(arena, line.number);
        previous = line.number;
    }

    var tag: ?hashline.FileHash = null;
    if (scan.snapshot_text) |snapshot_text| {
        tag = try state.recordReadSnapshot(io, absolute, snapshot_text, seen.items);
    }
    if (display_mode.hash_lines) if (tag) |file_hash| {
        const anchor = try readAnchor(state, arena, absolute);
        const header = try hashline.formatHashlineHeader(arena, anchor, &file_hash);
        const body = try rendered.toOwnedSlice(arena);
        rendered = .empty;
        try rendered.appendSlice(arena, header);
        if (body.len != 0) try rendered.print(arena, "\n{s}", .{body});
    };

    if (selector.explicit and selector.ranges.len > 1) {
        for (selector.ranges) |range| if (range.start > scan.total_lines) {
            const requested_start = range.start + if (!selector.raw and range.start > 1) @as(usize, RANGE_LEADING_CONTEXT_LINES) else 0;
            const requested_end: ?usize = if (range.end) |end| end -| @as(usize, RANGE_TRAILING_CONTEXT_LINES) else null;
            if (rendered.items.len != 0) try rendered.appendSlice(arena, "\n\n");
            if (requested_end) |end| {
                try rendered.print(arena, "Range {d}-{d} is beyond end of file ({d} lines total); skipped", .{ requested_start, end, scan.total_lines });
            } else {
                try rendered.print(arena, "Range {d}- is beyond end of file ({d} lines total); skipped", .{ requested_start, scan.total_lines });
            }
        };
    }

    const truncated = scan.lines.len < scan.selected_lines or scan.stopped_by_byte_limit;
    const total_selected_lines = if (selector.ranges.len == 1)
        scan.total_lines -| (selector.ranges[0].start -| 1)
    else
        scan.selected_lines;
    if (truncated and scan.lines.len > 0) {
        const next = scan.lines[scan.lines.len - 1].number + 1;
        const notice = try output.formatOutputNotice(arena, .{
            .direction = .head,
            .truncated_by = if (scan.stopped_by_byte_limit) .bytes else .lines,
            .total_lines = total_selected_lines,
            .total_bytes = scan.total_bytes,
            .output_lines = scan.lines.len,
            .output_bytes = scan.collected_bytes,
            .max_bytes = max_bytes,
            .shown_range = if (selector.ranges.len == 1) .{
                .start = scan.lines[0].number,
                .end = scan.lines[scan.lines.len - 1].number,
            } else null,
            .next_offset = next,
        });
        try rendered.appendSlice(arena, notice);
    }

    const text = try throughOutputSink(arena, try rendered.toOwnedSlice(arena));
    var display_content: std.json.ObjectMap = .empty;
    try display_content.put(arena, "text", .{ .string = try plain.toOwnedSlice(arena) });
    try display_content.put(arena, "startLine", .{ .integer = @intCast(first_line) });
    try display_content.put(arena, "lineNumbers", .{ .array = line_numbers });
    var details: std.json.ObjectMap = .empty;
    try details.put(arena, "kind", .{ .string = "file" });
    try details.put(arena, "resolvedPath", .{ .string = absolute });
    try details.put(arena, "displayContent", .{ .object = display_content });
    if (truncated) {
        var truncation: std.json.ObjectMap = .empty;
        try truncation.put(arena, "direction", .{ .string = "head" });
        try truncation.put(arena, "truncatedBy", .{ .string = if (scan.stopped_by_byte_limit) "bytes" else "lines" });
        try truncation.put(arena, "totalLines", .{ .integer = @intCast(total_selected_lines) });
        try truncation.put(arena, "totalBytes", .{ .integer = @intCast(scan.total_bytes) });
        try truncation.put(arena, "outputLines", .{ .integer = @intCast(scan.lines.len) });
        try truncation.put(arena, "outputBytes", .{ .integer = @intCast(scan.collected_bytes) });
        try truncation.put(arena, "maxBytes", .{ .integer = @intCast(max_bytes) });
        if (scan.lines.len > 0) try truncation.put(arena, "nextOffset", .{ .integer = @intCast(scan.lines[scan.lines.len - 1].number + 1) });
        if (selector.ranges.len == 1 and scan.lines.len > 0) {
            var shown_range: std.json.ObjectMap = .empty;
            try shown_range.put(arena, "start", .{ .integer = @intCast(scan.lines[0].number) });
            try shown_range.put(arena, "end", .{ .integer = @intCast(scan.lines[scan.lines.len - 1].number) });
            try truncation.put(arena, "shownRange", .{ .object = shown_range });
        }
        try details.put(arena, "truncation", .{ .object = truncation });
    }
    const outcome = try outcomeWithDetails(arena, text, .{ .object = details }, false);
    if (on_update) |update| update(outcome);
    return outcome;
}

fn scanFile(
    io: std.Io,
    arena: Allocator,
    absolute: []const u8,
    ranges: []const Range,
    max_lines: usize,
    max_bytes: usize,
    cancel: *const tool_api.CancelToken,
) !ScanResult {
    var file = try std.Io.Dir.openFileAbsolute(io, absolute, .{ .allow_directory = false });
    defer file.close(io);
    var reader_buffer: [8192]u8 = undefined;
    var file_reader = file.readerStreaming(io, &reader_buffer);

    var snapshot_raw: std.ArrayList(u8) = .empty;
    var snapshot_possible = true;
    var current: std.ArrayList(u8) = .empty;
    var selected: std.ArrayList(SelectedLine) = .empty;
    var line_number: usize = 1;
    var current_bytes: usize = 0;
    var collected_bytes: usize = 0;
    var selected_lines: usize = 0;
    var stopped_by_byte_limit = false;
    var first_line_bytes: ?usize = null;
    var first_line_preview: ?[]const u8 = null;
    var total_bytes: usize = 0;
    var buffer: [8192]u8 = undefined;

    while (true) {
        try cancel.check();
        const count = file_reader.interface.readSliceShort(&buffer) catch |err| switch (err) {
            error.ReadFailed => return file_reader.err.?,
        };
        if (count == 0) break;
        total_bytes += count;
        if (snapshot_possible) {
            if (snapshot_raw.items.len + count <= session_state.snapshot_max_bytes) {
                try snapshot_raw.appendSlice(arena, buffer[0..count]);
            } else {
                snapshot_possible = false;
                snapshot_raw.clearRetainingCapacity();
            }
        }
        for (buffer[0..count]) |byte| {
            if (byte == '\n') {
                try finishLine(arena, ranges, max_lines, max_bytes, line_number, current.items, current_bytes, &selected, &selected_lines, &collected_bytes, &stopped_by_byte_limit, &first_line_bytes, &first_line_preview);
                current.clearRetainingCapacity();
                current_bytes = 0;
                line_number += 1;
                continue;
            }
            current_bytes += 1;
            if (lineInRanges(line_number, ranges) and selected.items.len < max_lines and !stopped_by_byte_limit and current.items.len <= max_bytes) {
                try current.append(arena, byte);
            }
        }
    }
    try finishLine(arena, ranges, max_lines, max_bytes, line_number, current.items, current_bytes, &selected, &selected_lines, &collected_bytes, &stopped_by_byte_limit, &first_line_bytes, &first_line_preview);

    const snapshot_text = if (snapshot_possible) try hashline.normalizeToLf(arena, snapshot_raw.items) else null;
    return .{
        .lines = try selected.toOwnedSlice(arena),
        .total_lines = line_number,
        .total_bytes = total_bytes,
        .selected_lines = selected_lines,
        .collected_bytes = collected_bytes,
        .stopped_by_byte_limit = stopped_by_byte_limit,
        .first_line_bytes = first_line_bytes,
        .first_line_preview = first_line_preview,
        .snapshot_text = snapshot_text,
    };
}

fn finishLine(
    arena: Allocator,
    ranges: []const Range,
    max_lines: usize,
    max_bytes: usize,
    line_number: usize,
    buffered: []const u8,
    line_bytes: usize,
    selected: *std.ArrayList(SelectedLine),
    selected_lines: *usize,
    collected_bytes: *usize,
    stopped_by_byte_limit: *bool,
    first_line_bytes: *?usize,
    first_line_preview: *?[]const u8,
) !void {
    if (!lineInRanges(line_number, ranges)) return;
    selected_lines.* += 1;
    if (first_line_bytes.* == null) {
        first_line_bytes.* = line_bytes;
        if (line_bytes > max_bytes) {
            const preview_end = utf8Prefix(buffered, @min(buffered.len, max_bytes));
            first_line_preview.* = try arena.dupe(u8, buffered[0..preview_end]);
        }
    }
    if (selected.items.len >= max_lines or stopped_by_byte_limit.*) return;
    const separator_bytes: usize = @intFromBool(selected.items.len > 0);
    if (line_bytes > buffered.len or collected_bytes.* + separator_bytes + line_bytes > max_bytes) {
        stopped_by_byte_limit.* = true;
        return;
    }
    try selected.append(arena, .{ .number = line_number, .text = try arena.dupe(u8, buffered) });
    collected_bytes.* += separator_bytes + line_bytes;
}

fn selectionLineLimit(state: *const SessionState, selector: Selector) usize {
    var bounded_total: usize = 0;
    for (selector.ranges, 0..) |range, index| {
        const requested = selector.requested_ranges[@min(index, selector.requested_ranges.len - 1)];
        const end = range.end orelse {
            const leading_context = @intFromBool(!selector.raw and selector.explicit and requested.start > 1);
            return @min(state.settings.read_default_limit +| leading_context, MAX_LINES);
        };
        bounded_total +|= end - range.start + 1;
    }
    return @min(bounded_total, MAX_LINES);
}

fn lineInRanges(line: usize, ranges: []const Range) bool {
    for (ranges) |range| {
        if (line < range.start) continue;
        if (range.end == null or line <= range.end.?) return true;
    }
    return false;
}

fn readDirectory(
    io: std.Io,
    arena: Allocator,
    absolute: []const u8,
    selector: Selector,
    on_update: ?tool_api.OnUpdate,
) !tool_api.ToolOutcome {
    if (selector.ranges.len > 1) return errorText(arena, "Multi-range line selectors are not supported for directory listings");
    var rendered_lines: std.ArrayList(DirectoryLine) = .empty;
    try rendered_lines.append(arena, .{ .label = "." });
    try collectDirectory(io, arena, absolute, 0, &rendered_lines);
    if (rendered_lines.items.len == 1) return directoryOutcome(arena, absolute, "(empty directory)", on_update);
    const tree = try formatDirectoryLines(arena, rendered_lines.items);
    const lines = try splitLines(arena, tree);
    const requested = selector.requested_ranges[0];
    const start = if (selector.explicit) requested.start else 1;
    if (start > lines.len) {
        const suggestion = try std.fmt.allocPrint(arena, "Use :1 to read from the start, or :{d} to read the last line.", .{lines.len});
        return directoryOutcome(arena, absolute, try std.fmt.allocPrint(
            arena,
            "Line {d} is beyond end of listing ({d} lines total). {s}",
            .{ start, lines.len, suggestion },
        ), on_update);
    }
    const end = if (selector.explicit) @min(requested.end orelse lines.len, lines.len) else lines.len;
    var text = try std.mem.join(arena, "\n", lines[start - 1 .. end]);
    if (end < lines.len) text = try std.fmt.allocPrint(
        arena,
        "{s}\n\n[{d} more lines in listing. Use :{d} to continue]",
        .{ text, lines.len - end, end + 1 },
    );
    return directoryOutcome(arena, absolute, text, on_update);
}

const DirectoryNode = struct {
    name: []const u8,
    kind: std.Io.File.Kind,
    size: u64,
    mtime_ns: i96,
};

const DirectoryLine = struct {
    label: []const u8,
    size: ?[]const u8 = null,
    age: ?[]const u8 = null,
};

fn collectDirectory(io: std.Io, arena: Allocator, absolute: []const u8, depth: usize, output_lines: *std.ArrayList(DirectoryLine)) anyerror!void {
    if (depth >= 2) return;
    var dir = try std.Io.Dir.openDirAbsolute(io, absolute, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    var nodes: std.ArrayList(DirectoryNode) = .empty;
    while (try iterator.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".DS_Store")) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        if (stat.kind == .directory and pruneDirectory(entry.name)) continue;
        try nodes.append(arena, .{
            .name = try arena.dupe(u8, entry.name),
            .kind = stat.kind,
            .size = stat.size,
            .mtime_ns = stat.mtime.nanoseconds,
        });
    }
    std.mem.sort(DirectoryNode, nodes.items, {}, struct {
        fn lessThan(_: void, a: DirectoryNode, b: DirectoryNode) bool {
            if (a.mtime_ns != b.mtime_ns) return a.mtime_ns > b.mtime_ns;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    const limit: usize = if (depth == 0) nodes.items.len else 12;
    const dropped = nodes.items.len -| limit;
    const recent_count = if (dropped > 0) limit - 1 else nodes.items.len;
    for (nodes.items[0..recent_count]) |node| try appendDirectoryNode(io, arena, absolute, depth, node, output_lines);
    if (dropped > 0) {
        try output_lines.append(arena, .{ .label = try std.fmt.allocPrint(arena, "{s}- … {d} more", .{ indent(depth + 1), dropped }) });
        try appendDirectoryNode(io, arena, absolute, depth, nodes.items[nodes.items.len - 1], output_lines);
    }
}

fn pruneDirectory(name: []const u8) bool {
    const pruned = [_][]const u8{
        ".git",
        "node_modules",
        "build",
        "dist",
        "target",
        "zig-out",
        ".zig-cache",
        ".cache",
        ".next",
        ".turbo",
        "coverage",
        "__pycache__",
    };
    for (pruned) |entry| if (std.mem.eql(u8, name, entry)) return true;
    return false;
}

fn appendDirectoryNode(io: std.Io, arena: Allocator, parent: []const u8, depth: usize, node: DirectoryNode, lines: *std.ArrayList(DirectoryLine)) anyerror!void {
    const is_dir = node.kind == .directory;
    const label = try std.fmt.allocPrint(arena, "{s}- {s}{s}", .{ indent(depth + 1), node.name, if (is_dir) "/" else "" });
    try lines.append(arena, .{
        .label = label,
        .size = if (is_dir) null else try formatBytes(arena, node.size),
        .age = try formatAge(arena, io, node.mtime_ns),
    });
    if (is_dir) {
        const child = try std.fs.path.join(arena, &.{ parent, node.name });
        try collectDirectory(io, arena, child, depth + 1, lines);
    }
}

fn formatDirectoryLines(arena: Allocator, lines: []const DirectoryLine) ![]const u8 {
    var width: usize = 0;
    for (lines) |line| width = @max(width, line.label.len);
    var output_text: std.ArrayList(u8) = .empty;
    for (lines, 0..) |line, index| {
        if (index > 0) try output_text.append(arena, '\n');
        try output_text.appendSlice(arena, line.label);
        if (line.age) |age| {
            try output_text.appendNTimes(arena, ' ', width + 2 - line.label.len);
            const size = line.size orelse "";
            try output_text.appendSlice(arena, size);
            try output_text.appendNTimes(arena, ' ', 10 -| size.len);
            try output_text.appendSlice(arena, age);
        }
    }
    return output_text.toOwnedSlice(arena);
}

fn indent(depth: usize) []const u8 {
    const spaces = "                                                                ";
    return spaces[0..@min(spaces.len, depth * 2)];
}

fn formatBytes(arena: Allocator, bytes: u64) ![]const u8 {
    if (bytes < 1024) return std.fmt.allocPrint(arena, "{d}B", .{bytes});
    if (bytes < 1024 * 1024) return std.fmt.allocPrint(arena, "{d:.1}KB", .{@as(f64, @floatFromInt(bytes)) / 1024.0});
    if (bytes < 1024 * 1024 * 1024) return std.fmt.allocPrint(arena, "{d:.1}MB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)});
    return std.fmt.allocPrint(arena, "{d:.1}GB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0)});
}

fn formatAge(arena: Allocator, io: std.Io, mtime_ns: i96) ![]const u8 {
    if (mtime_ns == 0) return arena.dupe(u8, "");
    const now = std.Io.Clock.real.now(io).nanoseconds;
    const seconds: u64 = @intCast(@max(@as(i96, 0), @divTrunc(now - mtime_ns, std.time.ns_per_s)));
    const minutes = seconds / 60;
    const hours = minutes / 60;
    const days = hours / 24;
    const weeks = days / 7;
    const months = days / 30;
    if (months > 0) return std.fmt.allocPrint(arena, "{d}mo ago", .{months});
    if (weeks > 0) return std.fmt.allocPrint(arena, "{d}w ago", .{weeks});
    if (days > 0) return std.fmt.allocPrint(arena, "{d}d ago", .{days});
    if (hours > 0) return std.fmt.allocPrint(arena, "{d}h ago", .{hours});
    if (minutes > 0) return std.fmt.allocPrint(arena, "{d}m ago", .{minutes});
    return arena.dupe(u8, "just now");
}

fn splitLines(arena: Allocator, text: []const u8) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var iterator = std.mem.splitScalar(u8, text, '\n');
    while (iterator.next()) |line| try lines.append(arena, line);
    return lines.toOwnedSlice(arena);
}

fn readAnchor(state: *SessionState, arena: Allocator, absolute: []const u8) ![]const u8 {
    const display = try state.real_fs.displayPath(arena, absolute);
    if (!std.fs.path.isAbsolute(display)) return arena.dupe(u8, std.fs.path.basename(display));
    return state.real_fs.shortPath(arena, absolute);
}

fn utf8Prefix(text: []const u8, max_bytes: usize) usize {
    var index: usize = 0;
    while (index < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        if (index + length > max_bytes or index + length > text.len) break;
        index += length;
    }
    return index;
}

fn unsupportedSurface(path: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, path, "://") != null or std.mem.startsWith(u8, path, "www.")) return "URLs and internal resources";
    const extensions = [_]struct { suffix: []const u8, label: []const u8 }{
        .{ .suffix = ".zip", .label = "archives" },
        .{ .suffix = ".tar", .label = "archives" },
        .{ .suffix = ".tar.gz", .label = "archives" },
        .{ .suffix = ".tgz", .label = "archives" },
        .{ .suffix = ".sqlite", .label = "SQLite" },
        .{ .suffix = ".sqlite3", .label = "SQLite" },
        .{ .suffix = ".db", .label = "SQLite" },
        .{ .suffix = ".db3", .label = "SQLite" },
        .{ .suffix = ".pdf", .label = "documents" },
        .{ .suffix = ".doc", .label = "documents" },
        .{ .suffix = ".docx", .label = "documents" },
        .{ .suffix = ".ppt", .label = "documents" },
        .{ .suffix = ".pptx", .label = "documents" },
        .{ .suffix = ".xls", .label = "documents" },
        .{ .suffix = ".xlsx", .label = "documents" },
        .{ .suffix = ".rtf", .label = "documents" },
        .{ .suffix = ".epub", .label = "documents" },
        .{ .suffix = ".ipynb", .label = "notebooks" },
        .{ .suffix = ".png", .label = "images" },
        .{ .suffix = ".jpg", .label = "images" },
        .{ .suffix = ".jpeg", .label = "images" },
        .{ .suffix = ".gif", .label = "images" },
        .{ .suffix = ".webp", .label = "images" },
    };
    for (extensions) |entry| if (endsWithIgnoreCase(path, entry.suffix) or containsSuffixSelector(path, entry.suffix)) return entry.label;
    return null;
}

fn containsSuffixSelector(path: []const u8, suffix: []const u8) bool {
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, path, index, suffix)) |found| {
        const after = found + suffix.len;
        if (after < path.len and path[after] == ':') return true;
        index = found + 1;
    }
    return false;
}

fn endsWithIgnoreCase(text: []const u8, suffix: []const u8) bool {
    if (text.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(text[text.len - suffix.len ..], suffix);
}

const PathSelector = struct { path: []const u8, selector: ?[]const u8 };

fn literalPathExists(state: *SessionState, io: std.Io, arena: Allocator, path: []const u8) !bool {
    const absolute = state.real_fs.resolve(arena, path) catch return false;
    _ = std.Io.Dir.cwd().statFile(io, absolute, .{ .follow_symlinks = false }) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => false,
        else => true,
    };
    return true;
}

fn splitInlineSelector(path: []const u8) PathSelector {
    const last = std.mem.lastIndexOfScalar(u8, path, ':') orelse return .{ .path = path, .selector = null };
    if (last == 0) return .{ .path = path, .selector = null };
    const outer = path[last + 1 ..];
    if (!looksLikeSelector(outer)) return .{ .path = path, .selector = null };
    var base = path[0..last];
    var selector = outer;
    if (std.mem.lastIndexOfScalar(u8, base, ':')) |inner| {
        if (inner > 0) {
            const first = base[inner + 1 ..];
            const compound = (std.ascii.eqlIgnoreCase(first, "raw") and looksLikeRange(outer)) or
                (looksLikeRange(first) and std.ascii.eqlIgnoreCase(outer, "raw"));
            if (compound) {
                selector = path[inner + 1 ..];
                base = path[0..inner];
            }
        }
    }
    return .{ .path = base, .selector = selector };
}

fn looksLikeSelector(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "raw") or looksLikeRange(value);
}

fn looksLikeRange(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and byte != 'L' and byte != 'l' and byte != '-' and byte != '+' and byte != '.' and byte != ',') return false;
    return true;
}

fn directoryOutcome(arena: Allocator, absolute: []const u8, text: []const u8, on_update: ?tool_api.OnUpdate) !tool_api.ToolOutcome {
    var details: std.json.ObjectMap = .empty;
    try details.put(arena, "isDirectory", .{ .bool = true });
    try details.put(arena, "resolvedPath", .{ .string = absolute });
    const outcome = try outcomeWithDetails(arena, try throughOutputSink(arena, text), .{ .object = details }, false);
    if (on_update) |update| update(outcome);
    return outcome;
}

fn throughOutputSink(arena: Allocator, text: []const u8) ![]const u8 {
    var sink = output.OutputSink.init(arena, .{
        .spill_threshold = @max(@as(usize, 1), text.len),
        .max_columns = 0,
    });
    defer sink.deinit();
    try sink.push(text);
    var summary = try sink.dump(null);
    defer summary.deinit(arena);
    return arena.dupe(u8, summary.output);
}

fn textOutcome(arena: Allocator, text: []const u8) !tool_api.ToolOutcome {
    return outcomeWithDetails(arena, text, null, false);
}

fn errorText(arena: Allocator, text: []const u8) !tool_api.ToolOutcome {
    return outcomeWithDetails(arena, text, null, true);
}

fn outcomeWithDetails(arena: Allocator, text: []const u8, details: ?std.json.Value, is_error: bool) !tool_api.ToolOutcome {
    const content = try arena.alloc(tool_api.ResultBlock, 1);
    content[0] = .{ .text = text };
    return .{ .content = content, .details = details, .is_error = is_error };
}

test "read selector grammar locks exact validation text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var message: ?[]const u8 = null;
    try std.testing.expectError(error.InvalidSelector, parseSelector(arena, "0", &message));
    try std.testing.expectEqualStrings("Line selector 0 is invalid; lines are 1-indexed. Use :1.", message.?);
    message = null;
    try std.testing.expectError(error.InvalidSelector, parseSelector(arena, "4+0", &message));
    try std.testing.expectEqualStrings("Invalid range 4+0: count must be >= 1.", message.?);
    message = null;
    try std.testing.expectError(error.InvalidSelector, parseSelector(arena, "9-3", &message));
    try std.testing.expectEqualStrings("Invalid range 9-3: end must be >= start.", message.?);
    message = null;
    try std.testing.expectError(error.InvalidSelector, parseSelector(arena, "wat", &message));
    try std.testing.expectEqualStrings(
        "Invalid selector ':wat'. Use :N, :N-M, :N+K, :N- (open-ended), a comma-separated list of ranges, :raw, or a range combined with raw (e.g. :raw:50-100).",
        message.?,
    );
}

test "read formats hashline ranges directories and records snapshots" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "sample.txt", .data = "one\ntwo\nthree\nfour\nfive\n" });
    try tmp.dir.createDirPath(io, "dir/nested");
    try tmp.dir.writeFile(io, .{ .sub_path = "dir/a.txt", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "dir/nested/b.txt", .data = "bb" });
    const cwd = try fs_real.dirRealPathAlloc(allocator, io, tmp.dir);
    defer allocator.free(cwd);
    var state = try SessionState.init(allocator, io, .{ .cwd = cwd });
    defer state.deinit();
    var cancelled = std.atomic.Value(bool).init(false);
    var timed_out = std.atomic.Value(bool).init(false);
    const cancel: tool_api.CancelToken = .{ .batch_cancelled = &cancelled, .timed_out = &timed_out };

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const input = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\"sample.txt\",\"selector\":\"3-3\"}", .{});
    const result = try execute(&state, io, arena, input, null, &cancel);
    const tag = hashline.computeFileHash("one\ntwo\nthree\nfour\nfive\n");
    const expected = try std.fmt.allocPrint(arena, "[sample.txt#{s}]\n2:two\n3:three\n4:four\n5:five\n6:", .{&tag});
    try std.testing.expectEqualStrings(expected, result.content[0].text);
    const absolute = try state.real_fs.resolve(arena, "sample.txt");
    const snapshot = state.snapshots.byHash(absolute, &tag) orelse return error.TestUnexpectedResult;
    try std.testing.expect(snapshot.hasSeenLine(2));
    try std.testing.expect(snapshot.hasSeenLine(5));

    const raw_input = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\"sample.txt\",\"selector\":\"raw:3-3\"}", .{});
    const raw_result = try execute(&state, io, arena, raw_input, null, &cancel);
    try std.testing.expectEqualStrings("three", raw_result.content[0].text);

    state.settings.read_default_limit = 2;
    const limited_input = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\"sample.txt\"}", .{});
    const limited = try execute(&state, io, arena, limited_input, null, &cancel);
    const limited_expected = try std.fmt.allocPrint(
        arena,
        "[sample.txt#{s}]\n1:one\n2:two\n\n[Showing lines 1-2 of 6. Use :3 to continue]",
        .{&tag},
    );
    try std.testing.expectEqualStrings(limited_expected, limited.content[0].text);
    try std.testing.expectEqualStrings("head", limited.details.?.object.get("truncation").?.object.get("direction").?.string);

    const dir_input = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\"dir\"}", .{});
    const dir_result = try execute(&state, io, arena, dir_input, null, &cancel);
    try std.testing.expect(dir_result.details.?.object.get("isDirectory").?.bool);
    try std.testing.expect(std.mem.indexOf(u8, dir_result.content[0].text, "a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, dir_result.content[0].text, "nested/") != null);
    try std.testing.expect(std.mem.indexOf(u8, dir_result.content[0].text, "b.txt") != null);
}

test "read directory leaves top-level children uncapped" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "many");
    var name_buffer: [64]u8 = undefined;
    for (0..20) |index| {
        const name = try std.fmt.bufPrint(&name_buffer, "many/entry-{d:0>2}.txt", .{index});
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "x" });
    }
    const cwd = try fs_real.dirRealPathAlloc(allocator, io, tmp.dir);
    defer allocator.free(cwd);
    var state = try SessionState.init(allocator, io, .{ .cwd = cwd });
    defer state.deinit();
    var cancelled = std.atomic.Value(bool).init(false);
    var timed_out = std.atomic.Value(bool).init(false);
    const cancel: tool_api.CancelToken = .{ .batch_cancelled = &cancelled, .timed_out = &timed_out };
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const input = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\"many\"}", .{});
    const result = try execute(&state, io, arena, input, null, &cancel);
    for (0..20) |index| {
        const name = try std.fmt.allocPrint(arena, "entry-{d:0>2}.txt", .{index});
        try std.testing.expect(std.mem.indexOf(u8, result.content[0].text, name) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text, "more") == null);
}

test "read directory prunes standard non-source directories" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/.git");
    try tmp.dir.createDirPath(io, "repo/node_modules/pkg");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.git/config", .data = "ignored" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/node_modules/pkg/index.js", .data = "ignored" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/source.zig", .data = "visible" });
    try tmp.dir.createDirPath(io, "repo/hidden-only/.git");
    const tmp_root = try fs_real.dirRealPathAlloc(allocator, io, tmp.dir);
    defer allocator.free(tmp_root);
    const cwd = try std.fs.path.join(allocator, &.{ tmp_root, "repo" });
    defer allocator.free(cwd);
    var state = try SessionState.init(allocator, io, .{ .cwd = cwd });
    defer state.deinit();
    var cancelled = std.atomic.Value(bool).init(false);
    var timed_out = std.atomic.Value(bool).init(false);
    const cancel: tool_api.CancelToken = .{ .batch_cancelled = &cancelled, .timed_out = &timed_out };
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const repo_input = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\".\"}", .{});
    const repo = try execute(&state, io, arena, repo_input, null, &cancel);
    try std.testing.expect(std.mem.indexOf(u8, repo.content[0].text, "source.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, repo.content[0].text, ".git") == null);
    try std.testing.expect(std.mem.indexOf(u8, repo.content[0].text, "node_modules") == null);

    const hidden_input = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\"hidden-only\"}", .{});
    const hidden = try execute(&state, io, arena, hidden_input, null, &cancel);
    try std.testing.expectEqualStrings("(empty directory)", hidden.content[0].text);
}

test "read directory selector starts at the requested second line" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "dir");
    try tmp.dir.writeFile(io, .{ .sub_path = "dir/only.txt", .data = "x" });
    const cwd = try fs_real.dirRealPathAlloc(allocator, io, tmp.dir);
    defer allocator.free(cwd);
    var state = try SessionState.init(allocator, io, .{ .cwd = cwd });
    defer state.deinit();
    var cancelled = std.atomic.Value(bool).init(false);
    var timed_out = std.atomic.Value(bool).init(false);
    const cancel: tool_api.CancelToken = .{ .batch_cancelled = &cancelled, .timed_out = &timed_out };
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const input = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\"dir:2\"}", .{});
    const result = try execute(&state, io, arena, input, null, &cancel);
    try std.testing.expect(std.mem.startsWith(u8, result.content[0].text, "  - only.txt"));
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text, "\n.") == null);
}

test "read open-ended offset includes leading context in its line budget" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var file_text: std.ArrayList(u8) = .empty;
    for (1..501) |line| try file_text.print(arena, "line {d}\n", .{line});
    try tmp.dir.writeFile(io, .{ .sub_path = "large.txt", .data = file_text.items });
    const cwd = try fs_real.dirRealPathAlloc(allocator, io, tmp.dir);
    defer allocator.free(cwd);
    var state = try SessionState.init(allocator, io, .{ .cwd = cwd });
    defer state.deinit();
    var cancelled = std.atomic.Value(bool).init(false);
    var timed_out = std.atomic.Value(bool).init(false);
    const cancel: tool_api.CancelToken = .{ .batch_cancelled = &cancelled, .timed_out = &timed_out };
    const input = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\"large.txt:50-\"}", .{});
    const result = try execute(&state, io, arena, input, null, &cancel);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text, "\n49:line 49\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text, "\n349:line 349\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text, "\n350:line 350\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text, "Use :350 to continue") != null);
}

test "read prefers an existing literal path with a selector-shaped suffix" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "test:1-2", .data = "literal\n" });
    const cwd = try fs_real.dirRealPathAlloc(allocator, io, tmp.dir);
    defer allocator.free(cwd);
    var state = try SessionState.init(allocator, io, .{ .cwd = cwd });
    defer state.deinit();
    var cancelled = std.atomic.Value(bool).init(false);
    var timed_out = std.atomic.Value(bool).init(false);
    const cancel: tool_api.CancelToken = .{ .batch_cancelled = &cancelled, .timed_out = &timed_out };
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const input = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\"test:1-2\"}", .{});
    const result = try execute(&state, io, arena, input, null, &cancel);
    const tag = hashline.computeFileHash("literal\n");
    const expected = try std.fmt.allocPrint(arena, "[test:1-2#{s}]\n1:literal\n2:", .{&tag});
    try std.testing.expectEqualStrings(expected, result.content[0].text);
}

test "read bounded range cap reports remaining file lines" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var file_text: std.ArrayList(u8) = .empty;
    for (1..5001) |line| {
        if (line > 1) try file_text.append(arena, '\n');
        try file_text.print(arena, "line {d}", .{line});
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "five-thousand.txt", .data = file_text.items });
    const cwd = try fs_real.dirRealPathAlloc(allocator, io, tmp.dir);
    defer allocator.free(cwd);
    var state = try SessionState.init(allocator, io, .{ .cwd = cwd });
    defer state.deinit();
    var cancelled = std.atomic.Value(bool).init(false);
    var timed_out = std.atomic.Value(bool).init(false);
    const cancel: tool_api.CancelToken = .{ .batch_cancelled = &cancelled, .timed_out = &timed_out };
    const input = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"path\":\"five-thousand.txt:1-4000\"}",
        .{},
    );
    const result = try execute(&state, io, arena, input, null, &cancel);
    try std.testing.expect(std.mem.indexOf(
        u8,
        result.content[0].text,
        "[Showing lines 1-3000 of 5000. Use :3001 to continue]",
    ) != null);
    try std.testing.expectEqual(@as(i64, 5000), result.details.?.object.get("truncation").?.object.get("totalLines").?.integer);
}

test "read oversized first line follows the selected display mode" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const long_line = try arena.alloc(u8, MAX_BYTES + 1);
    @memset(long_line, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "one-line.txt", .data = long_line });
    const cwd = try fs_real.dirRealPathAlloc(allocator, io, tmp.dir);
    defer allocator.free(cwd);
    var state = try SessionState.init(allocator, io, .{ .cwd = cwd, .settings = .{ .read_default_limit = 1 } });
    defer state.deinit();
    var cancelled = std.atomic.Value(bool).init(false);
    var timed_out = std.atomic.Value(bool).init(false);
    const cancel: tool_api.CancelToken = .{ .batch_cancelled = &cancelled, .timed_out = &timed_out };
    const input = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\"one-line.txt\"}", .{});

    const hashline_result = try execute(&state, io, arena, input, null, &cancel);
    try std.testing.expect(std.mem.indexOf(u8, hashline_result.content[0].text, "Hashline output requires full lines") != null);

    state.settings.has_edit_tool = false;
    const plain_result = try execute(&state, io, arena, input, null, &cancel);
    try std.testing.expectEqual(@as(usize, MAX_BYTES), plain_result.content[0].text.len);
    try std.testing.expect(std.mem.indexOf(u8, plain_result.content[0].text, "requires full lines") == null);

    state.settings.read_line_numbers = true;
    const numbered_result = try execute(&state, io, arena, input, null, &cancel);
    try std.testing.expect(std.mem.startsWith(u8, numbered_result.content[0].text, "1|xxxx"));
    try std.testing.expectEqual(@as(usize, MAX_BYTES + 2), numbered_result.content[0].text.len);
}
