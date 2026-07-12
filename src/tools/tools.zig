//! Phases 1 and 5: Tool registry and coding-tool implementations.

const std = @import("std");

pub const output = @import("output.zig");
pub const timeouts = @import("timeouts.zig");

test {
    std.testing.refAllDecls(@This());
}
