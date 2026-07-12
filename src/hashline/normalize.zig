//! BOM and line-ending normalization used by the patcher.

const std = @import("std");

pub const LineEnding = enum {
    lf,
    crlf,
};

pub const BomResult = struct {
    bom: []const u8,
    text: []const u8,
};

pub fn detectLineEnding(content: []const u8) LineEnding {
    const lf_index = std.mem.indexOfScalar(u8, content, '\n') orelse return .lf;
    return if (lf_index > 0 and content[lf_index - 1] == '\r') .crlf else .lf;
}

pub fn normalizeToLf(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, text, '\r') == null) return allocator.dupe(u8, text);
    var output: std.ArrayList(u8) = .empty;
    try output.ensureTotalCapacity(allocator, text.len);
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] != '\r') {
            try output.append(allocator, text[index]);
            continue;
        }
        if (index + 1 < text.len and text[index + 1] == '\n') index += 1;
        try output.append(allocator, '\n');
    }
    return output.toOwnedSlice(allocator);
}

pub fn restoreLineEndings(allocator: std.mem.Allocator, text: []const u8, ending: LineEnding) ![]u8 {
    if (ending == .lf) return allocator.dupe(u8, text);
    const newline_count = std.mem.count(u8, text, "\n");
    var output = try allocator.alloc(u8, text.len + newline_count);
    var write_index: usize = 0;
    for (text) |byte| {
        if (byte == '\n') {
            output[write_index] = '\r';
            write_index += 1;
        }
        output[write_index] = byte;
        write_index += 1;
    }
    return output;
}

pub fn stripBom(content: []const u8) BomResult {
    const utf8_bom = "\xEF\xBB\xBF";
    if (std.mem.startsWith(u8, content, utf8_bom)) {
        return .{ .bom = content[0..utf8_bom.len], .text = content[utf8_bom.len..] };
    }
    return .{ .bom = "", .text = content };
}

test "hashline normalize: preserves first newline style" {
    try std.testing.expectEqual(LineEnding.crlf, detectLineEnding("a\r\nb\nc"));
    try std.testing.expectEqual(LineEnding.lf, detectLineEnding("a\nb\r\nc"));
}
