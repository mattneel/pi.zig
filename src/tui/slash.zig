//! Slash-command names and submission classification for the interactive TUI.

const std = @import("std");

pub const ArgKind = enum {
    none,
    model,
    thinking,
    file,
};

pub const Command = struct {
    name: []const u8,
    summary: []const u8,
    consumes_args: bool,
    arg_kind: ArgKind,
};

pub const commands = [_]Command{
    .{ .name = "/help", .summary = "List composer commands", .consumes_args = false, .arg_kind = .none },
    .{ .name = "/model", .summary = "Change the active model", .consumes_args = true, .arg_kind = .model },
    .{ .name = "/thinking", .summary = "Change the thinking level", .consumes_args = true, .arg_kind = .thinking },
    .{ .name = "/compact", .summary = "Compact the current session", .consumes_args = false, .arg_kind = .none },
    .{ .name = "/retry", .summary = "Retry the last turn", .consumes_args = false, .arg_kind = .none },
    .{ .name = "/clear", .summary = "Clear the on-screen transcript", .consumes_args = false, .arg_kind = .none },
    .{ .name = "/exit", .summary = "Exit the interactive session", .consumes_args = false, .arg_kind = .none },
    .{ .name = "/login", .summary = "Sign in with OAuth", .consumes_args = false, .arg_kind = .none },
};

const Alias = struct {
    name: []const u8,
    command_index: usize,
};

const aliases = [_]Alias{
    .{ .name = "/quit", .command_index = 6 },
};

pub const Match = struct {
    command: *const Command,
    typed_name: []const u8,
    args: []const u8,
    used_prefix: bool,
};

pub const Unknown = struct {
    typed_name: []const u8,
    args: []const u8,
};

pub const ParseResult = union(enum) {
    not_command,
    bare,
    command: Match,
    unknown: Unknown,
};

pub fn parse(line: []const u8) ParseResult {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '/') return .not_command;

    const name_end = std.mem.indexOfAny(u8, trimmed, " \t\r\n") orelse trimmed.len;
    const typed = trimmed[0..name_end];
    const args = std.mem.trim(u8, trimmed[name_end..], " \t\r\n");
    if (typed.len == 1) return .bare;

    if (findExact(typed)) |command| {
        return .{ .command = .{
            .command = command,
            .typed_name = typed[1..],
            .args = args,
            .used_prefix = !std.ascii.eqlIgnoreCase(typed, command.name),
        } };
    }

    if (findUniquePrefix(typed)) |command| {
        return .{ .command = .{
            .command = command,
            .typed_name = typed[1..],
            .args = args,
            .used_prefix = true,
        } };
    }

    return .{ .unknown = .{ .typed_name = typed[1..], .args = args } };
}

pub fn findExact(name: []const u8) ?*const Command {
    for (&commands) |*command| {
        if (std.ascii.eqlIgnoreCase(name, command.name)) return command;
    }
    for (aliases) |alias| {
        if (std.ascii.eqlIgnoreCase(name, alias.name)) return &commands[alias.command_index];
    }
    return null;
}

fn findUniquePrefix(name: []const u8) ?*const Command {
    var match: ?*const Command = null;
    for (&commands) |*command| {
        if (!startsWithIgnoreCase(command.name, name)) continue;
        if (match != null and match.? != command) return null;
        match = command;
    }
    for (aliases) |alias| {
        if (!startsWithIgnoreCase(alias.name, name)) continue;
        const command = &commands[alias.command_index];
        if (match != null and match.? != command) return null;
        match = command;
    }
    return match;
}

fn startsWithIgnoreCase(candidate: []const u8, prefix: []const u8) bool {
    return prefix.len <= candidate.len and std.ascii.eqlIgnoreCase(candidate[0..prefix.len], prefix);
}

test "slash parser classifies commands aliases prefixes and unknown names" {
    const model = parse("/model gpt").command;
    try std.testing.expectEqualStrings("/model", model.command.name);
    try std.testing.expectEqualStrings("gpt", model.args);
    try std.testing.expect(!model.used_prefix);

    const thinking = parse("/thinking max").command;
    try std.testing.expectEqualStrings("/thinking", thinking.command.name);
    try std.testing.expectEqualStrings("max", thinking.args);

    const help = parse("/help").command;
    try std.testing.expectEqualStrings("/help", help.command.name);
    try std.testing.expectEqualStrings("", help.args);

    const quit = parse("/quit").command;
    try std.testing.expectEqualStrings("/exit", quit.command.name);
    try std.testing.expectEqualStrings("quit", quit.typed_name);

    const unknown = parse("/nope").unknown;
    try std.testing.expectEqualStrings("nope", unknown.typed_name);

    const prefix = parse("/mod").command;
    try std.testing.expectEqualStrings("/model", prefix.command.name);
    try std.testing.expect(prefix.used_prefix);

    try std.testing.expect(parse("/") == .bare);
}
