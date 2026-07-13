//! Builder for the four essential coding tools.

const std = @import("std");
const tool_api = @import("../core/tool.zig");
const session_state = @import("session_state.zig");
const read = @import("read.zig");
const bash = @import("bash.zig");
const edit = @import("edit.zig");
const write = @import("write.zig");

const Allocator = std.mem.Allocator;

/// The returned registry owns its lookup storage and borrows `state` through
/// every declaration context. Deinitialize the registry before `state`.
pub fn buildDefaultRegistry(allocator: Allocator, state: *session_state.SessionState) !tool_api.ToolRegistry {
    var registry = tool_api.ToolRegistry.init(allocator);
    errdefer registry.deinit();
    const declarations = [_]tool_api.Tool{ read.tool, bash.tool, edit.tool, write.tool };
    for (declarations) |source| {
        var declaration = source;
        declaration.ctx = state;
        try registry.add(declaration);
    }
    return registry;
}

test "registry wires the four essential tools to one session state" {
    var state = try session_state.SessionState.init(std.testing.allocator, std.testing.io, .{ .cwd = "." });
    defer state.deinit();
    var registry = try buildDefaultRegistry(std.testing.allocator, &state);
    defer registry.deinit();
    try std.testing.expectEqual(@as(usize, 4), registry.tools.items.len);
    for (&[_][]const u8{ "read", "bash", "edit", "write" }) |name| {
        const declaration = registry.get(name) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(?*anyopaque, &state), declaration.ctx);
    }
    try std.testing.expectEqual(tool_api.Concurrency.shared, registry.get("read").?.resolveConcurrency(.null));
    try std.testing.expectEqual(tool_api.Concurrency.shared, registry.get("bash").?.resolveConcurrency(.null));
    try std.testing.expectEqual(tool_api.Concurrency.exclusive, registry.get("edit").?.resolveConcurrency(.null));
    try std.testing.expectEqual(tool_api.Concurrency.exclusive, registry.get("write").?.resolveConcurrency(.null));
}

fn toolCallSse(
    arena: Allocator,
    response_id: []const u8,
    call_id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
) ![]const u8 {
    const encoded_arguments = try std.json.Stringify.valueAlloc(arena, arguments_json, .{});
    return std.fmt.allocPrint(
        arena,
        "data: {{\"id\":\"{s}\",\"created\":1711115037,\"model\":\"smoke-model\",\"choices\":[{{\"delta\":{{\"tool_calls\":[{{\"index\":0,\"id\":\"{s}\",\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}]}}}}]}}\n\n" ++
            "data: {{\"choices\":[{{\"delta\":{{}},\"finish_reason\":\"stop\"}}],\"usage\":{{\"prompt_tokens\":5,\"completion_tokens\":2,\"total_tokens\":7}}}}\n\n" ++
            "data: [DONE]\n\n",
        .{ response_id, call_id, name, encoded_arguments },
    );
}

const final_sse =
    "data: {\"id\":\"chatcmpl-final\",\"created\":1711115038,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{\"content\":\"done\"}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":8,\"completion_tokens\":1,\"total_tokens\":9}}\n\n" ++
    "data: [DONE]\n\n";

fn latestToolResultText(messages: []const @import("../core/message.zig").AgentMessage) ?[]const u8 {
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        switch (messages[index]) {
            .tool_result => |result| for (result.content) |block| switch (block) {
                .text => |text| return text.text,
                else => {},
            },
            else => {},
        }
    }
    return null;
}

fn extractReadHeaderTag(text: []const u8) ?[]const u8 {
    const line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const header = text[0..line_end];
    if (header.len < 7 or header[0] != '[' or header[header.len - 1] != ']') return null;
    const hash = std.mem.lastIndexOfScalar(u8, header, '#') orelse return null;
    const tag = header[hash + 1 .. header.len - 1];
    if (tag.len != 4) return null;
    for (tag) |byte| if (!std.ascii.isHex(byte)) return null;
    return tag;
}

fn installTag(body: []u8, tag: []const u8) !void {
    const marker = std.mem.indexOf(u8, body, "#0000]") orelse return error.TestUnexpectedResult;
    if (tag.len != 4) return error.TestUnexpectedResult;
    @memcpy(body[marker + 1 .. marker + 5], tag);
}

const AgentToolCapture = struct {
    text: []u8,
    is_error: bool,
};

fn runAgentEdit(
    allocator: Allocator,
    io: std.Io,
    tools: *tool_api.ToolRegistry,
    edit_sse: []const u8,
) !AgentToolCapture {
    const agent = @import("../core/agent.zig");
    const events = @import("../core/events.zig");
    const mock_transport = @import("../testkit/mock_transport.zig");
    const openai_compatible = @import("openai_compatible");
    const script = [_]mock_transport.ScriptedResponse{
        .{ .sse = edit_sse },
        .{ .sse = final_sse },
    };
    var mock = mock_transport.MockTransport.init(&script);
    const factory = openai_compatible.createOpenAiCompatible(.{
        .provider_name = "phase-1c",
        .base_url = "https://example.test/v1",
        .api_key = "dummy-key",
        .transport = mock.transport(),
    });
    var chat = try factory.chatModel("smoke-model", null);
    var session = try agent.AgentSession.init(allocator, io, .{
        .model = .{
            .language_model = .{ .model = chat.languageModel() },
            .provider_name = "phase-1c",
            .model_id = "smoke-model",
            .api = "openai-compatible",
        },
        .system_prompt = "Use the tools.",
        .tools = tools,
    });
    defer session.deinit();
    var runner = io.async(agent.AgentSession.run, .{&session});
    var prompt = try events.OwnedPrompt.init(allocator, "apply the edit", &.{}, false, .user);
    defer prompt.deinit(allocator);
    try session.inbox().push(io, .{ .prompt = prompt });
    while (try session.outbox().pop(io)) |owned_event| {
        var event = owned_event;
        const done = event == .run_finished;
        event.deinit(allocator);
        if (done) break;
    }
    try session.inbox().push(io, .shutdown);
    try runner.await(io);
    try std.testing.expectEqual(@as(usize, 2), mock.request_count);

    var result_text: ?[]const u8 = null;
    var is_error = false;
    for (session.messagesBorrowed()) |entry| switch (entry) {
        .tool_result => |result| {
            is_error = result.is_error;
            for (result.content) |block| switch (block) {
                .text => |text| result_text = text.text,
                else => {},
            };
        },
        else => {},
    };
    return .{
        .text = try allocator.dupe(u8, result_text orelse return error.TestUnexpectedResult),
        .is_error = is_error,
    };
}

test "integration real registry drives read then edit through AgentSession" {
    const agent = @import("../core/agent.zig");
    const events = @import("../core/events.zig");
    const mock_transport = @import("../testkit/mock_transport.zig");
    const openai_compatible = @import("openai_compatible");
    const fs_real = @import("fs_real.zig");

    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "target.txt", .data = "before\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "recovery.txt", .data = "one\ntwo\nthree\n" });
    const cwd = try fs_real.dirRealPathAlloc(allocator, io, tmp.dir);
    defer allocator.free(cwd);
    var state = try session_state.SessionState.init(allocator, io, .{ .cwd = cwd });
    defer state.deinit();
    var tools = try buildDefaultRegistry(allocator, &state);
    defer tools.deinit();

    var script_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer script_arena_state.deinit();
    const script_arena = script_arena_state.allocator();
    const read_arguments = try std.json.Stringify.valueAlloc(script_arena, .{ .path = "target.txt" }, .{});
    const patch_input = "[target.txt#0000]\nSWAP 1.=1:\n+after";
    const edit_arguments = try std.json.Stringify.valueAlloc(script_arena, .{ .input = patch_input }, .{});
    const recovery_read_arguments = try std.json.Stringify.valueAlloc(script_arena, .{ .path = "recovery.txt" }, .{});
    const recovery_patch_input = "[recovery.txt#0000]\nSWAP 2.=2:\n+TWO";
    const recovery_edit_arguments = try std.json.Stringify.valueAlloc(script_arena, .{ .input = recovery_patch_input }, .{});
    const read_sse = try toolCallSse(script_arena, "chatcmpl-read", "call-read", "read", read_arguments);
    const edit_sse = try script_arena.dupe(u8, try toolCallSse(script_arena, "chatcmpl-edit", "call-edit", "edit", edit_arguments));
    const recovery_read_sse = try toolCallSse(script_arena, "chatcmpl-recovery-read", "call-recovery-read", "read", recovery_read_arguments);
    const recovery_edit_sse = try script_arena.dupe(u8, try toolCallSse(script_arena, "chatcmpl-recovery-edit", "call-recovery-edit", "edit", recovery_edit_arguments));
    var direct_edit_entered: std.Io.Event = .unset;
    var direct_edit_release: std.Io.Event = .unset;
    var recovery_edit_entered: std.Io.Event = .unset;
    var recovery_edit_release: std.Io.Event = .unset;
    const script = [_]mock_transport.ScriptedResponse{
        .{ .sse = read_sse },
        .{ .blocked_sse = .{ .gate = &direct_edit_release, .entered = &direct_edit_entered, .body = edit_sse } },
        .{ .sse = recovery_read_sse },
        .{ .blocked_sse = .{ .gate = &recovery_edit_release, .entered = &recovery_edit_entered, .body = recovery_edit_sse } },
        .{ .sse = final_sse },
    };
    var mock = mock_transport.MockTransport.init(&script);
    const factory = openai_compatible.createOpenAiCompatible(.{
        .provider_name = "phase-1c",
        .base_url = "https://example.test/v1",
        .api_key = "dummy-key",
        .transport = mock.transport(),
    });
    var chat = try factory.chatModel("smoke-model", null);
    var session = try agent.AgentSession.init(allocator, io, .{
        .model = .{
            .language_model = .{ .model = chat.languageModel() },
            .provider_name = "phase-1c",
            .model_id = "smoke-model",
            .api = "openai-compatible",
        },
        .system_prompt = "Use the tools.",
        .tools = &tools,
    });
    defer session.deinit();
    var runner = io.async(agent.AgentSession.run, .{&session});

    var prompt = try events.OwnedPrompt.init(allocator, "change the file", &.{}, false, .user);
    defer prompt.deinit(allocator);
    try session.inbox().push(io, .{ .prompt = prompt });
    try direct_edit_entered.wait(io);
    const direct_read_text = latestToolResultText(session.messagesBorrowed()) orelse return error.TestUnexpectedResult;
    const direct_tag = extractReadHeaderTag(direct_read_text) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.startsWith(u8, direct_read_text, "[target.txt#"));
    try installTag(edit_sse, direct_tag);
    direct_edit_release.set(io);

    try recovery_edit_entered.wait(io);
    const recovery_read_text = latestToolResultText(session.messagesBorrowed()) orelse return error.TestUnexpectedResult;
    const recovery_tag = extractReadHeaderTag(recovery_read_text) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.startsWith(u8, recovery_read_text, "[recovery.txt#"));
    try installTag(recovery_edit_sse, recovery_tag);
    try tmp.dir.writeFile(io, .{ .sub_path = "recovery.txt", .data = "inserted\none\ntwo\nthree\n" });
    {
        var control_state = try session_state.SessionState.init(allocator, io, .{ .cwd = cwd });
        defer control_state.deinit();
        var control_tools = try buildDefaultRegistry(allocator, &control_state);
        defer control_tools.deinit();
        const control = try runAgentEdit(allocator, io, &control_tools, recovery_edit_sse);
        defer allocator.free(control.text);
        try std.testing.expect(control.is_error);
        const unchanged = try tmp.dir.readFileAlloc(io, "recovery.txt", allocator, .unlimited);
        defer allocator.free(unchanged);
        try std.testing.expectEqualStrings("inserted\none\ntwo\nthree\n", unchanged);
    }
    recovery_edit_release.set(io);

    var started: usize = 0;
    var finished: usize = 0;
    while (try session.outbox().pop(io)) |owned_event| {
        var event = owned_event;
        const done = event == .run_finished;
        switch (event) {
            .tool_started => started += 1,
            .tool_finished => finished += 1,
            else => {},
        }
        event.deinit(allocator);
        if (done) break;
    }
    try session.inbox().push(io, .shutdown);
    try runner.await(io);

    try std.testing.expectEqual(@as(usize, 5), mock.request_count);
    try std.testing.expectEqual(@as(usize, 4), started);
    try std.testing.expectEqual(@as(usize, 4), finished);
    const changed = try tmp.dir.readFileAlloc(io, "target.txt", allocator, .unlimited);
    defer allocator.free(changed);
    try std.testing.expectEqualStrings("after\n", changed);
    const recovered = try tmp.dir.readFileAlloc(io, "recovery.txt", allocator, .unlimited);
    defer allocator.free(recovered);
    try std.testing.expectEqualStrings("inserted\none\nTWO\nthree\n", recovered);
}
