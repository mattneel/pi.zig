//! Raise one completed ai.zig model step into the session message vocabulary.
//!
//! The returned assistant message and every nested value are owned by `arena`.
//! Callers must raise before deinitializing the `StreamTextResult` that owns the
//! source `StepResult`.

const std = @import("std");
const ai = @import("ai");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const catalog = @import("../catalog/catalog.zig");
const lower = @import("lower.zig");
const message = @import("message.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    resolved_model: ?*const catalog.Model = null,
    api: ?[]const u8 = null,
    timestamp_ms: ?i64 = null,
    error_message: ?[]const u8 = null,
};

pub fn fromStep(arena: Allocator, step: *const ai.StepResult, options: Options) !message.AssistantMessage {
    var content: std.ArrayList(message.AssistantBlock) = .empty;
    defer content.deinit(arena);

    for (step.content) |part| switch (part) {
        .text => |text| try content.append(arena, .{ .text = .{
            .text = try arena.dupe(u8, text.text),
            .text_signature = try textSignature(arena, step.model.provider_name, text.provider_metadata),
        } }),
        .reasoning => |reasoning| if (metadataString(step.model.provider_name, reasoning.provider_metadata, "redactedData")) |data|
            try content.append(arena, .{ .redacted_thinking = .{ .data = try arena.dupe(u8, data) } })
        else
            try content.append(arena, .{ .thinking = .{
                .thinking = try arena.dupe(u8, reasoning.text),
                .thinking_signature = try thinkingSignature(arena, step.model.provider_name, reasoning.provider_metadata),
                .item_id = try metadataStringAlloc(arena, step.model.provider_name, reasoning.provider_metadata, "itemId"),
            } }),
        .tool_call => |call| try content.append(arena, .{ .tool_call = .{
            .id = try arena.dupe(u8, call.tool_call_id),
            .name = try arena.dupe(u8, call.tool_name),
            .arguments = try provider_utils.cloneJsonValue(arena, call.input),
            .thought_signature = try toolCallSignature(arena, step.model.provider_name, call.provider_metadata),
        } }),
        .custom => |custom| if (std.mem.eql(u8, custom.kind, "anthropic.redacted-thinking")) {
            if (metadataString(step.model.provider_name, custom.provider_metadata, "redactedData")) |data| {
                try content.append(arena, .{ .redacted_thinking = .{ .data = try arena.dupe(u8, data) } });
            }
        } else try content.append(arena, .{ .unknown = try rawCustomPart(arena, custom) }),
        .reasoning_file,
        .file,
        .source,
        .tool_result,
        .tool_error,
        .tool_approval_request,
        .tool_approval_response,
        => {},
    };

    var usage = message.Usage.fromAiUsage(step.usage, .{});
    if (options.resolved_model) |model| _ = catalog.calculateCost(model, &usage);

    const provider_name = try arena.dupe(u8, step.model.provider_name);
    const model_id = try arena.dupe(u8, step.model.model_id);
    const api = if (options.api) |value|
        try arena.dupe(u8, value)
    else if (options.resolved_model) |model|
        try arena.dupe(u8, model.api.wireName())
    else
        try arena.dupe(u8, step.model.provider_name);

    return .{
        .content = try content.toOwnedSlice(arena),
        .api = api,
        .provider = provider_name,
        .model = model_id,
        .response_id = if (step.response.id) |id| try arena.dupe(u8, id) else null,
        .usage = usage,
        .stop_reason = mapStopReason(step.finish_reason),
        .stop_details = try stopDetails(arena, step.model.provider_name, step.provider_metadata),
        .error_message = if (options.error_message) |text| try arena.dupe(u8, text) else null,
        .provider_payload = if (step.provider_metadata) |metadata|
            try provider_utils.cloneJsonValue(arena, metadata)
        else
            null,
        .timestamp = options.timestamp_ms orelse step.response.timestamp_ms orelse 0,
        .duration = positiveMillis(step.performance.step_time_ms),
        .ttft = if (step.performance.time_to_first_output_ms) |value| positiveMillis(value) else null,
    };
}

fn rawCustomPart(arena: Allocator, custom: provider.CustomContent) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "type", .{ .string = "custom" });
    try object.put(arena, "kind", .{ .string = try arena.dupe(u8, custom.kind) });
    if (custom.provider_metadata) |metadata| {
        try object.put(arena, "providerMetadata", try provider_utils.cloneJsonValue(arena, metadata));
    }
    return .{ .object = object };
}

pub fn mapStopReason(finish: provider.FinishReason) message.StopReason {
    return switch (finish.unified) {
        .stop => .stop,
        .length => .length,
        .tool_calls => .tool_use,
        .content_filter, .@"error" => .@"error",
        .other => if (finish.raw) |raw|
            if (std.mem.eql(u8, raw, "aborted") or
                std.mem.eql(u8, raw, "cancelled") or
                std.mem.eql(u8, raw, "canceled"))
                .aborted
            else
                .@"error"
        else
            .@"error",
    };
}

fn positiveMillis(value: f64) ?u64 {
    if (!std.math.isFinite(value) or value < 0) return null;
    const maximum: f64 = @floatFromInt(std.math.maxInt(u64));
    if (value >= maximum) return std.math.maxInt(u64);
    return @intFromFloat(@round(value));
}

fn stopDetails(
    arena: Allocator,
    provider_name: []const u8,
    metadata: ?provider.ProviderMetadata,
) !?std.json.Value {
    const value = metadataValue(provider_name, metadata, "stopDetails") orelse return null;
    if (value == .null) return null;
    return @as(?std.json.Value, try provider_utils.cloneJsonValue(arena, value));
}

fn textSignature(
    arena: Allocator,
    provider_name: []const u8,
    metadata: ?provider.ProviderMetadata,
) !?[]const u8 {
    if (metadataString(provider_name, metadata, "thoughtSignature")) |value| {
        return @as(?[]const u8, try arena.dupe(u8, value));
    }
    const id = metadataString(provider_name, metadata, "itemId") orelse return null;
    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "v", .{ .integer = 1 });
    try object.put(arena, "id", .{ .string = try arena.dupe(u8, id) });
    if (metadataString(provider_name, metadata, "phase")) |phase| {
        try object.put(arena, "phase", .{ .string = try arena.dupe(u8, phase) });
    }
    return @as(?[]const u8, try provider.wire.stringifyAlloc(arena, std.json.Value{ .object = object }));
}

fn thinkingSignature(
    arena: Allocator,
    provider_name: []const u8,
    metadata: ?provider.ProviderMetadata,
) !?[]const u8 {
    if (metadataString(provider_name, metadata, "signature")) |value| return @as(?[]const u8, try arena.dupe(u8, value));
    if (metadataString(provider_name, metadata, "thoughtSignature")) |value| return @as(?[]const u8, try arena.dupe(u8, value));

    const id = metadataString(provider_name, metadata, "itemId");
    const encrypted = metadataString(provider_name, metadata, "reasoningEncryptedContent");
    if (id == null and encrypted == null) return null;
    var object: std.json.ObjectMap = .empty;
    if (id) |value| try object.put(arena, "id", .{ .string = try arena.dupe(u8, value) });
    if (encrypted) |value| {
        try object.put(arena, "encrypted_content", .{ .string = try arena.dupe(u8, value) });
    }
    return @as(?[]const u8, try provider.wire.stringifyAlloc(arena, std.json.Value{ .object = object }));
}

fn toolCallSignature(
    arena: Allocator,
    provider_name: []const u8,
    metadata: ?provider.ProviderMetadata,
) !?[]const u8 {
    if (metadataString(provider_name, metadata, "thoughtSignature")) |value| return @as(?[]const u8, try arena.dupe(u8, value));
    if (metadataString(provider_name, metadata, "itemId")) |value| return @as(?[]const u8, try arena.dupe(u8, value));
    return null;
}

fn metadataStringAlloc(
    arena: Allocator,
    provider_name: []const u8,
    metadata: ?provider.ProviderMetadata,
    field: []const u8,
) !?[]const u8 {
    return if (metadataString(provider_name, metadata, field)) |value| try arena.dupe(u8, value) else null;
}

fn metadataString(
    provider_name: []const u8,
    metadata: ?provider.ProviderMetadata,
    field: []const u8,
) ?[]const u8 {
    const value = metadataValue(provider_name, metadata, field) orelse return null;
    return if (value == .string) value.string else null;
}

fn metadataValue(
    provider_name: []const u8,
    metadata: ?provider.ProviderMetadata,
    field: []const u8,
) ?std.json.Value {
    const root = metadata orelse return null;
    if (root != .object) return null;
    if (root.object.get(provider_name)) |namespace| {
        if (namespace == .object) if (namespace.object.get(field)) |value| return value;
    }
    const namespaces = [_][]const u8{ "anthropic", "google", "openai", "openai-compatible" };
    for (namespaces) |name| if (root.object.get(name)) |namespace| {
        if (namespace == .object) if (namespace.object.get(field)) |value| return value;
    };
    return root.object.get(field);
}

test "raise maps content signatures cost and stamps from a completed step" {
    var source_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer source_arena_state.deinit();
    const source_arena = source_arena_state.allocator();
    const metadata = try std.json.parseFromSliceLeaky(
        std.json.Value,
        source_arena,
        "{\"openai\":{\"itemId\":\"msg-1\",\"phase\":\"final_answer\"}}",
        .{},
    );
    const input = try std.json.parseFromSliceLeaky(std.json.Value, source_arena, "{\"value\":1}", .{});
    const content = try source_arena.alloc(ai.ContentPart, 2);
    content[0] = .{ .text = .{ .text = "done", .provider_metadata = metadata } };
    content[1] = .{ .tool_call = .{
        .tool_call_id = "call-1",
        .tool_name = "echo",
        .input = input,
        .provider_metadata = metadata,
    } };
    const step: ai.StepResult = .{
        .call_id = "step-1",
        .step_number = 0,
        .model = .{ .provider_name = "openai", .model_id = "gpt-5.2" },
        .tools_context = null,
        .runtime_context = null,
        .content = content,
        .finish_reason = .{ .unified = .tool_calls, .raw = "tool_calls" },
        .usage = .{
            .input_tokens = .{ .total = 10, .no_cache = 10 },
            .output_tokens = .{ .total = 5, .text = 5 },
        },
        .performance = .{
            .effective_output_tokens_per_second = 1,
            .effective_total_tokens_per_second = 1,
            .step_time_ms = 12,
            .response_time_ms = 11,
            .time_to_first_output_ms = 3,
        },
        .warnings = &.{},
        .request = .{},
        .response = .{ .id = "resp-1", .timestamp_ms = 44 },
        .provider_metadata = metadata,
    };

    const model = (try catalog.getBundledModel("openai", "gpt-5.2")).?;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const raised = try fromStep(arena_state.allocator(), &step, .{ .resolved_model = model });
    try std.testing.expectEqual(message.StopReason.tool_use, raised.stop_reason);
    try std.testing.expectEqualStrings("resp-1", raised.response_id.?);
    try std.testing.expectEqualStrings("{\"v\":1,\"id\":\"msg-1\",\"phase\":\"final_answer\"}", raised.content[0].text.text_signature.?);
    try std.testing.expectEqualStrings("msg-1", raised.content[1].tool_call.thought_signature.?);
    try std.testing.expect(raised.usage.cost.total > 0);
    try std.testing.expectEqual(@as(?u64, 12), raised.duration);
}

fn replayTestStep(provider_name: []const u8, model_id: []const u8, content: []const ai.ContentPart) ai.StepResult {
    return .{
        .call_id = "step-replay",
        .step_number = 0,
        .model = .{ .provider_name = provider_name, .model_id = model_id },
        .tools_context = null,
        .runtime_context = null,
        .content = content,
        .finish_reason = .{ .unified = .stop, .raw = "stop" },
        .usage = .{
            .input_tokens = .{ .total = 0, .no_cache = 0 },
            .output_tokens = .{ .total = 0, .text = 0 },
        },
        .performance = .{
            .effective_output_tokens_per_second = 0,
            .effective_total_tokens_per_second = 0,
            .step_time_ms = 0,
            .response_time_ms = 0,
        },
        .warnings = &.{},
        .request = .{},
        .response = .{},
        .provider_metadata = null,
    };
}

test "raise and lower preserve Anthropic redacted thinking metadata" {
    var source_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer source_arena_state.deinit();
    const metadata = try std.json.parseFromSliceLeaky(
        std.json.Value,
        source_arena_state.allocator(),
        "{\"anthropic\":{\"redactedData\":\"encrypted-redaction\"}}",
        .{},
    );
    const content = [_]ai.ContentPart{.{ .reasoning = .{
        .text = "",
        .provider_metadata = metadata,
    } }};
    const step = replayTestStep("anthropic", "claude-test", &content);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raised = try fromStep(arena, &step, .{ .api = "anthropic-messages" });
    try std.testing.expect(raised.content[0] == .redacted_thinking);
    try std.testing.expectEqualStrings("encrypted-redaction", raised.content[0].redacted_thinking.data);

    const lowered = try lower.toModelMessages(arena, &.{.{ .assistant = raised }}, .{
        .target_provider = "anthropic",
        .target_model = "claude-test",
    });
    const encoded = try provider.wire.stringifyAlloc(arena, lowered);
    try std.testing.expectEqualStrings(
        \\[{"role":"assistant","content":[{"type":"reasoning","text":"","providerOptions":{"anthropic":{"redactedData":"encrypted-redaction"}}}]}]
    , encoded);
}

test "raise and lower preserve OpenAI compaction custom content" {
    var source_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer source_arena_state.deinit();
    const metadata = try std.json.parseFromSliceLeaky(
        std.json.Value,
        source_arena_state.allocator(),
        "{\"openai\":{\"itemId\":\"cmp_1\",\"encryptedContent\":\"encrypted-context\"}}",
        .{},
    );
    const content = [_]ai.ContentPart{.{ .custom = .{
        .kind = "openai.compaction",
        .provider_metadata = metadata,
    } }};
    const step = replayTestStep("openai", "gpt-test", &content);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raised = try fromStep(arena, &step, .{ .api = "openai-responses" });
    try std.testing.expect(raised.content[0] == .unknown);

    const lowered = try lower.toModelMessages(arena, &.{.{ .assistant = raised }}, .{
        .target_provider = "openai",
        .target_model = "gpt-test",
    });
    const encoded = try provider.wire.stringifyAlloc(arena, lowered);
    try std.testing.expectEqualStrings(
        \\[{"role":"assistant","content":[{"type":"custom","kind":"openai.compaction","providerOptions":{"openai":{"itemId":"cmp_1","encryptedContent":"encrypted-context"}}}]}]
    , encoded);
}
