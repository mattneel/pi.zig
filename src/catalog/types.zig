//! Model-catalog and usage-accounting value types.
//!
//! Models returned by the bundled registry borrow process-lifetime storage.
//! Values parsed by callers borrow the arena owned by `std.json.Parsed`.

const std = @import("std");
const provider = @import("provider");

/// APIs with first-party dispatch support in the upstream catalog.
pub const KnownApi = enum {
    @"openai-completions",
    @"openai-responses",
    openrouter,
    @"openai-codex-responses",
    @"azure-openai-responses",
    @"anthropic-messages",
    @"bedrock-converse-stream",
    @"google-generative-ai",
    @"google-gemini-cli",
    @"google-vertex",
    @"ollama-chat",
    @"cursor-agent",
    @"gitlab-duo-agent",
    @"devin-agent",
};

/// A known API or an extension-provided API name.
pub const Api = union(enum) {
    known: KnownApi,
    custom: []const u8,

    pub fn fromString(value: []const u8) Api {
        return if (std.meta.stringToEnum(KnownApi, value)) |known|
            .{ .known = known }
        else
            .{ .custom = value };
    }

    pub fn wireName(self: Api) []const u8 {
        return switch (self) {
            .known => |known| @tagName(known),
            .custom => |custom| custom,
        };
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !Api {
        return fromString(try std.json.innerParse([]const u8, allocator, source, options));
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) std.json.ParseFromValueError!Api {
        return switch (source) {
            .string => |value| if (std.meta.stringToEnum(KnownApi, value)) |known|
                .{ .known = known }
            else
                .{ .custom = try allocator.dupe(u8, value) },
            else => error.UnexpectedToken,
        };
    }
};

/// User-facing thinking levels, ordered from least to most intensive.
pub const Effort = enum {
    minimal,
    low,
    medium,
    high,
    xhigh,
    max,
};

pub const all_efforts = [_]Effort{ .minimal, .low, .medium, .high, .xhigh, .max };

/// Session-facing thinking level; `off` is not a provider effort.
pub const ThinkingLevel = enum {
    off,
    minimal,
    low,
    medium,
    high,
    xhigh,
    max,

    pub fn asEffort(self: ThinkingLevel) ?Effort {
        return switch (self) {
            .off => null,
            .minimal => .minimal,
            .low => .low,
            .medium => .medium,
            .high => .high,
            .xhigh => .xhigh,
            .max => .max,
        };
    }
};

pub const ThinkingControlMode = enum {
    effort,
    budget,
    @"google-level",
    @"anthropic-adaptive",
    @"anthropic-budget-effort",
};

pub const EffortBudgets = struct {
    minimal: ?i64 = null,
    low: ?i64 = null,
    medium: ?i64 = null,
    high: ?i64 = null,
    xhigh: ?i64 = null,
    max: ?i64 = null,

    pub fn get(self: EffortBudgets, effort: Effort) ?i64 {
        return switch (effort) {
            inline else => |tag| @field(self, @tagName(tag)),
        };
    }
};

/// Baked provider wire remaps. Missing entries use the effort's own name.
pub const EffortMap = struct {
    minimal: ?[]const u8 = null,
    low: ?[]const u8 = null,
    medium: ?[]const u8 = null,
    high: ?[]const u8 = null,
    xhigh: ?[]const u8 = null,
    max: ?[]const u8 = null,

    pub fn get(self: EffortMap, effort: Effort) ?[]const u8 {
        return switch (effort) {
            inline else => |tag| @field(self, @tagName(tag)),
        };
    }
};

/// Per-thinking-level provider model ids for collapsed catalog variants.
pub const EffortRouting = struct {
    off: ?[]const u8 = null,
    minimal: ?[]const u8 = null,
    low: ?[]const u8 = null,
    medium: ?[]const u8 = null,
    high: ?[]const u8 = null,
    xhigh: ?[]const u8 = null,
    max: ?[]const u8 = null,

    pub fn get(self: EffortRouting, level: ThinkingLevel) ?[]const u8 {
        return switch (level) {
            inline else => |tag| @field(self, @tagName(tag)),
        };
    }

    pub fn getEffort(self: EffortRouting, effort: ?Effort) ?[]const u8 {
        return if (effort) |value|
            switch (value) {
                inline else => |tag| @field(self, @tagName(tag)),
            }
        else
            self.off;
    }
};

pub const ThinkingConfig = struct {
    mode: ThinkingControlMode,
    efforts: []const Effort,
    defaultLevel: ?Effort = null,
    effortMap: ?EffortMap = null,
    supportsDisplay: ?bool = null,
    effortRouting: ?EffortRouting = null,
    effortBudgets: ?EffortBudgets = null,
    requiresEffort: ?bool = null,
    suppressWhenOff: ?bool = null,

    pub fn supports(self: ThinkingConfig, effort: Effort) bool {
        for (self.efforts) |candidate| {
            if (candidate == effort) return true;
        }
        return false;
    }
};

pub const InputModality = enum {
    text,
    image,
};

/// Per-million-token prices from the model catalog.
pub const ModelCost = struct {
    input: f64,
    output: f64,
    cacheRead: f64,
    cacheWrite: f64,
};

pub const Model = struct {
    id: []const u8,
    requestModelId: ?[]const u8 = null,
    name: []const u8,
    api: Api,
    provider: []const u8,
    baseUrl: ?[]const u8 = null,
    reasoning: bool,
    input: []const InputModality,
    supportsTools: ?bool = null,
    cost: ModelCost,
    contextWindow: ?u64 = null,
    maxTokens: ?u64 = null,
    thinking: ?ThinkingConfig = null,
};

/// USD cost buckets stored on assistant messages.
pub const Cost = struct {
    input: f64 = 0,
    output: f64 = 0,
    cache_read: f64 = 0,
    cache_write: f64 = 0,
    total: f64 = 0,
};

/// Provider-side tokens that are billed but are not replayable conversation
/// input. Upstream reports no orchestration cache-write bucket.
pub const OrchestrationUsage = struct {
    input: u64 = 0,
    cache_read: u64 = 0,
    output: u64 = 0,
};

pub const CacheTtlUsage = struct {
    ephemeral5m: ?u64 = null,
    ephemeral1h: ?u64 = null,
};

pub const ServerToolUsage = struct {
    webSearch: ?u64 = null,
    webFetch: ?u64 = null,
};

/// Upstream usage vocabulary. Required counters default to zero so partially
/// populated provider reports can be normalized without nullable arithmetic.
pub const Usage = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,
    total_tokens: ?u64 = null,
    orchestration: ?OrchestrationUsage = null,
    premium_requests: ?u64 = null,
    reasoning_tokens: ?u64 = null,
    cttl: ?CacheTtlUsage = null,
    server: ?ServerToolUsage = null,
    cost: Cost = .{},

    /// Map ai.zig's disjoint token buckets into the upstream Pi vocabulary.
    /// When both aggregate input and output counts are present, their sum is
    /// the upstream total; otherwise it remains unknown rather than guessed.
    pub fn fromAiUsage(value: provider.Usage, cost: Cost) Usage {
        return .{
            .input = value.input_tokens.no_cache orelse 0,
            .output = value.output_tokens.total orelse 0,
            .cache_read = value.input_tokens.cache_read orelse 0,
            .cache_write = value.input_tokens.cache_write orelse 0,
            .total_tokens = if (value.input_tokens.total) |input_total|
                if (value.output_tokens.total) |output_total| input_total + output_total else null
            else
                null,
            .reasoning_tokens = value.output_tokens.reasoning,
            .cost = cost,
        };
    }
};

test "catalog API preserves known and extension names" {
    const known = Api.fromString("openai-responses");
    try std.testing.expectEqualStrings("openai-responses", known.wireName());
    try std.testing.expect(known == .known);

    const custom = Api.fromString("acme-stream-v2");
    try std.testing.expectEqualStrings("acme-stream-v2", custom.wireName());
    try std.testing.expect(custom == .custom);

    const parsed = try std.json.parseFromSlice(Api, std.testing.allocator, "\"acme-stream-v2\"", .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .custom);
    try std.testing.expectEqualStrings("acme-stream-v2", parsed.value.wireName());

    var source = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "\"owned-extension-api\"",
        .{},
    );
    var from_value = try std.json.parseFromValue(
        Api,
        std.testing.allocator,
        source.value,
        .{},
    );
    source.deinit();
    defer from_value.deinit();
    try std.testing.expect(from_value.value == .custom);
    try std.testing.expectEqualStrings("owned-extension-api", from_value.value.wireName());
}

test "catalog Usage.fromAiUsage maps disjoint provider buckets" {
    const usage = Usage.fromAiUsage(.{
        .input_tokens = .{
            .total = 30,
            .no_cache = 11,
            .cache_read = 13,
            .cache_write = 6,
        },
        .output_tokens = .{
            .total = 17,
            .text = 12,
            .reasoning = 5,
        },
    }, .{ .total = 1.25 });

    try std.testing.expectEqual(@as(u64, 11), usage.input);
    try std.testing.expectEqual(@as(u64, 17), usage.output);
    try std.testing.expectEqual(@as(u64, 13), usage.cache_read);
    try std.testing.expectEqual(@as(u64, 6), usage.cache_write);
    try std.testing.expectEqual(@as(?u64, 5), usage.reasoning_tokens);
    try std.testing.expectEqual(@as(?u64, 47), usage.total_tokens);
    try std.testing.expectEqual(@as(f64, 1.25), usage.cost.total);
}
