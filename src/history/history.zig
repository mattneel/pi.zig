//! Consecutive-deduplicated prompt history stored as JSONL.

const std = @import("std");
const session_paths = @import("../session/paths.zig");

const Allocator = std.mem.Allocator;

pub fn pathAlloc(allocator: Allocator, options: session_paths.Options) ![]u8 {
    const agent_dir = try session_paths.agentDirAlloc(allocator, options);
    defer allocator.free(agent_dir);
    return std.fs.path.join(allocator, &.{ agent_dir, "history.jsonl" });
}

pub fn append(
    allocator: Allocator,
    io: std.Io,
    prompt: []const u8,
    options: session_paths.Options,
) !bool {
    const history_path = try pathAlloc(allocator, options);
    defer allocator.free(history_path);
    const parent = std.fs.path.dirname(history_path) orelse return error.InvalidHistoryPath;
    try std.Io.Dir.cwd().createDirPath(io, parent);
    var file = try std.Io.Dir.createFileAbsolute(io, history_path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
    });
    defer file.close(io);

    const offset = try file.length(io);
    const existing = try lastLineAlloc(allocator, io, file, offset);
    defer if (existing) |bytes| allocator.free(bytes);
    if (existing) |bytes| if (lastPromptEquals(bytes, prompt)) return false;

    const line = try std.json.Stringify.valueAlloc(allocator, .{ .prompt = prompt }, .{});
    defer allocator.free(line);
    const record = try std.mem.concat(allocator, u8, &.{ line, "\n" });
    defer allocator.free(record);
    try file.writePositionalAll(io, record, offset);
    try file.sync(io);
    return true;
}

fn lastLineAlloc(
    allocator: Allocator,
    io: std.Io,
    file: std.Io.File,
    file_length: u64,
) !?[]u8 {
    var buffer: [4096]u8 = undefined;
    var end = file_length;

    while (end != 0) {
        const amount_u64 = @min(end, @as(u64, buffer.len));
        const amount: usize = @intCast(amount_u64);
        const start = end - amount_u64;
        const read = try file.readPositionalAll(io, buffer[0..amount], start);
        if (read != amount) return error.UnexpectedEndOfFile;
        var index = read;
        while (index != 0 and (buffer[index - 1] == '\n' or buffer[index - 1] == '\r')) {
            index -= 1;
            end -= 1;
        }
        if (index != 0) break;
    }
    if (end == 0) return null;

    var start: u64 = 0;
    var cursor = end;
    while (cursor != 0) {
        const amount_u64 = @min(cursor, @as(u64, buffer.len));
        const amount: usize = @intCast(amount_u64);
        const chunk_start = cursor - amount_u64;
        const read = try file.readPositionalAll(io, buffer[0..amount], chunk_start);
        if (read != amount) return error.UnexpectedEndOfFile;
        if (std.mem.lastIndexOfScalar(u8, buffer[0..read], '\n')) |newline| {
            start = chunk_start + @as(u64, @intCast(newline)) + 1;
            break;
        }
        cursor = chunk_start;
    }

    const line_length = std.math.cast(usize, end - start) orelse return error.FileTooBig;
    const line = try allocator.alloc(u8, line_length);
    errdefer allocator.free(line);
    const read = try file.readPositionalAll(io, line, start);
    if (read != line.len) return error.UnexpectedEndOfFile;
    return line;
}

fn lastPromptEquals(bytes: []const u8, expected: []const u8) bool {
    var end = bytes.len;
    while (end != 0 and (bytes[end - 1] == '\n' or bytes[end - 1] == '\r')) end -= 1;
    if (end == 0) return false;
    const start = if (std.mem.lastIndexOfScalar(u8, bytes[0..end], '\n')) |newline| newline + 1 else 0;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), bytes[start..end], .{}) catch return false;
    const object = switch (value) {
        .object => |object| object,
        else => return false,
    };
    return switch (object.get("prompt") orelse return false) {
        .string => |prompt| std.mem.eql(u8, prompt, expected),
        else => false,
    };
}

test "prompt history appends JSONL and removes only consecutive duplicates" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const options: session_paths.Options = .{ .agent_dir = root, .home = root, .temp_dir = "/tmp" };
    try std.testing.expect(try append(allocator, io, "first", options));
    try std.testing.expect(!(try append(allocator, io, "first", options)));
    try std.testing.expect(try append(allocator, io, "second\nline", options));
    try std.testing.expect(try append(allocator, io, "first", options));
    const history_path = try pathAlloc(allocator, options);
    defer allocator.free(history_path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, history_path, allocator, .unlimited);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings(
        "{\"prompt\":\"first\"}\n" ++
            "{\"prompt\":\"second\\nline\"}\n" ++
            "{\"prompt\":\"first\"}\n",
        bytes,
    );
}

test "prompt history deduplicates from the tail of a file larger than the former read limit" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const options: session_paths.Options = .{ .agent_dir = root, .home = root, .temp_dir = "/tmp" };
    const history_path = try pathAlloc(allocator, options);
    defer allocator.free(history_path);

    var file = try std.Io.Dir.createFileAbsolute(io, history_path, .{});
    const record_offset = 65 * 1024 * 1024;
    try file.setLength(io, record_offset);
    try file.writePositionalAll(io, "\n{\"prompt\":\"last\"}\n", record_offset - 1);
    file.close(io);

    try std.testing.expect(!(try append(allocator, io, "last", options)));
    try std.testing.expect(try append(allocator, io, "next", options));
}

test "concurrent prompt history appends retain both complete records" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const options: session_paths.Options = .{ .agent_dir = root, .home = root, .temp_dir = "/tmp" };
    var start: std.Io.Event = .unset;
    const Task = struct {
        fn run(task_io: std.Io, gate: *std.Io.Event, task_options: session_paths.Options, prompt: []const u8) !void {
            try gate.wait(task_io);
            _ = try append(std.heap.smp_allocator, task_io, prompt, task_options);
        }
    };
    var first = io.async(Task.run, .{ io, &start, options, "first concurrent prompt" });
    var second = io.async(Task.run, .{ io, &start, options, "second concurrent prompt with more bytes" });
    start.set(io);
    try first.await(io);
    try second.await(io);

    const history_path = try pathAlloc(std.testing.allocator, options);
    defer std.testing.allocator.free(history_path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, history_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, bytes, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "{\"prompt\":\"first concurrent prompt\"}\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "{\"prompt\":\"second concurrent prompt with more bytes\"}\n") != null);
}
