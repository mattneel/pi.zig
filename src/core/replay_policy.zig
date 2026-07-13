//! Provider-refusal replay filtering.
//!
//! Provider refusals are identified on session messages before lowering so
//! stop reason and stop details remain available to the predicate.

const std = @import("std");
const ai = @import("ai");
const lower = @import("lower.zig");
const message = @import("message.zig");

const Allocator = std.mem.Allocator;

pub fn filterProviderReplayMessages(
    arena: Allocator,
    source: []const message.AgentMessage,
    options: lower.Options,
) ![]const ai.ModelMessage {
    var kept: std.ArrayList(message.AgentMessage) = .empty;
    defer kept.deinit(arena);
    for (source) |candidate| {
        if (isProviderRefusal(candidate)) continue;
        try kept.append(arena, candidate);
    }
    return lower.toModelMessages(arena, kept.items, options);
}

pub fn isProviderRefusal(value: message.AgentMessage) bool {
    if (value != .assistant or value.assistant.stop_reason != .@"error") return false;
    const details = value.assistant.stop_details orelse return false;
    if (details != .object) return false;
    const kind = details.object.get("type") orelse return false;
    if (kind != .string) return false;
    return std.mem.eql(u8, kind.string, "refusal") or std.mem.eql(u8, kind.string, "sensitive");
}

test "replay policy removes refusal only after lowering" {
    var source_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer source_arena_state.deinit();
    const source_arena = source_arena_state.allocator();
    const details = try std.json.parseFromSliceLeaky(std.json.Value, source_arena, "{\"type\":\"refusal\"}", .{});
    const source = [_]message.AgentMessage{
        .{ .user = .{ .content = .{ .string = "first" }, .timestamp = 1 } },
        .{ .assistant = .{
            .content = &.{.{ .text = .{ .text = "refused" } }},
            .api = "anthropic-messages",
            .provider = "anthropic",
            .model = "claude",
            .usage = .{},
            .stop_reason = .@"error",
            .stop_details = details,
            .timestamp = 2,
        } },
        .{ .user = .{ .content = .{ .string = "second" }, .timestamp = 3 } },
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const filtered = try filterProviderReplayMessages(arena, &source, .{});
    try std.testing.expectEqual(@as(usize, 2), filtered.len);
    try std.testing.expect(filtered[0] == .user and filtered[1] == .user);
}

test "replay policy keeps ordinary assistant content identical to a refusal" {
    var source_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer source_arena_state.deinit();
    const source_arena = source_arena_state.allocator();
    const details = try std.json.parseFromSliceLeaky(std.json.Value, source_arena, "{\"type\":\"refusal\"}", .{});
    const refusal: message.AssistantMessage = .{
        .content = &.{.{ .text = .{ .text = "same bytes" } }},
        .api = "anthropic-messages",
        .provider = "anthropic",
        .model = "claude",
        .usage = .{},
        .stop_reason = .@"error",
        .stop_details = details,
        .timestamp = 1,
    };
    var ordinary = refusal;
    ordinary.stop_reason = .stop;
    ordinary.stop_details = null;
    ordinary.timestamp = 2;
    const source = [_]message.AgentMessage{
        .{ .assistant = refusal },
        .{ .assistant = ordinary },
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const filtered = try filterProviderReplayMessages(arena_state.allocator(), &source, .{});
    try std.testing.expectEqual(@as(usize, 1), filtered.len);
    try std.testing.expect(filtered[0] == .assistant);
    try std.testing.expectEqualStrings("same bytes", filtered[0].assistant.content.parts[0].text.text);
}
