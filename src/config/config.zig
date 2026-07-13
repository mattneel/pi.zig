//! Application settings surfaces.

const std = @import("std");

pub const settings = @import("settings.zig");
pub const Settings = settings.Settings;

test {
    std.testing.refAllDecls(@This());
}
