//! Session wire types, paths, persistence, and management.

const std = @import("std");

pub const entries = @import("entries.zig");
pub const manager = @import("manager.zig");
pub const paths = @import("paths.zig");

pub const CURRENT_SESSION_VERSION = entries.CURRENT_SESSION_VERSION;
pub const SESSION_TITLE_SLOT_BYTES = entries.SESSION_TITLE_SLOT_BYTES;
pub const SessionEntry = entries.SessionEntry;
pub const SessionHeader = entries.SessionHeader;
pub const SessionTitleSlotEntry = entries.SessionTitleSlotEntry;
pub const SessionManager = manager.SessionManager;

test {
    std.testing.refAllDecls(@This());
}
