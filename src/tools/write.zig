//! Plain-file writer for the essential tool registry.

const std = @import("std");
const approval = @import("../core/approval.zig");
const tool_api = @import("../core/tool.zig");
const hashline = @import("../hashline/hashline.zig");
const session_state = @import("session_state.zig");
const fs_real = @import("fs_real.zig");

const Allocator = std.mem.Allocator;
const SessionState = session_state.SessionState;

const EXECUTABLE_NOTICE = "[Notice: Made executable via chmod +x]";

pub const description = @embedFile("../prompts/tools/write.md");
pub const input_schema =
    \\{"type":"object","properties":{"path":{"type":"string","description":"file path"},"content":{"type":"string","description":"file content"}},"required":["path","content"],"additionalProperties":false}
;

pub const tool: tool_api.Tool = .{
    .name = "write",
    .description = description,
    .input_schema = input_schema,
    .concurrency = .{ .mode = .exclusive },
    .approval = .{ .tier = approval.ToolTier.write },
    .intent = .{ .mode = .require },
    .vtable = &vtable,
};

const vtable: tool_api.VTable = .{
    .execute = execute,
    .format_approval_details = formatApprovalDetails,
};

const StrippedContent = struct {
    text: []const u8,
    stripped: bool,
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
    const object = if (input == .object) input.object else return errorText(arena, "write input must be an object");
    const path_value = object.get("path") orelse return errorText(arena, "write requires a string path");
    const content_value = object.get("content") orelse return errorText(arena, "write requires string content");
    if (path_value != .string or path_value.string.len == 0) return errorText(arena, "write requires a string path");
    if (content_value != .string) return errorText(arena, "write requires string content");
    try cancel.check();

    const path = unwrapPathHeader(path_value.string);
    if (unsupportedSurface(path)) |surface| {
        return textOutcome(arena, try std.fmt.allocPrint(
            arena,
            "Unsupported in this build: write supports plain local files only; {s} is not available.",
            .{surface},
        ));
    }
    const display_mode = state.displayMode(false, false);
    const clean = if (display_mode.hash_lines)
        try stripWriteContent(arena, content_value.string)
    else
        StrippedContent{ .text = content_value.string, .stripped = false };
    const absolute = state.real_fs.resolve(arena, path) catch |err| {
        return errorText(arena, try std.fmt.allocPrint(arena, "Cannot resolve path '{s}': {s}", .{ path, @errorName(err) }));
    };

    const existing = std.Io.Dir.cwd().statFile(io, absolute, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => null,
        else => return errorText(arena, try std.fmt.allocPrint(arena, "Cannot inspect '{s}': {s}", .{ path, @errorName(err) })),
    };
    if (existing) |stat| {
        if (stat.kind == .directory) return errorText(arena, try std.fmt.allocPrint(arena, "Cannot write file: {s} is a directory", .{path}));
        if (state.settings.block_auto_generated) {
            const marker = try generatedMarker(io, arena, absolute, path);
            if (marker) |detected| return errorText(arena, try generatedFileMessage(arena, path, detected));
        }
    }

    const display_path = try state.real_fs.displayPath(arena, absolute);
    if (on_update) |update| {
        const partial_text = try std.fmt.allocPrint(arena, "Writing {d} bytes to {s}...", .{ utf16CodeUnits(clean.text), display_path });
        update(try textOutcome(arena, partial_text));
    }
    try state.real_fs.makeParent(absolute);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = absolute, .data = clean.text });
    try cancel.check();

    const made_executable = if (std.mem.startsWith(u8, clean.text, "#!"))
        tryMarkExecutable(io, absolute)
    else
        false;
    const normalized = try hashline.normalizeToLf(arena, clean.text);
    const hash = try state.snapshots.record(absolute, normalized, null);
    var result: std.ArrayList(u8) = .empty;
    if (display_mode.hash_lines) {
        const header = try hashline.formatHashlineHeader(arena, display_path, &hash);
        try result.print(arena, "{s}\n", .{header});
    }
    try result.print(arena, "Successfully wrote {d} bytes to {s}", .{ utf16CodeUnits(clean.text), display_path });
    if (clean.stripped) try result.appendSlice(arena, "\nNote: auto-stripped hashline display prefixes from content before writing.");
    if (made_executable) try result.print(arena, "\n{s}", .{EXECUTABLE_NOTICE});

    var details: std.json.ObjectMap = .empty;
    try details.put(arena, "resolvedPath", .{ .string = absolute });
    if (made_executable) try details.put(arena, "madeExecutable", .{ .bool = true });
    return outcome(arena, try result.toOwnedSlice(arena), .{ .object = details }, false);
}

fn stripWriteContent(arena: Allocator, content: []const u8) !StrippedContent {
    const lines = try splitLines(arena, content);
    const stripped = try hashline.stripHashlinePrefixes(arena, lines);
    if (!sameLines(stripped, lines)) {
        return .{ .text = try std.mem.join(arena, "\n", stripped), .stripped = true };
    }

    var header_index: ?usize = null;
    for (lines, 0..) |line, index| {
        if (std.mem.trim(u8, line, " \t\r\n").len == 0) continue;
        if (isLooseHashlineHeader(line)) header_index = index;
        break;
    }
    const remove = header_index orelse return .{ .text = content, .stripped = false };
    var without_header: std.ArrayList([]const u8) = .empty;
    try without_header.appendSlice(arena, lines[0..remove]);
    try without_header.appendSlice(arena, lines[remove + 1 ..]);
    const cleaned = try hashline.stripHashlinePrefixes(arena, without_header.items);
    if (sameLines(cleaned, without_header.items)) return .{ .text = content, .stripped = false };
    return .{ .text = try std.mem.join(arena, "\n", cleaned), .stripped = true };
}

fn sameLines(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |after, before| {
        if (after.ptr != before.ptr or after.len != before.len) return false;
    }
    return true;
}

fn isLooseHashlineHeader(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len < 4 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') return false;
    const body = trimmed[1 .. trimmed.len - 1];
    const hash = std.mem.indexOfScalar(u8, body, '#') orelse return false;
    if (hash == 0) return false;
    for (body[hash + 1 ..]) |byte| {
        if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n') return false;
    }
    return true;
}

fn splitLines(arena: Allocator, content: []const u8) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var iterator = std.mem.splitScalar(u8, content, '\n');
    while (iterator.next()) |line| try lines.append(arena, line);
    return lines.toOwnedSlice(arena);
}

fn generatedMarker(io: std.Io, arena: Allocator, absolute: []const u8, display_path: []const u8) !?[]const u8 {
    const basename = std.fs.path.basename(display_path);
    if (generatedFilename(basename)) return basename;
    const content = std.Io.Dir.cwd().readFileAlloc(io, absolute, arena, .limited(1024)) catch |err| switch (err) {
        error.StreamTooLong => blk: {
            var file = try std.Io.Dir.openFileAbsolute(io, absolute, .{ .allow_directory = false });
            defer file.close(io);
            var reader = file.reader(io, &.{});
            break :blk try reader.interface.readAlloc(arena, 1024);
        },
        else => return err,
    };
    const header = try leadingHeaderComments(arena, content, display_path);
    return findGeneratedMarker(header);
}

fn generatedFilename(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "zz_generated.")) return true;
    const suffixes = [_][]const u8{
        ".pb.go",        ".pb.cc",        ".pb.h",    ".pb.c",    ".pb.js",   ".pb.ts",
        "_pb2.py",       "_pb2_grpc.py",  ".gen.go",  ".gen.ts",  ".gen.js",  ".gen.py",
        ".swagger.json", ".openapi.json", ".mock.go", ".mock.ts", ".mock.js", ".mocks.go",
        ".mocks.ts",     ".mocks.js",
    };
    for (suffixes) |suffix| if (std.mem.endsWith(u8, name, suffix)) return true;
    return std.mem.eql(u8, name, "generated.go") or std.mem.eql(u8, name, "generated.ts") or
        std.mem.eql(u8, name, "generated.js") or std.mem.eql(u8, name, "generated.py");
}

const CommentStyle = enum { slash, hash, sql, html };

fn commentStyles(path: []const u8) []const CommentStyle {
    const basename = std.fs.path.basename(path);
    const hash_basenames = [_][]const u8{ "dockerfile", "makefile", "justfile" };
    for (hash_basenames) |name| if (std.ascii.eqlIgnoreCase(basename, name)) return &.{.hash};
    const slash_extensions = [_][]const u8{
        ".c",     ".cc",  ".cpp", ".cs",  ".dart", ".go",  ".h",   ".hpp", ".java",
        ".js",    ".jsx", ".kt",  ".kts", ".mjs",  ".cjs", ".php", ".rs",  ".scala",
        ".swift", ".ts",  ".tsx",
    };
    for (slash_extensions) |extension| if (endsWithIgnoreCase(basename, extension)) return &.{.slash};
    const hash_extensions = [_][]const u8{
        ".py", ".rb", ".sh", ".bash", ".zsh", ".yml", ".yaml", ".toml", ".ini", ".cfg", ".conf", ".env", ".pl", ".r",
    };
    for (hash_extensions) |extension| if (endsWithIgnoreCase(basename, extension)) return &.{.hash};
    if (endsWithIgnoreCase(basename, ".sql")) return &.{.sql};
    const html_extensions = [_][]const u8{ ".html", ".htm", ".xml", ".svg", ".xhtml" };
    for (html_extensions) |extension| if (endsWithIgnoreCase(basename, extension)) return &.{.html};
    return &.{};
}

fn leadingHeaderComments(arena: Allocator, content: []const u8, path: []const u8) ![]const u8 {
    const styles = commentStyles(path);
    if (styles.len == 0) return "";
    const source = if (std.mem.startsWith(u8, content, "\xef\xbb\xbf")) content[3..] else content;
    const include_slash = std.mem.indexOfScalar(CommentStyle, styles, .slash) != null;
    const include_hash = std.mem.indexOfScalar(CommentStyle, styles, .hash) != null;
    const include_sql = std.mem.indexOfScalar(CommentStyle, styles, .sql) != null;
    const include_html = std.mem.indexOfScalar(CommentStyle, styles, .html) != null;
    var header: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_index: usize = 0;
    var started = false;
    var in_slash_block = false;
    var in_html_block = false;
    while (line_index < 40) : (line_index += 1) {
        const line = lines.next() orelse break;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (line_index == 0 and std.mem.startsWith(u8, trimmed, "#!")) continue;
        if (in_slash_block) {
            try appendHeaderLine(arena, &header, trimmed);
            if (std.mem.indexOf(u8, trimmed, "*/") != null) in_slash_block = false;
            continue;
        }
        if (in_html_block) {
            try appendHeaderLine(arena, &header, trimmed);
            if (std.mem.indexOf(u8, trimmed, "-->") != null) in_html_block = false;
            continue;
        }
        if (trimmed.len == 0) {
            if (started) try appendHeaderLine(arena, &header, "");
            continue;
        }
        if (include_slash and std.mem.startsWith(u8, trimmed, "//")) {
            started = true;
            try appendHeaderLine(arena, &header, trimmed);
            continue;
        }
        if (include_slash and std.mem.startsWith(u8, trimmed, "/*")) {
            started = true;
            try appendHeaderLine(arena, &header, trimmed);
            in_slash_block = std.mem.indexOf(u8, trimmed, "*/") == null;
            continue;
        }
        if (include_hash and std.mem.startsWith(u8, trimmed, "#")) {
            started = true;
            try appendHeaderLine(arena, &header, trimmed);
            continue;
        }
        if (include_sql and std.mem.startsWith(u8, trimmed, "--")) {
            started = true;
            try appendHeaderLine(arena, &header, trimmed);
            continue;
        }
        if (include_html and std.mem.startsWith(u8, trimmed, "<!--")) {
            started = true;
            try appendHeaderLine(arena, &header, trimmed);
            in_html_block = std.mem.indexOf(u8, trimmed, "-->") == null;
            continue;
        }
        break;
    }
    return header.toOwnedSlice(arena);
}

fn appendHeaderLine(arena: Allocator, header: *std.ArrayList(u8), line: []const u8) !void {
    if (header.items.len != 0) try header.append(arena, '\n');
    try header.appendSlice(arena, line);
}

fn findGeneratedMarker(content: []const u8) ?[]const u8 {
    if (findWordIgnoreCase(content, "@generated")) |index| return content[index .. index + "@generated".len];
    if (findIgnoreCase(content, "this file was automatically generated")) |index| {
        return content[index .. index + "this file was automatically generated".len];
    }
    if (findIgnoreCase(content, "code generated by ")) |index| {
        var end = index + "code generated by ".len;
        while (end < content.len and (std.ascii.isAlphanumeric(content[end]) or content[end] == '_' or content[end] == '.' or content[end] == '-')) end += 1;
        if (end > index + "code generated by ".len and wordBoundary(content, end)) return content[index..end];
    }
    const generators = [_][]const u8{
        "protoc",         "sqlc",     "buf",          "swagger",       "swagger-codegen", "openapi-generator", "grpc-gateway", "mockery",
        "stringer",       "easyjson", "deepcopy-gen", "defaulter-gen", "conversion-gen",  "client-gen",        "lister-gen",   "informer-gen",
        "kysely-codegen", "napi-rs",
    };
    if (findIgnoreCase(content, "generated by ")) |index| {
        const start = index + "generated by ".len;
        for (generators) |generator| if (start + generator.len <= content.len and std.ascii.eqlIgnoreCase(content[start .. start + generator.len], generator) and wordBoundary(content, start + generator.len)) {
            return content[index .. start + generator.len];
        };
    }
    return null;
}

fn findIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    for (0..haystack.len - needle.len + 1) |index| if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return index;
    return null;
}

fn findWordIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle) and wordBoundary(haystack, start + needle.len)) return start;
    }
    return null;
}

fn wordBoundary(text: []const u8, index: usize) bool {
    return index == text.len or (!std.ascii.isAlphanumeric(text[index]) and text[index] != '_');
}

fn endsWithIgnoreCase(text: []const u8, suffix: []const u8) bool {
    if (text.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(text[text.len - suffix.len ..], suffix);
}

fn generatedFileMessage(arena: Allocator, path: []const u8, detected: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "Cannot modify auto-generated file: {s}\n\n" ++
            "This file appears to be automatically generated (detected marker: \"{s}\").\n" ++
            "Auto-generated files should not be edited directly. Instead:\n" ++
            "1. Find the source file or generator configuration\n" ++
            "2. Make changes to the source\n" ++
            "3. Regenerate the file",
        .{ path, detected },
    );
}

fn tryMarkExecutable(io: std.Io, absolute: []const u8) bool {
    if (!std.Io.File.Permissions.has_executable_bit) return false;
    var file = std.Io.Dir.openFileAbsolute(io, absolute, .{ .mode = .read_write }) catch |err| {
        std.log.debug("cannot reopen shebang file for chmod: {s}", .{@errorName(err)});
        return false;
    };
    defer file.close(io);
    const stat = file.stat(io) catch |err| {
        std.log.debug("cannot stat shebang file for chmod: {s}", .{@errorName(err)});
        return false;
    };
    const mode = stat.permissions.toMode();
    const executable = mode | 0o111;
    if (mode == executable) return false;
    file.setPermissions(io, .fromMode(executable)) catch |err| {
        std.log.debug("cannot chmod shebang file: {s}", .{@errorName(err)});
        return false;
    };
    return true;
}

fn utf16CodeUnits(text: []const u8) usize {
    var units: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch {
            index += 1;
            units += 1;
            continue;
        };
        if (index + length > text.len) {
            units += text.len - index;
            break;
        }
        const codepoint = std.unicode.utf8Decode(text[index .. index + length]) catch {
            index += 1;
            units += 1;
            continue;
        };
        units += if (codepoint > 0xffff) 2 else 1;
        index += length;
    }
    return units;
}

fn unwrapPathHeader(path: []const u8) []const u8 {
    if (path.len < 8 or path[0] != '[' or path[path.len - 1] != ']') return path;
    const hash = std.mem.lastIndexOfScalar(u8, path, '#') orelse return path;
    if (path.len - hash - 2 != 4) return path;
    for (path[hash + 1 .. path.len - 1]) |byte| if (!std.ascii.isHex(byte)) return path;
    return path[1..hash];
}

fn unsupportedSurface(path: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, path, "://") != null) return "internal URLs and conflict targets";
    const archive = [_][]const u8{ ".zip:", ".tar:", ".tar.gz:", ".tgz:" };
    for (archive) |marker| if (std.mem.indexOf(u8, path, marker) != null) return "archive entries";
    const sqlite = [_][]const u8{ ".sqlite:", ".sqlite3:", ".db:", ".db3:" };
    for (sqlite) |marker| if (std.mem.indexOf(u8, path, marker) != null) return "SQLite rows";
    return null;
}

fn formatApprovalDetails(_: ?*anyopaque, arena: Allocator, input: std.json.Value) anyerror!?[]const u8 {
    const path = if (input == .object and input.object.get("path") != null and input.object.get("path").? == .string)
        input.object.get("path").?.string
    else
        "(missing)";
    const content = if (input == .object and input.object.get("content") != null and input.object.get("content").? == .string)
        input.object.get("content").?.string
    else
        "";
    const truncated_path = try approval.truncateForPrompt(arena, path, approval.default_prompt_truncate_chars);
    const truncated_content = try approval.truncateForPrompt(arena, content, approval.default_prompt_truncate_chars);
    return try std.fmt.allocPrint(arena, "Path: {s}\nContent:\n{s}", .{ truncated_path, truncated_content });
}

fn textOutcome(arena: Allocator, text: []const u8) !tool_api.ToolOutcome {
    return outcome(arena, text, null, false);
}

fn errorText(arena: Allocator, text: []const u8) !tool_api.ToolOutcome {
    return outcome(arena, text, null, true);
}

fn outcome(arena: Allocator, text: []const u8, details: ?std.json.Value, is_error: bool) !tool_api.ToolOutcome {
    const content = try arena.alloc(tool_api.ResultBlock, 1);
    content[0] = .{ .text = text };
    return .{ .content = content, .details = details, .is_error = is_error };
}

test "write counts JavaScript UTF-16 code units" {
    try std.testing.expectEqual(@as(usize, 3), utf16CodeUnits("a😀"));
    try std.testing.expectEqual(@as(usize, 1), utf16CodeUnits("é"));
}

test "write generated-file message is byte exact" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings(
        "Cannot modify auto-generated file: api.pb.go\n\nThis file appears to be automatically generated (detected marker: \"api.pb.go\").\nAuto-generated files should not be edited directly. Instead:\n1. Find the source file or generator configuration\n2. Make changes to the source\n3. Regenerate the file",
        try generatedFileMessage(arena_state.allocator(), "api.pb.go", "api.pb.go"),
    );
}

test "write rejects a mock JavaScript filename without a generated header" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "service.mock.js", .data = "export const service = {};\n" });
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
    const input = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"path\":\"service.mock.js\",\"content\":\"replacement\\n\"}",
        .{},
    );
    const result = try execute(&state, io, arena, input, null, &cancel);
    try std.testing.expect(result.is_error);
    const first_line_end = std.mem.indexOfScalar(u8, result.content[0].text, '\n') orelse result.content[0].text.len;
    try std.testing.expectEqualStrings(
        "Cannot modify auto-generated file: service.mock.js",
        result.content[0].text[0..first_line_end],
    );
}

test "write strips numbered content after a loose hashline header" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const clean = try stripWriteContent(
        arena_state.allocator(),
        " [legacy.txt#ZZZZ] \n1:one\n2:two",
    );
    try std.testing.expect(clean.stripped);
    try std.testing.expectEqualStrings("one\ntwo", clean.text);
}

test "write approval detail truncates both path and content" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const long_path = try arena.alloc(u8, approval.default_prompt_truncate_chars + 1);
    const long_content = try arena.alloc(u8, approval.default_prompt_truncate_chars + 2);
    @memset(long_path, 'p');
    @memset(long_content, 'c');
    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "path", .{ .string = long_path });
    try object.put(arena, "content", .{ .string = long_content });
    const detail = (try formatApprovalDetails(null, arena, .{ .object = object })).?;
    try std.testing.expect(std.mem.indexOf(u8, detail, "[…1ch elided…]") != null);
    try std.testing.expect(std.mem.endsWith(u8, detail, "[…2ch elided…]"));
}

test "write persists plain content strips hashlines records tags and blocks generated files" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
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

    const input = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\"nested/value.txt\",\"content\":\"[value.txt#ABCD]\\n1:hello 😀\\n2:world\\n\"}", .{});
    const result = try execute(&state, io, arena, input, null, &cancel);
    const clean = "hello 😀\nworld\n";
    const tag = hashline.computeFileHash(clean);
    const expected = try std.fmt.allocPrint(
        arena,
        "[nested/value.txt#{s}]\nSuccessfully wrote 15 bytes to nested/value.txt\nNote: auto-stripped hashline display prefixes from content before writing.",
        .{&tag},
    );
    try std.testing.expectEqualStrings(expected, result.content[0].text);
    const stored = try tmp.dir.readFileAlloc(io, "nested/value.txt", arena, .unlimited);
    try std.testing.expectEqualStrings(clean, stored);
    const absolute = try state.real_fs.resolve(arena, "nested/value.txt");
    try std.testing.expectEqualStrings(clean, state.snapshots.byHash(absolute, &tag).?.text);

    try tmp.dir.writeFile(io, .{ .sub_path = "generated.go", .data = "// Code generated by protoc. DO NOT EDIT.\npackage x\n" });
    const generated_input = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\"generated.go\",\"content\":\"replacement\\n\"}", .{});
    const blocked = try execute(&state, io, arena, generated_input, null, &cancel);
    try std.testing.expect(blocked.is_error);
    try std.testing.expect(std.mem.startsWith(u8, blocked.content[0].text, "Cannot modify auto-generated file: generated.go"));

    try tmp.dir.writeFile(io, .{ .sub_path = "header.go", .data = "// Code generated by protoc. DO NOT EDIT.\npackage x\n" });
    const header_input = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\"header.go\",\"content\":\"replacement\\n\"}", .{});
    const header_blocked = try execute(&state, io, arena, header_input, null, &cancel);
    try std.testing.expect(header_blocked.is_error);
    try std.testing.expect(std.mem.indexOf(u8, header_blocked.content[0].text, "detected marker: \"Code generated by protoc.\"") != null);

    try tmp.dir.writeFile(io, .{ .sub_path = "handwritten.go", .data = "package x\nconst note = \"Code generated by protoc\"\n" });
    const handwritten_input = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\"handwritten.go\",\"content\":\"package x\\nconst changed = true\\n\"}", .{});
    const handwritten = try execute(&state, io, arena, handwritten_input, null, &cancel);
    try std.testing.expect(!handwritten.is_error);
}
