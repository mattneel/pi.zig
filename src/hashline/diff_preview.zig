//! Compact, post-edit-numbered preview for numbered unified-diff rows.

const std = @import("std");
const types = @import("types.zig");

pub const Options = struct {
    max_added_run_context: ?usize = null,
    max_unchanged_run: ?usize = null,
};

const default_added_run_context_lines = 2;
const elision = "…";

const ParsedLine = struct {
    kind: u8,
    /// JavaScript's `Number.parseInt` produces an IEEE-754 number. Keeping the
    /// same representation both preserves its rounding/stringification at
    /// large values and makes offset arithmetic non-trapping.
    line_number: f64,
    content: []const u8,
};

pub fn buildCompactDiffPreview(
    allocator: std.mem.Allocator,
    diff: []const u8,
    options: Options,
) !types.CompactDiffPreview {
    const edge_lines = @max(@as(usize, 1), options.max_added_run_context orelse options.max_unchanged_run orelse default_added_run_context_lines);
    var formatted: std.ArrayList([]const u8) = .empty;
    var added_run: std.ArrayList([]const u8) = .empty;
    var added_lines: usize = 0;
    var removed_lines: usize = 0;

    if (diff.len > 0) {
        var iterator = std.mem.splitScalar(u8, diff, '\n');
        while (iterator.next()) |line| {
            const parsed = parseNumberedDiffLine(line) orelse {
                try flushAddedRun(allocator, &formatted, &added_run, edge_lines);
                try appendPreviewLine(allocator, &formatted, line);
                continue;
            };
            switch (parsed.kind) {
                '+' => {
                    added_lines += 1;
                    const line_number = try formatJsNumber(allocator, parsed.line_number);
                    try added_run.append(allocator, try std.fmt.allocPrint(allocator, "{s}:{s}", .{ line_number, parsed.content }));
                },
                '-' => {
                    try flushAddedRun(allocator, &formatted, &added_run, edge_lines);
                    removed_lines += 1;
                },
                ' ' => {
                    try flushAddedRun(allocator, &formatted, &added_run, edge_lines);
                    // This intentionally follows upstream Number arithmetic:
                    // f64 has enough exponent range that even values far past
                    // i64 cannot overflow or trap while being renumbered.
                    const shifted = parsed.line_number + @as(f64, @floatFromInt(added_lines)) - @as(f64, @floatFromInt(removed_lines));
                    const line_number = try formatJsNumber(allocator, shifted);
                    try appendPreviewLine(
                        allocator,
                        &formatted,
                        try std.fmt.allocPrint(allocator, "{s}:{s}", .{ line_number, parsed.content }),
                    );
                },
                else => unreachable,
            }
        }
    }
    try flushAddedRun(allocator, &formatted, &added_run, edge_lines);
    while (formatted.items.len > 0 and isSeparator(formatted.items[formatted.items.len - 1])) {
        _ = formatted.pop();
    }
    return .{
        .preview = try std.mem.join(allocator, "\n", formatted.items),
        .added_lines = added_lines,
        .removed_lines = removed_lines,
    };
}

fn parseNumberedDiffLine(line: []const u8) ?ParsedLine {
    if (line.len < 3) return null;
    const kind = line[0];
    if (kind != '+' and kind != '-' and kind != ' ') return null;
    const separator = std.mem.indexOfScalar(u8, line[1..], '|') orelse return null;
    const number_field = line[1 .. separator + 1];
    const number = parseIntPrefix(number_field) orelse return null;
    return .{
        .kind = kind,
        .line_number = number,
        .content = line[separator + 2 ..],
    };
}

fn parseIntPrefix(raw: []const u8) ?f64 {
    const trimmed = std.mem.trimStart(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    var end: usize = 0;
    if (trimmed[0] == '+' or trimmed[0] == '-') end = 1;
    const digit_start = end;
    while (end < trimmed.len and std.ascii.isDigit(trimmed[end])) end += 1;
    if (end == digit_start) return null;
    const number = std.fmt.parseFloat(f64, trimmed[0..end]) catch return null;
    return if (std.math.isFinite(number)) number else null;
}

/// Render a finite integral f64 with ECMAScript Number-to-string thresholds.
/// Zig and JavaScript both use shortest-round-trip conversion; JavaScript
/// switches to exponent form at 1e21 and includes `+` on positive exponents.
fn formatJsNumber(allocator: std.mem.Allocator, number: f64) ![]const u8 {
    if (number == 0) return allocator.dupe(u8, "0");

    var scientific_buffer: [std.fmt.float.bufferSize(.scientific, f64)]u8 = undefined;
    const scientific = try std.fmt.float.render(&scientific_buffer, number, .{ .mode = .scientific });
    const exponent_separator = std.mem.lastIndexOfScalar(u8, scientific, 'e') orelse unreachable;
    const exponent = try std.fmt.parseInt(i32, scientific[exponent_separator + 1 ..], 10);
    const mantissa = scientific[0..exponent_separator];

    if (exponent < -6 or exponent >= 21) {
        if (exponent >= 0) return std.fmt.allocPrint(allocator, "{s}e+{d}", .{ mantissa, exponent });
        return allocator.dupe(u8, scientific);
    }

    const negative = mantissa[0] == '-';
    const unsigned_mantissa = mantissa[@intFromBool(negative)..];
    var digits_buffer: [std.fmt.float.min_buffer_size]u8 = undefined;
    var digits_len: usize = 0;
    for (unsigned_mantissa) |byte| {
        if (byte == '.') continue;
        digits_buffer[digits_len] = byte;
        digits_len += 1;
    }
    const digits = digits_buffer[0..digits_len];
    const decimal_position = exponent + 1;

    var rendered: std.ArrayList(u8) = .empty;
    if (negative) try rendered.append(allocator, '-');
    if (decimal_position <= 0) {
        try rendered.appendSlice(allocator, "0.");
        try rendered.appendNTimes(allocator, '0', @intCast(-decimal_position));
        try rendered.appendSlice(allocator, digits);
    } else if (decimal_position >= digits.len) {
        try rendered.appendSlice(allocator, digits);
        try rendered.appendNTimes(allocator, '0', @as(usize, @intCast(decimal_position)) - digits.len);
    } else {
        const split: usize = @intCast(decimal_position);
        try rendered.appendSlice(allocator, digits[0..split]);
        try rendered.append(allocator, '.');
        try rendered.appendSlice(allocator, digits[split..]);
    }
    return rendered.toOwnedSlice(allocator);
}

fn flushAddedRun(
    allocator: std.mem.Allocator,
    output: *std.ArrayList([]const u8),
    run: *std.ArrayList([]const u8),
    edge_lines: usize,
) !void {
    if (run.items.len == 0) return;
    const threshold = edge_lines * 2 + 1;
    if (run.items.len <= threshold) {
        for (run.items) |line| try appendPreviewLine(allocator, output, line);
    } else {
        for (run.items[0..edge_lines]) |line| try appendPreviewLine(allocator, output, line);
        try appendPreviewLine(allocator, output, elision);
        for (run.items[run.items.len - edge_lines ..]) |line| try appendPreviewLine(allocator, output, line);
    }
    run.clearRetainingCapacity();
}

fn appendPreviewLine(
    allocator: std.mem.Allocator,
    output: *std.ArrayList([]const u8),
    raw: []const u8,
) !void {
    const normalized = if (std.mem.eql(u8, raw, "...") or std.mem.eql(u8, raw, elision) or std.mem.eql(u8, raw, "+…")) elision else raw;
    if (isSeparator(normalized) and (output.items.len == 0 or isSeparator(output.items[output.items.len - 1]))) return;
    try output.append(allocator, normalized);
}

fn isSeparator(line: []const u8) bool {
    return line.len == 0 or std.mem.eql(u8, line, elision);
}

test "hashline diff-preview: renders current lines and counts removals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const preview = try buildCompactDiffPreview(
        arena.allocator(),
        " 1|alpha\n-2|beta\n+2|DELTA\n+3|EPSILON\n 3|gamma",
        .{},
    );
    try std.testing.expectEqualStrings("1:alpha\n2:DELTA\n3:EPSILON\n4:gamma", preview.preview);
    try std.testing.expectEqual(@as(usize, 2), preview.added_lines);
    try std.testing.expectEqual(@as(usize, 1), preview.removed_lines);
}

test "hashline diff-preview: collapses additions and normalizes separators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const preview = try buildCompactDiffPreview(
        arena.allocator(),
        "+10|line 1\n+11|line 2\n+12|line 3\n+13|line 4\n+14|line 5\n+15|line 6\n+16|line 7",
        .{},
    );
    try std.testing.expectEqualStrings("10:line 1\n11:line 2\n…\n15:line 6\n16:line 7", preview.preview);

    const separators = try buildCompactDiffPreview(arena.allocator(), "\n 1|a\n...\n…\n-4|x\n\n 9|z\n", .{});
    try std.testing.expectEqualStrings("1:a\n…\n8:z", separators.preview);
}

test "hashline diff-preview.test.ts: renders current lines and omits removed content while preserving counts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try buildCompactDiffPreview(arena.allocator(), " 1|alpha\n-2|beta\n+2|DELTA\n+3|EPSILON\n 3|gamma", .{});
    try std.testing.expectEqualStrings("1:alpha\n2:DELTA\n3:EPSILON\n4:gamma", result.preview);
    try std.testing.expectEqual(@as(usize, 2), result.added_lines);
    try std.testing.expectEqual(@as(usize, 1), result.removed_lines);
}

test "hashline diff-preview.test.ts: renumbers context lines after range expansion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try buildCompactDiffPreview(
        arena.allocator(),
        " 1|a1\n 2|a2\n-3|a3\n-4|a4\n+3|X\n+4|Y\n+5|Z\n 5|a5\n 6|a6\n 7|a7",
        .{},
    );
    try std.testing.expectEqualStrings("1:a1\n2:a2\n3:X\n4:Y\n5:Z\n6:a5\n7:a6\n8:a7", result.preview);
}

test "hashline diff-preview.test.ts: collapses long contiguous added runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try buildCompactDiffPreview(
        arena.allocator(),
        "+10|line 1\n+11|line 2\n+12|line 3\n+13|line 4\n+14|line 5\n+15|line 6\n+16|line 7",
        .{},
    );
    try std.testing.expectEqualStrings("10:line 1\n11:line 2\n…\n15:line 6\n16:line 7", result.preview);
    try std.testing.expectEqual(@as(usize, 7), result.added_lines);
    try std.testing.expectEqual(@as(usize, 0), result.removed_lines);
}

test "hashline diff-preview: large JavaScript line numbers renumber without overflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try buildCompactDiffPreview(
        arena.allocator(),
        "+1|added\n 1000000000000000000|within\n 9223372036854775807|max\n 9223372036854775808|beyond\n 999999999999999999999|exp",
        .{},
    );
    try std.testing.expectEqualStrings(
        "1:added\n1000000000000000000:within\n9223372036854776000:max\n9223372036854776000:beyond\n1e+21:exp",
        result.preview,
    );
    try std.testing.expectEqual(@as(usize, 1), result.added_lines);
    try std.testing.expectEqual(@as(usize, 0), result.removed_lines);
}

test "hashline diff-preview.test.ts: normalizes adjacent elision markers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try buildCompactDiffPreview(arena.allocator(), " 1|alpha\n...\n...\n…\n 20|omega", .{});
    try std.testing.expectEqualStrings("1:alpha\n…\n20:omega", result.preview);
}

test "hashline diff-preview.test.ts: dedupes blank gaps and trims edge separators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try buildCompactDiffPreview(arena.allocator(), "\n 1|alpha\n\n-5|beta\n\n 9|gamma\n\n-12|omitted", .{});
    try std.testing.expectEqualStrings("1:alpha\n\n8:gamma", result.preview);
    try std.testing.expectEqual(@as(usize, 2), result.removed_lines);
}
