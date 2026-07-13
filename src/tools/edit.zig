//! Hashline-mode edit tool wiring around the Phase 0b patcher.

const std = @import("std");
const approval = @import("../core/approval.zig");
const tool_api = @import("../core/tool.zig");
const hashline = @import("../hashline/hashline.zig");
const session_state = @import("session_state.zig");
const fs_real = @import("fs_real.zig");

const Allocator = std.mem.Allocator;
const SessionState = session_state.SessionState;

pub const description = @embedFile("../prompts/hashline.md");
pub const input_schema =
    \\{"type":"object","properties":{"input":{"type":"string"}},"required":["input"],"additionalProperties":false}
;

pub const tool: tool_api.Tool = .{
    .name = "edit",
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

const Rendered = struct {
    text: []const u8,
    details: std.json.Value,
    per_file: std.json.Value,
};

fn execute(
    raw_context: ?*anyopaque,
    _: std.Io,
    arena: Allocator,
    input: std.json.Value,
    _: ?tool_api.OnUpdate,
    cancel: *const tool_api.CancelToken,
) anyerror!tool_api.ToolOutcome {
    const state: *SessionState = @ptrCast(@alignCast(raw_context.?));
    const object = if (input == .object) input.object else return errorText(arena, "edit input must be an object");
    const input_value = object.get("input") orelse return errorText(arena, "edit requires a string input");
    if (input_value != .string) return errorText(arena, "edit requires a string input");
    try cancel.check();

    const parsed = try hashline.Patch.parse(arena, input_value.string, .{ .cwd = state.cwd });
    const patch = switch (parsed) {
        .failure => |failure| return errorText(arena, failure.message),
        .success => |value| value,
    };
    if (patch.sections.len == 0) return errorText(arena, "No hashline sections found in input.");

    var patcher = hashline.Patcher.init(.{
        .fs = state.real_fs.fs(),
        .snapshot_store = &state.snapshots,
        .cwd = state.cwd,
    });
    if (patch.sections.len == 1) {
        const prepared_outcome = try patcher.prepare(arena, patch.sections[0]);
        const prepared = switch (prepared_outcome) {
            .failure => |failure| return errorText(arena, failure.message),
            .success => |value| value,
        };
        try cancel.check();
        const committed_outcome = try patcher.commit(arena, prepared);
        const committed = switch (committed_outcome) {
            .failure => |failure| return errorText(arena, failure.message),
            .success => |value| value,
        };
        if (committed.op == .noop) return noOpOutcome(state, arena, committed, input_value.string);
        state.resetNoop(committed.canonical_path);
        const rendered = try renderSection(arena, committed);
        return outcome(arena, rendered.text, rendered.details, false);
    }

    var prepared: std.ArrayList(hashline.PreparedSection) = .empty;
    for (patch.sections) |section| {
        try cancel.check();
        const prepared_outcome = try patcher.prepare(arena, section);
        switch (prepared_outcome) {
            .failure => |failure| return errorText(arena, failure.message),
            .success => |value| try prepared.append(arena, value),
        }
    }
    if (try duplicateCanonicalFailure(arena, prepared.items)) |message| return errorText(arena, message);
    for (prepared.items) |entry| if (entry.isNoop()) {
        const record = try state.recordNoop(entry.canonical_path, input_value.string);
        const message = if (record.escalate)
            try noChangeLoopDiagnostic(arena, entry.section.path, record.count)
        else
            try hashline.messages.noChangeDiagnosticMessage(arena, entry.section.path);
        return errorText(arena, message);
    };

    var rendered: std.ArrayList(Rendered) = .empty;
    for (prepared.items, 0..) |entry, index| {
        try cancel.check();
        const committed_outcome = try patcher.commit(arena, entry);
        const committed = switch (committed_outcome) {
            .failure => |failure| {
                const aggregate = try aggregateCommitFailure(arena, prepared.items, index, failure.message);
                return errorText(arena, aggregate);
            },
            .success => |value| value,
        };
        if (committed.op == .noop) {
            const record = try state.recordNoop(committed.canonical_path, input_value.string);
            const message = if (record.escalate)
                try noChangeLoopDiagnostic(arena, committed.path, record.count)
            else
                try hashline.messages.noChangeDiagnosticMessage(arena, committed.path);
            const aggregate = try aggregateCommitFailure(arena, prepared.items, index, message);
            return errorText(arena, aggregate);
        }
        state.resetNoop(committed.canonical_path);
        try rendered.append(arena, try renderSection(arena, committed));
    }

    var text_parts: std.ArrayList([]const u8) = .empty;
    var per_file: std.json.Array = .init(arena);
    var combined_diff: std.ArrayList(u8) = .empty;
    for (rendered.items) |entry| {
        try text_parts.append(arena, entry.text);
        try per_file.append(entry.per_file);
        if (entry.details.object.get("diff")) |diff| if (diff == .string and diff.string.len != 0) {
            if (combined_diff.items.len != 0) try combined_diff.append(arena, '\n');
            try combined_diff.appendSlice(arena, diff.string);
        };
    }
    var details: std.json.ObjectMap = .empty;
    try details.put(arena, "diff", .{ .string = try combined_diff.toOwnedSlice(arena) });
    try details.put(arena, "perFileResults", .{ .array = per_file });
    return outcome(arena, try std.mem.join(arena, "\n\n", text_parts.items), .{ .object = details }, false);
}

fn renderSection(arena: Allocator, section: hashline.PatchSectionResult) !Rendered {
    const text = try section.render(arena);
    const numbered = try hashline.buildNumberedDiff(arena, section.before, section.after, 2);
    const op = switch (section.op) {
        .create => "create",
        .update, .noop => "update",
        .delete => "delete",
    };
    var details: std.json.ObjectMap = .empty;
    try details.put(arena, "diff", .{ .string = numbered.diff });
    try details.put(arena, "op", .{ .string = op });
    try details.put(arena, "path", .{ .string = section.path });
    if (section.first_changed_line) |line| try details.put(arena, "firstChangedLine", .{ .integer = @intCast(line) });
    if (section.move_dest) |destination| try details.put(arena, "move", .{ .string = destination });
    return .{
        .text = text,
        .details = .{ .object = details },
        .per_file = .{ .object = details },
    };
}

fn noOpOutcome(
    state: *SessionState,
    arena: Allocator,
    section: hashline.PatchSectionResult,
    payload: []const u8,
) !tool_api.ToolOutcome {
    const record = try state.recordNoop(section.canonical_path, payload);
    const message = if (record.escalate)
        try noChangeLoopDiagnostic(arena, section.path, record.count)
    else
        try hashline.messages.noChangeDiagnosticMessage(arena, section.path);
    var details: std.json.ObjectMap = .empty;
    try details.put(arena, "diff", .{ .string = "" });
    try details.put(arena, "op", .{ .string = "update" });
    return outcome(arena, message, .{ .object = details }, record.escalate);
}

fn noChangeLoopDiagnostic(arena: Allocator, path: []const u8, count: usize) ![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "STOP. Edits to {s} have been a byte-identical no-op {d} times in a row — " ++
            "the patch body matches the file at the targeted lines and the soft hint did not break the cycle. " ++
            "Cease re-issuing this payload. Either the intended change is already on disk (move on), " ++
            "or your anchor is wrong (re-read the file with `read` to observe the current line numbers and " ++
            "tag, then author a different edit). This exact payload will keep being rejected until it changes.",
        .{ path, count },
    );
}

fn duplicateCanonicalFailure(arena: Allocator, prepared: []const hashline.PreparedSection) !?[]const u8 {
    for (prepared, 0..) |entry, index| {
        for (prepared[0..index]) |previous| {
            if (!std.mem.eql(u8, previous.canonical_path, entry.canonical_path)) continue;
            return try hashline.messages.duplicateCanonicalPathMessage(
                arena,
                previous.section.path,
                entry.section.path,
            );
        }
    }
    return null;
}

fn aggregateCommitFailure(
    arena: Allocator,
    prepared: []const hashline.PreparedSection,
    failed_index: usize,
    cause: []const u8,
) ![]const u8 {
    var already: std.ArrayList([]const u8) = .empty;
    for (prepared[0..failed_index]) |entry| try already.append(arena, entry.section.path);
    var pending: std.ArrayList([]const u8) = .empty;
    if (failed_index + 1 < prepared.len) for (prepared[failed_index + 1 ..]) |entry| try pending.append(arena, entry.section.path);
    return hashline.messages.aggregateCommitFailureMessage(
        arena,
        prepared[failed_index].section.path,
        cause,
        already.items,
        pending.items,
    );
}

fn formatApprovalDetails(_: ?*anyopaque, arena: Allocator, input: std.json.Value) anyerror!?[]const u8 {
    const path = extractApprovalPath(input);
    const truncated = try approval.truncateForPrompt(arena, path, approval.default_prompt_truncate_chars);
    return try std.fmt.allocPrint(arena, "File: {s}", .{truncated});
}

fn extractApprovalPath(input: std.json.Value) []const u8 {
    if (input != .object) return "(unknown)";
    if (input.object.get("input")) |patch_value| if (patch_value == .string) {
        var lines = std.mem.splitScalar(u8, patch_value.string, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            if (line.len < 3 or line[0] != '[') continue;
            const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            const inside = line[1..close];
            if (inside.len == 0) continue;
            const hash = std.mem.indexOfScalar(u8, inside, '#');
            if (hash) |hash_index| {
                const tag = inside[hash_index + 1 ..];
                if (hash_index == 0 or tag.len != 4) continue;
                var valid_tag = true;
                for (tag) |byte| if (!std.ascii.isHex(byte)) {
                    valid_tag = false;
                    break;
                };
                if (!valid_tag) continue;
                return inside[0..hash_index];
            } else {
                return inside;
            }
        }
    };
    if (input.object.get("path")) |path_value| {
        if (path_value == .string and path_value.string.len > 0) return path_value.string;
    }
    return "(unknown)";
}

fn errorText(arena: Allocator, text: []const u8) !tool_api.ToolOutcome {
    return outcome(arena, text, null, true);
}

fn outcome(arena: Allocator, text: []const u8, details: ?std.json.Value, is_error: bool) !tool_api.ToolOutcome {
    const content = try arena.alloc(tool_api.ResultBlock, 1);
    content[0] = .{ .text = text };
    return .{ .content = content, .details = details, .is_error = is_error };
}

test "edit no-op loop diagnostic is byte exact" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings(
        "STOP. Edits to a.txt have been a byte-identical no-op 3 times in a row — the patch body matches the file at the targeted lines and the soft hint did not break the cycle. Cease re-issuing this payload. Either the intended change is already on disk (move on), or your anchor is wrong (re-read the file with `read` to observe the current line numbers and tag, then author a different edit). This exact payload will keep being rejected until it changes.",
        try noChangeLoopDiagnostic(arena_state.allocator(), "a.txt", 3),
    );
}

test "edit approval detail accepts an anchored tagless header and truncates the path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tagless = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"input\":\"prefix [wrong#ABCD]\\n[path]\\nSWAP 1.=1:\"}",
        .{},
    );
    try std.testing.expectEqualStrings("File: path", (try formatApprovalDetails(null, arena, tagless)).?);

    const long_path = try arena.alloc(u8, approval.default_prompt_truncate_chars + 1);
    @memset(long_path, 'a');
    const patch_input = try std.fmt.allocPrint(arena, "[{s}]", .{long_path});
    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "input", .{ .string = patch_input });
    const detail = (try formatApprovalDetails(null, arena, .{ .object = object })).?;
    try std.testing.expect(std.mem.startsWith(u8, detail, "File: aaaa"));
    try std.testing.expect(std.mem.endsWith(u8, detail, "[…1ch elided…]"));
}

test "edit multi-file aggregate text is byte exact" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings(
        "Error editing b.ts: disk full\n" ++
            "Files already applied: a.ts.\n" ++
            "Files NOT applied: c.ts; re-read the affected files and re-issue only the failed and unapplied files.",
        try hashline.messages.aggregateCommitFailureMessage(
            arena_state.allocator(),
            "b.ts",
            "disk full",
            &.{"a.ts"},
            &.{"c.ts"},
        ),
    );
}

test "edit read round trip applies fresh tags guards no-ops and supports multiple files" {
    const read_tool = @import("read.zig");
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "alpha\nbeta\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "one\ntwo\n" });
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

    const read_input = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\"a.txt\"}", .{});
    var read_declaration = read_tool.tool;
    read_declaration.ctx = &state;
    const read_result = try read_declaration.execute(io, arena, read_input, null, &cancel);
    _ = read_result;
    const old_a = hashline.computeFileHash("alpha\nbeta\n");
    const edit_json = try std.fmt.allocPrint(arena, "{{\"input\":\"[a.txt#{s}]\\nSWAP 2.=2:\\n+BETA\"}}", .{&old_a});
    const edit_input = try std.json.parseFromSliceLeaky(std.json.Value, arena, edit_json, .{});
    const edited = try execute(&state, io, arena, edit_input, null, &cancel);
    try std.testing.expect(!edited.is_error);
    const new_a = hashline.computeFileHash("alpha\nBETA\n");
    const expected_header = try std.fmt.allocPrint(arena, "[a.txt#{s}]", .{&new_a});
    try std.testing.expect(std.mem.startsWith(u8, edited.content[0].text, expected_header));
    const disk_a = try tmp.dir.readFileAlloc(io, "a.txt", arena, .unlimited);
    try std.testing.expectEqualStrings("alpha\nBETA\n", disk_a);

    const noop_json = try std.fmt.allocPrint(arena, "{{\"input\":\"[a.txt#{s}]\\nSWAP 2.=2:\\n+BETA\"}}", .{&new_a});
    const noop_input = try std.json.parseFromSliceLeaky(std.json.Value, arena, noop_json, .{});
    const noop_one = try execute(&state, io, arena, noop_input, null, &cancel);
    const noop_two = try execute(&state, io, arena, noop_input, null, &cancel);
    const noop_three = try execute(&state, io, arena, noop_input, null, &cancel);
    try std.testing.expect(!noop_one.is_error);
    try std.testing.expect(!noop_two.is_error);
    try std.testing.expect(noop_three.is_error);
    try std.testing.expect(std.mem.startsWith(u8, noop_three.content[0].text, "STOP. Edits to a.txt have been a byte-identical no-op 3 times"));

    const old_b = hashline.computeFileHash("one\ntwo\n");
    const absolute_b = try state.real_fs.resolve(arena, "b.txt");
    _ = try state.snapshots.record(absolute_b, "one\ntwo\n", &.{ 1, 2 });
    const multi_json = try std.fmt.allocPrint(arena, "{{\"input\":\"[a.txt#{s}]\\nSWAP 1.=1:\\n+ALPHA\\n[b.txt#{s}]\\nSWAP 1.=1:\\n+ONE\"}}", .{ &new_a, &old_b });
    const multi_input = try std.json.parseFromSliceLeaky(std.json.Value, arena, multi_json, .{});
    const multi = try execute(&state, io, arena, multi_input, null, &cancel);
    try std.testing.expect(!multi.is_error);
    try std.testing.expectEqual(@as(usize, 2), multi.details.?.object.get("perFileResults").?.array.items.len);
    try std.testing.expectEqualStrings("ALPHA\nBETA\n", try tmp.dir.readFileAlloc(io, "a.txt", arena, .unlimited));
    try std.testing.expectEqualStrings("ONE\ntwo\n", try tmp.dir.readFileAlloc(io, "b.txt", arena, .unlimited));
}
