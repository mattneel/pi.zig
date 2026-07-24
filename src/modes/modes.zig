//! Non-interactive frontends over the AgentCommand/AgentEvent mailboxes.

const std = @import("std");
const openai_compatible = @import("openai_compatible");
const agent = @import("../core/agent.zig");
const events = @import("../core/events.zig");
const message = @import("../core/message.zig");
const scheduler = @import("../core/scheduler.zig");
const session_entries = @import("../session/entries.zig");

const Allocator = std.mem.Allocator;

pub const Mode = enum { text, json };

pub const Options = struct {
    mode: Mode = .text,
    prompts: []const []const u8 = &.{},
};

pub fn run(
    allocator: Allocator,
    io: std.Io,
    session: *agent.AgentSession,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    options: Options,
) !u8 {
    if (options.mode == .json) {
        const header = try session_entries.stringifyHeaderAlloc(
            allocator,
            session.sessionManager().getHeader(),
        );
        defer allocator.free(header);
        try stdout.writeAll(header);
        try stdout.writeByte('\n');
    }

    var final_message: FinalMessage = .{};
    defer final_message.deinit(allocator);
    var last_failure: ?[]u8 = null;
    defer if (last_failure) |text| allocator.free(text);
    var last_status: ?events.RunStatus = null;

    // Must be `concurrent`, not `async`: `Io.async` is permitted to run the
    // task inline to completion before returning, and this loop feeds the
    // session only afterwards, so an inline run would wait forever for a
    // prompt that has not been pushed yet.
    var runner = try io.concurrent(agent.AgentSession.run, .{session});
    var joined = false;
    defer if (!joined) {
        session.inbox().push(io, .shutdown) catch {};
        runner.await(io) catch {};
    };

    for (options.prompts) |text| {
        var prompt = try events.OwnedPrompt.init(allocator, text, &.{}, false, .user);
        defer prompt.deinit(allocator);
        try session.inbox().push(io, .{ .prompt = prompt });

        while (try session.outbox().pop(io)) |owned_event| {
            var event = owned_event;
            defer event.deinit(allocator);

            if (options.mode == .json) {
                const encoded = try events.stringifyEventAlloc(allocator, event);
                defer allocator.free(encoded);
                try stdout.writeAll(encoded);
                try stdout.writeByte('\n');
            }

            switch (event) {
                .message_finished => |finished| if (finished.stop_reason != null) {
                    try final_message.replace(allocator, finished);
                },
                .failed => |failure| {
                    if (last_failure) |previous| allocator.free(previous);
                    last_failure = try allocator.dupe(u8, failure.message);
                },
                .run_finished => |result| last_status = result.status,
                else => {},
            }
            if (event == .run_finished) break;
        }
    }

    try session.inbox().push(io, .shutdown);
    runner.await(io) catch |err| {
        joined = true;
        if (last_status != .failed) return err;
    };
    joined = true;

    if (options.mode == .json) {
        try stdout.flush();
        return 0;
    }

    if (final_message.stop_reason == .@"error" or
        final_message.stop_reason == .aborted or
        last_status == .failed)
    {
        try stdout.flush();
        const error_text = final_message.error_message orelse last_failure orelse
            if (final_message.stop_reason == .aborted) "Request was aborted" else "Agent run failed";
        const sanitized = try scheduler.sanitizeText(allocator, error_text);
        defer allocator.free(sanitized);
        try stderr.writeAll(sanitized);
        try stderr.writeByte('\n');
        try stderr.flush();
        return 1;
    }

    for (final_message.text_blocks.items) |block| {
        const sanitized = try scheduler.sanitizeText(allocator, block);
        defer allocator.free(sanitized);
        try stdout.writeAll(sanitized);
        try stdout.writeByte('\n');
    }
    try stdout.flush();
    return 0;
}

const FinalMessage = struct {
    stop_reason: ?message.StopReason = null,
    text_blocks: std.ArrayList([]u8) = .empty,
    error_message: ?[]u8 = null,

    fn replace(self: *FinalMessage, allocator: Allocator, source: events.MessageFinished) !void {
        self.clear(allocator);
        self.stop_reason = source.stop_reason;
        for (source.text_blocks) |block| {
            const copy = try allocator.dupe(u8, block);
            errdefer allocator.free(copy);
            try self.text_blocks.append(allocator, copy);
        }
        if (source.error_message) |text| self.error_message = try allocator.dupe(u8, text);
    }

    fn clear(self: *FinalMessage, allocator: Allocator) void {
        for (self.text_blocks.items) |block| allocator.free(block);
        self.text_blocks.clearRetainingCapacity();
        if (self.error_message) |text| allocator.free(text);
        self.error_message = null;
        self.stop_reason = null;
    }

    fn deinit(self: *FinalMessage, allocator: Allocator) void {
        self.clear(allocator);
        self.text_blocks.deinit(allocator);
        self.* = undefined;
    }
};

const testkit = @import("../testkit/mock_transport.zig");
const tool_api = @import("../core/tool.zig");

const TestSession = struct {
    allocator: Allocator,
    mock: testkit.MockTransport,
    factory: openai_compatible.OpenAiCompatible,
    chat: openai_compatible.ChatLanguageModel,
    tools: tool_api.ToolRegistry,
    persistence: @import("../session/manager.zig").SessionManager,
    session: agent.AgentSession,

    fn create(
        allocator: Allocator,
        io: std.Io,
        cwd: []const u8,
        script: []const testkit.ScriptedResponse,
    ) !*TestSession {
        return createWithSessionDir(allocator, io, cwd, script, null);
    }

    fn createWithSessionDir(
        allocator: Allocator,
        io: std.Io,
        cwd: []const u8,
        script: []const testkit.ScriptedResponse,
        session_dir: ?[]const u8,
    ) !*TestSession {
        const result = try allocator.create(TestSession);
        errdefer allocator.destroy(result);
        result.allocator = allocator;
        result.mock = testkit.MockTransport.init(script);
        result.factory = openai_compatible.createOpenAiCompatible(.{
            .provider_name = "phase-2b-test",
            .base_url = "https://example.test/v1",
            .api_key = "dummy-key",
            .transport = result.mock.transport(),
        });
        result.chat = try result.factory.chatModel("smoke-model", null);
        result.tools = tool_api.ToolRegistry.init(allocator);
        errdefer result.tools.deinit();
        result.persistence = if (session_dir) |directory|
            try @import("../session/manager.zig").SessionManager.create(allocator, io, cwd, .{
                .session_dir = directory,
                .path_options = .{ .agent_dir = cwd, .home = cwd, .temp_dir = "/tmp" },
            })
        else
            try @import("../session/manager.zig").SessionManager.inMemory(allocator, io, cwd);
        errdefer result.persistence.deinit();
        result.session = try agent.AgentSession.init(allocator, io, .{
            .model = .{
                .language_model = .{ .model = result.chat.languageModel() },
                .provider_name = "phase-2b-test",
                .model_id = "smoke-model",
                .api = "openai-compatible",
            },
            .tools = &result.tools,
            .session_manager = &result.persistence,
            .retry = .{ .max_retries = 0 },
        });
        return result;
    }

    fn deinit(self: *TestSession) void {
        const allocator = self.allocator;
        self.session.deinit();
        self.persistence.deinit();
        self.tools.deinit();
        self.* = undefined;
        allocator.destroy(self);
    }
};

test "print mode emits only the final assistant text after a multi-step run" {
    const tool_sse =
        "data: {\"id\":\"chatcmpl-tool\",\"created\":1711115037,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-1\",\"type\":\"function\",\"function\":{\"name\":\"missing\",\"arguments\":\"{}\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const final_sse =
        "data: {\"id\":\"chatcmpl-final\",\"created\":1711115038,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{\"content\":\"\\u001b[31mfinal\\u001b[0m\\u0000 answer\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const script = [_]testkit.ScriptedResponse{ .{ .sse = tool_sse }, .{ .sse = final_sse } };
    const fixture = try TestSession.create(std.testing.allocator, std.testing.io, ".", &script);
    defer fixture.deinit();
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const exit_code = try run(
        std.testing.allocator,
        std.testing.io,
        &fixture.session,
        &stdout.writer,
        &stderr.writer,
        .{ .prompts = &.{"use the tool"} },
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("final answer\n", stdout.written());
    try std.testing.expectEqualStrings("", stderr.written());
    try std.testing.expectEqual(@as(usize, 2), fixture.mock.request_count);
}

test "print mode writes a final assistant error to stderr and exits one" {
    const script = [_]testkit.ScriptedResponse{.{ .http_error = .{
        .status = 400,
        .status_text = "Bad Request",
        .body = "{\"error\":{\"message\":\"bad provider request\"}}",
    } }};
    const fixture = try TestSession.create(std.testing.allocator, std.testing.io, ".", &script);
    defer fixture.deinit();
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const exit_code = try run(
        std.testing.allocator,
        std.testing.io,
        &fixture.session,
        &stdout.writer,
        &stderr.writer,
        .{ .prompts = &.{"fail"} },
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expectEqualStrings("bad provider request\n", stderr.written());
}

test "json mode writes a header then one object for every event" {
    const fixture = try TestSession.create(std.testing.allocator, std.testing.io, ".", &.{});
    defer fixture.deinit();
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();
    const header = try session_entries.stringifyHeaderAlloc(
        std.testing.allocator,
        fixture.persistence.getHeader(),
    );
    defer std.testing.allocator.free(header);

    const exit_code = try run(
        std.testing.allocator,
        std.testing.io,
        &fixture.session,
        &stdout.writer,
        &stderr.writer,
        .{ .mode = .json, .prompts = &.{"hello"} },
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("", stderr.written());
    var lines = std.mem.splitScalar(u8, stdout.written(), '\n');
    try std.testing.expectEqualStrings(header, lines.next().?);
    const events_start = std.mem.indexOfScalar(u8, stdout.written(), '\n').? + 1;
    const events_text = stdout.written()[events_start..];
    const id_prefix = "\"id\":\"user-";
    const id_start = std.mem.indexOf(u8, events_text, id_prefix).? + "\"id\":\"".len;
    const id_tail = events_text[id_start..];
    const id_end = std.mem.indexOfScalar(u8, id_tail, '"').?;
    const user_id = id_tail[0..id_end];
    const normalized = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        events_text,
        user_id,
        "<user-id>",
    );
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings(
        "{\"type\":\"run_started\"}\n" ++
            "{\"type\":\"turn_started\"}\n" ++
            "{\"type\":\"message_started\",\"id\":\"<user-id>\",\"role\":\"user\"}\n" ++
            "{\"type\":\"message_finished\",\"id\":\"<user-id>\"}\n" ++
            "{\"type\":\"message_started\",\"id\":\"assistant-1-1\",\"role\":\"assistant\"}\n" ++
            "{\"type\":\"text_delta\",\"message_id\":\"assistant-1-1\",\"text\":\"Hel\"}\n" ++
            "{\"type\":\"text_delta\",\"message_id\":\"assistant-1-1\",\"text\":\"lo\"}\n" ++
            "{\"type\":\"message_finished\",\"id\":\"assistant-1-1\",\"stop_reason\":\"stop\",\"text_blocks\":[\"Hello\"]}\n" ++
            "{\"type\":\"usage_updated\",\"usage\":{\"input\":0,\"output\":0,\"cache_read\":0,\"cache_write\":0,\"cost\":{\"input\":0,\"output\":0,\"cache_read\":0,\"cache_write\":0,\"total\":0}}}\n" ++
            "{\"type\":\"turn_finished\",\"stop_reason\":\"stop\",\"tool_calls\":0,\"tool_results\":0}\n" ++
            "{\"type\":\"run_finished\",\"status\":\"completed\",\"turns\":1}\n",
        normalized,
    );
}

test "print mode completes two sequential prompts and prints the second result" {
    const first_sse =
        "data: {\"id\":\"chatcmpl-first\",\"created\":1711115037,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{\"content\":\"first result\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const second_sse =
        "data: {\"id\":\"chatcmpl-second\",\"created\":1711115038,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{\"content\":\"second result\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const script = [_]testkit.ScriptedResponse{ .{ .sse = first_sse }, .{ .sse = second_sse } };
    const fixture = try TestSession.create(std.testing.allocator, std.testing.io, ".", &script);
    defer fixture.deinit();
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const exit_code = try run(
        std.testing.allocator,
        std.testing.io,
        &fixture.session,
        &stdout.writer,
        &stderr.writer,
        .{ .prompts = &.{ "first prompt", "second prompt" } },
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("second result\n", stdout.written());
    try std.testing.expectEqualStrings("", stderr.written());
    try std.testing.expectEqual(@as(usize, 2), fixture.mock.request_count);
}

test "json mode completes two sequential prompts with two run boundaries" {
    const first_sse =
        "data: {\"id\":\"chatcmpl-first\",\"created\":1711115037,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{\"content\":\"first result\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const second_sse =
        "data: {\"id\":\"chatcmpl-second\",\"created\":1711115038,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{\"content\":\"second result\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const script = [_]testkit.ScriptedResponse{ .{ .sse = first_sse }, .{ .sse = second_sse } };
    const fixture = try TestSession.create(std.testing.allocator, std.testing.io, ".", &script);
    defer fixture.deinit();
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const exit_code = try run(
        std.testing.allocator,
        std.testing.io,
        &fixture.session,
        &stdout.writer,
        &stderr.writer,
        .{ .mode = .json, .prompts = &.{ "first prompt", "second prompt" } },
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("", stderr.written());
    try std.testing.expectEqual(@as(usize, 2), fixture.mock.request_count);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, stdout.written(), "{\"type\":\"run_started\"}"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, stdout.written(), "\"type\":\"run_finished\""));
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "\"text_blocks\":[\"first result\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "\"text_blocks\":[\"second result\"]") != null);
}

test "print mode reports a failed run without a model-finished event" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "not-a-directory", .data = "file" });
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const invalid_session_dir = try std.fs.path.join(allocator, &.{ root, "not-a-directory" });
    defer allocator.free(invalid_session_dir);
    const fixture = try TestSession.createWithSessionDir(allocator, io, root, &.{}, invalid_session_dir);
    defer fixture.deinit();
    var stdout: std.Io.Writer.Allocating = .init(allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();

    const exit_code = try run(
        allocator,
        io,
        &fixture.session,
        &stdout.writer,
        &stderr.writer,
        .{ .prompts = &.{"persist this prompt"} },
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expectEqualStrings("NotDir\n", stderr.written());
    try std.testing.expectEqual(@as(usize, 1), fixture.mock.request_count);
}

test {
    std.testing.refAllDecls(@This());
}
