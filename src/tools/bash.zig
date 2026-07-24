//! One-shot non-interactive shell execution for the essential tool registry.

const std = @import("std");
const builtin = @import("builtin");
const approval = @import("../core/approval.zig");
const tool_api = @import("../core/tool.zig");
const output = @import("output.zig");
const session_state = @import("session_state.zig");
const fs_real = @import("fs_real.zig");
const timeouts = @import("timeouts.zig");

const Allocator = std.mem.Allocator;
const SessionState = session_state.SessionState;

pub const description = @embedFile("../prompts/tools/bash.md");
pub const input_schema =
    \\{"type":"object","properties":{"command":{"type":"string","description":"command to execute"},"env":{"type":"object","additionalProperties":{"type":"string"},"description":"extra env vars"},"timeout":{"type":"number","description":"timeout in seconds; clamped to 1-3600"},"cwd":{"type":"string","description":"working directory"}},"required":["command"],"additionalProperties":false}
;

pub const tool: tool_api.Tool = .{
    .name = "bash",
    .description = description,
    .input_schema = input_schema,
    .concurrency = .{ .mode = .shared },
    .interruptible = true,
    .approval = .{ .tier = approval.ToolTier.exec },
    .intent = .{ .mode = .require },
    .vtable = &vtable,
};

const vtable: tool_api.VTable = .{
    .execute = execute,
    .format_approval_details = formatApprovalDetails,
};

const EnvironmentEntry = struct {
    name: []const u8,
    value: []const u8,
};

const ProcessResult = struct {
    term: std.process.Child.Term,
    output_text: []const u8,
    truncated: bool,
    total_lines: usize,
    total_bytes: usize,
    max_front_buffered_bytes: usize,
};

fn execute(
    raw_context: ?*anyopaque,
    io: std.Io,
    arena: Allocator,
    input: std.json.Value,
    on_update: ?tool_api.OnUpdate,
    cancel: *const tool_api.CancelToken,
) anyerror!tool_api.ToolOutcome {
    const state: *SessionState = @ptrCast(@alignCast(raw_context.?));
    const object = if (input == .object) input.object else return errorText(arena, "bash input must be an object");
    const command_value = object.get("command") orelse return errorText(arena, "bash requires a string command");
    if (command_value != .string) return errorText(arena, "bash requires a string command");
    var command = command_value.string;
    if (command.len == 0) return errorText(arena, "bash requires a non-empty command");

    var env_entries: std.ArrayList(EnvironmentEntry) = .empty;
    if (object.get("env")) |env_value| {
        if (env_value != .object) return errorText(arena, "bash env must be an object of string values");
        var iterator = env_value.object.iterator();
        while (iterator.next()) |entry| {
            if (!validEnvName(entry.key_ptr.*)) {
                return errorText(arena, try std.fmt.allocPrint(arena, "Invalid bash env name: {s}", .{entry.key_ptr.*}));
            }
            if (entry.value_ptr.* != .string) return errorText(arena, "bash env values must be strings");
            try env_entries.append(arena, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.string });
        }
    }

    const requested_timeout: ?f64 = if (object.get("timeout")) |value| switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => return errorText(arena, "bash timeout must be a number"),
    } else null;
    const timeout_seconds = timeouts.clampTimeout(.bash, requested_timeout);

    var cwd_value: ?[]const u8 = null;
    if (object.get("cwd")) |value| {
        if (value != .string) return errorText(arena, "bash cwd must be a string");
        cwd_value = value.string;
    } else if (rewriteLeadingCd(command)) |rewrite| {
        cwd_value = rewrite.cwd;
        command = rewrite.command;
    }
    const cwd = if (cwd_value) |path| state.real_fs.resolve(arena, path) catch |err| {
        return errorText(arena, try std.fmt.allocPrint(arena, "Invalid bash cwd '{s}': {s}", .{ path, @errorName(err) }));
    } else state.cwd;
    const cwd_stat = std.Io.Dir.cwd().statFile(io, cwd, .{}) catch |err| {
        return errorText(arena, try std.fmt.allocPrint(arena, "Invalid bash cwd '{s}': {s}", .{ cwd, @errorName(err) }));
    };
    if (cwd_stat.kind != .directory) return errorText(arena, try std.fmt.allocPrint(arena, "Invalid bash cwd '{s}': not a directory", .{cwd}));

    const shell = state.settings.shell orelse defaultShell();
    const script = try buildScript(arena, command, env_entries.items);
    const Context = struct {
        io: std.Io,
        arena: Allocator,
        shell: []const u8,
        script: []const u8,
        cwd: []const u8,
        max_columns: usize,
        on_update: ?tool_api.OnUpdate,

        fn run(self: @This()) anyerror!ProcessResult {
            return runProcess(self.io, self.arena, self.shell, self.script, self.cwd, self.max_columns, self.on_update);
        }
    };
    const process_context: Context = .{
        .io = io,
        .arena = arena,
        .shell = shell,
        .script = script,
        .cwd = cwd,
        .max_columns = state.settings.output_max_columns,
        .on_update = on_update,
    };

    const Race = union(enum) {
        process: anyerror!ProcessResult,
        deadline: std.Io.Cancelable!void,
        cancelled: std.Io.Cancelable!void,
    };
    var race_buffer: [3]Race = undefined;
    var select: std.Io.Select(Race) = .init(io, &race_buffer);
    defer select.cancelDiscard();
    try select.concurrent(.process, Context.run, .{process_context});
    try select.concurrent(.deadline, waitSeconds, .{ io, timeout_seconds });
    try select.concurrent(.cancelled, waitForCancel, .{ io, cancel });

    const selected = try select.await();
    const result = switch (selected) {
        .deadline => |wait| {
            try wait;
            return errorText(arena, try std.fmt.allocPrint(arena, "Command timed out after {d} seconds", .{timeout_seconds}));
        },
        .cancelled => |wait| {
            try wait;
            return error.Canceled;
        },
        .process => |process| process catch |err| {
            if (err == error.Canceled) return error.Canceled;
            return errorText(arena, try std.fmt.allocPrint(arena, "Command failed: {s}", .{@errorName(err)}));
        },
    };

    const exit_code: ?u8 = switch (result.term) {
        .exited => |code| code,
        .signal => |signal| @truncate(128 + @intFromEnum(signal)),
        .stopped, .unknown => null,
    };
    if (exit_code == null) return errorText(arena, "Command failed: missing exit status");
    const base_output = if (result.output_text.len == 0) "(no output)" else result.output_text;
    const failed = exit_code.? != 0;
    const final_text = if (failed)
        try std.fmt.allocPrint(arena, "{s}\n\nCommand exited with code {d}", .{ base_output, exit_code.? })
    else
        base_output;

    var details: std.json.ObjectMap = .empty;
    try details.put(arena, "timeoutSeconds", jsonNumber(timeout_seconds));
    if (requested_timeout) |requested| if (requested != timeout_seconds) {
        try details.put(arena, "requestedTimeoutSeconds", jsonNumber(requested));
    };
    if (failed) try details.put(arena, "exitCode", .{ .integer = exit_code.? });
    if (result.truncated) {
        var truncation: std.json.ObjectMap = .empty;
        try truncation.put(arena, "truncated", .{ .bool = true });
        try truncation.put(arena, "totalLines", .{ .integer = @intCast(result.total_lines) });
        try truncation.put(arena, "totalBytes", .{ .integer = @intCast(result.total_bytes) });
        var meta: std.json.ObjectMap = .empty;
        try meta.put(arena, "truncation", .{ .object = truncation });
        try details.put(arena, "meta", .{ .object = meta });
    }
    return outcome(arena, final_text, .{ .object = details }, failed);
}

fn runProcess(
    io: std.Io,
    arena: Allocator,
    shell: []const u8,
    script: []const u8,
    cwd: []const u8,
    max_columns: usize,
    on_update: ?tool_api.OnUpdate,
) !ProcessResult {
    var child = try std.process.spawn(io, .{
        .argv = &.{ shell, "-c", script },
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = if (builtin.os.tag == .windows or builtin.os.tag == .wasi) null else 0,
    });
    defer killChildTree(io, &child);

    var sink = output.OutputSink.init(arena, .{
        .spill_threshold = output.DEFAULT_TAIL_BYTES,
        .head_bytes = output.DEFAULT_HEAD_BYTES,
        .max_columns = max_columns,
    });
    defer sink.deinit();

    var readers_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var readers: std.Io.File.MultiReader = undefined;
    readers.init(arena, io, readers_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer readers.deinit();
    const stdout_reader = readers.reader(0);
    const stderr_reader = readers.reader(1);
    var max_front_buffered_bytes: usize = 0;
    while (readers.fill(4096, .none)) |_| {
        max_front_buffered_bytes = @max(
            max_front_buffered_bytes,
            stdout_reader.buffered().len + stderr_reader.buffered().len,
        );
        try drainReader(&sink, stdout_reader);
        try drainReader(&sink, stderr_reader);
        try emitUpdate(arena, &sink, on_update);
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |other| return other,
    }
    try readers.checkAnyError();
    max_front_buffered_bytes = @max(
        max_front_buffered_bytes,
        stdout_reader.buffered().len + stderr_reader.buffered().len,
    );
    try drainReader(&sink, stdout_reader);
    try drainReader(&sink, stderr_reader);
    const term = try child.wait(io);
    var summary = try sink.dump(null);
    const text = try arena.dupe(u8, summary.output);
    const result: ProcessResult = .{
        .term = term,
        .output_text = text,
        .truncated = summary.truncated,
        .total_lines = summary.total_lines,
        .total_bytes = summary.total_bytes,
        .max_front_buffered_bytes = max_front_buffered_bytes,
    };
    summary.deinit(arena);
    return result;
}

fn drainReader(sink: *output.OutputSink, reader: *std.Io.Reader) !void {
    const chunk = reader.buffered();
    if (chunk.len == 0) return;
    try sink.push(chunk);
    reader.toss(chunk.len);
}

fn emitUpdate(arena: Allocator, sink: *output.OutputSink, on_update: ?tool_api.OnUpdate) !void {
    const update = on_update orelse return;
    var summary = try sink.dump(null);
    defer summary.deinit(arena);
    const partial = try outcome(arena, summary.output, null, false);
    update(partial);
}

fn waitSeconds(io: std.Io, seconds: f64) std.Io.Cancelable!void {
    const nanoseconds: i96 = @intFromFloat(seconds * @as(f64, std.time.ns_per_s));
    return io.sleep(.fromNanoseconds(nanoseconds), .awake);
}

fn waitForCancel(io: std.Io, cancel: *const tool_api.CancelToken) std.Io.Cancelable!void {
    while (!cancel.isCancelled()) try io.sleep(.fromMilliseconds(10), .awake);
}

fn killChildTree(io: std.Io, child: *std.process.Child) void {
    const id = child.id orelse return;
    if (comptime builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        std.posix.kill(-id, .KILL) catch |err| {
            std.log.debug("process-group cleanup for pid {d} returned {s}", .{ id, @errorName(err) });
        };
    }
    child.kill(io);
}

const CdRewrite = struct {
    cwd: []const u8,
    command: []const u8,
};

fn rewriteLeadingCd(command: []const u8) ?CdRewrite {
    if (!std.mem.startsWith(u8, command, "cd")) return null;
    var index: usize = 2;
    if (index >= command.len or (command[index] != ' ' and command[index] != '\t')) return null;
    while (index < command.len and (command[index] == ' ' or command[index] == '\t')) index += 1;
    const path_start = index;
    var escaped = false;
    var and_index: ?usize = null;
    while (index + 1 < command.len) : (index += 1) {
        const byte = command[index];
        if (byte == '\n' or byte == '\r') return null;
        if (escaped) {
            escaped = false;
            continue;
        }
        if (byte == '\\') {
            escaped = true;
            continue;
        }
        if (byte == '&') {
            if (command[index + 1] != '&') return null;
            and_index = index;
            break;
        }
    }
    const separator = and_index orelse return null;
    var cwd = std.mem.trim(u8, command[path_start..separator], " \t");
    if (std.mem.findAny(u8, cwd, "$`(") != null) return null;
    if (cwd.len > 0 and (cwd[0] == '\'' or cwd[0] == '"')) cwd = cwd[1..];
    if (cwd.len > 0 and (cwd[cwd.len - 1] == '\'' or cwd[cwd.len - 1] == '"')) cwd = cwd[0 .. cwd.len - 1];
    if (cwd.len == 0) return null;
    var command_start = separator + 2;
    while (command_start < command.len and (command[command_start] == ' ' or command[command_start] == '\t')) command_start += 1;
    if (command_start >= command.len) return null;
    return .{ .cwd = cwd, .command = command[command_start..] };
}

fn buildScript(arena: Allocator, command: []const u8, overrides: []const EnvironmentEntry) ![]const u8 {
    const defaults = [_]EnvironmentEntry{
        .{ .name = "PAGER", .value = "cat" },
        .{ .name = "GIT_PAGER", .value = "cat" },
        .{ .name = "MANPAGER", .value = "cat" },
        .{ .name = "SYSTEMD_PAGER", .value = "cat" },
        .{ .name = "BAT_PAGER", .value = "cat" },
        .{ .name = "DELTA_PAGER", .value = "cat" },
        .{ .name = "GH_PAGER", .value = "cat" },
        .{ .name = "GLAB_PAGER", .value = "cat" },
        .{ .name = "PSQL_PAGER", .value = "cat" },
        .{ .name = "MYSQL_PAGER", .value = "cat" },
        .{ .name = "AWS_PAGER", .value = "" },
        .{ .name = "HOMEBREW_PAGER", .value = "cat" },
        .{ .name = "LESS", .value = "FRX" },
        .{ .name = "TERM", .value = "dumb" },
        .{ .name = "NO_COLOR", .value = "1" },
        .{ .name = "PYTHONUNBUFFERED", .value = "1" },
        .{ .name = "GIT_EDITOR", .value = "true" },
        .{ .name = "VISUAL", .value = "true" },
        .{ .name = "EDITOR", .value = "true" },
        .{ .name = "GIT_TERMINAL_PROMPT", .value = "0" },
        .{ .name = "SSH_ASKPASS", .value = "/usr/bin/false" },
        .{ .name = "CI", .value = "1" },
        .{ .name = "npm_config_yes", .value = "true" },
        .{ .name = "npm_config_update_notifier", .value = "false" },
        .{ .name = "npm_config_fund", .value = "false" },
        .{ .name = "npm_config_audit", .value = "false" },
        .{ .name = "npm_config_progress", .value = "false" },
        .{ .name = "PNPM_DISABLE_SELF_UPDATE_CHECK", .value = "true" },
        .{ .name = "PNPM_UPDATE_NOTIFIER", .value = "false" },
        .{ .name = "YARN_ENABLE_TELEMETRY", .value = "0" },
        .{ .name = "YARN_ENABLE_PROGRESS_BARS", .value = "0" },
        .{ .name = "CARGO_TERM_PROGRESS_WHEN", .value = "never" },
        .{ .name = "DEBIAN_FRONTEND", .value = "noninteractive" },
        .{ .name = "PIP_NO_INPUT", .value = "1" },
        .{ .name = "PIP_DISABLE_PIP_VERSION_CHECK", .value = "1" },
        .{ .name = "TF_INPUT", .value = "0" },
        .{ .name = "TF_IN_AUTOMATION", .value = "1" },
        .{ .name = "GH_PROMPT_DISABLED", .value = "1" },
        .{ .name = "COMPOSER_NO_INTERACTION", .value = "1" },
        .{ .name = "CLOUDSDK_CORE_DISABLE_PROMPTS", .value = "1" },
    };
    var script: std.ArrayList(u8) = .empty;
    for (defaults) |entry| if (!hasOverride(overrides, entry.name)) try appendExport(arena, &script, entry);
    for (overrides) |entry| try appendExport(arena, &script, entry);
    try script.appendSlice(arena, "exec 2>&1\n");
    try script.appendSlice(arena, command);
    return script.toOwnedSlice(arena);
}

fn hasOverride(entries: []const EnvironmentEntry, name: []const u8) bool {
    for (entries) |entry| if (std.mem.eql(u8, entry.name, name)) return true;
    return false;
}

fn appendExport(arena: Allocator, script: *std.ArrayList(u8), entry: EnvironmentEntry) !void {
    try script.print(arena, "export {s}=", .{entry.name});
    try appendShellQuoted(arena, script, entry.value);
    try script.append(arena, '\n');
}

fn appendShellQuoted(arena: Allocator, output_text: *std.ArrayList(u8), value: []const u8) !void {
    try output_text.append(arena, '\'');
    for (value) |byte| {
        if (byte == '\'') try output_text.appendSlice(arena, "'\\''") else try output_text.append(arena, byte);
    }
    try output_text.append(arena, '\'');
}

fn validEnvName(name: []const u8) bool {
    if (name.len == 0 or (!std.ascii.isAlphabetic(name[0]) and name[0] != '_')) return false;
    for (name[1..]) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

fn defaultShell() []const u8 {
    if (comptime builtin.link_libc and builtin.os.tag != .windows) {
        if (std.c.getenv("SHELL")) |value| {
            const shell = std.mem.span(value);
            if (shell.len != 0) return shell;
        }
    }
    return if (builtin.os.tag == .windows) "cmd.exe" else "/bin/sh";
}

fn formatApprovalDetails(_: ?*anyopaque, arena: Allocator, input: std.json.Value) anyerror!?[]const u8 {
    const command = if (input == .object and input.object.get("command") != null and input.object.get("command").? == .string)
        input.object.get("command").?.string
    else
        "(missing)";
    return try std.fmt.allocPrint(arena, "Command: {s}", .{command});
}

fn jsonNumber(value: f64) std.json.Value {
    const integer = @trunc(value);
    return if (integer == value and value >= @as(f64, @floatFromInt(std.math.minInt(i64))) and value <= @as(f64, @floatFromInt(std.math.maxInt(i64))))
        .{ .integer = @intFromFloat(value) }
    else
        .{ .float = value };
}

fn errorText(arena: Allocator, text: []const u8) !tool_api.ToolOutcome {
    return outcome(arena, text, null, true);
}

fn outcome(arena: Allocator, text: []const u8, details: ?std.json.Value, is_error: bool) !tool_api.ToolOutcome {
    const content = try arena.alloc(tool_api.ResultBlock, 1);
    content[0] = .{ .text = text };
    return .{ .content = content, .details = details, .is_error = is_error };
}

test "bash validates environment names and rewrites a leading cd" {
    try std.testing.expect(validEnvName("GOOD_name9"));
    try std.testing.expect(!validEnvName("9bad"));
    try std.testing.expect(!validEnvName("also-bad"));
    const rewrite = rewriteLeadingCd("cd 'some dir' && pwd").?;
    try std.testing.expectEqualStrings("some dir", rewrite.cwd);
    try std.testing.expectEqualStrings("pwd", rewrite.command);
    try std.testing.expect(rewriteLeadingCd("cd $HOME && pwd") == null);
}

test "bash executes output failures environment cwd timeout and cancellation" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "child");
    const cwd = try fs_real.dirRealPathAlloc(allocator, io, tmp.dir);
    defer allocator.free(cwd);
    var state = try SessionState.init(allocator, io, .{ .cwd = cwd, .settings = .{ .shell = "/bin/sh" } });
    defer state.deinit();
    var cancelled = std.atomic.Value(bool).init(false);
    var timed_out = std.atomic.Value(bool).init(false);
    const cancel: tool_api.CancelToken = .{ .batch_cancelled = &cancelled, .timed_out = &timed_out };
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const empty_input = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"command\":\"true\"}", .{});
    const empty = try execute(&state, io, arena, empty_input, null, &cancel);
    try std.testing.expectEqualStrings("(no output)", empty.content[0].text);

    const invalid_env_input = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"command\":\"true\",\"env\":{\"9bad\":\"x\"}}", .{});
    const invalid_env = try execute(&state, io, arena, invalid_env_input, null, &cancel);
    try std.testing.expect(invalid_env.is_error);
    try std.testing.expectEqualStrings("Invalid bash env name: 9bad", invalid_env.content[0].text);

    const fail_input = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"command\":\"printf boom; exit 7\"}", .{});
    const failed = try execute(&state, io, arena, fail_input, null, &cancel);
    try std.testing.expect(failed.is_error);
    try std.testing.expectEqualStrings("boom\n\nCommand exited with code 7", failed.content[0].text);
    try std.testing.expectEqual(@as(i64, 7), failed.details.?.object.get("exitCode").?.integer);

    const env_input = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"command\":\"printf \\\"%s\\\" \\\"$SPECIAL\\\"\",\"env\":{\"SPECIAL\":\"a'b\"}}", .{});
    const environment = try execute(&state, io, arena, env_input, null, &cancel);
    try std.testing.expectEqualStrings("a'b", environment.content[0].text);

    const cd_input = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"command\":\"cd child && pwd\"}", .{});
    const changed = try execute(&state, io, arena, cd_input, null, &cancel);
    const child_path = try std.fs.path.join(arena, &.{ cwd, "child" });
    try std.testing.expectEqualStrings(child_path, std.mem.trimEnd(u8, changed.content[0].text, "\r\n"));

    const timeout_input = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"command\":\"sleep 2\",\"timeout\":1}", .{});
    const timeout = try execute(&state, io, arena, timeout_input, null, &cancel);
    try std.testing.expect(timeout.is_error);
    try std.testing.expectEqualStrings("Command timed out after 1 seconds", timeout.content[0].text);

    cancelled.store(true, .release);
    try std.testing.expectError(error.Canceled, execute(&state, io, arena, empty_input, null, &cancel));
}

test "bash drains process readers while retaining bounded large output" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try fs_real.dirRealPathAlloc(allocator, io, tmp.dir);
    defer allocator.free(cwd);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const result = try runProcess(
        io,
        arena_state.allocator(),
        "/bin/sh",
        "yes 0123456789abcdef0123456789abcdef | head -c 1048576; printf '\\nTAIL-MARKER\\n'",
        cwd,
        0,
        null,
    );
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.total_bytes > 1024 * 1024);
    try std.testing.expect(result.truncated);
    try std.testing.expect(result.output_text.len <= output.DEFAULT_HEAD_BYTES + output.DEFAULT_TAIL_BYTES + 128);
    try std.testing.expect(std.mem.indexOf(u8, result.output_text, "TAIL-MARKER") != null);
    try std.testing.expect(result.max_front_buffered_bytes <= 64 * 1024);
}
