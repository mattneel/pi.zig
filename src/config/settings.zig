//! JSON settings layers for the phase-2 frontends.

const std = @import("std");
const approval = @import("../core/approval.zig");
const catalog = @import("../catalog/types.zig");
const session_paths = @import("../session/paths.zig");

const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;

const defaults_json =
    \\{
    \\  "modelRoles": {},
    \\  "cycleOrder": ["smol", "default", "slow"],
    \\  "includeModelInPrompt": true,
    \\  "defaultThinkingLevel": "high",
    \\  "retry": {"maxRetries": 10, "baseDelayMs": 500, "maxDelayMs": 300000},
    \\  "tools": {"approvalMode": "yolo"},
    \\  "edit": {"mode": "hashline"},
    \\  "read": {"defaultLimit": 300}
    \\}
;

pub const RuntimeOverrides = struct {
    model: ?[]const u8 = null,
    thinking: ?catalog.ThinkingLevel = null,
};

pub const LoadOptions = struct {
    cwd: []const u8,
    overlays: []const []const u8 = &.{},
    path_options: session_paths.Options = .{},
    runtime: RuntimeOverrides = .{},
};

pub const Retry = struct {
    max_retries: u8,
    base_delay_ms: u64,
    max_delay_ms: u64,
};

pub const Settings = struct {
    arena_state: std.heap.ArenaAllocator,
    document: JsonValue,
    model_roles: std.json.ObjectMap,
    cycle_order: []const []const u8,
    include_model_in_prompt: bool,
    default_thinking_level: catalog.ThinkingLevel,
    retry: Retry,
    approval_mode: approval.ApprovalMode,
    edit_mode: []const u8,
    read_default_limit: usize,

    pub fn load(gpa: Allocator, io: std.Io, options: LoadOptions) !Settings {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();
        var document = try parseObject(arena, defaults_json);

        const global_path = try globalConfigPathAlloc(arena, options.path_options);
        try mergeOptionalFile(io, arena, &document, global_path);

        const project_path = try std.fs.path.join(arena, &.{ options.cwd, ".omp-zig", "config.json" });
        try mergeOptionalFile(io, arena, &document, project_path);

        for (options.overlays) |overlay| {
            const resolved = try resolveAgainst(arena, options.cwd, overlay);
            try mergeRequiredFile(io, arena, &document, resolved);
        }
        try applyRuntime(arena, &document, options.runtime);

        const typed = try validate(arena, document);
        return .{
            .arena_state = arena_state,
            .document = document,
            .model_roles = typed.model_roles,
            .cycle_order = typed.cycle_order,
            .include_model_in_prompt = typed.include_model_in_prompt,
            .default_thinking_level = typed.default_thinking_level,
            .retry = typed.retry,
            .approval_mode = typed.approval_mode,
            .edit_mode = typed.edit_mode,
            .read_default_limit = typed.read_default_limit,
        };
    }

    pub fn deinit(self: *Settings) void {
        self.arena_state.deinit();
        self.* = undefined;
    }

    pub fn modelRole(self: *const Settings, role: []const u8) ?[]const u8 {
        const value = self.model_roles.get(role) orelse return null;
        return switch (value) {
            .string => |text| text,
            else => null,
        };
    }

    pub fn valueAt(self: *const Settings, dotted_path: []const u8) ?JsonValue {
        var current = self.document;
        var parts = std.mem.splitScalar(u8, dotted_path, '.');
        while (parts.next()) |part| {
            current = switch (current) {
                .object => |object| object.get(part) orelse return null,
                else => return null,
            };
        }
        return current;
    }
};

pub fn globalConfigPathAlloc(allocator: Allocator, options: session_paths.Options) ![]u8 {
    const agent_dir = try session_paths.agentDirAlloc(allocator, options);
    defer allocator.free(agent_dir);
    return std.fs.path.join(allocator, &.{ agent_dir, "config.json" });
}

pub fn modelsConfigPathAlloc(allocator: Allocator, options: session_paths.Options) ![]u8 {
    const agent_dir = try session_paths.agentDirAlloc(allocator, options);
    defer allocator.free(agent_dir);
    return std.fs.path.join(allocator, &.{ agent_dir, "models.json" });
}

const Validated = struct {
    model_roles: std.json.ObjectMap,
    cycle_order: []const []const u8,
    include_model_in_prompt: bool,
    default_thinking_level: catalog.ThinkingLevel,
    retry: Retry,
    approval_mode: approval.ApprovalMode,
    edit_mode: []const u8,
    read_default_limit: usize,
};

fn validate(arena: Allocator, document: JsonValue) !Validated {
    const root = try asObject(document);
    const model_roles = try asObject(root.get("modelRoles") orelse return error.InvalidSettings);
    var role_iterator = model_roles.iterator();
    while (role_iterator.next()) |entry| if (entry.value_ptr.* != .string) return error.InvalidSettings;

    const cycle_value = root.get("cycleOrder") orelse return error.InvalidSettings;
    const cycle_array = switch (cycle_value) {
        .array => |array| array.items,
        else => return error.InvalidSettings,
    };
    const cycle_order = try arena.alloc([]const u8, cycle_array.len);
    for (cycle_array, cycle_order) |value, *destination| destination.* = try asString(value);

    const retry_object = try asObject(root.get("retry") orelse return error.InvalidSettings);
    const tools_object = try asObject(root.get("tools") orelse return error.InvalidSettings);
    const edit_object = try asObject(root.get("edit") orelse return error.InvalidSettings);
    const read_object = try asObject(root.get("read") orelse return error.InvalidSettings);
    const approval_name = try asString(tools_object.get("approvalMode") orelse return error.InvalidSettings);
    const approval_mode: approval.ApprovalMode = if (std.mem.eql(u8, approval_name, "always-ask"))
        .always_ask
    else
        std.meta.stringToEnum(approval.ApprovalMode, approval_name) orelse return error.InvalidSettings;
    const edit_mode = try asString(edit_object.get("mode") orelse return error.InvalidSettings);
    if (!std.mem.eql(u8, edit_mode, "hashline")) return error.UnsupportedEditMode;

    return .{
        .model_roles = model_roles,
        .cycle_order = cycle_order,
        .include_model_in_prompt = try asBool(root.get("includeModelInPrompt") orelse return error.InvalidSettings),
        .default_thinking_level = std.meta.stringToEnum(
            catalog.ThinkingLevel,
            try asString(root.get("defaultThinkingLevel") orelse return error.InvalidSettings),
        ) orelse return error.InvalidSettings,
        .retry = .{
            .max_retries = std.math.cast(u8, try asUnsigned(retry_object.get("maxRetries") orelse return error.InvalidSettings)) orelse
                return error.InvalidSettings,
            .base_delay_ms = try asUnsigned(retry_object.get("baseDelayMs") orelse return error.InvalidSettings),
            .max_delay_ms = try asUnsigned(retry_object.get("maxDelayMs") orelse return error.InvalidSettings),
        },
        .approval_mode = approval_mode,
        .edit_mode = edit_mode,
        .read_default_limit = std.math.cast(usize, try asUnsigned(read_object.get("defaultLimit") orelse return error.InvalidSettings)) orelse
            return error.InvalidSettings,
    };
}

fn mergeOptionalFile(io: std.Io, arena: Allocator, document: *JsonValue, path: []const u8) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    const layer = try parseObject(arena, bytes);
    try deepMerge(arena, document, layer);
}

fn mergeRequiredFile(io: std.Io, arena: Allocator, document: *JsonValue, path: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(8 * 1024 * 1024));
    const layer = try parseObject(arena, bytes);
    try deepMerge(arena, document, layer);
}

fn parseObject(arena: Allocator, bytes: []const u8) !JsonValue {
    const value = try std.json.parseFromSliceLeaky(JsonValue, arena, bytes, .{ .allocate = .alloc_always });
    if (value != .object) return error.InvalidConfigRoot;
    return value;
}

fn deepMerge(arena: Allocator, destination: *JsonValue, source: JsonValue) !void {
    if (destination.* == .object and source == .object) {
        var iterator = source.object.iterator();
        while (iterator.next()) |entry| {
            if (destination.object.getPtr(entry.key_ptr.*)) |current| {
                try deepMerge(arena, current, entry.value_ptr.*);
            } else {
                try destination.object.put(arena, try arena.dupe(u8, entry.key_ptr.*), entry.value_ptr.*);
            }
        }
        return;
    }
    destination.* = source;
}

fn applyRuntime(arena: Allocator, document: *JsonValue, runtime: RuntimeOverrides) !void {
    const root = &document.object;
    if (runtime.model) |model| {
        const roles = root.getPtr("modelRoles") orelse return error.InvalidSettings;
        if (roles.* != .object) return error.InvalidSettings;
        try roles.object.put(arena, try arena.dupe(u8, "default"), .{ .string = try arena.dupe(u8, model) });
    }
    if (runtime.thinking) |thinking| {
        try root.put(
            arena,
            try arena.dupe(u8, "defaultThinkingLevel"),
            .{ .string = try arena.dupe(u8, @tagName(thinking)) },
        );
    }
}

fn resolveAgainst(allocator: Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(allocator, &.{path});
    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

fn asObject(value: JsonValue) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.InvalidSettings,
    };
}

fn asString(value: JsonValue) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => error.InvalidSettings,
    };
}

fn asBool(value: JsonValue) !bool {
    return switch (value) {
        .bool => |boolean| boolean,
        else => error.InvalidSettings,
    };
}

fn asUnsigned(value: JsonValue) !u64 {
    return switch (value) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else error.InvalidSettings,
        else => error.InvalidSettings,
    };
}

fn writeFile(io: std.Io, directory: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    try directory.writeFile(io, .{ .sub_path = path, .data = bytes });
}

test "settings defaults match the phase two consumed schema" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var settings = try Settings.load(allocator, io, .{
        .cwd = root,
        .path_options = .{ .agent_dir = root, .home = root, .temp_dir = "/tmp" },
    });
    defer settings.deinit();
    try std.testing.expectEqual(catalog.ThinkingLevel.high, settings.default_thinking_level);
    try std.testing.expectEqual(approval.ApprovalMode.yolo, settings.approval_mode);
    try std.testing.expectEqualStrings("hashline", settings.edit_mode);
    try std.testing.expectEqual(@as(usize, 300), settings.read_default_limit);
    try std.testing.expectEqual(Retry{ .max_retries = 10, .base_delay_ms = 500, .max_delay_ms = 300_000 }, settings.retry);
    try expectStrings(&.{ "smol", "default", "slow" }, settings.cycle_order);
    try std.testing.expect(settings.include_model_in_prompt);
}

test "settings precedence deep merges objects and replaces scalars and arrays" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "agent");
    try tmp.dir.createDirPath(io, "project/.omp-zig");
    try writeFile(io, tmp.dir, "agent/config.json",
        \\{"modelRoles":{"default":"global/default","smol":"global/smol"},"cycleOrder":["default"],"retry":{"baseDelayMs":700},"extra":{"left":1,"shared":{"a":1}}}
    );
    try writeFile(io, tmp.dir, "project/.omp-zig/config.json",
        \\{"modelRoles":{"smol":"project/smol"},"cycleOrder":["smol","default"],"extra":{"shared":{"b":2}}}
    );
    try writeFile(io, tmp.dir, "overlay-a.json",
        \\{"retry":{"maxRetries":4},"extra":{"shared":{"a":3,"c":4}}}
    );
    try writeFile(io, tmp.dir, "overlay-b.json",
        \\{"includeModelInPrompt":false,"read":{"defaultLimit":42}}
    );
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const project = try std.fs.path.join(allocator, &.{ root, "project" });
    defer allocator.free(project);
    const agent_dir = try std.fs.path.join(allocator, &.{ root, "agent" });
    defer allocator.free(agent_dir);
    var settings = try Settings.load(allocator, io, .{
        .cwd = project,
        .overlays = &.{ "../overlay-a.json", "../overlay-b.json" },
        .path_options = .{ .agent_dir = agent_dir, .home = root, .temp_dir = "/tmp" },
        .runtime = .{ .model = "runtime/default", .thinking = .medium },
    });
    defer settings.deinit();
    try std.testing.expectEqualStrings("runtime/default", settings.modelRole("default").?);
    try std.testing.expectEqualStrings("project/smol", settings.modelRole("smol").?);
    try expectStrings(&.{ "smol", "default" }, settings.cycle_order);
    try std.testing.expectEqual(catalog.ThinkingLevel.medium, settings.default_thinking_level);
    try std.testing.expectEqual(Retry{ .max_retries = 4, .base_delay_ms = 700, .max_delay_ms = 300_000 }, settings.retry);
    try std.testing.expect(!settings.include_model_in_prompt);
    try std.testing.expectEqual(@as(usize, 42), settings.read_default_limit);
    try std.testing.expectEqual(@as(i64, 3), settings.valueAt("extra.shared.a").?.integer);
    try std.testing.expectEqual(@as(i64, 2), settings.valueAt("extra.shared.b").?.integer);
    try std.testing.expectEqual(@as(i64, 4), settings.valueAt("extra.shared.c").?.integer);
}

test "settings overlays require an existing object JSON document" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "invalid.json", "{");
    try writeFile(io, tmp.dir, "array.json", "[]");
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const options: session_paths.Options = .{ .agent_dir = root, .home = root, .temp_dir = "/tmp" };
    try std.testing.expectError(error.FileNotFound, Settings.load(allocator, io, .{
        .cwd = root,
        .overlays = &.{"missing.json"},
        .path_options = options,
    }));
    try std.testing.expectError(error.UnexpectedEndOfInput, Settings.load(allocator, io, .{
        .cwd = root,
        .overlays = &.{"invalid.json"},
        .path_options = options,
    }));
    try std.testing.expectError(error.InvalidConfigRoot, Settings.load(allocator, io, .{
        .cwd = root,
        .overlays = &.{"array.json"},
        .path_options = options,
    }));
}

fn expectStrings(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |left, right| try std.testing.expectEqualStrings(left, right);
}
