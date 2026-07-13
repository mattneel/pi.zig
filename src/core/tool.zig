//! Tool definitions exposed to the agent loop.
//!
//! A `Tool` borrows its declaration strings and implementation context. A
//! registry owns only its lookup tables; declarations must outlive the registry
//! and every model call or tool batch that uses it. Tool outcomes borrow the
//! arena passed to `execute`.

const std = @import("std");
const ai = @import("ai");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const approval = @import("approval.zig");
const message = @import("message.zig");

const Allocator = std.mem.Allocator;

pub const Concurrency = enum {
    shared,
    exclusive,
};

pub const ImageBlock = struct {
    data: []const u8,
    mime_type: []const u8,
};

pub const ResultBlock = union(enum) {
    text: []const u8,
    image: ImageBlock,
};

pub const ToolOutcome = struct {
    content: []const ResultBlock,
    details: ?std.json.Value = null,
    is_error: bool = false,
    useless: ?bool = null,
};

pub const OnUpdate = *const fn (partial: ToolOutcome) void;

/// Cooperative cancellation state passed to tools. The scheduler also cancels
/// the `std.Io` task that runs a tool, so tools which block in `std.Io` calls
/// receive `error.Canceled`; CPU-bound tools should call `check` periodically.
pub const CancelToken = struct {
    batch_cancelled: *const std.atomic.Value(bool),
    timed_out: *const std.atomic.Value(bool),

    pub fn isCancelled(self: *const CancelToken) bool {
        return self.batch_cancelled.load(.acquire) or self.timed_out.load(.acquire);
    }

    pub fn isTimedOut(self: *const CancelToken) bool {
        return self.timed_out.load(.acquire);
    }

    pub fn check(self: *const CancelToken) error{Canceled}!void {
        if (self.isCancelled()) return error.Canceled;
    }
};

pub const ExecuteFn = *const fn (
    ctx: ?*anyopaque,
    io: std.Io,
    arena: Allocator,
    input: std.json.Value,
    on_update: ?OnUpdate,
    cancel: *const CancelToken,
) anyerror!ToolOutcome;

pub const ResolveConcurrencyFn = *const fn (
    ctx: ?*anyopaque,
    raw_args: std.json.Value,
) Concurrency;

pub const ConcurrencyDecl = union(enum) {
    mode: Concurrency,
    dynamic: ResolveConcurrencyFn,
};

pub const IntentMode = enum {
    require,
    optional,
    omit,
};

pub const DeriveIntentFn = *const fn (ctx: ?*anyopaque, args: std.json.Value) ?[]const u8;

pub const IntentDecl = union(enum) {
    mode: IntentMode,
    dynamic: DeriveIntentFn,
};

pub const FormatApprovalDetailsFn = *const fn (
    ctx: ?*anyopaque,
    arena: Allocator,
    raw_args: std.json.Value,
) anyerror!?[]const u8;

pub const VTable = struct {
    execute: ExecuteFn,
    format_approval_details: ?FormatApprovalDetailsFn = null,
};

pub const Tool = struct {
    ctx: ?*anyopaque = null,
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
    concurrency: ConcurrencyDecl = .{ .mode = .shared },
    interruptible: bool = false,
    timeout_ms: ?u64 = null,
    approval: approval.ToolApprovalDecl = .{ .tier = .exec },
    intent: IntentDecl = .{ .mode = .require },
    vtable: *const VTable,

    pub fn resolveConcurrency(self: Tool, raw_args: std.json.Value) Concurrency {
        return switch (self.concurrency) {
            .mode => |mode| mode,
            .dynamic => |resolve| resolve(self.ctx, raw_args),
        };
    }

    pub fn execute(
        self: Tool,
        io: std.Io,
        arena: Allocator,
        input: std.json.Value,
        on_update: ?OnUpdate,
        cancel: *const CancelToken,
    ) anyerror!ToolOutcome {
        return self.vtable.execute(self.ctx, io, arena, input, on_update, cancel);
    }

    pub fn formatApprovalDetails(
        self: Tool,
        arena: Allocator,
        raw_args: std.json.Value,
    ) anyerror!?[]const u8 {
        const format = self.vtable.format_approval_details orelse return null;
        return format(self.ctx, arena, raw_args);
    }
};

/// Name-indexed, non-owning tool registry. `buildNamedTools` allocates only the
/// returned ai.zig declarations in `arena`; every declaration has
/// `tool.execute = null`, leaving execution to the pi.zig scheduler.
/// Finish registration before model calls begin; concurrent lookup is read-only.
pub const ToolRegistry = struct {
    allocator: Allocator,
    tools: std.ArrayList(Tool) = .empty,
    by_name: std.StringHashMapUnmanaged(usize) = .empty,

    pub fn init(allocator: Allocator) ToolRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ToolRegistry) void {
        self.tools.deinit(self.allocator);
        self.by_name.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(self: *ToolRegistry, declaration: Tool) !void {
        if (self.by_name.contains(declaration.name)) return error.DuplicateTool;
        const index = self.tools.items.len;
        try self.tools.append(self.allocator, declaration);
        errdefer _ = self.tools.pop();
        try self.by_name.put(self.allocator, declaration.name, index);
    }

    pub fn get(self: *const ToolRegistry, name: []const u8) ?*const Tool {
        const index = self.by_name.get(name) orelse return null;
        return &self.tools.items[index];
    }

    pub fn buildNamedTools(
        self: *const ToolRegistry,
        arena: Allocator,
        active: ?[]const []const u8,
    ) ![]ai.NamedTool {
        return self.buildNamedToolsWithOptions(arena, active, true);
    }

    pub fn buildNamedToolsWithOptions(
        self: *const ToolRegistry,
        arena: Allocator,
        active: ?[]const []const u8,
        intent_tracing: bool,
    ) ![]ai.NamedTool {
        var named: std.ArrayList(ai.NamedTool) = .empty;
        defer named.deinit(arena);
        for (self.tools.items) |declaration| {
            if (!isActive(declaration.name, active)) continue;
            const schema = if (intent_tracing) switch (declaration.intent) {
                .mode => |mode| switch (mode) {
                    .require, .optional => try schemaWithIntent(arena, declaration.input_schema, mode),
                    .omit => declaration.input_schema,
                },
                .dynamic => declaration.input_schema,
            } else declaration.input_schema;
            try named.append(arena, .{
                .name = declaration.name,
                .tool = .{
                    .name = declaration.name,
                    .description = .{ .text = declaration.description },
                    .input_schema = provider_utils.rawSchema(schema, null),
                    .execute = null,
                },
            });
        }
        return named.toOwnedSlice(arena);
    }
};

fn isActive(name: []const u8, active: ?[]const []const u8) bool {
    const names = active orelse return true;
    for (names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

pub fn normalizeAssistantIntents(
    arena: Allocator,
    source: message.AssistantMessage,
    registry: *const ToolRegistry,
    enabled: bool,
) !message.AssistantMessage {
    if (!enabled) return source;
    const content = try arena.alloc(message.AssistantBlock, source.content.len);
    for (source.content, content) |block, *destination| destination.* = switch (block) {
        .tool_call => |call| .{ .tool_call = try normalizeToolCallIntent(arena, call, registry.get(call.name)) },
        else => block,
    };
    var normalized = source;
    normalized.content = content;
    return normalized;
}

fn normalizeToolCallIntent(
    arena: Allocator,
    source: message.ToolCallContent,
    declaration: ?*const Tool,
) !message.ToolCallContent {
    if (source.arguments != .object) return source;
    var stripped: std.json.ObjectMap = .empty;
    var explicit: ?[]const u8 = null;
    var iterator = source.arguments.object.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "i")) {
            if (entry.value_ptr.* == .string) {
                const trimmed = std.mem.trim(u8, entry.value_ptr.string, " \t\r\n");
                if (trimmed.len != 0) explicit = trimmed;
            }
            continue;
        }
        try stripped.put(arena, entry.key_ptr.*, entry.value_ptr.*);
    }
    const arguments: std.json.Value = .{ .object = stripped };
    const derived = explicit orelse if (declaration) |tool| switch (tool.intent) {
        .dynamic => |derive| derive(tool.ctx, arguments),
        .mode => null,
    } else null;
    var normalized = source;
    normalized.arguments = arguments;
    normalized.intent = if (derived) |intent| try arena.dupe(u8, std.mem.trim(u8, intent, " \t\r\n")) else null;
    return normalized;
}

fn schemaWithIntent(arena: Allocator, raw_schema: []const u8, mode: IntentMode) ![]const u8 {
    var schema = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        raw_schema,
        .{ .allocate = .alloc_always },
    ) catch return raw_schema;
    try injectIntent(arena, &schema, mode);
    return provider.wire.stringifyAlloc(arena, schema);
}

fn injectIntent(arena: Allocator, schema: *std.json.Value, mode: IntentMode) !void {
    if (schema.* != .object or mode == .omit) return;
    const properties_value = schema.object.getPtr("properties");
    if (properties_value == null or properties_value.?.* != .object) {
        const union_keys = [_][]const u8{ "anyOf", "oneOf" };
        for (union_keys) |key| {
            const variants = schema.object.getPtr(key) orelse continue;
            if (variants.* != .array) continue;
            for (variants.array.items) |*variant| try injectIntent(arena, variant, mode);
            return;
        }
    }

    var intent_schema: std.json.ObjectMap = .empty;
    try intent_schema.put(arena, "type", .{ .string = "string" });
    try intent_schema.put(arena, "description", .{ .string = "concise intent" });
    const intent_property = if (properties_value) |existing|
        if (existing.* == .object) existing.object.get("i") orelse std.json.Value{ .object = intent_schema } else std.json.Value{ .object = intent_schema }
    else
        std.json.Value{ .object = intent_schema };
    var properties: std.json.ObjectMap = .empty;
    try properties.put(arena, "i", intent_property);
    if (properties_value) |existing| if (existing.* == .object) {
        var iterator = existing.object.iterator();
        while (iterator.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "i")) continue;
            try properties.put(arena, entry.key_ptr.*, entry.value_ptr.*);
        }
    };
    try schema.object.put(arena, "properties", .{ .object = properties });

    if (mode == .require) {
        var required = if (schema.object.getPtr("required")) |value|
            if (value.* == .array) value.array else std.json.Array.init(arena)
        else
            std.json.Array.init(arena);
        var contains_intent = false;
        for (required.items) |item| {
            if (item == .string and std.mem.eql(u8, item.string, "i")) contains_intent = true;
        }
        if (!contains_intent) try required.append(.{ .string = "i" });
        try schema.object.put(arena, "required", .{ .array = required });
    }
}

pub fn cloneOutcome(arena: Allocator, source: ToolOutcome) !ToolOutcome {
    const content = try arena.alloc(ResultBlock, source.content.len);
    for (source.content, content) |block, *destination| destination.* = switch (block) {
        .text => |text| .{ .text = try arena.dupe(u8, text) },
        .image => |image| .{ .image = .{
            .data = try arena.dupe(u8, image.data),
            .mime_type = try arena.dupe(u8, image.mime_type),
        } },
    };
    return .{
        .content = content,
        .details = if (source.details) |details|
            try provider_utils.cloneJsonValue(arena, details)
        else
            null,
        .is_error = source.is_error,
        .useless = if (source.is_error) null else source.useless,
    };
}

test "tool registry filters active tools and disables ai.zig execution" {
    const Echo = struct {
        fn execute(
            _: ?*anyopaque,
            _: std.Io,
            arena: Allocator,
            input: std.json.Value,
            _: ?OnUpdate,
            _: *const CancelToken,
        ) anyerror!ToolOutcome {
            const value = if (input == .object and input.object.get("value") != null and
                input.object.get("value").? == .string)
                input.object.get("value").?.string
            else
                "";
            const blocks = try arena.alloc(ResultBlock, 1);
            blocks[0] = .{ .text = try arena.dupe(u8, value) };
            return .{ .content = blocks };
        }
    };
    const vtable: VTable = .{ .execute = Echo.execute };
    var registry = ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.add(.{
        .name = "echo",
        .description = "Echo input",
        .input_schema = "{\"type\":\"object\"}",
        .vtable = &vtable,
    });
    try registry.add(.{
        .name = "other",
        .description = "Other",
        .input_schema = "{}",
        .vtable = &vtable,
    });

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const named = try registry.buildNamedTools(arena_state.allocator(), &.{"echo"});
    try std.testing.expectEqual(@as(usize, 1), named.len);
    try std.testing.expectEqualStrings("echo", named[0].name);
    try std.testing.expect(named[0].tool.execute == null);
    const schema_text = named[0].tool.input_schema.document.text;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), schema_text, .{});
    try std.testing.expectEqualStrings("concise intent", parsed.object.get("properties").?.object.get("i").?.object.get("description").?.string);
    try std.testing.expectEqualStrings("i", parsed.object.get("required").?.array.items[0].string);
}

test "tool intent normalization strips i and preserves explicit or derived intent" {
    const Deriver = struct {
        fn derive(_: ?*anyopaque, args: std.json.Value) ?[]const u8 {
            return if (args.object.get("path") != null) "inspect path" else null;
        }

        fn execute(
            _: ?*anyopaque,
            _: std.Io,
            arena: Allocator,
            _: std.json.Value,
            _: ?OnUpdate,
            _: *const CancelToken,
        ) anyerror!ToolOutcome {
            return .{ .content = try arena.alloc(ResultBlock, 0) };
        }
    };
    const vtable: VTable = .{ .execute = Deriver.execute };
    var registry = ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.add(.{
        .name = "read",
        .description = "",
        .input_schema = "{}",
        .intent = .{ .dynamic = Deriver.derive },
        .vtable = &vtable,
    });
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const explicit_args = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"i\":\"  check file  \",\"path\":\"a\"}", .{});
    const explicit = message.AssistantMessage{
        .content = &.{.{ .tool_call = .{ .id = "1", .name = "read", .arguments = explicit_args } }},
        .api = "test",
        .provider = "test",
        .model = "test",
        .usage = .{},
        .stop_reason = .tool_use,
        .timestamp = 1,
    };
    const normalized = try normalizeAssistantIntents(arena, explicit, &registry, true);
    try std.testing.expectEqualStrings("check file", normalized.content[0].tool_call.intent.?);
    try std.testing.expect(normalized.content[0].tool_call.arguments.object.get("i") == null);
    try std.testing.expectEqualStrings("a", normalized.content[0].tool_call.arguments.object.get("path").?.string);

    const derived_args = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\"b\"}", .{});
    var derived_source = explicit;
    derived_source.content = &.{.{ .tool_call = .{ .id = "2", .name = "read", .arguments = derived_args } }};
    const derived = try normalizeAssistantIntents(arena, derived_source, &registry, true);
    try std.testing.expectEqualStrings("inspect path", derived.content[0].tool_call.intent.?);
}
