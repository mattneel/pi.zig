//! Bundled-catalog selection, API-key lookup, and ai.zig provider construction.

const std = @import("std");
const ai = @import("ai");
const anthropic = @import("anthropic");
const google = @import("google");
const openai = @import("openai");
const openai_compatible = @import("openai_compatible");
const openrouter = @import("openrouter");
const provider_utils = @import("provider_utils");
const xai = @import("xai");
const catalog = @import("../catalog/catalog.zig");
const agent = @import("../core/agent.zig");
const settings = @import("../config/settings.zig");
const session_paths = @import("../session/paths.zig");

const Allocator = std.mem.Allocator;

pub const Selection = struct {
    registry: catalog.Registry,
    model: *const catalog.Model,
    thinking: ?catalog.ThinkingLevel,

    pub fn init(gpa: Allocator, selector: []const u8) !Selection {
        var registry = try catalog.Registry.init(gpa);
        errdefer registry.deinit();
        const split = splitThinking(&registry, selector);
        const model = findModel(&registry, split.selector) orelse return error.ModelNotFound;
        return .{ .registry = registry, .model = model, .thinking = split.thinking };
    }

    pub fn deinit(self: *Selection) void {
        self.registry.deinit();
        self.* = undefined;
    }
};

pub const KeyOptions = struct {
    runtime_key: ?[]const u8 = null,
    path_options: session_paths.Options = .{},
    environ: ?std.process.Environ = null,
};

/// The returned key is allocator-owned. No caller in this module writes key
/// bytes to output or persistence.
pub fn resolveApiKeyAlloc(
    allocator: Allocator,
    io: std.Io,
    provider_name: []const u8,
    options: KeyOptions,
) !?[]u8 {
    if (options.runtime_key) |key| if (key.len != 0) return @as(?[]u8, try allocator.dupe(u8, key));

    const models_path = try settings.modelsConfigPathAlloc(allocator, options.path_options);
    defer allocator.free(models_path);
    const config_key = try modelsConfigKeyAlloc(allocator, io, models_path, provider_name, options.environ);
    if (config_key != null) return config_key;

    const variable = providerEnvVar(provider_name) orelse return null;
    return environmentValueAlloc(allocator, options.environ, variable);
}

fn modelsConfigKeyAlloc(
    allocator: Allocator,
    io: std.Io,
    path: []const u8,
    provider_name: []const u8,
    environ: ?std.process.Environ,
) !?[]u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidModelsConfig,
    };
    const providers_value = root.get("providers") orelse return null;
    const providers = switch (providers_value) {
        .object => |object| object,
        else => return error.InvalidModelsConfig,
    };
    const provider_value = providers.get(provider_name) orelse return null;
    const provider_object = switch (provider_value) {
        .object => |object| object,
        else => return error.InvalidModelsConfig,
    };
    const api_key_value = provider_object.get("apiKey") orelse return null;
    const configured = switch (api_key_value) {
        .string => |text| text,
        else => return error.InvalidModelsConfig,
    };
    if (configured.len == 0) return null;
    if (configured[0] == '!') return error.ModelsConfigKeyCommandUnsupported;
    if (try environmentValueAlloc(allocator, environ, configured)) |from_environment| return from_environment;
    return @as(?[]u8, try allocator.dupe(u8, configured));
}

fn providerEnvVar(provider_name: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(provider_name, "anthropic")) return "ANTHROPIC_API_KEY";
    if (std.ascii.eqlIgnoreCase(provider_name, "openai")) return "OPENAI_API_KEY";
    if (std.ascii.eqlIgnoreCase(provider_name, "google")) return "GEMINI_API_KEY";
    if (std.ascii.eqlIgnoreCase(provider_name, "openrouter")) return "OPENROUTER_API_KEY";
    if (std.ascii.eqlIgnoreCase(provider_name, "xai")) return "XAI_API_KEY";
    return null;
}

fn environmentValueAlloc(
    allocator: Allocator,
    environ: ?std.process.Environ,
    name: []const u8,
) !?[]u8 {
    const source = environ orelse return null;
    return std.process.Environ.getAlloc(source, allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => return err,
    };
}

pub const ModelResolver = struct {
    gpa: Allocator,
    storage: *Storage,
    target_value: agent.ModelTarget,

    pub fn init(
        gpa: Allocator,
        io: std.Io,
        model: *const catalog.Model,
        api_key: []const u8,
    ) !ModelResolver {
        const storage = try gpa.create(Storage);
        errdefer gpa.destroy(storage);
        storage.* = .{
            .transport = provider_utils.HttpClientTransport.init(gpa, io),
            .provider = undefined,
        };
        errdefer storage.transport.deinit();

        const request_model_id = model.requestModelId orelse model.id;
        const language_model = try buildLanguageModel(storage, gpa, model, request_model_id, api_key);
        return .{
            .gpa = gpa,
            .storage = storage,
            .target_value = .{
                .language_model = .{ .model = language_model },
                .provider_name = model.provider,
                .model_id = model.id,
                .api = model.api.wireName(),
            },
        };
    }

    pub fn deinit(self: *ModelResolver) void {
        self.storage.transport.deinit();
        self.gpa.destroy(self.storage);
        self.* = undefined;
    }

    pub fn target(self: *const ModelResolver) agent.ModelTarget {
        return self.target_value;
    }

    pub fn seam(self: *ModelResolver) agent.ResolveModel {
        return .{ .ctx = self, .resolve_fn = resolve };
    }

    fn resolve(raw: ?*anyopaque, provider_name: []const u8, model_id: []const u8) ?agent.ModelTarget {
        const self: *ModelResolver = @ptrCast(@alignCast(raw.?));
        if (!std.ascii.eqlIgnoreCase(provider_name, self.target_value.provider_name)) return null;
        if (!std.ascii.eqlIgnoreCase(model_id, self.target_value.model_id)) return null;
        return self.target_value;
    }
};

const Storage = struct {
    transport: provider_utils.HttpClientTransport,
    provider: ProviderStorage,
};

const ProviderStorage = union(enum) {
    anthropic_messages: struct {
        factory: anthropic.Anthropic,
        model: anthropic.AnthropicLanguageModel,
    },
    openai_responses: struct {
        factory: openai.OpenAi,
        model: openai.ResponsesLanguageModel,
    },
    openai_chat: struct {
        factory: openai.OpenAi,
        model: openai.ChatLanguageModel,
    },
    openai_compatible: struct {
        factory: openai_compatible.OpenAiCompatible,
        model: openai_compatible.ChatLanguageModel,
    },
    openrouter: struct {
        factory: openrouter.OpenRouter,
        model: openai_compatible.ChatLanguageModel,
    },
    google: struct {
        factory: google.GoogleGenerativeAi,
        model: google.GoogleLanguageModel,
    },
    xai: struct {
        factory: xai.Xai,
        model: openai_compatible.ChatLanguageModel,
    },
};

fn buildLanguageModel(
    storage: *Storage,
    gpa: Allocator,
    model: *const catalog.Model,
    request_model_id: []const u8,
    api_key: []const u8,
) !@import("provider").LanguageModel {
    const transport = storage.transport.transport();
    const api = model.api.wireName();
    if (std.mem.eql(u8, model.provider, "openrouter") or std.mem.eql(u8, api, "openrouter")) {
        storage.provider = .{ .openrouter = .{
            .factory = openrouter.createOpenRouter(.{
                .base_url = model.baseUrl,
                .api_key = api_key,
                .transport = transport,
                .include_usage = true,
            }),
            .model = undefined,
        } };
        storage.provider.openrouter.model = try storage.provider.openrouter.factory.chatModel(request_model_id, null);
        return storage.provider.openrouter.model.languageModel();
    }
    if (std.mem.eql(u8, model.provider, "google") and std.mem.eql(u8, api, "google-generative-ai")) {
        storage.provider = .{ .google = .{
            .factory = google.createGoogleGenerativeAi(.{
                .allocator = gpa,
                .base_url = model.baseUrl,
                .api_key = api_key,
                .transport = transport,
            }),
            .model = undefined,
        } };
        storage.provider.google.model = try storage.provider.google.factory.languageModel(request_model_id, null);
        return storage.provider.google.model.languageModel();
    }
    if (std.mem.eql(u8, model.provider, "xai") and std.mem.eql(u8, api, "openai-completions")) {
        storage.provider = .{ .xai = .{
            .factory = xai.createXai(.{
                .allocator = gpa,
                .base_url = model.baseUrl,
                .api_key = api_key,
                .transport = transport,
            }),
            .model = undefined,
        } };
        storage.provider.xai.model = try storage.provider.xai.factory.languageModel(request_model_id, null);
        return storage.provider.xai.model.languageModel();
    }
    if (std.mem.eql(u8, api, "anthropic-messages")) {
        if (!std.mem.eql(u8, model.provider, "anthropic") and model.baseUrl == null) return error.MissingProviderBaseUrl;
        storage.provider = .{ .anthropic_messages = .{
            .factory = try anthropic.createAnthropic(.{
                .base_url = model.baseUrl,
                .api_key = api_key,
                .transport = transport,
                .provider_name = model.provider,
            }),
            .model = undefined,
        } };
        storage.provider.anthropic_messages.model = try storage.provider.anthropic_messages.factory.messages(request_model_id, null);
        return storage.provider.anthropic_messages.model.languageModel();
    }
    if (std.mem.eql(u8, api, "openai-responses")) {
        storage.provider = .{ .openai_responses = .{
            .factory = openai.createOpenAi(.{
                .allocator = gpa,
                .base_url = model.baseUrl,
                .api_key = api_key,
                .transport = transport,
                .name = model.provider,
            }),
            .model = undefined,
        } };
        storage.provider.openai_responses.model = try storage.provider.openai_responses.factory.responses(request_model_id, null);
        return storage.provider.openai_responses.model.languageModel();
    }
    if (std.mem.eql(u8, model.provider, "openai") and std.mem.eql(u8, api, "openai-completions")) {
        storage.provider = .{ .openai_chat = .{
            .factory = openai.createOpenAi(.{
                .allocator = gpa,
                .base_url = model.baseUrl,
                .api_key = api_key,
                .transport = transport,
            }),
            .model = undefined,
        } };
        storage.provider.openai_chat.model = try storage.provider.openai_chat.factory.chat(request_model_id, null);
        return storage.provider.openai_chat.model.languageModel();
    }
    if (std.mem.eql(u8, api, "openai-completions")) {
        const base_url = model.baseUrl orelse return error.MissingProviderBaseUrl;
        storage.provider = .{ .openai_compatible = .{
            .factory = openai_compatible.createOpenAiCompatible(.{
                .provider_name = model.provider,
                .base_url = base_url,
                .api_key = api_key,
                .transport = transport,
                .include_usage = true,
            }),
            .model = undefined,
        } };
        storage.provider.openai_compatible.model = try storage.provider.openai_compatible.factory.chatModel(request_model_id, null);
        return storage.provider.openai_compatible.model.languageModel();
    }
    return error.UnsupportedProviderApi;
}

const SplitSelector = struct {
    selector: []const u8,
    thinking: ?catalog.ThinkingLevel,
};

fn splitThinking(registry: *const catalog.Registry, selector: []const u8) SplitSelector {
    if (findExact(registry, selector) != null) return .{ .selector = selector, .thinking = null };
    const colon = std.mem.lastIndexOfScalar(u8, selector, ':') orelse return .{ .selector = selector, .thinking = null };
    if (colon == 0 or colon + 1 == selector.len) return .{ .selector = selector, .thinking = null };
    const thinking = std.meta.stringToEnum(catalog.ThinkingLevel, selector[colon + 1 ..]) orelse
        return .{ .selector = selector, .thinking = null };
    return .{ .selector = selector[0..colon], .thinking = thinking };
}

fn findExact(registry: *const catalog.Registry, selector: []const u8) ?*const catalog.Model {
    const slash = std.mem.indexOfScalar(u8, selector, '/') orelse return null;
    if (slash == 0 or slash + 1 == selector.len) return null;
    return registry.get(selector[0..slash], selector[slash + 1 ..]);
}

fn findModel(registry: *const catalog.Registry, selector: []const u8) ?*const catalog.Model {
    if (selector.len == 0) return null;
    if (findExact(registry, selector)) |exact| return exact;
    var best: ?*const catalog.Model = null;
    var best_rank: u8 = std.math.maxInt(u8);
    var provider_iterator = registry.providers.iterator();
    while (provider_iterator.next()) |provider_entry| {
        var model_iterator = provider_entry.value_ptr.iterator();
        while (model_iterator.next()) |model_entry| {
            const candidate = model_entry.value_ptr;
            const rank = matchRank(candidate, selector) orelse continue;
            if (best == null or rank < best_rank or
                (rank == best_rank and modelLess(candidate, best.?)))
            {
                best = candidate;
                best_rank = rank;
            }
        }
    }
    return best;
}

fn matchRank(model: *const catalog.Model, selector: []const u8) ?u8 {
    const has_provider = std.mem.indexOfScalar(u8, selector, '/') != null;
    if (has_provider) {
        var full_buffer: [512]u8 = undefined;
        const full = std.fmt.bufPrint(&full_buffer, "{s}/{s}", .{ model.provider, model.id }) catch return null;
        if (std.ascii.eqlIgnoreCase(full, selector)) return 0;
        if (std.ascii.startsWithIgnoreCase(full, selector)) return 3;
        if (std.ascii.indexOfIgnoreCase(full, selector) != null) return 5;
        return null;
    }
    if (std.ascii.eqlIgnoreCase(model.id, selector)) return 1;
    if (std.ascii.eqlIgnoreCase(model.name, selector)) return 2;
    if (std.ascii.startsWithIgnoreCase(model.id, selector)) return 3;
    if (std.ascii.startsWithIgnoreCase(model.name, selector)) return 4;
    if (std.ascii.indexOfIgnoreCase(model.id, selector) != null) return 6;
    if (std.ascii.indexOfIgnoreCase(model.name, selector) != null) return 7;
    return null;
}

fn modelLess(left: *const catalog.Model, right: *const catalog.Model) bool {
    const left_priority = providerPriority(left.provider);
    const right_priority = providerPriority(right.provider);
    if (left_priority != right_priority) return left_priority < right_priority;
    const provider_order = std.ascii.orderIgnoreCase(left.provider, right.provider);
    if (provider_order != .eq) return provider_order == .lt;
    return std.ascii.orderIgnoreCase(left.id, right.id) == .lt;
}

fn providerPriority(name: []const u8) u8 {
    if (std.mem.eql(u8, name, "anthropic")) return 0;
    if (std.mem.eql(u8, name, "openai")) return 1;
    if (std.mem.eql(u8, name, "google")) return 2;
    if (std.mem.eql(u8, name, "openrouter")) return 3;
    if (std.mem.eql(u8, name, "xai")) return 4;
    return 5;
}

test "bundled model selection supports provider ids fuzzy names and thinking suffixes" {
    var exact = try Selection.init(std.testing.allocator, "anthropic/claude-sonnet-4-6:medium");
    defer exact.deinit();
    try std.testing.expectEqualStrings("anthropic", exact.model.provider);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", exact.model.id);
    try std.testing.expectEqual(catalog.ThinkingLevel.medium, exact.thinking.?);

    const ultra = splitThinking(&exact.registry, "anthropic/claude-sonnet-4-6:ultra");
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-4-6", ultra.selector);
    try std.testing.expectEqual(catalog.ThinkingLevel.ultra, ultra.thinking.?);

    var fuzzy = try Selection.init(std.testing.allocator, "Claude Sonnet 4.6");
    defer fuzzy.deinit();
    try std.testing.expectEqualStrings("anthropic", fuzzy.model.provider);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", fuzzy.model.id);
}

test "empty model selection does not choose a catalog model" {
    try std.testing.expectError(
        error.ModelNotFound,
        Selection.init(std.testing.allocator, ""),
    );
}

test "runtime and models config keys precede provider environment keys" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "models.json",
        .data = "{\"providers\":{\"anthropic\":{\"apiKey\":\"MODELS_KEY\"}}}",
    });
    var environment_map = std.process.Environ.Map.init(allocator);
    defer environment_map.deinit();
    try environment_map.put("MODELS_KEY", "models-value");
    try environment_map.put("ANTHROPIC_API_KEY", "environment-value");
    const block = try environment_map.createPosixBlock(allocator, .{});
    defer block.deinit(allocator);
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const path_options: session_paths.Options = .{ .agent_dir = root, .home = root, .temp_dir = "/tmp" };
    const from_runtime = (try resolveApiKeyAlloc(allocator, io, "anthropic", .{
        .runtime_key = "runtime-value",
        .path_options = path_options,
        .environ = .{ .block = block },
    })).?;
    defer allocator.free(from_runtime);
    try std.testing.expectEqualStrings("runtime-value", from_runtime);
    const from_models = (try resolveApiKeyAlloc(allocator, io, "anthropic", .{
        .path_options = path_options,
        .environ = .{ .block = block },
    })).?;
    defer allocator.free(from_models);
    try std.testing.expectEqualStrings("models-value", from_models);
}

test "bundled anthropic construction yields a resolver target without a request" {
    var selection = try Selection.init(std.testing.allocator, "anthropic/claude-sonnet-4-6");
    defer selection.deinit();
    var resolver = try ModelResolver.init(std.testing.allocator, std.testing.io, selection.model, "dummy-key");
    defer resolver.deinit();
    const target = resolver.target();
    try std.testing.expectEqualStrings("anthropic", target.provider_name);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", target.model_id);
    try std.testing.expectEqualStrings("anthropic-messages", target.api.?);
    try std.testing.expect(resolver.seam().resolve_fn(resolver.seam().ctx, "anthropic", "claude-sonnet-4-6") != null);
}

test "bundled openai-compatible construction yields a resolver target without a request" {
    var selection = try Selection.init(std.testing.allocator, "mistral/codestral-latest");
    defer selection.deinit();
    var resolver = try ModelResolver.init(std.testing.allocator, std.testing.io, selection.model, "dummy-key");
    defer resolver.deinit();
    const target = resolver.target();
    try std.testing.expectEqualStrings("mistral", target.provider_name);
    try std.testing.expectEqualStrings("codestral-latest", target.model_id);
    try std.testing.expectEqualStrings("openai-completions", target.api.?);
}

test "first-party providers use the documented environment key map" {
    const cases = [_]struct { provider_name: []const u8, variable: []const u8 }{
        .{ .provider_name = "anthropic", .variable = "ANTHROPIC_API_KEY" },
        .{ .provider_name = "openai", .variable = "OPENAI_API_KEY" },
        .{ .provider_name = "google", .variable = "GEMINI_API_KEY" },
        .{ .provider_name = "openrouter", .variable = "OPENROUTER_API_KEY" },
        .{ .provider_name = "xai", .variable = "XAI_API_KEY" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(
        case.variable,
        providerEnvVar(case.provider_name).?,
    );
}
