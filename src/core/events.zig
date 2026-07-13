//! Frontend/core command and event vocabulary.
//!
//! Every slice in this module is owned by its containing payload. Values may be
//! moved freely, but must be deep-copied with `dupeInto` before crossing a
//! mailbox boundary and released exactly once with `deinit`.

const std = @import("std");
const catalog = @import("../catalog/types.zig");
const message = @import("message.zig");

const Allocator = std.mem.Allocator;

fn dupeOptional(allocator: Allocator, value: ?[]const u8) !?[]u8 {
    return if (value) |text| try allocator.dupe(u8, text) else null;
}

fn freeOptional(allocator: Allocator, value: ?[]u8) void {
    if (value) |text| allocator.free(text);
}

pub const OwnedText = struct {
    bytes: []u8,

    pub fn init(allocator: Allocator, bytes: []const u8) !OwnedText {
        return .{ .bytes = try allocator.dupe(u8, bytes) };
    }

    pub fn dupeInto(self: OwnedText, allocator: Allocator) !OwnedText {
        return init(allocator, self.bytes);
    }

    pub fn deinit(self: *OwnedText, allocator: Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const OwnedImage = struct {
    data: []u8,
    mime_type: []u8,
    detail: ?message.ImageDetail = null,

    pub fn init(
        allocator: Allocator,
        data: []const u8,
        mime_type: []const u8,
        detail: ?message.ImageDetail,
    ) !OwnedImage {
        const owned_data = try allocator.dupe(u8, data);
        errdefer allocator.free(owned_data);
        return .{
            .data = owned_data,
            .mime_type = try allocator.dupe(u8, mime_type),
            .detail = detail,
        };
    }

    pub fn dupeInto(self: OwnedImage, allocator: Allocator) !OwnedImage {
        return init(allocator, self.data, self.mime_type, self.detail);
    }

    pub fn deinit(self: *OwnedImage, allocator: Allocator) void {
        allocator.free(self.data);
        allocator.free(self.mime_type);
        self.* = undefined;
    }
};

pub const OwnedPrompt = struct {
    text: []u8,
    images: []OwnedImage,
    synthetic: bool = false,
    attribution: message.Attribution = .user,

    pub fn init(
        allocator: Allocator,
        text: []const u8,
        images: []const OwnedImage,
        synthetic: bool,
        attribution: message.Attribution,
    ) !OwnedPrompt {
        const owned_text = try allocator.dupe(u8, text);
        errdefer allocator.free(owned_text);
        const owned_images = try allocator.alloc(OwnedImage, images.len);
        var initialized: usize = 0;
        errdefer {
            for (owned_images[0..initialized]) |*image| image.deinit(allocator);
            allocator.free(owned_images);
        }
        for (images, owned_images) |image, *destination| {
            destination.* = try image.dupeInto(allocator);
            initialized += 1;
        }
        return .{
            .text = owned_text,
            .images = owned_images,
            .synthetic = synthetic,
            .attribution = attribution,
        };
    }

    pub fn dupeInto(self: OwnedPrompt, allocator: Allocator) !OwnedPrompt {
        return init(allocator, self.text, self.images, self.synthetic, self.attribution);
    }

    pub fn deinit(self: *OwnedPrompt, allocator: Allocator) void {
        allocator.free(self.text);
        for (self.images) |*image| image.deinit(allocator);
        allocator.free(self.images);
        self.* = undefined;
    }
};

pub const CancelReason = union(enum) {
    user,
    shutdown,
    deadline,
    superseded,
    other: OwnedText,

    pub fn dupeInto(self: CancelReason, allocator: Allocator) !CancelReason {
        return switch (self) {
            .other => |text| .{ .other = try text.dupeInto(allocator) },
            inline else => |_, tag| @unionInit(CancelReason, @tagName(tag), {}),
        };
    }

    pub fn deinit(self: *CancelReason, allocator: Allocator) void {
        switch (self.*) {
            .other => |*text| text.deinit(allocator),
            else => {},
        }
        self.* = undefined;
    }
};

pub const ApprovalDecision = struct {
    request_id: []u8,
    approved: bool,
    reason: ?[]u8 = null,

    pub fn init(
        allocator: Allocator,
        request_id: []const u8,
        approved: bool,
        reason: ?[]const u8,
    ) !ApprovalDecision {
        const owned_id = try allocator.dupe(u8, request_id);
        errdefer allocator.free(owned_id);
        return .{
            .request_id = owned_id,
            .approved = approved,
            .reason = try dupeOptional(allocator, reason),
        };
    }

    pub fn dupeInto(self: ApprovalDecision, allocator: Allocator) !ApprovalDecision {
        return init(allocator, self.request_id, self.approved, self.reason);
    }

    pub fn deinit(self: *ApprovalDecision, allocator: Allocator) void {
        allocator.free(self.request_id);
        freeOptional(allocator, self.reason);
        self.* = undefined;
    }
};

pub const ModelSelection = struct {
    provider: []u8,
    model: []u8,
    role: ?[]u8 = null,

    pub fn init(
        allocator: Allocator,
        provider_name: []const u8,
        model_name: []const u8,
        role: ?[]const u8,
    ) !ModelSelection {
        const provider_copy = try allocator.dupe(u8, provider_name);
        errdefer allocator.free(provider_copy);
        const model_copy = try allocator.dupe(u8, model_name);
        errdefer allocator.free(model_copy);
        return .{
            .provider = provider_copy,
            .model = model_copy,
            .role = try dupeOptional(allocator, role),
        };
    }

    pub fn dupeInto(self: ModelSelection, allocator: Allocator) !ModelSelection {
        return init(allocator, self.provider, self.model, self.role);
    }

    pub fn deinit(self: *ModelSelection, allocator: Allocator) void {
        allocator.free(self.provider);
        allocator.free(self.model);
        freeOptional(allocator, self.role);
        self.* = undefined;
    }
};

pub const AgentCommand = union(enum) {
    prompt: OwnedPrompt,
    steer: OwnedPrompt,
    follow_up: OwnedPrompt,
    dequeue_last,
    cancel: CancelReason,
    approve: ApprovalDecision,
    change_model: ModelSelection,
    change_thinking: catalog.ThinkingLevel,
    compact: ?OwnedText,
    retry,
    shutdown,

    pub fn dupeInto(self: AgentCommand, allocator: Allocator) !AgentCommand {
        return switch (self) {
            .prompt => |value| .{ .prompt = try value.dupeInto(allocator) },
            .steer => |value| .{ .steer = try value.dupeInto(allocator) },
            .follow_up => |value| .{ .follow_up = try value.dupeInto(allocator) },
            .cancel => |value| .{ .cancel = try value.dupeInto(allocator) },
            .approve => |value| .{ .approve = try value.dupeInto(allocator) },
            .change_model => |value| .{ .change_model = try value.dupeInto(allocator) },
            .change_thinking => |value| .{ .change_thinking = value },
            .compact => |value| .{ .compact = if (value) |text| try text.dupeInto(allocator) else null },
            .dequeue_last => .dequeue_last,
            .retry => .retry,
            .shutdown => .shutdown,
        };
    }

    pub fn deinit(self: *AgentCommand, allocator: Allocator) void {
        switch (self.*) {
            .prompt, .steer, .follow_up => |*value| value.deinit(allocator),
            .cancel => |*value| value.deinit(allocator),
            .approve => |*value| value.deinit(allocator),
            .change_model => |*value| value.deinit(allocator),
            .compact => |*value| if (value.*) |*text| text.deinit(allocator),
            else => {},
        }
        self.* = undefined;
    }
};

pub const RunStatus = enum { completed, cancelled, failed };

pub const RunResult = struct {
    status: RunStatus,
    turns: u32,

    pub fn dupeInto(self: RunResult, _: Allocator) !RunResult {
        return self;
    }

    pub fn deinit(self: *RunResult, _: Allocator) void {
        self.* = undefined;
    }
};

pub const TurnResult = struct {
    stop_reason: ?message.StopReason = null,
    tool_calls: u32 = 0,
    tool_results: u32 = 0,

    pub fn dupeInto(self: TurnResult, _: Allocator) !TurnResult {
        return self;
    }

    pub fn deinit(self: *TurnResult, _: Allocator) void {
        self.* = undefined;
    }
};

pub const MessageRole = enum {
    user,
    developer,
    assistant,
    tool_result,
    custom,
};

pub const MessageStarted = struct {
    id: []u8,
    role: MessageRole,

    pub fn init(allocator: Allocator, id: []const u8, role: MessageRole) !MessageStarted {
        return .{ .id = try allocator.dupe(u8, id), .role = role };
    }

    pub fn dupeInto(self: MessageStarted, allocator: Allocator) !MessageStarted {
        return init(allocator, self.id, self.role);
    }

    pub fn deinit(self: *MessageStarted, allocator: Allocator) void {
        allocator.free(self.id);
        self.* = undefined;
    }
};

pub const TextDelta = struct {
    message_id: []u8,
    text: []u8,

    pub fn init(allocator: Allocator, message_id: []const u8, text: []const u8) !TextDelta {
        const id = try allocator.dupe(u8, message_id);
        errdefer allocator.free(id);
        return .{ .message_id = id, .text = try allocator.dupe(u8, text) };
    }

    pub fn dupeInto(self: TextDelta, allocator: Allocator) !TextDelta {
        return init(allocator, self.message_id, self.text);
    }

    pub fn deinit(self: *TextDelta, allocator: Allocator) void {
        allocator.free(self.message_id);
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const ReasoningDelta = TextDelta;

pub const MessageFinished = struct {
    id: []u8,
    stop_reason: ?message.StopReason = null,
    text_blocks: [][]u8,
    error_message: ?[]u8 = null,

    pub fn init(
        allocator: Allocator,
        id: []const u8,
        stop_reason: ?message.StopReason,
        text_blocks: []const []const u8,
        error_message: ?[]const u8,
    ) !MessageFinished {
        const owned_id = try allocator.dupe(u8, id);
        errdefer allocator.free(owned_id);
        const owned_blocks = try allocator.alloc([]u8, text_blocks.len);
        var initialized: usize = 0;
        errdefer {
            for (owned_blocks[0..initialized]) |block| allocator.free(block);
            allocator.free(owned_blocks);
        }
        for (text_blocks, owned_blocks) |block, *destination| {
            destination.* = try allocator.dupe(u8, block);
            initialized += 1;
        }
        return .{
            .id = owned_id,
            .stop_reason = stop_reason,
            .text_blocks = owned_blocks,
            .error_message = try dupeOptional(allocator, error_message),
        };
    }

    pub fn initAssistant(
        allocator: Allocator,
        id: []const u8,
        assistant: message.AssistantMessage,
    ) !MessageFinished {
        var texts: std.ArrayList([]const u8) = .empty;
        defer texts.deinit(allocator);
        for (assistant.content) |block| switch (block) {
            .text => |text| try texts.append(allocator, text.text),
            else => {},
        };
        return init(allocator, id, assistant.stop_reason, texts.items, assistant.error_message);
    }

    pub fn dupeInto(self: MessageFinished, allocator: Allocator) !MessageFinished {
        return init(allocator, self.id, self.stop_reason, self.text_blocks, self.error_message);
    }

    pub fn deinit(self: *MessageFinished, allocator: Allocator) void {
        allocator.free(self.id);
        for (self.text_blocks) |block| allocator.free(block);
        allocator.free(self.text_blocks);
        freeOptional(allocator, self.error_message);
        self.* = undefined;
    }
};

pub const ToolStarted = struct {
    tool_call_id: []u8,
    tool_name: []u8,
    input_json: []u8,

    pub fn init(
        allocator: Allocator,
        tool_call_id: []const u8,
        tool_name: []const u8,
        input_json: []const u8,
    ) !ToolStarted {
        const call_id = try allocator.dupe(u8, tool_call_id);
        errdefer allocator.free(call_id);
        const name = try allocator.dupe(u8, tool_name);
        errdefer allocator.free(name);
        return .{
            .tool_call_id = call_id,
            .tool_name = name,
            .input_json = try allocator.dupe(u8, input_json),
        };
    }

    pub fn dupeInto(self: ToolStarted, allocator: Allocator) !ToolStarted {
        return init(allocator, self.tool_call_id, self.tool_name, self.input_json);
    }

    pub fn deinit(self: *ToolStarted, allocator: Allocator) void {
        allocator.free(self.tool_call_id);
        allocator.free(self.tool_name);
        allocator.free(self.input_json);
        self.* = undefined;
    }
};

pub const ToolOutputDelta = struct {
    tool_call_id: []u8,
    bytes: []u8,

    pub fn init(allocator: Allocator, tool_call_id: []const u8, bytes: []const u8) !ToolOutputDelta {
        const id = try allocator.dupe(u8, tool_call_id);
        errdefer allocator.free(id);
        return .{ .tool_call_id = id, .bytes = try allocator.dupe(u8, bytes) };
    }

    pub fn dupeInto(self: ToolOutputDelta, allocator: Allocator) !ToolOutputDelta {
        return init(allocator, self.tool_call_id, self.bytes);
    }

    pub fn deinit(self: *ToolOutputDelta, allocator: Allocator) void {
        allocator.free(self.tool_call_id);
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const ToolFinished = struct {
    tool_call_id: []u8,
    tool_name: []u8,
    is_error: bool,
    output_json: ?[]u8 = null,

    pub fn init(
        allocator: Allocator,
        tool_call_id: []const u8,
        tool_name: []const u8,
        is_error: bool,
        output_json: ?[]const u8,
    ) !ToolFinished {
        const call_id = try allocator.dupe(u8, tool_call_id);
        errdefer allocator.free(call_id);
        const name = try allocator.dupe(u8, tool_name);
        errdefer allocator.free(name);
        return .{
            .tool_call_id = call_id,
            .tool_name = name,
            .is_error = is_error,
            .output_json = try dupeOptional(allocator, output_json),
        };
    }

    pub fn dupeInto(self: ToolFinished, allocator: Allocator) !ToolFinished {
        return init(allocator, self.tool_call_id, self.tool_name, self.is_error, self.output_json);
    }

    pub fn deinit(self: *ToolFinished, allocator: Allocator) void {
        allocator.free(self.tool_call_id);
        allocator.free(self.tool_name);
        freeOptional(allocator, self.output_json);
        self.* = undefined;
    }
};

pub const ApprovalRequest = struct {
    request_id: []u8,
    tool_call_id: []u8,
    tool_name: []u8,
    reason: ?[]u8 = null,
    details_json: ?[]u8 = null,

    pub fn init(
        allocator: Allocator,
        request_id: []const u8,
        tool_call_id: []const u8,
        tool_name: []const u8,
        reason: ?[]const u8,
        details_json: ?[]const u8,
    ) !ApprovalRequest {
        const request = try allocator.dupe(u8, request_id);
        errdefer allocator.free(request);
        const call = try allocator.dupe(u8, tool_call_id);
        errdefer allocator.free(call);
        const name = try allocator.dupe(u8, tool_name);
        errdefer allocator.free(name);
        const reason_copy = try dupeOptional(allocator, reason);
        errdefer freeOptional(allocator, reason_copy);
        return .{
            .request_id = request,
            .tool_call_id = call,
            .tool_name = name,
            .reason = reason_copy,
            .details_json = try dupeOptional(allocator, details_json),
        };
    }

    pub fn dupeInto(self: ApprovalRequest, allocator: Allocator) !ApprovalRequest {
        return init(
            allocator,
            self.request_id,
            self.tool_call_id,
            self.tool_name,
            self.reason,
            self.details_json,
        );
    }

    pub fn deinit(self: *ApprovalRequest, allocator: Allocator) void {
        allocator.free(self.request_id);
        allocator.free(self.tool_call_id);
        allocator.free(self.tool_name);
        freeOptional(allocator, self.reason);
        freeOptional(allocator, self.details_json);
        self.* = undefined;
    }
};

pub const CompactionReason = enum {
    threshold,
    overflow,
    idle,
    incomplete,
};

pub const CompactionResult = struct {
    summary: []u8,
    short_summary: ?[]u8 = null,
    tokens_before: u64,

    pub fn init(
        allocator: Allocator,
        summary: []const u8,
        short_summary: ?[]const u8,
        tokens_before: u64,
    ) !CompactionResult {
        const summary_copy = try allocator.dupe(u8, summary);
        errdefer allocator.free(summary_copy);
        return .{
            .summary = summary_copy,
            .short_summary = try dupeOptional(allocator, short_summary),
            .tokens_before = tokens_before,
        };
    }

    pub fn dupeInto(self: CompactionResult, allocator: Allocator) !CompactionResult {
        return init(allocator, self.summary, self.short_summary, self.tokens_before);
    }

    pub fn deinit(self: *CompactionResult, allocator: Allocator) void {
        allocator.free(self.summary);
        freeOptional(allocator, self.short_summary);
        self.* = undefined;
    }
};

pub const RetryInfo = struct {
    attempt: u32,
    max_attempts: u32,
    delay_ms: u64,
    error_message: []u8,

    pub fn init(
        allocator: Allocator,
        attempt: u32,
        max_attempts: u32,
        delay_ms: u64,
        error_message: []const u8,
    ) !RetryInfo {
        return .{
            .attempt = attempt,
            .max_attempts = max_attempts,
            .delay_ms = delay_ms,
            .error_message = try allocator.dupe(u8, error_message),
        };
    }

    pub fn dupeInto(self: RetryInfo, allocator: Allocator) !RetryInfo {
        return init(allocator, self.attempt, self.max_attempts, self.delay_ms, self.error_message);
    }

    pub fn deinit(self: *RetryInfo, allocator: Allocator) void {
        allocator.free(self.error_message);
        self.* = undefined;
    }
};

pub const RetryOutcome = struct {
    success: bool,
    attempt: u32,
    final_error: ?[]u8 = null,

    pub fn init(
        allocator: Allocator,
        success: bool,
        attempt: u32,
        final_error: ?[]const u8,
    ) !RetryOutcome {
        return .{
            .success = success,
            .attempt = attempt,
            .final_error = try dupeOptional(allocator, final_error),
        };
    }

    pub fn dupeInto(self: RetryOutcome, allocator: Allocator) !RetryOutcome {
        return init(allocator, self.success, self.attempt, self.final_error);
    }

    pub fn deinit(self: *RetryOutcome, allocator: Allocator) void {
        freeOptional(allocator, self.final_error);
        self.* = undefined;
    }
};

pub const UsageSnapshot = struct {
    usage: catalog.Usage,
    context_window: ?u64 = null,
    context_percent: ?f64 = null,

    pub fn dupeInto(self: UsageSnapshot, _: Allocator) !UsageSnapshot {
        return self;
    }

    pub fn deinit(self: *UsageSnapshot, _: Allocator) void {
        self.* = undefined;
    }
};

pub const NoticeLevel = enum { info, warning, @"error" };

pub const Notice = struct {
    level: NoticeLevel,
    message: []u8,

    pub fn init(allocator: Allocator, level: NoticeLevel, text: []const u8) !Notice {
        return .{ .level = level, .message = try allocator.dupe(u8, text) };
    }

    pub fn dupeInto(self: Notice, allocator: Allocator) !Notice {
        return init(allocator, self.level, self.message);
    }

    pub fn deinit(self: *Notice, allocator: Allocator) void {
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const OwnedError = struct {
    code: ?[]u8 = null,
    message: []u8,

    pub fn init(allocator: Allocator, code: ?[]const u8, text: []const u8) !OwnedError {
        const code_copy = try dupeOptional(allocator, code);
        errdefer freeOptional(allocator, code_copy);
        return .{
            .code = code_copy,
            .message = try allocator.dupe(u8, text),
        };
    }

    pub fn dupeInto(self: OwnedError, allocator: Allocator) !OwnedError {
        return init(allocator, self.code, self.message);
    }

    pub fn deinit(self: *OwnedError, allocator: Allocator) void {
        freeOptional(allocator, self.code);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const AgentEvent = union(enum) {
    run_started,
    run_finished: RunResult,
    turn_started,
    turn_finished: TurnResult,
    message_started: MessageStarted,
    text_delta: TextDelta,
    reasoning_delta: ReasoningDelta,
    message_finished: MessageFinished,
    tool_started: ToolStarted,
    tool_output: ToolOutputDelta,
    tool_finished: ToolFinished,
    approval_requested: ApprovalRequest,
    auto_compaction_started: CompactionReason,
    auto_compaction_finished: CompactionResult,
    auto_retry_started: RetryInfo,
    auto_retry_finished: RetryOutcome,
    usage_updated: UsageSnapshot,
    notice: Notice,
    failed: OwnedError,

    /// Stable JSON-mode representation: one flat object with the active event
    /// name in `type`, followed by the payload fields in declaration order.
    pub fn jsonStringify(self: AgentEvent, jw: anytype) !void {
        try jw.beginObject();
        try eventField(jw, "type", @tagName(self));
        switch (self) {
            .run_started, .turn_started => {},
            .run_finished => |value| {
                try eventField(jw, "status", value.status);
                try eventField(jw, "turns", value.turns);
            },
            .turn_finished => |value| {
                if (value.stop_reason) |reason| try eventField(jw, "stop_reason", reason);
                try eventField(jw, "tool_calls", value.tool_calls);
                try eventField(jw, "tool_results", value.tool_results);
            },
            .message_started => |value| {
                try eventField(jw, "id", value.id);
                try eventField(jw, "role", value.role);
            },
            .text_delta, .reasoning_delta => |value| {
                try eventField(jw, "message_id", value.message_id);
                try eventField(jw, "text", value.text);
            },
            .message_finished => |value| {
                try eventField(jw, "id", value.id);
                if (value.stop_reason) |reason| try eventField(jw, "stop_reason", reason);
                if (value.text_blocks.len != 0) try eventField(jw, "text_blocks", value.text_blocks);
                if (value.error_message) |error_message| try eventField(jw, "error_message", error_message);
            },
            .tool_started => |value| {
                try eventField(jw, "tool_call_id", value.tool_call_id);
                try eventField(jw, "tool_name", value.tool_name);
                try eventField(jw, "input_json", value.input_json);
            },
            .tool_output => |value| {
                try eventField(jw, "tool_call_id", value.tool_call_id);
                try eventField(jw, "bytes", value.bytes);
            },
            .tool_finished => |value| {
                try eventField(jw, "tool_call_id", value.tool_call_id);
                try eventField(jw, "tool_name", value.tool_name);
                try eventField(jw, "is_error", value.is_error);
                if (value.output_json) |output| try eventField(jw, "output_json", output);
            },
            .approval_requested => |value| {
                try eventField(jw, "request_id", value.request_id);
                try eventField(jw, "tool_call_id", value.tool_call_id);
                try eventField(jw, "tool_name", value.tool_name);
                if (value.reason) |reason| try eventField(jw, "reason", reason);
                if (value.details_json) |details| try eventField(jw, "details_json", details);
            },
            .auto_compaction_started => |value| try eventField(jw, "reason", value),
            .auto_compaction_finished => |value| {
                try eventField(jw, "summary", value.summary);
                if (value.short_summary) |summary| try eventField(jw, "short_summary", summary);
                try eventField(jw, "tokens_before", value.tokens_before);
            },
            .auto_retry_started => |value| {
                try eventField(jw, "attempt", value.attempt);
                try eventField(jw, "max_attempts", value.max_attempts);
                try eventField(jw, "delay_ms", value.delay_ms);
                try eventField(jw, "error_message", value.error_message);
            },
            .auto_retry_finished => |value| {
                try eventField(jw, "success", value.success);
                try eventField(jw, "attempt", value.attempt);
                if (value.final_error) |failure| try eventField(jw, "final_error", failure);
            },
            .usage_updated => |value| {
                try eventField(jw, "usage", value.usage);
                if (value.context_window) |window| try eventField(jw, "context_window", window);
                if (value.context_percent) |percent| try eventField(jw, "context_percent", percent);
            },
            .notice => |value| {
                try eventField(jw, "level", value.level);
                try eventField(jw, "message", value.message);
            },
            .failed => |value| {
                if (value.code) |code| try eventField(jw, "code", code);
                try eventField(jw, "message", value.message);
            },
        }
        try jw.endObject();
    }

    pub fn dupeInto(self: AgentEvent, allocator: Allocator) !AgentEvent {
        return switch (self) {
            .message_started => |value| .{ .message_started = try value.dupeInto(allocator) },
            .text_delta => |value| .{ .text_delta = try value.dupeInto(allocator) },
            .reasoning_delta => |value| .{ .reasoning_delta = try value.dupeInto(allocator) },
            .message_finished => |value| .{ .message_finished = try value.dupeInto(allocator) },
            .tool_started => |value| .{ .tool_started = try value.dupeInto(allocator) },
            .tool_output => |value| .{ .tool_output = try value.dupeInto(allocator) },
            .tool_finished => |value| .{ .tool_finished = try value.dupeInto(allocator) },
            .approval_requested => |value| .{ .approval_requested = try value.dupeInto(allocator) },
            .auto_compaction_finished => |value| .{ .auto_compaction_finished = try value.dupeInto(allocator) },
            .auto_retry_started => |value| .{ .auto_retry_started = try value.dupeInto(allocator) },
            .auto_retry_finished => |value| .{ .auto_retry_finished = try value.dupeInto(allocator) },
            .notice => |value| .{ .notice = try value.dupeInto(allocator) },
            .failed => |value| .{ .failed = try value.dupeInto(allocator) },
            .run_started => .run_started,
            .run_finished => |value| .{ .run_finished = value },
            .turn_started => .turn_started,
            .turn_finished => |value| .{ .turn_finished = value },
            .auto_compaction_started => |value| .{ .auto_compaction_started = value },
            .usage_updated => |value| .{ .usage_updated = value },
        };
    }

    pub fn deinit(self: *AgentEvent, allocator: Allocator) void {
        switch (self.*) {
            .message_started => |*value| value.deinit(allocator),
            .text_delta => |*value| value.deinit(allocator),
            .reasoning_delta => |*value| value.deinit(allocator),
            .message_finished => |*value| value.deinit(allocator),
            .tool_started => |*value| value.deinit(allocator),
            .tool_output => |*value| value.deinit(allocator),
            .tool_finished => |*value| value.deinit(allocator),
            .approval_requested => |*value| value.deinit(allocator),
            .auto_compaction_finished => |*value| value.deinit(allocator),
            .auto_retry_started => |*value| value.deinit(allocator),
            .auto_retry_finished => |*value| value.deinit(allocator),
            .notice => |*value| value.deinit(allocator),
            .failed => |*value| value.deinit(allocator),
            else => {},
        }
        self.* = undefined;
    }
};

fn eventField(jw: anytype, name: []const u8, value: anytype) !void {
    try jw.objectField(name);
    try jw.write(value);
}

pub fn stringifyEventAlloc(allocator: Allocator, event: AgentEvent) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, event, .{ .emit_null_optional_fields = false });
}

test "events AgentCommand dupeInto deeply owns prompt payloads" {
    const allocator = std.testing.allocator;
    var source_image = try OwnedImage.init(allocator, "aGVsbG8=", "image/png", .high);
    defer source_image.deinit(allocator);
    var source_prompt = try OwnedPrompt.init(
        allocator,
        "inspect",
        &.{source_image},
        false,
        .user,
    );
    defer source_prompt.deinit(allocator);

    var command: AgentCommand = .{ .prompt = source_prompt };
    // `command` is a borrowed view of source_prompt for this test; only the
    // independently duplicated value is deinitialized through the union.
    var copied = try command.dupeInto(allocator);
    defer copied.deinit(allocator);
    source_prompt.text[0] = 'X';
    source_prompt.images[0].data[0] = 'Z';

    try std.testing.expectEqualStrings("inspect", copied.prompt.text);
    try std.testing.expectEqualStrings("aGVsbG8=", copied.prompt.images[0].data);
    command = .shutdown;
}

test "events AgentEvent dupeInto deeply owns nested approval and delta payloads" {
    const allocator = std.testing.allocator;
    var request = try ApprovalRequest.init(
        allocator,
        "approval-1",
        "call-1",
        "bash",
        "command execution",
        "{\"command\":\"pwd\"}",
    );
    defer request.deinit(allocator);
    const event: AgentEvent = .{ .approval_requested = request };
    var copied = try event.dupeInto(allocator);
    defer copied.deinit(allocator);
    request.tool_name[0] = 'X';
    try std.testing.expectEqualStrings("bash", copied.approval_requested.tool_name);

    var delta = try TextDelta.init(allocator, "message-1", "hello");
    defer delta.deinit(allocator);
    const delta_event: AgentEvent = .{ .text_delta = delta };
    var delta_copy = try delta_event.dupeInto(allocator);
    defer delta_copy.deinit(allocator);
    delta.text[0] = 'X';
    try std.testing.expectEqualStrings("hello", delta_copy.text_delta.text);
}
