//! Top-level hashline input splitter and parsed patch data model.
//!
//! `Patch.parse` is lexical plus parser validation; it performs no filesystem
//! access. Every returned slice is allocated in, or borrows storage owned by,
//! the caller's parse arena.

const std = @import("std");
const apply = @import("apply.zig");
const block = @import("block.zig");
const format = @import("format.zig");
const messages = @import("messages.zig");
const parser = @import("parser.zig");
const tokenizer_mod = @import("tokenizer.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const InputError = Allocator.Error || error{InvalidPatch};

pub const SplitOptions = struct {
    cwd: ?[]const u8 = null,
    path: ?[]const u8 = null,
};

const RawSection = struct {
    path: []const u8,
    file_hash: ?format.FileHash = null,
    diff: []const u8,
};

pub const PatchSection = struct {
    path: []const u8,
    file_hash: ?format.FileHash = null,
    diff: []const u8,
    edits: []const types.Edit,
    file_op: ?types.FileOp = null,
    warnings: []const []const u8 = &.{},
    anchor_lines: []const usize = &.{},
    anchor_scoped: bool = false,

    pub fn parse(self: PatchSection) parser.ParseResult {
        return .{ .edits = self.edits, .file_op = self.file_op, .warnings = self.warnings };
    }

    pub fn hasAnchorScopedEdit(self: PatchSection) bool {
        return self.anchor_scoped;
    }

    pub fn collectAnchorLines(self: PatchSection) []const usize {
        return self.anchor_lines;
    }

    pub fn withPath(self: PatchSection, allocator: Allocator, path: []const u8) Allocator.Error!PatchSection {
        var rebound = self;
        rebound.path = try allocator.dupe(u8, path);
        return rebound;
    }

    pub fn rebind(self: PatchSection, allocator: Allocator, path: []const u8) Allocator.Error!PatchSection {
        return self.withPath(allocator, path);
    }

    /// Applies the cached, strict parse result. Block edits must resolve.
    pub fn applyTo(
        self: PatchSection,
        allocator: Allocator,
        text: []const u8,
        resolver: ?types.BlockResolver,
    ) !types.Outcome(types.ApplyResult) {
        return applyParsed(self, allocator, text, resolver, self.parse(), .fail);
    }

    /// Streaming preview counterpart. A trailing incomplete op is omitted and
    /// unresolvable block edits are dropped.
    pub fn applyPartialTo(
        self: PatchSection,
        allocator: Allocator,
        text: []const u8,
        resolver: ?types.BlockResolver,
    ) !types.Outcome(types.ApplyResult) {
        const parsed = try parser.parsePatchStreaming(allocator, self.diff);
        return switch (parsed) {
            .failure => |failure| .{ .failure = failure },
            .success => |result| applyParsed(self, allocator, text, resolver, result, .drop),
        };
    }
};

fn applyParsed(
    section: PatchSection,
    allocator: Allocator,
    text: []const u8,
    resolver: ?types.BlockResolver,
    parsed: parser.ParseResult,
    unresolved_mode: block.UnresolvedMode,
) !types.Outcome(types.ApplyResult) {
    const resolved_outcome = try block.resolveBlockEdits(
        allocator,
        parsed.edits,
        text,
        section.path,
        resolver,
        .{ .on_unresolved = unresolved_mode },
    );
    const resolved = switch (resolved_outcome) {
        .failure => |failure| return .{ .failure = failure },
        .success => |result| result,
    };
    const applied_outcome = try apply.applyEdits(allocator, text, resolved.edits);
    var result = switch (applied_outcome) {
        .failure => |failure| return .{ .failure = failure },
        .success => |success| success,
    };
    const warning_count = parsed.warnings.len + resolved.warnings.len + result.warnings.len;
    if (warning_count == 0) return .{ .success = result };

    const warnings = try allocator.alloc([]const u8, warning_count);
    var index: usize = 0;
    for (parsed.warnings) |warning| {
        warnings[index] = warning;
        index += 1;
    }
    for (resolved.warnings) |warning| {
        warnings[index] = warning;
        index += 1;
    }
    for (result.warnings) |warning| {
        warnings[index] = warning;
        index += 1;
    }
    result.warnings = warnings;
    return .{ .success = result };
}

pub const Patch = struct {
    sections: []const PatchSection,

    pub fn parse(
        allocator: Allocator,
        input: []const u8,
        options: SplitOptions,
    ) Allocator.Error!types.Outcome(Patch) {
        var context = Context.init(allocator);
        defer context.deinit();
        const raw = context.splitRawSections(input, options) catch |err| switch (err) {
            error.InvalidPatch => return context.failureOutcome(Patch),
            error.OutOfMemory => return error.OutOfMemory,
        };
        const merged = context.mergeSamePathSections(raw) catch |err| switch (err) {
            error.InvalidPatch => return context.failureOutcome(Patch),
            error.OutOfMemory => return error.OutOfMemory,
        };

        const sections = try allocator.alloc(PatchSection, merged.len);
        for (merged, sections) |raw_section, *section| {
            const parsed = try parser.parsePatch(allocator, raw_section.diff);
            const result = switch (parsed) {
                .failure => |failure| return .{ .failure = failure },
                .success => |success| success,
            };
            var file_op = result.file_op;
            if (file_op) |op| switch (op) {
                .move => |dest| file_op = .{ .move = try context.normalizeHashlinePath(dest, null) },
                .rem => {},
            };
            const anchor_lines = try collectAnchorLines(allocator, result.edits);
            section.* = .{
                .path = raw_section.path,
                .file_hash = raw_section.file_hash,
                .diff = raw_section.diff,
                .edits = result.edits,
                .file_op = file_op,
                .warnings = result.warnings,
                .anchor_lines = anchor_lines,
                .anchor_scoped = hasAnchorScopedEdit(result.edits),
            };
        }
        return .{ .success = .{ .sections = sections } };
    }

    pub fn parseSingle(
        allocator: Allocator,
        input: []const u8,
        options: SplitOptions,
    ) Allocator.Error!types.Outcome(PatchSection) {
        const parsed = try Patch.parse(allocator, input, options);
        return switch (parsed) {
            .failure => |failure| .{ .failure = failure },
            .success => |patch| if (patch.sections.len > 0)
                .{ .success = patch.sections[0] }
            else
                .{ .failure = types.failure(messages.patch_input_no_sections) },
        };
    }
};

fn hasAnchorScopedEdit(edits: []const types.Edit) bool {
    for (edits) |edit| switch (edit) {
        .delete, .block => return true,
        .insert => |insert| if (insert.cursor.anchor() != null) return true,
    };
    return false;
}

fn collectAnchorLines(allocator: Allocator, edits: []const types.Edit) Allocator.Error![]const usize {
    var lines: std.ArrayList(usize) = .empty;
    for (edits) |edit| {
        const anchor = edit.anchor() orelse continue;
        var found = false;
        for (lines.items) |line| {
            if (line == anchor.line) {
                found = true;
                break;
            }
        }
        if (!found) try lines.append(allocator, anchor.line);
    }
    std.mem.sort(usize, lines.items, {}, std.sort.asc(usize));
    return lines.toOwnedSlice(allocator);
}

const Context = struct {
    allocator: Allocator,
    tokenizer: tokenizer_mod.Tokenizer,
    failure_message: ?[]const u8 = null,

    fn init(allocator: Allocator) Context {
        return .{ .allocator = allocator, .tokenizer = tokenizer_mod.Tokenizer.init(allocator) };
    }

    fn deinit(self: *Context) void {
        self.tokenizer.deinit();
    }

    fn failureOutcome(self: *const Context, comptime T: type) types.Outcome(T) {
        return .{ .failure = types.failure(self.failure_message orelse messages.invalid_hashline_input) };
    }

    fn invalid(self: *Context, message: []const u8) InputError {
        self.failure_message = message;
        return error.InvalidPatch;
    }

    fn stripApplyPatchPathNoise(_: *Context, path_text: []const u8) []const u8 {
        var index: usize = 0;
        var stars: usize = 0;
        while (index < path_text.len and stars < 3 and path_text[index] == '*') : (stars += 1) index += 1;
        index = skipJsWhitespace(path_text, index);

        const keyword_end = keyword: {
            const keywords = [_][]const u8{ "update", "add", "delete", "move" };
            for (keywords) |keyword| {
                if (startsWithIgnoreCase(path_text[index..], keyword)) break :keyword index + keyword.len;
            }
            break :keyword null;
        };
        if (keyword_end) |end| {
            // Both `[^A-Za-z0-9]*` groups are greedy and include colons.
            // Select the farthest colon whose preceding segment can be split
            // around the optional `file|to` token, reproducing regex
            // backtracking for shapes such as `Update::foo.ts`.
            var best_colon: ?usize = null;
            for (end..path_text.len) |cursor| {
                if (path_text[cursor] == ':' and isApplyPatchNoiseSegment(path_text[end..cursor])) {
                    best_colon = cursor;
                }
            }
            if (best_colon) |colon| index = colon + 1;
        }

        index = skipJsWhitespace(path_text, index);
        stars = 0;
        while (index < path_text.len and stars < 3 and path_text[index] == '*') : (stars += 1) index += 1;
        index = skipJsWhitespace(path_text, index);
        return path_text[index..];
    }

    fn normalizeHashlinePath(
        self: *Context,
        raw_path: []const u8,
        cwd: ?[]const u8,
    ) Allocator.Error![]const u8 {
        const trimmed = std.mem.trim(u8, raw_path, " \t\n\r\x0b\x0c");
        const unquoted = unquoteHashlinePath(trimmed);
        const clean = self.stripApplyPatchPathNoise(unquoted);
        if (cwd == null or !std.fs.path.isAbsolute(clean)) return self.allocator.dupe(u8, clean);

        const relative = try std.fs.path.relative(self.allocator, cwd.?, null, cwd.?, clean);
        const is_within = relative.len == 0 or
            (!std.fs.path.isAbsolute(relative) and !isParentRelative(relative));
        if (!is_within) return self.allocator.dupe(u8, clean);
        if (relative.len == 0) return self.allocator.dupe(u8, ".");
        const normalized = try self.allocator.dupe(u8, relative);
        for (normalized) |*byte| {
            if (std.fs.path.isSep(byte.*)) byte.* = '/';
        }
        return normalized;
    }

    fn tryParseRecoveryHeader(
        self: *Context,
        line: []const u8,
        cwd: ?[]const u8,
    ) Allocator.Error!?RawSection {
        if (!std.mem.startsWith(u8, line, format.file_prefix) or !std.mem.endsWith(u8, line, format.file_suffix)) return null;
        var body = std.mem.trim(
            u8,
            line[format.file_prefix.len .. line.len - format.file_suffix.len],
            " \t\n\r\x0b\x0c",
        );
        body = self.stripApplyPatchPathNoise(body);
        if (body.len == 0) return null;

        var path_text = std.mem.trimEnd(u8, body, " \t\n\r\x0b\x0c");
        var file_hash: ?format.FileHash = null;
        if (body.len >= format.file_hash_length + 1) {
            const hash_start = body.len - format.file_hash_length - 1;
            if (body[hash_start] == '#') {
                var all_hex = true;
                for (body[hash_start + 1 ..]) |byte| if (!std.ascii.isHex(byte)) {
                    all_hex = false;
                    break;
                };
                if (all_hex) {
                    path_text = body[0..hash_start];
                    var hash: format.FileHash = undefined;
                    for (body[hash_start + 1 ..], 0..) |byte, index| {
                        hash[index] = if (byte >= 'a' and byte <= 'f') byte - ('a' - 'A') else byte;
                    }
                    file_hash = hash;
                }
            }
        }
        if (std.mem.indexOfScalar(u8, path_text, '#') != null) return null;
        const path = try self.normalizeHashlinePath(path_text, cwd);
        if (path.len == 0) return null;
        return .{ .path = path, .file_hash = file_hash, .diff = "" };
    }

    fn parseHeaderLine(self: *Context, line: []const u8, cwd: ?[]const u8) InputError!?RawSection {
        const trimmed = trimJsEnd(line);
        if (!std.mem.startsWith(u8, trimmed, format.file_prefix)) return null;
        const token = try self.tokenizer.tokenize(trimmed, 0);
        switch (token) {
            .header => |header| {
                const path = try self.normalizeHashlinePath(header.path, cwd);
                if (path.len == 0) return self.invalid(messages.input_header_empty);
                return .{ .path = path, .file_hash = header.file_hash, .diff = "" };
            },
            else => {},
        }
        if (try self.tryParseRecoveryHeader(trimmed, cwd)) |recovered| return recovered;
        return self.invalid(try messages.malformedInputHeaderMessage(self.allocator, trimmed));
    }

    fn normalizeFallbackInput(
        self: *Context,
        input: []const u8,
        options: SplitOptions,
    ) InputError![]const u8 {
        const stripped = stripBom(input);
        const lines = try normalizedLines(self.allocator, stripped);
        for (lines) |line| if (try self.parseHeaderLine(line, options.cwd) != null) return input;
        const fallback = options.path orelse return input;
        if (!containsRecognizableHashlineOperations(input)) return input;
        const path = try self.normalizeHashlinePath(fallback, options.cwd);
        if (path.len == 0) return input;
        return std.fmt.allocPrint(self.allocator, "[{s}]\n{s}", .{ path, input });
    }

    fn splitRawSections(
        self: *Context,
        input: []const u8,
        options: SplitOptions,
    ) InputError![]const RawSection {
        const normalized_input = try self.normalizeFallbackInput(input, options);
        const lines_all = try normalizedLines(self.allocator, stripBom(normalized_input));
        var leading: usize = 0;
        while (leading < lines_all.len) : (leading += 1) {
            const line = lines_all[leading];
            if (std.mem.trim(u8, line, " \t\n\r\x0b\x0c").len == 0) continue;
            const token = try self.tokenizer.tokenize(line, 0);
            if (token == .envelope_begin) continue;
            break;
        }
        const lines = lines_all[leading..];
        const first_line = if (lines.len > 0) lines[0] else "";
        if (try self.parseHeaderLine(first_line, options.cwd) == null) {
            const first_trimmed = trimJsEnd(first_line);
            if (parser.isUnifiedDiffHeader(first_trimmed)) {
                return self.invalid(messages.input_unified_diff_header);
            }
            return self.invalid(try messages.missingInputHeaderMessage(self.allocator, first_line));
        }

        var sections: std.ArrayList(RawSection) = .empty;
        var current: ?RawSection = null;
        var current_lines: std.ArrayList([]const u8) = .empty;
        for (lines, 0..) |line, line_index| {
            const token = try self.tokenizer.tokenize(line, line_index + 1);
            if (token == .envelope_end or token == .abort) break;
            if (token == .envelope_begin) continue;

            const trimmed = trimJsEnd(line);
            if (std.mem.startsWith(u8, trimmed, format.file_prefix)) {
                if (try self.parseHeaderLine(line, options.cwd)) |header| {
                    try self.flushSection(&sections, current, current_lines.items);
                    current = header;
                    current_lines.clearRetainingCapacity();
                    continue;
                }
            }
            try current_lines.append(self.allocator, line);
        }
        try self.flushSection(&sections, current, current_lines.items);
        return sections.toOwnedSlice(self.allocator);
    }

    fn flushSection(
        self: *Context,
        sections: *std.ArrayList(RawSection),
        current: ?RawSection,
        lines: []const []const u8,
    ) Allocator.Error!void {
        const section = current orelse return;
        var has_ops = false;
        for (lines) |line| if (std.mem.trim(u8, line, " \t\n\r\x0b\x0c").len > 0) {
            has_ops = true;
            break;
        };
        if (!has_ops) return;
        var result = section;
        result.diff = try joinLines(self.allocator, lines);
        try sections.append(self.allocator, result);
    }

    fn mergeSamePathSections(
        self: *Context,
        sections: []const RawSection,
    ) InputError![]const RawSection {
        const Entry = struct {
            path: []const u8,
            file_hash: ?format.FileHash,
            diffs: std.ArrayList([]const u8) = .empty,
        };
        var entries: std.ArrayList(Entry) = .empty;
        for (sections) |section| {
            var existing: ?*Entry = null;
            for (entries.items) |*entry| if (std.mem.eql(u8, entry.path, section.path)) {
                existing = entry;
                break;
            };
            if (existing) |entry| {
                if (entry.file_hash != null and section.file_hash != null and
                    !std.mem.eql(u8, &entry.file_hash.?, &section.file_hash.?))
                {
                    return self.invalid(try messages.conflictingSnapshotTagsMessage(
                        self.allocator,
                        section.path,
                        &entry.file_hash.?,
                        &section.file_hash.?,
                    ));
                }
                if (entry.file_hash == null and section.file_hash != null) entry.file_hash = section.file_hash;
                try entry.diffs.append(self.allocator, section.diff);
                continue;
            }
            var entry: Entry = .{ .path = section.path, .file_hash = section.file_hash };
            try entry.diffs.append(self.allocator, section.diff);
            try entries.append(self.allocator, entry);
        }
        const merged = try self.allocator.alloc(RawSection, entries.items.len);
        for (entries.items, merged) |entry, *section| {
            section.* = .{
                .path = entry.path,
                .file_hash = entry.file_hash,
                .diff = try joinLines(self.allocator, entry.diffs.items),
            };
        }
        return merged;
    }
};

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    for (text[0..prefix.len], prefix) |actual, expected| {
        if (std.ascii.toLower(actual) != expected) return false;
    }
    return true;
}

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

fn skipJsWhitespace(text: []const u8, initial: usize) usize {
    var index = initial;
    while (true) {
        const length = jsWhitespaceLenAt(text, index);
        if (length == 0) return index;
        index += length;
    }
}

fn trimJsEnd(text: []const u8) []const u8 {
    var index: usize = 0;
    var last_non_whitespace_end: usize = 0;
    while (index < text.len) {
        const whitespace_len = jsWhitespaceLenAt(text, index);
        if (whitespace_len > 0) {
            index += whitespace_len;
            continue;
        }
        const sequence_len = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        index += @min(sequence_len, text.len - index);
        last_non_whitespace_end = index;
    }
    return text[0..last_non_whitespace_end];
}

fn isApplyPatchNoiseSegment(segment: []const u8) bool {
    var first_alphanumeric: ?usize = null;
    for (segment, 0..) |byte, index| {
        if (!std.ascii.isAlphanumeric(byte)) continue;
        first_alphanumeric = index;
        break;
    }
    const token_start = first_alphanumeric orelse return true;
    const token_len: usize = if (startsWithIgnoreCase(segment[token_start..], "file"))
        "file".len
    else if (startsWithIgnoreCase(segment[token_start..], "to"))
        "to".len
    else
        return false;
    for (segment[token_start + token_len ..]) |byte| {
        if (std.ascii.isAlphanumeric(byte)) return false;
    }
    return true;
}

fn unquoteHashlinePath(path: []const u8) []const u8 {
    if (path.len < 2) return path;
    const first = path[0];
    if ((first == '"' or first == '\'') and path[path.len - 1] == first) return path[1 .. path.len - 1];
    return path;
}

fn isParentRelative(path: []const u8) bool {
    if (std.mem.eql(u8, path, "..")) return true;
    return path.len >= 3 and std.mem.eql(u8, path[0..2], "..") and std.fs.path.isSep(path[2]);
}

fn stripBom(input: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, input, "\xef\xbb\xbf")) input[3..] else input;
}

fn normalizedLines(allocator: Allocator, input: []const u8) Allocator.Error![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    for (input, 0..) |byte, index| {
        if (byte != '\n') continue;
        const end = if (index > start and input[index - 1] == '\r') index - 1 else index;
        try lines.append(allocator, input[start..end]);
        start = index + 1;
    }
    if (start <= input.len) {
        const end = if (input.len > start and input[input.len - 1] == '\r') input.len - 1 else input.len;
        try lines.append(allocator, input[start..end]);
    }
    return lines.toOwnedSlice(allocator);
}

fn joinLines(allocator: Allocator, lines: []const []const u8) Allocator.Error![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    for (lines, 0..) |line, index| {
        if (index > 0) try output.append(allocator, '\n');
        try output.appendSlice(allocator, line);
    }
    return output.toOwnedSlice(allocator);
}

pub fn containsRecognizableHashlineOperations(input: []const u8) bool {
    var tokenizer = tokenizer_mod.Tokenizer.init(std.heap.page_allocator);
    defer tokenizer.deinit();
    var iterator = std.mem.splitScalar(u8, input, '\n');
    while (iterator.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (tokenizer.isOp(line)) return true;
    }
    return false;
}

fn expectPatch(outcome: types.Outcome(Patch)) !Patch {
    return switch (outcome) {
        .success => |patch| patch,
        .failure => |failure| {
            std.debug.print("unexpected patch failure: {s}\n", .{failure.message});
            return error.TestUnexpectedResult;
        },
    };
}

fn expectSection(outcome: types.Outcome(PatchSection)) !PatchSection {
    return switch (outcome) {
        .success => |section| section,
        .failure => |failure| {
            std.debug.print("unexpected section failure: {s}\n", .{failure.message});
            return error.TestUnexpectedResult;
        },
    };
}

fn expectPatchFailure(outcome: types.Outcome(Patch)) !types.Failure {
    return switch (outcome) {
        .failure => |failure| failure,
        .success => error.TestUnexpectedResult,
    };
}

fn expectApplyResult(outcome: types.Outcome(types.ApplyResult)) !types.ApplyResult {
    return switch (outcome) {
        .success => |result| result,
        .failure => |failure| {
            std.debug.print("unexpected apply failure: {s}\n", .{failure.message});
            return error.TestUnexpectedResult;
        },
    };
}

fn twoLineBlockResolver(request: types.BlockResolverRequest) ?types.BlockSpan {
    return .{ .start = request.line, .end = request.line + 1 };
}

test "hashline: input accepts spaced paths and contaminated apply_patch headers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const plain = try expectSection(try Patch.parseSingle(
        arena.allocator(),
        "[dir with spaces/file.ts#1a2b]\nSWAP 1.=1:\n+after",
        .{},
    ));
    try std.testing.expectEqualStrings("dir with spaces/file.ts", plain.path);
    try std.testing.expectEqualStrings("1A2B", &plain.file_hash.?);

    const contaminated = try expectSection(try Patch.parseSingle(
        arena.allocator(),
        "[*** Update File: dir with spaces/file.ts#1A2B]\nSWAP 1.=1:\n+after",
        .{},
    ));
    try std.testing.expectEqualStrings("dir with spaces/file.ts", contaminated.path);
}

test "hashline: input rejects malformed tags and missing headers with exact guidance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const malformed = try expectPatchFailure(try Patch.parse(
        arena.allocator(),
        "[src/a.ts#1A2G]\nSWAP 1.=1:\n+after",
        .{},
    ));
    try std.testing.expectEqualStrings(
        try messages.malformedInputHeaderMessage(arena.allocator(), "[src/a.ts#1A2G]"),
        malformed.message,
    );
    const missing = try expectPatchFailure(try Patch.parse(arena.allocator(), "DEL 38.=40", .{}));
    try std.testing.expectEqualStrings(
        try messages.missingInputHeaderMessage(arena.allocator(), "DEL 38.=40"),
        missing.message,
    );
}

test "hashline: input fallback path split abort and repeated-section merge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fallback = try expectPatch(try Patch.parse(arena.allocator(), "INS.HEAD:\n+x", .{ .path = "a.ts" }));
    try std.testing.expectEqual(@as(usize, 1), fallback.sections.len);
    try std.testing.expectEqualStrings("a.ts", fallback.sections[0].path);

    const merged = try expectPatch(try Patch.parse(
        arena.allocator(),
        "[a.ts#1A2B]\nINS.HEAD:\n+a\n[b.ts#2B3C]\nINS.TAIL:\n+b\n[a.ts#1A2B]\nINS.TAIL:\n+c\n*** Abort\n[c.ts#3C4D]\nREM",
        .{},
    ));
    try std.testing.expectEqual(@as(usize, 2), merged.sections.len);
    try std.testing.expectEqualStrings("a.ts", merged.sections[0].path);
    try std.testing.expectEqual(@as(usize, 2), merged.sections[0].edits.len);
    try std.testing.expectEqualStrings("b.ts", merged.sections[1].path);
}

test "hashline: input carries anchor helpers and path rebinding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const section = try expectSection(try Patch.parseSingle(
        arena.allocator(),
        "[a.ts#1A2B]\nINS.HEAD:\n+top\nSWAP 3.=4:\n+body",
        .{},
    ));
    try std.testing.expect(section.hasAnchorScopedEdit());
    try std.testing.expectEqualSlices(usize, &.{ 3, 4 }, section.collectAnchorLines());
    const rebound = try section.withPath(arena.allocator(), "nested/a.ts");
    try std.testing.expectEqualStrings("nested/a.ts", rebound.path);
    try std.testing.expectEqualSlices(usize, section.collectAnchorLines(), rebound.collectAnchorLines());
}

test "hashline: input parses REM and normalized MV destinations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rem = try expectSection(try Patch.parseSingle(arena.allocator(), "[a.ts#1A2B]\nREM", .{}));
    try std.testing.expect(rem.file_op.? == .rem);
    const move = try expectSection(try Patch.parseSingle(
        arena.allocator(),
        "[a.ts#1A2B]\nMV \"dir with spaces/new.ts\"",
        .{},
    ));
    try std.testing.expectEqualStrings("dir with spaces/new.ts", move.file_op.?.move);
}

test "hashline: input rejects all malformed and suffixed snapshot tags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const headers = [_][]const u8{
        "[src/a.ts#1A2]",
        "[src/a.ts#1A2G]",
        "[src/a.ts#1A2B5]",
        "[src/a.ts#1A2B copied from read]",
        "[src/a.ts#1A2B:812]",
        "[Update File: src/a.ts#1A2G]",
        "[Update File: src/a.ts#1A2B copied from read]",
    };
    for (headers) |header| {
        const input = try std.fmt.allocPrint(arena.allocator(), "{s}\nSWAP 1.=1:\n+after", .{header});
        const failure = try expectPatchFailure(try Patch.parse(arena.allocator(), input, .{}));
        try std.testing.expectEqualStrings(try messages.malformedInputHeaderMessage(arena.allocator(), header), failure.message);
    }
}

test "hashline: input recovers observed apply_patch path-noise variants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const noisy_paths = [_][]const u8{
        "Update File:foo.ts",
        "Update:foo.ts",
        "UpdateFile:foo.ts",
        "Update/File:foo.ts",
        "Update-file:foo.ts",
        "Update(File):foo.ts",
        "Update<File:foo.ts",
        "Add File:foo.ts",
        "Delete File:foo.ts",
        "Move to:foo.ts",
        "***foo.ts",
        "***Update File:foo.ts",
    };
    for (noisy_paths) |noisy| {
        const input = try std.fmt.allocPrint(arena.allocator(), "[{s}#1a2b]\nDEL 1", .{noisy});
        const section = try expectSection(try Patch.parseSingle(arena.allocator(), input, .{}));
        try std.testing.expectEqualStrings("foo.ts", section.path);
        try std.testing.expectEqualStrings("1A2B", &section.file_hash.?);
    }
}

test "hashline: input leading BOM envelope cwd and trailing header semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const patch = try expectPatch(try Patch.parse(
        arena.allocator(),
        "\xef\xbb\xbf\n*** Begin Patch\n[/tmp/hashline-root/src/a.ts#1A2B]\nINS.HEAD:\n+x\n[b.ts#2B3C]",
        .{ .cwd = "/tmp/hashline-root" },
    ));
    try std.testing.expectEqual(@as(usize, 1), patch.sections.len);
    try std.testing.expectEqualStrings("src/a.ts", patch.sections[0].path);
    try std.testing.expectEqualStrings("INS.HEAD:\n+x", patch.sections[0].diff);
}

test "hashline: input reports conflicting tags and first-line unified diffs exactly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const conflict = try expectPatchFailure(try Patch.parse(
        arena.allocator(),
        "[a.ts#1A2B]\nINS.HEAD:\n+a\n[a.ts#2B3C]\nINS.TAIL:\n+b",
        .{},
    ));
    try std.testing.expectEqualStrings(
        try messages.conflictingSnapshotTagsMessage(arena.allocator(), "a.ts", "1A2B", "2B3C"),
        conflict.message,
    );
    const unified = try expectPatchFailure(try Patch.parse(
        arena.allocator(),
        "@@ -1,3 +1,3 @@\nINS.HEAD:\n+x",
        .{},
    ));
    try std.testing.expectEqualStrings(
        messages.input_unified_diff_header,
        unified.message,
    );
}

test "hashline regression 8: first-line unified diff detection accepts a trailing function label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const failure = try expectPatchFailure(try Patch.parse(
        arena.allocator(),
        "@@ -1,3 +1,3 @@ function f()\nINS.HEAD:\n+x",
        .{},
    ));
    try std.testing.expectEqualStrings(messages.input_unified_diff_header, failure.message);
}

test "hashline regression 10: apply_patch path noise consumes interior colons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const section = try expectSection(try Patch.parseSingle(
        arena.allocator(),
        "[Update::foo.ts#1a2b]\nDEL 1",
        .{},
    ));
    try std.testing.expectEqualStrings("foo.ts", section.path);
    try std.testing.expectEqualStrings("1A2B", &section.file_hash.?);
}

test "hashline: input fallback requires a recognizable operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const failure = try expectPatchFailure(try Patch.parse(arena.allocator(), "plain text", .{ .path = "a.ts" }));
    try std.testing.expectEqualStrings(try messages.missingInputHeaderMessage(arena.allocator(), "plain text"), failure.message);
}

test "hashline core-contracts.test.ts: parsed sections apply repeatedly to different snapshots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const section = try expectSection(try Patch.parseSingle(
        arena.allocator(),
        "[a.ts]\nINS.POST 2:\n+tail",
        .{},
    ));
    const short = try expectApplyResult(try section.applyTo(arena.allocator(), "aaa\nbbb", null));
    try std.testing.expectEqualStrings("aaa\nbbb\ntail", short.text);
    const long = try expectApplyResult(try section.applyTo(arena.allocator(), "aaa\nbbb\nccc", null));
    try std.testing.expectEqualStrings("aaa\nbbb\ntail\nccc", long.text);
}

test "hashline block.test.ts: PatchSection applyTo resolves and strict failure is semantic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const section = try expectSection(try Patch.parseSingle(
        arena.allocator(),
        "[x.ts#1A2B]\nSWAP.BLK 2:\n+  if (y || z) {\n+  }",
        .{},
    ));
    const text = "function x() {\n  if (y) {\n  }\n}\n";
    const result = try expectApplyResult(try section.applyTo(
        arena.allocator(),
        text,
        types.BlockResolver.fromFunction(twoLineBlockResolver),
    ));
    try std.testing.expectEqualStrings("function x() {\n  if (y || z) {\n  }\n}\n", result.text);

    const unresolved = try section.applyTo(arena.allocator(), text, null);
    switch (unresolved) {
        .success => return error.TestUnexpectedResult,
        .failure => |failure| try std.testing.expect(std.mem.indexOf(u8, failure.message, messages.block_resolver_unavailable) != null),
    }
}

test "hashline block.test.ts: PatchSection applyPartialTo drops unresolved block edits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const section = try expectSection(try Patch.parseSingle(
        arena.allocator(),
        "[x.ts#1A2B]\nSWAP.BLK 2:\n+X",
        .{},
    ));
    const text = "function x() {\n  if (y) {\n  }\n}\n";
    const result = try expectApplyResult(try section.applyPartialTo(arena.allocator(), text, null));
    try std.testing.expectEqualStrings(text, result.text);
    try std.testing.expectEqual(@as(?usize, null), result.first_changed_line);
}

test "hashline: PatchSection warning order is parse then resolve then apply" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const section = try expectSection(try Patch.parseSingle(
        arena.allocator(),
        "[x.ts#1A2B]\nINS.BLK.POST 2:\nref = t;",
        .{},
    ));
    const text = "function f() {\n    const t = mk({\n    });\n}\nx();\n";
    const result = try expectApplyResult(try section.applyTo(arena.allocator(), text, null));
    try std.testing.expectEqual(@as(usize, 3), result.warnings.len);
    try std.testing.expectEqualStrings(messages.bare_body_auto_piped_warning, result.warnings[0]);
    try std.testing.expectEqualStrings(
        try messages.insertAfterBlockUnresolvedLoweredWarning(arena.allocator(), 2),
        result.warnings[1],
    );
    try std.testing.expectEqualStrings(
        try messages.afterInsertLandingShiftWarning(arena.allocator(), 2, 4, 2),
        result.warnings[2],
    );
}
