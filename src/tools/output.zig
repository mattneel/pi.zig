//! Bounded, UTF-8-safe tool output and byte-exact truncation notices.
//!
//! `truncateHead` returns a borrowed slice of its input. `OutputSink` owns its
//! streaming buffers; `dump` returns an allocator-owned `OutputSummary` that
//! the caller must deinitialize. When an `ArtifactSink` is configured, raw
//! bytes are staged until truncation occurs because the deliberately small
//! artifact interface stores one complete byte slice.

const std = @import("std");

pub const DEFAULT_MAX_LINES: usize = 3000;
pub const DEFAULT_MAX_BYTES: usize = 50 * 1024;
pub const DEFAULT_MAX_COLUMN: usize = 512;

pub const DEFAULT_HEAD_BYTES: usize = 20 * 1024;
pub const DEFAULT_TAIL_BYTES: usize = 20 * 1024;
pub const DEFAULT_TAIL_LINES: usize = 500;
pub const DEFAULT_OUTPUT_MAX_COLUMNS: usize = 768;

const ellipsis = "\u{2026}";

pub const TruncatedBy = enum {
    lines,
    bytes,
    middle,
};

pub const TruncationOptions = struct {
    max_lines: usize = DEFAULT_MAX_LINES,
    max_bytes: usize = DEFAULT_MAX_BYTES,
};

/// `content` borrows from the input passed to `truncateHead`.
pub const TruncationResult = struct {
    content: []const u8,
    truncated: bool,
    truncated_by: ?TruncatedBy,
    total_lines: usize,
    total_bytes: usize,
    output_lines: usize,
    output_bytes: usize,
    last_line_partial: bool = false,
    first_line_exceeds_limit: bool = false,
};

/// Keep complete leading lines within both limits. This is a direct port of
/// `session/streaming-output.ts::truncateHead`.
pub fn truncateHead(content: []const u8, options: TruncationOptions) TruncationResult {
    const total_bytes = content.len;
    const total_lines = logicalLineCount(content);

    if (total_lines <= options.max_lines and total_bytes <= options.max_bytes) {
        return .{
            .content = content,
            .truncated = false,
            .truncated_by = null,
            .total_lines = total_lines,
            .total_bytes = total_bytes,
            .output_lines = total_lines,
            .output_bytes = total_bytes,
        };
    }

    var included_lines: usize = 0;
    var bytes_used: usize = 0;
    var cut_index: usize = 0;
    var cursor: usize = 0;
    var truncated_by: TruncatedBy = .lines;

    while (included_lines < options.max_lines) {
        const newline = std.mem.indexOfScalarPos(u8, content, cursor, '\n');
        const line_end = newline orelse content.len;
        const separator_bytes: usize = if (included_lines > 0) 1 else 0;

        if (bytes_used + separator_bytes > options.max_bytes) {
            truncated_by = .bytes;
            break;
        }
        const remaining = options.max_bytes - bytes_used - separator_bytes;
        const line_bytes = line_end - cursor;
        if (line_bytes > remaining) {
            truncated_by = .bytes;
            if (included_lines == 0) {
                return .{
                    .content = content[0..0],
                    .truncated = true,
                    .truncated_by = .bytes,
                    .total_lines = total_lines,
                    .total_bytes = total_bytes,
                    .output_lines = 0,
                    .output_bytes = 0,
                    .first_line_exceeds_limit = true,
                };
            }
            break;
        }

        bytes_used += separator_bytes + line_bytes;
        included_lines += 1;
        cut_index = line_end;
        if (newline == null) break;
        cursor = line_end + 1;
    }

    if (included_lines >= options.max_lines and bytes_used <= options.max_bytes) {
        truncated_by = .lines;
    }

    return .{
        .content = content[0..cut_index],
        .truncated = true,
        .truncated_by = truncated_by,
        .total_lines = total_lines,
        .total_bytes = total_bytes,
        .output_lines = included_lines,
        .output_bytes = bytes_used,
    };
}

/// Keep complete trailing lines within both limits. A single overlong final
/// line keeps a UTF-8-safe byte tail, matching upstream `truncateTail`.
pub fn truncateTail(content: []const u8, options: TruncationOptions) TruncationResult {
    const total_bytes = content.len;
    const total_lines = logicalLineCount(content);
    if (total_lines <= options.max_lines and total_bytes <= options.max_bytes) {
        return .{
            .content = content,
            .truncated = false,
            .truncated_by = null,
            .total_lines = total_lines,
            .total_bytes = total_bytes,
            .output_lines = total_lines,
            .output_bytes = total_bytes,
        };
    }

    var included_lines: usize = 0;
    var bytes_used: usize = 0;
    var start_index = content.len;
    var end = content.len;
    var truncated_by: TruncatedBy = .lines;
    while (included_lines < options.max_lines) {
        const newline = if (end == 0) null else std.mem.lastIndexOfScalar(u8, content[0..end], '\n');
        const line_start = if (newline) |position| position + 1 else 0;
        const separator_bytes: usize = if (included_lines > 0) 1 else 0;
        if (bytes_used + separator_bytes > options.max_bytes) {
            truncated_by = .bytes;
            break;
        }
        const remaining = options.max_bytes - bytes_used - separator_bytes;
        const line_bytes = end - line_start;
        if (line_bytes > remaining) {
            truncated_by = .bytes;
            if (included_lines == 0) {
                const start = utf8TailStart(content[line_start..end], options.max_bytes) + line_start;
                return .{
                    .content = content[start..end],
                    .truncated = true,
                    .truncated_by = .bytes,
                    .total_lines = total_lines,
                    .total_bytes = total_bytes,
                    .output_lines = 1,
                    .output_bytes = end - start,
                    .last_line_partial = true,
                };
            }
            break;
        }
        bytes_used += separator_bytes + line_bytes;
        included_lines += 1;
        start_index = line_start;
        if (newline == null) break;
        end = newline.?;
    }
    if (included_lines >= options.max_lines and bytes_used <= options.max_bytes) truncated_by = .lines;
    return .{
        .content = content[start_index..],
        .truncated = true,
        .truncated_by = truncated_by,
        .total_lines = total_lines,
        .total_bytes = total_bytes,
        .output_lines = included_lines,
        .output_bytes = bytes_used,
    };
}

pub const SpillLargeResultOptions = struct {
    threshold: usize = DEFAULT_MAX_BYTES,
    head_bytes: usize = DEFAULT_HEAD_BYTES,
    tail_bytes: usize = DEFAULT_TAIL_BYTES,
    tail_lines: usize = DEFAULT_TAIL_LINES,
    artifact_sink: ?ArtifactSink = null,
};

pub const SpillLargeResult = struct {
    output: []u8,
    truncation: ?TruncationMeta = null,
    artifact_id: ?[]u8 = null,

    pub fn deinit(self: *SpillLargeResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        if (self.artifact_id) |id| allocator.free(id);
        self.* = undefined;
    }
};

/// Post-tool wrapper for complete results. Unlike `OutputSink`, this layer uses
/// line-aligned head/tail windows and the 500-line cap on both sides.
pub fn spillLargeResultToArtifact(
    allocator: std.mem.Allocator,
    full_text: []const u8,
    existing_artifact_id: ?[]const u8,
    options: SpillLargeResultOptions,
) !SpillLargeResult {
    if (existing_artifact_id) |id| return .{
        .output = try allocator.dupe(u8, full_text),
        .artifact_id = try allocator.dupe(u8, id),
    };
    if (full_text.len <= options.threshold) return .{ .output = try allocator.dupe(u8, full_text) };

    var artifact_id: ?[]u8 = null;
    errdefer if (artifact_id) |id| allocator.free(id);
    if (options.artifact_sink) |sink| {
        if (sink.store(full_text) catch null) |borrowed| {
            artifact_id = try allocator.dupe(u8, borrowed);
        }
    }

    const head = truncateHead(full_text, .{
        .max_bytes = options.head_bytes,
        .max_lines = options.tail_lines,
    });
    const tail = truncateTail(full_text, .{
        .max_bytes = options.tail_bytes,
        .max_lines = options.tail_lines,
    });
    if (options.head_bytes == 0 or head.output_lines == 0 or head.first_line_exceeds_limit) {
        const output = try allocator.dupe(u8, tail.content);
        return .{
            .output = output,
            .artifact_id = artifact_id,
            .truncation = .{
                .direction = .tail,
                .truncated_by = tail.truncated_by orelse .bytes,
                .total_lines = tail.total_lines,
                .total_bytes = tail.total_bytes,
                .output_lines = tail.output_lines,
                .output_bytes = tail.output_bytes,
                .max_bytes = options.tail_bytes,
                .shown_range = .{
                    .start = tail.total_lines -| tail.output_lines + 1,
                    .end = tail.total_lines,
                },
                .artifact_id = artifact_id,
            },
        };
    }
    if (head.output_lines + tail.output_lines >= head.total_lines) {
        return .{ .output = try allocator.dupe(u8, full_text), .artifact_id = artifact_id };
    }

    const elided_lines = head.total_lines - head.output_lines - tail.output_lines;
    const elided_bytes = head.total_bytes -| (head.output_bytes + tail.output_bytes);
    const marker = try formatMiddleElisionMarker(allocator, elided_lines, elided_bytes);
    defer allocator.free(marker);
    const output = try std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}", .{ head.content, marker, tail.content });
    return .{
        .output = output,
        .artifact_id = artifact_id,
        .truncation = .{
            .direction = .middle,
            .truncated_by = .middle,
            .total_lines = head.total_lines,
            .total_bytes = head.total_bytes,
            .output_lines = head.output_lines + 1 + tail.output_lines,
            .output_bytes = output.len,
            .max_bytes = options.head_bytes + options.tail_bytes,
            .head_range = .{ .start = 1, .end = head.output_lines },
            .tail_range = .{
                .start = head.total_lines - tail.output_lines + 1,
                .end = head.total_lines,
            },
            .elided_bytes = elided_bytes,
            .elided_lines = elided_lines,
            .artifact_id = artifact_id,
        },
    };
}

pub const ArtifactSink = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The returned ID is borrowed from the adapter. `OutputSink.dump`
        /// duplicates it into the summary allocator.
        store: *const fn (context: *anyopaque, bytes: []const u8) anyerror![]const u8,
    };

    pub fn store(self: ArtifactSink, bytes: []const u8) ![]const u8 {
        return self.vtable.store(self.context, bytes);
    }
};

/// Leak-checked artifact adapter useful to callers as well as module tests.
pub const InMemoryArtifactSink = struct {
    const Artifact = struct {
        id: []u8,
        bytes: []u8,
    };

    allocator: std.mem.Allocator,
    artifacts: std.ArrayList(Artifact) = .empty,
    next_id: usize = 1,

    pub fn init(allocator: std.mem.Allocator) InMemoryArtifactSink {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *InMemoryArtifactSink) void {
        for (self.artifacts.items) |artifact| {
            self.allocator.free(artifact.id);
            self.allocator.free(artifact.bytes);
        }
        self.artifacts.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn sink(self: *InMemoryArtifactSink) ArtifactSink {
        return .{ .context = self, .vtable = &vtable };
    }

    pub fn get(self: *const InMemoryArtifactSink, id: []const u8) ?[]const u8 {
        for (self.artifacts.items) |artifact| {
            if (std.mem.eql(u8, artifact.id, id)) return artifact.bytes;
        }
        return null;
    }

    fn storeErased(context: *anyopaque, bytes: []const u8) ![]const u8 {
        const self: *InMemoryArtifactSink = @ptrCast(@alignCast(context));
        const id = try std.fmt.allocPrint(self.allocator, "{d}", .{self.next_id});
        errdefer self.allocator.free(id);
        const owned_bytes = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(owned_bytes);
        try self.artifacts.append(self.allocator, .{ .id = id, .bytes = owned_bytes });
        self.next_id += 1;
        return id;
    }

    const vtable: ArtifactSink.VTable = .{ .store = storeErased };
};

pub const OutputSinkOptions = struct {
    spill_threshold: usize = DEFAULT_MAX_BYTES,
    head_bytes: usize = 0,
    max_columns: usize = DEFAULT_OUTPUT_MAX_COLUMNS,
    artifact_sink: ?ArtifactSink = null,
    /// Identity when absent. The Phase 1c bash tool supplies terminal-control
    /// sanitization here so counting, retention, and artifacts see one stream.
    sanitize_hook: ?*const fn (
        allocator: std.mem.Allocator,
        chunk: []const u8,
        output: *std.ArrayList(u8),
    ) anyerror!void = null,
};

pub const OutputSummary = struct {
    output: []u8,
    truncated: bool,
    total_lines: usize,
    total_bytes: usize,
    output_lines: usize,
    output_bytes: usize,
    elided_bytes: ?usize = null,
    elided_lines: ?usize = null,
    column_dropped_bytes: ?usize = null,
    column_truncated_lines: ?usize = null,
    artifact_id: ?[]u8 = null,

    pub fn deinit(self: *OutputSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        if (self.artifact_id) |id| allocator.free(id);
        self.* = undefined;
    }
};

pub const OutputSink = struct {
    allocator: std.mem.Allocator,
    options: OutputSinkOptions,
    raw: std.ArrayList(u8) = .empty,
    pending_utf8: std.ArrayList(u8) = .empty,
    head: std.ArrayList(u8) = .empty,
    tail: std.ArrayList(u8) = .empty,
    total_bytes: usize = 0,
    total_newlines: usize = 0,
    saw_data: bool = false,
    truncated: bool = false,
    artifact_needed: bool = false,
    current_line_bytes: usize = 0,
    column_ellipsis_added: bool = false,
    column_dropped_bytes: usize = 0,
    column_truncated_lines: usize = 0,

    pub fn init(allocator: std.mem.Allocator, options: OutputSinkOptions) OutputSink {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn deinit(self: *OutputSink) void {
        self.raw.deinit(self.allocator);
        self.pending_utf8.deinit(self.allocator);
        self.head.deinit(self.allocator);
        self.tail.deinit(self.allocator);
        self.* = undefined;
    }

    /// Accept arbitrary byte chunk boundaries. Invalid UTF-8 is replaced with
    /// U+FFFD and incomplete sequences are retained until a later push or dump.
    pub fn push(self: *OutputSink, chunk: []const u8) !void {
        if (chunk.len == 0) return;

        var combined: std.ArrayList(u8) = .empty;
        defer combined.deinit(self.allocator);
        try combined.ensureTotalCapacity(
            self.allocator,
            self.pending_utf8.items.len + chunk.len,
        );
        try combined.appendSlice(self.allocator, self.pending_utf8.items);
        try combined.appendSlice(self.allocator, chunk);
        var decoded: std.ArrayList(u8) = .empty;
        defer decoded.deinit(self.allocator);
        const consumed = try decodeUtf8Lossy(self.allocator, combined.items, false, &decoded);
        try self.processDecoded(decoded.items);

        self.pending_utf8.clearRetainingCapacity();
        try self.pending_utf8.appendSlice(self.allocator, combined.items[consumed..]);
    }

    /// Produce an owned snapshot. The sink remains reusable after this call.
    pub fn dump(self: *OutputSink, notice: ?[]const u8) !OutputSummary {
        try self.flushPendingUtf8();

        var artifact_id: ?[]u8 = null;
        errdefer if (artifact_id) |id| self.allocator.free(id);
        if (self.artifact_needed) {
            if (self.options.artifact_sink) |sink| {
                const borrowed_id = try sink.store(self.raw.items);
                artifact_id = try self.allocator.dupe(u8, borrowed_id);
            }
        }

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        if (notice) |text| try output.print(self.allocator, "[{s}]\n", .{text});
        var elided_bytes: ?usize = null;
        var elided_lines: ?usize = null;

        const effective_total_bytes = self.total_bytes -| self.column_dropped_bytes;
        if (self.head.items.len > 0 and effective_total_bytes > self.head.items.len + self.tail.items.len) {
            const total_lines = self.totalLines();
            const head_lines = retainedHeadLines(self.head.items);
            const tail_lines = streamLineCount(self.tail.items);
            const middle_bytes = effective_total_bytes -| (self.head.items.len + self.tail.items.len);
            const middle_lines = total_lines -| (head_lines + tail_lines);
            const marker = try formatMiddleElisionMarker(self.allocator, middle_lines, middle_bytes);
            defer self.allocator.free(marker);

            try output.appendSlice(self.allocator, self.head.items);
            if (!std.mem.endsWith(u8, self.head.items, "\n")) try output.append(self.allocator, '\n');
            try output.appendSlice(self.allocator, marker);
            if (!std.mem.startsWith(u8, self.tail.items, "\n")) try output.append(self.allocator, '\n');
            try output.appendSlice(self.allocator, self.tail.items);
            elided_bytes = middle_bytes;
            elided_lines = middle_lines;
            self.truncated = true;
        } else if (self.head.items.len > 0) {
            try output.appendSlice(self.allocator, self.head.items);
            try output.appendSlice(self.allocator, self.tail.items);
        } else {
            try output.appendSlice(self.allocator, self.tail.items);
        }

        const owned_output = try output.toOwnedSlice(self.allocator);
        const notice_bytes = if (notice) |text| text.len + 3 else 0;
        const body = owned_output[notice_bytes..];
        return .{
            .output = owned_output,
            .truncated = self.truncated,
            .total_lines = self.totalLines(),
            .total_bytes = self.total_bytes,
            .output_lines = streamLineCount(body),
            .output_bytes = body.len,
            .elided_bytes = elided_bytes,
            .elided_lines = elided_lines,
            .column_dropped_bytes = if (self.column_dropped_bytes == 0) null else self.column_dropped_bytes,
            .column_truncated_lines = if (self.column_truncated_lines == 0) null else self.column_truncated_lines,
            .artifact_id = artifact_id,
        };
    }

    fn totalLines(self: *const OutputSink) usize {
        return if (self.saw_data) self.total_newlines + 1 else 0;
    }

    fn flushPendingUtf8(self: *OutputSink) !void {
        if (self.pending_utf8.items.len == 0) return;
        var decoded: std.ArrayList(u8) = .empty;
        defer decoded.deinit(self.allocator);
        _ = try decodeUtf8Lossy(self.allocator, self.pending_utf8.items, true, &decoded);
        self.pending_utf8.clearRetainingCapacity();
        try self.processDecoded(decoded.items);
    }

    fn processDecoded(self: *OutputSink, decoded: []const u8) !void {
        if (decoded.len == 0) return;
        var sanitized: std.ArrayList(u8) = .empty;
        defer sanitized.deinit(self.allocator);
        if (self.options.sanitize_hook) |sanitize| {
            try sanitize(self.allocator, decoded, &sanitized);
        } else {
            try sanitized.appendSlice(self.allocator, decoded);
        }
        if (sanitized.items.len == 0) return;

        if (self.options.artifact_sink != null) try self.raw.appendSlice(self.allocator, sanitized.items);
        self.total_bytes += sanitized.items.len;
        self.total_newlines += std.mem.count(u8, sanitized.items, "\n");
        self.saw_data = true;

        var capped: std.ArrayList(u8) = .empty;
        defer capped.deinit(self.allocator);
        const dropped_before = self.column_dropped_bytes;
        try self.applyColumnCap(sanitized.items, &capped);
        if (self.column_dropped_bytes != dropped_before) self.artifact_needed = true;
        try self.appendCapped(capped.items);
    }

    fn applyColumnCap(self: *OutputSink, input: []const u8, output: *std.ArrayList(u8)) !void {
        if (self.options.max_columns == 0) {
            try output.appendSlice(self.allocator, input);
            return;
        }

        var cursor: usize = 0;
        while (cursor < input.len) {
            const newline = std.mem.indexOfScalarPos(u8, input, cursor, '\n');
            const segment_end = newline orelse input.len;
            const segment = input[cursor..segment_end];
            if (segment.len > 0) {
                if (self.column_ellipsis_added) {
                    self.column_dropped_bytes += segment.len;
                } else {
                    const remaining = self.options.max_columns -| self.current_line_bytes;
                    if (segment.len <= remaining) {
                        try output.appendSlice(self.allocator, segment);
                        self.current_line_bytes += segment.len;
                    } else {
                        const head_room = remaining -| ellipsis.len;
                        const kept_len = utf8PrefixAtMost(segment, head_room);
                        try output.appendSlice(self.allocator, segment[0..kept_len]);
                        try output.appendSlice(self.allocator, ellipsis);
                        self.column_dropped_bytes += segment.len - kept_len;
                        self.column_truncated_lines += 1;
                        self.current_line_bytes += kept_len + ellipsis.len;
                        self.column_ellipsis_added = true;
                        self.truncated = true;
                    }
                }
            }
            if (newline == null) break;
            try output.append(self.allocator, '\n');
            self.current_line_bytes = 0;
            self.column_ellipsis_added = false;
            cursor = segment_end + 1;
        }
    }

    fn appendCapped(self: *OutputSink, input: []const u8) !void {
        if (input.len == 0) return;
        var tail_input = input;

        if (self.options.head_bytes > 0 and self.head.items.len < self.options.head_bytes) {
            const room = self.options.head_bytes - self.head.items.len;
            if (input.len <= room) {
                try self.head.appendSlice(self.allocator, input);
                return;
            }
            const kept_len = utf8PrefixAtMost(input, room);
            try self.head.appendSlice(self.allocator, input[0..kept_len]);
            tail_input = input[kept_len..];
        }

        try self.pushTail(tail_input);
    }

    fn pushTail(self: *OutputSink, input: []const u8) !void {
        if (input.len == 0) return;
        const threshold = self.options.spill_threshold;
        if (self.tail.items.len + input.len <= threshold) {
            try self.tail.appendSlice(self.allocator, input);
            return;
        }
        self.truncated = true;
        self.artifact_needed = true;

        if (input.len >= threshold) {
            self.tail.clearRetainingCapacity();
            const start = utf8TailStart(input, threshold);
            try self.tail.appendSlice(self.allocator, input[start..]);
            return;
        }
        try self.tail.appendSlice(self.allocator, input);
        const start = utf8TailStart(self.tail.items, threshold);
        dropPrefix(&self.tail, start);
    }
};

pub const LineRange = struct {
    start: usize,
    end: usize,
};

pub const TruncationDirection = enum {
    head,
    tail,
    middle,
};

/// Metadata consumed by the byte-exact upstream notice formatter.
pub const TruncationMeta = struct {
    direction: TruncationDirection,
    truncated_by: TruncatedBy,
    total_lines: usize,
    total_bytes: usize,
    output_lines: usize,
    output_bytes: usize,
    max_bytes: ?usize = null,
    shown_range: ?LineRange = null,
    head_range: ?LineRange = null,
    tail_range: ?LineRange = null,
    elided_bytes: ?usize = null,
    elided_lines: ?usize = null,
    artifact_id: ?[]const u8 = null,
    next_offset: ?usize = null,
};

pub fn formatFullOutputReference(allocator: std.mem.Allocator, artifact_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "Read artifact://{s} for full output", .{artifact_id});
}

pub fn formatBashArtifactFooter(allocator: std.mem.Allocator, artifact_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "[raw output: artifact://{s}]", .{artifact_id});
}

/// Port of `output-meta.ts::formatTruncationMetaNotice`, without surrounding
/// brackets (the wrapper adds those when attaching it to model output).
pub fn formatTruncationMetaNotice(allocator: std.mem.Allocator, meta: TruncationMeta) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    if (meta.direction == .middle) {
        if (meta.head_range != null and meta.tail_range != null) {
            const head = meta.head_range.?;
            const tail = meta.tail_range.?;
            const elided_lines = meta.elided_lines orelse meta.total_lines -| meta.output_lines;
            const elided_bytes = meta.elided_bytes orelse meta.total_bytes -| meta.output_bytes;
            try output.print(
                allocator,
                "Showing lines {d}-{d} and {d}-{d} of {d}; ",
                .{ head.start, head.end, tail.start, tail.end, meta.total_lines },
            );
            try appendGroupedInteger(&output, allocator, elided_lines);
            try output.appendSlice(allocator, " middle line");
            if (elided_lines != 1) try output.append(allocator, 's');
            try output.appendSlice(allocator, " (");
            try appendFormattedBytes(&output, allocator, elided_bytes);
            try output.appendSlice(allocator, ") elided");
        } else {
            try output.print(
                allocator,
                "Showing {d} of {d} lines; middle elided",
                .{ meta.output_lines, meta.total_lines },
            );
        }
        if (meta.artifact_id) |artifact_id| {
            try output.print(allocator, ". Read artifact://{s} for full output", .{artifact_id});
        }
        return output.toOwnedSlice(allocator);
    }

    if (meta.shown_range) |range| {
        if (range.end >= range.start) {
            try output.print(
                allocator,
                "Showing lines {d}-{d} of {d}",
                .{ range.start, range.end, meta.total_lines },
            );
        } else {
            try output.print(
                allocator,
                "Showing {d} of {d} lines",
                .{ meta.output_lines, meta.total_lines },
            );
        }
    } else {
        try output.print(
            allocator,
            "Showing {d} of {d} lines",
            .{ meta.output_lines, meta.total_lines },
        );
    }

    if (meta.truncated_by == .bytes) {
        try output.appendSlice(allocator, " (");
        try appendFormattedBytes(&output, allocator, meta.max_bytes orelse meta.output_bytes);
        try output.appendSlice(allocator, " limit)");
    }
    if (meta.next_offset) |next_offset| {
        try output.print(allocator, ". Use :{d} to continue", .{next_offset});
    }
    if (meta.artifact_id) |artifact_id| {
        try output.print(allocator, ". Read artifact://{s} for full output", .{artifact_id});
    }
    return output.toOwnedSlice(allocator);
}

/// Model-facing wrapper used when appending one truncation notice to text.
pub fn formatOutputNotice(allocator: std.mem.Allocator, meta: TruncationMeta) ![]u8 {
    const body = try formatTruncationMetaNotice(allocator, meta);
    defer allocator.free(body);
    return std.fmt.allocPrint(allocator, "\n\n[{s}]", .{body});
}

/// Port of `output-meta.ts::formatOutputNotice` for persisted opaque metadata.
pub fn formatOutputMetaNoticeValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    const object = switch (value) {
        .object => |item| item,
        else => return allocator.dupe(u8, ""),
    };
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var part_count: usize = 0;

    if (object.get("truncation")) |raw| {
        const parsed = try parseTruncationMeta(raw);
        const text = try formatTruncationMetaNotice(allocator, parsed);
        defer allocator.free(text);
        try appendNoticePart(&output, allocator, &part_count, text);
    }

    if (object.get("limits")) |raw_limits| if (raw_limits == .object) {
        const limits = raw_limits.object;
        if (try parseLimit(limits, "matchLimit")) |limit| {
            const text = try std.fmt.allocPrint(
                allocator,
                "{d} matches limit reached. Use limit={d} for more",
                .{ limit.reached, limit.suggestion },
            );
            defer allocator.free(text);
            try appendNoticePart(&output, allocator, &part_count, text);
        }
        if (try parseLimit(limits, "resultLimit")) |limit| {
            const text = try std.fmt.allocPrint(
                allocator,
                "{d} results limit reached. Use limit={d} for more",
                .{ limit.reached, limit.suggestion },
            );
            defer allocator.free(text);
            try appendNoticePart(&output, allocator, &part_count, text);
        }
        if (try parseLimit(limits, "headLimit")) |limit| {
            const text = try std.fmt.allocPrint(
                allocator,
                "{d} results limit reached. Use limit={d} for more",
                .{ limit.reached, limit.suggestion },
            );
            defer allocator.free(text);
            try appendNoticePart(&output, allocator, &part_count, text);
        }
        if (limits.get("columnTruncated")) |raw_column| if (raw_column == .object) {
            const max_column = try requiredNonNegativeInteger(raw_column.object, "maxColumn");
            const text = try std.fmt.allocPrint(
                allocator,
                "Some lines truncated to {d} chars",
                .{max_column},
            );
            defer allocator.free(text);
            try appendNoticePart(&output, allocator, &part_count, text);
        };
    };
    if (part_count != 0) try output.append(allocator, ']');

    if (object.get("diagnostics")) |raw_diagnostics| if (raw_diagnostics == .object) {
        const diagnostics = raw_diagnostics.object;
        if (diagnostics.get("messages")) |messages| if (messages == .array and messages.array.items.len != 0) {
            const summary = try requiredString(diagnostics, "summary");
            try output.print(allocator, "\n\nLSP Diagnostics ({s}):", .{summary});
            for (messages.array.items) |item| {
                const text = switch (item) {
                    .string => |message_text| message_text,
                    else => return error.UnexpectedToken,
                };
                try output.print(allocator, "\n{s}", .{text});
            }
        };
    };
    return output.toOwnedSlice(allocator);
}

fn appendNoticePart(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    count: *usize,
    text: []const u8,
) !void {
    if (count.* == 0) {
        try output.appendSlice(allocator, "\n\n[");
    } else {
        try output.appendSlice(allocator, ". ");
    }
    try output.appendSlice(allocator, text);
    count.* += 1;
}

const RawLimit = struct { reached: usize, suggestion: usize };

fn parseLimit(object: std.json.ObjectMap, name: []const u8) !?RawLimit {
    const raw = object.get(name) orelse return null;
    if (raw != .object) return error.UnexpectedToken;
    return .{
        .reached = try requiredNonNegativeInteger(raw.object, "reached"),
        .suggestion = try requiredNonNegativeInteger(raw.object, "suggestion"),
    };
}

fn parseTruncationMeta(value: std.json.Value) !TruncationMeta {
    const object = switch (value) {
        .object => |item| item,
        else => return error.UnexpectedToken,
    };
    return .{
        .direction = std.meta.stringToEnum(
            TruncationDirection,
            try requiredString(object, "direction"),
        ) orelse return error.InvalidEnumTag,
        .truncated_by = std.meta.stringToEnum(
            TruncatedBy,
            try requiredString(object, "truncatedBy"),
        ) orelse return error.InvalidEnumTag,
        .total_lines = try requiredNonNegativeInteger(object, "totalLines"),
        .total_bytes = try requiredNonNegativeInteger(object, "totalBytes"),
        .output_lines = try requiredNonNegativeInteger(object, "outputLines"),
        .output_bytes = try requiredNonNegativeInteger(object, "outputBytes"),
        .max_bytes = try optionalNonNegativeInteger(object, "maxBytes"),
        .shown_range = try optionalLineRange(object, "shownRange"),
        .head_range = try optionalLineRange(object, "headRange"),
        .tail_range = try optionalLineRange(object, "tailRange"),
        .elided_bytes = try optionalNonNegativeInteger(object, "elidedBytes"),
        .elided_lines = try optionalNonNegativeInteger(object, "elidedLines"),
        .artifact_id = try optionalString(object, "artifactId"),
        .next_offset = try optionalNonNegativeInteger(object, "nextOffset"),
    };
}

fn requiredString(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return switch (object.get(name) orelse return error.MissingField) {
        .string => |text| text,
        else => error.UnexpectedToken,
    };
}

fn optionalString(object: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => error.UnexpectedToken,
    };
}

fn requiredNonNegativeInteger(object: std.json.ObjectMap, name: []const u8) !usize {
    return switch (object.get(name) orelse return error.MissingField) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else error.Overflow,
        else => error.UnexpectedToken,
    };
}

fn optionalNonNegativeInteger(object: std.json.ObjectMap, name: []const u8) !?usize {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else error.Overflow,
        else => error.UnexpectedToken,
    };
}

fn optionalLineRange(object: std.json.ObjectMap, name: []const u8) !?LineRange {
    const value = object.get(name) orelse return null;
    if (value != .object) return error.UnexpectedToken;
    return .{
        .start = try requiredNonNegativeInteger(value.object, "start"),
        .end = try requiredNonNegativeInteger(value.object, "end"),
    };
}

pub fn formatBytes(allocator: std.mem.Allocator, bytes: usize) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try appendFormattedBytes(&output, allocator, bytes);
    return output.toOwnedSlice(allocator);
}

pub fn formatMiddleElisionMarker(
    allocator: std.mem.Allocator,
    elided_lines: usize,
    elided_bytes: usize,
) ![]u8 {
    if (elided_lines <= 1) {
        return std.fmt.allocPrint(allocator, "[\u{2026}{d}B elided\u{2026}]", .{elided_bytes});
    }
    return std.fmt.allocPrint(allocator, "[\u{2026}{d}ln elided\u{2026}]", .{elided_lines});
}

fn appendFormattedBytes(output: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: usize) !void {
    if (bytes < 1024) {
        try output.print(allocator, "{d}B", .{bytes});
    } else if (bytes < 1024 * 1024) {
        try output.print(allocator, "{d:.1}KB", .{@as(f64, @floatFromInt(bytes)) / 1024.0});
    } else if (bytes < 1024 * 1024 * 1024) {
        try output.print(allocator, "{d:.1}MB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)});
    } else {
        try output.print(
            allocator,
            "{d:.1}GB",
            .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0)},
        );
    }
}

fn appendGroupedInteger(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: usize) !void {
    if (value < 1000) {
        try output.print(allocator, "{d}", .{value});
        return;
    }
    try appendGroupedInteger(output, allocator, value / 1000);
    const group = value % 1000;
    try output.append(allocator, ',');
    try output.append(allocator, @intCast('0' + group / 100));
    try output.append(allocator, @intCast('0' + (group / 10) % 10));
    try output.append(allocator, @intCast('0' + group % 10));
}

fn logicalLineCount(content: []const u8) usize {
    return std.mem.count(u8, content, "\n") + 1;
}

fn streamLineCount(content: []const u8) usize {
    return if (content.len == 0) 0 else logicalLineCount(content);
}

fn retainedHeadLines(content: []const u8) usize {
    if (content.len == 0) return 0;
    const newlines = std.mem.count(u8, content, "\n");
    return newlines + @intFromBool(content[content.len - 1] != '\n');
}

fn decodeUtf8Lossy(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    flush: bool,
    output: *std.ArrayList(u8),
) !usize {
    var index: usize = 0;
    while (index < bytes.len) {
        if (bytes[index] < 0x80) {
            try output.append(allocator, bytes[index]);
            index += 1;
            continue;
        }
        const sequence_len = std.unicode.utf8ByteSequenceLength(bytes[index]) catch {
            try output.appendSlice(allocator, "\xef\xbf\xbd");
            index += 1;
            continue;
        };
        if (index + sequence_len > bytes.len) {
            if (!flush) return index;
            try output.appendSlice(allocator, "\xef\xbf\xbd");
            return bytes.len;
        }
        _ = std.unicode.utf8Decode(bytes[index .. index + sequence_len]) catch {
            try output.appendSlice(allocator, "\xef\xbf\xbd");
            index += 1;
            continue;
        };
        try output.appendSlice(allocator, bytes[index .. index + sequence_len]);
        index += sequence_len;
    }
    return index;
}

fn utf8PrefixAtMost(bytes: []const u8, max_bytes: usize) usize {
    var index: usize = 0;
    while (index < bytes.len) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(bytes[index]) catch return index;
        if (index + sequence_len > bytes.len or index + sequence_len > max_bytes) return index;
        index += sequence_len;
    }
    return index;
}

fn isUtf8Continuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

fn utf8TailStart(bytes: []const u8, max_bytes: usize) usize {
    if (bytes.len <= max_bytes) return 0;
    var start = bytes.len - max_bytes;
    while (start < bytes.len and isUtf8Continuation(bytes[start])) : (start += 1) {}
    return start;
}

fn dropPrefix(list: *std.ArrayList(u8), count: usize) void {
    if (count == 0) return;
    const remaining = list.items[count..];
    std.mem.copyForwards(u8, list.items[0..remaining.len], remaining);
    list.shrinkRetainingCapacity(remaining.len);
}

fn removeEscapeBytes(
    allocator: std.mem.Allocator,
    chunk: []const u8,
    output: *std.ArrayList(u8),
) !void {
    for (chunk) |byte| if (byte != 0x1b) try output.append(allocator, byte);
}

test "truncateHead upstream fixtures" {
    const within = truncateHead("a\nb", .{ .max_lines = 10, .max_bytes = 20 });
    try std.testing.expect(!within.truncated);
    try std.testing.expectEqualStrings("a\nb", within.content);

    const too_wide = truncateHead("abcdef\nnext", .{ .max_lines = 10, .max_bytes = 3 });
    try std.testing.expectEqualStrings("", too_wide.content);
    try std.testing.expectEqual(TruncatedBy.bytes, too_wide.truncated_by.?);
    try std.testing.expect(too_wide.first_line_exceeds_limit);

    const exact = truncateHead("abc\nx", .{ .max_lines = 10, .max_bytes = 3 });
    try std.testing.expectEqualStrings("abc", exact.content);
    try std.testing.expectEqual(@as(usize, 3), exact.output_bytes);

    const lines = truncateHead("l1\nl2\nl3", .{ .max_lines = 2, .max_bytes = 100 });
    try std.testing.expectEqualStrings("l1\nl2", lines.content);
    try std.testing.expectEqual(TruncatedBy.lines, lines.truncated_by.?);

    const bytes = truncateHead("12345\nabc\nz", .{ .max_lines = 10, .max_bytes = 7 });
    try std.testing.expectEqualStrings("12345", bytes.content);
    try std.testing.expectEqual(TruncatedBy.bytes, bytes.truncated_by.?);
}

test "OutputSink overflow is per push and keeps the spill-threshold tail" {
    var artifacts = InMemoryArtifactSink.init(std.testing.allocator);
    defer artifacts.deinit();
    var sink = OutputSink.init(std.testing.allocator, .{
        .spill_threshold = 5,
        .max_columns = 0,
        .artifact_sink = artifacts.sink(),
    });
    defer sink.deinit();

    try sink.push("abc");
    try sink.push("def");
    var summary = try sink.dump(null);
    defer summary.deinit(std.testing.allocator);

    try std.testing.expect(summary.truncated);
    try std.testing.expectEqualStrings("bcdef", summary.output);
    try std.testing.expectEqualStrings("1", summary.artifact_id.?);
    try std.testing.expectEqualStrings("abcdef", artifacts.get("1").?);
}

test "OutputSink accepts split UTF-8 and never returns a partial codepoint" {
    var sink = OutputSink.init(std.testing.allocator, .{
        .spill_threshold = 4,
        .max_columns = 0,
    });
    defer sink.deinit();
    const face = "\u{1f600}";
    try sink.push(face[0..2]);
    try sink.push(face[2..]);
    try sink.push("x");
    var summary = try sink.dump(null);
    defer summary.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("x", summary.output);
    try std.testing.expect(std.unicode.utf8ValidateSlice(summary.output));
}

test "OutputSink applies the column cap without a tail line cap" {
    var column_sink = OutputSink.init(std.testing.allocator, .{
        .spill_threshold = 1000,
        .max_columns = 8,
    });
    defer column_sink.deinit();
    try column_sink.push("short\nxxxxxxxxxxxxxxxx\nfooter");
    var column_summary = try column_sink.dump(null);
    defer column_summary.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("short\nxxxxx\u{2026}\nfooter", column_summary.output);
    try std.testing.expectEqual(@as(?usize, 1), column_summary.column_truncated_lines);
    try std.testing.expectEqual(@as(?usize, 11), column_summary.column_dropped_bytes);
}

test "OutputSink keeps a fifty-kilobyte single-line tail" {
    const input = try std.testing.allocator.alloc(u8, 100 * 1024);
    defer std.testing.allocator.free(input);
    @memset(input, 'x');
    var sink = OutputSink.init(std.testing.allocator, .{
        .spill_threshold = 50 * 1024,
        .max_columns = 0,
    });
    defer sink.deinit();
    try sink.push(input);
    var summary = try sink.dump(null);
    defer summary.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 50 * 1024), summary.output.len);
    try std.testing.expectEqual(@as(usize, 1), summary.output_lines);
}

test "OutputSink does not create an artifact without tail overflow" {
    var artifacts = InMemoryArtifactSink.init(std.testing.allocator);
    defer artifacts.deinit();
    var sink = OutputSink.init(std.testing.allocator, .{
        .spill_threshold = 5,
        .max_columns = 0,
        .artifact_sink = artifacts.sink(),
    });
    defer sink.deinit();
    try sink.push("abc");
    var summary = try sink.dump(null);
    defer summary.deinit(std.testing.allocator);
    try std.testing.expect(summary.artifact_id == null);
    try std.testing.expectEqual(@as(usize, 0), artifacts.artifacts.items.len);
}

test "OutputSink replaces malformed and incomplete UTF-8 and preserves it in artifacts" {
    var artifacts = InMemoryArtifactSink.init(std.testing.allocator);
    defer artifacts.deinit();
    var sink = OutputSink.init(std.testing.allocator, .{
        .spill_threshold = 4,
        .max_columns = 0,
        .artifact_sink = artifacts.sink(),
    });
    defer sink.deinit();
    try sink.push(&.{0xff});
    try sink.push(&.{ 0xe2, 0x82 });
    var summary = try sink.dump(null);
    defer summary.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("\u{fffd}", summary.output);
    try std.testing.expectEqualStrings("\u{fffd}\u{fffd}", artifacts.get(summary.artifact_id.?).?);
}

test "OutputSink dump prepends notices" {
    var sink = OutputSink.init(std.testing.allocator, .{ .max_columns = 0 });
    defer sink.deinit();
    try sink.push("partial output");
    var summary = try sink.dump("Command cancelled");
    defer summary.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("[Command cancelled]\npartial output", summary.output);
}

test "OutputSink sanitizes before counting and artifact capture" {
    var artifacts = InMemoryArtifactSink.init(std.testing.allocator);
    defer artifacts.deinit();
    var sink = OutputSink.init(std.testing.allocator, .{
        .spill_threshold = 3,
        .max_columns = 0,
        .artifact_sink = artifacts.sink(),
        .sanitize_hook = removeEscapeBytes,
    });
    defer sink.deinit();
    try sink.push("a\x1bbc");
    try sink.push("d");
    var summary = try sink.dump(null);
    defer summary.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), summary.total_bytes);
    try std.testing.expectEqualStrings("abcd", artifacts.get(summary.artifact_id.?).?);
}

test "spillLargeResultToArtifact uses separate line-aligned head and tail windows" {
    var artifacts = InMemoryArtifactSink.init(std.testing.allocator);
    defer artifacts.deinit();
    var spilled = try spillLargeResultToArtifact(
        std.testing.allocator,
        "one\ntwo\nthree\nfour\nfive\nsix",
        null,
        .{
            .threshold = 5,
            .head_bytes = 20,
            .tail_bytes = 20,
            .tail_lines = 2,
            .artifact_sink = artifacts.sink(),
        },
    );
    defer spilled.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("one\ntwo\n[\u{2026}2ln elided\u{2026}]\nfive\nsix", spilled.output);
    try std.testing.expectEqual(@as(?usize, 2), spilled.truncation.?.head_range.?.end);
    try std.testing.expectEqualStrings("one\ntwo\nthree\nfour\nfive\nsix", artifacts.get(spilled.artifact_id.?).?);

    var skipped = try spillLargeResultToArtifact(
        std.testing.allocator,
        "already handled",
        "existing",
        .{ .threshold = 1, .artifact_sink = artifacts.sink() },
    );
    defer skipped.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("already handled", skipped.output);
    try std.testing.expectEqual(@as(usize, 1), artifacts.artifacts.items.len);
}

test "notice artifact reference and bash minimizer footer are byte exact" {
    const reference = try formatFullOutputReference(std.testing.allocator, "17");
    defer std.testing.allocator.free(reference);
    try std.testing.expectEqualStrings("Read artifact://17 for full output", reference);

    const footer = try formatBashArtifactFooter(std.testing.allocator, "17");
    defer std.testing.allocator.free(footer);
    try std.testing.expectEqualStrings("[raw output: artifact://17]", footer);
}

test "notice head and tail variants are byte exact" {
    const base: TruncationMeta = .{
        .direction = .head,
        .truncated_by = .lines,
        .total_lines = 100,
        .total_bytes = 100_000,
        .output_lines = 13,
        .output_bytes = 1000,
        .shown_range = .{ .start = 1, .end = 13 },
    };
    const plain = try formatTruncationMetaNotice(std.testing.allocator, base);
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("Showing lines 1-13 of 100", plain);

    const wrapped = try formatOutputNotice(std.testing.allocator, base);
    defer std.testing.allocator.free(wrapped);
    try std.testing.expectEqualStrings("\n\n[Showing lines 1-13 of 100]", wrapped);

    var byte_limited = base;
    byte_limited.direction = .tail;
    byte_limited.truncated_by = .bytes;
    byte_limited.max_bytes = 50 * 1024;
    byte_limited.shown_range = .{ .start = 88, .end = 100 };
    const byte_limited_text = try formatTruncationMetaNotice(std.testing.allocator, byte_limited);
    defer std.testing.allocator.free(byte_limited_text);
    try std.testing.expectEqualStrings("Showing lines 88-100 of 100 (50.0KB limit)", byte_limited_text);

    var paged = base;
    paged.next_offset = 14;
    const paged_text = try formatTruncationMetaNotice(std.testing.allocator, paged);
    defer std.testing.allocator.free(paged_text);
    try std.testing.expectEqualStrings("Showing lines 1-13 of 100. Use :14 to continue", paged_text);

    var artifact = base;
    artifact.artifact_id = "29";
    const artifact_text = try formatTruncationMetaNotice(std.testing.allocator, artifact);
    defer std.testing.allocator.free(artifact_text);
    try std.testing.expectEqualStrings(
        "Showing lines 1-13 of 100. Read artifact://29 for full output",
        artifact_text,
    );

    var all = base;
    all.truncated_by = .bytes;
    all.max_bytes = 50 * 1024;
    all.next_offset = 14;
    all.artifact_id = "29";
    const combined = try formatTruncationMetaNotice(std.testing.allocator, all);
    defer std.testing.allocator.free(combined);
    try std.testing.expectEqualStrings(
        "Showing lines 1-13 of 100 (50.0KB limit). Use :14 to continue. Read artifact://29 for full output",
        combined,
    );

    var fallback = base;
    fallback.shown_range = .{ .start = 9, .end = 8 };
    const fallback_text = try formatTruncationMetaNotice(std.testing.allocator, fallback);
    defer std.testing.allocator.free(fallback_text);
    try std.testing.expectEqualStrings("Showing 13 of 100 lines", fallback_text);
}

test "notice middle elision variants are byte exact" {
    const plural: TruncationMeta = .{
        .direction = .middle,
        .truncated_by = .middle,
        .total_lines = 1000,
        .total_bytes = 100_000,
        .output_lines = 40,
        .output_bytes = 40_000,
        .head_range = .{ .start = 1, .end = 20 },
        .tail_range = .{ .start = 981, .end = 1000 },
        .elided_lines = 12_345,
        .elided_bytes = 46_592,
        .artifact_id = "8",
    };
    const plural_text = try formatTruncationMetaNotice(std.testing.allocator, plural);
    defer std.testing.allocator.free(plural_text);
    try std.testing.expectEqualStrings(
        "Showing lines 1-20 and 981-1000 of 1000; 12,345 middle lines (45.5KB) elided. Read artifact://8 for full output",
        plural_text,
    );

    var singular = plural;
    singular.elided_lines = 1;
    singular.artifact_id = null;
    const singular_text = try formatTruncationMetaNotice(std.testing.allocator, singular);
    defer std.testing.allocator.free(singular_text);
    try std.testing.expectEqualStrings(
        "Showing lines 1-20 and 981-1000 of 1000; 1 middle line (45.5KB) elided",
        singular_text,
    );

    var fallback = plural;
    fallback.head_range = null;
    const fallback_text = try formatTruncationMetaNotice(std.testing.allocator, fallback);
    defer std.testing.allocator.free(fallback_text);
    try std.testing.expectEqualStrings(
        "Showing 40 of 1000 lines; middle elided. Read artifact://8 for full output",
        fallback_text,
    );
}

test "notice byte-size rounding matches upstream formatBytes" {
    const cases = [_]struct { bytes: usize, expected: []const u8 }{
        .{ .bytes = 1023, .expected = "1023B" },
        .{ .bytes = 1024, .expected = "1.0KB" },
        .{ .bytes = 1536, .expected = "1.5KB" },
        .{ .bytes = 50 * 1024, .expected = "50.0KB" },
        .{ .bytes = 1024 * 1024, .expected = "1.0MB" },
    };
    for (cases) |case| {
        const actual = try formatBytes(std.testing.allocator, case.bytes);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}
