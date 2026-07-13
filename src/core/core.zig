//! Agent-core contracts and the library-only execution engine.

const std = @import("std");

pub const message = @import("message.zig");
pub const lower = @import("lower.zig");
pub const approval = @import("approval.zig");
pub const events = @import("events.zig");
pub const tool = @import("tool.zig");
pub const mailbox = @import("mailbox.zig");
pub const raise = @import("raise.zig");
pub const scheduler = @import("scheduler.zig");
pub const loop = @import("loop.zig");
pub const replay_policy = @import("replay_policy.zig");
pub const agent = @import("agent.zig");

pub const AgentSession = agent.AgentSession;

pub const AgentMessage = message.AgentMessage;
pub const AgentCommand = events.AgentCommand;
pub const AgentEvent = events.AgentEvent;

test {
    std.testing.refAllDecls(@This());
}
