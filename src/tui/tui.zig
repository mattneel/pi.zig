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

const transcript_theme: tuizr.TranscriptTheme = .{
    .markdown = .{
        .text = .{
            .fg = .{ .r = 224, .g = 228, .b = 238 },
            .bg = .{ .r = 0, .g = 0, .b = 0 },
        },
        .heading = .{
            .fg = .{ .r = 150, .g = 205, .b = 255 },
            .bg = .{ .r = 0, .g = 0, .b = 0 },
            .attrs = tuizr.Attr.bold,
        },
        .code = .{
            .fg = .{ .r = 232, .g = 235, .b = 242 },
            .bg = .{ .r = 30, .g = 35, .b = 46 },
        },
        .code_bg = .{
            .fg = .{ .r = 232, .g = 235, .b = 242 },
            .bg = .{ .r = 20, .g = 24, .b = 34 },
        },
        .quote = .{
            .fg = .{ .r = 175, .g = 184, .b = 200 },
            .bg = .{ .r = 0, .g = 0, .b = 0 },
            .attrs = tuizr.Attr.dim,
        },
        .bullet = .{
            .fg = .{ .r = 115, .g = 195, .b = 255 },
            .bg = .{ .r = 0, .g = 0, .b = 0 },
        },
        .link = .{
            .fg = .{ .r = 110, .g = 185, .b = 255 },
            .bg = .{ .r = 0, .g = 0, .b = 0 },
            .attrs = tuizr.Attr.underline,
        },
    },
    .user = .{
        .fg = .{ .r = 160, .g = 215, .b = 255 },
        .bg = .{ .r = 15, .g = 27, .b = 42 },
    },
    .reasoning = .{
        .fg = .{ .r = 160, .g = 170, .b = 188 },
        .bg = .{ .r = 0, .g = 0, .b = 0 },
        .attrs = tuizr.Attr.dim,
    },
    .tool = .{
        .fg = .{ .r = 170, .g = 225, .b = 190 },
        .bg = .{ .r = 16, .g = 30, .b = 26 },
    },
    .@"error" = .{
        .fg = .{ .r = 245, .g = 145, .b = 145 },
        .bg = .{ .r = 0, .g = 0, .b = 0 },
    },
    .notice = .{
        .fg = .{ .r = 185, .g = 194, .b = 210 },
        .bg = .{ .r = 0, .g = 0, .b = 0 },
        .attrs = tuizr.Attr.dim,
    },
    .separator = .{
        .fg = .{ .r = 105, .g = 115, .b = 130 },
        .bg = .{ .r = 0, .g = 0, .b = 0 },
        .attrs = tuizr.Attr.dim,
    },
};

const composer_style: tuizr.widgets.Style = .{
    .fg = .{ .r = 232, .g = 236, .b = 248 },
    .bg = .{ .r = 38, .g = 46, .b = 64 },
};

const status_style: tuizr.widgets.Style = .{
    .fg = .{ .r = 210, .g = 215, .b = 230 },
    .bg = .{ .r = 24, .g = 30, .b = 44 },
};

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
    transcript: tuizr.Transcript = .{},
    current_kind: ?tuizr.BlockKind = null,
    composer: tuizr.TextInput,
    is_running: bool = false,
    quit_requested: bool = false,
    last_ctrl_c_ms: ?i64 = null,

    fn init() State {
        return .{ .composer = tuizr.TextInput.init() };
    }
};

fn ensureBlock(state: *State, kind: tuizr.BlockKind) void {
    if (state.current_kind == kind) return;
    tuizr.transcriptStartBlock(&state.transcript, kind);
    state.current_kind = kind;
}

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

    const state = try gpa.create(State);
    defer gpa.destroy(state);
    state.* = State.init();

    for (initial_prompts) |text| {
        try pushPrompt(gpa, io, session, text);
        tuizr.transcriptStartBlock(&state.transcript, .user);
        tuizr.transcriptAppend(&state.transcript, text);
        tuizr.transcriptFinalize(&state.transcript);
        state.current_kind = null;
    }

    const clock: Clock = .{ .io = io };
    while (!state.quit_requested) {
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
            state.current_kind = null;
        },
        .reasoning_delta => |delta| {
            ensureBlock(state, .reasoning);
            tuizr.transcriptAppend(&state.transcript, delta.text);
        },
        .text_delta => |delta| {
            ensureBlock(state, .assistant);
            tuizr.transcriptAppend(&state.transcript, delta.text);
        },
        .message_finished => {
            tuizr.transcriptFinalize(&state.transcript);
            state.current_kind = null;
        },
        .tool_started => |started| {
            tuizr.transcriptStartBlock(&state.transcript, .tool);
            tuizr.transcriptAppend(&state.transcript, "→ ");
            tuizr.transcriptAppend(&state.transcript, started.tool_name);
            tuizr.transcriptAppend(&state.transcript, "\n");
            state.current_kind = .tool;
        },
        .tool_output => |output| {
            // Phase 5 will route interleaved output by tool_call_id.
            tuizr.transcriptAppend(&state.transcript, output.bytes);
        },
        .tool_finished => |finished| {
            tuizr.transcriptAppend(&state.transcript, "\n");
            tuizr.transcriptAppend(&state.transcript, if (finished.is_error) "error" else "done");
            tuizr.transcriptFinalize(&state.transcript);
            state.current_kind = null;
        },
        .approval_requested => |request| {
            tuizr.transcriptStartBlock(&state.transcript, .notice);
            tuizr.transcriptAppend(&state.transcript, "auto-approved ");
            tuizr.transcriptAppend(&state.transcript, request.tool_name);
            tuizr.transcriptAppend(&state.transcript, " (approval UI arrives in Phase 5)");
            tuizr.transcriptFinalize(&state.transcript);
            state.current_kind = null;
        },
        .failed => |failure| {
            tuizr.transcriptStartBlock(&state.transcript, .@"error");
            tuizr.transcriptAppend(&state.transcript, failure.message);
            tuizr.transcriptFinalize(&state.transcript);
            state.current_kind = null;
        },
        .notice => |notice| {
            tuizr.transcriptStartBlock(&state.transcript, .notice);
            tuizr.transcriptAppend(&state.transcript, notice.message);
            tuizr.transcriptFinalize(&state.transcript);
            state.current_kind = null;
        },
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
                tuizr.transcriptStartBlock(&state.transcript, .user);
                tuizr.transcriptAppend(&state.transcript, submitted);
                tuizr.transcriptFinalize(&state.transcript);
                state.current_kind = null;
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
    if (transcript_height != 0) {
        tuizr.drawTranscript(
            grid,
            .{ .x = 0, .y = 0, .w = width, .h = transcript_height },
            &state.transcript,
            transcript_theme,
        );
    }

    const composer_y = if (height >= 2) height - 2 else 0;
    tuizr.drawTextInput(
        grid,
        .{ .x = 0, .y = composer_y, .w = width, .h = 1 },
        &state.composer,
        composer_style,
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
            status_style,
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

fn applyConsecutiveAssistantScript(allocator: Allocator, state: *State) !void {
    var script = [_]events.AgentEvent{
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
    };
    defer for (&script) |*event| event.deinit(allocator);
    for (script) |event| applyEvent(state, event);
}

fn applyComposedFrameScript(allocator: Allocator, state: *State) !void {
    var script = [_]events.AgentEvent{
        .run_started,
        .{ .message_started = try events.MessageStarted.init(allocator, "a1", .assistant) },
        .{ .reasoning_delta = try events.ReasoningDelta.init(allocator, "a1", "pondering") },
        .{ .text_delta = try events.TextDelta.init(allocator, "a1", "Hello") },
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

fn applyToolScript(allocator: Allocator, state: *State) !void {
    var script = [_]events.AgentEvent{
        .{ .tool_started = try events.ToolStarted.init(allocator, "t1", "read", "{}") },
        .{ .tool_output = try events.ToolOutputDelta.init(allocator, "t1", "contents") },
        .{ .tool_finished = try events.ToolFinished.init(allocator, "t1", "read", false, null) },
    };
    defer for (&script) |*event| event.deinit(allocator);
    for (script) |event| applyEvent(state, event);
}

fn transcriptBlockContent(transcript: *const tuizr.Transcript, index: usize) []const u8 {
    const block = transcript.blocks[index];
    return transcript.buffer[block.start .. block.start + block.len];
}

fn expectCellColors(expected: tuizr.widgets.Style, actual: tuizr.Cell) !void {
    try std.testing.expectEqual(expected.fg.r, actual.fg_r);
    try std.testing.expectEqual(expected.fg.g, actual.fg_g);
    try std.testing.expectEqual(expected.fg.b, actual.fg_b);
    try std.testing.expectEqual(expected.bg.r, actual.bg_r);
    try std.testing.expectEqual(expected.bg.g, actual.bg_g);
    try std.testing.expectEqual(expected.bg.b, actual.bg_b);
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

test "consecutive assistant deltas append to one transcript block" {
    var state = State.init();
    try applyConsecutiveAssistantScript(std.testing.allocator, &state);

    try std.testing.expectEqual(@as(usize, 1), state.transcript.block_count);
    const block = state.transcript.blocks[0];
    try std.testing.expectEqual(tuizr.BlockKind.assistant, block.kind);
    try std.testing.expect(block.finalized);
    try std.testing.expectEqualStrings("Hello", transcriptBlockContent(&state.transcript, 0));
    try std.testing.expectEqual(@as(?usize, null), state.transcript.active_index);
    try std.testing.expectEqual(@as(?tuizr.BlockKind, null), state.current_kind);
}

test "composed reasoning and assistant frame matches the CellGrid projection and styles" {
    var state = State.init();
    try applyComposedFrameScript(std.testing.allocator, &state);
    var grid = try tuizr.CellGrid.init(std.testing.allocator, 64, 6);
    defer grid.deinit();

    draw(&state, &grid);
    const projection = try gridProjectionAlloc(std.testing.allocator, &grid);
    defer std.testing.allocator.free(projection);
    try std.testing.expectEqualStrings(
        "pondering\n\nHello\n\n\n" ++
            "ready | esc cancel | ctrl+c clear/quit | ctrl+d quit\n",
        projection,
    );

    const reasoning = grid.getCell(0, 0) orelse return error.TestUnexpectedResult;
    const assistant = grid.getCell(0, 2) orelse return error.TestUnexpectedResult;
    const composer = grid.getCell(0, 4) orelse return error.TestUnexpectedResult;
    const status = grid.getCell(0, 5) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(transcript_theme.reasoning.attrs, reasoning.attrs);
    try expectCellColors(transcript_theme.reasoning, reasoning);
    try std.testing.expectEqual(transcript_theme.markdown.text.attrs, assistant.attrs);
    try expectCellColors(transcript_theme.markdown.text, assistant);
    try std.testing.expectEqual(composer_style.attrs | tuizr.Attr.reverse, composer.attrs);
    try expectCellColors(composer_style, composer);
    try std.testing.expectEqual(status_style.attrs, status.attrs);
    try expectCellColors(status_style, status);
    try std.testing.expect(!state.is_running);
}

test "tool events render one finalized transcript block with header output and status" {
    var state = State.init();
    try applyToolScript(std.testing.allocator, &state);
    var grid = try tuizr.CellGrid.init(std.testing.allocator, 64, 6);
    defer grid.deinit();

    draw(&state, &grid);
    const projection = try gridProjectionAlloc(std.testing.allocator, &grid);
    defer std.testing.allocator.free(projection);
    try std.testing.expectEqualStrings(
        "→ read\ncontents\ndone\n\n\n" ++
            "ready | esc cancel | ctrl+c clear/quit | ctrl+d quit\n",
        projection,
    );

    try std.testing.expectEqual(@as(usize, 1), state.transcript.block_count);
    const block = state.transcript.blocks[0];
    try std.testing.expectEqual(tuizr.BlockKind.tool, block.kind);
    try std.testing.expect(block.finalized);
    try std.testing.expectEqualStrings("→ read\ncontents\ndone", transcriptBlockContent(&state.transcript, 0));
    const header = grid.getCell(0, 0) orelse return error.TestUnexpectedResult;
    const output = grid.getCell(0, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(transcript_theme.tool.attrs | tuizr.Attr.bold, header.attrs);
    try expectCellColors(transcript_theme.tool, header);
    try std.testing.expectEqual(transcript_theme.tool.attrs, output.attrs);
    try expectCellColors(transcript_theme.tool, output);
    try std.testing.expectEqual(@as(?tuizr.BlockKind, null), state.current_kind);
}

test "text input submission pushes one prompt and clears the composer" {
    const fixture = try TestSession.create(std.testing.allocator, std.testing.io);
    defer fixture.deinit();
    var state = State.init();
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
    try std.testing.expectEqual(@as(usize, 1), state.transcript.block_count);
    try std.testing.expectEqual(tuizr.BlockKind.user, state.transcript.blocks[0].kind);
    try std.testing.expect(state.transcript.blocks[0].finalized);
    try std.testing.expectEqualStrings("hi", transcriptBlockContent(&state.transcript, 0));
}

test "escape pushes user cancellation" {
    const fixture = try TestSession.create(std.testing.allocator, std.testing.io);
    defer fixture.deinit();
    var state = State.init();
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
    var state = State.init();

    try handleKey(std.testing.allocator, std.testing.io, &fixture.session, &state, clock, keyCharacter('x'));
    try handleKey(std.testing.allocator, std.testing.io, &fixture.session, &state, clock, keyCtrlC(.release));
    try std.testing.expectEqual(@as(usize, 1), state.composer.len);
    try handleKey(std.testing.allocator, std.testing.io, &fixture.session, &state, clock, keyCtrlC(.press));
    try std.testing.expectEqual(@as(usize, 0), state.composer.len);
    try std.testing.expect(!state.quit_requested);

    now_ms = 1_500;
    try handleKey(std.testing.allocator, std.testing.io, &fixture.session, &state, clock, keyCtrlC(.press));
    try std.testing.expect(state.quit_requested);

    var late_state = State.init();
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
    var state = State.init();
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
    var state = State.init();
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
