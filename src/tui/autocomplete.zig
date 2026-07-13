//! Fixed-storage composer completion, modeled on
//! `inspiration/packages/tui/src/autocomplete.ts`.

const std = @import("std");
const slash = @import("slash.zig");

pub const max_items: usize = 20;
pub const max_item_bytes: usize = 512;
const max_directory_entries: usize = 256;

pub const ReplacementSpan = struct {
    start: usize = 0,
    end: usize = 0,
};

pub const ItemKind = enum {
    command,
    model,
    thinking,
    file,
};

pub const Item = struct {
    value_buffer: [max_item_bytes]u8 = undefined,
    value_len: usize = 0,
    label_buffer: [max_item_bytes]u8 = undefined,
    label_len: usize = 0,
    score: i32 = 0,
    kind: ItemKind = .file,
    consumes_args: bool = false,
    is_directory: bool = false,

    pub fn value(self: *const Item) []const u8 {
        return self.value_buffer[0..self.value_len];
    }

    pub fn label(self: *const Item) []const u8 {
        return self.label_buffer[0..self.label_len];
    }
};

pub const Completions = struct {
    items: [max_items]Item = undefined,
    count: usize = 0,
    replacement: ReplacementSpan = .{},

    pub fn slice(self: *const Completions) []const Item {
        return self.items[0..self.count];
    }

    fn add(
        self: *Completions,
        value: []const u8,
        label: []const u8,
        score: i32,
        kind: ItemKind,
        consumes_args: bool,
        is_directory: bool,
    ) void {
        if (value.len > max_item_bytes or label.len > max_item_bytes) return;
        if (self.containsValue(value)) return;

        var item: Item = .{
            .score = score,
            .kind = kind,
            .consumes_args = consumes_args,
            .is_directory = is_directory,
        };
        @memcpy(item.value_buffer[0..value.len], value);
        item.value_len = value.len;
        @memcpy(item.label_buffer[0..label.len], label);
        item.label_len = label.len;

        var insert_at: usize = 0;
        while (insert_at < self.count and !itemBefore(&item, &self.items[insert_at])) : (insert_at += 1) {}
        if (insert_at >= max_items) return;

        const new_count = @min(self.count + 1, max_items);
        var index = new_count;
        while (index > insert_at + 1) {
            index -= 1;
            self.items[index] = self.items[index - 1];
        }
        self.items[insert_at] = item;
        self.count = new_count;
    }

    fn containsValue(self: *const Completions, value: []const u8) bool {
        for (self.slice()) |*item| {
            if (std.mem.eql(u8, item.value(), value)) return true;
        }
        return false;
    }
};

pub const WorkingDirectory = struct {
    io: std.Io,
    dir: std.Io.Dir = .cwd(),
    home: ?[]const u8 = null,
};

pub fn fuzzyMatch(query: []const u8, candidate: []const u8) bool {
    if (query.len == 0) return true;
    if (query.len > candidate.len) return false;

    var query_index: usize = 0;
    for (candidate) |byte| {
        if (lower(byte) == lower(query[query_index])) {
            query_index += 1;
            if (query_index == query.len) return true;
        }
    }
    return false;
}

/// Higher scores are better: exact, prefix, substring, then tight subsequence.
pub fn fuzzyScore(query: []const u8, candidate: []const u8) i32 {
    if (query.len == 0) return 1;
    if (!fuzzyMatch(query, candidate)) return 0;
    if (eqlIgnoreCase(query, candidate)) return 1_000;
    if (startsWithIgnoreCase(candidate, query)) {
        const penalty: i32 = @intCast(@min(candidate.len - query.len, 100));
        return 900 - penalty;
    }
    if (indexOfIgnoreCase(candidate, query)) |index| {
        return 700 - @as(i32, @intCast(@min(index, 100)));
    }

    var query_index: usize = 0;
    var first_match: usize = 0;
    var last_match: usize = 0;
    for (candidate, 0..) |byte, candidate_index| {
        if (lower(byte) != lower(query[query_index])) continue;
        if (query_index == 0) first_match = candidate_index;
        last_match = candidate_index;
        query_index += 1;
        if (query_index == query.len) break;
    }
    const span = last_match - first_match + 1;
    const gap_bytes = span - query.len;
    const penalty = @min(first_match + gap_bytes * 4, 399);
    return 400 - @as(i32, @intCast(penalty));
}

pub fn computeCompletions(
    text_before_cursor: []const u8,
    registry: []const slash.Command,
    model_ids: []const []const u8,
    effort_names: []const []const u8,
    cwd: WorkingDirectory,
) Completions {
    return compute(text_before_cursor, registry, model_ids, effort_names, cwd, false);
}

pub fn computeCompletionsForced(
    text_before_cursor: []const u8,
    registry: []const slash.Command,
    model_ids: []const []const u8,
    effort_names: []const []const u8,
    cwd: WorkingDirectory,
) Completions {
    return compute(text_before_cursor, registry, model_ids, effort_names, cwd, true);
}

fn compute(
    text_before_cursor: []const u8,
    registry: []const slash.Command,
    model_ids: []const []const u8,
    effort_names: []const []const u8,
    cwd: WorkingDirectory,
    force_file: bool,
) Completions {
    if (leadingSlashStart(text_before_cursor)) |slash_start| {
        const command_text = text_before_cursor[slash_start..];
        const name_end = std.mem.indexOfAny(u8, command_text, " \t\r\n");
        if (name_end == null) {
            var result: Completions = .{
                .replacement = .{ .start = slash_start, .end = text_before_cursor.len },
            };
            const query = command_text[1..];
            for (registry) |command| {
                const score = fuzzyScore(query, command.name[1..]);
                if (score == 0) continue;
                var label_buffer: [max_item_bytes]u8 = undefined;
                const label = std.fmt.bufPrint(
                    &label_buffer,
                    "{s}  {s}",
                    .{ command.name, command.summary },
                ) catch command.name;
                result.add(command.name, label, score, .command, command.consumes_args, false);
            }
            return result;
        }

        switch (slash.parse(command_text)) {
            .command => |matched| switch (matched.command.arg_kind) {
                .model => return completeNames(text_before_cursor, model_ids, .model),
                .thinking => return completeNames(text_before_cursor, effort_names, .thinking),
                else => {},
            },
            else => {},
        }
    }

    const token_start = findPathTokenStart(text_before_cursor);
    const token = text_before_cursor[token_start..];
    if (!force_file and !isPathLike(token)) return .{};

    var result: Completions = .{
        .replacement = .{ .start = token_start, .end = text_before_cursor.len },
    };
    completeFiles(&result, token, cwd);
    return result;
}

fn completeNames(text: []const u8, names: []const []const u8, kind: ItemKind) Completions {
    const start = findArgumentStart(text);
    const query = text[start..];
    var result: Completions = .{ .replacement = .{ .start = start, .end = text.len } };
    for (names) |name| {
        const score = fuzzyScore(query, name);
        if (score != 0) result.add(name, name, score, kind, false, false);
    }
    return result;
}

fn completeFiles(result: *Completions, token: []const u8, cwd: WorkingDirectory) void {
    if (std.mem.eql(u8, token, "~")) {
        if (cwd.home != null) result.add("~/", "~/", 1_000, .file, false, true);
        return;
    }

    const slash_index = std.mem.lastIndexOfScalar(u8, token, '/');
    const display_prefix = if (slash_index) |index| token[0 .. index + 1] else "";
    const query = if (slash_index) |index| token[index + 1 ..] else token;
    const directory_token = if (slash_index) |index|
        if (index == 0 and token[0] == '/') "/" else token[0..index]
    else
        ".";

    const directory = openDirectory(cwd, directory_token) orelse return;
    defer directory.close(cwd.io);

    var iterator = directory.iterateAssumeFirstIteration();
    var scanned: usize = 0;
    while (scanned < max_directory_entries) : (scanned += 1) {
        const entry = iterator.next(cwd.io) catch {
            result.count = 0;
            return;
        } orelse break;
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;

        const score = fuzzyScore(query, entry.name);
        if (score == 0) continue;
        const is_directory = entry.kind == .directory;

        var value_buffer: [max_item_bytes]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&value_buffer);
        writer.writeAll(display_prefix) catch continue;
        writer.writeAll(entry.name) catch continue;
        if (is_directory) writer.writeByte('/') catch continue;
        const value = writer.buffered();
        result.add(value, value, score, .file, false, is_directory);
    }
}

fn openDirectory(cwd: WorkingDirectory, directory_token: []const u8) ?std.Io.Dir {
    if (std.mem.eql(u8, directory_token, "~") or std.mem.startsWith(u8, directory_token, "~/")) {
        const home = cwd.home orelse return null;
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&path_buffer);
        writer.writeAll(home) catch return null;
        if (directory_token.len > 1) writer.writeAll(directory_token[1..]) catch return null;
        return std.Io.Dir.openDirAbsolute(cwd.io, writer.buffered(), .{ .iterate = true }) catch null;
    }
    if (std.fs.path.isAbsolute(directory_token)) {
        return std.Io.Dir.openDirAbsolute(cwd.io, directory_token, .{ .iterate = true }) catch null;
    }
    return cwd.dir.openDir(cwd.io, directory_token, .{ .iterate = true }) catch null;
}

fn leadingSlashStart(text: []const u8) ?usize {
    var index: usize = 0;
    while (index < text.len and std.ascii.isWhitespace(text[index])) : (index += 1) {}
    return if (index < text.len and text[index] == '/') index else null;
}

fn findArgumentStart(text: []const u8) usize {
    var index = text.len;
    while (index > 0 and !std.ascii.isWhitespace(text[index - 1])) : (index -= 1) {}
    return index;
}

fn findPathTokenStart(text: []const u8) usize {
    var index = text.len;
    while (index > 0) {
        const byte = text[index - 1];
        if (std.ascii.isWhitespace(byte) or byte == '"' or byte == '\'' or byte == '=') break;
        index -= 1;
    }
    return index;
}

fn isPathLike(token: []const u8) bool {
    return std.mem.indexOfScalar(u8, token, '/') != null or
        std.mem.startsWith(u8, token, "~");
}

fn itemBefore(lhs: *const Item, rhs: *const Item) bool {
    if (lhs.score != rhs.score) return lhs.score > rhs.score;
    return orderIgnoreCase(lhs.value(), rhs.value()) == .lt;
}

fn orderIgnoreCase(lhs: []const u8, rhs: []const u8) std.math.Order {
    const shared = @min(lhs.len, rhs.len);
    var index: usize = 0;
    while (index < shared) : (index += 1) {
        const lhs_byte = lower(lhs[index]);
        const rhs_byte = lower(rhs[index]);
        if (lhs_byte < rhs_byte) return .lt;
        if (lhs_byte > rhs_byte) return .gt;
    }
    return std.math.order(lhs.len, rhs.len);
}

fn eqlIgnoreCase(lhs: []const u8, rhs: []const u8) bool {
    return lhs.len == rhs.len and startsWithIgnoreCase(lhs, rhs);
}

fn startsWithIgnoreCase(candidate: []const u8, prefix: []const u8) bool {
    if (prefix.len > candidate.len) return false;
    for (candidate[0..prefix.len], prefix) |candidate_byte, prefix_byte| {
        if (lower(candidate_byte) != lower(prefix_byte)) return false;
    }
    return true;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (startsWithIgnoreCase(haystack[index..], needle)) return index;
    }
    return null;
}

fn lower(byte: u8) u8 {
    return std.ascii.toLower(byte);
}

fn findValue(result: *const Completions, value: []const u8) ?*const Item {
    for (result.slice()) |*item| {
        if (std.mem.eql(u8, item.value(), value)) return item;
    }
    return null;
}

test "fuzzy matches are case insensitive and score exact prefix substring then tight subsequence" {
    try std.testing.expect(fuzzyMatch("G5", "gpt-5"));
    try std.testing.expect(!fuzzyMatch("5g", "gpt-5"));
    try std.testing.expect(fuzzyScore("abc", "abc") > fuzzyScore("abc", "abcdef"));
    try std.testing.expect(fuzzyScore("abc", "abcdef") > fuzzyScore("abc", "zabc"));
    try std.testing.expect(fuzzyScore("abc", "zabc") > fuzzyScore("abc", "a-b-c"));
    try std.testing.expect(fuzzyScore("abc", "a-b-c") > fuzzyScore("abc", "a---b---c"));
}

test "slash model and thinking completion are score sorted with exact replacement spans" {
    const cwd: WorkingDirectory = .{ .io = std.testing.io };

    const slash_result = computeCompletions("  /mo", &slash.commands, &.{}, &.{}, cwd);
    try std.testing.expectEqual(@as(usize, 1), slash_result.count);
    try std.testing.expectEqualStrings("/model", slash_result.items[0].value());
    try std.testing.expectEqual(@as(usize, 2), slash_result.replacement.start);
    try std.testing.expectEqual(@as(usize, 5), slash_result.replacement.end);

    const models = [_][]const u8{ "a---b---c", "zabc", "abcdef", "abc" };
    const model_result = computeCompletions("/model abc", &slash.commands, &models, &.{}, cwd);
    try std.testing.expectEqual(@as(usize, 4), model_result.count);
    try std.testing.expectEqualStrings("abc", model_result.items[0].value());
    try std.testing.expectEqualStrings("abcdef", model_result.items[1].value());
    try std.testing.expectEqualStrings("zabc", model_result.items[2].value());
    try std.testing.expectEqualStrings("a---b---c", model_result.items[3].value());
    try std.testing.expectEqual(@as(usize, 7), model_result.replacement.start);
    try std.testing.expectEqual(@as(usize, 10), model_result.replacement.end);

    const efforts = [_][]const u8{ "off", "minimal", "low", "medium", "high", "xhigh", "max", "ultra" };
    const thinking_result = computeCompletions("/thinking x", &slash.commands, &.{}, &efforts, cwd);
    try std.testing.expect(thinking_result.count >= 1);
    try std.testing.expectEqualStrings("xhigh", thinking_result.items[0].value());

    const none = computeCompletions("/model impossible", &slash.commands, &models, &efforts, cwd);
    try std.testing.expectEqual(@as(usize, 0), none.count);
}

test "file completion uses a bounded cwd scan and suffixes directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "src", .default_dir);
    var file = try tmp.dir.createFile(std.testing.io, "sample.zig", .{});
    file.close(std.testing.io);

    const cwd: WorkingDirectory = .{ .io = std.testing.io, .dir = tmp.dir };
    const result = computeCompletions("open ./s", &slash.commands, &.{}, &.{}, cwd);
    try std.testing.expect(findValue(&result, "./sample.zig") != null);
    const directory = findValue(&result, "./src/") orelse return error.TestUnexpectedResult;
    try std.testing.expect(directory.is_directory);
    try std.testing.expectEqual(@as(usize, 5), result.replacement.start);
    try std.testing.expectEqual(@as(usize, 8), result.replacement.end);

    const forced = computeCompletionsForced("sam", &slash.commands, &.{}, &.{}, cwd);
    try std.testing.expect(findValue(&forced, "sample.zig") != null);

    const none = computeCompletions("./does-not-exist/z", &slash.commands, &.{}, &.{}, cwd);
    try std.testing.expectEqual(@as(usize, 0), none.count);
}
