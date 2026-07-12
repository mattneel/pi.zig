//! Session-owned agent messages and their canonical upstream-compatible wire form.
//!
//! Parsed strings, slices, and JSON values are owned by the allocator passed to
//! `parse`/`parseValue`. Constructed values borrow their inputs. `stringifyAlloc`
//! returns a separately allocator-owned byte slice.

const std = @import("std");
const provider = @import("provider");
const catalog_types = @import("../catalog/types.zig");

const Allocator = std.mem.Allocator;

pub const Cost = catalog_types.Cost;
pub const Usage = catalog_types.Usage;

pub const Attribution = enum {
    user,
    agent,
};

pub const StopReason = enum {
    stop,
    length,
    tool_use,
    @"error",
    aborted,

    pub const wire_values = .{
        .{ .stop, "stop" },
        .{ .length, "length" },
        .{ .tool_use, "toolUse" },
        .{ .@"error", "error" },
        .{ .aborted, "aborted" },
    };
};

pub const ImageDetail = enum {
    auto,
    low,
    high,
    original,
};

pub const TextContent = struct {
    text: []const u8,
    text_signature: ?[]const u8 = null,
};

pub const ThinkingContent = struct {
    thinking: []const u8,
    thinking_signature: ?[]const u8 = null,
    item_id: ?[]const u8 = null,
};

pub const RedactedThinkingContent = struct {
    data: []const u8,
};

pub const ImageContent = struct {
    data: []const u8,
    mime_type: []const u8,
    detail: ?ImageDetail = null,
};

pub const ToolCallContent = struct {
    id: []const u8,
    name: []const u8,
    arguments: std.json.Value,
    thought_signature: ?[]const u8 = null,
    intent: ?[]const u8 = null,
    raw_block: ?[]const u8 = null,
    custom_wire_name: ?[]const u8 = null,
};

pub const AnthropicFallbackContent = struct {
    from: struct { model: []const u8 },
    to: struct { model: []const u8 },
};

pub const TextImageBlock = union(enum) {
    text: TextContent,
    image: ImageContent,
    unknown: std.json.Value,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .text, "text" },
        .{ .image, "image" },
        .{ .unknown, "unknown" },
    };

    pub fn wireParse(arena: Allocator, value: std.json.Value) provider.wire.ParseError!TextImageBlock {
        const tag = try rawTag(value, "type");
        if (isKnownTag(KnownTextImageBlock, tag)) {
            return fromKnownTextImageBlock(try provider.wire.parse(KnownTextImageBlock, arena, value));
        }
        return .{ .unknown = try provider.wire.parse(std.json.Value, arena, value) };
    }

    pub fn wireWrite(value: TextImageBlock, writer: *std.json.Stringify) std.Io.Writer.Error!void {
        return switch (value) {
            .text => |payload| provider.wire.write(KnownTextImageBlock{ .text = payload }, writer),
            .image => |payload| provider.wire.write(KnownTextImageBlock{ .image = payload }, writer),
            .unknown => |raw| writer.write(raw),
        };
    }
};

pub const AssistantBlock = union(enum) {
    text: TextContent,
    thinking: ThinkingContent,
    redacted_thinking: RedactedThinkingContent,
    fallback: AnthropicFallbackContent,
    tool_call: ToolCallContent,
    unknown: std.json.Value,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .text, "text" },
        .{ .thinking, "thinking" },
        .{ .redacted_thinking, "redactedThinking" },
        .{ .fallback, "fallback" },
        .{ .tool_call, "toolCall" },
        .{ .unknown, "unknown" },
    };

    pub fn wireParse(arena: Allocator, value: std.json.Value) provider.wire.ParseError!AssistantBlock {
        const tag = try rawTag(value, "type");
        if (isKnownTag(KnownAssistantBlock, tag)) {
            return fromKnownAssistantBlock(try provider.wire.parse(KnownAssistantBlock, arena, value));
        }
        return .{ .unknown = try provider.wire.parse(std.json.Value, arena, value) };
    }

    pub fn wireWrite(value: AssistantBlock, writer: *std.json.Stringify) std.Io.Writer.Error!void {
        return switch (value) {
            .text => |payload| provider.wire.write(KnownAssistantBlock{ .text = payload }, writer),
            .thinking => |payload| provider.wire.write(KnownAssistantBlock{ .thinking = payload }, writer),
            .redacted_thinking => |payload| provider.wire.write(KnownAssistantBlock{ .redacted_thinking = payload }, writer),
            .fallback => |payload| provider.wire.write(KnownAssistantBlock{ .fallback = payload }, writer),
            .tool_call => |payload| provider.wire.write(KnownAssistantBlock{ .tool_call = payload }, writer),
            .unknown => |raw| writer.write(raw),
        };
    }
};

pub fn Content(comptime Block: type) type {
    return union(enum) {
        string: []const u8,
        blocks: []const Block,

        const Self = @This();

        pub fn wireParse(arena: Allocator, value: std.json.Value) provider.wire.ParseError!Self {
            return switch (value) {
                .string => |text| .{ .string = try arena.dupe(u8, text) },
                .array => .{ .blocks = try provider.wire.parse([]const Block, arena, value) },
                else => error.TypeValidationError,
            };
        }

        pub fn wireWrite(value: Self, writer: *std.json.Stringify) std.Io.Writer.Error!void {
            return switch (value) {
                .string => |text| writer.write(text),
                .blocks => |blocks| provider.wire.write(blocks, writer),
            };
        }
    };
}

pub const TextImageContent = Content(TextImageBlock);

pub const UserMessage = struct {
    content: TextImageContent,
    synthetic: ?bool = null,
    steering: ?bool = null,
    attribution: ?Attribution = null,
    provider_payload: ?std.json.Value = null,
    timestamp: i64,
};

pub const DeveloperMessage = struct {
    content: TextImageContent,
    attribution: ?Attribution = null,
    provider_payload: ?std.json.Value = null,
    timestamp: i64,
};

pub const ContextSnapshot = struct {
    prompt_tokens: u64,
    non_message_tokens: u64,
    last_message_timestamp: ?i64 = null,
};

pub const AssistantMessage = struct {
    content: []const AssistantBlock,
    api: []const u8,
    provider: []const u8,
    model: []const u8,
    context_snapshot: ?ContextSnapshot = null,
    retry_recovery: ?std.json.Value = null,
    response_id: ?[]const u8 = null,
    upstream_provider: ?[]const u8 = null,
    usage: Usage,
    stop_reason: StopReason,
    stop_details: ?std.json.Value = null,
    error_message: ?[]const u8 = null,
    tool_call_abort_messages: ?std.json.Value = null,
    error_status: ?u16 = null,
    error_id: ?u64 = null,
    disabled_features: ?[]const []const u8 = null,
    provider_payload: ?std.json.Value = null,
    timestamp: i64,
    duration: ?u64 = null,
    ttft: ?u64 = null,

    pub fn wireParse(arena: Allocator, value: std.json.Value) provider.wire.ParseError!AssistantMessage {
        const Wire = struct {
            content: []const AssistantBlock,
            api: ?[]const u8 = null,
            provider: []const u8,
            model: []const u8,
            context_snapshot: ?ContextSnapshot = null,
            retry_recovery: ?std.json.Value = null,
            response_id: ?[]const u8 = null,
            upstream_provider: ?[]const u8 = null,
            usage: Usage,
            stop_reason: ?StopReason = null,
            stop_details: ?std.json.Value = null,
            error_message: ?[]const u8 = null,
            tool_call_abort_messages: ?std.json.Value = null,
            error_status: ?u16 = null,
            error_id: ?u64 = null,
            disabled_features: ?[]const []const u8 = null,
            provider_payload: ?std.json.Value = null,
            timestamp: i64,
            duration: ?u64 = null,
            ttft: ?u64 = null,
        };
        const parsed = try provider.wire.parse(Wire, arena, value);
        return .{
            .content = parsed.content,
            .api = parsed.api orelse deriveApi(parsed.provider),
            .provider = parsed.provider,
            .model = parsed.model,
            .context_snapshot = parsed.context_snapshot,
            .retry_recovery = parsed.retry_recovery,
            .response_id = parsed.response_id,
            .upstream_provider = parsed.upstream_provider,
            .usage = parsed.usage,
            .stop_reason = parsed.stop_reason orelse .stop,
            .stop_details = parsed.stop_details,
            .error_message = parsed.error_message,
            .tool_call_abort_messages = parsed.tool_call_abort_messages,
            .error_status = parsed.error_status,
            .error_id = parsed.error_id,
            .disabled_features = parsed.disabled_features,
            .provider_payload = parsed.provider_payload,
            .timestamp = parsed.timestamp,
            .duration = parsed.duration,
            .ttft = parsed.ttft,
        };
    }
};

pub const ToolResultMessage = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    content: []const TextImageBlock,
    details: ?std.json.Value = null,
    is_error: bool,
    attribution: ?Attribution = null,
    pruned_at: ?i64 = null,
    useless: ?bool = null,
    timestamp: i64,
};

pub const BashExecutionMessage = struct {
    command: []const u8,
    output: []const u8,
    exit_code: ?i32 = null,
    cancelled: bool,
    truncated: bool,
    meta: ?std.json.Value = null,
    exclude_from_context: ?bool = null,
    timestamp: i64,
};

pub const CustomMessage = struct {
    custom_type: []const u8,
    content: TextImageContent,
    display: bool,
    details: ?std.json.Value = null,
    attribution: ?Attribution = null,
    timestamp: i64,
};

pub const BranchSummaryMessage = struct {
    summary: []const u8,
    from_id: []const u8,
    timestamp: i64,
};

pub const CompactionSummaryMessage = struct {
    summary: []const u8,
    short_summary: ?[]const u8 = null,
    tokens_before: u64,
    provider_payload: ?std.json.Value = null,
    blocks: ?[]const TextImageBlock = null,
    images: ?[]const ImageContent = null,
    timestamp: i64,
};

pub const SkippedReason = enum {
    too_large,
    binary,

    pub const wire_values = .{
        .{ .too_large, "tooLarge" },
        .{ .binary, "binary" },
    };
};

pub const FileMention = struct {
    path: []const u8,
    content: []const u8,
    line_count: ?u64 = null,
    byte_size: ?u64 = null,
    skipped_reason: ?SkippedReason = null,
    image: ?ImageContent = null,
};

pub const FileMentionMessage = struct {
    files: []const FileMention,
    timestamp: i64,
};

pub const AgentMessage = union(enum) {
    user: UserMessage,
    developer: DeveloperMessage,
    assistant: AssistantMessage,
    tool_result: ToolResultMessage,
    bash_execution: BashExecutionMessage,
    custom: CustomMessage,
    branch_summary: BranchSummaryMessage,
    compaction_summary: CompactionSummaryMessage,
    file_mention: FileMentionMessage,
    unknown: std.json.Value,

    pub const wire_tag_field = "role";
    pub const wire_tags = .{
        .{ .user, "user" },
        .{ .developer, "developer" },
        .{ .assistant, "assistant" },
        .{ .tool_result, "toolResult" },
        .{ .bash_execution, "bashExecution" },
        .{ .custom, "custom" },
        .{ .branch_summary, "branchSummary" },
        .{ .compaction_summary, "compactionSummary" },
        .{ .file_mention, "fileMention" },
        .{ .unknown, "unknown" },
    };

    pub fn wireParse(arena: Allocator, value: std.json.Value) provider.wire.ParseError!AgentMessage {
        const tag = try rawTag(value, "role");
        if (isKnownTag(KnownAgentMessage, tag)) {
            return fromKnownAgentMessage(try provider.wire.parse(KnownAgentMessage, arena, value));
        }
        return .{ .unknown = try provider.wire.parse(std.json.Value, arena, value) };
    }

    pub fn wireWrite(value: AgentMessage, writer: *std.json.Stringify) std.Io.Writer.Error!void {
        return switch (value) {
            .user => |payload| provider.wire.write(KnownAgentMessage{ .user = payload }, writer),
            .developer => |payload| provider.wire.write(KnownAgentMessage{ .developer = payload }, writer),
            .assistant => |payload| provider.wire.write(KnownAgentMessage{ .assistant = payload }, writer),
            .tool_result => |payload| provider.wire.write(KnownAgentMessage{ .tool_result = payload }, writer),
            .bash_execution => |payload| provider.wire.write(KnownAgentMessage{ .bash_execution = payload }, writer),
            .custom => |payload| provider.wire.write(KnownAgentMessage{ .custom = payload }, writer),
            .branch_summary => |payload| provider.wire.write(KnownAgentMessage{ .branch_summary = payload }, writer),
            .compaction_summary => |payload| provider.wire.write(KnownAgentMessage{ .compaction_summary = payload }, writer),
            .file_mention => |payload| provider.wire.write(KnownAgentMessage{ .file_mention = payload }, writer),
            .unknown => |raw| writer.write(raw),
        };
    }
};

const KnownTextImageBlock = union(enum) {
    text: TextContent,
    image: ImageContent,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .text, "text" },
        .{ .image, "image" },
    };
};

const KnownAssistantBlock = union(enum) {
    text: TextContent,
    thinking: ThinkingContent,
    redacted_thinking: RedactedThinkingContent,
    fallback: AnthropicFallbackContent,
    tool_call: ToolCallContent,

    pub const wire_tag_field = "type";
    pub const wire_tags = .{
        .{ .text, "text" },
        .{ .thinking, "thinking" },
        .{ .redacted_thinking, "redactedThinking" },
        .{ .fallback, "fallback" },
        .{ .tool_call, "toolCall" },
    };
};

const KnownAgentMessage = union(enum) {
    user: UserMessage,
    developer: DeveloperMessage,
    assistant: AssistantMessage,
    tool_result: ToolResultMessage,
    bash_execution: BashExecutionMessage,
    custom: CustomMessage,
    branch_summary: BranchSummaryMessage,
    compaction_summary: CompactionSummaryMessage,
    file_mention: FileMentionMessage,

    pub const wire_tag_field = "role";
    pub const wire_tags = .{
        .{ .user, "user" },
        .{ .developer, "developer" },
        .{ .assistant, "assistant" },
        .{ .tool_result, "toolResult" },
        .{ .bash_execution, "bashExecution" },
        .{ .custom, "custom" },
        .{ .branch_summary, "branchSummary" },
        .{ .compaction_summary, "compactionSummary" },
        .{ .file_mention, "fileMention" },
    };
};

fn rawTag(value: std.json.Value, field: []const u8) provider.wire.ParseError![]const u8 {
    const object = switch (value) {
        .object => |item| item,
        else => return error.TypeValidationError,
    };
    return switch (object.get(field) orelse return error.TypeValidationError) {
        .string => |tag| tag,
        else => error.TypeValidationError,
    };
}

fn isKnownTag(comptime T: type, tag: []const u8) bool {
    inline for (T.wire_tags) |mapping| {
        if (std.mem.eql(u8, tag, mapping[1])) return true;
    }
    return false;
}

fn fromKnownTextImageBlock(value: KnownTextImageBlock) TextImageBlock {
    return switch (value) {
        inline else => |payload, tag| @unionInit(TextImageBlock, @tagName(tag), payload),
    };
}

fn fromKnownAssistantBlock(value: KnownAssistantBlock) AssistantBlock {
    return switch (value) {
        inline else => |payload, tag| @unionInit(AssistantBlock, @tagName(tag), payload),
    };
}

fn fromKnownAgentMessage(value: KnownAgentMessage) AgentMessage {
    return switch (value) {
        inline else => |payload, tag| @unionInit(AgentMessage, @tagName(tag), payload),
    };
}

fn deriveApi(provider_name: []const u8) []const u8 {
    if (std.mem.eql(u8, provider_name, "anthropic")) return "anthropic-messages";
    if (std.mem.eql(u8, provider_name, "openai")) return "openai-responses";
    if (std.mem.eql(u8, provider_name, "google")) return "google-generative-ai";
    return provider_name;
}

pub fn parse(arena: Allocator, json_text: []const u8) !AgentMessage {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, json_text, .{
        .allocate = .alloc_always,
    });
    return parseValue(arena, value);
}

pub fn parseValue(arena: Allocator, value: std.json.Value) !AgentMessage {
    return provider.wire.parse(AgentMessage, arena, value);
}

pub fn write(message: AgentMessage, writer: *std.json.Stringify) std.Io.Writer.Error!void {
    return provider.wire.write(message, writer);
}

pub fn stringifyAlloc(allocator: Allocator, message: AgentMessage) ![]u8 {
    return provider.wire.stringifyAlloc(allocator, message);
}

fn expectStableRoundTrip(arena: Allocator, fixture: []const u8) !AgentMessage {
    const first = try parse(arena, fixture);
    const encoded = try stringifyAlloc(arena, first);
    const second = try parse(arena, encoded);
    const encoded_again = try stringifyAlloc(arena, second);
    try std.testing.expectEqualStrings(encoded, encoded_again);
    return second;
}

test "message user fixture round-trips and omits absent optionals" {
    // Shape from packages/agent/test/handoff.test.ts and ai/types.ts UserMessage.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try expectStableRoundTrip(arena,
        \\{"role":"user","content":"start work","synthetic":true,"steering":true,"attribution":"user","timestamp":1}
    );
    try std.testing.expect(parsed == .user);
    try std.testing.expectEqualStrings("start work", parsed.user.content.string);

    const minimal = try stringifyAlloc(arena, .{ .user = .{
        .content = .{ .string = "hello" },
        .timestamp = 2,
    } });
    try std.testing.expectEqualStrings(
        \\{"role":"user","content":"hello","timestamp":2}
    , minimal);
    try std.testing.expect(std.mem.indexOf(u8, minimal, "null") == null);
}

test "message assistant fixture preserves signatures usage and envelope fields" {
    // Adapted verbatim field values from coding-agent's
    // session-manager/signature-persistence.test.ts assistant fixture.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try expectStableRoundTrip(arena,
        \\{"role":"assistant","content":[{"type":"thinking","thinking":"reasoning","thinkingSignature":"sig-1","itemId":"rs_1"},{"type":"text","text":"done","textSignature":"{\"v\":1,\"id\":\"msg_1\"}"},{"type":"toolCall","id":"tool_image","name":"eval","arguments":{},"thoughtSignature":"opaque","intent":"inspect"},{"type":"redactedThinking","data":"encrypted"}],"api":"openai-responses","provider":"openai","model":"gpt-5-mini","contextSnapshot":{"promptTokens":1,"nonMessageTokens":2},"responseId":"resp_1","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2,"reasoningTokens":1,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"toolUse","stopDetails":{"type":"pause_turn"},"errorMessage":"retryable","errorStatus":429,"timestamp":2,"duration":10,"ttft":3}
    );
    try std.testing.expect(parsed == .assistant);
    try std.testing.expectEqual(StopReason.tool_use, parsed.assistant.stop_reason);
    try std.testing.expectEqual(@as(usize, 4), parsed.assistant.content.len);
    try std.testing.expectEqualStrings("sig-1", parsed.assistant.content[0].thinking.thinking_signature.?);
    try std.testing.expectEqual(@as(u64, 2), parsed.assistant.usage.total_tokens.?);
}

test "message tool result fixture preserves image details and JSON details" {
    // Field values from coding-agent's session-manager/signature-persistence.test.ts.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try expectStableRoundTrip(arena,
        \\{"role":"toolResult","toolCallId":"tool_image","toolName":"eval","content":[{"type":"text","text":"displayed image"},{"type":"image","data":"cmVhZC1pbWFnZQ==","mimeType":"image/png","detail":"high"}],"details":{"images":1},"isError":false,"attribution":"agent","useless":false,"timestamp":2}
    );
    try std.testing.expect(parsed == .tool_result);
    try std.testing.expectEqualStrings("image/png", parsed.tool_result.content[1].image.mime_type);
    try std.testing.expectEqual(ImageDetail.high, parsed.tool_result.content[1].image.detail.?);
    try std.testing.expect(parsed.tool_result.pruned_at == null);
}

test "message application role fixtures preserve exact upstream role tags" {
    // Shapes are from coding-agent/session/messages.ts custom-role declarations
    // and agent/compaction/messages.ts summary declarations.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fixtures = [_][]const u8{
        \\{"role":"developer","content":[{"type":"text","text":"instruction"}],"attribution":"agent","timestamp":3}
        ,
        \\{"role":"bashExecution","command":"pwd","output":"/work","exitCode":0,"cancelled":false,"truncated":false,"excludeFromContext":false,"timestamp":4}
        ,
        \\{"role":"custom","customType":"advisor","content":"context","display":true,"details":{"source":"test"},"attribution":"agent","timestamp":5}
        ,
        \\{"role":"branchSummary","summary":"branch state","fromId":"a1b2c3d4","timestamp":6}
        ,
        \\{"role":"compactionSummary","summary":"prior work","shortSummary":"recap","tokensBefore":42000,"timestamp":7}
        ,
        \\{"role":"fileMention","files":[{"path":"notes.md","content":"hello","lineCount":1,"byteSize":5},{"path":"shot.png","content":"","skippedReason":"binary","image":{"data":"aA==","mimeType":"image/png"}}],"timestamp":8}
        ,
    };

    for (fixtures) |fixture| {
        const parsed = try expectStableRoundTrip(arena, fixture);
        const encoded = try stringifyAlloc(arena, parsed);
        try std.testing.expect(std.mem.indexOf(u8, encoded, "null") == null);
    }
}

test "message Usage.fromAiUsage maps ai vocabulary" {
    const usage = Usage.fromAiUsage(.{
        .input_tokens = .{
            .total = 18,
            .no_cache = 10,
            .cache_read = 5,
            .cache_write = 3,
        },
        .output_tokens = .{
            .total = 7,
            .text = 5,
            .reasoning = 2,
        },
    }, .{
        .input = 0.1,
        .output = 0.2,
        .cache_read = 0.3,
        .cache_write = 0.4,
        .total = 1.0,
    });
    try std.testing.expectEqual(@as(u64, 10), usage.input);
    try std.testing.expectEqual(@as(u64, 7), usage.output);
    try std.testing.expectEqual(@as(u64, 5), usage.cache_read);
    try std.testing.expectEqual(@as(u64, 3), usage.cache_write);
    try std.testing.expectEqual(@as(u64, 25), usage.total_tokens.?);
    try std.testing.expectEqual(@as(u64, 2), usage.reasoning_tokens.?);
    try std.testing.expectEqual(@as(f64, 1.0), usage.cost.total);
}

test "message unknown roles and blocks round trip without interpretation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const unknown_role =
        \\{"role":"pythonExecution","code":"print(1)","output":"1","cancelled":false,"future":{"x":1},"timestamp":9}
    ;
    const parsed_role = try parse(arena, unknown_role);
    try std.testing.expect(parsed_role == .unknown);
    const encoded_role = try stringifyAlloc(arena, parsed_role);
    try std.testing.expectEqualStrings(unknown_role, encoded_role);

    const unknown_blocks =
        \\{"role":"assistant","content":[{"type":"futureReasoning","payload":{"v":2}},{"type":"fallback","from":{"model":"claude-a"},"to":{"model":"claude-b"}}],"api":"anthropic-messages","provider":"anthropic","model":"claude-b","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"stop","timestamp":10}
    ;
    const parsed_blocks = try parse(arena, unknown_blocks);
    try std.testing.expect(parsed_blocks == .assistant);
    try std.testing.expect(parsed_blocks.assistant.content[0] == .unknown);
    try std.testing.expect(parsed_blocks.assistant.content[1] == .fallback);
    const encoded_blocks = try stringifyAlloc(arena, parsed_blocks);
    try std.testing.expectEqualStrings(unknown_blocks, encoded_blocks);
}

test "message modeled rewrite fields are byte stable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fixtures = [_][]const u8{
        \\{"role":"user","content":[{"type":"text","text":"u"},{"type":"futureInput","payload":[1,2]}],"synthetic":true,"steering":false,"attribution":"user","providerPayload":{"type":"openaiResponsesHistory","items":[{"type":"message"}]},"timestamp":1}
        ,
        \\{"role":"developer","content":"d","attribution":"agent","providerPayload":{"type":"openaiResponsesHistory","provider":"openai","dt":true,"items":[]},"timestamp":2}
        ,
        \\{"role":"assistant","content":[{"type":"text","text":"done","textSignature":"sig"},{"type":"thinking","thinking":"why","thinkingSignature":"think-sig","itemId":"rs_1"},{"type":"redactedThinking","data":"redacted"},{"type":"fallback","from":{"model":"claude-a"},"to":{"model":"claude-b"}},{"type":"toolCall","id":"call-1","name":"edit","arguments":{"path":"a"},"thoughtSignature":"tool-sig","intent":"change","rawBlock":"<tool/>","customWireName":"apply_patch"}],"api":"anthropic-messages","provider":"anthropic","model":"claude-b","contextSnapshot":{"promptTokens":10,"nonMessageTokens":2,"lastMessageTimestamp":99},"retryRecovery":{"kind":"auto-retry","status":"recovered","attempt":2},"responseId":"msg-1","upstreamProvider":"Anthropic","usage":{"input":1,"output":2,"cacheRead":3,"cacheWrite":4,"totalTokens":10,"orchestration":{"input":5,"cacheRead":6,"output":7},"premiumRequests":8,"reasoningTokens":1,"cttl":{"ephemeral5m":3,"ephemeral1h":1},"server":{"webSearch":2,"webFetch":1},"cost":{"input":0.1,"output":0.2,"cacheRead":0.3,"cacheWrite":0.4,"total":1}},"stopReason":"toolUse","stopDetails":{"type":"pause_turn"},"errorMessage":"recovered","toolCallAbortMessages":{"call-1":"stopped"},"errorStatus":429,"errorId":17,"disabledFeatures":["priority"],"providerPayload":{"type":"openaiResponsesHistory","items":[]},"timestamp":3,"duration":4,"ttft":5}
        ,
        \\{"role":"bashExecution","command":"pwd","output":"/work","exitCode":0,"cancelled":false,"truncated":true,"meta":{"truncation":{"direction":"tail","truncatedBy":"bytes","totalLines":2,"totalBytes":100,"outputLines":1,"outputBytes":20}},"excludeFromContext":false,"timestamp":4}
        ,
        \\{"role":"compactionSummary","summary":"raw summary","shortSummary":"short","tokensBefore":500,"providerPayload":{"type":"openaiResponsesHistory","items":[]},"blocks":[{"type":"text","text":"old"},{"type":"image","data":"aA==","mimeType":"image/png","detail":"original"}],"images":[{"data":"aA==","mimeType":"image/png","detail":"original"}],"timestamp":5}
        ,
    };

    for (fixtures) |fixture| {
        const parsed = try parse(arena, fixture);
        const encoded = try stringifyAlloc(arena, parsed);
        try std.testing.expectEqualStrings(fixture, encoded);
    }
}

test "message docs assistant example parses with strict serialization defaults" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const docs_payload =
        \\{"role":"assistant","provider":"anthropic","model":"claude-sonnet-4-5","content":[{"type":"text","text":"Done."}],"usage":{"input":100,"output":20,"cacheRead":0,"cacheWrite":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"timestamp":1760000000000}
    ;
    const parsed = try parse(arena, docs_payload);
    try std.testing.expectEqualStrings("anthropic-messages", parsed.assistant.api);
    try std.testing.expectEqual(StopReason.stop, parsed.assistant.stop_reason);

    const encoded = try stringifyAlloc(arena, parsed);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"api\":\"anthropic-messages\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"stopReason\":\"stop\"") != null);
}
