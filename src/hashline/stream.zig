//! Incremental UTF-8 byte stream to bounded `LINE:TEXT` chunks.

const std = @import("std");
const format = @import("format.zig");

pub const Options = struct {
    start_line: usize = 1,
    max_chunk_lines: usize = 200,
    max_chunk_bytes: usize = 64 * 1024,
};

pub const Streamer = struct {
    options: Options,
    pending: std.ArrayList(u8) = .empty,
    output_lines: std.ArrayList([]const u8) = .empty,
    output_bytes: usize = 0,
    next_line: usize,
    saw_any_line: bool = false,
    closed: bool = false,

    pub fn init(options: Options) Streamer {
        return .{ .options = options, .next_line = options.start_line };
    }

    pub fn deinit(self: *Streamer, allocator: std.mem.Allocator) void {
        self.pending.deinit(allocator);
        self.output_lines.deinit(allocator);
        self.* = undefined;
    }

    pub fn feed(
        self: *Streamer,
        allocator: std.mem.Allocator,
        bytes: []const u8,
        chunks: *std.ArrayList([]const u8),
    ) !void {
        if (self.closed) return error.StreamClosed;
        if (bytes.len == 0) return;
        try self.pending.appendSlice(allocator, bytes);
        var consumed: usize = 0;
        while (std.mem.indexOfScalarPos(u8, self.pending.items, consumed, '\n')) |newline| {
            var line = self.pending.items[consumed..newline];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            self.saw_any_line = true;
            try self.pushLine(allocator, line, chunks);
            consumed = newline + 1;
        }
        if (consumed > 0) {
            const remaining = self.pending.items[consumed..];
            std.mem.copyForwards(u8, self.pending.items[0..remaining.len], remaining);
            self.pending.shrinkRetainingCapacity(remaining.len);
        }
    }

    pub fn finish(
        self: *Streamer,
        allocator: std.mem.Allocator,
        chunks: *std.ArrayList([]const u8),
    ) !void {
        if (self.closed) return;
        self.closed = true;
        if (self.pending.items.len > 0) {
            var tail = self.pending.items;
            if (tail[tail.len - 1] == '\r') tail = tail[0 .. tail.len - 1];
            self.saw_any_line = true;
            try self.pushLine(allocator, tail, chunks);
        }
        if (!self.saw_any_line) try self.pushLine(allocator, "", chunks);
        try self.flush(allocator, chunks);
    }

    fn pushLine(
        self: *Streamer,
        allocator: std.mem.Allocator,
        line: []const u8,
        chunks: *std.ArrayList([]const u8),
    ) !void {
        const decoded = if (std.unicode.utf8ValidateSlice(line))
            line
        else
            try std.fmt.allocPrint(allocator, "{f}", .{std.unicode.fmtUtf8(line)});
        const formatted = try format.formatNumberedLine(allocator, self.next_line, decoded);
        self.next_line += 1;
        const separator_bytes: usize = if (self.output_lines.items.len == 0) 0 else 1;
        const would_overflow = self.output_lines.items.len >= self.options.max_chunk_lines or
            self.output_bytes + separator_bytes + formatted.len > self.options.max_chunk_bytes;
        if (self.output_lines.items.len > 0 and would_overflow) try self.flush(allocator, chunks);
        try self.output_lines.append(allocator, formatted);
        const emitted_separator: usize = if (self.output_lines.items.len == 1) 0 else 1;
        self.output_bytes += emitted_separator + formatted.len;
        if (self.output_lines.items.len >= self.options.max_chunk_lines or self.output_bytes >= self.options.max_chunk_bytes) {
            try self.flush(allocator, chunks);
        }
    }

    fn flush(
        self: *Streamer,
        allocator: std.mem.Allocator,
        chunks: *std.ArrayList([]const u8),
    ) !void {
        if (self.output_lines.items.len == 0) return;
        try chunks.append(allocator, try std.mem.join(allocator, "\n", self.output_lines.items));
        self.output_lines.clearRetainingCapacity();
        self.output_bytes = 0;
    }
};

pub fn streamHashLines(
    allocator: std.mem.Allocator,
    byte_chunks: []const []const u8,
    options: Options,
) ![]const []const u8 {
    var streamer = Streamer.init(options);
    defer streamer.deinit(allocator);
    var output: std.ArrayList([]const u8) = .empty;
    for (byte_chunks) |chunk| try streamer.feed(allocator, chunk, &output);
    try streamer.finish(allocator, &output);
    return output.toOwnedSlice(allocator);
}

test "hashline stream: preserves split UTF-8 codepoints and CRLF" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const euro = "€";
    const chunks = [_][]const u8{ "a\r\n", euro[0..1], euro[1..], "\nlast" };
    const output = try streamHashLines(arena.allocator(), &chunks, .{ .max_chunk_lines = 2 });
    try std.testing.expectEqual(@as(usize, 2), output.len);
    try std.testing.expectEqualStrings("1:a\n2:€", output[0]);
    try std.testing.expectEqualStrings("3:last", output[1]);
}

test "hashline stream: empty source and oversized line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const empty = try streamHashLines(arena.allocator(), &.{}, .{});
    try std.testing.expectEqualStrings("1:", empty[0]);
    const long = try streamHashLines(arena.allocator(), &.{"abcdef"}, .{ .max_chunk_bytes = 3 });
    try std.testing.expectEqualStrings("1:abcdef", long[0]);
}

test "hashline stream: TextDecoder replacement semantics for malformed UTF-8" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const output = try streamHashLines(
        arena.allocator(),
        &.{ "\xE2", "\x28\n", "\xF0\x9F" },
        .{},
    );
    try std.testing.expectEqual(@as(usize, 1), output.len);
    try std.testing.expectEqualStrings("1:�(\n2:�", output[0]);
}
