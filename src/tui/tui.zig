//! Interactive terminal frontend over the agent mailbox contract.

const std = @import("std");
const builtin = @import("builtin");
const openai_compatible = @import("openai_compatible");
const tuizr = @import("tuizr");
const catalog = @import("../catalog/types.zig");
const model_catalog = @import("../catalog/models.zig");
const agent = @import("../core/agent.zig");
const events = @import("../core/events.zig");
const tool_api = @import("../core/tool.zig");
const testkit = @import("../testkit/mock_transport.zig");
const autocomplete = @import("autocomplete.zig");
const slash = @import("slash.zig");

const Allocator = std.mem.Allocator;
const double_ctrl_c_ms: i64 = 500;
const spinner_frame_ms: i64 = 80;
const max_composer_height: u16 = 8;
const max_in_flight_tools: usize = 8;
const max_tool_call_id_bytes: usize = 256;
const max_tool_name_bytes: usize = 256;
const max_buffered_tool_output_bytes: usize = 8 * 1024;
const buffered_tool_output_truncation_marker = "…[output truncated]";
const shell_timeout_seconds: i64 = 10;
const max_shell_output_bytes: usize = 64 * 1024;

const thinking_level_names = [_][]const u8{
    "off",
    "minimal",
    "low",
    "medium",
    "high",
    "xhigh",
    "max",
    "ultra",
};

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

const InFlightToolCall = struct {
    tool_call_id: [max_tool_call_id_bytes]u8 = undefined,
    tool_call_id_len: usize = 0,
    tool_call_id_source_len: usize = 0,
    tool_call_id_hash: u64 = 0,
    tool_name: [max_tool_name_bytes]u8 = undefined,
    tool_name_len: usize = 0,
    output: [max_buffered_tool_output_bytes]u8 = undefined,
    output_len: usize = 0,
    output_truncated: bool = false,
    finished: bool = false,
    is_error: bool = false,

    fn init(tool_call_id: []const u8, tool_name: []const u8) InFlightToolCall {
        var result: InFlightToolCall = .{};

        result.tool_call_id_len = @min(tool_call_id.len, max_tool_call_id_bytes);
        @memcpy(
            result.tool_call_id[0..result.tool_call_id_len],
            tool_call_id[0..result.tool_call_id_len],
        );
        result.tool_call_id_source_len = tool_call_id.len;
        result.tool_call_id_hash = std.hash.XxHash64.hash(0, tool_call_id);

        result.tool_name_len = @min(tool_name.len, max_tool_name_bytes);
        @memcpy(
            result.tool_name[0..result.tool_name_len],
            tool_name[0..result.tool_name_len],
        );
        return result;
    }

    fn matches(self: *const InFlightToolCall, tool_call_id: []const u8, id_hash: u64) bool {
        if (self.tool_call_id_source_len != tool_call_id.len or
            self.tool_call_id_hash != id_hash)
        {
            return false;
        }
        return std.mem.eql(
            u8,
            self.tool_call_id[0..self.tool_call_id_len],
            tool_call_id[0..self.tool_call_id_len],
        );
    }

    fn name(self: *const InFlightToolCall) []const u8 {
        return self.tool_name[0..self.tool_name_len];
    }

    fn bufferedOutput(self: *const InFlightToolCall) []const u8 {
        return self.output[0..self.output_len];
    }

    fn appendBufferedOutput(self: *InFlightToolCall, bytes: []const u8) void {
        if (bytes.len == 0 or self.output_truncated) return;

        const available = max_buffered_tool_output_bytes - self.output_len;
        const retained_len = @min(bytes.len, available);
        @memcpy(
            self.output[self.output_len .. self.output_len + retained_len],
            bytes[0..retained_len],
        );
        self.output_len += retained_len;

        if (retained_len != bytes.len) {
            const marker_start = max_buffered_tool_output_bytes -
                buffered_tool_output_truncation_marker.len;
            @memcpy(
                self.output[marker_start..max_buffered_tool_output_bytes],
                buffered_tool_output_truncation_marker,
            );
            self.output_len = max_buffered_tool_output_bytes;
            self.output_truncated = true;
        }
    }
};

const AutocompletePopup = struct {
    visible: bool = false,
    completions: autocomplete.Completions = .{},
    item_views: [autocomplete.max_items][]const u8 = undefined,
    selected: usize = 0,

    fn set(self: *AutocompletePopup, completions: autocomplete.Completions) void {
        self.completions = completions;
        self.selected = 0;
        self.visible = completions.count != 0;
        for (self.completions.items[0..self.completions.count], 0..) |*item, index| {
            self.item_views[index] = item.label();
        }
    }

    fn hide(self: *AutocompletePopup) void {
        self.visible = false;
        self.selected = 0;
    }

    fn previous(self: *AutocompletePopup) void {
        if (self.completions.count == 0) return;
        self.selected = if (self.selected == 0) self.completions.count - 1 else self.selected - 1;
    }

    fn next(self: *AutocompletePopup) void {
        if (self.completions.count == 0) return;
        self.selected = (self.selected + 1) % self.completions.count;
    }

    fn selectedItem(self: *const AutocompletePopup) ?*const autocomplete.Item {
        if (!self.visible or self.completions.count == 0) return null;
        return &self.completions.items[@min(self.selected, self.completions.count - 1)];
    }
};

const State = struct {
    transcript: tuizr.Transcript = .{},
    current_kind: ?tuizr.BlockKind = null,
    tool_calls: [max_in_flight_tools]InFlightToolCall = undefined,
    tool_head: usize = 0,
    tool_count: usize = 0,
    composer: tuizr.TextInput,
    is_running: bool = false,
    usage: ?events.UsageSnapshot = null,
    spinner_started_ms: ?i64 = null,
    transcript_width: u16 = 0,
    transcript_viewport_height: u16 = 0,
    quit_requested: bool = false,
    last_ctrl_c_ms: ?i64 = null,
    popup: AutocompletePopup = .{},
    registry: ?model_catalog.Registry = null,
    model_ids: []const []const u8 = &.{},
    effort_names: []const []const u8 = &thinking_level_names,

    fn init() State {
        var composer = tuizr.TextInput.init();
        composer.multiline = true;
        return .{ .composer = composer };
    }

    fn initCatalog(self: *State, allocator: Allocator) !void {
        self.registry = try model_catalog.Registry.init(allocator);
        errdefer {
            self.registry.?.deinit();
            self.registry = null;
        }
        self.model_ids = try collectModelIds(allocator, &self.registry.?);
    }

    fn deinit(self: *State, allocator: Allocator) void {
        if (self.model_ids.len != 0) allocator.free(self.model_ids);
        if (self.registry) |*registry| registry.deinit();
        self.registry = null;
        self.model_ids = &.{};
    }
};

fn collectModelIds(allocator: Allocator, registry: *const model_catalog.Registry) ![]const []const u8 {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    var result: std.ArrayList([]const u8) = .empty;
    defer result.deinit(allocator);

    var provider_iterator = registry.providers.iterator();
    while (provider_iterator.next()) |provider_entry| {
        var model_iterator = provider_entry.value_ptr.iterator();
        while (model_iterator.next()) |model_entry| {
            const model_id = model_entry.key_ptr.*;
            if (seen.contains(model_id)) continue;
            try seen.put(allocator, model_id, {});
            try result.append(allocator, model_id);
        }
    }
    std.mem.sort([]const u8, result.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);
    return result.toOwnedSlice(allocator);
}

fn ensureBlock(state: *State, kind: tuizr.BlockKind) void {
    if (state.current_kind == kind) return;
    tuizr.transcriptStartBlock(&state.transcript, kind);
    state.current_kind = kind;
}

fn findToolCall(state: *const State, tool_call_id: []const u8) ?usize {
    const id_hash = std.hash.XxHash64.hash(0, tool_call_id);
    var offset: usize = 0;
    while (offset < state.tool_count) : (offset += 1) {
        const index = (state.tool_head + offset) % max_in_flight_tools;
        if (state.tool_calls[index].matches(tool_call_id, id_hash)) return index;
    }
    return null;
}

fn startToolBlock(state: *State, tool_name: []const u8) void {
    tuizr.transcriptStartBlock(&state.transcript, .tool);
    tuizr.transcriptAppend(&state.transcript, "→ ");
    tuizr.transcriptAppend(&state.transcript, tool_name);
    tuizr.transcriptAppend(&state.transcript, "\n");
    state.current_kind = .tool;
}

fn appendToolStatus(state: *State, is_error: bool) void {
    tuizr.transcriptAppend(&state.transcript, "\n");
    tuizr.transcriptAppend(&state.transcript, if (is_error) "error" else "done");
}

fn popForegroundTool(state: *State) void {
    state.tool_head = (state.tool_head + 1) % max_in_flight_tools;
    state.tool_count -= 1;
    if (state.tool_count == 0) state.tool_head = 0;
}

fn finalizeForegroundToolAndPromote(state: *State, is_error: bool) void {
    appendToolStatus(state, is_error);
    tuizr.transcriptFinalize(&state.transcript);
    state.current_kind = null;
    popForegroundTool(state);

    while (state.tool_count != 0) {
        const pending = &state.tool_calls[state.tool_head];
        startToolBlock(state, pending.name());
        tuizr.transcriptAppend(&state.transcript, pending.bufferedOutput());
        if (!pending.finished) return;

        appendToolStatus(state, pending.is_error);
        tuizr.transcriptFinalize(&state.transcript);
        state.current_kind = null;
        popForegroundTool(state);
    }
}

fn appendOverflowedToolStart(state: *State, tool_name: []const u8) void {
    if (state.current_kind != .tool) return;
    tuizr.transcriptAppend(&state.transcript, "\n→ ");
    tuizr.transcriptAppend(&state.transcript, tool_name);
    tuizr.transcriptAppend(&state.transcript, "\n");
}

fn appendOverflowedToolFinish(state: *State, is_error: bool) void {
    if (state.current_kind != .tool) return;
    appendToolStatus(state, is_error);
    tuizr.transcriptAppend(&state.transcript, "\n");
}

fn toolStarted(state: *State, tool_call_id: []const u8, tool_name: []const u8) void {
    if (state.tool_count == max_in_flight_tools) {
        appendOverflowedToolStart(state, tool_name);
        return;
    }

    const was_empty = state.tool_count == 0;
    const index = (state.tool_head + state.tool_count) % max_in_flight_tools;
    state.tool_calls[index] = InFlightToolCall.init(tool_call_id, tool_name);
    state.tool_count += 1;
    if (was_empty) startToolBlock(state, tool_name);
}

fn toolOutput(state: *State, tool_call_id: []const u8, bytes: []const u8) void {
    const index = findToolCall(state, tool_call_id) orelse {
        if (state.current_kind == .tool) {
            tuizr.transcriptAppend(&state.transcript, bytes);
        }
        return;
    };

    if (index == state.tool_head) {
        tuizr.transcriptAppend(&state.transcript, bytes);
    } else {
        state.tool_calls[index].appendBufferedOutput(bytes);
    }
}

fn toolFinished(state: *State, tool_call_id: []const u8, is_error: bool) void {
    const index = findToolCall(state, tool_call_id) orelse {
        appendOverflowedToolFinish(state, is_error);
        return;
    };

    const call = &state.tool_calls[index];
    call.finished = true;
    call.is_error = is_error;
    if (index == state.tool_head) finalizeForegroundToolAndPromote(state, is_error);
}

pub fn run(
    gpa: Allocator,
    io: std.Io,
    session: *agent.AgentSession,
    model_label: []const u8,
    thinking: catalog.ThinkingLevel,
    initial_prompts: []const []const u8,
    stderr: *std.Io.Writer,
) !u8 {
    // Must be `concurrent`, not `async`: `Io.async` is permitted to run the
    // task inline to completion before returning, and the UI loop feeds the
    // session only afterwards, so an inline run would wait forever for a
    // prompt that has not been pushed yet.
    var runner = try io.concurrent(agent.AgentSession.run, .{session});
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
    try state.initCatalog(gpa);
    defer state.deinit(gpa);

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
            _ = updateTranscriptViewport(state, term.backBuffer());
            try handleKey(gpa, io, session, state, clock, key_event);
            if (state.quit_requested) break;
        }
        if (state.quit_requested) break;

        const tick = spinnerTick(state, clock.nowMs());
        draw(state, term.backBuffer(), model_label, thinking, tick);
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
        .run_started => {
            state.is_running = true;
            state.spinner_started_ms = null;
        },
        .run_finished => {
            state.is_running = false;
            state.spinner_started_ms = null;
        },
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
            toolStarted(state, started.tool_call_id, started.tool_name);
        },
        .tool_output => |output| {
            toolOutput(state, output.tool_call_id, output.bytes);
        },
        .tool_finished => |finished| {
            toolFinished(state, finished.tool_call_id, finished.is_error);
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
        .usage_updated => |snapshot| state.usage = snapshot,
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
        state.popup.hide();
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
        if (state.popup.visible) {
            state.popup.hide();
        } else if (state.is_running) {
            try session.inbox().push(io, .{ .cancel = .user });
        }
        return;
    }

    if (state.popup.visible) {
        if (key_event.key == .up or isCtrlCharacter(key_event, 'p')) {
            state.popup.previous();
            return;
        }
        if (key_event.key == .down or isCtrlCharacter(key_event, 'n')) {
            state.popup.next();
            return;
        }
        if (key_event.key == .tab or key_event.key == .enter) {
            acceptCompletion(io, state);
            return;
        }
    }

    if (key_event.key == .up and key_event.modifiers.alt) {
        try session.inbox().push(io, .dequeue_last);
        return;
    }

    if ((key_event.key == .enter and key_event.modifiers.ctrl) or isCtrlCharacter(key_event, 'q')) {
        try submitComposer(gpa, io, session, state, .follow_up);
        return;
    }

    switch (key_event.key) {
        .page_up => {
            const page: u32 = @max(state.transcript_viewport_height, 1);
            tuizr.transcriptScrollUp(&state.transcript, page);
            return;
        },
        .home => {
            tuizr.transcriptScrollUp(&state.transcript, std.math.maxInt(u32));
            return;
        },
        .end, .page_down => {
            tuizr.transcriptScrollToBottom(
                &state.transcript,
                state.transcript_width,
                state.transcript_viewport_height,
                transcript_theme,
            );
            return;
        },
        else => {},
    }

    if (key_event.key == .enter and !key_event.modifiers.shift) {
        try submitComposer(gpa, io, session, state, null);
        return;
    }

    if (key_event.key == .tab) {
        recomputeAutocomplete(io, state, true);
        return;
    }

    _ = tuizr.textInputHandleKey(&state.composer, key_event);
    recomputeAutocomplete(io, state, false);
}

const PromptRoute = enum {
    prompt,
    steer,
    follow_up,
};

fn isCtrlCharacter(key_event: tuizr.KeyEvent, expected: u21) bool {
    return key_event.modifiers.ctrl and
        (key_event.codepoint == expected or key_event.codepoint == expected - 'a' + 'A');
}

fn recomputeAutocomplete(io: std.Io, state: *State, force_file: bool) void {
    const before_cursor = state.composer.buffer[0..state.composer.cursor];
    const cwd: autocomplete.WorkingDirectory = .{
        .io = io,
        .home = defaultHomeDirectory(),
    };
    const completions = if (force_file)
        autocomplete.computeCompletionsForced(
            before_cursor,
            &slash.commands,
            state.model_ids,
            state.effort_names,
            cwd,
        )
    else
        autocomplete.computeCompletions(
            before_cursor,
            &slash.commands,
            state.model_ids,
            state.effort_names,
            cwd,
        );
    state.popup.set(completions);
}

fn acceptCompletion(io: std.Io, state: *State) void {
    const item = state.popup.selectedItem() orelse return;
    const span = state.popup.completions.replacement;
    if (span.start > span.end or span.end > state.composer.len) {
        state.popup.hide();
        return;
    }

    const append_space = item.kind == .command and item.consumes_args;
    const replacement_len = item.value().len + @intFromBool(append_space);
    const replaced_len = span.end - span.start;
    const new_len = state.composer.len - replaced_len + replacement_len;
    if (new_len > @min(state.composer.max_len, state.composer.buffer.len)) {
        state.popup.hide();
        return;
    }

    const suffix = state.composer.buffer[span.end..state.composer.len];
    if (replacement_len > replaced_len) {
        std.mem.copyBackwards(
            u8,
            state.composer.buffer[span.start + replacement_len .. new_len],
            suffix,
        );
    } else if (replacement_len < replaced_len) {
        std.mem.copyForwards(
            u8,
            state.composer.buffer[span.start + replacement_len .. new_len],
            suffix,
        );
    }
    @memcpy(
        state.composer.buffer[span.start .. span.start + item.value().len],
        item.value(),
    );
    if (append_space) state.composer.buffer[span.start + item.value().len] = ' ';
    state.composer.len = new_len;
    state.composer.cursor = span.start + replacement_len;
    state.composer.history_idx = null;
    state.composer.saved_len = 0;
    state.composer.submitted_len = 0;

    const continue_completion = append_space or (item.kind == .file and item.is_directory);
    state.popup.hide();
    if (continue_completion) recomputeAutocomplete(io, state, false);
}

fn submitComposer(
    gpa: Allocator,
    io: std.Io,
    session: *agent.AgentSession,
    state: *State,
    forced_route: ?PromptRoute,
) !void {
    const submit_key: tuizr.KeyEvent = .{ .key = .enter, .codepoint = 0 };
    const submitted = tuizr.textInputHandleKey(&state.composer, submit_key) orelse return;
    state.popup.hide();
    const trimmed = std.mem.trim(u8, submitted, " \t\r\n");
    if (trimmed.len == 0) return;

    if (forced_route) |route| {
        try pushAgentPrompt(gpa, io, session, route, trimmed);
        appendTranscriptBlock(state, .user, trimmed);
        return;
    }
    try dispatchSubmission(gpa, io, session, state, trimmed);
}

fn dispatchSubmission(
    gpa: Allocator,
    io: std.Io,
    session: *agent.AgentSession,
    state: *State,
    submitted: []const u8,
) !void {
    if (submitted[0] == '/') {
        try dispatchSlash(gpa, io, session, state, slash.parse(submitted));
        return;
    }
    if (std.mem.startsWith(u8, submitted, "!!")) {
        try dispatchShell(gpa, io, session, state, submitted[2..], true);
        return;
    }
    if (submitted[0] == '!') {
        try dispatchShell(gpa, io, session, state, submitted[1..], false);
        return;
    }
    if (std.mem.startsWith(u8, submitted, "->") or std.mem.startsWith(u8, submitted, "=>")) {
        const text = std.mem.trim(u8, submitted[2..], " \t\r\n");
        if (text.len != 0) {
            try pushAgentPrompt(gpa, io, session, .follow_up, text);
            appendTranscriptBlock(state, .user, text);
        }
        return;
    }
    if (std.mem.eql(u8, submitted, ".") or std.mem.eql(u8, submitted, "c")) {
        try pushAgentPrompt(gpa, io, session, .prompt, "continue");
        appendTranscriptBlock(state, .user, "continue");
        return;
    }

    const route: PromptRoute = if (state.is_running) .steer else .prompt;
    try pushAgentPrompt(gpa, io, session, route, submitted);
    appendTranscriptBlock(state, .user, submitted);
}

fn dispatchSlash(
    gpa: Allocator,
    io: std.Io,
    session: *agent.AgentSession,
    state: *State,
    parsed: slash.ParseResult,
) !void {
    const matched = switch (parsed) {
        .command => |value| value,
        .bare, .unknown => {
            appendNotice(state, "unknown command");
            return;
        },
        .not_command => return,
    };
    const name = matched.command.name;

    if (std.mem.eql(u8, name, "/help")) {
        appendCommandHelp(state);
    } else if (std.mem.eql(u8, name, "/model")) {
        if (matched.args.len == 0) {
            appendNotice(state, "model id required");
            return;
        }
        const registry = if (state.registry) |*value| value else {
            appendNotice(state, "unknown model");
            return;
        };
        const provider_name = findModelProvider(registry, matched.args) orelse {
            appendNotice(state, "unknown model");
            return;
        };
        var selection = try events.ModelSelection.init(gpa, provider_name, matched.args, null);
        defer selection.deinit(gpa);
        try session.inbox().push(io, .{ .change_model = selection });
    } else if (std.mem.eql(u8, name, "/thinking")) {
        const level = std.meta.stringToEnum(catalog.ThinkingLevel, matched.args) orelse {
            appendNotice(state, "invalid thinking level");
            return;
        };
        try session.inbox().push(io, .{ .change_thinking = level });
    } else if (std.mem.eql(u8, name, "/compact")) {
        try session.inbox().push(io, .{ .compact = null });
    } else if (std.mem.eql(u8, name, "/retry")) {
        try session.inbox().push(io, .retry);
    } else if (std.mem.eql(u8, name, "/clear")) {
        tuizr.transcriptClear(&state.transcript);
        state.current_kind = null;
        appendNotice(state, "on-screen view was cleared");
    } else if (std.mem.eql(u8, name, "/exit")) {
        state.quit_requested = true;
    } else if (std.mem.eql(u8, name, "/login")) {
        appendNotice(state, "OAuth login lands next");
    }
}

fn findModelProvider(registry: *const model_catalog.Registry, model_id: []const u8) ?[]const u8 {
    var provider_iterator = registry.providers.iterator();
    while (provider_iterator.next()) |provider_entry| {
        if (provider_entry.value_ptr.get(model_id) != null) return provider_entry.key_ptr.*;
    }
    return null;
}

fn dispatchShell(
    gpa: Allocator,
    io: std.Io,
    session: *agent.AgentSession,
    state: *State,
    raw_command: []const u8,
    send_to_model: bool,
) !void {
    const command = std.mem.trim(u8, raw_command, " \t\r\n");
    if (command.len == 0) {
        appendNotice(state, "shell command required");
        return;
    }

    const output = try runShellCommand(gpa, io, command);
    defer gpa.free(output);
    const message = try std.fmt.allocPrint(gpa, "$ {s}\n{s}", .{ command, output });
    defer gpa.free(message);
    appendTranscriptBlock(state, .tool, message);
    if (send_to_model) {
        const route: PromptRoute = if (state.is_running) .steer else .prompt;
        try pushAgentPrompt(gpa, io, session, route, message);
    }
}

fn runShellCommand(gpa: Allocator, io: std.Io, command: []const u8) ![]u8 {
    const timeout: std.Io.Timeout = .{ .deadline = .fromNow(io, .{
        .raw = .fromSeconds(shell_timeout_seconds),
        .clock = .awake,
    }) };
    const result = std.process.run(gpa, io, .{
        .argv = &.{ defaultShell(), "-c", command },
        .stdout_limit = .limited(max_shell_output_bytes / 2),
        .stderr_limit = .limited(max_shell_output_bytes / 2),
        .reserve_amount = 4096,
        .timeout = timeout,
    }) catch |err| switch (err) {
        error.Timeout => return std.fmt.allocPrint(
            gpa,
            "Command timed out after {d} seconds",
            .{shell_timeout_seconds},
        ),
        error.StreamTooLong => return std.fmt.allocPrint(
            gpa,
            "Command output exceeded {d} bytes",
            .{max_shell_output_bytes},
        ),
        else => return std.fmt.allocPrint(gpa, "Command failed: {s}", .{@errorName(err)}),
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    try output.appendSlice(gpa, result.stdout);
    if (result.stderr.len != 0) {
        if (output.items.len != 0 and output.items[output.items.len - 1] != '\n') {
            try output.append(gpa, '\n');
        }
        try output.appendSlice(gpa, result.stderr);
    }
    if (output.items.len == 0) try output.appendSlice(gpa, "(no output)");

    var status_buffer: [128]u8 = undefined;
    const status: ?[]const u8 = switch (result.term) {
        .exited => |code| if (code == 0)
            null
        else
            try std.fmt.bufPrint(&status_buffer, "\n\nCommand exited with code {d}", .{code}),
        .signal => |signal| try std.fmt.bufPrint(
            &status_buffer,
            "\n\nCommand terminated by signal {d}",
            .{signal},
        ),
        .stopped => |signal| try std.fmt.bufPrint(
            &status_buffer,
            "\n\nCommand stopped by signal {d}",
            .{signal},
        ),
        .unknown => |value| try std.fmt.bufPrint(
            &status_buffer,
            "\n\nCommand ended with status {d}",
            .{value},
        ),
    };
    if (status) |text| try output.appendSlice(gpa, text);
    return output.toOwnedSlice(gpa);
}

fn defaultShell() []const u8 {
    if (comptime builtin.link_libc and builtin.os.tag != .windows) {
        if (std.c.getenv("SHELL")) |value| {
            const shell = std.mem.span(value);
            if (shell.len != 0) return shell;
        }
    }
    return if (builtin.os.tag == .windows) "cmd.exe" else "/bin/sh";
}

fn defaultHomeDirectory() ?[]const u8 {
    if (comptime builtin.link_libc) {
        const name = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
        if (std.c.getenv(name)) |value| {
            const home = std.mem.span(value);
            if (home.len != 0) return home;
        }
    }
    return null;
}

fn appendCommandHelp(state: *State) void {
    tuizr.transcriptStartBlock(&state.transcript, .notice);
    for (slash.commands, 0..) |command, index| {
        if (index != 0) tuizr.transcriptAppend(&state.transcript, "\n");
        tuizr.transcriptAppend(&state.transcript, command.name);
        if (std.mem.eql(u8, command.name, "/exit")) {
            tuizr.transcriptAppend(&state.transcript, " (/quit)");
        }
        tuizr.transcriptAppend(&state.transcript, " — ");
        tuizr.transcriptAppend(&state.transcript, command.summary);
    }
    tuizr.transcriptFinalize(&state.transcript);
    state.current_kind = null;
}

fn appendNotice(state: *State, text: []const u8) void {
    appendTranscriptBlock(state, .notice, text);
}

fn appendTranscriptBlock(state: *State, kind: tuizr.BlockKind, text: []const u8) void {
    tuizr.transcriptStartBlock(&state.transcript, kind);
    tuizr.transcriptAppend(&state.transcript, text);
    tuizr.transcriptFinalize(&state.transcript);
    state.current_kind = null;
}

fn pushAgentPrompt(
    gpa: Allocator,
    io: std.Io,
    session: *agent.AgentSession,
    route: PromptRoute,
    text: []const u8,
) !void {
    var prompt = try events.OwnedPrompt.init(gpa, text, &.{}, false, .user);
    defer prompt.deinit(gpa);
    switch (route) {
        .prompt => try session.inbox().push(io, .{ .prompt = prompt }),
        .steer => try session.inbox().push(io, .{ .steer = prompt }),
        .follow_up => try session.inbox().push(io, .{ .follow_up = prompt }),
    }
}

fn pushPrompt(
    gpa: Allocator,
    io: std.Io,
    session: *agent.AgentSession,
    text: []const u8,
) !void {
    try pushAgentPrompt(gpa, io, session, .prompt, text);
}

fn clearComposer(composer: *tuizr.TextInput) void {
    composer.len = 0;
    composer.cursor = 0;
    composer.scroll_x = 0;
    composer.history_idx = null;
    composer.saved_len = 0;
    composer.submitted_len = 0;
}

const Layout = struct {
    transcript_height: u16 = 0,
    composer_y: u16 = 0,
    composer_height: u16 = 0,
    status_y: u16 = 0,
};

fn calculateLayout(state: *const State, width: u16, height: u16) Layout {
    if (height == 0) return .{};

    const status_y = height - 1;
    if (height == 1) return .{ .status_y = status_y };

    const composer_limit = @min(max_composer_height, height / 2);
    const composer_height = @min(
        @max(tuizr.textInputLineCount(&state.composer, width), 1),
        composer_limit,
    );
    const transcript_height = height - composer_height - 1;
    return .{
        .transcript_height = transcript_height,
        .composer_y = transcript_height,
        .composer_height = composer_height,
        .status_y = status_y,
    };
}

fn updateTranscriptViewport(state: *State, grid: *const tuizr.CellGrid) Layout {
    const layout = calculateLayout(state, grid.width(), grid.height());
    state.transcript_width = grid.width();
    state.transcript_viewport_height = layout.transcript_height;
    return layout;
}

fn spinnerTick(state: *State, now_ms: i64) usize {
    if (!state.is_running) {
        state.spinner_started_ms = null;
        return 0;
    }

    const started_ms = state.spinner_started_ms orelse {
        state.spinner_started_ms = now_ms;
        return 0;
    };
    const elapsed_ms = if (now_ms > started_ms) now_ms - started_ms else 0;
    return @intCast(@divTrunc(elapsed_ms, spinner_frame_ms));
}

fn formatStatusLeft(buffer: []u8, state: *const State) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    writer.writeAll(if (state.is_running) "  working" else "ready") catch
        return writer.buffered();

    const snapshot = state.usage orelse return writer.buffered();
    const usage = snapshot.usage;
    if (usage.input != 0) {
        writer.print(" ↑{d}", .{usage.input}) catch return writer.buffered();
    }
    if (usage.output != 0) {
        writer.print(" ↓{d}", .{usage.output}) catch return writer.buffered();
    }
    if (usage.cache_read != 0) {
        writer.print(" R{d}", .{usage.cache_read}) catch return writer.buffered();
    }
    if (usage.cache_write != 0) {
        writer.print(" W{d}", .{usage.cache_write}) catch return writer.buffered();
    }
    if (usage.cost.total != 0) {
        writer.print(" ${d:.4}", .{usage.cost.total}) catch return writer.buffered();
    }
    if (snapshot.context_percent) |percent| {
        writer.print(" {d:.0}%", .{percent}) catch return writer.buffered();
    }
    return writer.buffered();
}

fn draw(
    state: *State,
    grid: *tuizr.CellGrid,
    model_label: []const u8,
    thinking: catalog.ThinkingLevel,
    spinner_tick: usize,
) void {
    grid.fill(tuizr.default_cell);
    const width = grid.width();
    const height = grid.height();
    if (height == 0) return;
    const layout = updateTranscriptViewport(state, grid);

    if (layout.transcript_height != 0) {
        tuizr.drawTranscript(
            grid,
            .{ .x = 0, .y = 0, .w = width, .h = layout.transcript_height },
            &state.transcript,
            transcript_theme,
        );
    }

    if (layout.composer_height != 0) {
        tuizr.drawTextInput(
            grid,
            .{
                .x = 0,
                .y = layout.composer_y,
                .w = width,
                .h = layout.composer_height,
            },
            &state.composer,
            composer_style,
            true,
        );
    }

    if (state.popup.visible and layout.composer_y != 0 and width != 0) {
        const popup_height: u16 = @intCast(@min(
            state.popup.completions.count,
            @as(usize, layout.composer_y),
        ));
        if (popup_height != 0) {
            tuizr.drawPopupList(
                grid,
                .{
                    .x = 0,
                    .y = layout.composer_y - popup_height,
                    .w = width,
                    .h = popup_height,
                },
                state.popup.item_views[0..state.popup.completions.count],
                state.popup.selected,
                .{},
            );
        }
    }

    var left_buffer: [256]u8 = undefined;
    const left = formatStatusLeft(&left_buffer, state);
    var right_buffer: [512]u8 = undefined;
    const right = std.fmt.bufPrint(
        &right_buffer,
        "{s} • {s}",
        .{ model_label, @tagName(thinking) },
    ) catch @tagName(thinking);
    tuizr.drawStatusBar(
        grid,
        .{ .x = 0, .y = layout.status_y, .w = width, .h = 1 },
        left,
        right,
        status_style,
    );
    if (state.is_running and width != 0) {
        tuizr.drawSpinner(grid, 0, layout.status_y, spinner_tick, status_style);
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

fn insertComposerText(composer: *tuizr.TextInput, text: []const u8) void {
    for (text) |byte| _ = tuizr.textInputHandleKey(composer, keyCharacter(byte));
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
        .{ .text_delta = try events.TextDelta.init(allocator, "a1", "Hi") },
        .{ .message_finished = try events.MessageFinished.init(
            allocator,
            "a1",
            .stop,
            &.{"Hi"},
            null,
        ) },
        .{ .run_finished = .{ .status = .completed, .turns = 1 } },
        .{ .usage_updated = .{
            .usage = .{
                .input = 120,
                .output = 34,
                .cache_read = 5,
                .cost = .{ .total = 0.012345 },
            },
            .context_window = 200_000,
            .context_percent = 42.6,
        } },
    };
    defer for (&script) |*event| event.deinit(allocator);
    for (script) |event| applyEvent(state, event);
}

fn applyToolStartedForTest(
    allocator: Allocator,
    state: *State,
    tool_call_id: []const u8,
    tool_name: []const u8,
) !void {
    var started = try events.ToolStarted.init(allocator, tool_call_id, tool_name, "{}");
    defer started.deinit(allocator);
    applyEvent(state, .{ .tool_started = started });
}

fn applyToolOutputForTest(
    allocator: Allocator,
    state: *State,
    tool_call_id: []const u8,
    bytes: []const u8,
) !void {
    var output = try events.ToolOutputDelta.init(allocator, tool_call_id, bytes);
    defer output.deinit(allocator);
    applyEvent(state, .{ .tool_output = output });
}

fn applyToolFinishedForTest(
    allocator: Allocator,
    state: *State,
    tool_call_id: []const u8,
    tool_name: []const u8,
    is_error: bool,
) !void {
    var finished = try events.ToolFinished.init(
        allocator,
        tool_call_id,
        tool_name,
        is_error,
        null,
    );
    defer finished.deinit(allocator);
    applyEvent(state, .{ .tool_finished = finished });
}

fn applyToolScript(allocator: Allocator, state: *State) !void {
    try applyToolStartedForTest(allocator, state, "t1", "read");
    try applyToolOutputForTest(allocator, state, "t1", "contents");
    try applyToolFinishedForTest(allocator, state, "t1", "read", false);
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

test "composed assistant frame shows usage model and thinking in the status bar" {
    var state = State.init();
    try applyComposedFrameScript(std.testing.allocator, &state);
    for ("draft") |byte| {
        _ = tuizr.textInputHandleKey(&state.composer, keyCharacter(byte));
    }
    var grid = try tuizr.CellGrid.init(std.testing.allocator, 48, 6);
    defer grid.deinit();

    draw(&state, &grid, "test-model", .high, 0);
    const projection = try gridProjectionAlloc(std.testing.allocator, &grid);
    defer std.testing.allocator.free(projection);
    try std.testing.expectEqualStrings(
        "Hi\n\n\n\ndraft\n" ++
            "ready ↑120 ↓34 R5 $0.0123 43%  test-model • high\n",
        projection,
    );

    const assistant = grid.getCell(0, 0) orelse return error.TestUnexpectedResult;
    const composer = grid.getCell(0, 4) orelse return error.TestUnexpectedResult;
    const composer_cursor = grid.getCell(5, 4) orelse return error.TestUnexpectedResult;
    const status = grid.getCell(0, 5) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(transcript_theme.markdown.text.attrs, assistant.attrs);
    try expectCellColors(transcript_theme.markdown.text, assistant);
    try std.testing.expectEqual(composer_style.attrs, composer.attrs);
    try expectCellColors(composer_style, composer);
    try std.testing.expectEqual(composer_style.attrs | tuizr.Attr.reverse, composer_cursor.attrs);
    try expectCellColors(composer_style, composer_cursor);
    try std.testing.expectEqual(status_style.attrs, status.attrs);
    try expectCellColors(status_style, status);
    try std.testing.expect(state.composer.multiline);
    try std.testing.expectEqual(@as(u16, 1), tuizr.textInputLineCount(&state.composer, grid.width()));
    try std.testing.expectEqual(@as(u16, 4), state.transcript_viewport_height);
    try std.testing.expect(!state.is_running);
    try std.testing.expectEqual(@as(u64, 120), state.usage.?.usage.input);
    try std.testing.expectEqual(@as(?f64, 42.6), state.usage.?.context_percent);
}

test "newline keys expand the composer without submitting" {
    const fixture = try TestSession.create(std.testing.allocator, std.testing.io);
    defer fixture.deinit();
    var state = State.init();
    var now_ms: i64 = 0;
    const clock: Clock = .{ .fixed_ms = &now_ms };

    tuizr.transcriptStartBlock(&state.transcript, .notice);
    tuizr.transcriptAppend(&state.transcript, "above");
    tuizr.transcriptFinalize(&state.transcript);
    for ("one") |byte| {
        _ = tuizr.textInputHandleKey(&state.composer, keyCharacter(byte));
    }
    try handleKey(
        std.testing.allocator,
        std.testing.io,
        &fixture.session,
        &state,
        clock,
        .{ .key = .enter, .codepoint = 0, .modifiers = .{ .shift = true } },
    );
    for ("two") |byte| {
        _ = tuizr.textInputHandleKey(&state.composer, keyCharacter(byte));
    }

    try std.testing.expectEqualStrings("one\ntwo", state.composer.buffer[0..state.composer.len]);
    try std.testing.expectEqual(@as(u16, 2), tuizr.textInputLineCount(&state.composer, 20));
    try std.testing.expect(fixture.session.inbox().tryPop(std.testing.io) == null);

    var grid = try tuizr.CellGrid.init(std.testing.allocator, 20, 6);
    defer grid.deinit();
    draw(&state, &grid, "model", .low, 0);
    const projection = try gridProjectionAlloc(std.testing.allocator, &grid);
    defer std.testing.allocator.free(projection);
    try std.testing.expectEqualStrings(
        "above\n\n\none\ntwo\n" ++
            "ready    model • low\n",
        projection,
    );
    try std.testing.expectEqual(@as(u16, 3), state.transcript_viewport_height);
    try expectCellColors(composer_style, grid.getCell(0, 3) orelse return error.TestUnexpectedResult);
    try expectCellColors(composer_style, grid.getCell(0, 4) orelse return error.TestUnexpectedResult);

    var ctrl_j_state = State.init();
    _ = tuizr.textInputHandleKey(&ctrl_j_state.composer, keyCharacter('a'));
    try handleKey(
        std.testing.allocator,
        std.testing.io,
        &fixture.session,
        &ctrl_j_state,
        clock,
        .{
            .key = .character,
            .codepoint = 'j',
            .modifiers = .{ .ctrl = true },
        },
    );
    _ = tuizr.textInputHandleKey(&ctrl_j_state.composer, keyCharacter('b'));
    try std.testing.expectEqualStrings(
        "a\nb",
        ctrl_j_state.composer.buffer[0..ctrl_j_state.composer.len],
    );
    try std.testing.expect(fixture.session.inbox().tryPop(std.testing.io) == null);
}

test "running status draws an injected spinner frame" {
    var state = State.init();
    state.is_running = true;
    var grid = try tuizr.CellGrid.init(std.testing.allocator, 32, 2);
    defer grid.deinit();

    draw(&state, &grid, "test-model", .high, 3);
    const projection = try gridProjectionAlloc(std.testing.allocator, &grid);
    defer std.testing.allocator.free(projection);
    try std.testing.expectEqualStrings(
        "\n⠸ working      test-model • high\n",
        projection,
    );

    const spinner = grid.getCell(0, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(tuizr.spinnerFrame(3), spinner.codepoint);
    try expectCellColors(status_style, spinner);
}

test "spinner tick advances every 80 elapsed milliseconds only while running" {
    var state = State.init();
    state.is_running = true;

    try std.testing.expectEqual(@as(usize, 0), spinnerTick(&state, 1_000));
    try std.testing.expectEqual(@as(usize, 0), spinnerTick(&state, 1_079));
    try std.testing.expectEqual(@as(usize, 1), spinnerTick(&state, 1_080));
    try std.testing.expectEqual(@as(usize, 10), spinnerTick(&state, 1_800));

    state.is_running = false;
    try std.testing.expectEqual(@as(usize, 0), spinnerTick(&state, 2_000));
    try std.testing.expectEqual(@as(?i64, null), state.spinner_started_ms);
}

test "tool events render one finalized transcript block with header output and status" {
    var state = State.init();
    try applyToolScript(std.testing.allocator, &state);
    var grid = try tuizr.CellGrid.init(std.testing.allocator, 20, 6);
    defer grid.deinit();

    draw(&state, &grid, "model", .low, 0);
    const projection = try gridProjectionAlloc(std.testing.allocator, &grid);
    defer std.testing.allocator.free(projection);
    try std.testing.expectEqualStrings(
        "→ read\ncontents\ndone\n\n\n" ++
            "ready    model • low\n",
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

test "interleaved tool output is attributed to sequential transcript blocks" {
    var state = State.init();
    try applyToolStartedForTest(std.testing.allocator, &state, "a", "A");
    try applyToolStartedForTest(std.testing.allocator, &state, "b", "B");
    try applyToolOutputForTest(std.testing.allocator, &state, "a", "aaa");
    try applyToolOutputForTest(std.testing.allocator, &state, "b", "bbb");
    try applyToolOutputForTest(std.testing.allocator, &state, "a", "aaa2");
    try applyToolFinishedForTest(std.testing.allocator, &state, "a", "A", false);
    try applyToolFinishedForTest(std.testing.allocator, &state, "b", "B", false);

    try std.testing.expectEqual(@as(usize, 2), state.transcript.block_count);
    try std.testing.expectEqualStrings(
        "→ A\naaaaaa2\ndone",
        transcriptBlockContent(&state.transcript, 0),
    );
    try std.testing.expectEqualStrings(
        "→ B\nbbb\ndone",
        transcriptBlockContent(&state.transcript, 1),
    );
    try std.testing.expect(state.transcript.blocks[0].finalized);
    try std.testing.expect(state.transcript.blocks[1].finalized);
    try std.testing.expectEqual(@as(usize, 0), state.tool_count);
    try std.testing.expectEqual(@as(?tuizr.BlockKind, null), state.current_kind);
}

test "pending tool finished before promotion renders and finalizes on promotion" {
    var state = State.init();
    try applyToolStartedForTest(std.testing.allocator, &state, "a", "A");
    try applyToolStartedForTest(std.testing.allocator, &state, "b", "B");
    try applyToolOutputForTest(std.testing.allocator, &state, "a", "front");
    try applyToolOutputForTest(std.testing.allocator, &state, "b", "buffered");
    try applyToolFinishedForTest(std.testing.allocator, &state, "b", "B", true);

    try std.testing.expectEqual(@as(usize, 1), state.transcript.block_count);
    try std.testing.expectEqualStrings(
        "→ A\nfront",
        transcriptBlockContent(&state.transcript, 0),
    );
    try std.testing.expectEqual(@as(usize, 2), state.tool_count);

    try applyToolFinishedForTest(std.testing.allocator, &state, "a", "A", false);

    try std.testing.expectEqual(@as(usize, 2), state.transcript.block_count);
    try std.testing.expectEqualStrings(
        "→ A\nfront\ndone",
        transcriptBlockContent(&state.transcript, 0),
    );
    try std.testing.expectEqualStrings(
        "→ B\nbuffered\nerror",
        transcriptBlockContent(&state.transcript, 1),
    );
    try std.testing.expect(state.transcript.blocks[1].finalized);
    try std.testing.expectEqual(@as(usize, 0), state.tool_count);
    try std.testing.expectEqual(@as(?usize, null), state.transcript.active_index);
    try std.testing.expectEqual(@as(?tuizr.BlockKind, null), state.current_kind);
}

test "single tool output streams live before finalization" {
    var state = State.init();
    try applyToolStartedForTest(std.testing.allocator, &state, "single", "read");
    try applyToolOutputForTest(std.testing.allocator, &state, "single", "contents");

    try std.testing.expectEqual(@as(usize, 1), state.transcript.block_count);
    try std.testing.expectEqualStrings(
        "→ read\ncontents",
        transcriptBlockContent(&state.transcript, 0),
    );
    try std.testing.expect(!state.transcript.blocks[0].finalized);
    try std.testing.expectEqual(@as(?usize, 0), state.transcript.active_index);
    try std.testing.expectEqual(@as(?tuizr.BlockKind, .tool), state.current_kind);

    try applyToolFinishedForTest(std.testing.allocator, &state, "single", "read", false);

    try std.testing.expectEqualStrings(
        "→ read\ncontents\ndone",
        transcriptBlockContent(&state.transcript, 0),
    );
    try std.testing.expect(state.transcript.blocks[0].finalized);
    try std.testing.expectEqual(@as(usize, 0), state.tool_count);
    try std.testing.expectEqual(@as(?tuizr.BlockKind, null), state.current_kind);
}

test "pending tool output buffer truncates with a marker" {
    var state = State.init();
    try applyToolStartedForTest(std.testing.allocator, &state, "foreground", "A");
    try applyToolStartedForTest(std.testing.allocator, &state, "buffered", "B");

    var oversized: [max_buffered_tool_output_bytes + 64]u8 = undefined;
    @memset(&oversized, 'x');
    try applyToolOutputForTest(std.testing.allocator, &state, "buffered", &oversized);
    try applyToolFinishedForTest(std.testing.allocator, &state, "foreground", "A", false);
    try applyToolFinishedForTest(std.testing.allocator, &state, "buffered", "B", false);

    try std.testing.expectEqual(@as(usize, 2), state.transcript.block_count);
    const content = transcriptBlockContent(&state.transcript, 1);
    const header = "→ B\n";
    try std.testing.expect(std.mem.startsWith(u8, content, header));
    const buffered_end = header.len + max_buffered_tool_output_bytes;
    const buffered = content[header.len..buffered_end];
    try std.testing.expectEqual(
        @as(usize, max_buffered_tool_output_bytes),
        buffered.len,
    );
    try std.testing.expect(std.mem.allEqual(
        u8,
        buffered[0 .. buffered.len - buffered_tool_output_truncation_marker.len],
        'x',
    ));
    try std.testing.expect(std.mem.endsWith(
        u8,
        buffered,
        buffered_tool_output_truncation_marker,
    ));
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, buffered, buffered_tool_output_truncation_marker),
    );
    try std.testing.expectEqualStrings("\ndone", content[buffered_end..]);
    try std.testing.expect(state.transcript.blocks[1].finalized);
    try std.testing.expectEqual(@as(usize, 0), state.tool_count);
}

test "tool tracking capacity overflow appends best effort to foreground" {
    var state = State.init();
    var index: usize = 0;
    while (index < max_in_flight_tools + 1) : (index += 1) {
        var id_buffer: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "tool-{d}", .{index});
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "Tool-{d}", .{index});
        try applyToolStartedForTest(std.testing.allocator, &state, id, name);
    }

    try applyToolOutputForTest(std.testing.allocator, &state, "tool-8", "overflow-output");
    try applyToolFinishedForTest(std.testing.allocator, &state, "tool-8", "Tool-8", false);

    try std.testing.expectEqual(@as(usize, max_in_flight_tools), state.tool_count);
    try std.testing.expectEqual(@as(usize, 1), state.transcript.block_count);
    const content = transcriptBlockContent(&state.transcript, 0);
    try std.testing.expect(std.mem.indexOf(u8, content, "→ Tool-8\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "overflow-output") != null);
    try std.testing.expect(!state.transcript.blocks[0].finalized);
    try std.testing.expectEqual(@as(?tuizr.BlockKind, .tool), state.current_kind);
}

test "transcript scroll keys preserve the composer and restore follow-bottom" {
    const fixture = try TestSession.create(std.testing.allocator, std.testing.io);
    defer fixture.deinit();
    var state = State.init();
    var now_ms: i64 = 0;
    const clock: Clock = .{ .fixed_ms = &now_ms };

    tuizr.transcriptStartBlock(&state.transcript, .notice);
    tuizr.transcriptAppend(
        &state.transcript,
        "line 01\nline 02\nline 03\nline 04\nline 05\nline 06\n" ++
            "line 07\nline 08\nline 09\nline 10\nline 11\nline 12",
    );
    tuizr.transcriptFinalize(&state.transcript);
    try handleKey(
        std.testing.allocator,
        std.testing.io,
        &fixture.session,
        &state,
        clock,
        keyCharacter('x'),
    );

    var grid = try tuizr.CellGrid.init(std.testing.allocator, 20, 6);
    defer grid.deinit();
    draw(&state, &grid, "model", .low, 0);
    const bottom = tuizr.transcriptLineCount(
        &state.transcript,
        state.transcript_width,
        transcript_theme,
    ) -| @as(u32, state.transcript_viewport_height);
    try std.testing.expect(bottom > 0);
    try std.testing.expectEqual(bottom, state.transcript.scroll_offset);
    try std.testing.expect(state.transcript.auto_scroll);

    try handleKey(
        std.testing.allocator,
        std.testing.io,
        &fixture.session,
        &state,
        clock,
        keyNamed(.page_up),
    );
    try std.testing.expect(!state.transcript.auto_scroll);
    try std.testing.expect(state.transcript.scroll_offset < bottom);

    try handleKey(
        std.testing.allocator,
        std.testing.io,
        &fixture.session,
        &state,
        clock,
        keyNamed(.home),
    );
    try std.testing.expectEqual(@as(u32, 0), state.transcript.scroll_offset);

    try handleKey(
        std.testing.allocator,
        std.testing.io,
        &fixture.session,
        &state,
        clock,
        keyNamed(.end),
    );
    try std.testing.expect(state.transcript.auto_scroll);
    try std.testing.expectEqual(bottom, state.transcript.scroll_offset);

    try handleKey(
        std.testing.allocator,
        std.testing.io,
        &fixture.session,
        &state,
        clock,
        keyNamed(.page_up),
    );
    try handleKey(
        std.testing.allocator,
        std.testing.io,
        &fixture.session,
        &state,
        clock,
        keyNamed(.page_down),
    );
    try std.testing.expect(state.transcript.auto_scroll);
    try std.testing.expectEqual(bottom, state.transcript.scroll_offset);
    try std.testing.expectEqual(@as(usize, 1), state.composer.len);
    try std.testing.expectEqual(@as(usize, 1), state.composer.cursor);
    try std.testing.expect(fixture.session.inbox().tryPop(std.testing.io) == null);
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

test "typing and accepting a slash completion preserves the completed composer" {
    const fixture = try TestSession.create(std.testing.allocator, std.testing.io);
    defer fixture.deinit();
    var state = State.init();
    var now_ms: i64 = 0;
    const clock: Clock = .{ .fixed_ms = &now_ms };

    for ("/mo") |byte| {
        try handleKey(
            std.testing.allocator,
            std.testing.io,
            &fixture.session,
            &state,
            clock,
            keyCharacter(byte),
        );
    }

    try std.testing.expect(state.popup.visible);
    const selected = state.popup.selectedItem() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/model", selected.value());

    try handleKey(
        std.testing.allocator,
        std.testing.io,
        &fixture.session,
        &state,
        clock,
        keyNamed(.enter),
    );
    try std.testing.expectEqualStrings("/model ", state.composer.buffer[0..state.composer.len]);
    try std.testing.expectEqual(@as(usize, 7), state.composer.cursor);
    try std.testing.expect(fixture.session.inbox().tryPop(std.testing.io) == null);
}

test "Escape closes autocomplete before it can cancel a running turn" {
    const fixture = try TestSession.create(std.testing.allocator, std.testing.io);
    defer fixture.deinit();
    var state = State.init();
    var now_ms: i64 = 0;
    const clock: Clock = .{ .fixed_ms = &now_ms };

    state.is_running = true;
    for ("/mo") |byte| {
        try handleKey(
            std.testing.allocator,
            std.testing.io,
            &fixture.session,
            &state,
            clock,
            keyCharacter(byte),
        );
    }
    try std.testing.expect(state.popup.visible);

    try handleKey(
        std.testing.allocator,
        std.testing.io,
        &fixture.session,
        &state,
        clock,
        keyNamed(.escape),
    );
    try std.testing.expect(!state.popup.visible);
    try std.testing.expectEqualStrings("/mo", state.composer.buffer[0..state.composer.len]);
    try std.testing.expect(fixture.session.inbox().tryPop(std.testing.io) == null);

    var idle_state = State.init();
    insertComposerText(&idle_state.composer, "draft");
    try handleKey(
        std.testing.allocator,
        std.testing.io,
        &fixture.session,
        &idle_state,
        clock,
        keyNamed(.escape),
    );
    try std.testing.expectEqualStrings("draft", idle_state.composer.buffer[0..idle_state.composer.len]);
    try std.testing.expect(fixture.session.inbox().tryPop(std.testing.io) == null);
}

test "streaming Enter Ctrl Enter Ctrl Q and Alt Up route to distinct commands" {
    const fixture = try TestSession.create(std.testing.allocator, std.testing.io);
    defer fixture.deinit();
    var now_ms: i64 = 0;
    const clock: Clock = .{ .fixed_ms = &now_ms };

    var streaming = State.init();
    streaming.is_running = true;
    insertComposerText(&streaming.composer, "fix now");
    try handleKey(
        std.testing.allocator,
        std.testing.io,
        &fixture.session,
        &streaming,
        clock,
        keyNamed(.enter),
    );
    var steer = fixture.session.inbox().tryPop(std.testing.io) orelse
        return error.TestUnexpectedResult;
    defer steer.deinit(std.testing.allocator);
    try std.testing.expect(steer == .steer);
    try std.testing.expectEqualStrings("fix now", steer.steer.text);

    var ctrl_enter_state = State.init();
    insertComposerText(&ctrl_enter_state.composer, "after this");
    try handleKey(
        std.testing.allocator,
        std.testing.io,
        &fixture.session,
        &ctrl_enter_state,
        clock,
        .{ .key = .enter, .codepoint = 0, .modifiers = .{ .ctrl = true } },
    );
    var follow_up = fixture.session.inbox().tryPop(std.testing.io) orelse
        return error.TestUnexpectedResult;
    defer follow_up.deinit(std.testing.allocator);
    try std.testing.expect(follow_up == .follow_up);
    try std.testing.expectEqualStrings("after this", follow_up.follow_up.text);

    var ctrl_q_state = State.init();
    insertComposerText(&ctrl_q_state.composer, "also later");
    try handleKey(
        std.testing.allocator,
        std.testing.io,
        &fixture.session,
        &ctrl_q_state,
        clock,
        .{ .key = .character, .codepoint = 'q', .modifiers = .{ .ctrl = true } },
    );
    var ctrl_q = fixture.session.inbox().tryPop(std.testing.io) orelse
        return error.TestUnexpectedResult;
    defer ctrl_q.deinit(std.testing.allocator);
    try std.testing.expect(ctrl_q == .follow_up);
    try std.testing.expectEqualStrings("also later", ctrl_q.follow_up.text);

    var dequeue_state = State.init();
    try handleKey(
        std.testing.allocator,
        std.testing.io,
        &fixture.session,
        &dequeue_state,
        clock,
        .{ .key = .up, .codepoint = 0, .modifiers = .{ .alt = true } },
    );
    var dequeue = fixture.session.inbox().tryPop(std.testing.io) orelse
        return error.TestUnexpectedResult;
    defer dequeue.deinit(std.testing.allocator);
    try std.testing.expect(dequeue == .dequeue_last);
}

test "slash queue and continue submissions dispatch their classified commands" {
    const fixture = try TestSession.create(std.testing.allocator, std.testing.io);
    defer fixture.deinit();
    var now_ms: i64 = 0;
    const clock: Clock = .{ .fixed_ms = &now_ms };

    var thinking_state = State.init();
    insertComposerText(&thinking_state.composer, "/thinking max");
    try handleKey(
        std.testing.allocator,
        std.testing.io,
        &fixture.session,
        &thinking_state,
        clock,
        keyNamed(.enter),
    );
    var thinking = fixture.session.inbox().tryPop(std.testing.io) orelse
        return error.TestUnexpectedResult;
    defer thinking.deinit(std.testing.allocator);
    try std.testing.expect(thinking == .change_thinking);
    try std.testing.expect(thinking.change_thinking == .max);

    var queue_state = State.init();
    insertComposerText(&queue_state.composer, "->fix it");
    try handleKey(
        std.testing.allocator,
        std.testing.io,
        &fixture.session,
        &queue_state,
        clock,
        keyNamed(.enter),
    );
    var queued = fixture.session.inbox().tryPop(std.testing.io) orelse
        return error.TestUnexpectedResult;
    defer queued.deinit(std.testing.allocator);
    try std.testing.expect(queued == .follow_up);
    try std.testing.expectEqualStrings("fix it", queued.follow_up.text);

    var continue_state = State.init();
    insertComposerText(&continue_state.composer, ".");
    try handleKey(
        std.testing.allocator,
        std.testing.io,
        &fixture.session,
        &continue_state,
        clock,
        keyNamed(.enter),
    );
    var continued = fixture.session.inbox().tryPop(std.testing.io) orelse
        return error.TestUnexpectedResult;
    defer continued.deinit(std.testing.allocator);
    try std.testing.expect(continued == .prompt);
    try std.testing.expectEqualStrings("continue", continued.prompt.text);

    var unknown_state = State.init();
    insertComposerText(&unknown_state.composer, "/nope");
    try handleKey(
        std.testing.allocator,
        std.testing.io,
        &fixture.session,
        &unknown_state,
        clock,
        keyNamed(.enter),
    );
    try std.testing.expect(fixture.session.inbox().tryPop(std.testing.io) == null);
    try std.testing.expectEqual(@as(usize, 1), unknown_state.transcript.block_count);
    try std.testing.expectEqual(tuizr.BlockKind.notice, unknown_state.transcript.blocks[0].kind);
    try std.testing.expectEqualStrings(
        "unknown command",
        transcriptBlockContent(&unknown_state.transcript, 0),
    );
}

test "model command resolves a provider from the startup catalog" {
    const fixture = try TestSession.create(std.testing.allocator, std.testing.io);
    defer fixture.deinit();
    var state = State.init();
    try state.initCatalog(std.testing.allocator);
    defer state.deinit(std.testing.allocator);

    try dispatchSubmission(
        std.testing.allocator,
        std.testing.io,
        &fixture.session,
        &state,
        "/model gpt-5.2",
    );
    var command = fixture.session.inbox().tryPop(std.testing.io) orelse
        return error.TestUnexpectedResult;
    defer command.deinit(std.testing.allocator);
    try std.testing.expect(command == .change_model);
    try std.testing.expectEqualStrings("gpt-5.2", command.change_model.model);
    try std.testing.expect(command.change_model.provider.len != 0);
}

test "shell sigils separate local output from model-visible output" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const fixture = try TestSession.create(std.testing.allocator, std.testing.io);
    defer fixture.deinit();

    var local_state = State.init();
    try dispatchSubmission(
        std.testing.allocator,
        std.testing.io,
        &fixture.session,
        &local_state,
        "!printf local",
    );
    try std.testing.expect(fixture.session.inbox().tryPop(std.testing.io) == null);
    try std.testing.expectEqualStrings(
        "$ printf local\nlocal",
        transcriptBlockContent(&local_state.transcript, 0),
    );

    var shared_state = State.init();
    try dispatchSubmission(
        std.testing.allocator,
        std.testing.io,
        &fixture.session,
        &shared_state,
        "!!printf shared",
    );
    var command = fixture.session.inbox().tryPop(std.testing.io) orelse
        return error.TestUnexpectedResult;
    defer command.deinit(std.testing.allocator);
    try std.testing.expect(command == .prompt);
    try std.testing.expectEqualStrings("$ printf shared\nshared", command.prompt.text);
    try std.testing.expectEqualStrings(
        command.prompt.text,
        transcriptBlockContent(&shared_state.transcript, 0),
    );
}

test "autocomplete popup overlays the transcript directly above the composer" {
    const fixture = try TestSession.create(std.testing.allocator, std.testing.io);
    defer fixture.deinit();
    var state = State.init();
    var now_ms: i64 = 0;
    const clock: Clock = .{ .fixed_ms = &now_ms };

    appendNotice(&state, "line1\nline2\nline3\nline4\nline5");
    for ("/mo") |byte| {
        try handleKey(
            std.testing.allocator,
            std.testing.io,
            &fixture.session,
            &state,
            clock,
            keyCharacter(byte),
        );
    }
    var grid = try tuizr.CellGrid.init(std.testing.allocator, 40, 7);
    defer grid.deinit();

    draw(&state, &grid, "model", .low, 0);
    const projection = try gridProjectionAlloc(std.testing.allocator, &grid);
    defer std.testing.allocator.free(projection);
    try std.testing.expectEqualStrings(
        "line1\n" ++
            "line2\n" ++
            "line3\n" ++
            "line4\n" ++
            "/model  Change the active model\n" ++
            "/mo\n" ++
            "ready                        model • low\n",
        projection,
    );
}
