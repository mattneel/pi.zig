//! In-memory agent session and mailbox command processor.
//!
//! The session owns its message arena for its whole lifetime. ai.zig results
//! are raised into that arena before `StreamTextResult.deinit`; frontend events
//! cross the outbox only through deep-copying mailbox pushes.

const std = @import("std");
const build_options = @import("build_options");
const ai = @import("ai");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const catalog = @import("../catalog/catalog.zig");
const approval = @import("approval.zig");
const events = @import("events.zig");
const loop = @import("loop.zig");
const lower = @import("lower.zig");
const mailbox = @import("mailbox.zig");
const message = @import("message.zig");
const raise = @import("raise.zig");
const replay_policy = @import("replay_policy.zig");
const scheduler = @import("scheduler.zig");
const session_manager = @import("../session/manager.zig");
const tool_api = @import("tool.zig");

const Allocator = std.mem.Allocator;

pub const QueueMode = enum {
    one_at_a_time,
    all,
};

/// Provider/model strings are cloned by `AgentSession`; the erased language
/// model implementation is borrowed and must outlive the session.
pub const ModelTarget = struct {
    language_model: ai.LanguageModelRef,
    provider_name: []const u8,
    model_id: []const u8,
    api: ?[]const u8 = null,
};

pub const FallbackChain = struct {
    role: []const u8,
    models: []const ModelTarget,
};

pub const ResolveModel = struct {
    ctx: ?*anyopaque = null,
    resolve_fn: *const fn (ctx: ?*anyopaque, provider_name: []const u8, model_id: []const u8) ?ModelTarget,
};

pub const ToolChoiceResolver = struct {
    ctx: ?*anyopaque = null,
    resolve_fn: *const fn (ctx: ?*anyopaque) ?loop.ToolChoiceDirective,
};

pub const UnexpectedStopClassifier = struct {
    ctx: ?*anyopaque = null,
    classify_fn: *const fn (ctx: ?*anyopaque, text: []const u8) ?bool,
};

pub const ApprovalPolicyResolver = struct {
    ctx: ?*anyopaque = null,
    resolve_fn: *const fn (ctx: ?*anyopaque, tool_name: []const u8) ?approval.UserPolicy,
};

pub const RetryOptions = struct {
    max_retries: u8 = 10,
    base_delay_ms: u64 = 500,
    backoff_cap_ms: u64 = loop.RETRY_BACKOFF_MAX_DELAY_MS,
    /// Provider-directed waits above this fail fast unless a fallback exists.
    max_delay_ms: u64 = 300_000,
};

pub const Options = struct {
    model: ModelTarget,
    model_role: ?[]const u8 = null,
    fallback_models: []const ModelTarget = &.{},
    fallback_chains: []const FallbackChain = &.{},
    resolve_model: ?ResolveModel = null,
    system_prompt: []const u8 = "",
    tools: *const tool_api.ToolRegistry,
    active_tools: ?[]const []const u8 = null,
    thinking: catalog.ThinkingLevel = .off,
    steering_mode: QueueMode = .one_at_a_time,
    follow_up_mode: QueueMode = .one_at_a_time,
    interrupt_mode: scheduler.InterruptMode = .immediate,
    intent_tracing: bool = true,
    tool_choice: ?ToolChoiceResolver = null,
    unexpected_stop_classifier: ?UnexpectedStopClassifier = null,
    approval_mode: approval.ApprovalMode = .yolo,
    approval_policy: ?ApprovalPolicyResolver = null,
    command_capacity: usize = 64,
    event_capacity: usize = 256,
    retry: RetryOptions = .{},
    /// When absent, the agent owns an in-memory session manager.
    session_manager: ?*session_manager.SessionManager = null,
    restore_model_from_session: bool = true,
    restore_thinking_from_session: bool = true,
    max_output_tokens: ?f64 = null,
};

const AbortKind = enum(u8) {
    none,
    user,
    shutdown,
    deadline,
    superseded,
    other,
};

const PendingApproval = struct {
    request_id: []u8,
    decided: std.Io.Event = .unset,
    approved: ?bool = null,
    reason: ?[]u8 = null,

    fn deinit(self: *PendingApproval, allocator: Allocator) void {
        allocator.free(self.request_id);
        if (self.reason) |reason| allocator.free(reason);
        self.* = undefined;
    }
};

const StepCapture = struct {
    arena: Allocator,
    text: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    tool_calls: std.ArrayList(ai.TypedToolCall) = .empty,
    aborted: bool = false,
    abort_reason: ?[]const u8 = null,
    stream_error: ?[]const u8 = null,

    fn deinit(self: *StepCapture) void {
        self.text.deinit(self.arena);
        self.reasoning.deinit(self.arena);
        self.tool_calls.deinit(self.arena);
    }
};

const AttemptResult = union(enum) {
    assistant: message.AssistantMessage,
    failure: struct {
        retryable: bool,
        text: []const u8,
        retry_after_ms: ?u64 = null,
    },
};

const LiveCallSettings = struct {
    system_prompt: []const u8,
    active_tools: ?[]const []const u8,
    thinking: catalog.ThinkingLevel,
    max_output_tokens: ?f64,
};

pub const AgentSession = struct {
    gpa: Allocator,
    io: std.Io,
    config_arena_state: std.heap.ArenaAllocator,
    message_arena_state: std.heap.ArenaAllocator,
    catalog_registry: catalog.Registry,
    messages: std.ArrayList(message.AgentMessage) = .empty,
    commands: mailbox.CommandInbox,
    event_outbox: mailbox.EventOutbox,
    run_group: std.Io.Group = .init,

    tools: *const tool_api.ToolRegistry,
    current_model: ModelTarget,
    current_model_role: ?[]const u8,
    fallback_models: []const ModelTarget,
    fallback_chains: []const FallbackChain,
    resolve_model: ?ResolveModel,
    system_prompt: []const u8,
    active_tools: ?[]const []const u8,
    thinking: catalog.ThinkingLevel,
    steering_mode: QueueMode,
    follow_up_mode: QueueMode,
    interrupt_mode: scheduler.InterruptMode,
    intent_tracing: bool,
    tool_choice: ?ToolChoiceResolver,
    unexpected_stop_classifier: ?UnexpectedStopClassifier,
    approval_mode: approval.ApprovalMode,
    approval_policy: ?ApprovalPolicyResolver,
    retry: RetryOptions,
    session_manager: *session_manager.SessionManager,
    owns_session_manager: bool,
    restore_model_from_session: bool,
    restore_thinking_from_session: bool,
    max_output_tokens: ?f64,

    state_mutex: std.Io.Mutex = .init,
    initial_queue: std.ArrayList(events.OwnedPrompt) = .empty,
    steering_queue: std.ArrayList(events.OwnedPrompt) = .empty,
    follow_up_queue: std.ArrayList(events.OwnedPrompt) = .empty,
    aside_queue: std.ArrayList([]u8) = .empty,
    pending_approvals: std.ArrayList(*PendingApproval) = .empty,

    running: std.atomic.Value(bool) = .init(false),
    shutting_down: std.atomic.Value(bool) = .init(false),
    aborted: std.atomic.Value(bool) = .init(false),
    abort_kind: std.atomic.Value(AbortKind) = .init(.none),
    retry_abort: std.Io.Event = .unset,
    generation: std.atomic.Value(u64) = .init(0),
    step_number: u64 = 0,

    active_mutex: std.Io.Mutex = .init,
    active_step: ?*std.Io.Future(anyerror!void) = null,
    active_scope: ?*scheduler.CancelScope = null,
    callback_error: ?anyerror = null,

    /// `gpa` must support concurrent allocation because provider, mailbox, and
    /// shared-tool tasks may allocate at the same time.
    pub fn init(gpa: Allocator, io: std.Io, options: Options) !AgentSession {
        var config_arena_state = std.heap.ArenaAllocator.init(gpa);
        errdefer config_arena_state.deinit();
        const config_arena = config_arena_state.allocator();
        var message_arena_state = std.heap.ArenaAllocator.init(gpa);
        errdefer message_arena_state.deinit();
        var registry = try catalog.Registry.init(gpa);
        errdefer registry.deinit();
        var commands = try mailbox.CommandInbox.init(gpa, options.command_capacity);
        errdefer commands.deinit();
        var event_outbox = try mailbox.EventOutbox.init(gpa, options.event_capacity);
        errdefer event_outbox.deinit();

        const persistence = if (options.session_manager) |manager|
            manager
        else blk: {
            const manager = try gpa.create(session_manager.SessionManager);
            errdefer gpa.destroy(manager);
            manager.* = try session_manager.SessionManager.inMemory(gpa, io, ".");
            break :blk manager;
        };
        errdefer if (options.session_manager == null) {
            persistence.deinit();
            gpa.destroy(persistence);
        };

        const fallback_models = try config_arena.alloc(ModelTarget, options.fallback_models.len);
        for (options.fallback_models, fallback_models) |target, *destination| {
            destination.* = try cloneTarget(config_arena, target);
        }
        const fallback_chains = try config_arena.alloc(FallbackChain, options.fallback_chains.len);
        for (options.fallback_chains, fallback_chains) |chain, *destination| {
            const models = try config_arena.alloc(ModelTarget, chain.models.len);
            for (chain.models, models) |target, *model| model.* = try cloneTarget(config_arena, target);
            destination.* = .{
                .role = try config_arena.dupe(u8, chain.role),
                .models = models,
            };
        }
        const active_tools = if (options.active_tools) |names| blk: {
            const copy = try config_arena.alloc([]const u8, names.len);
            for (names, copy) |name, *destination| destination.* = try config_arena.dupe(u8, name);
            break :blk copy;
        } else null;
        const current_model = try cloneTarget(config_arena, options.model);
        const current_model_role = if (options.model_role) |role| try config_arena.dupe(u8, role) else null;
        const system_prompt = try config_arena.dupe(u8, options.system_prompt);

        var result: AgentSession = .{
            .gpa = gpa,
            .io = io,
            .config_arena_state = config_arena_state,
            .message_arena_state = message_arena_state,
            .catalog_registry = registry,
            .commands = commands,
            .event_outbox = event_outbox,
            .tools = options.tools,
            .current_model = current_model,
            .current_model_role = current_model_role,
            .fallback_models = fallback_models,
            .fallback_chains = fallback_chains,
            .resolve_model = options.resolve_model,
            .system_prompt = system_prompt,
            .active_tools = active_tools,
            .thinking = options.thinking,
            .steering_mode = options.steering_mode,
            .follow_up_mode = options.follow_up_mode,
            .interrupt_mode = options.interrupt_mode,
            .intent_tracing = options.intent_tracing,
            .tool_choice = options.tool_choice,
            .unexpected_stop_classifier = options.unexpected_stop_classifier,
            .approval_mode = options.approval_mode,
            .approval_policy = options.approval_policy,
            .retry = options.retry,
            .session_manager = persistence,
            .owns_session_manager = options.session_manager == null,
            .restore_model_from_session = options.restore_model_from_session,
            .restore_thinking_from_session = options.restore_thinking_from_session,
            .max_output_tokens = options.max_output_tokens,
        };
        try result.restoreFromSession();
        return result;
    }

    /// Call after `run` has returned (normally by sending `.shutdown`).
    pub fn deinit(self: *AgentSession) void {
        // Backstop for callers that drop the session without running `run` to
        // completion. Draining the group here guarantees no run task is still
        // executing against the fields freed below.
        self.closeToRuns();
        self.run_group.cancel(self.io);
        self.commands.close(self.io);
        self.event_outbox.close(self.io);
        deinitPromptQueue(self.gpa, &self.initial_queue);
        deinitPromptQueue(self.gpa, &self.steering_queue);
        deinitPromptQueue(self.gpa, &self.follow_up_queue);
        for (self.aside_queue.items) |encoded| self.gpa.free(encoded);
        self.aside_queue.deinit(self.gpa);
        for (self.pending_approvals.items) |pending| {
            pending.deinit(self.gpa);
            self.gpa.destroy(pending);
        }
        self.pending_approvals.deinit(self.gpa);
        self.commands.deinit();
        self.event_outbox.deinit();
        self.catalog_registry.deinit();
        if (self.owns_session_manager) {
            self.session_manager.deinit();
            self.gpa.destroy(self.session_manager);
        }
        self.message_arena_state.deinit();
        self.config_arena_state.deinit();
        self.* = undefined;
    }

    pub fn inbox(self: *AgentSession) *mailbox.CommandInbox {
        return &self.commands;
    }

    pub fn outbox(self: *AgentSession) *mailbox.EventOutbox {
        return &self.event_outbox;
    }

    /// The returned slice is session-owned and is only stable while the agent
    /// is idle. Use `cloneMessages` for a caller-owned snapshot.
    pub fn messagesBorrowed(self: *const AgentSession) []const message.AgentMessage {
        return self.messages.items;
    }

    pub fn persistedUsage(self: *const AgentSession) message.Usage {
        return self.session_manager.usageTotals();
    }

    pub fn sessionManager(self: *AgentSession) *session_manager.SessionManager {
        return self.session_manager;
    }

    /// Deep-copy the current history into a caller-owned arena. The returned
    /// slice and all nested message storage live until that arena is reset.
    pub fn cloneMessages(self: *const AgentSession, arena: Allocator) ![]message.AgentMessage {
        const output = try arena.alloc(message.AgentMessage, self.messages.items.len);
        for (self.messages.items, output) |value, *destination| {
            const encoded = try message.stringifyAlloc(arena, value);
            destination.* = try message.parse(arena, encoded);
        }
        return output;
    }

    pub fn isRunning(self: *const AgentSession) bool {
        return self.running.load(.acquire);
    }

    pub fn pause(self: *AgentSession) bool {
        return loop.agent_pause_gate.pause(self.io);
    }

    pub fn @"resume"(self: *AgentSession) ?u64 {
        return loop.agent_pause_gate.@"resume"(self.io);
    }

    pub fn setSystemPrompt(self: *AgentSession, text: []const u8) !void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        self.system_prompt = try self.config_arena_state.allocator().dupe(u8, text);
    }

    pub fn setActiveTools(self: *AgentSession, names: ?[]const []const u8) !void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        self.active_tools = if (names) |source| blk: {
            const copy = try self.config_arena_state.allocator().alloc([]const u8, source.len);
            for (source, copy) |name, *destination| {
                destination.* = try self.config_arena_state.allocator().dupe(u8, name);
            }
            break :blk copy;
        } else null;
    }

    /// Queue an aside without exposing session storage. The wire encoding is
    /// owned by the queue and parsed into the message arena at the next boundary.
    pub fn queueAside(self: *AgentSession, value: message.AgentMessage) !void {
        const encoded = try message.stringifyAlloc(self.gpa, value);
        errdefer self.gpa.free(encoded);
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        try self.aside_queue.append(self.gpa, encoded);
    }

    /// Command-processor entry point. It remains responsive while a run task
    /// performs provider calls and tools in `run_group`.
    pub fn run(self: *AgentSession) !void {
        // Runs on every exit path, not just the `.shutdown` break: the loop
        // body can also fail out through `try`, and `commands.pop` returning
        // null ends it without any shutdown command having been seen. Leaving
        // the group undrained on those paths lets a run task outlive the
        // session and touch freed memory.
        defer {
            self.closeToRuns();
            self.run_group.cancel(self.io);
            self.event_outbox.close(self.io);
        }
        while (try self.commands.pop(self.io)) |owned_command| {
            var command = owned_command;
            defer command.deinit(self.gpa);
            switch (command) {
                .prompt => |prompt| try self.handlePrompt(prompt),
                .steer => |prompt| {
                    try self.enqueuePrompt(&self.steering_queue, prompt);
                    if (!self.running.load(.acquire)) self.startRun();
                },
                .follow_up => |prompt| {
                    try self.enqueuePrompt(&self.follow_up_queue, prompt);
                    if (!self.running.load(.acquire)) self.startRun();
                },
                .dequeue_last => try self.dequeueLast(),
                .cancel => |reason| self.cancel(reason),
                .change_model => |selection| try self.changeModel(selection),
                .change_thinking => |thinking| {
                    self.state_mutex.lockUncancelable(self.io);
                    self.thinking = thinking;
                    self.state_mutex.unlock(self.io);
                    _ = try self.session_manager.appendThinkingChange(@tagName(thinking));
                },
                .compact => try self.emitNotice(.info, "Compaction is deferred to Phase 4"),
                .approve => |decision| try self.resolveApproval(decision),
                .retry => {
                    if (!self.running.load(.acquire)) self.startRun();
                },
                .shutdown => {
                    self.shutting_down.store(true, .release);
                    self.cancel(.shutdown);
                    try self.session_manager.flush();
                    break;
                },
            }
        }
    }

    /// Marks the session as accepting no further run tasks. Taken under
    /// `state_mutex` so it cannot interleave with the check in `startRun`.
    fn closeToRuns(self: *AgentSession) void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        self.shutting_down.store(true, .release);
    }

    fn handlePrompt(self: *AgentSession, prompt: events.OwnedPrompt) !void {
        try self.enqueuePrompt(&self.initial_queue, prompt);
        if (!self.running.load(.acquire)) self.startRun();
    }

    fn startRun(self: *AgentSession) void {
        // Held across the spawn so it cannot interleave with `closeToRuns`.
        // A run task's own tail calls back into `startRun`, so without this a
        // task could be added to `run_group` after `cancel` had already drained
        // it -- that task then runs on a session which is being torn down.
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        if (self.shutting_down.load(.acquire)) return;
        if (self.running.swap(true, .acq_rel)) return;
        self.aborted.store(false, .release);
        self.abort_kind.store(.none, .release);
        self.retry_abort.reset();
        // Must be `concurrent`, not `async`: `Group.async` may run the task
        // inline, which would block this call until the whole run finished and
        // leave the inbox unread for its duration -- so steering, cancel and
        // shutdown could not be delivered to a run already in progress.
        self.run_group.concurrent(self.io, runTask, .{self}) catch |err| {
            self.running.store(false, .release);
            self.recordCallbackError(err);
        };
    }

    fn runTask(self: *AgentSession) std.Io.Cancelable!void {
        self.runGenerations() catch |err| {
            self.persistFailure(@errorName(err));
            self.emit(.{ .run_finished = .{ .status = .failed, .turns = 0 } }) catch |emit_err|
                self.recordCallbackError(emit_err);
            self.running.store(false, .release);
            if (!self.shutting_down.load(.acquire) and self.hasQueuedInput()) self.startRun();
        };
    }

    fn runGenerations(self: *AgentSession) !void {
        while (!self.shutting_down.load(.acquire)) {
            _ = self.generation.fetchAdd(1, .acq_rel);
            try self.emit(.run_started);
            const initial = try self.takeInitialMessages();
            var runtime_host = self.host();
            const summary = loop.runLoopBody(&runtime_host, initial);
            try self.emit(.{ .run_finished = .{ .status = summary.status, .turns = summary.turns } });

            const queued = self.hasQueuedInput();
            if (!queued) break;
            self.aborted.store(false, .release);
            self.abort_kind.store(.none, .release);
            self.retry_abort.reset();
        }
        self.running.store(false, .release);

        // Close the race where input lands after the final yield poll but before
        // `running` becomes false.
        if (!self.shutting_down.load(.acquire) and self.hasQueuedInput()) self.startRun();
    }

    fn host(self: *AgentSession) loop.Host {
        return .{
            .ctx = self,
            .io = self.io,
            .gpa = self.gpa,
            .arena = self.message_arena_state.allocator(),
            .registry = self.tools,
            .aborted = &self.aborted,
            .scheduler_callbacks = .{
                .ctx = self,
                .on_started = onToolStarted,
                .on_update = onToolUpdate,
                .on_finished = onToolFinished,
            },
            .scheduler_authorization = .{ .ctx = self, .authorize_fn = authorizeTool },
            .scheduler_tool_filter = .{ .ctx = self, .enabled_fn = toolEnabled },
            .interrupt_mode = self.interrupt_mode,
            .intent_tracing = self.intent_tracing,
            .vtable = &host_vtable,
        };
    }

    const host_vtable: loop.HostVTable = .{
        .emit = hostEmit,
        .append = hostAppend,
        .perform_step = hostPerformStep,
        .finish_assistant = hostFinishAssistant,
        .emit_message_lifecycle = hostEmitMessageLifecycle,
        .emit_synthetic_tool = hostEmitSyntheticTool,
        .dequeue_steering = hostDequeueSteering,
        .dequeue_follow_ups = hostDequeueFollowUps,
        .dequeue_asides = hostDequeueAsides,
        .has_steering = hostHasSteering,
        .get_tool_choice = hostGetToolChoice,
        .discard_last_assistant = hostDiscardLastAssistant,
        .classify_unexpected_stop = hostClassifyUnexpectedStop,
        .batch_scope_changed = hostBatchScopeChanged,
        .now_ms = hostNowMs,
        .fail = hostFail,
    };

    fn hostEmit(raw: *anyopaque, event: events.AgentEvent) anyerror!void {
        const self: *AgentSession = @ptrCast(@alignCast(raw));
        return self.emit(event);
    }

    fn hostAppend(raw: *anyopaque, value: message.AgentMessage) anyerror!void {
        const self: *AgentSession = @ptrCast(@alignCast(raw));
        try self.messages.append(self.message_arena_state.allocator(), value);
        _ = try self.session_manager.appendMessage(value);
    }

    fn hostPerformStep(raw: *anyopaque, choice: ?ai.prompt.ToolChoice) anyerror!message.AssistantMessage {
        const self: *AgentSession = @ptrCast(@alignCast(raw));
        return self.performStep(choice);
    }

    fn hostFinishAssistant(raw: *anyopaque, value: message.AssistantMessage) anyerror!void {
        const self: *AgentSession = @ptrCast(@alignCast(raw));
        var id_buffer: [64]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "assistant-{d}-{d}", .{ self.generation.load(.acquire), self.step_number });
        var finished = try events.MessageFinished.initAssistant(self.gpa, id, value);
        defer finished.deinit(self.gpa);
        try self.emit(.{ .message_finished = finished });
        const model = self.catalogModel(value.provider, value.model);
        try self.emit(.{ .usage_updated = .{
            .usage = value.usage,
            .context_window = if (model) |catalog_model| catalog_model.contextWindow else null,
            .context_percent = contextPercent(value.usage, model),
        } });
        if (value.stop_reason == .@"error") {
            try self.emitFailure(value.error_message orelse "Provider step failed");
        } else if (value.stop_reason == .aborted) {
            try self.emitNotice(.info, value.error_message orelse "Request was aborted");
        }
    }

    fn hostEmitMessageLifecycle(raw: *anyopaque, value: message.AgentMessage) anyerror!void {
        const self: *AgentSession = @ptrCast(@alignCast(raw));
        return self.emitMessageLifecycle(value);
    }

    fn hostEmitSyntheticTool(
        raw: *anyopaque,
        call: message.ToolCallContent,
        result: message.ToolResultMessage,
    ) anyerror!void {
        const self: *AgentSession = @ptrCast(@alignCast(raw));
        try self.emitToolStarted(call);
        try self.emitToolFinished(call, result.is_error);
        try self.emitMessageLifecycle(.{ .tool_result = result });
    }

    fn hostDequeueSteering(raw: *anyopaque, arena: Allocator) anyerror![]const message.AgentMessage {
        const self: *AgentSession = @ptrCast(@alignCast(raw));
        return self.dequeuePromptMessages(arena, &self.steering_queue, self.steering_mode, true);
    }

    fn hostDequeueFollowUps(raw: *anyopaque, arena: Allocator) anyerror![]const message.AgentMessage {
        const self: *AgentSession = @ptrCast(@alignCast(raw));
        return self.dequeuePromptMessages(arena, &self.follow_up_queue, self.follow_up_mode, false);
    }

    fn hostDequeueAsides(raw: *anyopaque, arena: Allocator) anyerror![]const message.AgentMessage {
        const self: *AgentSession = @ptrCast(@alignCast(raw));
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        const output = try arena.alloc(message.AgentMessage, self.aside_queue.items.len);
        for (self.aside_queue.items, output) |encoded, *destination| {
            destination.* = try message.parse(arena, encoded);
            self.gpa.free(encoded);
        }
        self.aside_queue.clearRetainingCapacity();
        return output;
    }

    fn hostHasSteering(raw: ?*anyopaque) scheduler.SteeringState {
        const self: *AgentSession = @ptrCast(@alignCast(raw.?));
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        if (self.steering_queue.items.len == 0) return .{ .queued = false };
        for (self.steering_queue.items) |prompt| {
            if (prompt.attribution == .user and !prompt.synthetic) return .{ .queued = true, .source = .user };
        }
        return .{ .queued = true, .source = .system };
    }

    fn hostGetToolChoice(raw: *anyopaque) ?loop.ToolChoiceDirective {
        const self: *AgentSession = @ptrCast(@alignCast(raw));
        const resolver = self.tool_choice orelse return null;
        const directive = resolver.resolve_fn(resolver.ctx) orelse return null;
        return switch (directive) {
            .hard => |choice| if (hardChoiceActive(self, choice)) directive else null,
            .soft => |requirement| if (self.isToolEnabled(requirement.tool_name)) directive else null,
        };
    }

    fn hostDiscardLastAssistant(raw: *anyopaque) void {
        const self: *AgentSession = @ptrCast(@alignCast(raw));
        if (self.messages.items.len == 0) return;
        if (self.messages.items[self.messages.items.len - 1] != .assistant) return;
        _ = self.messages.pop();
        self.session_manager.moveLeafToParent() catch |err| self.recordCallbackError(err);
    }

    fn hostClassifyUnexpectedStop(raw: *anyopaque, text: []const u8) ?bool {
        const self: *AgentSession = @ptrCast(@alignCast(raw));
        const classifier = self.unexpected_stop_classifier orelse return null;
        if (countTextBlocks(self.messages.items[self.messages.items.len - 1].assistant) <= 1) {
            return classifier.classify_fn(classifier.ctx, text);
        }
        const arena = self.message_arena_state.allocator();
        const joined = joinAssistantText(arena, self.messages.items[self.messages.items.len - 1].assistant) catch |err| {
            self.recordCallbackError(err);
            return null;
        };
        return classifier.classify_fn(classifier.ctx, joined);
    }

    fn hostNowMs(raw: *anyopaque) i64 {
        const self: *AgentSession = @ptrCast(@alignCast(raw));
        return nowMs(self.io);
    }

    fn hostBatchScopeChanged(raw: *anyopaque, scope: ?*scheduler.CancelScope) void {
        const self: *AgentSession = @ptrCast(@alignCast(raw));
        self.active_mutex.lockUncancelable(self.io);
        self.active_scope = scope;
        self.active_mutex.unlock(self.io);
    }

    fn hostFail(raw: *anyopaque, text: []const u8) void {
        const self: *AgentSession = @ptrCast(@alignCast(raw));
        self.persistFailure(text);
    }

    fn performStep(self: *AgentSession, choice: ?ai.prompt.ToolChoice) !message.AssistantMessage {
        self.step_number += 1;
        var id_buffer: [64]u8 = undefined;
        const message_id = try std.fmt.bufPrint(&id_buffer, "assistant-{d}-{d}", .{ self.generation.load(.acquire), self.step_number });
        var started = try events.MessageStarted.init(self.gpa, message_id, .assistant);
        defer started.deinit(self.gpa);
        try self.emit(.{ .message_started = started });

        var retry_count: u8 = 0;
        while (true) {
            if (self.aborted.load(.acquire)) return self.abortedAssistant();
            const target = self.targetForAttempt(retry_count);
            const attempt = try self.performStepAttempt(target, choice, message_id);
            switch (attempt) {
                .assistant => |assistant| {
                    if (retry_count != 0) {
                        var outcome = try events.RetryOutcome.init(self.gpa, true, retry_count, null);
                        defer outcome.deinit(self.gpa);
                        try self.emit(.{ .auto_retry_finished = outcome });
                    }
                    return assistant;
                },
                .failure => |failure| {
                    if (!failure.retryable or retry_count >= self.retry.max_retries) {
                        if (retry_count != 0) {
                            var outcome = try events.RetryOutcome.init(self.gpa, false, retry_count, failure.text);
                            defer outcome.deinit(self.gpa);
                            try self.emit(.{ .auto_retry_finished = outcome });
                        }
                        return self.errorAssistant(target, failure.text);
                    }
                    retry_count += 1;
                    const next_target = self.targetForAttempt(retry_count);
                    const provider_wait_ms = failure.retry_after_ms orelse 0;
                    if (sameTarget(target, next_target) and
                        self.retry.max_delay_ms != 0 and
                        provider_wait_ms > self.retry.max_delay_ms)
                    {
                        const final_error = try std.fmt.allocPrint(
                            self.message_arena_state.allocator(),
                            "Provider requested {d}ms wait, exceeds retry.maxDelayMs ({d}ms). Original error: {s}",
                            .{ provider_wait_ms, self.retry.max_delay_ms, failure.text },
                        );
                        var outcome = try events.RetryOutcome.init(self.gpa, false, retry_count, final_error);
                        defer outcome.deinit(self.gpa);
                        try self.emit(.{ .auto_retry_finished = outcome });
                        return self.errorAssistant(target, final_error);
                    }
                    const delay_ms = if (sameTarget(target, next_target))
                        @max(retryDelay(self.retry, retry_count), provider_wait_ms)
                    else
                        0;
                    var info = try events.RetryInfo.init(
                        self.gpa,
                        retry_count,
                        self.retry.max_retries,
                        delay_ms,
                        failure.text,
                    );
                    defer info.deinit(self.gpa);
                    try self.emit(.{ .auto_retry_started = info });
                    const bounded: i64 = @intCast(@min(delay_ms, @as(u64, std.math.maxInt(i64))));
                    self.retry_abort.waitTimeout(self.io, .{ .duration = .{
                        .raw = .fromMilliseconds(bounded),
                        .clock = .awake,
                    } }) catch |err| switch (err) {
                        error.Timeout => continue,
                        error.Canceled => return error.Canceled,
                    };
                    return self.abortedAssistant();
                },
            }
        }
    }

    fn performStepAttempt(
        self: *AgentSession,
        target: ModelTarget,
        choice: ?ai.prompt.ToolChoice,
        message_id: []const u8,
    ) !AttemptResult {
        var call_arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer call_arena_state.deinit();
        const call_arena = call_arena_state.allocator();
        var diagnostics = provider.Diagnostics.init(self.gpa);
        defer diagnostics.deinit();

        const lower_options: lower.Options = .{
            .target_provider = target.provider_name,
            .target_model = target.model_id,
        };
        const live = self.liveCallSettings();
        const replay = try replay_policy.filterProviderReplayMessages(call_arena, self.messages.items, lower_options);
        const named_tools = try self.tools.buildNamedToolsWithOptions(
            call_arena,
            live.active_tools,
            self.intent_tracing,
        );
        const reasoning = reasoningEffort(live.thinking);
        const stop_conditions = [_]ai.StopCondition{ai.stepCount(1)};
        var result = ai.streamText(self.io, self.gpa, .{
            .model = target.language_model,
            .instructions = if (live.system_prompt.len == 0) null else .{ .text = live.system_prompt },
            .messages = replay,
            .tools = named_tools,
            .tool_choice = choice,
            .stop_when = &stop_conditions,
            .reasoning = reasoning,
            .max_output_tokens = live.max_output_tokens,
            .max_retries = 0,
            .diag = &diagnostics,
            .on_error = .{ .callback = observeStreamError },
        }) catch |err| return failureFromDiagnostics(self.message_arena_state.allocator(), &diagnostics, err);
        defer result.deinit(self.io);

        var capture: StepCapture = .{ .arena = call_arena };
        defer capture.deinit();
        const Driver = struct {
            fn drive(session: *AgentSession, stream: *ai.StreamTextResult, state: *StepCapture, id: []const u8) anyerror!void {
                while (try stream.next(session.io)) |part| switch (part) {
                    .text_delta => |delta| {
                        try state.text.appendSlice(state.arena, delta.text);
                        try session.emitTextDelta(id, delta.text, false);
                    },
                    .reasoning_delta => |delta| {
                        try state.reasoning.appendSlice(state.arena, delta.text);
                        try session.emitTextDelta(id, delta.text, true);
                    },
                    .tool_call => |call| try state.tool_calls.append(state.arena, call),
                    .abort => |abort| {
                        state.aborted = true;
                        state.abort_reason = if (abort.reason) |reason| try state.arena.dupe(u8, reason) else null;
                    },
                    .err => |stream_error| {
                        state.stream_error = try streamErrorText(state.arena, stream_error);
                    },
                    else => {},
                };
            }

            fn runAndSignal(
                session: *AgentSession,
                stream: *ai.StreamTextResult,
                state: *StepCapture,
                id: []const u8,
                completed: *std.Io.Event,
            ) anyerror!void {
                defer completed.set(session.io);
                return drive(session, stream, state, id);
            }
        };
        var completed: std.Io.Event = .unset;
        var future = try self.io.concurrent(Driver.runAndSignal, .{ self, &result, &capture, message_id, &completed });
        self.active_mutex.lockUncancelable(self.io);
        self.active_step = &future;
        self.active_mutex.unlock(self.io);

        try completed.wait(self.io);
        self.active_mutex.lockUncancelable(self.io);
        const owns_future = self.active_step == &future;
        if (owns_future) self.active_step = null;
        self.active_mutex.unlock(self.io);
        const drive_result = if (owns_future) future.await(self.io) else future.result;
        drive_result catch |err| {
            if (err == error.Canceled or capture.aborted or self.aborted.load(.acquire)) {
                return .{ .assistant = try self.capturedAbortedAssistant(target, &capture) };
            }
            return failureFromDiagnostics(self.message_arena_state.allocator(), &diagnostics, err);
        };
        if (capture.aborted or self.aborted.load(.acquire)) {
            return .{ .assistant = try self.capturedAbortedAssistant(target, &capture) };
        }

        const step = result.finalStep(self.io) catch |err| return failureFromDiagnostics(self.message_arena_state.allocator(), &diagnostics, err);
        var assistant = try raise.fromStep(self.message_arena_state.allocator(), step, .{
            .resolved_model = self.catalogModel(target.provider_name, target.model_id),
            .api = target.api,
            .timestamp_ms = nowMs(self.io),
            .error_message = capture.stream_error,
        });
        if (capture.stream_error != null and assistant.stop_reason != .aborted) assistant.stop_reason = .@"error";
        return .{ .assistant = assistant };
    }

    fn cancel(self: *AgentSession, reason: events.CancelReason) void {
        self.aborted.store(true, .release);
        self.abort_kind.store(switch (reason) {
            .user => .user,
            .shutdown => .shutdown,
            .deadline => .deadline,
            .superseded => .superseded,
            .other => .other,
        }, .release);
        self.retry_abort.set(self.io);
        loop.agent_pause_gate.wake(self.io);

        var cancel_error: ?anyerror = null;
        self.active_mutex.lockUncancelable(self.io);
        if (self.active_scope) |scope| scope.cancel(self.io, switch (reason) {
            .user => .run_user,
            .shutdown => .run_shutdown,
            .deadline => .run_deadline,
            .superseded => .run_superseded,
            .other => .run_other,
        });
        if (self.active_step) |future| {
            _ = future.cancel(self.io) catch |err| {
                cancel_error = err;
            };
            self.active_step = null;
        }
        self.active_mutex.unlock(self.io);
        if (cancel_error) |err| self.recordCallbackError(err);
    }

    fn takeInitialMessages(self: *AgentSession) ![]const message.AgentMessage {
        const arena = self.message_arena_state.allocator();
        const initial = try self.dequeuePromptMessages(arena, &self.initial_queue, .all, false);
        if (initial.len != 0 or self.hasSteering()) return initial;
        return self.dequeuePromptMessages(arena, &self.follow_up_queue, self.follow_up_mode, false);
    }

    fn dequeuePromptMessages(
        self: *AgentSession,
        arena: Allocator,
        queue: *std.ArrayList(events.OwnedPrompt),
        mode: QueueMode,
        steering: bool,
    ) ![]const message.AgentMessage {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        const count: usize = switch (mode) {
            .one_at_a_time => @min(queue.items.len, 1),
            .all => queue.items.len,
        };
        const output = try arena.alloc(message.AgentMessage, count);
        for (output) |*destination| {
            var prompt = queue.orderedRemove(0);
            destination.* = try promptToMessage(arena, prompt, steering, nowMs(self.io));
            prompt.deinit(self.gpa);
        }
        return output;
    }

    fn enqueuePrompt(self: *AgentSession, queue: *std.ArrayList(events.OwnedPrompt), prompt: events.OwnedPrompt) !void {
        const copy = try prompt.dupeInto(self.gpa);
        errdefer {
            var owned = copy;
            owned.deinit(self.gpa);
        }
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        try queue.append(self.gpa, copy);
    }

    fn resolveApproval(self: *AgentSession, decision: events.ApprovalDecision) !void {
        const reason = if (decision.reason) |value| try self.gpa.dupe(u8, value) else null;
        self.state_mutex.lockUncancelable(self.io);
        for (self.pending_approvals.items) |pending| {
            if (!std.mem.eql(u8, pending.request_id, decision.request_id)) continue;
            if (pending.approved != null) {
                self.state_mutex.unlock(self.io);
                if (reason) |value| self.gpa.free(value);
                return;
            }
            pending.approved = decision.approved;
            pending.reason = reason;
            pending.decided.set(self.io);
            self.state_mutex.unlock(self.io);
            return;
        }
        self.state_mutex.unlock(self.io);
        defer if (reason) |value| self.gpa.free(value);
        try self.emitNotice(.warning, "No approval request is pending");
    }

    fn hasQueuedInput(self: *AgentSession) bool {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        return self.initial_queue.items.len != 0 or self.steering_queue.items.len != 0 or
            self.follow_up_queue.items.len != 0 or self.aside_queue.items.len != 0;
    }

    fn hasSteering(self: *AgentSession) bool {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        return self.steering_queue.items.len != 0;
    }

    fn dequeueLast(self: *AgentSession) !void {
        self.state_mutex.lockUncancelable(self.io);
        var prompt: ?events.OwnedPrompt = if (self.steering_queue.items.len != 0)
            self.steering_queue.pop()
        else if (self.follow_up_queue.items.len != 0)
            self.follow_up_queue.pop()
        else
            null;
        self.state_mutex.unlock(self.io);
        if (prompt) |*value| {
            defer value.deinit(self.gpa);
            try self.emitNotice(.info, value.text);
        }
    }

    fn changeModel(self: *AgentSession, selection: events.ModelSelection) !void {
        const resolver = self.resolve_model orelse {
            try self.emitNotice(.warning, "No model resolver is configured");
            return;
        };
        const target = resolver.resolve_fn(resolver.ctx, selection.provider, selection.model) orelse {
            try self.emitNotice(.@"error", "Requested model is unavailable");
            return;
        };
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        const owned_target = try cloneTarget(self.config_arena_state.allocator(), target);
        const owned_role = if (selection.role) |role|
            try self.config_arena_state.allocator().dupe(u8, role)
        else
            null;
        self.current_model = owned_target;
        self.current_model_role = owned_role;
        const persisted_model = try std.fmt.allocPrint(
            self.gpa,
            "{s}/{s}",
            .{ selection.provider, selection.model },
        );
        defer self.gpa.free(persisted_model);
        _ = try self.session_manager.appendModelChange(persisted_model, selection.role);
    }

    fn liveCallSettings(self: *AgentSession) LiveCallSettings {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        return .{
            .system_prompt = self.system_prompt,
            .active_tools = self.active_tools,
            .thinking = self.thinking,
            .max_output_tokens = self.max_output_tokens,
        };
    }

    fn restoreFromSession(self: *AgentSession) !void {
        const arena = self.message_arena_state.allocator();
        const path_entries = try self.session_manager.activePathAlloc(self.gpa);
        defer self.gpa.free(path_entries);
        var selected_model: ?[]const u8 = null;
        var selected_role: ?[]const u8 = null;
        var selected_thinking: ?catalog.ThinkingLevel = null;
        for (path_entries) |entry| switch (entry) {
            .message => |stored| {
                const encoded = try message.stringifyAlloc(arena, stored.message);
                try self.messages.append(arena, try message.parse(arena, encoded));
            },
            .model_change => |change| {
                selected_model = change.model;
                selected_role = change.role;
            },
            .thinking_level_change => |change| {
                const configured = switch (change.configured) {
                    .value => |value| value,
                    else => switch (change.thinkingLevel) {
                        .value => |value| value,
                        else => null,
                    },
                };
                if (configured) |value| selected_thinking = std.meta.stringToEnum(catalog.ThinkingLevel, value);
            },
            else => {},
        };
        if (self.restore_thinking_from_session) {
            if (selected_thinking) |value| self.thinking = value;
        }
        if (self.restore_model_from_session) {
            if (selected_model) |combined| {
                if (std.mem.indexOfScalar(u8, combined, '/')) |separator| {
                    const provider_name = combined[0..separator];
                    const model_id = combined[separator + 1 ..];
                    if (self.resolve_model) |resolver| if (resolver.resolve_fn(resolver.ctx, provider_name, model_id)) |target| {
                        self.current_model = try cloneTarget(self.config_arena_state.allocator(), target);
                        self.current_model_role = if (selected_role) |role|
                            try self.config_arena_state.allocator().dupe(u8, role)
                        else
                            null;
                    };
                }
            }
        }
    }

    fn currentTarget(self: *AgentSession) ModelTarget {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        return self.current_model;
    }

    fn isToolEnabled(self: *AgentSession, name: []const u8) bool {
        if (self.tools.get(name) == null) return false;
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        const active = self.active_tools orelse return true;
        for (active) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
        return false;
    }

    fn targetForAttempt(self: *AgentSession, attempt: u8) ModelTarget {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        if (attempt == 0) return self.current_model;
        const candidates = if (self.current_model_role) |role| blk: {
            for (self.fallback_chains) |chain| {
                if (std.mem.eql(u8, chain.role, role)) break :blk chain.models;
            }
            break :blk self.fallback_models;
        } else self.fallback_models;
        if (candidates.len == 0) return self.current_model;
        const index = @min(@as(usize, attempt - 1), candidates.len - 1);
        return candidates[index];
    }

    fn catalogModel(self: *AgentSession, provider_name: []const u8, model_id: []const u8) ?*const catalog.Model {
        return self.catalog_registry.get(provider_name, model_id);
    }

    fn capturedAbortedAssistant(
        self: *AgentSession,
        target: ModelTarget,
        capture: *const StepCapture,
    ) !message.AssistantMessage {
        const arena = self.message_arena_state.allocator();
        var blocks: std.ArrayList(message.AssistantBlock) = .empty;
        defer blocks.deinit(arena);
        if (capture.reasoning.items.len != 0) {
            try blocks.append(arena, .{ .thinking = .{ .thinking = try arena.dupe(u8, capture.reasoning.items) } });
        }
        if (capture.text.items.len != 0) {
            try blocks.append(arena, .{ .text = .{ .text = try arena.dupe(u8, capture.text.items) } });
        }
        for (capture.tool_calls.items) |call| {
            try blocks.append(arena, .{ .tool_call = .{
                .id = try arena.dupe(u8, call.tool_call_id),
                .name = try arena.dupe(u8, call.tool_name),
                .arguments = try provider_utils.cloneJsonValue(arena, call.input),
            } });
        }
        return .{
            .content = try blocks.toOwnedSlice(arena),
            .api = try arena.dupe(u8, target.api orelse target.provider_name),
            .provider = try arena.dupe(u8, target.provider_name),
            .model = try arena.dupe(u8, target.model_id),
            .usage = .{},
            .stop_reason = .aborted,
            .error_message = try arena.dupe(u8, self.abortText(capture.abort_reason)),
            .timestamp = nowMs(self.io),
        };
    }

    fn abortedAssistant(self: *AgentSession) !message.AssistantMessage {
        return self.capturedAbortedAssistant(self.currentTarget(), &.{ .arena = self.message_arena_state.allocator() });
    }

    fn errorAssistant(self: *AgentSession, target: ModelTarget, text: []const u8) !message.AssistantMessage {
        const arena = self.message_arena_state.allocator();
        return .{
            .content = &.{},
            .api = try arena.dupe(u8, target.api orelse target.provider_name),
            .provider = try arena.dupe(u8, target.provider_name),
            .model = try arena.dupe(u8, target.model_id),
            .usage = .{},
            .stop_reason = .@"error",
            .error_message = try arena.dupe(u8, text),
            .timestamp = nowMs(self.io),
        };
    }

    fn abortText(self: *const AgentSession, provider_reason: ?[]const u8) []const u8 {
        if (provider_reason) |value| if (value.len != 0) return value;
        return switch (self.abort_kind.load(.acquire)) {
            .user => "Interrupted by user",
            .shutdown => "Shutdown requested",
            .deadline => "Deadline exceeded",
            .superseded => "Superseded",
            .other => "Request was aborted",
            .none => "Request was aborted",
        };
    }

    fn persistFailure(self: *AgentSession, text: []const u8) void {
        const assistant = self.errorAssistant(self.currentTarget(), text) catch |err| {
            self.recordCallbackError(err);
            self.emitFailure(text) catch |emit_err| self.recordCallbackError(emit_err);
            return;
        };
        self.messages.append(self.message_arena_state.allocator(), .{ .assistant = assistant }) catch |err| {
            self.recordCallbackError(err);
        };
        if (self.session_manager.appendMessage(.{ .assistant = assistant })) |_| {} else |err| self.recordCallbackError(err);
        self.emitMessageLifecycle(.{ .assistant = assistant }) catch |err| self.recordCallbackError(err);
        self.emitFailure(text) catch |err| self.recordCallbackError(err);
    }

    fn recordCallbackError(self: *AgentSession, err: anyerror) void {
        self.active_mutex.lockUncancelable(self.io);
        if (self.callback_error == null) self.callback_error = err;
        self.active_mutex.unlock(self.io);
    }

    fn emit(self: *AgentSession, event: events.AgentEvent) !void {
        return self.event_outbox.push(self.io, event);
    }

    fn emitNotice(self: *AgentSession, level: events.NoticeLevel, text: []const u8) !void {
        var notice = try events.Notice.init(self.gpa, level, text);
        defer notice.deinit(self.gpa);
        try self.emit(.{ .notice = notice });
    }

    fn emitFailure(self: *AgentSession, text: []const u8) !void {
        var failure = try events.OwnedError.init(self.gpa, null, text);
        defer failure.deinit(self.gpa);
        try self.emit(.{ .failed = failure });
    }

    fn emitMessageLifecycle(self: *AgentSession, value: message.AgentMessage) !void {
        var id_buffer: [96]u8 = undefined;
        const timestamp = messageTimestamp(value);
        const role = messageRole(value);
        const id = try std.fmt.bufPrint(&id_buffer, "{s}-{d}", .{ @tagName(role), timestamp });
        var started = try events.MessageStarted.init(self.gpa, id, role);
        defer started.deinit(self.gpa);
        try self.emit(.{ .message_started = started });
        var finished = if (value == .assistant)
            try events.MessageFinished.initAssistant(self.gpa, id, value.assistant)
        else
            try events.MessageFinished.init(self.gpa, id, null, &.{}, null);
        defer finished.deinit(self.gpa);
        try self.emit(.{ .message_finished = finished });
    }

    fn emitTextDelta(self: *AgentSession, id: []const u8, text: []const u8, reasoning: bool) !void {
        var delta = try events.TextDelta.init(self.gpa, id, text);
        defer delta.deinit(self.gpa);
        try self.emit(if (reasoning) .{ .reasoning_delta = delta } else .{ .text_delta = delta });
    }

    fn emitToolStarted(self: *AgentSession, call: message.ToolCallContent) !void {
        const input_json = try provider.wire.stringifyAlloc(self.gpa, call.arguments);
        defer self.gpa.free(input_json);
        var started = try events.ToolStarted.init(self.gpa, call.id, call.name, input_json);
        defer started.deinit(self.gpa);
        try self.emit(.{ .tool_started = started });
    }

    fn emitToolFinished(self: *AgentSession, call: message.ToolCallContent, is_error: bool) !void {
        var finished = try events.ToolFinished.init(self.gpa, call.id, call.name, is_error, null);
        defer finished.deinit(self.gpa);
        try self.emit(.{ .tool_finished = finished });
    }

    fn onToolStarted(raw: ?*anyopaque, call: message.ToolCallContent) void {
        const self: *AgentSession = @ptrCast(@alignCast(raw.?));
        self.emitToolStarted(call) catch |err| self.recordCallbackError(err);
    }

    fn onToolUpdate(raw: ?*anyopaque, call: message.ToolCallContent, partial: tool_api.ToolOutcome) void {
        const self: *AgentSession = @ptrCast(@alignCast(raw.?));
        for (partial.content) |block| switch (block) {
            .text => |text| {
                var delta = events.ToolOutputDelta.init(self.gpa, call.id, text) catch |err| {
                    self.recordCallbackError(err);
                    return;
                };
                defer delta.deinit(self.gpa);
                self.emit(.{ .tool_output = delta }) catch |err| self.recordCallbackError(err);
            },
            .image => {},
        };
    }

    fn onToolFinished(raw: ?*anyopaque, call: message.ToolCallContent, outcome: tool_api.ToolOutcome) void {
        const self: *AgentSession = @ptrCast(@alignCast(raw.?));
        self.emitToolFinished(call, outcome.is_error) catch |err| self.recordCallbackError(err);
    }

    fn toolEnabled(raw: ?*anyopaque, name: []const u8) bool {
        const self: *AgentSession = @ptrCast(@alignCast(raw.?));
        return self.isToolEnabled(name);
    }

    fn authorizeTool(
        raw: ?*anyopaque,
        io: std.Io,
        arena: Allocator,
        call: message.ToolCallContent,
        declaration: tool_api.Tool,
        scope: *scheduler.CancelScope,
    ) anyerror!scheduler.AuthorizationResult {
        const self: *AgentSession = @ptrCast(@alignCast(raw.?));
        const user_policy = if (self.approval_policy) |resolver|
            resolver.resolve_fn(resolver.ctx, declaration.name)
        else
            null;
        const resolved = approval.resolve(declaration.approval, self.approval_mode, user_policy);
        switch (resolved) {
            .allow => return .allow,
            .deny => return .{ .deny = try std.fmt.allocPrint(
                arena,
                "Tool \"{s}\" is blocked by user policy.\nTo allow: remove \"tools.approval.{s}: deny\" from config.",
                .{ declaration.name, declaration.name },
            ) },
            .prompt => |prompt| {
                if (scope.isCancelled()) return .aborted;
                const pending = try self.gpa.create(PendingApproval);
                var initialized = false;
                var registered = false;
                defer {
                    if (registered) self.removePendingApproval(pending);
                    if (initialized) pending.deinit(self.gpa);
                    self.gpa.destroy(pending);
                }
                pending.* = .{
                    .request_id = try std.fmt.allocPrint(
                        self.gpa,
                        "approval-{d}-{s}",
                        .{ self.generation.load(.acquire), call.id },
                    ),
                };
                initialized = true;

                self.state_mutex.lockUncancelable(io);
                self.pending_approvals.append(self.gpa, pending) catch |err| {
                    self.state_mutex.unlock(io);
                    return err;
                };
                registered = true;
                self.state_mutex.unlock(io);

                const details = try declaration.formatApprovalDetails(arena, call.arguments);
                var request = try events.ApprovalRequest.init(
                    self.gpa,
                    pending.request_id,
                    call.id,
                    declaration.name,
                    prompt.reason,
                    details,
                );
                defer request.deinit(self.gpa);
                try self.emit(.{ .approval_requested = request });

                const Selected = union(enum) {
                    decided: std.Io.Cancelable!void,
                    cancelled: std.Io.Cancelable!void,
                };
                var buffer: [2]Selected = undefined;
                var select: std.Io.Select(Selected) = .init(io, &buffer);
                defer select.cancelDiscard();
                try select.concurrent(.decided, std.Io.Event.wait, .{ &pending.decided, io });
                try select.concurrent(.cancelled, std.Io.Event.wait, .{ &scope.event, io });
                const selected = try select.await();
                return switch (selected) {
                    .decided => |result| blk: {
                        try result;
                        if (pending.approved == true) break :blk .allow;
                        break :blk .{ .deny = if (pending.reason) |reason|
                            try arena.dupe(u8, reason)
                        else
                            "Tool execution was blocked" };
                    },
                    .cancelled => |result| blk: {
                        try result;
                        break :blk .aborted;
                    },
                };
            },
        }
    }

    fn removePendingApproval(self: *AgentSession, pending: *PendingApproval) void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        for (self.pending_approvals.items, 0..) |candidate, index| {
            if (candidate != pending) continue;
            _ = self.pending_approvals.orderedRemove(index);
            return;
        }
    }
};

fn cloneTarget(arena: Allocator, source: ModelTarget) !ModelTarget {
    return .{
        .language_model = source.language_model,
        .provider_name = try arena.dupe(u8, source.provider_name),
        .model_id = try arena.dupe(u8, source.model_id),
        .api = if (source.api) |value| try arena.dupe(u8, value) else null,
    };
}

fn sameTarget(first: ModelTarget, second: ModelTarget) bool {
    return std.mem.eql(u8, first.provider_name, second.provider_name) and
        std.mem.eql(u8, first.model_id, second.model_id);
}

fn promptToMessage(
    arena: Allocator,
    prompt: events.OwnedPrompt,
    steering: bool,
    timestamp: i64,
) !message.AgentMessage {
    const content: message.TextImageContent = if (prompt.images.len == 0)
        .{ .string = try arena.dupe(u8, prompt.text) }
    else blk: {
        const blocks = try arena.alloc(message.TextImageBlock, prompt.images.len + 1);
        blocks[0] = .{ .text = .{ .text = try arena.dupe(u8, prompt.text) } };
        for (prompt.images, blocks[1..]) |image, *block| block.* = .{ .image = .{
            .data = try arena.dupe(u8, image.data),
            .mime_type = try arena.dupe(u8, image.mime_type),
            .detail = image.detail,
        } };
        break :blk .{ .blocks = blocks };
    };
    if (prompt.synthetic) return .{ .developer = .{
        .content = content,
        .attribution = prompt.attribution,
        .timestamp = timestamp,
    } };
    return .{ .user = .{
        .content = content,
        .synthetic = false,
        .steering = steering,
        .attribution = prompt.attribution,
        .timestamp = timestamp,
    } };
}

fn deinitPromptQueue(allocator: Allocator, queue: *std.ArrayList(events.OwnedPrompt)) void {
    for (queue.items) |*prompt| prompt.deinit(allocator);
    queue.deinit(allocator);
}

fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

fn retryDelay(options: RetryOptions, attempt: u8) u64 {
    if (attempt == 0 or options.base_delay_ms == 0) return 0;
    const shift: u6 = @intCast(@min(attempt - 1, 63));
    const multiplied = std.math.shlExact(u64, options.base_delay_ms, shift) catch std.math.maxInt(u64);
    return @min(multiplied, options.backoff_cap_ms);
}

fn reasoningEffort(level: catalog.ThinkingLevel) ?provider.ReasoningEffort {
    return switch (level) {
        .off => null,
        .minimal => .minimal,
        .low => .low,
        .medium => .medium,
        .high => .high,
        .xhigh, .max, .ultra => .xhigh,
    };
}

fn failureFromDiagnostics(arena: Allocator, diagnostics: *const provider.Diagnostics, err: anyerror) !AttemptResult {
    const text = if (diagnostics.available)
        try diagnostics.message(arena)
    else
        try arena.dupe(u8, @errorName(err));
    if (diagnostics.available) switch (diagnostics.payload) {
        .api_call => |failure| return .{ .failure = .{
            .retryable = failure.is_retryable,
            .text = text,
            .retry_after_ms = retryAfterMilliseconds(failure.response_headers),
        } },
        else => {},
    };
    return .{ .failure = .{ .retryable = false, .text = text } };
}

fn retryAfterMilliseconds(headers: []const provider.Header) ?u64 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "retry-after-ms")) {
            return std.fmt.parseInt(u64, std.mem.trim(u8, header.value, " \t"), 10) catch null;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
            const seconds = std.fmt.parseFloat(f64, std.mem.trim(u8, header.value, " \t")) catch continue;
            if (!std.math.isFinite(seconds) or seconds < 0) continue;
            const milliseconds = seconds * std.time.ms_per_s;
            if (milliseconds >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) return std.math.maxInt(u64);
            return @intFromFloat(@ceil(milliseconds));
        }
    }
    return null;
}

fn streamErrorText(arena: Allocator, value: ai.stream.parts.StreamError) ![]const u8 {
    if (value.error_value == .object) {
        if (value.error_value.object.get("message")) |message_value| {
            if (message_value == .string) return arena.dupe(u8, message_value.string);
        }
    }
    return provider.wire.stringifyAlloc(arena, value.error_value);
}

fn messageTimestamp(value: message.AgentMessage) i64 {
    return switch (value) {
        inline else => |payload| if (@hasField(@TypeOf(payload), "timestamp")) payload.timestamp else 0,
    };
}

fn messageRole(value: message.AgentMessage) events.MessageRole {
    return switch (value) {
        .user => .user,
        .developer => .developer,
        .assistant => .assistant,
        .tool_result => .tool_result,
        else => .custom,
    };
}

fn contextPercent(usage: message.Usage, model: ?*const catalog.Model) ?f64 {
    const window = (model orelse return null).contextWindow orelse return null;
    const total = usage.total_tokens orelse return null;
    if (window == 0) return null;
    return @as(f64, @floatFromInt(total)) * 100.0 / @as(f64, @floatFromInt(window));
}

fn hardChoiceActive(session: *AgentSession, choice: ai.prompt.ToolChoice) bool {
    return switch (choice) {
        .named => |name| session.isToolEnabled(name),
        else => true,
    };
}

fn countTextBlocks(assistant: message.AssistantMessage) usize {
    var count: usize = 0;
    for (assistant.content) |block| if (block == .text) {
        if (std.mem.trim(u8, block.text.text, " \t\r\n").len != 0) count += 1;
    };
    return count;
}

fn joinAssistantText(arena: Allocator, assistant: message.AssistantMessage) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(arena);
    for (assistant.content) |block| switch (block) {
        .text => |text| {
            if (std.mem.trim(u8, text.text, " \t\r\n").len == 0) continue;
            if (output.items.len != 0) try output.append(arena, '\n');
            try output.appendSlice(arena, text.text);
        },
        else => {},
    };
    return output.toOwnedSlice(arena);
}

/// The driver consumes `.err` parts and turns them into assistant data. An
/// explicit callback prevents ai.zig's fallback logger from duplicating that
/// user-visible error on stderr.
fn observeStreamError(_: ?*anyopaque, _: *const ai.stream_text.StreamErrorEvent) anyerror!void {}

fn drainRun(io: std.Io, allocator: Allocator, session: *AgentSession) !void {
    while (try session.outbox().pop(io)) |owned_event| {
        var event = owned_event;
        const finished = event == .run_finished;
        event.deinit(allocator);
        if (finished) return;
    }
    return error.EventOutboxClosed;
}

test "prompt command queues an initial turn while a run is active" {
    const openai_compatible = @import("openai_compatible");
    const mock_transport = @import("../testkit/mock_transport.zig");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var mock = mock_transport.MockTransport.init(&.{});
    const factory = openai_compatible.createOpenAiCompatible(.{
        .provider_name = "phase-2b-test",
        .base_url = "https://example.test/v1",
        .api_key = "dummy-key",
        .transport = mock.transport(),
    });
    var chat = try factory.chatModel("smoke-model", null);
    var registry = tool_api.ToolRegistry.init(allocator);
    defer registry.deinit();
    var session = try AgentSession.init(allocator, io, .{
        .model = .{
            .language_model = .{ .model = chat.languageModel() },
            .provider_name = "phase-2b-test",
            .model_id = "smoke-model",
        },
        .tools = &registry,
    });
    defer session.deinit();
    session.running.store(true, .release);
    defer session.running.store(false, .release);
    var prompt = try events.OwnedPrompt.init(allocator, "next turn", &.{}, false, .user);
    defer prompt.deinit(allocator);

    try session.handlePrompt(prompt);

    session.state_mutex.lockUncancelable(io);
    defer session.state_mutex.unlock(io);
    try std.testing.expectEqual(@as(usize, 1), session.initial_queue.items.len);
    try std.testing.expectEqualStrings("next turn", session.initial_queue.items[0].text);
    try std.testing.expectEqual(@as(usize, 0), session.steering_queue.items.len);
    try std.testing.expect(session.outbox().tryPop(io) == null);
}

test "persisted internal failure emits a terminal assistant event before failed" {
    const openai_compatible = @import("openai_compatible");
    const mock_transport = @import("../testkit/mock_transport.zig");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var mock = mock_transport.MockTransport.init(&.{});
    const factory = openai_compatible.createOpenAiCompatible(.{
        .provider_name = "phase-2b-test",
        .base_url = "https://example.test/v1",
        .api_key = "dummy-key",
        .transport = mock.transport(),
    });
    var chat = try factory.chatModel("smoke-model", null);
    var registry = tool_api.ToolRegistry.init(allocator);
    defer registry.deinit();
    var session = try AgentSession.init(allocator, io, .{
        .model = .{
            .language_model = .{ .model = chat.languageModel() },
            .provider_name = "phase-2b-test",
            .model_id = "smoke-model",
        },
        .tools = &registry,
    });
    defer session.deinit();

    session.persistFailure("persistence write failed");

    var started = session.outbox().tryPop(io).?;
    defer started.deinit(allocator);
    try std.testing.expect(started == .message_started);
    var finished = session.outbox().tryPop(io).?;
    defer finished.deinit(allocator);
    try std.testing.expect(finished == .message_finished);
    try std.testing.expectEqual(message.StopReason.@"error", finished.message_finished.stop_reason.?);
    try std.testing.expectEqualStrings("persistence write failed", finished.message_finished.error_message.?);
    var failed = session.outbox().tryPop(io).?;
    defer failed.deinit(allocator);
    try std.testing.expect(failed == .failed);
    try std.testing.expectEqualStrings("persistence write failed", failed.failed.message);
    try std.testing.expect(session.outbox().tryPop(io) == null);
    try std.testing.expectEqual(@as(usize, 1), session.messagesBorrowed().len);
    try std.testing.expectEqual(message.StopReason.@"error", session.messagesBorrowed()[0].assistant.stop_reason);
}

test "agent retry delay uses exact exponential defaults and cap" {
    try std.testing.expectEqual(@as(u64, 500), retryDelay(.{}, 1));
    try std.testing.expectEqual(@as(u64, 1_000), retryDelay(.{}, 2));
    try std.testing.expectEqual(@as(u64, loop.RETRY_BACKOFF_MAX_DELAY_MS), retryDelay(.{}, 20));
    try std.testing.expectEqual(
        @as(?u64, 1_250),
        retryAfterMilliseconds(&.{.{ .name = "Retry-After", .value = "1.25" }}),
    );
    try std.testing.expectEqual(
        @as(?u64, 300_001),
        retryAfterMilliseconds(&.{.{ .name = "retry-after-ms", .value = "300001" }}),
    );
}

fn exportEnvValue(contents: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export ")) {
            line = std.mem.trim(u8, line["export ".len..], " \t");
        }
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..separator], " \t"), name)) continue;
        var value = std.mem.trim(u8, line[separator + 1 ..], " \t\r");
        if (value.len >= 2 and
            ((value[0] == '"' and value[value.len - 1] == '"') or
                (value[0] == '\'' and value[value.len - 1] == '\'')))
        {
            value = value[1 .. value.len - 1];
        }
        return if (value.len == 0) null else value;
    }
    return null;
}

fn loadAnthropicApiKey(allocator: Allocator, io: std.Io) ![]u8 {
    const env_path = "/home/autark/src/rctr/.env";
    const file_contents = std.Io.Dir.cwd().readFileAlloc(
        io,
        env_path,
        allocator,
        .limited(1024 * 1024),
    ) catch null;
    if (file_contents) |contents| {
        defer allocator.free(contents);
        if (exportEnvValue(contents, "ANTHROPIC_API_KEY")) |value| return allocator.dupe(u8, value);
    }
    return std.process.Environ.getAlloc(std.testing.environ, allocator, "ANTHROPIC_API_KEY") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("live provider smoke requires ANTHROPIC_API_KEY in the configured env file or process environment\n", .{});
            return error.AnthropicApiKeyUnavailable;
        },
        else => return err,
    };
}

test "env file parser accepts export quotes comments and blanks" {
    const fixture = "# comment\n\n export ANTHROPIC_API_KEY = \"quoted-value\"\nOTHER=value\n";
    try std.testing.expectEqualStrings("quoted-value", exportEnvValue(fixture, "ANTHROPIC_API_KEY").?);
    try std.testing.expect(exportEnvValue(fixture, "MISSING") == null);
}

test "live AgentSession Anthropic read-tool turn" {
    if (!build_options.live) return error.SkipZigTest;

    const anthropic = @import("anthropic");
    const provider_utils_http = @import("provider_utils");
    const read_tool = @import("../tools/read.zig");
    const tool_state = @import("../tools/session_state.zig");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const api_key = try loadAnthropicApiKey(allocator, io);
    defer allocator.free(api_key);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "marker.txt", .data = "PI_ZIG_LIVE_MARKER\n" });
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_length = try tmp.dir.realPath(io, &cwd_buffer);
    const cwd = cwd_buffer[0..cwd_length];
    var state = try tool_state.SessionState.init(allocator, io, .{ .cwd = cwd });
    defer state.deinit();
    var registry = tool_api.ToolRegistry.init(allocator);
    defer registry.deinit();
    var declaration = read_tool.tool;
    declaration.ctx = &state;
    try registry.add(declaration);

    var client = provider_utils_http.HttpClientTransport.init(allocator, io);
    defer client.deinit();
    const factory = try anthropic.createAnthropic(.{
        .api_key = api_key,
        .transport = client.transport(),
    });
    const model_id = "claude-haiku-4-5-20251001";
    var chat = try factory.messages(model_id, null);
    const ForceRead = struct {
        calls: std.atomic.Value(u8) = .init(0),

        fn resolve(raw: ?*anyopaque) ?loop.ToolChoiceDirective {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.calls.fetchAdd(1, .acq_rel) != 0) return null;
            return .{ .hard = .{ .named = "read" } };
        }
    };
    var force_read: ForceRead = .{};
    var session = try AgentSession.init(allocator, io, .{
        .model = .{
            .language_model = .{ .model = chat.languageModel() },
            .provider_name = "anthropic",
            .model_id = model_id,
            .api = "anthropic-messages",
        },
        .system_prompt = "Use the read tool for marker.txt. Then answer with the marker word from the file and no explanation.",
        .tools = &registry,
        .thinking = .off,
        .tool_choice = .{ .ctx = &force_read, .resolve_fn = ForceRead.resolve },
        .max_output_tokens = 128,
    });
    defer session.deinit();
    var runner = try io.concurrent(AgentSession.run, .{&session});
    var prompt = try events.OwnedPrompt.init(allocator, "Read marker.txt and return its marker word.", &.{}, false, .user);
    defer prompt.deinit(allocator);
    try session.inbox().push(io, .{ .prompt = prompt });

    const Tag = std.meta.Tag(events.AgentEvent);
    var tags: std.ArrayList(Tag) = .empty;
    defer tags.deinit(allocator);
    while (try session.outbox().pop(io)) |owned_event| {
        var event = owned_event;
        const tag = std.meta.activeTag(event);
        try tags.append(allocator, tag);
        const finished = tag == .run_finished;
        event.deinit(allocator);
        if (finished) break;
    }
    try session.inbox().push(io, .shutdown);
    try runner.await(io);

    var tool_call_count: usize = 0;
    var paired_result_count: usize = 0;
    var total_usage: message.Usage = .{};
    var final_text: []const u8 = "";
    for (session.messagesBorrowed()) |stored| switch (stored) {
        .assistant => |assistant| {
            for (assistant.content) |block| switch (block) {
                .tool_call => |call| {
                    tool_call_count += 1;
                    for (session.messagesBorrowed()) |candidate| if (candidate == .tool_result and
                        std.mem.eql(u8, candidate.tool_result.tool_call_id, call.id))
                    {
                        paired_result_count += 1;
                        break;
                    };
                },
                .text => |text| {
                    if (text.text.len != 0) final_text = text.text;
                },
                else => {},
            };
            addTestUsage(&total_usage, assistant.usage);
            const model = (try catalog.getBundledModel("anthropic", model_id)).?;
            var recomputed = assistant.usage;
            const expected_cost = catalog.calculateCost(model, &recomputed);
            try std.testing.expectApproxEqAbs(expected_cost.total, assistant.usage.cost.total, 1e-12);
        },
        else => {},
    };
    try std.testing.expect(tool_call_count >= 1);
    try std.testing.expectEqual(tool_call_count, paired_result_count);
    try std.testing.expect(final_text.len != 0);
    try std.testing.expect(std.mem.indexOf(u8, final_text, "PI_ZIG_LIVE_MARKER") != null);
    try std.testing.expect(total_usage.input + total_usage.output + total_usage.cache_read + total_usage.cache_write > 0);
    try expectOrderedTags(tags.items, &.{ .run_started, .tool_started, .tool_finished, .run_finished });
}

fn addTestUsage(total: *message.Usage, value: message.Usage) void {
    total.input += value.input;
    total.output += value.output;
    total.cache_read += value.cache_read;
    total.cache_write += value.cache_write;
}

fn expectOrderedTags(actual: []const std.meta.Tag(events.AgentEvent), expected: []const std.meta.Tag(events.AgentEvent)) !void {
    var index: usize = 0;
    for (actual) |tag| if (index < expected.len and tag == expected[index]) {
        index += 1;
    };
    try std.testing.expectEqual(expected.len, index);
}

test "loop integration runs one model step at a time around a client tool" {
    const openai_compatible = @import("openai_compatible");
    const mock_transport = @import("../testkit/mock_transport.zig");
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var temp_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temp_path_length = try tmp.dir.realPath(io, &temp_path_buffer);
    const temp_root = temp_path_buffer[0..temp_path_length];
    var persistent = try session_manager.SessionManager.create(allocator, io, temp_root, .{
        .path_options = .{
            .agent_dir = temp_root,
            .home = temp_root,
            .temp_dir = "/tmp",
        },
    });
    defer persistent.deinit();
    const tool_sse =
        "data: {\"id\":\"chatcmpl-tool\",\"created\":1711115037,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-1\",\"type\":\"function\",\"function\":{\"name\":\"echo\",\"arguments\":\"{\\\"value\\\":\\\"hello\\\"}\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":2,\"total_tokens\":7}}\n\n" ++
        "data: [DONE]\n\n";
    const final_sse =
        "data: {\"id\":\"chatcmpl-final\",\"created\":1711115038,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{\"content\":\"done\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":8,\"completion_tokens\":1,\"total_tokens\":9}}\n\n" ++
        "data: [DONE]\n\n";
    const script = [_]mock_transport.ScriptedResponse{
        .{ .sse = tool_sse },
        .{ .sse = final_sse },
    };
    const Observer = struct {
        saw_tool_result: std.atomic.Value(bool) = .init(false),

        fn observe(raw: ?*anyopaque, index: usize, body: ?[]const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (index == 1 and body != null and std.mem.indexOf(u8, body.?, "tool_call_id") != null) {
                self.saw_tool_result.store(true, .release);
            }
        }
    };
    var observer: Observer = .{};
    var mock = mock_transport.MockTransport.init(&script);
    mock.observer = .{ .ctx = &observer, .observe_fn = Observer.observe };
    const factory = openai_compatible.createOpenAiCompatible(.{
        .provider_name = "phase-1b",
        .base_url = "https://example.test/v1",
        .api_key = "dummy-key",
        .transport = mock.transport(),
    });
    var chat = try factory.chatModel("smoke-model", null);

    const Echo = struct {
        fn execute(
            _: ?*anyopaque,
            _: std.Io,
            arena: Allocator,
            input: std.json.Value,
            _: ?tool_api.OnUpdate,
            _: *const tool_api.CancelToken,
        ) anyerror!tool_api.ToolOutcome {
            const value = input.object.get("value").?.string;
            const content = try arena.alloc(tool_api.ResultBlock, 1);
            content[0] = .{ .text = try std.fmt.allocPrint(arena, "echoed: {s}", .{value}) };
            return .{ .content = content };
        }
    };
    const echo_vtable: tool_api.VTable = .{ .execute = Echo.execute };
    var registry = tool_api.ToolRegistry.init(allocator);
    defer registry.deinit();
    try registry.add(.{
        .name = "echo",
        .description = "Echo input",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"string\"}},\"required\":[\"value\"]}",
        .vtable = &echo_vtable,
    });

    var session = try AgentSession.init(allocator, io, .{
        .model = .{
            .language_model = .{ .model = chat.languageModel() },
            .provider_name = "phase-1b",
            .model_id = "smoke-model",
            .api = "openai-compatible",
        },
        .system_prompt = "You are helpful.",
        .tools = &registry,
        .session_manager = &persistent,
    });
    defer session.deinit();
    var runner = try io.concurrent(AgentSession.run, .{&session});

    var prompt = try events.OwnedPrompt.init(allocator, "echo hello", &.{}, false, .user);
    defer prompt.deinit(allocator);
    try session.inbox().push(io, .{ .prompt = prompt });

    const Tag = std.meta.Tag(events.AgentEvent);
    var tags: std.ArrayList(Tag) = .empty;
    defer tags.deinit(allocator);
    while (try session.outbox().pop(io)) |owned_event| {
        var event = owned_event;
        const tag = std.meta.activeTag(event);
        try tags.append(allocator, tag);
        const finished = tag == .run_finished;
        event.deinit(allocator);
        if (finished) break;
    }

    try session.inbox().push(io, .shutdown);
    try runner.await(io);
    try std.testing.expectEqual(@as(usize, 2), mock.request_count);
    try std.testing.expect(observer.saw_tool_result.load(.acquire));
    try std.testing.expectEqual(@as(usize, 4), session.messagesBorrowed().len);
    try std.testing.expect(session.messagesBorrowed()[1] == .assistant);
    try std.testing.expect(session.messagesBorrowed()[2] == .tool_result);
    try std.testing.expectEqualStrings("echoed: hello", session.messagesBorrowed()[2].tool_result.content[0].text.text);
    try std.testing.expectEqualStrings("done", session.messagesBorrowed()[3].assistant.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 4), persistent.getEntries().len);
    try persistent.flush();
    var reopened = try session_manager.SessionManager.open(allocator, io, persistent.path().?, .{
        .path_options = .{
            .agent_dir = temp_root,
            .home = temp_root,
            .temp_dir = "/tmp",
        },
    });
    defer reopened.deinit();
    try std.testing.expectEqual(persistent.getEntries().len, reopened.getEntries().len);
    try std.testing.expectEqualStrings(persistent.currentLeaf().?, reopened.currentLeaf().?);
    try std.testing.expectEqual(persistent.usageTotals().input, reopened.usageTotals().input);
    for (persistent.getEntries(), reopened.getEntries()) |expected, actual| {
        const expected_json = try @import("../session/entries.zig").stringifyEntryAlloc(allocator, expected);
        defer allocator.free(expected_json);
        const actual_json = try @import("../session/entries.zig").stringifyEntryAlloc(allocator, actual);
        defer allocator.free(actual_json);
        try std.testing.expectEqualStrings(expected_json, actual_json);
    }
    const expected_tags = [_]Tag{
        .run_started,
        .turn_started,
        .message_started,
        .message_finished,
        .message_started,
        .message_finished,
        .usage_updated,
        .tool_started,
        .tool_finished,
        .message_started,
        .message_finished,
        .turn_finished,
        .turn_started,
        .message_started,
        .text_delta,
        .message_finished,
        .usage_updated,
        .turn_finished,
        .run_finished,
    };
    try std.testing.expectEqualSlices(Tag, &expected_tags, tags.items);

    const resume_sse =
        "data: {\"id\":\"chatcmpl-resume\",\"created\":1711115039,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{\"content\":\"resumed\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":1,\"total_tokens\":13}}\n\n" ++
        "data: [DONE]\n\n";
    const resume_script = [_]mock_transport.ScriptedResponse{.{ .sse = resume_sse }};
    const ResumeObserver = struct {
        saw_prior_turn: std.atomic.Value(bool) = .init(false),

        fn observe(raw: ?*anyopaque, _: usize, body: ?[]const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const request = body orelse return;
            self.saw_prior_turn.store(
                std.mem.indexOf(u8, request, "done") != null and
                    std.mem.indexOf(u8, request, "echoed: hello") != null,
                .release,
            );
        }
    };
    var resume_observer: ResumeObserver = .{};
    var resume_mock = mock_transport.MockTransport.init(&resume_script);
    resume_mock.observer = .{ .ctx = &resume_observer, .observe_fn = ResumeObserver.observe };
    const resume_factory = openai_compatible.createOpenAiCompatible(.{
        .provider_name = "phase-1b",
        .base_url = "https://example.test/v1",
        .api_key = "dummy-key",
        .transport = resume_mock.transport(),
    });
    var resume_chat = try resume_factory.chatModel("smoke-model", null);
    var resumed = try AgentSession.init(allocator, io, .{
        .model = .{
            .language_model = .{ .model = resume_chat.languageModel() },
            .provider_name = "phase-1b",
            .model_id = "smoke-model",
            .api = "openai-compatible",
        },
        .tools = &registry,
        .session_manager = &reopened,
    });
    defer resumed.deinit();
    try std.testing.expectEqual(@as(usize, 4), resumed.messagesBorrowed().len);
    var resumed_runner = try io.concurrent(AgentSession.run, .{&resumed});
    var resume_prompt = try events.OwnedPrompt.init(allocator, "continue", &.{}, false, .user);
    defer resume_prompt.deinit(allocator);
    try resumed.inbox().push(io, .{ .prompt = resume_prompt });
    try drainRun(io, allocator, &resumed);
    try resumed.inbox().push(io, .shutdown);
    try resumed_runner.await(io);
    try std.testing.expect(resume_observer.saw_prior_turn.load(.acquire));
    try std.testing.expectEqualStrings("resumed", resumed.messagesBorrowed()[5].assistant.content[0].text.text);
}

test "loop integration blocks an exec tool until the approval command" {
    const openai_compatible = @import("openai_compatible");
    const mock_transport = @import("../testkit/mock_transport.zig");
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const tool_sse =
        "data: {\"id\":\"chatcmpl-approval\",\"created\":1711115037,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-approved\",\"type\":\"function\",\"function\":{\"name\":\"write\",\"arguments\":\"{}\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const final_sse =
        "data: {\"id\":\"chatcmpl-approved\",\"created\":1711115038,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{\"content\":\"approved\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const script = [_]mock_transport.ScriptedResponse{ .{ .sse = tool_sse }, .{ .sse = final_sse } };
    var mock = mock_transport.MockTransport.init(&script);
    const factory = openai_compatible.createOpenAiCompatible(.{
        .provider_name = "phase-1b",
        .base_url = "https://example.test/v1",
        .api_key = "dummy-key",
        .transport = mock.transport(),
    });
    var chat = try factory.chatModel("smoke-model", null);
    const Write = struct {
        fn execute(
            raw: ?*anyopaque,
            _: std.Io,
            arena: Allocator,
            _: std.json.Value,
            _: ?tool_api.OnUpdate,
            _: *const tool_api.CancelToken,
        ) anyerror!tool_api.ToolOutcome {
            const runs: *std.atomic.Value(u32) = @ptrCast(@alignCast(raw.?));
            _ = runs.fetchAdd(1, .acq_rel);
            const content = try arena.alloc(tool_api.ResultBlock, 1);
            content[0] = .{ .text = "wrote" };
            return .{ .content = content };
        }
    };
    var runs = std.atomic.Value(u32).init(0);
    const write_vtable: tool_api.VTable = .{ .execute = Write.execute };
    var registry = tool_api.ToolRegistry.init(allocator);
    defer registry.deinit();
    try registry.add(.{
        .ctx = &runs,
        .name = "write",
        .description = "write",
        .input_schema = "{}",
        .vtable = &write_vtable,
    });
    var session = try AgentSession.init(allocator, io, .{
        .model = .{
            .language_model = .{ .model = chat.languageModel() },
            .provider_name = "phase-1b",
            .model_id = "smoke-model",
        },
        .tools = &registry,
        .approval_mode = .always_ask,
    });
    defer session.deinit();
    var runner = try io.concurrent(AgentSession.run, .{&session});
    var prompt = try events.OwnedPrompt.init(allocator, "write", &.{}, false, .user);
    defer prompt.deinit(allocator);
    try session.inbox().push(io, .{ .prompt = prompt });

    var saw_approval = false;
    while (try session.outbox().pop(io)) |owned_event| {
        var event = owned_event;
        if (event == .approval_requested) {
            try std.testing.expectEqual(@as(u32, 0), runs.load(.acquire));
            var decision = try events.ApprovalDecision.init(
                allocator,
                event.approval_requested.request_id,
                true,
                null,
            );
            defer decision.deinit(allocator);
            try session.inbox().push(io, .{ .approve = decision });
            saw_approval = true;
        }
        const finished = event == .run_finished;
        event.deinit(allocator);
        if (finished) break;
    }
    try session.inbox().push(io, .shutdown);
    try runner.await(io);
    try std.testing.expect(saw_approval);
    try std.testing.expectEqual(@as(u32, 1), runs.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), mock.request_count);
}

test "loop integration skips a soft-requirement detour then forces one required turn" {
    const openai_compatible = @import("openai_compatible");
    const mock_transport = @import("../testkit/mock_transport.zig");
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const detour_sse =
        "data: {\"id\":\"chatcmpl-detour\",\"created\":1711115037,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-detour\",\"type\":\"function\",\"function\":{\"name\":\"detour\",\"arguments\":\"{}\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const required_sse =
        "data: {\"id\":\"chatcmpl-required\",\"created\":1711115038,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-required\",\"type\":\"function\",\"function\":{\"name\":\"required\",\"arguments\":\"{}\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const final_sse =
        "data: {\"id\":\"chatcmpl-soft-done\",\"created\":1711115039,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{\"content\":\"done\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const script = [_]mock_transport.ScriptedResponse{
        .{ .sse = detour_sse },
        .{ .sse = required_sse },
        .{ .sse = final_sse },
    };
    var mock = mock_transport.MockTransport.init(&script);
    const factory = openai_compatible.createOpenAiCompatible(.{
        .provider_name = "phase-1b",
        .base_url = "https://example.test/v1",
        .api_key = "dummy-key",
        .transport = mock.transport(),
    });
    var chat = try factory.chatModel("smoke-model", null);
    const CountingTool = struct {
        fn execute(
            raw: ?*anyopaque,
            _: std.Io,
            arena: Allocator,
            _: std.json.Value,
            _: ?tool_api.OnUpdate,
            _: *const tool_api.CancelToken,
        ) anyerror!tool_api.ToolOutcome {
            const runs: *std.atomic.Value(u32) = @ptrCast(@alignCast(raw.?));
            _ = runs.fetchAdd(1, .acq_rel);
            const content = try arena.alloc(tool_api.ResultBlock, 1);
            content[0] = .{ .text = "ok" };
            return .{ .content = content };
        }
    };
    const tool_vtable: tool_api.VTable = .{ .execute = CountingTool.execute };
    var detour_runs = std.atomic.Value(u32).init(0);
    var required_runs = std.atomic.Value(u32).init(0);
    var registry = tool_api.ToolRegistry.init(allocator);
    defer registry.deinit();
    try registry.add(.{ .ctx = &detour_runs, .name = "detour", .description = "", .input_schema = "{}", .vtable = &tool_vtable });
    try registry.add(.{ .ctx = &required_runs, .name = "required", .description = "", .input_schema = "{}", .vtable = &tool_vtable });

    const ReminderState = struct {
        resolutions: std.atomic.Value(u32) = .init(0),
        reminders: [1]message.AgentMessage = .{.{ .developer = .{
            .content = .{ .string = "Resolve the pending action with required." },
            .attribution = .agent,
            .timestamp = 1,
        } }},

        fn resolve(raw: ?*anyopaque) ?loop.ToolChoiceDirective {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.resolutions.fetchAdd(1, .acq_rel) != 0) return null;
            return .{ .soft = .{
                .id = "soft-1",
                .tool_name = "required",
                .reminder = &self.reminders,
            } };
        }
    };
    var reminder_state: ReminderState = .{};
    var session = try AgentSession.init(allocator, io, .{
        .model = .{
            .language_model = .{ .model = chat.languageModel() },
            .provider_name = "phase-1b",
            .model_id = "smoke-model",
        },
        .tools = &registry,
        .tool_choice = .{ .ctx = &reminder_state, .resolve_fn = ReminderState.resolve },
    });
    defer session.deinit();
    var runner = try io.concurrent(AgentSession.run, .{&session});
    var prompt = try events.OwnedPrompt.init(allocator, "act", &.{}, false, .user);
    defer prompt.deinit(allocator);
    try session.inbox().push(io, .{ .prompt = prompt });
    try drainRun(io, allocator, &session);
    try session.inbox().push(io, .shutdown);
    try runner.await(io);

    try std.testing.expectEqual(@as(u32, 0), detour_runs.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), required_runs.load(.acquire));
    try std.testing.expectEqual(@as(usize, 7), session.messagesBorrowed().len);
    try std.testing.expectEqualStrings(
        "Tool call was not executed because the assistant ended its turn: Not executed: call the `required` tool to resolve the pending action before using other tools.",
        session.messagesBorrowed()[3].tool_result.content[0].text.text,
    );
    try std.testing.expectEqualStrings("required", session.messagesBorrowed()[4].assistant.content[0].tool_call.name);
}

test "loop integration lets a pending soft requirement outrank an empty-stop retry" {
    const openai_compatible = @import("openai_compatible");
    const mock_transport = @import("../testkit/mock_transport.zig");
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const empty_sse =
        "data: {\"id\":\"chatcmpl-soft-empty\",\"created\":1711115037,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const required_sse =
        "data: {\"id\":\"chatcmpl-soft-required\",\"created\":1711115038,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-required\",\"type\":\"function\",\"function\":{\"name\":\"required\",\"arguments\":\"{}\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const final_sse =
        "data: {\"id\":\"chatcmpl-soft-finished\",\"created\":1711115039,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{\"content\":\"done\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const script = [_]mock_transport.ScriptedResponse{
        .{ .sse = empty_sse },
        .{ .sse = required_sse },
        .{ .sse = final_sse },
    };
    const Observation = struct {
        forced_required: std.atomic.Value(bool) = .init(false),

        fn observe(raw: ?*anyopaque, request_index: usize, body: ?[]const u8) void {
            if (request_index != 1) return;
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const request = body orelse return;
            self.forced_required.store(
                std.mem.indexOf(u8, request, "\"tool_choice\":{\"type\":\"function\",\"function\":{\"name\":\"required\"}}") != null,
                .release,
            );
        }
    };
    var observation: Observation = .{};
    var mock = mock_transport.MockTransport.init(&script);
    mock.observer = .{ .ctx = &observation, .observe_fn = Observation.observe };
    const factory = openai_compatible.createOpenAiCompatible(.{
        .provider_name = "phase-1b",
        .base_url = "https://example.test/v1",
        .api_key = "dummy-key",
        .transport = mock.transport(),
    });
    var chat = try factory.chatModel("smoke-model", null);
    const RequiredTool = struct {
        fn execute(
            raw: ?*anyopaque,
            _: std.Io,
            arena: Allocator,
            _: std.json.Value,
            _: ?tool_api.OnUpdate,
            _: *const tool_api.CancelToken,
        ) anyerror!tool_api.ToolOutcome {
            const runs: *std.atomic.Value(u32) = @ptrCast(@alignCast(raw.?));
            _ = runs.fetchAdd(1, .acq_rel);
            const content = try arena.alloc(tool_api.ResultBlock, 1);
            content[0] = .{ .text = "ok" };
            return .{ .content = content };
        }
    };
    const tool_vtable: tool_api.VTable = .{ .execute = RequiredTool.execute };
    var runs = std.atomic.Value(u32).init(0);
    var registry = tool_api.ToolRegistry.init(allocator);
    defer registry.deinit();
    try registry.add(.{ .ctx = &runs, .name = "required", .description = "", .input_schema = "{}", .vtable = &tool_vtable });
    const Requirement = struct {
        calls: std.atomic.Value(u32) = .init(0),

        fn resolve(raw: ?*anyopaque) ?loop.ToolChoiceDirective {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.calls.fetchAdd(1, .acq_rel) != 0) return null;
            return .{ .soft = .{ .id = "soft-empty", .tool_name = "required", .reminder = &.{} } };
        }
    };
    var requirement: Requirement = .{};
    var session = try AgentSession.init(allocator, io, .{
        .model = .{
            .language_model = .{ .model = chat.languageModel() },
            .provider_name = "phase-1b",
            .model_id = "smoke-model",
        },
        .tools = &registry,
        .tool_choice = .{ .ctx = &requirement, .resolve_fn = Requirement.resolve },
    });
    defer session.deinit();
    var runner = try io.concurrent(AgentSession.run, .{&session});
    var prompt = try events.OwnedPrompt.init(allocator, "act", &.{}, false, .user);
    defer prompt.deinit(allocator);
    try session.inbox().push(io, .{ .prompt = prompt });
    try drainRun(io, allocator, &session);
    try session.inbox().push(io, .shutdown);
    try runner.await(io);

    try std.testing.expect(observation.forced_required.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), runs.load(.acquire));
    try std.testing.expectEqual(@as(usize, 3), mock.request_count);
    try std.testing.expectEqual(@as(usize, 5), session.messagesBorrowed().len);
}

test "loop integration retries one 429 model call then succeeds" {
    const openai_compatible = @import("openai_compatible");
    const mock_transport = @import("../testkit/mock_transport.zig");
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const success_sse =
        "data: {\"id\":\"chatcmpl-retry\",\"created\":1711115038,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{\"content\":\"recovered\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const script = [_]mock_transport.ScriptedResponse{
        .{ .http_error = .{ .status = 429, .status_text = "Too Many Requests", .retry_after_ms = "0" } },
        .{ .sse = success_sse },
    };
    var mock = mock_transport.MockTransport.init(&script);
    const factory = openai_compatible.createOpenAiCompatible(.{
        .provider_name = "phase-1b",
        .base_url = "https://example.test/v1",
        .api_key = "dummy-key",
        .transport = mock.transport(),
    });
    var chat = try factory.chatModel("smoke-model", null);
    var registry = tool_api.ToolRegistry.init(allocator);
    defer registry.deinit();
    const Choice = struct {
        fn resolve(raw: ?*anyopaque) ?loop.ToolChoiceDirective {
            const count: *std.atomic.Value(u32) = @ptrCast(@alignCast(raw.?));
            _ = count.fetchAdd(1, .acq_rel);
            return .{ .hard = .auto };
        }
    };
    var choice_resolutions = std.atomic.Value(u32).init(0);
    const retry_target: ModelTarget = .{
        .language_model = .{ .model = chat.languageModel() },
        .provider_name = "phase-1b",
        .model_id = "smoke-model",
    };
    const default_fallbacks = [_]ModelTarget{retry_target};
    const fallback_chains = [_]FallbackChain{.{ .role = "default", .models = &default_fallbacks }};
    var session = try AgentSession.init(allocator, io, .{
        .model = retry_target,
        .model_role = "default",
        .fallback_chains = &fallback_chains,
        .tools = &registry,
        .retry = .{ .base_delay_ms = 1 },
        .tool_choice = .{ .ctx = &choice_resolutions, .resolve_fn = Choice.resolve },
    });
    defer session.deinit();
    var runner = try io.concurrent(AgentSession.run, .{&session});
    var prompt = try events.OwnedPrompt.init(allocator, "retry", &.{}, false, .user);
    defer prompt.deinit(allocator);
    try session.inbox().push(io, .{ .prompt = prompt });

    var retry_started: u32 = 0;
    var retry_finished: u32 = 0;
    while (try session.outbox().pop(io)) |owned_event| {
        var event = owned_event;
        switch (event) {
            .auto_retry_started => retry_started += 1,
            .auto_retry_finished => retry_finished += 1,
            else => {},
        }
        const finished = event == .run_finished;
        event.deinit(allocator);
        if (finished) break;
    }
    try session.inbox().push(io, .shutdown);
    try runner.await(io);
    try std.testing.expectEqual(@as(usize, 2), mock.request_count);
    try std.testing.expectEqual(@as(u32, 1), retry_started);
    try std.testing.expectEqual(@as(u32, 1), retry_finished);
    try std.testing.expectEqual(@as(u32, 1), choice_resolutions.load(.acquire));
    try std.testing.expectEqualStrings("recovered", session.messagesBorrowed()[1].assistant.content[0].text.text);
}

test "loop integration fails fast when provider wait exceeds retry maximum" {
    const openai_compatible = @import("openai_compatible");
    const mock_transport = @import("../testkit/mock_transport.zig");
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const script = [_]mock_transport.ScriptedResponse{.{ .http_error = .{
        .status = 429,
        .status_text = "Too Many Requests",
        .body = "{\"error\":{\"message\":\"wait before retrying\"}}",
        .retry_after_ms = "60000",
    } }};
    var mock = mock_transport.MockTransport.init(&script);
    const factory = openai_compatible.createOpenAiCompatible(.{
        .provider_name = "phase-1b",
        .base_url = "https://example.test/v1",
        .api_key = "dummy-key",
        .transport = mock.transport(),
    });
    var chat = try factory.chatModel("smoke-model", null);
    var registry = tool_api.ToolRegistry.init(allocator);
    defer registry.deinit();
    var session = try AgentSession.init(allocator, io, .{
        .model = .{
            .language_model = .{ .model = chat.languageModel() },
            .provider_name = "phase-1b",
            .model_id = "smoke-model",
        },
        .tools = &registry,
        .retry = .{ .base_delay_ms = 1, .max_delay_ms = 10 },
    });
    defer session.deinit();
    var runner = try io.concurrent(AgentSession.run, .{&session});
    var prompt = try events.OwnedPrompt.init(allocator, "retry", &.{}, false, .user);
    defer prompt.deinit(allocator);
    const started_at = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    try session.inbox().push(io, .{ .prompt = prompt });

    var retry_starts: u32 = 0;
    var retry_ends: u32 = 0;
    var status: ?events.RunStatus = null;
    while (try session.outbox().pop(io)) |owned_event| {
        var event = owned_event;
        switch (event) {
            .auto_retry_started => retry_starts += 1,
            .auto_retry_finished => |outcome| {
                retry_ends += 1;
                try std.testing.expect(!outcome.success);
                try std.testing.expectEqual(@as(u32, 1), outcome.attempt);
                try std.testing.expect(std.mem.startsWith(
                    u8,
                    outcome.final_error.?,
                    "Provider requested 60000ms wait, exceeds retry.maxDelayMs (10ms). Original error: ",
                ));
            },
            .run_finished => |result| status = result.status,
            else => {},
        }
        const finished = event == .run_finished;
        event.deinit(allocator);
        if (finished) break;
    }
    const elapsed_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds() - started_at;
    try session.inbox().push(io, .shutdown);
    try runner.await(io);

    try std.testing.expect(elapsed_ms < 1_000);
    try std.testing.expectEqual(@as(usize, 1), mock.request_count);
    try std.testing.expectEqual(@as(u32, 0), retry_starts);
    try std.testing.expectEqual(@as(u32, 1), retry_ends);
    try std.testing.expectEqual(events.RunStatus.failed, status.?);
    try std.testing.expect(std.mem.startsWith(
        u8,
        session.messagesBorrowed()[1].assistant.error_message.?,
        "Provider requested 60000ms wait, exceeds retry.maxDelayMs (10ms). Original error: ",
    ));
}

test "loop integration user cancel interrupts retry backoff" {
    const openai_compatible = @import("openai_compatible");
    const mock_transport = @import("../testkit/mock_transport.zig");
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const script = [_]mock_transport.ScriptedResponse{.{ .http_error = .{
        .status = 429,
        .status_text = "Too Many Requests",
        .body = "{\"error\":{\"message\":\"retry later\"}}",
    } }};
    var mock = mock_transport.MockTransport.init(&script);
    const factory = openai_compatible.createOpenAiCompatible(.{
        .provider_name = "phase-1b",
        .base_url = "https://example.test/v1",
        .api_key = "dummy-key",
        .transport = mock.transport(),
    });
    var chat = try factory.chatModel("smoke-model", null);
    var registry = tool_api.ToolRegistry.init(allocator);
    defer registry.deinit();
    var session = try AgentSession.init(allocator, io, .{
        .model = .{
            .language_model = .{ .model = chat.languageModel() },
            .provider_name = "phase-1b",
            .model_id = "smoke-model",
        },
        .tools = &registry,
        .retry = .{ .base_delay_ms = 5_000 },
    });
    defer session.deinit();
    var runner = try io.concurrent(AgentSession.run, .{&session});
    var prompt = try events.OwnedPrompt.init(allocator, "retry", &.{}, false, .user);
    defer prompt.deinit(allocator);
    try session.inbox().push(io, .{ .prompt = prompt });

    var cancel_started_at: ?i64 = null;
    var status: ?events.RunStatus = null;
    while (try session.outbox().pop(io)) |owned_event| {
        var event = owned_event;
        if (event == .auto_retry_started and cancel_started_at == null) {
            cancel_started_at = std.Io.Timestamp.now(io, .awake).toMilliseconds();
            try session.inbox().push(io, .{ .cancel = .user });
        }
        if (event == .run_finished) status = event.run_finished.status;
        const finished = event == .run_finished;
        event.deinit(allocator);
        if (finished) break;
    }
    const elapsed_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds() - cancel_started_at.?;
    try session.inbox().push(io, .shutdown);
    try runner.await(io);

    try std.testing.expect(elapsed_ms < 1_000);
    try std.testing.expectEqual(@as(usize, 1), mock.request_count);
    try std.testing.expectEqual(events.RunStatus.cancelled, status.?);
    try std.testing.expectEqual(message.StopReason.aborted, session.messagesBorrowed()[1].assistant.stop_reason);
    try std.testing.expectEqualStrings("Interrupted by user", session.messagesBorrowed()[1].assistant.error_message.?);
}

test "loop integration re-prompts an empty stop at most three times" {
    const openai_compatible = @import("openai_compatible");
    const mock_transport = @import("../testkit/mock_transport.zig");
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const empty_sse =
        "data: {\"id\":\"chatcmpl-empty\",\"created\":1711115038,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const success_sse =
        "data: {\"id\":\"chatcmpl-after-empty\",\"created\":1711115038,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{\"content\":\"finished\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const script = [_]mock_transport.ScriptedResponse{
        .{ .sse = empty_sse },
        .{ .sse = empty_sse },
        .{ .sse = empty_sse },
        .{ .sse = success_sse },
    };
    var mock = mock_transport.MockTransport.init(&script);
    const factory = openai_compatible.createOpenAiCompatible(.{
        .provider_name = "phase-1b",
        .base_url = "https://example.test/v1",
        .api_key = "dummy-key",
        .transport = mock.transport(),
    });
    var chat = try factory.chatModel("smoke-model", null);
    var registry = tool_api.ToolRegistry.init(allocator);
    defer registry.deinit();
    var session = try AgentSession.init(allocator, io, .{
        .model = .{
            .language_model = .{ .model = chat.languageModel() },
            .provider_name = "phase-1b",
            .model_id = "smoke-model",
        },
        .tools = &registry,
    });
    defer session.deinit();
    var runner = try io.concurrent(AgentSession.run, .{&session});
    var prompt = try events.OwnedPrompt.init(allocator, "finish the task", &.{}, false, .user);
    defer prompt.deinit(allocator);
    try session.inbox().push(io, .{ .prompt = prompt });
    try drainRun(io, allocator, &session);
    try session.inbox().push(io, .shutdown);
    try runner.await(io);

    try std.testing.expectEqual(@as(usize, 4), mock.request_count);
    try std.testing.expectEqual(@as(usize, 5), session.messagesBorrowed().len);
    for (session.messagesBorrowed()[1..4], 1..) |value, attempt| {
        try std.testing.expect(value == .developer);
        var expected_buffer: [32]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buffer, "Attempt #{d}/3", .{attempt});
        try std.testing.expect(std.mem.indexOf(u8, value.developer.content.blocks[0].text.text, expected) != null);
    }
    try std.testing.expectEqualStrings("finished", session.messagesBorrowed()[4].assistant.content[0].text.text);
}

test "loop integration caps consecutive pause-turn continuations at eight" {
    const anthropic_provider = @import("anthropic");
    const mock_transport = @import("../testkit/mock_transport.zig");
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const pause_sse =
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg-pause\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-test\",\"stop_sequence\":null,\"usage\":{\"input_tokens\":1,\"output_tokens\":1},\"content\":[],\"stop_reason\":null}}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null,\"stop_details\":{\"type\":\"pause_turn\"}},\"usage\":{\"output_tokens\":1}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
    const script = [_]mock_transport.ScriptedResponse{.{ .sse = pause_sse }} ** 9;
    var mock = mock_transport.MockTransport.init(&script);
    const factory = try anthropic_provider.createAnthropic(.{
        .base_url = "https://example.test/v1",
        .api_key = "dummy-key",
        .transport = mock.transport(),
    });
    var chat = try factory.messages("claude-test", null);
    var registry = tool_api.ToolRegistry.init(allocator);
    defer registry.deinit();
    var session = try AgentSession.init(allocator, io, .{
        .model = .{
            .language_model = .{ .model = chat.languageModel() },
            .provider_name = "anthropic",
            .model_id = "claude-test",
            .api = "anthropic-messages",
        },
        .tools = &registry,
    });
    defer session.deinit();
    var runner = try io.concurrent(AgentSession.run, .{&session});
    var prompt = try events.OwnedPrompt.init(allocator, "continue", &.{}, false, .user);
    defer prompt.deinit(allocator);
    try session.inbox().push(io, .{ .prompt = prompt });
    try drainRun(io, allocator, &session);
    try session.inbox().push(io, .shutdown);
    try runner.await(io);

    try std.testing.expectEqual(@as(usize, 9), mock.request_count);
    try std.testing.expectEqual(@as(usize, 10), session.messagesBorrowed().len);
    try std.testing.expectEqualStrings(
        "pause_turn",
        session.messagesBorrowed()[9].assistant.stop_details.?.object.get("type").?.string,
    );
}

test "loop integration bounds classifier-confirmed unexpected stops" {
    const openai_compatible = @import("openai_compatible");
    const mock_transport = @import("../testkit/mock_transport.zig");
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const unexpected_sse =
        "data: {\"id\":\"chatcmpl-unexpected\",\"created\":1711115038,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{\"content\":\"I will continue.\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const success_sse =
        "data: {\"id\":\"chatcmpl-unexpected-done\",\"created\":1711115038,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{\"content\":\"done\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const script = [_]mock_transport.ScriptedResponse{
        .{ .sse = unexpected_sse },
        .{ .sse = unexpected_sse },
        .{ .sse = unexpected_sse },
        .{ .sse = success_sse },
    };
    var mock = mock_transport.MockTransport.init(&script);
    const factory = openai_compatible.createOpenAiCompatible(.{
        .provider_name = "phase-1b",
        .base_url = "https://example.test/v1",
        .api_key = "dummy-key",
        .transport = mock.transport(),
    });
    var chat = try factory.chatModel("smoke-model", null);
    var registry = tool_api.ToolRegistry.init(allocator);
    defer registry.deinit();
    const Classifier = struct {
        fn classify(_: ?*anyopaque, text: []const u8) ?bool {
            return std.mem.indexOf(u8, text, "continue") != null;
        }
    };
    var session = try AgentSession.init(allocator, io, .{
        .model = .{
            .language_model = .{ .model = chat.languageModel() },
            .provider_name = "phase-1b",
            .model_id = "smoke-model",
        },
        .tools = &registry,
        .unexpected_stop_classifier = .{ .classify_fn = Classifier.classify },
    });
    defer session.deinit();
    var runner = try io.concurrent(AgentSession.run, .{&session});
    var prompt = try events.OwnedPrompt.init(allocator, "finish the task", &.{}, false, .user);
    defer prompt.deinit(allocator);
    try session.inbox().push(io, .{ .prompt = prompt });
    try drainRun(io, allocator, &session);
    try session.inbox().push(io, .shutdown);
    try runner.await(io);

    try std.testing.expectEqual(@as(usize, 4), mock.request_count);
    var reminder_count: usize = 0;
    for (session.messagesBorrowed()) |value| if (value == .developer) {
        if (std.mem.indexOf(u8, value.developer.content.blocks[0].text.text, "Continue now") != null) {
            reminder_count += 1;
        }
    };
    try std.testing.expectEqual(@as(usize, 3), reminder_count);
    try std.testing.expectEqualStrings(
        "done",
        session.messagesBorrowed()[session.messagesBorrowed().len - 1].assistant.content[0].text.text,
    );
}

test "loop integration persists a non-retryable provider error as assistant data" {
    const openai_compatible = @import("openai_compatible");
    const mock_transport = @import("../testkit/mock_transport.zig");
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const script = [_]mock_transport.ScriptedResponse{.{ .http_error = .{
        .status = 400,
        .status_text = "Bad Request",
        .body = "{\"error\":{\"message\":\"bad provider request\"}}",
    } }};
    var mock = mock_transport.MockTransport.init(&script);
    const factory = openai_compatible.createOpenAiCompatible(.{
        .provider_name = "phase-1b",
        .base_url = "https://example.test/v1",
        .api_key = "dummy-key",
        .transport = mock.transport(),
    });
    var chat = try factory.chatModel("smoke-model", null);
    var registry = tool_api.ToolRegistry.init(allocator);
    defer registry.deinit();
    var session = try AgentSession.init(allocator, io, .{
        .model = .{
            .language_model = .{ .model = chat.languageModel() },
            .provider_name = "phase-1b",
            .model_id = "smoke-model",
        },
        .tools = &registry,
    });
    defer session.deinit();
    var runner = try io.concurrent(AgentSession.run, .{&session});
    var prompt = try events.OwnedPrompt.init(allocator, "fail", &.{}, false, .user);
    defer prompt.deinit(allocator);
    try session.inbox().push(io, .{ .prompt = prompt });
    var run_status: ?events.RunStatus = null;
    while (try session.outbox().pop(io)) |owned_event| {
        var event = owned_event;
        if (event == .run_finished) run_status = event.run_finished.status;
        const finished = event == .run_finished;
        event.deinit(allocator);
        if (finished) break;
    }
    try session.inbox().push(io, .shutdown);
    try runner.await(io);
    try std.testing.expectEqual(events.RunStatus.failed, run_status.?);
    try std.testing.expectEqual(@as(usize, 2), session.messagesBorrowed().len);
    try std.testing.expectEqual(message.StopReason.@"error", session.messagesBorrowed()[1].assistant.stop_reason);
    try std.testing.expect(std.mem.indexOf(u8, session.messagesBorrowed()[1].assistant.error_message.?, "bad provider request") != null);
}

test "loop integration cancels a blocked model step as an aborted message" {
    const anthropic_provider = @import("anthropic");
    const mock_transport = @import("../testkit/mock_transport.zig");
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var entered: std.Io.Event = .unset;
    var release: std.Io.Event = .unset;
    const prefix =
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg-cancel\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-test\",\"stop_sequence\":null,\"usage\":{\"input_tokens\":1,\"output_tokens\":1},\"content\":[],\"stop_reason\":null}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call-before-cancel\",\"name\":\"echo\",\"input\":{}}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call-still-streaming\",\"name\":\"echo\",\"input\":{}}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\"}}\n\n";
    const script = [_]mock_transport.ScriptedResponse{.{ .split_sse = .{
        .prefix = prefix,
        .gate = &release,
        .entered = &entered,
    } }};
    var mock = mock_transport.MockTransport.init(&script);
    const factory = try anthropic_provider.createAnthropic(.{
        .base_url = "https://example.test/v1",
        .api_key = "dummy-key",
        .transport = mock.transport(),
    });
    var chat = try factory.messages("claude-test", null);
    const Echo = struct {
        fn execute(
            _: ?*anyopaque,
            _: std.Io,
            arena: Allocator,
            _: std.json.Value,
            _: ?tool_api.OnUpdate,
            _: *const tool_api.CancelToken,
        ) anyerror!tool_api.ToolOutcome {
            return .{ .content = try arena.alloc(tool_api.ResultBlock, 0) };
        }
    };
    const echo_vtable: tool_api.VTable = .{ .execute = Echo.execute };
    var registry = tool_api.ToolRegistry.init(allocator);
    defer registry.deinit();
    try registry.add(.{ .name = "echo", .description = "echo", .input_schema = "{}", .vtable = &echo_vtable });
    var session = try AgentSession.init(allocator, io, .{
        .model = .{
            .language_model = .{ .model = chat.languageModel() },
            .provider_name = "anthropic",
            .model_id = "claude-test",
            .api = "anthropic-messages",
        },
        .tools = &registry,
    });
    defer session.deinit();
    var runner = try io.concurrent(AgentSession.run, .{&session});
    var prompt = try events.OwnedPrompt.init(allocator, "block", &.{}, false, .user);
    defer prompt.deinit(allocator);
    try session.inbox().push(io, .{ .prompt = prompt });
    try entered.wait(io);
    try session.inbox().push(io, .{ .cancel = .user });

    var status: ?events.RunStatus = null;
    while (try session.outbox().pop(io)) |owned_event| {
        var event = owned_event;
        if (event == .run_finished) status = event.run_finished.status;
        const finished = event == .run_finished;
        event.deinit(allocator);
        if (finished) break;
    }
    try session.inbox().push(io, .shutdown);
    try runner.await(io);
    try std.testing.expectEqual(events.RunStatus.cancelled, status.?);
    try std.testing.expectEqual(@as(usize, 3), session.messagesBorrowed().len);
    try std.testing.expectEqual(message.StopReason.aborted, session.messagesBorrowed()[1].assistant.stop_reason);
    try std.testing.expectEqualStrings("Interrupted by user", session.messagesBorrowed()[1].assistant.error_message.?);
    try std.testing.expectEqual(@as(usize, 1), session.messagesBorrowed()[1].assistant.content.len);
    try std.testing.expectEqualStrings("call-before-cancel", session.messagesBorrowed()[1].assistant.content[0].tool_call.id);
    try std.testing.expectEqualStrings("call-before-cancel", session.messagesBorrowed()[2].tool_result.tool_call_id);
    try std.testing.expectEqualStrings(
        "assistant_stop_aborted",
        session.messagesBorrowed()[2].tool_result.details.?.object.get("source").?.string,
    );
}

test "loop integration pairs a length-stopped tool call and resamples without executing" {
    const openai_compatible = @import("openai_compatible");
    const mock_transport = @import("../testkit/mock_transport.zig");
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const length_sse =
        "data: {\"id\":\"chatcmpl-length\",\"created\":1711115037,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-length\",\"type\":\"function\",\"function\":{\"name\":\"write\",\"arguments\":\"{\\\"content\\\":\\\"partial\\\"}\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const final_sse =
        "data: {\"id\":\"chatcmpl-after-length\",\"created\":1711115038,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{\"content\":\"split into chunks\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const script = [_]mock_transport.ScriptedResponse{ .{ .sse = length_sse }, .{ .sse = final_sse } };
    var mock = mock_transport.MockTransport.init(&script);
    const factory = openai_compatible.createOpenAiCompatible(.{
        .provider_name = "phase-1b",
        .base_url = "https://example.test/v1",
        .api_key = "dummy-key",
        .transport = mock.transport(),
    });
    var chat = try factory.chatModel("smoke-model", null);
    const Write = struct {
        fn execute(
            raw: ?*anyopaque,
            _: std.Io,
            arena: Allocator,
            _: std.json.Value,
            _: ?tool_api.OnUpdate,
            _: *const tool_api.CancelToken,
        ) anyerror!tool_api.ToolOutcome {
            const runs: *std.atomic.Value(u32) = @ptrCast(@alignCast(raw.?));
            _ = runs.fetchAdd(1, .acq_rel);
            return .{ .content = try arena.alloc(tool_api.ResultBlock, 0) };
        }
    };
    var runs = std.atomic.Value(u32).init(0);
    const write_vtable: tool_api.VTable = .{ .execute = Write.execute };
    var registry = tool_api.ToolRegistry.init(allocator);
    defer registry.deinit();
    try registry.add(.{ .ctx = &runs, .name = "write", .description = "", .input_schema = "{}", .vtable = &write_vtable });
    var session = try AgentSession.init(allocator, io, .{
        .model = .{
            .language_model = .{ .model = chat.languageModel() },
            .provider_name = "phase-1b",
            .model_id = "smoke-model",
        },
        .tools = &registry,
    });
    defer session.deinit();
    var runner = try io.concurrent(AgentSession.run, .{&session});
    var prompt = try events.OwnedPrompt.init(allocator, "write", &.{}, false, .user);
    defer prompt.deinit(allocator);
    try session.inbox().push(io, .{ .prompt = prompt });
    while (try session.outbox().pop(io)) |owned_event| {
        var event = owned_event;
        const finished = event == .run_finished;
        event.deinit(allocator);
        if (finished) break;
    }
    try session.inbox().push(io, .shutdown);
    try runner.await(io);
    try std.testing.expectEqual(@as(u32, 0), runs.load(.acquire));
    try std.testing.expectEqual(@as(usize, 4), session.messagesBorrowed().len);
    const result = session.messagesBorrowed()[2].tool_result;
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "stop_reason: length") != null);
    try std.testing.expectEqualStrings("assistant_stop_length", result.details.?.object.get("source").?.string);
}

test "loop integration delivers follow-up only after the yield boundary" {
    const openai_compatible = @import("openai_compatible");
    const mock_transport = @import("../testkit/mock_transport.zig");
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const first_sse =
        "data: {\"id\":\"chatcmpl-first\",\"created\":1711115037,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{\"content\":\"first\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const second_sse =
        "data: {\"id\":\"chatcmpl-second\",\"created\":1711115038,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{\"content\":\"second\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";
    var entered: std.Io.Event = .unset;
    var release: std.Io.Event = .unset;
    const script = [_]mock_transport.ScriptedResponse{
        .{ .blocked_sse = .{ .gate = &release, .entered = &entered, .body = first_sse } },
        .{ .sse = second_sse },
    };
    var mock = mock_transport.MockTransport.init(&script);
    const factory = openai_compatible.createOpenAiCompatible(.{
        .provider_name = "phase-1b",
        .base_url = "https://example.test/v1",
        .api_key = "dummy-key",
        .transport = mock.transport(),
    });
    var chat = try factory.chatModel("smoke-model", null);
    var registry = tool_api.ToolRegistry.init(allocator);
    defer registry.deinit();
    var session = try AgentSession.init(allocator, io, .{
        .model = .{
            .language_model = .{ .model = chat.languageModel() },
            .provider_name = "phase-1b",
            .model_id = "smoke-model",
        },
        .tools = &registry,
    });
    defer session.deinit();
    var runner = try io.concurrent(AgentSession.run, .{&session});
    var initial = try events.OwnedPrompt.init(allocator, "initial", &.{}, false, .user);
    defer initial.deinit(allocator);
    var follow = try events.OwnedPrompt.init(allocator, "follow-up", &.{}, false, .user);
    defer follow.deinit(allocator);
    try session.inbox().push(io, .{ .prompt = initial });
    try entered.wait(io);
    try session.inbox().push(io, .{ .follow_up = follow });
    try io.sleep(.fromMilliseconds(2), .awake);
    release.set(io);

    var turn_finishes: u32 = 0;
    var second_user_boundary: ?u32 = null;
    var user_starts: u32 = 0;
    while (try session.outbox().pop(io)) |owned_event| {
        var event = owned_event;
        switch (event) {
            .turn_finished => turn_finishes += 1,
            .message_started => |started| if (started.role == .user) {
                user_starts += 1;
                if (user_starts == 2) second_user_boundary = turn_finishes;
            },
            else => {},
        }
        const finished = event == .run_finished;
        event.deinit(allocator);
        if (finished) break;
    }
    try session.inbox().push(io, .shutdown);
    try runner.await(io);
    try std.testing.expectEqual(@as(?u32, 1), second_user_boundary);
    try std.testing.expectEqual(@as(usize, 4), session.messagesBorrowed().len);
    try std.testing.expectEqualStrings("follow-up", session.messagesBorrowed()[2].user.content.string);
}

test "loop integration steering after one exclusive tool skips the rest and injects next" {
    const openai_compatible = @import("openai_compatible");
    const mock_transport = @import("../testkit/mock_transport.zig");
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const tools_sse =
        "data: {\"id\":\"chatcmpl-steer\",\"created\":1711115037,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-1\",\"type\":\"function\",\"function\":{\"name\":\"gate\",\"arguments\":\"{\\\"value\\\":\\\"first\\\"}\"}},{\"index\":1,\"id\":\"call-2\",\"type\":\"function\",\"function\":{\"name\":\"gate\",\"arguments\":\"{\\\"value\\\":\\\"second\\\"}\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const final_sse =
        "data: {\"id\":\"chatcmpl-steered\",\"created\":1711115038,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{\"content\":\"handled steering\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const script = [_]mock_transport.ScriptedResponse{ .{ .sse = tools_sse }, .{ .sse = final_sse } };
    var mock = mock_transport.MockTransport.init(&script);
    const factory = openai_compatible.createOpenAiCompatible(.{
        .provider_name = "phase-1b",
        .base_url = "https://example.test/v1",
        .api_key = "dummy-key",
        .transport = mock.transport(),
    });
    var chat = try factory.chatModel("smoke-model", null);
    const GateTool = struct {
        started: std.Io.Event = .unset,
        release: std.Io.Event = .unset,
        runs: std.atomic.Value(u32) = .init(0),

        fn execute(
            raw: ?*anyopaque,
            task_io: std.Io,
            arena: Allocator,
            _: std.json.Value,
            _: ?tool_api.OnUpdate,
            _: *const tool_api.CancelToken,
        ) anyerror!tool_api.ToolOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const run_number = self.runs.fetchAdd(1, .acq_rel);
            if (run_number == 0) {
                self.started.set(task_io);
                try self.release.wait(task_io);
            }
            const content = try arena.alloc(tool_api.ResultBlock, 1);
            content[0] = .{ .text = "ok" };
            return .{ .content = content };
        }
    };
    var gate: GateTool = .{};
    const gate_vtable: tool_api.VTable = .{ .execute = GateTool.execute };
    var registry = tool_api.ToolRegistry.init(allocator);
    defer registry.deinit();
    try registry.add(.{
        .ctx = &gate,
        .name = "gate",
        .description = "",
        .input_schema = "{}",
        .concurrency = .{ .mode = .exclusive },
        .vtable = &gate_vtable,
    });
    var session = try AgentSession.init(allocator, io, .{
        .model = .{
            .language_model = .{ .model = chat.languageModel() },
            .provider_name = "phase-1b",
            .model_id = "smoke-model",
        },
        .tools = &registry,
    });
    defer session.deinit();
    var runner = try io.concurrent(AgentSession.run, .{&session});
    var initial = try events.OwnedPrompt.init(allocator, "start", &.{}, false, .user);
    defer initial.deinit(allocator);
    var steer = try events.OwnedPrompt.init(allocator, "interrupt", &.{}, false, .user);
    defer steer.deinit(allocator);
    try session.inbox().push(io, .{ .prompt = initial });
    try gate.started.wait(io);
    try session.inbox().push(io, .{ .steer = steer });
    try io.sleep(.fromMilliseconds(2), .awake);
    gate.release.set(io);
    while (try session.outbox().pop(io)) |owned_event| {
        var event = owned_event;
        const finished = event == .run_finished;
        event.deinit(allocator);
        if (finished) break;
    }
    try session.inbox().push(io, .shutdown);
    try runner.await(io);
    try std.testing.expectEqual(@as(u32, 1), gate.runs.load(.acquire));
    try std.testing.expectEqual(@as(usize, 6), session.messagesBorrowed().len);
    try std.testing.expectEqualStrings(scheduler.SKIPPED_USER_MESSAGE, session.messagesBorrowed()[3].tool_result.content[0].text.text);
    try std.testing.expectEqualStrings("interrupt", session.messagesBorrowed()[4].user.content.string);
}
