//! Pi's outer/inner agent-loop state machine over one model call at a time.
//!
//! The host owns session storage, provider calls, and frontend event delivery.
//! This module owns turn continuation, tool-result pairing, queue boundaries,
//! soft tool requirements, and the process-wide pause gate.

const std = @import("std");
const ai = @import("ai");
const events = @import("events.zig");
const message = @import("message.zig");
const scheduler = @import("scheduler.zig");
const tool_api = @import("tool.zig");

const Allocator = std.mem.Allocator;
const empty_stop_retry_template = @embedFile("../prompts/empty-stop-retry.md");
const unexpected_stop_retry_template = @embedFile("../prompts/unexpected-stop-retry.md");

pub const MAX_PAUSED_TURN_CONTINUATIONS: u8 = 8;
pub const MAX_SOFT_TOOL_ESCALATIONS: u8 = 3;
pub const UNEXPECTED_STOP_MAX_RETRIES: u8 = 3;
pub const EMPTY_STOP_MAX_RETRIES: u8 = 3;
pub const RETRY_BACKOFF_MAX_DELAY_MS: u64 = 8_000;

pub const PauseGate = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    paused: bool = false,
    paused_at: ?std.Io.Timestamp = null,

    pub fn pause(self: *PauseGate, io: std.Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.paused) return false;
        self.paused = true;
        self.paused_at = .now(io, .awake);
        return true;
    }

    pub fn @"resume"(self: *PauseGate, io: std.Io) ?u64 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!self.paused) return null;
        const started = self.paused_at;
        self.paused = false;
        self.paused_at = null;
        self.condition.broadcast(io);
        const elapsed = if (started) |timestamp| timestamp.durationTo(.now(io, .awake)) else std.Io.Duration.zero;
        return @intCast(@max(0, @divTrunc(elapsed.nanoseconds, std.time.ns_per_ms)));
    }

    /// Wake parked loops to re-check their own abort flag without releasing the
    /// process-wide pause state.
    pub fn wake(self: *PauseGate, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.condition.broadcast(io);
    }

    pub fn waitUntilResumed(
        self: *PauseGate,
        io: std.Io,
        aborted: *const std.atomic.Value(bool),
    ) std.Io.Cancelable!void {
        return self.waitUntilResumedOrCancelled(io, aborted, null);
    }

    pub fn waitUntilResumedOrCancelled(
        self: *PauseGate,
        io: std.Io,
        aborted: *const std.atomic.Value(bool),
        batch_cancelled: ?*const std.atomic.Value(bool),
    ) std.Io.Cancelable!void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        while (self.paused and !aborted.load(.acquire) and
            (batch_cancelled == null or !batch_cancelled.?.load(.acquire)))
        {
            try self.condition.wait(io, &self.mutex);
        }
    }
};

pub var agent_pause_gate: PauseGate = .{};

pub const SoftToolRequirement = struct {
    id: []const u8,
    tool_name: []const u8,
    reminder: []const message.AgentMessage,
};

pub const ToolChoiceDirective = union(enum) {
    hard: ai.prompt.ToolChoice,
    soft: SoftToolRequirement,
};

pub const HostVTable = struct {
    emit: *const fn (ctx: *anyopaque, event: events.AgentEvent) anyerror!void,
    append: *const fn (ctx: *anyopaque, value: message.AgentMessage) anyerror!void,
    perform_step: *const fn (ctx: *anyopaque, choice: ?ai.prompt.ToolChoice) anyerror!message.AssistantMessage,
    finish_assistant: *const fn (ctx: *anyopaque, value: message.AssistantMessage) anyerror!void,
    emit_message_lifecycle: *const fn (ctx: *anyopaque, value: message.AgentMessage) anyerror!void,
    emit_synthetic_tool: *const fn (
        ctx: *anyopaque,
        call: message.ToolCallContent,
        result: message.ToolResultMessage,
    ) anyerror!void,
    dequeue_steering: *const fn (ctx: *anyopaque, arena: Allocator) anyerror![]const message.AgentMessage,
    dequeue_follow_ups: *const fn (ctx: *anyopaque, arena: Allocator) anyerror![]const message.AgentMessage,
    dequeue_asides: *const fn (ctx: *anyopaque, arena: Allocator) anyerror![]const message.AgentMessage,
    has_steering: *const fn (ctx: ?*anyopaque) scheduler.SteeringState,
    get_tool_choice: *const fn (ctx: *anyopaque) ?ToolChoiceDirective,
    discard_last_assistant: *const fn (ctx: *anyopaque) void,
    classify_unexpected_stop: *const fn (ctx: *anyopaque, text: []const u8) ?bool,
    batch_scope_changed: *const fn (ctx: *anyopaque, scope: ?*scheduler.CancelScope) void,
    now_ms: *const fn (ctx: *anyopaque) i64,
    fail: *const fn (ctx: *anyopaque, text: []const u8) void,
};

pub const Host = struct {
    ctx: *anyopaque,
    io: std.Io,
    gpa: Allocator,
    arena: Allocator,
    registry: *const tool_api.ToolRegistry,
    aborted: *std.atomic.Value(bool),
    pause_gate: *PauseGate = &agent_pause_gate,
    scheduler_callbacks: scheduler.Callbacks = .{},
    scheduler_authorization: ?scheduler.Authorization = null,
    scheduler_tool_filter: ?scheduler.ToolFilter = null,
    interrupt_mode: scheduler.InterruptMode = .immediate,
    intent_tracing: bool = true,
    vtable: *const HostVTable,
};

pub const RunSummary = struct {
    status: events.RunStatus,
    turns: u32,
};

/// Errors stay inside the loop boundary. Internal failures are handed to the
/// host, which persists an assistant error message and emits failed/notice.
pub fn runLoopBody(host: *Host, initial_messages: []const message.AgentMessage) RunSummary {
    return runLoopBodyFallible(host, initial_messages) catch |err| {
        host.vtable.fail(host.ctx, @errorName(err));
        return .{ .status = if (host.aborted.load(.acquire)) .cancelled else .failed, .turns = 0 };
    };
}

fn runLoopBodyFallible(host: *Host, initial_messages: []const message.AgentMessage) !RunSummary {
    var turns: u32 = 0;
    var paused_turn_continuations: u8 = 0;
    var soft_requirement_id: ?[]const u8 = null;
    var soft_required_tool: ?[]const u8 = null;
    var soft_escalations: u8 = 0;
    var forced_tool_choice: ?ai.prompt.ToolChoice = null;
    var empty_stop_retries: u8 = 0;
    var unexpected_stop_retries: u8 = 0;

    var pending = try concatMessages(
        host.arena,
        initial_messages,
        if (host.aborted.load(.acquire)) &.{} else try host.vtable.dequeue_steering(host.ctx, host.arena),
    );

    var outer_continue = true;
    while (outer_continue) {
        outer_continue = false;
        var has_more_tool_calls = true;
        while (has_more_tool_calls or pending.len != 0) {
            try host.pause_gate.waitUntilResumed(host.io, host.aborted);

            try host.vtable.emit(host.ctx, .turn_started);
            turns += 1;
            for (pending) |value| {
                try host.vtable.append(host.ctx, value);
                try host.vtable.emit_message_lifecycle(host.ctx, value);
            }
            pending = &.{};

            const directive = if (host.aborted.load(.acquire)) null else host.vtable.get_tool_choice(host.ctx);
            var hard_choice: ?ai.prompt.ToolChoice = null;
            if (directive) |value| switch (value) {
                .hard => |choice| {
                    hard_choice = choice;
                    soft_requirement_id = null;
                    soft_required_tool = null;
                    soft_escalations = 0;
                },
                .soft => |requirement| {
                    soft_required_tool = requirement.tool_name;
                    if (soft_requirement_id == null or !std.mem.eql(u8, soft_requirement_id.?, requirement.id)) {
                        soft_requirement_id = requirement.id;
                        soft_escalations = 0;
                        for (requirement.reminder) |reminder| {
                            try host.vtable.append(host.ctx, reminder);
                            try host.vtable.emit_message_lifecycle(host.ctx, reminder);
                        }
                    }
                },
            } else {
                soft_requirement_id = null;
                soft_required_tool = null;
                soft_escalations = 0;
            }

            const choice = hard_choice orelse forced_tool_choice;
            forced_tool_choice = null;
            var assistant = try host.vtable.perform_step(host.ctx, choice);
            assistant = try tool_api.normalizeAssistantIntents(host.arena, assistant, host.registry, host.intent_tracing);
            try host.vtable.append(host.ctx, .{ .assistant = assistant });
            try host.vtable.finish_assistant(host.ctx, assistant);

            const calls = try collectToolCalls(host.arena, assistant.content);
            var tool_results: []const message.ToolResultMessage = &.{};
            if (assistant.stop_reason == .@"error" or assistant.stop_reason == .aborted) {
                const reason: PlaceholderReason = if (assistant.stop_reason == .aborted) .aborted else .provider_error;
                tool_results = try appendPlaceholders(host, calls, reason, assistant.error_message);
                try emitTurnFinished(host, assistant.stop_reason, calls.len, tool_results.len);
                return .{
                    .status = if (assistant.stop_reason == .aborted) .cancelled else .failed,
                    .turns = turns,
                };
            }

            const runnable = (assistant.stop_reason == .tool_use or assistant.stop_reason == .stop) and calls.len != 0;
            has_more_tool_calls = runnable;
            const called_only_required = if (soft_required_tool) |required|
                calls.len != 0 and allCallsNamed(calls, required)
            else
                false;
            const soft_non_compliant = soft_required_tool != null and !called_only_required;
            var stop_retry_scheduled = false;

            if (!soft_non_compliant) {
                if (isEmptyAssistantStop(assistant)) {
                    empty_stop_retries += 1;
                    unexpected_stop_retries = 0;
                    if (empty_stop_retries <= EMPTY_STOP_MAX_RETRIES) {
                        host.vtable.discard_last_assistant(host.ctx);
                        const reminder = try stopRetryReminder(
                            host.arena,
                            empty_stop_retry_template,
                            empty_stop_retries,
                            EMPTY_STOP_MAX_RETRIES,
                            host.vtable.now_ms(host.ctx),
                        );
                        try host.vtable.append(host.ctx, reminder);
                        try host.vtable.emit_message_lifecycle(host.ctx, reminder);
                        has_more_tool_calls = true;
                        stop_retry_scheduled = true;
                    } else if (assistant.stop_reason == .tool_use) {
                        host.vtable.discard_last_assistant(host.ctx);
                    }
                } else {
                    empty_stop_retries = 0;
                    if (unexpectedStopText(assistant)) |text| {
                        if (host.vtable.classify_unexpected_stop(host.ctx, text) == true) {
                            unexpected_stop_retries += 1;
                            if (unexpected_stop_retries <= UNEXPECTED_STOP_MAX_RETRIES) {
                                const reminder = try stopRetryReminder(
                                    host.arena,
                                    unexpected_stop_retry_template,
                                    unexpected_stop_retries,
                                    UNEXPECTED_STOP_MAX_RETRIES,
                                    host.vtable.now_ms(host.ctx),
                                );
                                try host.vtable.append(host.ctx, reminder);
                                try host.vtable.emit_message_lifecycle(host.ctx, reminder);
                                has_more_tool_calls = true;
                                stop_retry_scheduled = true;
                            } else {
                                unexpected_stop_retries = 0;
                            }
                        } else {
                            unexpected_stop_retries = 0;
                        }
                    } else {
                        unexpected_stop_retries = 0;
                    }
                }
            }

            if (soft_non_compliant) {
                tool_results = try appendSoftRequirementPlaceholders(host, calls, soft_required_tool.?);
                if (soft_escalations >= MAX_SOFT_TOOL_ESCALATIONS) {
                    const text = try std.fmt.allocPrint(
                        host.arena,
                        "Soft tool requirement '{s}' was not satisfied after {d} forced turns; aborting to avoid an unbounded force loop.",
                        .{ soft_required_tool.?, MAX_SOFT_TOOL_ESCALATIONS },
                    );
                    host.vtable.fail(host.ctx, text);
                    try emitTurnFinished(host, assistant.stop_reason, calls.len, tool_results.len);
                    return .{ .status = .failed, .turns = turns };
                }
                forced_tool_choice = .{ .named = soft_required_tool.? };
                soft_escalations += 1;
                has_more_tool_calls = true;
            } else if (stop_retry_scheduled) {
                // The retry reminder is already in session history. Steering is
                // still consumed at the normal post-turn boundary below.
            } else if (runnable) {
                var scope: scheduler.CancelScope = .{};
                scope.wake_ctx = host.pause_gate;
                scope.wake_fn = wakePauseGate;
                host.vtable.batch_scope_changed(host.ctx, &scope);
                const batch = scheduler.executeToolCalls(
                    host.io,
                    host.gpa,
                    host.arena,
                    calls,
                    host.registry,
                    &scope,
                    .{
                        .interrupt_mode = host.interrupt_mode,
                        .steering = .{ .ctx = host.ctx, .check_fn = host.vtable.has_steering },
                        .callbacks = host.scheduler_callbacks,
                        .authorization = host.scheduler_authorization,
                        .park_before_tool = .{ .ctx = host, .wait_fn = parkBeforeTool },
                        .tool_filter = host.scheduler_tool_filter,
                        .timestamp_ms = host.vtable.now_ms(host.ctx),
                    },
                ) catch |err| {
                    host.vtable.batch_scope_changed(host.ctx, null);
                    return err;
                };
                host.vtable.batch_scope_changed(host.ctx, null);
                tool_results = batch.tool_results;
                for (tool_results) |result| {
                    try host.vtable.append(host.ctx, .{ .tool_result = result });
                    try host.vtable.emit_message_lifecycle(host.ctx, .{ .tool_result = result });
                }
            } else if (calls.len != 0) {
                const reason: PlaceholderReason = if (assistant.stop_reason == .length) .length else .skipped;
                tool_results = try appendPlaceholders(host, calls, reason, null);
                if (assistant.stop_reason == .length and tool_results.len != 0) has_more_tool_calls = true;
            }

            if (calls.len != 0) {
                paused_turn_continuations = 0;
            } else if (!has_more_tool_calls and
                assistant.stop_reason == .stop and
                isPauseTurn(assistant.stop_details) and
                paused_turn_continuations < MAX_PAUSED_TURN_CONTINUATIONS)
            {
                paused_turn_continuations += 1;
                has_more_tool_calls = true;
            }

            try emitTurnFinished(host, assistant.stop_reason, calls.len, tool_results.len);

            const steering = if (host.aborted.load(.acquire)) &.{} else try host.vtable.dequeue_steering(host.ctx, host.arena);
            if (has_more_tool_calls) {
                const asides = if (host.aborted.load(.acquire)) &.{} else try host.vtable.dequeue_asides(host.ctx, host.arena);
                pending = try concatMessages(host.arena, steering, asides);
            } else {
                pending = steering;
            }
        }

        if (host.aborted.load(.acquire)) return .{ .status = .cancelled, .turns = turns };
        const late_steering = try host.vtable.dequeue_steering(host.ctx, host.arena);
        const asides = try host.vtable.dequeue_asides(host.ctx, host.arena);
        const follow_ups = try host.vtable.dequeue_follow_ups(host.ctx, host.arena);
        pending = try concatThree(host.arena, late_steering, asides, follow_ups);
        if (pending.len != 0) outer_continue = true;
    }

    return .{ .status = .completed, .turns = turns };
}

fn wakePauseGate(raw: ?*anyopaque, io: std.Io) void {
    const gate: *PauseGate = @ptrCast(@alignCast(raw.?));
    gate.wake(io);
}

fn parkBeforeTool(raw: ?*anyopaque, io: std.Io, scope: *scheduler.CancelScope) std.Io.Cancelable!void {
    const host: *Host = @ptrCast(@alignCast(raw.?));
    return host.pause_gate.waitUntilResumedOrCancelled(io, host.aborted, &scope.cancelled);
}

const PlaceholderReason = enum {
    aborted,
    provider_error,
    skipped,
    length,
};

fn appendPlaceholders(
    host: *Host,
    calls: []const message.ToolCallContent,
    reason: PlaceholderReason,
    error_message: ?[]const u8,
) ![]const message.ToolResultMessage {
    const results = try host.arena.alloc(message.ToolResultMessage, calls.len);
    for (calls, results) |call, *result| {
        result.* = try placeholder(host.arena, call, reason, error_message, host.vtable.now_ms(host.ctx));
        try host.vtable.append(host.ctx, .{ .tool_result = result.* });
        try host.vtable.emit_synthetic_tool(host.ctx, call, result.*);
    }
    return results;
}

fn appendSoftRequirementPlaceholders(
    host: *Host,
    calls: []const message.ToolCallContent,
    required_tool: []const u8,
) ![]const message.ToolResultMessage {
    const results = try host.arena.alloc(message.ToolResultMessage, calls.len);
    const text = try std.fmt.allocPrint(
        host.arena,
        "Tool call was not executed because the assistant ended its turn: Not executed: call the `{s}` tool to resolve the pending action before using other tools.",
        .{required_tool},
    );
    for (calls, results) |call, *result| {
        result.* = try syntheticResult(
            host.arena,
            call,
            text,
            "assistant_stop_skipped",
            null,
            host.vtable.now_ms(host.ctx),
        );
        try host.vtable.append(host.ctx, .{ .tool_result = result.* });
        try host.vtable.emit_synthetic_tool(host.ctx, call, result.*);
    }
    return results;
}

fn placeholder(
    arena: Allocator,
    call: message.ToolCallContent,
    reason: PlaceholderReason,
    error_message: ?[]const u8,
    timestamp_ms: i64,
) !message.ToolResultMessage {
    const base = switch (reason) {
        .aborted => "Tool execution was aborted",
        .provider_error => "Tool call was not executed because the provider stream ended with an error before the tool could run",
        .skipped => "Tool call was not executed because the assistant ended its turn",
        .length => "Tool call was not executed because the assistant hit its output token limit (stop_reason: length) before the arguments could complete; the recorded arguments are truncated and unsafe to run. Do NOT retry by re-emitting the same large payload — split the work into several smaller tool calls (e.g. for `write`/`edit`, write the first chunk then append the rest with subsequent `edit` insert ops, or break the file into multiple `write` targets)",
    };
    const text = if (error_message) |detail|
        try std.fmt.allocPrint(arena, "{s}: {s}", .{ base, detail })
    else
        try std.fmt.allocPrint(arena, "{s}.", .{base});
    const source = switch (reason) {
        .aborted => "assistant_stop_aborted",
        .provider_error => "assistant_stop_error",
        .skipped => "assistant_stop_skipped",
        .length => "assistant_stop_length",
    };
    return syntheticResult(arena, call, text, source, if (reason == .provider_error) error_message else null, timestamp_ms);
}

fn syntheticResult(
    arena: Allocator,
    call: message.ToolCallContent,
    text: []const u8,
    source: []const u8,
    upstream_error: ?[]const u8,
    timestamp_ms: i64,
) !message.ToolResultMessage {
    const blocks = try arena.alloc(message.TextImageBlock, 1);
    blocks[0] = .{ .text = .{ .text = try arena.dupe(u8, text) } };
    var details: std.json.ObjectMap = .empty;
    try details.put(arena, "__synthetic", .{ .bool = true });
    try details.put(arena, "source", .{ .string = try arena.dupe(u8, source) });
    try details.put(arena, "executed", .{ .bool = false });
    if (upstream_error) |value| {
        try details.put(arena, "upstreamError", .{ .string = try arena.dupe(u8, value) });
    }
    return .{
        .tool_call_id = try arena.dupe(u8, call.id),
        .tool_name = try arena.dupe(u8, call.name),
        .content = blocks,
        .details = .{ .object = details },
        .is_error = true,
        .timestamp = timestamp_ms,
    };
}

fn collectToolCalls(arena: Allocator, content: []const message.AssistantBlock) ![]const message.ToolCallContent {
    var calls: std.ArrayList(message.ToolCallContent) = .empty;
    defer calls.deinit(arena);
    for (content) |block| switch (block) {
        .tool_call => |call| try calls.append(arena, call),
        else => {},
    };
    return calls.toOwnedSlice(arena);
}

fn allCallsNamed(calls: []const message.ToolCallContent, name: []const u8) bool {
    for (calls) |call| if (!std.mem.eql(u8, call.name, name)) return false;
    return true;
}

fn isPauseTurn(details: ?std.json.Value) bool {
    const value = details orelse return false;
    if (value != .object) return false;
    const type_value = value.object.get("type") orelse return false;
    return type_value == .string and std.mem.eql(u8, type_value.string, "pause_turn");
}

fn isEmptyAssistantStop(assistant: message.AssistantMessage) bool {
    if (assistant.stop_reason != .stop and assistant.stop_reason != .tool_use) return false;
    if (isPauseTurn(assistant.stop_details)) return false;
    for (assistant.content) |block| switch (block) {
        .tool_call => return false,
        .text => |text| if (std.mem.trim(u8, text.text, " \t\r\n").len != 0) return false,
        else => {},
    };
    return true;
}

fn unexpectedStopText(assistant: message.AssistantMessage) ?[]const u8 {
    if (assistant.stop_reason != .stop) return null;
    var found: ?[]const u8 = null;
    for (assistant.content) |block| switch (block) {
        .tool_call => return null,
        .text => |text| if (std.mem.trim(u8, text.text, " \t\r\n").len != 0) {
            // The classifier contract only needs the rendered text. A
            // multi-block response is joined by the AgentSession adapter.
            if (found == null) found = text.text;
        },
        else => {},
    };
    return found;
}

fn stopRetryReminder(
    arena: Allocator,
    template: []const u8,
    retry_count: u8,
    max_retries: u8,
    timestamp_ms: i64,
) !message.AgentMessage {
    var retry_buffer: [8]u8 = undefined;
    const retry_text = try std.fmt.bufPrint(&retry_buffer, "{d}", .{retry_count});
    var max_buffer: [8]u8 = undefined;
    const max_text = try std.fmt.bufPrint(&max_buffer, "{d}", .{max_retries});
    const with_retry = try std.mem.replaceOwned(u8, arena, template, "{{retryCount}}", retry_text);
    const rendered = try std.mem.replaceOwned(u8, arena, with_retry, "{{maxRetries}}", max_text);
    const blocks = try arena.alloc(message.TextImageBlock, 1);
    blocks[0] = .{ .text = .{ .text = rendered } };
    return .{ .developer = .{
        .content = .{ .blocks = blocks },
        .attribution = .agent,
        .timestamp = timestamp_ms,
    } };
}

fn concatMessages(
    arena: Allocator,
    first: []const message.AgentMessage,
    second: []const message.AgentMessage,
) ![]const message.AgentMessage {
    if (first.len == 0) return second;
    if (second.len == 0) return first;
    const result = try arena.alloc(message.AgentMessage, first.len + second.len);
    @memcpy(result[0..first.len], first);
    @memcpy(result[first.len..], second);
    return result;
}

fn concatThree(
    arena: Allocator,
    first: []const message.AgentMessage,
    second: []const message.AgentMessage,
    third: []const message.AgentMessage,
) ![]const message.AgentMessage {
    return concatMessages(arena, try concatMessages(arena, first, second), third);
}

fn emitTurnFinished(
    host: *Host,
    stop_reason: message.StopReason,
    tool_calls: usize,
    tool_results: usize,
) !void {
    try host.vtable.emit(host.ctx, .{ .turn_finished = .{
        .stop_reason = stop_reason,
        .tool_calls = @intCast(tool_calls),
        .tool_results = @intCast(tool_results),
    } });
}

test "loop pause gate releases only after resume" {
    const io = std.testing.io;
    var gate: PauseGate = .{};
    var aborted = std.atomic.Value(bool).init(false);
    try std.testing.expect(gate.pause(io));
    try std.testing.expect(!gate.pause(io));
    const Waiter = struct {
        fn run(value: *PauseGate, task_io: std.Io, stop: *const std.atomic.Value(bool)) std.Io.Cancelable!void {
            return value.waitUntilResumed(task_io, stop);
        }
    };
    var future = try io.concurrent(Waiter.run, .{ &gate, io, &aborted });
    try io.sleep(.fromMilliseconds(1), .awake);
    try std.testing.expect(gate.@"resume"(io) != null);
    try future.await(io);
}

test "loop abort wakes only its pause waiter and leaves the global gate paused" {
    const io = std.testing.io;
    var gate: PauseGate = .{};
    var aborted = std.atomic.Value(bool).init(false);
    try std.testing.expect(gate.pause(io));
    const Waiter = struct {
        fn run(value: *PauseGate, task_io: std.Io, stop: *const std.atomic.Value(bool)) std.Io.Cancelable!void {
            return value.waitUntilResumed(task_io, stop);
        }
    };
    var future = try io.concurrent(Waiter.run, .{ &gate, io, &aborted });
    try io.sleep(.fromMilliseconds(1), .awake);
    aborted.store(true, .release);
    gate.wake(io);
    try future.await(io);

    gate.mutex.lockUncancelable(io);
    const remains_paused = gate.paused;
    gate.mutex.unlock(io);
    try std.testing.expect(remains_paused);
    try std.testing.expect(gate.@"resume"(io) != null);
}
