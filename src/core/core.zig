//! Agent-core data contracts. Loop and mailbox implementations land in later phases.

const std = @import("std");

pub const message = @import("message.zig");
pub const lower = @import("lower.zig");
pub const approval = @import("approval.zig");
pub const events = @import("events.zig");

pub const AgentMessage = message.AgentMessage;
pub const AgentCommand = events.AgentCommand;
pub const AgentEvent = events.AgentEvent;

test {
    std.testing.refAllDecls(@This());
}
