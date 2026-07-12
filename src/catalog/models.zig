//! Bundled model registry and cost accounting.
//!
//! `models.json` is copied byte-for-byte from
//! `inspiration/packages/catalog/src/models.json` at the repository's pinned
//! oh-my-pi revision. The JSON remains data-only; this module owns parsing.

const std = @import("std");
const types = @import("types.zig");

pub const bundled_models_json = @embedFile("models.json");

const ProviderModels = std.StringHashMapUnmanaged(types.Model);

/// An allocator-owned parsed registry. Its model pointers remain valid until
/// `deinit`; an arena is used because all catalog values share one lifetime.
pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    providers: std.StringHashMapUnmanaged(ProviderModels),

    pub fn init(child_allocator: std.mem.Allocator) !Registry {
        var arena = std.heap.ArenaAllocator.init(child_allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();

        const document = try std.json.parseFromSliceLeaky(
            std.json.Value,
            allocator,
            bundled_models_json,
            .{ .allocate = .alloc_if_needed },
        );
        if (document != .object) return error.InvalidCatalogRoot;

        var providers: std.StringHashMapUnmanaged(ProviderModels) = .empty;
        var provider_iterator = document.object.iterator();
        while (provider_iterator.next()) |provider_entry| {
            if (provider_entry.value_ptr.* != .object) return error.InvalidProviderCatalog;

            var provider_models: ProviderModels = .empty;
            var model_iterator = provider_entry.value_ptr.object.iterator();
            while (model_iterator.next()) |model_entry| {
                var model = try std.json.parseFromValueLeaky(
                    types.Model,
                    allocator,
                    model_entry.value_ptr.*,
                    .{ .ignore_unknown_fields = true },
                );
                if (needsGoogleAntigravityRequiresEffortBackfill(provider_entry.key_ptr.*, model)) {
                    var thinking = model.thinking.?;
                    thinking.requiresEffort = true;
                    model.thinking = thinking;
                }
                try provider_models.put(allocator, model_entry.key_ptr.*, model);
            }
            try providers.put(allocator, provider_entry.key_ptr.*, provider_models);
        }

        return .{ .arena = arena, .providers = providers };
    }

    pub fn deinit(self: *Registry) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Returned models borrow this registry.
    pub fn get(self: *const Registry, provider_name: []const u8, model_id: []const u8) ?*const types.Model {
        const provider_models = self.providers.get(provider_name) orelse return null;
        return provider_models.getPtr(model_id);
    }
};

fn needsGoogleAntigravityRequiresEffortBackfill(
    provider_name: []const u8,
    model: types.Model,
) bool {
    if (!std.mem.eql(u8, provider_name, "google-antigravity")) return false;
    const thinking = model.thinking orelse return false;
    if (thinking.requiresEffort != null) return false;
    return std.mem.eql(u8, model.id, "gemini-3-flash") or
        std.mem.eql(u8, model.id, "gemini-3-pro") or
        std.mem.eql(u8, model.id, "gemini-3.1-pro") or
        std.mem.eql(u8, model.id, "gemini-3.5-flash");
}

// Process-lifetime cache mirroring upstream's module-level lazy registry.
// Phase 1a has no concurrent callers; the agent bootstrap initializes this
// before later worker activity is introduced.
var bundled_registry: ?Registry = null;

fn getBundledRegistry() !*const Registry {
    if (bundled_registry == null) {
        bundled_registry = try Registry.init(std.heap.page_allocator);
    }
    return if (bundled_registry) |*registry| registry else unreachable;
}

/// Lazily parse the embedded registry once. The returned model borrows
/// process-lifetime storage and must not be freed by the caller.
pub fn getBundledModel(provider_name: []const u8, model_id: []const u8) !?*const types.Model {
    return (try getBundledRegistry()).get(provider_name, model_id);
}

/// Reproduce `packages/catalog/src/models.ts:calculateCost`: orchestration
/// augments input, output, and cache-read billing; cache-write is conversation
/// cache creation only.
pub fn calculateCost(model: *const types.Model, usage: *types.Usage) types.Cost {
    const orchestration = usage.orchestration orelse types.OrchestrationUsage{};
    usage.cost.input = (model.cost.input / 1_000_000.0) *
        @as(f64, @floatFromInt(usage.input + orchestration.input));
    usage.cost.output = (model.cost.output / 1_000_000.0) *
        @as(f64, @floatFromInt(usage.output + orchestration.output));
    usage.cost.cache_read = (model.cost.cacheRead / 1_000_000.0) *
        @as(f64, @floatFromInt(usage.cache_read + orchestration.cache_read));
    usage.cost.cache_write = (model.cost.cacheWrite / 1_000_000.0) *
        @as(f64, @floatFromInt(usage.cache_write));
    usage.cost.total = usage.cost.input + usage.cost.output +
        usage.cost.cache_read + usage.cost.cache_write;
    return usage.cost;
}

test "catalog bundled lookup parses real Anthropic and OpenAI models once" {
    const anthropic = (try getBundledModel("anthropic", "claude-sonnet-4-6")).?;
    try std.testing.expectEqualStrings("Claude Sonnet 4.6", anthropic.name);
    try std.testing.expectEqualStrings("anthropic-messages", anthropic.api.wireName());
    try std.testing.expectEqual(@as(?u64, 1_000_000), anthropic.contextWindow);
    try std.testing.expect(anthropic.thinking.?.mode == .@"anthropic-adaptive");

    const openai = (try getBundledModel("openai", "gpt-5.2")).?;
    try std.testing.expectEqualStrings("GPT-5.2", openai.name);
    try std.testing.expectEqual(@as(f64, 1.75), openai.cost.input);
    try std.testing.expect(openai.thinking.?.supports(.xhigh));

    const same_openai = (try getBundledModel("openai", "gpt-5.2")).?;
    try std.testing.expect(openai == same_openai);
    try std.testing.expect((try getBundledModel("missing", "gpt-5.2")) == null);
    try std.testing.expect((try getBundledModel("openai", "missing")) == null);
}

test "catalog registry honors ignore_unknown_fields and caller ownership" {
    var registry = try Registry.init(std.testing.allocator);
    defer registry.deinit();

    const model = registry.get("google-antigravity", "gemini-3-flash").?;
    try std.testing.expectEqualStrings("google-gemini-cli", model.api.wireName());
    try std.testing.expectEqual(@as(?i64, 4_000), model.thinking.?.effortBudgets.?.medium);
    try std.testing.expectEqual(@as(?bool, true), model.thinking.?.suppressWhenOff);
}

test "catalog registry backfills mandatory effort on four Antigravity Gemini models" {
    var registry = try Registry.init(std.testing.allocator);
    defer registry.deinit();

    const ids = [_][]const u8{
        "gemini-3-flash",
        "gemini-3-pro",
        "gemini-3.1-pro",
        "gemini-3.5-flash",
    };
    for (ids) |id| {
        const model = registry.get("google-antigravity", id).?;
        try std.testing.expectEqual(@as(?bool, true), model.thinking.?.requiresEffort);
    }
}

test "catalog calculateCost matches upstream component pairing" {
    const model = (try getBundledModel("anthropic", "claude-sonnet-4-6")).?;
    var usage: types.Usage = .{
        .input = 1_000_000,
        .output = 200_000,
        .cache_read = 300_000,
        .cache_write = 400_000,
        .orchestration = .{
            .input = 250_000,
            .output = 50_000,
            .cache_read = 100_000,
        },
    };

    const cost = calculateCost(model, &usage);
    try std.testing.expectApproxEqAbs(@as(f64, 3.75), cost.input, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 3.75), cost.output, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.12), cost.cache_read, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), cost.cache_write, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 9.12), cost.total, 1e-12);
    try std.testing.expectApproxEqAbs(cost.total, usage.cost.total, 1e-12);
}

test "catalog calculateCost uses real OpenAI pricing" {
    const model = (try getBundledModel("openai", "gpt-5.2")).?;
    var usage: types.Usage = .{
        .input = 1_000_000,
        .output = 1_000_000,
        .cache_read = 1_000_000,
        .cache_write = 1_000_000,
    };

    const cost = calculateCost(model, &usage);
    try std.testing.expectApproxEqAbs(@as(f64, 1.75), cost.input, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 14), cost.output, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.175), cost.cache_read, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0), cost.cache_write, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 15.925), cost.total, 1e-12);
}
