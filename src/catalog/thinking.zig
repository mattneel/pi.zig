//! Provider thinking-knob tables and model-aware effort mapping.
//!
//! Tables are transcribed from upstream `packages/ai/src/stream.ts` and
//! `packages/catalog/src/model-thinking.ts` at the pinned revision.

const std = @import("std");
const types = @import("types.zig");

pub const BudgetTable = [types.all_efforts.len]i64;
pub const StringTable = [types.all_efforts.len][]const u8;

/// `ANTHROPIC_THINKING` from `packages/ai/src/stream.ts`.
pub const anthropic_budgets: BudgetTable = .{ 1024, 4096, 8192, 16384, 32768, 32768 };

/// `BEDROCK_CLAUDE_THINKING`; Bedrock's low/xhigh tiers intentionally differ.
pub const bedrock_budgets: BudgetTable = .{ 1024, 2048, 8192, 16384, 16384, 32768 };

/// Gemini 2.5 Flash-family `getGoogleBudget` ladder.
pub const google_25_flash_budgets: BudgetTable = .{ 128, 2048, 8192, 24576, 24576, 24576 };

/// Gemini 2.5 Pro-family `getGoogleBudget` ladder.
pub const google_25_pro_budgets: BudgetTable = .{ 128, 2048, 8192, 32768, 32768, 32768 };

/// Gemini CLI fallback `GOOGLE_THINKING` ladder.
pub const google_cli_budgets: BudgetTable = .{ 1024, 4096, 8192, 16384, 24575, 32768 };

/// OpenAI-family identity wire strings; model `effortMap` entries override it.
pub const openai_effort_strings: StringTable = .{ "minimal", "low", "medium", "high", "xhigh", "max" };

pub const GoogleThinkingLevel = enum {
    MINIMAL,
    LOW,
    MEDIUM,
    HIGH,
};

/// `mapEffortToGoogleThinkingLevel`: xhigh/max collapse to HIGH.
pub const google_levels = [types.all_efforts.len]GoogleThinkingLevel{
    .MINIMAL,
    .LOW,
    .MEDIUM,
    .HIGH,
    .HIGH,
    .HIGH,
};

pub const BudgetAndEffort = struct {
    tokens: i64,
    effort: []const u8,
};

/// The provider-facing value selected by a model's canonical thinking mode.
pub const ProviderKnob = union(enum) {
    reasoning_effort: []const u8,
    thinking_budget: i64,
    google_level: GoogleThinkingLevel,
    anthropic_effort: []const u8,
    anthropic_budget_effort: BudgetAndEffort,
};

pub const MapError = error{
    ThinkingUnsupported,
    EffortUnsupported,
};

/// Resolve collapsed effort variants to their provider wire model id.
pub fn resolveWireModelId(model: *const types.Model, effort: ?types.Effort) []const u8 {
    if (model.thinking) |thinking| {
        if (thinking.effortRouting) |routing| {
            if (routing.getEffort(effort)) |wire_id| return wire_id;
        }
    }
    return model.requestModelId orelse model.id;
}

fn index(effort: types.Effort) usize {
    return @intFromEnum(effort);
}

fn wireEffort(thinking: types.ThinkingConfig, effort: types.Effort) []const u8 {
    if (thinking.effortMap) |effort_map| {
        if (effort_map.get(effort)) |mapped| return mapped;
    }
    return openai_effort_strings[index(effort)];
}

fn budgetFor(model: *const types.Model, thinking: types.ThinkingConfig, effort: types.Effort) i64 {
    if (thinking.effortBudgets) |budgets| {
        if (budgets.get(effort)) |budget| return budget;
    }

    return switch (model.api) {
        .known => |api| switch (api) {
            .@"bedrock-converse-stream" => bedrock_budgets[index(effort)],
            .@"google-generative-ai", .@"google-vertex" => if (std.mem.indexOf(u8, model.id, "2.5-") != null)
                (if (std.mem.indexOf(u8, model.id, "2.5-flash") != null)
                    google_25_flash_budgets[index(effort)]
                else
                    google_25_pro_budgets[index(effort)])
            else
                -1,
            .@"google-gemini-cli" => google_cli_budgets[index(effort)],
            else => anthropic_budgets[index(effort)],
        },
        .custom => anthropic_budgets[index(effort)],
    };
}

/// Map one supported user effort to the provider transport selected by the
/// model. Unsupported levels fail rather than silently changing user intent;
/// callers that want clamping can do so before request construction.
pub fn mapEffort(model: *const types.Model, effort: types.Effort) MapError!ProviderKnob {
    if (!model.reasoning) return error.ThinkingUnsupported;
    const thinking = model.thinking orelse return error.ThinkingUnsupported;
    if (!thinking.supports(effort)) return error.EffortUnsupported;

    return switch (thinking.mode) {
        .effort => .{ .reasoning_effort = wireEffort(thinking, effort) },
        .budget => .{ .thinking_budget = budgetFor(model, thinking, effort) },
        .@"google-level" => .{ .google_level = google_levels[index(effort)] },
        .@"anthropic-adaptive" => .{ .anthropic_effort = wireEffort(thinking, effort) },
        .@"anthropic-budget-effort" => .{ .anthropic_budget_effort = .{
            .tokens = budgetFor(model, thinking, effort),
            .effort = wireEffort(thinking, effort),
        } },
    };
}

test "catalog thinking Anthropic budget table matches upstream" {
    try std.testing.expectEqual(@as(i64, 1024), anthropic_budgets[index(.minimal)]);
    try std.testing.expectEqual(@as(i64, 4096), anthropic_budgets[index(.low)]);
    try std.testing.expectEqual(@as(i64, 8192), anthropic_budgets[index(.medium)]);
    try std.testing.expectEqual(@as(i64, 16384), anthropic_budgets[index(.high)]);
    try std.testing.expectEqual(@as(i64, 32768), anthropic_budgets[index(.xhigh)]);
    try std.testing.expectEqual(@as(i64, 32768), anthropic_budgets[index(.max)]);
}

test "catalog thinking Google 2.5 family ladders match upstream" {
    try std.testing.expectEqual(@as(i64, 128), google_25_flash_budgets[index(.minimal)]);
    try std.testing.expectEqual(@as(i64, 2048), google_25_flash_budgets[index(.low)]);
    try std.testing.expectEqual(@as(i64, 8192), google_25_flash_budgets[index(.medium)]);
    try std.testing.expectEqual(@as(i64, 24576), google_25_flash_budgets[index(.high)]);
    try std.testing.expectEqual(@as(i64, 32768), google_25_pro_budgets[index(.high)]);
    try std.testing.expectEqual(.HIGH, google_levels[index(.max)]);
}

test "catalog thinking OpenAI effort strings match upstream" {
    try std.testing.expectEqualStrings("minimal", openai_effort_strings[index(.minimal)]);
    try std.testing.expectEqualStrings("xhigh", openai_effort_strings[index(.xhigh)]);
    try std.testing.expectEqualStrings("max", openai_effort_strings[index(.max)]);
}

test "catalog thinking mapEffort uses real bundled model modes" {
    const models = @import("models.zig");

    const anthropic = (try models.getBundledModel("anthropic", "claude-sonnet-4-6")).?;
    const adaptive = try mapEffort(anthropic, .high);
    try std.testing.expectEqualStrings("high", adaptive.anthropic_effort);

    const flash = (try models.getBundledModel("google", "gemini-2.5-flash")).?;
    const flash_budget = try mapEffort(flash, .high);
    try std.testing.expectEqual(@as(i64, 24576), flash_budget.thinking_budget);

    const openai = (try models.getBundledModel("openai", "gpt-5.2")).?;
    const openai_effort = try mapEffort(openai, .xhigh);
    try std.testing.expectEqualStrings("xhigh", openai_effort.reasoning_effort);
    try std.testing.expectError(error.EffortUnsupported, mapEffort(openai, .max));
}

test "catalog thinking mapEffort honors baked maps and budgets" {
    const models = @import("models.zig");

    const minimax = (try models.getBundledModel("minimax", "MiniMax-M2.5")).?;
    const adaptive = try mapEffort(minimax, .medium);
    try std.testing.expectEqualStrings("adaptive", adaptive.anthropic_effort);

    const antigravity = (try models.getBundledModel("google-antigravity", "gemini-3-flash")).?;
    const budget = try mapEffort(antigravity, .medium);
    try std.testing.expectEqual(@as(i64, 4000), budget.thinking_budget);
}

test "catalog thinking resolves routed wire ids including off" {
    const models = @import("models.zig");
    const antigravity = (try models.getBundledModel("google-antigravity", "gemini-3-flash")).?;

    try std.testing.expect(antigravity.thinking.?.supportsDisplay == null);
    try std.testing.expectEqualStrings(
        "gemini-3.5-flash-extra-low",
        resolveWireModelId(antigravity, null),
    );
    try std.testing.expectEqualStrings(
        "gemini-3-flash-agent",
        resolveWireModelId(antigravity, .high),
    );

    const anthropic = (try models.getBundledModel("anthropic", "claude-sonnet-4-6")).?;
    try std.testing.expectEqualStrings(
        anthropic.requestModelId orelse anthropic.id,
        resolveWireModelId(anthropic, .medium),
    );
    const display_model = (try models.getBundledModel(
        "amazon-bedrock",
        "anthropic.claude-opus-4-7",
    )).?;
    try std.testing.expectEqual(@as(?bool, true), display_model.thinking.?.supportsDisplay);
}
