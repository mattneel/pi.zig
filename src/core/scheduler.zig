//! Tool-batch scheduling with Pi's shared/exclusive barriers and steering cuts.
//!
//! Results are returned in tool-call order even though shared tools execute
//! concurrently. Each tool receives a private arena during execution; outcomes
//! are cloned into the caller's `arena` after all tasks settle.

const std = @import("std");
const message = @import("message.zig");
const tool_api = @import("tool.zig");

const Allocator = std.mem.Allocator;

pub const STEERING_INTERRUPT_POLL_MS: u64 = 250;
pub const EMPTY_ERROR_OUTPUT = "Tool failed with no output.";
pub const SKIPPED_USER_MESSAGE = "Skipped due to queued user message. Do not count this skipped result as completed work or verification. After the queued message is handled on the next step, retry the skipped tool if it is still needed.";
pub const SKIPPED_SYSTEM_MESSAGE = "Skipped due to pending system advisory. Do not count this skipped result as completed work or verification. After the advisory is handled on the next step, retry the skipped tool if it is still needed.";
pub const SKIPPED_UNKNOWN_MESSAGE = "Skipped due to pending steering message. Do not count this skipped result as completed work or verification. After the queued message is handled on the next step, retry the skipped tool if it is still needed.";

pub const InterruptMode = enum {
    immediate,
    wait,
};

pub const SteeringSource = enum(u8) {
    user,
    system,
    unknown,
    run_user,
    run_shutdown,
    run_deadline,
    run_superseded,
    run_other,
};

pub const SteeringState = struct {
    queued: bool,
    source: SteeringSource = .unknown,
};

pub const SteeringCheck = struct {
    ctx: ?*anyopaque = null,
    check_fn: *const fn (ctx: ?*anyopaque) SteeringState,

    pub fn check(self: SteeringCheck) SteeringState {
        return self.check_fn(self.ctx);
    }
};

pub const Callbacks = struct {
    ctx: ?*anyopaque = null,
    on_started: ?*const fn (ctx: ?*anyopaque, call: message.ToolCallContent) void = null,
    on_update: ?*const fn (ctx: ?*anyopaque, call: message.ToolCallContent, partial: tool_api.ToolOutcome) void = null,
    on_finished: ?*const fn (ctx: ?*anyopaque, call: message.ToolCallContent, outcome: tool_api.ToolOutcome) void = null,
};

pub const AuthorizationResult = union(enum) {
    allow,
    deny: []const u8,
    aborted,
};

pub const Authorization = struct {
    ctx: ?*anyopaque = null,
    authorize_fn: *const fn (
        ctx: ?*anyopaque,
        io: std.Io,
        arena: Allocator,
        call: message.ToolCallContent,
        declaration: tool_api.Tool,
        scope: *CancelScope,
    ) anyerror!AuthorizationResult,
};

pub const Park = struct {
    ctx: ?*anyopaque = null,
    wait_fn: *const fn (ctx: ?*anyopaque, io: std.Io, scope: *CancelScope) std.Io.Cancelable!void,
};

pub const ToolFilter = struct {
    ctx: ?*anyopaque = null,
    enabled_fn: *const fn (ctx: ?*anyopaque, name: []const u8) bool,
};

/// A per-batch cooperative cancel scope. Cancellation is idempotent and wakes
/// every tool task currently racing its execution against the scope.
pub const CancelScope = struct {
    cancelled: std.atomic.Value(bool) = .init(false),
    event: std.Io.Event = .unset,
    source: std.atomic.Value(SteeringSource) = .init(.unknown),
    wake_ctx: ?*anyopaque = null,
    wake_fn: ?*const fn (ctx: ?*anyopaque, io: std.Io) void = null,

    pub fn cancel(self: *CancelScope, io: std.Io, source: SteeringSource) void {
        self.source.store(source, .release);
        if (!self.cancelled.swap(true, .acq_rel)) {
            self.event.set(io);
            if (self.wake_fn) |wake| wake(self.wake_ctx, io);
        }
    }

    pub fn isCancelled(self: *const CancelScope) bool {
        return self.cancelled.load(.acquire);
    }
};

pub const Options = struct {
    interrupt_mode: InterruptMode = .immediate,
    steering: ?SteeringCheck = null,
    callbacks: Callbacks = .{},
    authorization: ?Authorization = null,
    park_before_tool: ?Park = null,
    tool_filter: ?ToolFilter = null,
    timestamp_ms: i64 = 0,
};

pub const BatchResult = struct {
    tool_results: []const message.ToolResultMessage,
    interrupted: bool,
};

threadlocal var active_update_callbacks: ?Callbacks = null;
threadlocal var active_update_call: ?message.ToolCallContent = null;

fn forwardUpdate(partial: tool_api.ToolOutcome) void {
    const callbacks = active_update_callbacks orelse return;
    const call = active_update_call orelse return;
    if (callbacks.on_update) |callback| callback(callbacks.ctx, call, partial);
}

const Record = struct {
    call: message.ToolCallContent,
    declaration: ?*const tool_api.Tool,
    mode: tool_api.Concurrency,
    arena_state: std.heap.ArenaAllocator,
    outcome: ?tool_api.ToolOutcome = null,
    timed_out: std.atomic.Value(bool) = .init(false),
    running: std.atomic.Value(bool) = .init(false),
    callbacks: Callbacks,
    authorization: ?Authorization,
    park_before_tool: ?Park,
    steering: ?SteeringCheck,
    interrupt_mode: InterruptMode,
    scope: *CancelScope,
    direct_execution: bool = false,
};

/// `gpa` must support concurrent allocation; each shared tool owns a private
/// arena backed by it while `arena` is touched only after the batch settles.
/// Shared execution uses the supplied `std.Io` implementation's async
/// capability and degrades to serial execution when tasks run inline. The
/// steering watcher requires real concurrency; when unavailable, steering is
/// still observed at normal tool and batch boundaries.
pub fn executeToolCalls(
    io: std.Io,
    gpa: Allocator,
    arena: Allocator,
    calls: []const message.ToolCallContent,
    registry: *const tool_api.ToolRegistry,
    scope: *CancelScope,
    options: Options,
) !BatchResult {
    const records = try gpa.alloc(Record, calls.len);
    defer gpa.free(records);
    var initialized: usize = 0;
    defer for (records[0..initialized]) |*record| record.arena_state.deinit();

    var has_interruptible = false;
    for (calls, records) |call, *record| {
        const declaration = if (options.tool_filter) |filter|
            if (filter.enabled_fn(filter.ctx, call.name)) registry.get(call.name) else null
        else
            registry.get(call.name);
        const mode = if (declaration) |value| value.resolveConcurrency(call.arguments) else .exclusive;
        record.* = .{
            .call = call,
            .declaration = declaration,
            .mode = mode,
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .callbacks = options.callbacks,
            .authorization = options.authorization,
            .park_before_tool = options.park_before_tool,
            .steering = options.steering,
            .interrupt_mode = options.interrupt_mode,
            .scope = scope,
        };
        initialized += 1;
        has_interruptible = has_interruptible or (declaration != null and declaration.?.interruptible);
    }

    var watcher_done = std.atomic.Value(bool).init(false);
    var watcher: ?std.Io.Future(std.Io.Cancelable!void) = null;
    var watcher_unavailable = false;
    if (options.interrupt_mode == .immediate and options.steering != null and has_interruptible) {
        watcher = io.concurrent(watchSteering, .{ io, scope, options.steering.?, &watcher_done }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => unavailable: {
                watcher_unavailable = true;
                break :unavailable null;
            },
        };
    }
    if (watcher_unavailable) {
        for (records) |*record| record.direct_execution = true;
    }
    defer if (watcher) |*future| {
        watcher_done.store(true, .release);
        _ = future.cancel(io) catch |err| switch (err) {
            error.Canceled => {},
        };
    };

    var index: usize = 0;
    while (index < records.len) {
        if (records[index].mode == .exclusive) {
            try runRecord(io, &records[index]);
            index += 1;
            continue;
        }

        const start = index;
        while (index < records.len and records[index].mode == .shared) : (index += 1) {}
        const segment = records[start..index];
        const futures = try gpa.alloc(std.Io.Future(anyerror!void), segment.len);
        defer gpa.free(futures);
        for (segment, futures) |*record, *future| {
            future.* = io.async(runRecord, .{ io, record });
        }
        var first_error: ?anyerror = null;
        for (futures) |*future| {
            future.await(io) catch |err| if (first_error == null) {
                first_error = err;
            };
        }
        if (first_error) |err| return err;
    }

    watcher_done.store(true, .release);
    if (watcher) |*future| {
        _ = future.cancel(io) catch |err| switch (err) {
            error.Canceled => {},
        };
        watcher = null;
    }

    const results = try arena.alloc(message.ToolResultMessage, records.len);
    for (records, results) |*record, *destination| {
        const outcome = try tool_api.cloneOutcome(arena, record.outcome orelse unreachable);
        const blocks = try arena.alloc(message.TextImageBlock, outcome.content.len);
        for (outcome.content, blocks) |block, *output| output.* = switch (block) {
            .text => |text| .{ .text = .{ .text = text } },
            .image => |image| .{ .image = .{ .data = image.data, .mime_type = image.mime_type } },
        };
        destination.* = .{
            .tool_call_id = try arena.dupe(u8, record.call.id),
            .tool_name = try arena.dupe(u8, record.call.name),
            .content = blocks,
            .details = outcome.details,
            .is_error = outcome.is_error,
            .useless = if (outcome.is_error) null else outcome.useless,
            .timestamp = options.timestamp_ms,
        };
    }
    return .{ .tool_results = results, .interrupted = scope.isCancelled() };
}

fn runRecord(io: std.Io, record: *Record) anyerror!void {
    const arena = record.arena_state.allocator();
    if (record.scope.isCancelled()) {
        record.outcome = try skippedOutcome(arena, record.scope.source.load(.acquire));
        emitLifecycle(record);
        return;
    }
    if (record.park_before_tool) |park| try park.wait_fn(park.ctx, io, record.scope);
    if (record.scope.isCancelled()) {
        record.outcome = try skippedOutcome(arena, record.scope.source.load(.acquire));
        emitLifecycle(record);
        return;
    }

    record.running.store(true, .release);
    defer record.running.store(false, .release);
    if (record.callbacks.on_started) |callback| callback(record.callbacks.ctx, record.call);

    const declaration = record.declaration orelse {
        record.outcome = try errorOutcome(arena, try std.fmt.allocPrint(arena, "Tool {s} not found", .{record.call.name}));
        emitFinished(record);
        try checkSteering(io, record);
        return;
    };
    if (record.authorization) |authorization| {
        const decision = authorization.authorize_fn(
            authorization.ctx,
            io,
            arena,
            record.call,
            declaration.*,
            record.scope,
        ) catch |err| AuthorizationResult{ .deny = @errorName(err) };
        switch (decision) {
            .allow => {},
            .deny => |reason| {
                record.outcome = try errorOutcome(arena, reason);
                emitFinished(record);
                try checkSteering(io, record);
                return;
            },
            .aborted => {
                record.outcome = try skippedOutcome(arena, record.scope.source.load(.acquire));
                emitFinished(record);
                return;
            },
        }
    }
    const token: tool_api.CancelToken = .{
        .batch_cancelled = &record.scope.cancelled,
        .timed_out = &record.timed_out,
    };
    const Context = struct {
        declaration: tool_api.Tool,
        io: std.Io,
        arena: Allocator,
        input: std.json.Value,
        callbacks: Callbacks,
        call: message.ToolCallContent,
        token: *const tool_api.CancelToken,

        fn execute(self: @This()) anyerror!tool_api.ToolOutcome {
            active_update_callbacks = self.callbacks;
            active_update_call = self.call;
            defer {
                active_update_callbacks = null;
                active_update_call = null;
            }
            return self.declaration.execute(
                self.io,
                self.arena,
                self.input,
                if (self.callbacks.on_update != null) forwardUpdate else null,
                self.token,
            );
        }
    };

    const context = Context{
        .declaration = declaration.*,
        .io = io,
        .arena = arena,
        .input = record.call.arguments,
        .callbacks = record.callbacks,
        .call = record.call,
        .token = &token,
    };
    if (record.direct_execution) {
        record.outcome = try normalizeOutcome(arena, context.execute() catch |err| try errorOutcome(arena, @errorName(err)));
        emitFinished(record);
        try checkSteering(io, record);
        return;
    }

    const Race = union(enum) {
        execution: anyerror!tool_api.ToolOutcome,
        cancelled: std.Io.Cancelable!void,
        deadline: std.Io.Cancelable!void,
    };
    var buffer: [3]Race = undefined;
    var select: std.Io.Select(Race) = .init(io, &buffer);
    defer select.cancelDiscard();
    select.async(.execution, Context.execute, .{context});
    select.async(.cancelled, waitForCancel, .{ io, record.scope });
    if (declaration.timeout_ms) |milliseconds| {
        select.async(.deadline, sleepMilliseconds, .{ io, milliseconds });
    }

    const selected = try select.await();
    record.outcome = try switch (selected) {
        .execution => |result| normalizeOutcome(arena, result catch |err| try errorOutcome(arena, @errorName(err))),
        .cancelled => |result| blk: {
            try result;
            break :blk try skippedOutcome(arena, record.scope.source.load(.acquire));
        },
        .deadline => |result| blk: {
            try result;
            record.timed_out.store(true, .release);
            break :blk try errorOutcome(arena, "Tool execution timed out.");
        },
    };
    emitFinished(record);
    try checkSteering(io, record);
}

fn emitLifecycle(record: *Record) void {
    if (record.callbacks.on_started) |callback| callback(record.callbacks.ctx, record.call);
    emitFinished(record);
}

fn emitFinished(record: *Record) void {
    if (record.callbacks.on_finished) |callback| {
        callback(record.callbacks.ctx, record.call, record.outcome orelse unreachable);
    }
}

fn checkSteering(io: std.Io, record: *Record) !void {
    if (record.interrupt_mode == .wait or record.scope.isCancelled()) return;
    const check = record.steering orelse return;
    const state = check.check();
    if (state.queued) record.scope.cancel(io, state.source);
}

fn watchSteering(
    io: std.Io,
    scope: *CancelScope,
    check: SteeringCheck,
    done: *const std.atomic.Value(bool),
) std.Io.Cancelable!void {
    while (!done.load(.acquire) and !scope.isCancelled()) {
        try sleepMilliseconds(io, STEERING_INTERRUPT_POLL_MS);
        if (done.load(.acquire) or scope.isCancelled()) return;
        const state = check.check();
        if (state.queued) {
            scope.cancel(io, state.source);
            return;
        }
    }
}

fn waitForCancel(io: std.Io, scope: *CancelScope) std.Io.Cancelable!void {
    return scope.event.wait(io);
}

fn sleepMilliseconds(io: std.Io, milliseconds: u64) std.Io.Cancelable!void {
    const bounded: i64 = @intCast(@min(milliseconds, @as(u64, std.math.maxInt(i64))));
    return io.sleep(.fromMilliseconds(bounded), .awake);
}

fn normalizeOutcome(arena: Allocator, source: tool_api.ToolOutcome) !tool_api.ToolOutcome {
    const content = try arena.alloc(tool_api.ResultBlock, source.content.len);
    for (source.content, content) |block, *destination| destination.* = switch (block) {
        .text => |text| .{ .text = try sanitizeText(arena, text) },
        .image => |image| .{ .image = image },
    };
    const normalized: tool_api.ToolOutcome = .{
        .content = content,
        .details = source.details,
        .is_error = source.is_error,
        .useless = if (source.is_error) null else source.useless,
    };
    if (!normalized.is_error) return normalized;
    var has_output = false;
    for (normalized.content) |block| switch (block) {
        .text => |text| has_output = has_output or std.mem.trim(u8, text, " \t\r\n").len != 0,
        .image => has_output = true,
    };
    if (has_output) return .{
        .content = normalized.content,
        .details = normalized.details,
        .is_error = true,
        .useless = null,
    };
    return errorOutcome(arena, EMPTY_ERROR_OUTPUT);
}

fn sanitizeText(arena: Allocator, source: []const u8) ![]const u8 {
    const without_ansi = try stripAnsi(arena, source);
    const malformed = !std.unicode.utf8ValidateSlice(without_ansi);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(arena);

    var index: usize = 0;
    while (index < without_ansi.len) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(without_ansi[index]) catch {
            index += 1;
            continue;
        };
        const end = index + sequence_len;
        if (end > without_ansi.len) {
            index += 1;
            continue;
        }
        const codepoint = std.unicode.utf8Decode(without_ansi[index..end]) catch {
            index += 1;
            continue;
        };
        if (!isTextControl(codepoint) and !(malformed and codepoint == 0xfffd)) {
            try output.appendSlice(arena, without_ansi[index..end]);
        }
        index = end;
    }
    return output.toOwnedSlice(arena);
}

fn stripAnsi(arena: Allocator, source: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(arena);
    var index: usize = 0;
    while (index < source.len) {
        if (source[index] == 0x1b) {
            index = ansiSequenceEnd(source, index);
            continue;
        }
        try output.append(arena, source[index]);
        index += 1;
    }
    return output.toOwnedSlice(arena);
}

fn ansiSequenceEnd(source: []const u8, start: usize) usize {
    if (start + 1 >= source.len) return source.len;
    const introducer = source[start + 1];
    if (introducer == '[') {
        var index = start + 2;
        while (index < source.len) : (index += 1) {
            if (source[index] >= 0x40 and source[index] <= 0x7e) return index + 1;
        }
        return source.len;
    }
    if (introducer == ']' or introducer == 'P' or introducer == 'X' or introducer == '^' or introducer == '_') {
        var index = start + 2;
        while (index < source.len) : (index += 1) {
            if (source[index] == 0x07) return index + 1;
            if (source[index] == 0x1b and index + 1 < source.len and source[index + 1] == '\\') return index + 2;
        }
        return source.len;
    }

    var index = start + 1;
    while (index < source.len and source[index] >= 0x20 and source[index] <= 0x2f) : (index += 1) {}
    if (index < source.len and source[index] >= 0x30 and source[index] <= 0x7e) return index + 1;
    return start + 1;
}

fn isTextControl(codepoint: u21) bool {
    return codepoint <= 0x08 or
        (codepoint >= 0x0b and codepoint <= 0x1f) or
        (codepoint >= 0x7f and codepoint <= 0x9f);
}

fn errorOutcome(arena: Allocator, text: []const u8) !tool_api.ToolOutcome {
    const content = try arena.alloc(tool_api.ResultBlock, 1);
    content[0] = .{ .text = try arena.dupe(u8, text) };
    return .{ .content = content, .is_error = true };
}

fn skippedOutcome(arena: Allocator, source: SteeringSource) !tool_api.ToolOutcome {
    const text = switch (source) {
        .user => SKIPPED_USER_MESSAGE,
        .system => SKIPPED_SYSTEM_MESSAGE,
        .unknown => SKIPPED_UNKNOWN_MESSAGE,
        .run_user => "Tool was not executed because the run was aborted: Interrupted by user.",
        .run_shutdown => "Tool was not executed because the run was aborted: Shutdown requested.",
        .run_deadline => "Tool was not executed because the run was aborted: Deadline exceeded.",
        .run_superseded => "Tool was not executed because the run was aborted: Superseded.",
        .run_other => "Tool was not executed because the run was aborted: Request was aborted.",
    };
    const details: std.json.ObjectMap = .empty;
    const content = try arena.alloc(tool_api.ResultBlock, 1);
    content[0] = .{ .text = try arena.dupe(u8, text) };
    return .{ .content = content, .details = .{ .object = details }, .is_error = true };
}

fn jsonObject(arena: Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{ .allocate = .alloc_always });
}

test "scheduler runs shared tools concurrently and exclusive tools behind a barrier" {
    const State = struct {
        first_started: std.Io.Event = .unset,
        release_first: std.Io.Event = .unset,
        completed: std.atomic.Value(u32) = .init(0),
        exclusive_saw: std.atomic.Value(u32) = .init(0),

        fn execute(
            raw: ?*anyopaque,
            io: std.Io,
            arena: Allocator,
            input: std.json.Value,
            _: ?tool_api.OnUpdate,
            _: *const tool_api.CancelToken,
        ) anyerror!tool_api.ToolOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const value = input.object.get("value").?.string;
            if (std.mem.eql(u8, value, "slow")) {
                self.first_started.set(io);
                try self.release_first.wait(io);
            } else if (std.mem.eql(u8, value, "fast")) {
                try self.first_started.wait(io);
                self.release_first.set(io);
            } else {
                self.exclusive_saw.store(self.completed.load(.acquire), .release);
            }
            _ = self.completed.fetchAdd(1, .acq_rel);
            const blocks = try arena.alloc(tool_api.ResultBlock, 1);
            blocks[0] = .{ .text = value };
            return .{ .content = blocks };
        }

        fn concurrency(_: ?*anyopaque, input: std.json.Value) tool_api.Concurrency {
            const value = input.object.get("value").?.string;
            return if (std.mem.eql(u8, value, "exclusive")) .exclusive else .shared;
        }
    };
    var state: State = .{};
    const vtable: tool_api.VTable = .{ .execute = State.execute };
    var registry = tool_api.ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.add(.{
        .ctx = &state,
        .name = "work",
        .description = "work",
        .input_schema = "{}",
        .concurrency = .{ .dynamic = State.concurrency },
        .vtable = &vtable,
    });
    var input_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer input_arena_state.deinit();
    const input_arena = input_arena_state.allocator();
    const calls = [_]message.ToolCallContent{
        .{ .id = "1", .name = "work", .arguments = try jsonObject(input_arena, "{\"value\":\"slow\"}") },
        .{ .id = "2", .name = "work", .arguments = try jsonObject(input_arena, "{\"value\":\"fast\"}") },
        .{ .id = "3", .name = "work", .arguments = try jsonObject(input_arena, "{\"value\":\"exclusive\"}") },
    };
    var output_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer output_arena_state.deinit();
    var scope: CancelScope = .{};
    const result = try executeToolCalls(
        std.testing.io,
        std.testing.allocator,
        output_arena_state.allocator(),
        &calls,
        &registry,
        &scope,
        .{},
    );
    try std.testing.expectEqual(@as(usize, 3), result.tool_results.len);
    try std.testing.expectEqual(@as(u32, 2), state.exclusive_saw.load(.acquire));
    try std.testing.expectEqualStrings("1", result.tool_results[0].tool_call_id);
    try std.testing.expectEqualStrings("3", result.tool_results[2].tool_call_id);
}

test "scheduler steering skips remaining exclusive calls with exact user text" {
    const State = struct {
        runs: std.atomic.Value(u32) = .init(0),

        fn execute(
            raw: ?*anyopaque,
            _: std.Io,
            arena: Allocator,
            _: std.json.Value,
            _: ?tool_api.OnUpdate,
            _: *const tool_api.CancelToken,
        ) anyerror!tool_api.ToolOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            _ = self.runs.fetchAdd(1, .acq_rel);
            const blocks = try arena.alloc(tool_api.ResultBlock, 1);
            blocks[0] = .{ .text = "ok" };
            return .{ .content = blocks };
        }

        fn steering(raw: ?*anyopaque) SteeringState {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return .{ .queued = self.runs.load(.acquire) != 0, .source = .user };
        }
    };
    var state: State = .{};
    const vtable: tool_api.VTable = .{ .execute = State.execute };
    var registry = tool_api.ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.add(.{
        .ctx = &state,
        .name = "one",
        .description = "one",
        .input_schema = "{}",
        .concurrency = .{ .mode = .exclusive },
        .vtable = &vtable,
    });
    var input_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer input_arena_state.deinit();
    const empty = try jsonObject(input_arena_state.allocator(), "{}");
    const calls = [_]message.ToolCallContent{
        .{ .id = "1", .name = "one", .arguments = empty },
        .{ .id = "2", .name = "one", .arguments = empty },
    };
    var output_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer output_arena_state.deinit();
    var scope: CancelScope = .{};
    const result = try executeToolCalls(
        std.testing.io,
        std.testing.allocator,
        output_arena_state.allocator(),
        &calls,
        &registry,
        &scope,
        .{ .steering = .{ .ctx = &state, .check_fn = State.steering } },
    );
    try std.testing.expectEqual(@as(u32, 1), state.runs.load(.acquire));
    try std.testing.expectEqualStrings(SKIPPED_USER_MESSAGE, result.tool_results[1].content[0].text.text);
    try std.testing.expect(result.tool_results[1].is_error);
}

test "scheduler turns thrown and empty errors into data" {
    const ErrorTool = struct {
        fn execute(
            raw: ?*anyopaque,
            _: std.Io,
            arena: Allocator,
            _: std.json.Value,
            _: ?tool_api.OnUpdate,
            _: *const tool_api.CancelToken,
        ) anyerror!tool_api.ToolOutcome {
            if (raw == null) return error.Exploded;
            const blocks = try arena.alloc(tool_api.ResultBlock, 1);
            blocks[0] = .{ .text = " \n" };
            return .{ .content = blocks, .is_error = true, .useless = true };
        }
    };
    const vtable: tool_api.VTable = .{ .execute = ErrorTool.execute };
    var marker: u8 = 0;
    var registry = tool_api.ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.add(.{ .name = "throw", .description = "", .input_schema = "{}", .vtable = &vtable });
    try registry.add(.{ .ctx = &marker, .name = "empty", .description = "", .input_schema = "{}", .vtable = &vtable });
    var input_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer input_arena_state.deinit();
    const empty = try jsonObject(input_arena_state.allocator(), "{}");
    const calls = [_]message.ToolCallContent{
        .{ .id = "1", .name = "throw", .arguments = empty },
        .{ .id = "2", .name = "empty", .arguments = empty },
    };
    var output_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer output_arena_state.deinit();
    var scope: CancelScope = .{};
    const result = try executeToolCalls(std.testing.io, std.testing.allocator, output_arena_state.allocator(), &calls, &registry, &scope, .{});
    try std.testing.expectEqualStrings("Exploded", result.tool_results[0].content[0].text.text);
    try std.testing.expectEqualStrings(EMPTY_ERROR_OUTPUT, result.tool_results[1].content[0].text.text);
    try std.testing.expect(result.tool_results[1].useless == null);
}

test "scheduler parks before starting a tool without cancelling the batch" {
    const State = struct {
        release: std.Io.Event = .unset,
        parked: std.Io.Event = .unset,
        runs: std.atomic.Value(u32) = .init(0),

        fn wait(raw: ?*anyopaque, io: std.Io, _: *CancelScope) std.Io.Cancelable!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.parked.set(io);
            return self.release.wait(io);
        }

        fn execute(
            raw: ?*anyopaque,
            _: std.Io,
            arena: Allocator,
            _: std.json.Value,
            _: ?tool_api.OnUpdate,
            _: *const tool_api.CancelToken,
        ) anyerror!tool_api.ToolOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            _ = self.runs.fetchAdd(1, .acq_rel);
            const content = try arena.alloc(tool_api.ResultBlock, 1);
            content[0] = .{ .text = "ran" };
            return .{ .content = content };
        }
    };
    var state: State = .{};
    const vtable: tool_api.VTable = .{ .execute = State.execute };
    var registry = tool_api.ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.add(.{ .ctx = &state, .name = "parked", .description = "", .input_schema = "{}", .vtable = &vtable });
    var input_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer input_arena_state.deinit();
    const call: message.ToolCallContent = .{
        .id = "1",
        .name = "parked",
        .arguments = try jsonObject(input_arena_state.allocator(), "{}"),
    };
    var output_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer output_arena_state.deinit();
    var scope: CancelScope = .{};
    const Runner = struct {
        fn run(
            arena: Allocator,
            selected_registry: *const tool_api.ToolRegistry,
            selected_scope: *CancelScope,
            selected_call: *const message.ToolCallContent,
            selected_state: *State,
        ) anyerror!BatchResult {
            return executeToolCalls(
                std.testing.io,
                std.testing.allocator,
                arena,
                selected_call[0..1],
                selected_registry,
                selected_scope,
                .{ .park_before_tool = .{ .ctx = selected_state, .wait_fn = State.wait } },
            );
        }
    };
    var future = std.testing.io.async(Runner.run, .{
        output_arena_state.allocator(),
        &registry,
        &scope,
        &call,
        &state,
    });
    try state.parked.wait(std.testing.io);
    try std.testing.expectEqual(@as(u32, 0), state.runs.load(.acquire));
    state.release.set(std.testing.io);
    const result = try future.await(std.testing.io);
    try std.testing.expectEqualStrings("ran", result.tool_results[0].content[0].text.text);
}

test "scheduler per-tool timeout cancels blocking execution" {
    const Slow = struct {
        fn execute(
            _: ?*anyopaque,
            io: std.Io,
            arena: Allocator,
            _: std.json.Value,
            _: ?tool_api.OnUpdate,
            cancel: *const tool_api.CancelToken,
        ) anyerror!tool_api.ToolOutcome {
            while (true) {
                try cancel.check();
                try io.sleep(.fromMilliseconds(10), .awake);
            }
            const blocks = try arena.alloc(tool_api.ResultBlock, 0);
            return .{ .content = blocks };
        }
    };
    const vtable: tool_api.VTable = .{ .execute = Slow.execute };
    var registry = tool_api.ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.add(.{ .name = "slow", .description = "", .input_schema = "{}", .timeout_ms = 25, .vtable = &vtable });
    var input_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer input_arena_state.deinit();
    const call: message.ToolCallContent = .{
        .id = "1",
        .name = "slow",
        .arguments = try jsonObject(input_arena_state.allocator(), "{}"),
    };
    var output_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer output_arena_state.deinit();
    var scope: CancelScope = .{};
    const result = try executeToolCalls(std.testing.io, std.testing.allocator, output_arena_state.allocator(), &.{call}, &registry, &scope, .{});
    try std.testing.expectEqualStrings("Tool execution timed out.", result.tool_results[0].content[0].text.text);
}

test "scheduler interruptible tool observes the 250ms non-consuming steering poll" {
    const State = struct {
        started: std.Io.Event = .unset,
        queued: std.atomic.Value(bool) = .init(false),
        observed_cancel: std.atomic.Value(bool) = .init(false),

        fn execute(
            raw: ?*anyopaque,
            io: std.Io,
            arena: Allocator,
            _: std.json.Value,
            _: ?tool_api.OnUpdate,
            cancel: *const tool_api.CancelToken,
        ) anyerror!tool_api.ToolOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.started.set(io);
            while (!cancel.isCancelled()) try io.sleep(.fromMilliseconds(10), .awake);
            self.observed_cancel.store(true, .release);
            const content = try arena.alloc(tool_api.ResultBlock, 1);
            content[0] = .{ .text = "cancelled" };
            return .{ .content = content, .is_error = true };
        }

        fn steering(raw: ?*anyopaque) SteeringState {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return .{ .queued = self.queued.load(.acquire), .source = .user };
        }
    };
    var state: State = .{};
    const vtable: tool_api.VTable = .{ .execute = State.execute };
    var registry = tool_api.ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.add(.{
        .ctx = &state,
        .name = "wait",
        .description = "",
        .input_schema = "{}",
        .interruptible = true,
        .vtable = &vtable,
    });
    var input_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer input_arena_state.deinit();
    const call: message.ToolCallContent = .{
        .id = "1",
        .name = "wait",
        .arguments = try jsonObject(input_arena_state.allocator(), "{}"),
    };
    var output_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer output_arena_state.deinit();
    var scope: CancelScope = .{};
    const Runner = struct {
        fn run(
            io: std.Io,
            arena: Allocator,
            selected_registry: *const tool_api.ToolRegistry,
            selected_scope: *CancelScope,
            selected_call: *const message.ToolCallContent,
            selected_state: *State,
        ) anyerror!BatchResult {
            return executeToolCalls(
                io,
                std.testing.allocator,
                arena,
                selected_call[0..1],
                selected_registry,
                selected_scope,
                .{ .steering = .{ .ctx = selected_state, .check_fn = State.steering } },
            );
        }
    };
    var future = std.testing.io.async(Runner.run, .{
        std.testing.io,
        output_arena_state.allocator(),
        &registry,
        &scope,
        &call,
        &state,
    });
    try state.started.wait(std.testing.io);
    state.queued.store(true, .release);
    const result = try future.await(std.testing.io);
    try std.testing.expect(result.interrupted);
    try std.testing.expectEqualStrings(SKIPPED_USER_MESSAGE, result.tool_results[0].content[0].text.text);
}

test "scheduler completes an interruptible batch without background concurrency" {
    const Echo = struct {
        fn execute(
            _: ?*anyopaque,
            _: std.Io,
            arena: Allocator,
            input: std.json.Value,
            _: ?tool_api.OnUpdate,
            _: *const tool_api.CancelToken,
        ) anyerror!tool_api.ToolOutcome {
            const content = try arena.alloc(tool_api.ResultBlock, 1);
            content[0] = .{ .text = try arena.dupe(u8, input.object.get("value").?.string) };
            return .{ .content = content };
        }

        fn steering(_: ?*anyopaque) SteeringState {
            return .{ .queued = false };
        }
    };
    const vtable: tool_api.VTable = .{ .execute = Echo.execute };
    var registry = tool_api.ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.add(.{
        .name = "echo",
        .description = "",
        .input_schema = "{}",
        .interruptible = true,
        .vtable = &vtable,
    });
    var input_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer input_arena_state.deinit();
    const input_arena = input_arena_state.allocator();
    const calls = [_]message.ToolCallContent{
        .{ .id = "1", .name = "echo", .arguments = try jsonObject(input_arena, "{\"value\":\"one\"}") },
        .{ .id = "2", .name = "echo", .arguments = try jsonObject(input_arena, "{\"value\":\"two\"}") },
    };
    var output_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer output_arena_state.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var scope: CancelScope = .{};
    const result = try executeToolCalls(
        io,
        std.testing.allocator,
        output_arena_state.allocator(),
        &calls,
        &registry,
        &scope,
        .{ .steering = .{ .check_fn = Echo.steering } },
    );
    try std.testing.expect(!result.interrupted);
    try std.testing.expectEqual(@as(usize, 2), result.tool_results.len);
    try std.testing.expectEqualStrings("one", result.tool_results[0].content[0].text.text);
    try std.testing.expectEqualStrings("two", result.tool_results[1].content[0].text.text);
}

test "scheduler centrally sanitizes persisted tool result text" {
    const RawText = struct {
        fn execute(
            _: ?*anyopaque,
            _: std.Io,
            arena: Allocator,
            _: std.json.Value,
            _: ?tool_api.OnUpdate,
            _: *const tool_api.CancelToken,
        ) anyerror!tool_api.ToolOutcome {
            const content = try arena.alloc(tool_api.ResultBlock, 1);
            content[0] = .{ .text = "\x1b[31mred\x1b[0m\ra\x00b\tline\ncarriage\r\x01\xc2\x85\xed\xa0\x80" };
            return .{ .content = content };
        }
    };
    const vtable: tool_api.VTable = .{ .execute = RawText.execute };
    var registry = tool_api.ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.add(.{ .name = "raw", .description = "", .input_schema = "{}", .vtable = &vtable });
    var input_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer input_arena_state.deinit();
    const call: message.ToolCallContent = .{
        .id = "1",
        .name = "raw",
        .arguments = try jsonObject(input_arena_state.allocator(), "{}"),
    };
    var output_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer output_arena_state.deinit();
    var scope: CancelScope = .{};
    const result = try executeToolCalls(
        std.testing.io,
        std.testing.allocator,
        output_arena_state.allocator(),
        &.{call},
        &registry,
        &scope,
        .{},
    );
    try std.testing.expectEqualStrings(
        "redab\tline\ncarriage",
        result.tool_results[0].content[0].text.text,
    );
}
