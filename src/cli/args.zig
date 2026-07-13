//! Phase-2 launch argument parsing.
//!
//! Returned slices borrow `argv`; collection storage belongs to the allocator
//! passed to `parse`. Callers normally use a step or process arena.

const std = @import("std");
const catalog = @import("../catalog/types.zig");

const Allocator = std.mem.Allocator;

pub const Mode = enum {
    text,
    json,
};

pub const Resume = union(enum) {
    none,
    bare,
    value: []const u8,
};

pub const ValidationError = struct {
    flag: []const u8,
    value: []const u8,
};

pub const Parsed = struct {
    cwd: ?[]const u8 = null,
    model: ?[]const u8 = null,
    thinking: ?catalog.ThinkingLevel = null,
    print: bool = false,
    mode: ?Mode = null,
    resume_session: Resume = .none,
    continue_recent: bool = false,
    no_session: bool = false,
    session_dir: ?[]const u8 = null,
    configs: []const []const u8 = &.{},
    api_key: ?[]const u8 = null,
    tools: ?[]const []const u8 = null,
    no_tools: bool = false,
    system_prompt: ?[]const u8 = null,
    append_system_prompt: ?[]const u8 = null,
    version: bool = false,
    help: bool = false,
    prompts: []const []const u8 = &.{},
    unknown_flags: []const []const u8 = &.{},
    validation_error: ?ValidationError = null,
    at_file_argument: ?[]const u8 = null,

    pub fn deinit(self: *Parsed, allocator: Allocator) void {
        allocator.free(self.configs);
        allocator.free(self.prompts);
        allocator.free(self.unknown_flags);
        if (self.tools) |names| allocator.free(names);
        self.* = undefined;
    }
};

/// Parse launch arguments without mutating the caller's argv. `argv` excludes
/// the executable name.
pub fn parse(allocator: Allocator, argv: []const []const u8) !Parsed {
    var result: Parsed = .{};
    var configs: std.ArrayList([]const u8) = .empty;
    var prompts: std.ArrayList([]const u8) = .empty;
    var unknown: std.ArrayList([]const u8) = .empty;
    var parsed_tools: std.ArrayList([]const u8) = .empty;

    var index: usize = 0;
    var positional_only = false;
    while (index < argv.len) : (index += 1) {
        const raw = argv[index];
        if (positional_only) {
            try prompts.append(allocator, raw);
            continue;
        }

        var flag = raw;
        var inline_value: ?[]const u8 = null;
        if (std.mem.startsWith(u8, raw, "--")) {
            if (std.mem.indexOfScalar(u8, raw, '=')) |equals| {
                flag = raw[0..equals];
                inline_value = raw[equals + 1 ..];
            }
        }

        if (isStringFlag(flag)) {
            const value = inline_value orelse blk: {
                if (index + 1 >= argv.len) break :blk null;
                index += 1;
                break :blk argv[index];
            };
            if (value) |text| {
                try setStringFlag(allocator, &result, &configs, &parsed_tools, flag, text);
            } else if (result.validation_error == null) {
                result.validation_error = .{ .flag = flag, .value = "" };
            }
            continue;
        }

        if (isResumeFlag(flag)) {
            if (inline_value) |text| {
                result.resume_session = if (text.len == 0) .bare else .{ .value = text };
            } else if (index + 1 < argv.len and !std.mem.startsWith(u8, argv[index + 1], "-") and
                argv[index + 1].len != 0)
            {
                index += 1;
                result.resume_session = .{ .value = argv[index] };
            } else {
                result.resume_session = .bare;
            }
            continue;
        }

        if (std.mem.eql(u8, flag, "--help") or std.mem.eql(u8, flag, "-h")) {
            result.help = true;
        } else if (std.mem.eql(u8, flag, "--version") or std.mem.eql(u8, flag, "-v")) {
            result.version = true;
        } else if (std.mem.eql(u8, flag, "--continue") or std.mem.eql(u8, flag, "-c")) {
            result.continue_recent = true;
        } else if (std.mem.eql(u8, flag, "--no-session")) {
            result.no_session = true;
        } else if (std.mem.eql(u8, flag, "--no-tools")) {
            result.no_tools = true;
        } else if (std.mem.eql(u8, flag, "--print") or std.mem.eql(u8, flag, "-p")) {
            result.print = true;
        } else if (std.mem.eql(u8, raw, "--")) {
            positional_only = true;
        } else if (raw.len != 0 and raw[0] == '@') {
            if (result.at_file_argument == null) result.at_file_argument = raw;
        } else if (!std.mem.startsWith(u8, raw, "-") or std.mem.eql(u8, raw, "-")) {
            try prompts.append(allocator, raw);
        } else {
            try unknown.append(allocator, flag);
        }
        // An equals value attached to a boolean or unknown flag is discarded,
        // matching the splice-and-drop behavior of the upstream parser.
    }

    result.configs = try configs.toOwnedSlice(allocator);
    result.prompts = try prompts.toOwnedSlice(allocator);
    result.unknown_flags = try unknown.toOwnedSlice(allocator);
    if (result.tools != null) result.tools = try parsed_tools.toOwnedSlice(allocator);
    return result;
}

fn isStringFlag(flag: []const u8) bool {
    return std.mem.eql(u8, flag, "--cwd") or
        std.mem.eql(u8, flag, "--model") or
        std.mem.eql(u8, flag, "--thinking") or
        std.mem.eql(u8, flag, "--mode") or
        std.mem.eql(u8, flag, "--session-dir") or
        std.mem.eql(u8, flag, "--config") or
        std.mem.eql(u8, flag, "--api-key") or
        std.mem.eql(u8, flag, "--tools") or
        std.mem.eql(u8, flag, "--system-prompt") or
        std.mem.eql(u8, flag, "--append-system-prompt");
}

fn isResumeFlag(flag: []const u8) bool {
    return std.mem.eql(u8, flag, "--resume") or std.mem.eql(u8, flag, "-r");
}

fn setStringFlag(
    allocator: Allocator,
    result: *Parsed,
    configs: *std.ArrayList([]const u8),
    parsed_tools: *std.ArrayList([]const u8),
    flag: []const u8,
    value: []const u8,
) !void {
    if (std.mem.eql(u8, flag, "--cwd")) {
        result.cwd = value;
    } else if (std.mem.eql(u8, flag, "--model")) {
        result.model = value;
    } else if (std.mem.eql(u8, flag, "--thinking")) {
        result.thinking = std.meta.stringToEnum(catalog.ThinkingLevel, value) orelse {
            if (result.validation_error == null) result.validation_error = .{ .flag = flag, .value = value };
            return;
        };
    } else if (std.mem.eql(u8, flag, "--mode")) {
        result.mode = std.meta.stringToEnum(Mode, value) orelse {
            if (result.validation_error == null) result.validation_error = .{ .flag = flag, .value = value };
            return;
        };
    } else if (std.mem.eql(u8, flag, "--session-dir")) {
        result.session_dir = value;
    } else if (std.mem.eql(u8, flag, "--config")) {
        try configs.append(allocator, value);
    } else if (std.mem.eql(u8, flag, "--api-key")) {
        result.api_key = value;
    } else if (std.mem.eql(u8, flag, "--tools")) {
        parsed_tools.clearRetainingCapacity();
        var names = std.mem.splitScalar(u8, value, ',');
        while (names.next()) |raw_name| {
            const name = std.mem.trim(u8, raw_name, " \t\r\n");
            if (name.len != 0) try parsed_tools.append(allocator, name);
        }
        result.tools = &.{};
    } else if (std.mem.eql(u8, flag, "--system-prompt")) {
        result.system_prompt = value;
    } else if (std.mem.eql(u8, flag, "--append-system-prompt")) {
        result.append_system_prompt = value;
    }
}

test "CLI parser handles the phase two flag table" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const parsed = try parse(arena_state.allocator(), &.{
        "--cwd",        "/work",           "--model=anthropic/claude:high", "--thinking",             "low",
        "-p",           "--mode=json",     "--resume",                      "abc",                    "-c",
        "--no-session", "--session-dir",   "/sessions",                     "--config=a.json",        "--config",
        "b.json",       "--api-key",       "dummy",                         "--tools",                "read, bash",
        "--no-tools",   "--system-prompt", "system",                        "--append-system-prompt", "tail",
        "hello",
    });
    try std.testing.expectEqualStrings("/work", parsed.cwd.?);
    try std.testing.expectEqualStrings("anthropic/claude:high", parsed.model.?);
    try std.testing.expectEqual(catalog.ThinkingLevel.low, parsed.thinking.?);
    try std.testing.expect(parsed.print);
    try std.testing.expectEqual(Mode.json, parsed.mode.?);
    try std.testing.expectEqualStrings("abc", parsed.resume_session.value);
    try std.testing.expect(parsed.continue_recent and parsed.no_session and parsed.no_tools);
    try expectStrings(&.{ "a.json", "b.json" }, parsed.configs);
    try expectStrings(&.{ "read", "bash" }, parsed.tools.?);
    try expectStrings(&.{"hello"}, parsed.prompts);
}

test "CLI parser splits equals ends options and keeps free text as sequential prompts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const parsed = try parse(arena_state.allocator(), &.{
        "--print=discarded", "first", "--", "--not-a-flag", "@literal", "-",
    });
    try std.testing.expect(parsed.print);
    try expectStrings(
        &.{ "first", "--not-a-flag", "@literal", "-" },
        parsed.prompts,
    );
    try std.testing.expectEqual(@as(usize, 0), parsed.unknown_flags.len);
}

test "CLI parser records unknown flags and deferred file arguments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const parsed = try parse(arena_state.allocator(), &.{ "--rpc", "-x", "--future=value", "@notes.md" });
    try expectStrings(&.{ "--rpc", "-x", "--future" }, parsed.unknown_flags);
    try std.testing.expectEqualStrings("@notes.md", parsed.at_file_argument.?);
}

test "CLI parser keeps bare resume and reports invalid enum values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const bare = try parse(arena_state.allocator(), &.{ "--resume", "--mode", "rpc" });
    try std.testing.expect(bare.resume_session == .bare);
    try std.testing.expectEqualStrings("--mode", bare.validation_error.?.flag);
    try std.testing.expectEqualStrings("rpc", bare.validation_error.?.value);
}

test "CLI parser reports a missing required flag value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const parsed = try parse(arena_state.allocator(), &.{"--model"});
    try std.testing.expectEqualStrings("--model", parsed.validation_error.?.flag);
    try std.testing.expectEqualStrings("", parsed.validation_error.?.value);
}

fn expectStrings(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |left, right| try std.testing.expectEqualStrings(left, right);
}
