//! Session wire types. Storage and session management arrive in Phase 2.

const std = @import("std");

pub const entries = @import("entries.zig");

pub const CURRENT_SESSION_VERSION = entries.CURRENT_SESSION_VERSION;
pub const SESSION_TITLE_SLOT_BYTES = entries.SESSION_TITLE_SLOT_BYTES;
pub const SessionEntry = entries.SessionEntry;
pub const SessionHeader = entries.SessionHeader;
pub const SessionTitleSlotEntry = entries.SessionTitleSlotEntry;

test {
    std.testing.refAllDecls(@This());
}
