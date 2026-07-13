//! CLI startup and frontend wiring.

const std = @import("std");
const agent = @import("../core/agent.zig");
const args = @import("args.zig");
const build_options = @import("build_options");
const catalog = @import("../catalog/types.zig");
const history = @import("../history/history.zig");
const model_resolver = @import("model_resolver.zig");
const modes = @import("../modes/modes.zig");
const session_paths = @import("../session/paths.zig");
const session_resolver = @import("session_resolver.zig");
const settings_module = @import("../config/settings.zig");
const tools = @import("../tools/tools.zig");

const Allocator = std.mem.Allocator;

pub const ExitCode = enum(u8) {
    success = 0,
    failure = 1,
    unknown_flags = 2,
};

pub const RunOptions = struct {
    environ: ?std.process.Environ = null,
    path_options: session_paths.Options = .{},
};

pub const help_text =
    \\Usage: omp-zig [options] [prompt ...]
    \\
    \\Options:
    \\  --cwd <path>
    \\  --model <fuzzy|provider/id[:thinking]>
    \\  --thinking <off|minimal|low|medium|high|xhigh|max|ultra>
    \\  -p, --print
    \\  --mode <text|json>
    \\  -r, --resume [session]
    \\  -c, --continue
    \\  --no-session
    \\  --session-dir <path>
    \\  --config <file>
    \\  --api-key <key>
    \\  --tools <read,bash,edit,write>
    \\  --no-tools
    \\  --system-prompt <text-or-file>
    \\  --append-system-prompt <text>
    \\  -v, --version
    \\  -h, --help
    \\
;

pub fn run(
    allocator: Allocator,
    io: std.Io,
    argv: []const []const u8,
    stdin: std.Io.File,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    options: RunOptions,
) !u8 {
    var parsed = try args.parse(allocator, argv);
    defer parsed.deinit(allocator);
    if (try handleImmediate(parsed, stdout, stderr)) |code| return @intFromEnum(code);

    const stdin_is_tty = try stdin.isTty(io);
    const piped_input = if (stdin_is_tty)
        null
    else
        try readPipedInput(allocator, io, stdin, stderr);
    defer if (piped_input) |text| allocator.free(text);
    return runParsed(allocator, io, parsed, stdin_is_tty, piped_input, stdout, stderr, options);
}

pub fn runWithInput(
    allocator: Allocator,
    io: std.Io,
    argv: []const []const u8,
    stdin_is_tty: bool,
    piped_input: ?[]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    options: RunOptions,
) !u8 {
    var parsed = try args.parse(allocator, argv);
    defer parsed.deinit(allocator);
    if (try handleImmediate(parsed, stdout, stderr)) |code| return @intFromEnum(code);
    return runParsed(allocator, io, parsed, stdin_is_tty, piped_input, stdout, stderr, options);
}

fn handleImmediate(
    parsed: args.Parsed,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !?ExitCode {
    if (parsed.help) {
        try stdout.writeAll(help_text);
        try stdout.flush();
        return .success;
    }
    if (parsed.version) {
        try stdout.writeAll(build_options.version ++ "\n");
        try stdout.flush();
        return .success;
    }
    if (parsed.unknown_flags.len != 0) {
        const plural = if (parsed.unknown_flags.len == 1) "" else "s";
        try stderr.print("Error: unknown flag{s}: ", .{plural});
        for (parsed.unknown_flags, 0..) |flag, index| {
            if (index != 0) try stderr.writeAll(", ");
            try stderr.writeAll(flag);
        }
        try stderr.writeAll("\nRun `omp --help` for available flags.\n");
        try stderr.flush();
        return .unknown_flags;
    }
    if (parsed.validation_error) |invalid| {
        try stderr.print("Invalid value \"{s}\" for {s}.\n", .{ invalid.value, invalid.flag });
        try stderr.flush();
        return .failure;
    }
    if (parsed.at_file_argument) |file_argument| {
        try stderr.print("File prompt arguments are not available in phase 2: {s}\n", .{file_argument});
        try stderr.flush();
        return .failure;
    }
    return null;
}

fn runParsed(
    allocator: Allocator,
    io: std.Io,
    parsed: args.Parsed,
    stdin_is_tty: bool,
    piped_input: ?[]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    options: RunOptions,
) !u8 {
    const is_print = parsed.print or parsed.mode != null or !stdin_is_tty;
    const resolved_cwd = resolveCwdAlloc(allocator, io, parsed.cwd) catch |err|
        return failError(stderr, "Unable to resolve --cwd", err);
    defer allocator.free(resolved_cwd);
    const cli_model = nonEmpty(parsed.model);

    var path_options = options.path_options;
    if (path_options.environ == null) path_options.environ = options.environ;

    var loaded_settings = settings_module.Settings.load(allocator, io, .{
        .cwd = resolved_cwd,
        .overlays = parsed.configs,
        .path_options = path_options,
        .runtime = .{ .model = cli_model, .thinking = parsed.thinking },
    }) catch |err| return failError(stderr, "Unable to load settings", err);
    defer loaded_settings.deinit();

    const session_result = session_resolver.resolve(
        allocator,
        io,
        parsed,
        resolved_cwd,
        .{ .path_options = path_options },
    ) catch |err| switch (err) {
        error.SessionNotFound => {
            const requested = switch (parsed.resume_session) {
                .value => |value| value,
                else => "",
            };
            try stderr.print("Session \"{s}\" not found.\n", .{requested});
            try stderr.flush();
            return @intFromEnum(ExitCode.failure);
        },
        else => return failError(stderr, "Unable to resolve session", err),
    };
    var manager = switch (session_result) {
        .manager => |value| value,
        .resume_picker_deferred => {
            try stderr.writeAll("No session selected; interactive resume arrives in phase 3.\n");
            try stderr.flush();
            return @intFromEnum(ExitCode.success);
        },
        .cross_project => {
            try stderr.writeAll("Resume cancelled: session is in another project.\n");
            try stderr.flush();
            return @intFromEnum(ExitCode.success);
        },
    };
    defer manager.deinit();

    const persisted_selection = sessionSelections(allocator, &manager) catch |err|
        return failError(stderr, "Unable to read session selections", err);
    const selector = cli_model orelse nonEmpty(persisted_selection.model) orelse
        nonEmpty(loaded_settings.modelRole("default")) orelse {
        try stderr.writeAll("No model configured. Pass --model <provider/id> or set modelRoles.default.\n");
        try stderr.flush();
        return @intFromEnum(ExitCode.failure);
    };
    var selection = model_resolver.Selection.init(allocator, selector) catch |err| switch (err) {
        error.ModelNotFound => {
            try stderr.print("Model \"{s}\" not found.\n", .{selector});
            try stderr.flush();
            return @intFromEnum(ExitCode.failure);
        },
        else => return failError(stderr, "Unable to resolve model", err),
    };
    defer selection.deinit();

    const api_key = model_resolver.resolveApiKeyAlloc(allocator, io, selection.model.provider, .{
        .runtime_key = parsed.api_key,
        .path_options = path_options,
        .environ = options.environ,
    }) catch |err| switch (err) {
        error.ModelsConfigKeyCommandUnsupported => {
            try stderr.writeAll("models.json apiKey commands are not available in phase 2.\n");
            try stderr.flush();
            return @intFromEnum(ExitCode.failure);
        },
        else => return failError(stderr, "Unable to resolve provider key", err),
    };
    defer if (api_key) |key| allocator.free(key);
    if (api_key == null) {
        try stderr.print(
            "No API key available for provider \"{s}\". Pass --api-key or configure {s}.\n",
            .{ selection.model.provider, providerEnvironmentVariable(selection.model.provider) orelse "the provider key" },
        );
        try stderr.flush();
        return @intFromEnum(ExitCode.failure);
    }

    var resolver = model_resolver.ModelResolver.init(
        allocator,
        io,
        selection.model,
        api_key.?,
    ) catch |err| switch (err) {
        error.UnsupportedProviderApi => {
            try stderr.print(
                "Provider \"{s}\" does not support catalog API \"{s}\" in phase 2.\n",
                .{ selection.model.provider, selection.model.api.wireName() },
            );
            try stderr.flush();
            return @intFromEnum(ExitCode.failure);
        },
        else => return failError(stderr, "Unable to construct provider", err),
    };
    defer resolver.deinit();

    const thinking = parsed.thinking orelse selection.thinking orelse
        persisted_selection.thinking orelse loaded_settings.default_thinking_level;
    const exact_model = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ selection.model.provider, selection.model.id },
    );
    defer allocator.free(exact_model);
    if (persisted_selection.model == null or
        !std.mem.eql(u8, persisted_selection.model.?, exact_model))
    {
        _ = manager.appendModelChange(exact_model, "default") catch |err|
            return failError(stderr, "Unable to record model selection", err);
    }
    if (persisted_selection.thinking == null or persisted_selection.thinking.? != thinking) {
        _ = manager.appendThinkingChange(@tagName(thinking)) catch |err|
            return failError(stderr, "Unable to record thinking selection", err);
    }

    const prompt_list = try buildPrompts(allocator, parsed.prompts, piped_input);
    defer {
        for (prompt_list.owned) |text| allocator.free(text);
        allocator.free(prompt_list.prompts);
        allocator.free(prompt_list.owned);
    }
    appendPromptHistoryBestEffort(allocator, io, prompt_list.prompts, path_options);

    const system_prompt = try resolveSystemPrompt(
        allocator,
        io,
        resolved_cwd,
        parsed.system_prompt,
        parsed.append_system_prompt,
    );
    defer allocator.free(system_prompt);

    const active_tools = try resolveActiveTools(allocator, parsed, stderr);
    defer if (active_tools) |names| allocator.free(names);
    var tool_state = tools.SessionState.init(allocator, io, .{
        .cwd = resolved_cwd,
        .home = path_options.home,
        .settings = .{
            .edit_mode = .hashline,
            .read_default_limit = loaded_settings.read_default_limit,
            .has_edit_tool = activeToolEnabled(active_tools, "edit"),
        },
    }) catch |err| return failError(stderr, "Unable to initialize tools", err);
    defer tool_state.deinit();
    var registry = tools.buildDefaultRegistry(allocator, &tool_state) catch |err|
        return failError(stderr, "Unable to initialize tools", err);
    defer registry.deinit();
    var session = agent.AgentSession.init(allocator, io, .{
        .model = resolver.target(),
        .model_role = "default",
        .resolve_model = resolver.seam(),
        .system_prompt = system_prompt,
        .tools = &registry,
        .active_tools = active_tools,
        .thinking = thinking,
        .approval_mode = loaded_settings.approval_mode,
        .retry = .{
            .max_retries = loaded_settings.retry.max_retries,
            .base_delay_ms = loaded_settings.retry.base_delay_ms,
            .max_delay_ms = loaded_settings.retry.max_delay_ms,
        },
        .session_manager = &manager,
        .restore_model_from_session = cli_model == null,
        .restore_thinking_from_session = parsed.thinking == null and
            !(cli_model != null and selection.thinking != null),
    }) catch |err| return failError(stderr, "Unable to initialize agent session", err);
    defer session.deinit();

    if (is_print) {
        const mode: modes.Mode = if (parsed.mode == .json) .json else .text;
        return modes.run(allocator, io, &session, stdout, stderr, .{
            .mode = mode,
            .prompts = prompt_list.prompts,
        }) catch |err| return failError(stderr, "Non-interactive mode failed", err);
    }
    return @import("../tui/tui.zig").run(
        allocator,
        io,
        &session,
        prompt_list.prompts,
        stderr,
    ) catch |err| return failError(stderr, "Interactive mode failed", err);
}

const PromptList = struct {
    prompts: [][]const u8,
    owned: [][]u8,
};

fn buildPrompts(
    allocator: Allocator,
    positional: []const []const u8,
    piped_input: ?[]const u8,
) !PromptList {
    var prompts: std.ArrayList([]const u8) = .empty;
    errdefer prompts.deinit(allocator);
    var owned: std.ArrayList([]u8) = .empty;
    errdefer {
        for (owned.items) |text| allocator.free(text);
        owned.deinit(allocator);
    }
    var positional_start: usize = 0;
    if (piped_input) |stdin_text| {
        const initial = if (positional.len != 0 and positional[0].len != 0)
            try std.mem.concat(allocator, u8, &.{ stdin_text, "\n", positional[0] })
        else
            try allocator.dupe(u8, stdin_text);
        try owned.append(allocator, initial);
        try prompts.append(allocator, initial);
        if (positional.len != 0) positional_start = 1;
    }
    try prompts.appendSlice(allocator, positional[positional_start..]);
    return .{
        .prompts = try prompts.toOwnedSlice(allocator),
        .owned = try owned.toOwnedSlice(allocator),
    };
}

fn appendPromptHistoryBestEffort(
    allocator: Allocator,
    io: std.Io,
    prompts: []const []const u8,
    path_options: session_paths.Options,
) void {
    for (prompts) |prompt| _ = history.append(allocator, io, prompt, path_options) catch {};
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    return if (text.len == 0) null else text;
}

fn resolveCwdAlloc(allocator: Allocator, io: std.Io, argument: ?[]const u8) ![]u8 {
    if (argument) |path| {
        var directory = try std.Io.Dir.cwd().openDir(io, path, .{});
        defer directory.close(io);
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const length = try directory.realPath(io, &buffer);
        return allocator.dupe(u8, buffer[0..length]);
    }
    const sentinel_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(sentinel_path);
    return allocator.dupe(u8, sentinel_path);
}

fn resolveSystemPrompt(
    allocator: Allocator,
    io: std.Io,
    cwd: []const u8,
    base_argument: ?[]const u8,
    appended: ?[]const u8,
) ![]u8 {
    const base = if (base_argument) |argument| blk: {
        const candidate = if (std.fs.path.isAbsolute(argument))
            try std.fs.path.resolve(allocator, &.{argument})
        else
            try std.fs.path.resolve(allocator, &.{ cwd, argument });
        defer allocator.free(candidate);
        break :blk std.Io.Dir.cwd().readFileAlloc(io, candidate, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound,
            error.IsDir,
            error.NotDir,
            error.NameTooLong,
            error.BadPathName,
            => try allocator.dupe(u8, argument),
            else => return err,
        };
    } else try allocator.dupe(u8, "");
    defer allocator.free(base);
    if (appended) |tail| {
        if (base.len == 0) return allocator.dupe(u8, tail);
        return std.mem.concat(allocator, u8, &.{ base, "\n\n", tail });
    }
    return allocator.dupe(u8, base);
}

fn resolveActiveTools(
    allocator: Allocator,
    parsed: args.Parsed,
    stderr: *std.Io.Writer,
) !?[]const []const u8 {
    if (parsed.no_tools) return @as(?[]const []const u8, try allocator.alloc([]const u8, 0));
    const requested = parsed.tools orelse return null;
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(allocator);
    for (requested) |name| {
        if (isBuiltinTool(name)) {
            try names.append(allocator, name);
        } else {
            try stderr.print(
                "Unknown tool passed to --tools: {s} (available: read, bash, edit, write)\n",
                .{name},
            );
        }
    }
    return try names.toOwnedSlice(allocator);
}

fn isBuiltinTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "read") or
        std.mem.eql(u8, name, "bash") or
        std.mem.eql(u8, name, "edit") or
        std.mem.eql(u8, name, "write");
}

fn activeToolEnabled(active: ?[]const []const u8, name: []const u8) bool {
    const names = active orelse return true;
    for (names) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}

const PersistedSelection = struct {
    model: ?[]const u8 = null,
    thinking: ?catalog.ThinkingLevel = null,
};

fn sessionSelections(
    allocator: Allocator,
    manager: *const @import("../session/manager.zig").SessionManager,
) !PersistedSelection {
    const entries = try manager.activePathAlloc(allocator);
    defer allocator.free(entries);
    var result: PersistedSelection = .{};
    for (entries) |entry| switch (entry) {
        .model_change => |change| result.model = change.model,
        .thinking_level_change => |change| {
            const configured = switch (change.configured) {
                .value => |value| value,
                else => switch (change.thinkingLevel) {
                    .value => |value| value,
                    else => null,
                },
            };
            if (configured) |value| result.thinking = std.meta.stringToEnum(catalog.ThinkingLevel, value);
        },
        else => {},
    };
    return result;
}

fn providerEnvironmentVariable(provider_name: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(provider_name, "anthropic")) return "ANTHROPIC_API_KEY";
    if (std.ascii.eqlIgnoreCase(provider_name, "openai")) return "OPENAI_API_KEY";
    if (std.ascii.eqlIgnoreCase(provider_name, "google")) return "GEMINI_API_KEY";
    if (std.ascii.eqlIgnoreCase(provider_name, "openrouter")) return "OPENROUTER_API_KEY";
    if (std.ascii.eqlIgnoreCase(provider_name, "xai")) return "XAI_API_KEY";
    return null;
}

fn readPipedInput(
    allocator: Allocator,
    io: std.Io,
    stdin: std.Io.File,
    stderr: *std.Io.Writer,
) ![]u8 {
    const Notice = struct {
        fn emit(task_io: std.Io, writer: *std.Io.Writer) std.Io.Cancelable!void {
            try task_io.sleep(.fromSeconds(1), .awake);
            writer.writeAll("Reading prompt from piped stdin (waiting for EOF; ctrl+c to abort)…\n") catch return;
            writer.flush() catch return;
        }
    };
    var notice = io.async(Notice.emit, .{ io, stderr });
    defer _ = notice.cancel(io) catch {};
    var buffer: [8192]u8 = undefined;
    var reader = stdin.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(64 * 1024 * 1024));
}

fn failError(stderr: *std.Io.Writer, context: []const u8, err: anyerror) u8 {
    stderr.print("{s}: {s}\n", .{ context, @errorName(err) }) catch {};
    stderr.flush() catch {};
    return @intFromEnum(ExitCode.failure);
}

test "CLI exit-code matrix covers success failure and unknown flags" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    const run_options: RunOptions = .{
        .path_options = .{ .agent_dir = root, .home = root, .temp_dir = "/tmp" },
    };

    var stdout: std.Io.Writer.Allocating = .init(allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();
    try std.testing.expectEqual(@as(u8, 0), try runWithInput(
        allocator,
        io,
        &.{"--version"},
        true,
        null,
        &stdout.writer,
        &stderr.writer,
        run_options,
    ));
    stdout.clearRetainingCapacity();
    stderr.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 0), try runWithInput(
        allocator,
        io,
        &.{ "-p", "--resume" },
        true,
        null,
        &stdout.writer,
        &stderr.writer,
        run_options,
    ));
    try std.testing.expectEqualStrings(
        "No session selected; interactive resume arrives in phase 3.\n",
        stderr.written(),
    );

    stdout.clearRetainingCapacity();
    stderr.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 1), try runWithInput(
        allocator,
        io,
        &.{},
        true,
        null,
        &stdout.writer,
        &stderr.writer,
        run_options,
    ));
    try std.testing.expectEqualStrings(
        "No model configured. Pass --model <provider/id> or set modelRoles.default.\n",
        stderr.written(),
    );

    stdout.clearRetainingCapacity();
    stderr.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 1), try runWithInput(
        allocator,
        io,
        &.{"-p"},
        true,
        null,
        &stdout.writer,
        &stderr.writer,
        run_options,
    ));
    try std.testing.expectEqualStrings(
        "No model configured. Pass --model <provider/id> or set modelRoles.default.\n",
        stderr.written(),
    );

    stdout.clearRetainingCapacity();
    stderr.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 1), try runWithInput(
        allocator,
        io,
        &.{ "-p", "--resume", "missing" },
        true,
        null,
        &stdout.writer,
        &stderr.writer,
        run_options,
    ));
    try std.testing.expectEqualStrings("Session \"missing\" not found.\n", stderr.written());

    stdout.clearRetainingCapacity();
    stderr.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 1), try runWithInput(
        allocator,
        io,
        &.{ "-p", "--model", "anthropic/claude-sonnet-4-6" },
        true,
        null,
        &stdout.writer,
        &stderr.writer,
        run_options,
    ));
    try std.testing.expectEqualStrings(
        "No API key available for provider \"anthropic\". Pass --api-key or configure ANTHROPIC_API_KEY.\n",
        stderr.written(),
    );

    stdout.clearRetainingCapacity();
    stderr.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 2), try runWithInput(
        allocator,
        io,
        &.{ "--future", "--rpc" },
        true,
        null,
        &stdout.writer,
        &stderr.writer,
        run_options,
    ));
    try std.testing.expectEqualStrings(
        "Error: unknown flags: --future, --rpc\nRun `omp --help` for available flags.\n",
        stderr.written(),
    );
}

test "help and version take precedence over argument errors" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var stdout: std.Io.Writer.Allocating = .init(allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();

    try std.testing.expectEqual(@as(u8, 0), try runWithInput(
        allocator,
        io,
        &.{ "--help", "--bogus" },
        true,
        null,
        &stdout.writer,
        &stderr.writer,
        .{},
    ));
    try std.testing.expectEqualStrings(help_text, stdout.written());
    try std.testing.expectEqualStrings("", stderr.written());

    stdout.clearRetainingCapacity();
    stderr.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 0), try runWithInput(
        allocator,
        io,
        &.{ "--version", "--mode=bogus" },
        true,
        null,
        &stdout.writer,
        &stderr.writer,
        .{},
    ));
    try std.testing.expectEqualStrings(build_options.version ++ "\n", stdout.written());
    try std.testing.expectEqualStrings("", stderr.written());

    stdout.clearRetainingCapacity();
    stderr.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 2), try runWithInput(
        allocator,
        io,
        &.{"--bogus"},
        true,
        null,
        &stdout.writer,
        &stderr.writer,
        .{},
    ));

    stdout.clearRetainingCapacity();
    stderr.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 1), try runWithInput(
        allocator,
        io,
        &.{"--mode=bogus"},
        true,
        null,
        &stdout.writer,
        &stderr.writer,
        .{},
    ));
}

test "empty CLI and settings model selectors remain unset" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project/.omp-zig");
    try tmp.dir.writeFile(io, .{
        .sub_path = "project/.omp-zig/config.json",
        .data = "{\"modelRoles\":{\"default\":\"\"}}",
    });
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const project = try std.fs.path.join(allocator, &.{ root, "project" });
    defer allocator.free(project);
    const run_options: RunOptions = .{
        .path_options = .{ .agent_dir = root, .home = root, .temp_dir = "/tmp" },
    };
    var stdout: std.Io.Writer.Allocating = .init(allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();

    try std.testing.expectEqual(@as(u8, 1), try runWithInput(
        allocator,
        io,
        &.{ "-p", "--no-session", "--cwd", project, "--model", "" },
        true,
        null,
        &stdout.writer,
        &stderr.writer,
        run_options,
    ));
    try std.testing.expectEqualStrings(
        "No model configured. Pass --model <provider/id> or set modelRoles.default.\n",
        stderr.written(),
    );

    stdout.clearRetainingCapacity();
    stderr.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 1), try runWithInput(
        allocator,
        io,
        &.{ "-p", "--no-session", "--cwd", project },
        true,
        null,
        &stdout.writer,
        &stderr.writer,
        run_options,
    ));
    try std.testing.expectEqualStrings(
        "No model configured. Pass --model <provider/id> or set modelRoles.default.\n",
        stderr.written(),
    );
}

test "piped input combines with the first positional prompt and leaves later prompts sequential" {
    const result = try buildPrompts(std.testing.allocator, &.{ "first", "second" }, "piped");
    defer {
        for (result.owned) |text| std.testing.allocator.free(text);
        std.testing.allocator.free(result.prompts);
        std.testing.allocator.free(result.owned);
    }
    try std.testing.expectEqual(@as(usize, 2), result.prompts.len);
    try std.testing.expectEqualStrings("piped\nfirst", result.prompts[0]);
    try std.testing.expectEqualStrings("second", result.prompts[1]);
}

test "system prompt accepts a file and appends literal text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "system.md", .data = "base" });
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try tmp.dir.realPath(std.testing.io, &path_buffer)];
    const prompt = try resolveSystemPrompt(
        std.testing.allocator,
        std.testing.io,
        root,
        "system.md",
        "tail",
    );
    defer std.testing.allocator.free(prompt);
    try std.testing.expectEqualStrings("base\n\ntail", prompt);
}

test "system prompt uses a long non-path argument as literal text" {
    const literal = "x" ** 300;
    const prompt = try resolveSystemPrompt(
        std.testing.allocator,
        std.testing.io,
        ".",
        literal,
        null,
    );
    defer std.testing.allocator.free(prompt);
    try std.testing.expectEqualStrings(literal, prompt);
}

test "prompt history failure does not stop prompt preparation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "agent-file", .data = "unchanged" });
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const agent_file = try std.fs.path.join(allocator, &.{ root, "agent-file" });
    defer allocator.free(agent_file);

    appendPromptHistoryBestEffort(allocator, io, &.{"prompt still runs"}, .{
        .agent_dir = agent_file,
        .home = root,
        .temp_dir = "/tmp",
    });

    const bytes = try tmp.dir.readFileAlloc(io, "agent-file", allocator, .unlimited);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("unchanged", bytes);
}
