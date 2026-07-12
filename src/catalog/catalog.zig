//! Embedded model catalog, capabilities, costs, and thinking mappings.
//!
//! The bundled JSON is MIT-licensed upstream data copied verbatim from the
//! repository-pinned oh-my-pi catalog. Parsed model pointers borrow either a
//! caller-owned `Registry` or the process-lifetime lazy bundled registry.

const std = @import("std");

pub const types = @import("types.zig");
pub const models = @import("models.zig");
pub const thinking = @import("thinking.zig");

pub const KnownApi = types.KnownApi;
pub const Api = types.Api;
pub const Effort = types.Effort;
pub const ThinkingLevel = types.ThinkingLevel;
pub const ThinkingControlMode = types.ThinkingControlMode;
pub const EffortBudgets = types.EffortBudgets;
pub const EffortMap = types.EffortMap;
pub const ThinkingConfig = types.ThinkingConfig;
pub const InputModality = types.InputModality;
pub const ModelCost = types.ModelCost;
pub const Model = types.Model;
pub const Cost = types.Cost;
pub const OrchestrationUsage = types.OrchestrationUsage;
pub const Usage = types.Usage;

pub const Registry = models.Registry;
pub const bundled_models_json = models.bundled_models_json;
pub const getBundledModel = models.getBundledModel;
pub const calculateCost = models.calculateCost;

pub const BudgetTable = thinking.BudgetTable;
pub const StringTable = thinking.StringTable;
pub const GoogleThinkingLevel = thinking.GoogleThinkingLevel;
pub const ProviderKnob = thinking.ProviderKnob;
pub const MapEffortError = thinking.MapError;
pub const anthropic_budgets = thinking.anthropic_budgets;
pub const bedrock_budgets = thinking.bedrock_budgets;
pub const google_25_flash_budgets = thinking.google_25_flash_budgets;
pub const google_25_pro_budgets = thinking.google_25_pro_budgets;
pub const google_cli_budgets = thinking.google_cli_budgets;
pub const google_levels = thinking.google_levels;
pub const openai_effort_strings = thinking.openai_effort_strings;
pub const mapEffort = thinking.mapEffort;

test {
    std.testing.refAllDecls(@This());
}
