//! Test helper that continuously appends session entries until terminated.

const std = @import("std");
const manager = @import("session/manager.zig");
const message = @import("core/message.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.InvalidArguments;
    const session_path = args[1];
    const agent_root = args[2];
    var session = try manager.SessionManager.open(init.gpa, init.io, session_path, .{
        .path_options = .{
            .agent_dir = agent_root,
            .home = agent_root,
            .temp_dir = "/tmp",
            .environ = init.minimal.environ,
        },
    });
    defer session.deinit();
    _ = try session.appendMessage(.{ .user = .{
        .content = .{ .string = "durability start" },
        .timestamp = 1,
    } });
    _ = try session.appendMessage(.{ .assistant = .{
        .content = &.{.{ .text = .{ .text = "started" } }},
        .api = "anthropic-messages",
        .provider = "anthropic",
        .model = "claude-haiku",
        .usage = .{ .input = 1, .output = 1 },
        .stop_reason = .stop,
        .timestamp = 2,
    } });

    const payload = try init.gpa.alloc(u8, 64 * 1024);
    defer init.gpa.free(payload);
    @memset(payload, 'p');
    var timestamp: i64 = 3;
    while (true) : (timestamp += 1) {
        _ = try session.appendMessage(.{ .user = .{
            .content = .{ .string = payload },
            .timestamp = timestamp,
        } });
    }
}

test {
    _ = message.AgentMessage;
}
