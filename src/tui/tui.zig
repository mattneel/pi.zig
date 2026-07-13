//! Interactive terminal frontend over the agent mailbox contract.

const std = @import("std");
const openai_compatible = @import("openai_compatible");
const tuizr = @import("tuizr");
const agent = @import("../core/agent.zig");
const events = @import("../core/events.zig");
const tool_api = @import("../core/tool.zig");
const testkit = @import("../testkit/mock_transport.zig");

const Allocator = std.mem.Allocator;
const double_ctrl_c_ms: i64 = 500;

const Clock = union(enum) {
    io: std.Io,
    fixed_ms: *const i64,

    fn nowMs(self: Clock) i64 {
        return switch (self) {
            .io => |io| std.Io.Clock.awake.now(io).toMilliseconds(),
            .fixed_ms => |milliseconds| milliseconds.*,
        };
    }
};

const State = struct {
    transcript: tuizr.StreamingView = .{},
    composer: tuizr.TextInput,
    is_running: bool = false,
    quit_requested: bool = false,
    last_ctrl_c_ms: ?i64 = null,
    transcript_width: u16,
    transcript_height: u16,
    assistant_id: [128]u8 = undefined,
    assistant_id_len: usize = 0,
    assistant_has_delta: bool = false,
    stream_line: enum { none, assistant, reasoning } = .none,

    fn init(width: u16, height: u16) State {
        return .{
            .composer = tuizr.TextInput.init(),
            .transcript_width = width,
            .transcript_height = height,
        };
    }

    fn setTranscriptViewport(self: *State, width: u16, height: u16) void {
        self.transcript_width = width;
        self.transcript_height = height;
        if (self.transcript.auto_scroll) {
            tuizr.streamingViewScrollToBottom(&self.transcript, width, height);
        }
    }

    fn append(self: *State, text: []const u8) void {
        tuizr.streamingViewAppend(
            &self.transcript,
            text,
            self.transcript_width,
            self.transcript_height,
        );
    }

    fn ensureLineStart(self: *State) void {
        if (self.transcript.len != 0 and self.transcript.buffer[self.transcript.len - 1] != '\n') {
            self.append("\n");
        }
    }

    fn appendLine(self: *State, prefix: []const u8, text: []const u8) void {
        self.ensureLineStart();
        self.append(prefix);
        self.append(text);
        self.append("\n");
        self.stream_line = .none;
    }

    fn appendPrompt(self: *State, text: []const u8) void {
        self.appendLine("user: ", text);
    }

    fn startAssistant(self: *State, id: []const u8) void {
        self.ensureLineStart();
        self.assistant_id_len = @min(id.len, self.assistant_id.len);
        @memcpy(self.assistant_id[0..self.assistant_id_len], id[0..self.assistant_id_len]);
        self.assistant_has_delta = false;
        self.stream_line = .none;
    }

    fn assistantMatches(self: *const State, id: []const u8) bool {
        return self.assistant_id_len == id.len and
            std.mem.eql(u8, self.assistant_id[0..self.assistant_id_len], id);
    }

    fn startAssistantLine(self: *State) void {
        if (self.stream_line == .assistant) return;
        self.ensureLineStart();
        self.append("assistant: ");
        self.stream_line = .assistant;
    }

    fn appendAssistantDelta(self: *State, delta: events.TextDelta) void {
        if (self.assistantMatches(delta.message_id)) {
            self.startAssistantLine();
            self.assistant_has_delta = true;
        }
        self.append(delta.text);
    }

    fn appendReasoningDelta(self: *State, delta: events.ReasoningDelta) void {
        if (self.stream_line != .reasoning) {
            self.ensureLineStart();
            self.append("thinking: ");
            self.stream_line = .reasoning;
        }
        self.append(delta.text);
    }

    fn finishAssistant(self: *State, finished: events.MessageFinished) void {
        if (!self.assistantMatches(finished.id)) return;
        if (!self.assistant_has_delta) {
            self.startAssistantLine();
            for (finished.text_blocks, 0..) |block, index| {
                if (index != 0) self.append("\n");
                self.append(block);
            }
            if (finished.text_blocks.len == 0) {
                if (finished.error_message) |message| self.append(message);
            }
        }
        self.ensureLineStart();
        self.assistant_id_len = 0;
        self.assistant_has_delta = false;
        self.stream_line = .none;
    }
};

pub fn run(
    gpa: Allocator,
    io: std.Io,
    session: *agent.AgentSession,
    initial_prompts: []const []const u8,
    stderr: *std.Io.Writer,
) !u8 {
    var runner = io.async(agent.AgentSession.run, .{session});
    var joined = false;
    defer if (!joined) {
        session.inbox().push(io, .shutdown) catch {};
        runner.await(io) catch {};
    };

    var term = try tuizr.Terminal.init(.{ .allocator = gpa, .io = io });
    var terminal_live = true;
    defer if (terminal_live) term.deinit();

    const grid = term.backBuffer();
    const state = try gpa.create(State);
    defer gpa.destroy(state);
    state.* = State.init(grid.width(), grid.height() -| 2);

    for (initial_prompts) |text| {
        try pushPrompt(gpa, io, session, text);
        state.appendPrompt(text);
    }

    const clock: Clock = .{ .io = io };
    while (!state.quit_requested) {
        state.setTranscriptViewport(term.backBuffer().width(), term.backBuffer().height() -| 2);

        while (session.outbox().tryPop(io)) |owned_event| {
            var event = owned_event;
            defer event.deinit(gpa);
            try bridgeEvent(gpa, io, session, state, event);
        }

        while (term.pollInput()) |key_event| {
            try handleKey(gpa, io, session, state, clock, key_event);
            if (state.quit_requested) break;
        }
        if (state.quit_requested) break;

        draw(state, term.backBuffer());
        try term.render();
        try io.sleep(.fromMilliseconds(16), .awake);
    }

    session.inbox().push(io, .shutdown) catch |err| switch (err) {
        error.Closed => {},
        else => return err,
    };
    const run_result = runner.await(io);
    joined = true;
    try run_result;

    term.deinit();
    terminal_live = false;

    try session.sessionManager().flushSync();
    if (session.sessionManager().path() != null) {
        try stderr.writeAll("Session saved. Resume with: omp --continue\n");
        try stderr.flush();
    }
    return 0;
}

fn bridgeEvent(
    gpa: Allocator,
    io: std.Io,
    session: *agent.AgentSession,
    state: *State,
    event: events.AgentEvent,
) !void {
    if (event == .approval_requested) {
        var decision = try events.ApprovalDecision.init(
            gpa,
            event.approval_requested.request_id,
            true,
            null,
        );
        defer decision.deinit(gpa);
        try session.inbox().push(io, .{ .approve = decision });
    }
    applyEvent(state, event);
}

fn applyEvent(state: *State, event: events.AgentEvent) void {
    switch (event) {
        .run_started => state.is_running = true,
        .run_finished => state.is_running = false,
        .message_started => |started| if (started.role == .assistant) {
            state.startAssistant(started.id);
        },
        .text_delta => |delta| state.appendAssistantDelta(delta),
        .reasoning_delta => |delta| state.appendReasoningDelta(delta),
        .message_finished => |finished| state.finishAssistant(finished),
        .tool_started => |started| state.appendLine("→ ", started.tool_name),
        .tool_finished => |finished| state.appendLine("  ", if (finished.is_error) "error" else "done"),
        .approval_requested => |request| {
            state.ensureLineStart();
            state.append("auto-approved ");
            state.append(request.tool_name);
            state.append(" (approval UI arrives in Phase 5)\n");
            state.stream_line = .none;
        },
        .notice => |notice| state.appendLine("notice: ", notice.message),
        .failed => |failure| state.appendLine("error: ", failure.message),
        else => {},
    }
}

fn handleKey(
    gpa: Allocator,
    io: std.Io,
    session: *agent.AgentSession,
    state: *State,
    clock: Clock,
    key_event: tuizr.KeyEvent,
) !void {
    if (key_event.event_type == .release) return;

    if ((key_event.key == .c and key_event.modifiers.ctrl) or key_event.codepoint == 3) {
        const now_ms = clock.nowMs();
        if (state.last_ctrl_c_ms) |previous| {
            if (now_ms >= previous and now_ms - previous <= double_ctrl_c_ms) {
                state.quit_requested = true;
                return;
            }
        }
        clearComposer(&state.composer);
        state.last_ctrl_c_ms = now_ms;
        return;
    }

    if ((key_event.modifiers.ctrl and
        (key_event.codepoint == 'd' or key_event.codepoint == 'D')) or
        (!key_event.modifiers.ctrl and key_event.key == .character and key_event.codepoint == 4))
    {
        state.quit_requested = true;
        return;
    }

    if (key_event.key == .escape) {
        try session.inbox().push(io, .{ .cancel = .user });
        return;
    }

    if (key_event.key == .enter and !key_event.modifiers.shift) {
        if (tuizr.textInputHandleKey(&state.composer, key_event)) |submitted| {
            if (submitted.len != 0) {
                try pushPrompt(gpa, io, session, submitted);
                state.appendPrompt(submitted);
            }
        }
        return;
    }
    if (key_event.key == .enter) return;

    _ = tuizr.textInputHandleKey(&state.composer, key_event);
}

fn pushPrompt(
    gpa: Allocator,
    io: std.Io,
    session: *agent.AgentSession,
    text: []const u8,
) !void {
    var prompt = try events.OwnedPrompt.init(gpa, text, &.{}, false, .user);
    defer prompt.deinit(gpa);
    try session.inbox().push(io, .{ .prompt = prompt });
}

fn clearComposer(composer: *tuizr.TextInput) void {
    composer.len = 0;
    composer.cursor = 0;
    composer.scroll_x = 0;
    composer.history_idx = null;
    composer.saved_len = 0;
    composer.submitted_len = 0;
}

fn draw(state: *State, grid: *tuizr.CellGrid) void {
    grid.fill(tuizr.default_cell);
    const width = grid.width();
    const height = grid.height();
    if (height == 0) return;

    const transcript_height = height -| 2;
    state.setTranscriptViewport(width, transcript_height);
    if (transcript_height != 0) {
        tuizr.drawStreamingView(
            grid,
            .{ .x = 0, .y = 0, .w = width, .h = transcript_height },
            &state.transcript,
            .{},
        );
    }

    const composer_y = if (height >= 2) height - 2 else 0;
    tuizr.drawTextInput(
        grid,
        .{ .x = 0, .y = composer_y, .w = width, .h = 1 },
        &state.composer,
        .{ .bg = .{ .r = 18, .g = 22, .b = 30 } },
        true,
    );

    if (height >= 2) {
        const status = if (state.is_running)
            "running | esc cancel | ctrl+c clear/quit | ctrl+d quit"
        else
            "ready | esc cancel | ctrl+c clear/quit | ctrl+d quit";
        const status_view = tuizr.TextView{ .content = status };
        tuizr.drawTextView(
            grid,
            .{ .x = 0, .y = height - 1, .w = width, .h = 1 },
            &status_view,
            .{
                .fg = .{ .r = 170, .g = 178, .b = 196 },
                .bg = .{ .r = 10, .g = 12, .b = 18 },
                .attrs = tuizr.Attr.dim,
            },
        );
    }
}

fn keyCharacter(codepoint: u21) tuizr.KeyEvent {
    return .{ .key = .character, .codepoint = codepoint };
}

fn keyNamed(key: tuizr.Key) tuizr.KeyEvent {
    return .{ .key = key, .codepoint = 0 };
}

fn keyCtrlC(event_type: tuizr.EventType) tuizr.KeyEvent {
    return .{
        .key = .c,
        .codepoint = 'c',
        .modifiers = .{ .ctrl = true },
        .event_type = event_type,
    };
}

fn applyAssistantScript(allocator: Allocator, state: *State) !void {
    var script = [_]events.AgentEvent{
        .run_started,
        .{ .message_started = try events.MessageStarted.init(allocator, "a1", .assistant) },
        .{ .text_delta = try events.TextDelta.init(allocator, "a1", "Hel") },
        .{ .text_delta = try events.TextDelta.init(allocator, "a1", "lo") },
        .{ .message_finished = try events.MessageFinished.init(
            allocator,
            "a1",
            .stop,
            &.{"Hello"},
            null,
        ) },
        .{ .run_finished = .{ .status = .completed, .turns = 1 } },
    };
    defer for (&script) |*event| event.deinit(allocator);
    for (script) |event| applyEvent(state, event);
}

fn applyActivityScript(allocator: Allocator, state: *State) !void {
    var script = [_]events.AgentEvent{
        .run_started,
        .{ .message_started = try events.MessageStarted.init(allocator, "a1", .assistant) },
        .{ .reasoning_delta = try events.ReasoningDelta.init(allocator, "a1", "pondering") },
        .{ .tool_started = try events.ToolStarted.init(allocator, "t1", "read", "{}") },
        .{ .tool_finished = try events.ToolFinished.init(allocator, "t1", "read", false, null) },
        .{ .text_delta = try events.TextDelta.init(allocator, "a1", "Hi") },
        .{ .message_finished = try events.MessageFinished.init(
            allocator,
            "a1",
            .stop,
            &.{"Hi"},
            null,
        ) },
    };
    defer for (&script) |*event| event.deinit(allocator);
    for (script) |event| applyEvent(state, event);
}

fn gridProjectionAlloc(allocator: Allocator, grid: *const tuizr.CellGrid) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    var row: u16 = 0;
    while (row < grid.height()) : (row += 1) {
        var last_non_space: usize = 0;
        var col: u16 = 0;
        while (col < grid.width()) : (col += 1) {
            const value = grid.getCell(col, row) orelse continue;
            if (value.codepoint != ' ') last_non_space = @as(usize, col) + 1;
        }

        col = 0;
        while (col < last_non_space) : (col += 1) {
            const value = grid.getCell(col, row) orelse continue;
            const codepoint: u21 = if (value.codepoint <= std.math.maxInt(u21))
                @intCast(value.codepoint)
            else
                '?';
            var encoded: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(codepoint, &encoded) catch 1;
            if (len == 1 and codepoint > std.math.maxInt(u7)) encoded[0] = '?';
            try output.appendSlice(allocator, encoded[0..len]);
        }
        try output.append(allocator, '\n');
    }
    return output.toOwnedSlice(allocator);
}

const TestSession = struct {
    allocator: Allocator,
    mock: testkit.MockTransport,
    factory: openai_compatible.OpenAiCompatible,
    chat: openai_compatible.ChatLanguageModel,
    tools: tool_api.ToolRegistry,
    session: agent.AgentSession,

    fn create(allocator: Allocator, io: std.Io) !*TestSession {
        const result = try allocator.create(TestSession);
        errdefer allocator.destroy(result);
        result.allocator = allocator;
        result.mock = testkit.MockTransport.init(&.{});
        result.factory = openai_compatible.createOpenAiCompatible(.{
            .provider_name = "phase-3a-test",
            .base_url = "https://example.test/v1",
            .api_key = "dummy-key",
            .transport = result.mock.transport(),
        });
        result.chat = try result.factory.chatModel("smoke-model", null);
        result.tools = tool_api.ToolRegistry.init(allocator);
        errdefer result.tools.deinit();
        result.session = try agent.AgentSession.init(allocator, io, .{
            .model = .{
                .language_model = .{ .model = result.chat.languageModel() },
                .provider_name = "phase-3a-test",
                .model_id = "smoke-model",
                .api = "openai-compatible",
            },
            .tools = &result.tools,
        });
        return result;
    }

    fn deinit(self: *TestSession) void {
        const allocator = self.allocator;
        self.session.deinit();
        self.tools.deinit();
        self.* = undefined;
        allocator.destroy(self);
    }
};

test "agent events append streamed assistant text to the transcript" {
    var state = State.init(40, 4);
    try applyAssistantScript(std.testing.allocator, &state);

    try std.testing.expectEqualStrings(
        "assistant: Hello\n",
        state.transcript.buffer[0..state.transcript.len],
    );
    try std.testing.expect(!state.is_running);
}

test "composed frame matches the CellGrid text projection" {
    var state = State.init(64, 4);
    try applyAssistantScript(std.testing.allocator, &state);
    var grid = try tuizr.CellGrid.init(std.testing.allocator, 64, 6);
    defer grid.deinit();

    draw(&state, &grid);
    const projection = try gridProjectionAlloc(std.testing.allocator, &grid);
    defer std.testing.allocator.free(projection);
    try std.testing.expectEqualStrings(
        "assistant: Hello\n\n\n\n\n" ++
            "ready | esc cancel | ctrl+c clear/quit | ctrl+d quit\n",
        projection,
    );
}

test "reasoning and tool activity precede the streamed reply in the CellGrid projection" {
    var state = State.init(64, 6);
    try applyActivityScript(std.testing.allocator, &state);
    var grid = try tuizr.CellGrid.init(std.testing.allocator, 64, 8);
    defer grid.deinit();

    draw(&state, &grid);
    const projection = try gridProjectionAlloc(std.testing.allocator, &grid);
    defer std.testing.allocator.free(projection);
    try std.testing.expectEqualStrings(
        "thinking: pondering\n" ++
            "→ read\n" ++
            "  done\n" ++
            "assistant: Hi\n\n\n\n" ++
            "running | esc cancel | ctrl+c clear/quit | ctrl+d quit\n",
        projection,
    );
}

test "text input submission pushes one prompt and clears the composer" {
    const fixture = try TestSession.create(std.testing.allocator, std.testing.io);
    defer fixture.deinit();
    var state = State.init(40, 4);
    var now_ms: i64 = 0;
    const clock: Clock = .{ .fixed_ms = &now_ms };

    try handleKey(std.testing.allocator, std.testing.io, &fixture.session, &state, clock, keyCharacter('h'));
    try handleKey(std.testing.allocator, std.testing.io, &fixture.session, &state, clock, keyCharacter('i'));
    try handleKey(std.testing.allocator, std.testing.io, &fixture.session, &state, clock, keyNamed(.enter));

    var command = fixture.session.inbox().tryPop(std.testing.io) orelse
        return error.TestUnexpectedResult;
    defer command.deinit(std.testing.allocator);
    try std.testing.expect(command == .prompt);
    try std.testing.expectEqualStrings("hi", command.prompt.text);
    try std.testing.expect(fixture.session.inbox().tryPop(std.testing.io) == null);
    try std.testing.expectEqual(@as(usize, 0), state.composer.len);
}

test "escape pushes user cancellation" {
    const fixture = try TestSession.create(std.testing.allocator, std.testing.io);
    defer fixture.deinit();
    var state = State.init(40, 4);
    var now_ms: i64 = 0;
    const clock: Clock = .{ .fixed_ms = &now_ms };

    state.is_running = true;
    try handleKey(std.testing.allocator, std.testing.io, &fixture.session, &state, clock, keyNamed(.escape));

    var command = fixture.session.inbox().tryPop(std.testing.io) orelse
        return error.TestUnexpectedResult;
    defer command.deinit(std.testing.allocator);
    try std.testing.expect(command == .cancel);
    try std.testing.expect(command.cancel == .user);
}

test "Ctrl+C clears once and quits only on a second press within 500ms" {
    const fixture = try TestSession.create(std.testing.allocator, std.testing.io);
    defer fixture.deinit();
    var now_ms: i64 = 1_000;
    const clock: Clock = .{ .fixed_ms = &now_ms };
    var state = State.init(40, 4);

    try handleKey(std.testing.allocator, std.testing.io, &fixture.session, &state, clock, keyCharacter('x'));
    try handleKey(std.testing.allocator, std.testing.io, &fixture.session, &state, clock, keyCtrlC(.release));
    try std.testing.expectEqual(@as(usize, 1), state.composer.len);
    try handleKey(std.testing.allocator, std.testing.io, &fixture.session, &state, clock, keyCtrlC(.press));
    try std.testing.expectEqual(@as(usize, 0), state.composer.len);
    try std.testing.expect(!state.quit_requested);

    now_ms = 1_500;
    try handleKey(std.testing.allocator, std.testing.io, &fixture.session, &state, clock, keyCtrlC(.press));
    try std.testing.expect(state.quit_requested);

    var late_state = State.init(40, 4);
    now_ms = 2_000;
    try handleKey(std.testing.allocator, std.testing.io, &fixture.session, &late_state, clock, keyCharacter('a'));
    try handleKey(std.testing.allocator, std.testing.io, &fixture.session, &late_state, clock, keyCtrlC(.press));
    try handleKey(std.testing.allocator, std.testing.io, &fixture.session, &late_state, clock, keyCharacter('b'));
    now_ms = 2_501;
    try handleKey(std.testing.allocator, std.testing.io, &fixture.session, &late_state, clock, keyCtrlC(.press));
    try std.testing.expect(!late_state.quit_requested);
    try std.testing.expectEqual(@as(usize, 0), late_state.composer.len);
}

test "raw Ctrl+C clears once and quits only on a second press within 500ms" {
    const fixture = try TestSession.create(std.testing.allocator, std.testing.io);
    defer fixture.deinit();
    var now_ms: i64 = 1_000;
    const clock: Clock = .{ .fixed_ms = &now_ms };
    var state = State.init(40, 4);
    const raw_ctrl_c = tuizr.KeyEvent{ .key = .character, .codepoint = 3 };

    try handleKey(std.testing.allocator, std.testing.io, &fixture.session, &state, clock, keyCharacter('x'));
    try handleKey(std.testing.allocator, std.testing.io, &fixture.session, &state, clock, raw_ctrl_c);
    try std.testing.expectEqual(@as(usize, 0), state.composer.len);
    try std.testing.expect(!state.quit_requested);

    now_ms = 1_499;
    try handleKey(std.testing.allocator, std.testing.io, &fixture.session, &state, clock, raw_ctrl_c);
    try std.testing.expect(state.quit_requested);
}

test "Ctrl+D codepoint requests a normal quit" {
    const fixture = try TestSession.create(std.testing.allocator, std.testing.io);
    defer fixture.deinit();
    var state = State.init(40, 4);
    var now_ms: i64 = 0;
    const clock: Clock = .{ .fixed_ms = &now_ms };
    const ctrl_d = tuizr.KeyEvent{
        .key = .character,
        .codepoint = 'd',
        .modifiers = .{ .ctrl = true },
    };

    try handleKey(std.testing.allocator, std.testing.io, &fixture.session, &state, clock, ctrl_d);
    try std.testing.expect(state.quit_requested);
    try std.testing.expect(fixture.session.inbox().tryPop(std.testing.io) == null);
}
