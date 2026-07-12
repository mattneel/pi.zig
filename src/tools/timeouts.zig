//! Per-tool timeout defaults and clamps, in seconds.

const std = @import("std");

pub const Tool = enum {
    bash,
    eval,
    browser,
    ssh,
    fetch,
    lsp,
    debug,
};

pub const ToolWithTimeout = Tool;

pub const Config = struct {
    default: f64,
    min: f64,
    max: f64,
};

pub const ToolTimeoutConfig = Config;

pub const TOOL_TIMEOUTS = std.EnumArray(Tool, Config).init(.{
    .bash = .{ .default = 300, .min = 1, .max = 3600 },
    .eval = .{ .default = 30, .min = 1, .max = 3600 },
    .browser = .{ .default = 30, .min = 1, .max = 300 },
    .ssh = .{ .default = 60, .min = 1, .max = 3600 },
    .fetch = .{ .default = 20, .min = 1, .max = 45 },
    .lsp = .{ .default = 20, .min = 5, .max = 60 },
    .debug = .{ .default = 30, .min = 5, .max = 300 },
});

/// Use the default when `raw_timeout` is absent, then clamp inclusively.
pub fn clampTimeout(tool: Tool, raw_timeout: ?f64) f64 {
    const config = TOOL_TIMEOUTS.get(tool);
    return @max(config.min, @min(config.max, raw_timeout orelse config.default));
}

test "timeout exact upstream clamp table" {
    const expected = [_]struct { tool: Tool, config: Config }{
        .{ .tool = .bash, .config = .{ .default = 300, .min = 1, .max = 3600 } },
        .{ .tool = .eval, .config = .{ .default = 30, .min = 1, .max = 3600 } },
        .{ .tool = .browser, .config = .{ .default = 30, .min = 1, .max = 300 } },
        .{ .tool = .ssh, .config = .{ .default = 60, .min = 1, .max = 3600 } },
        .{ .tool = .fetch, .config = .{ .default = 20, .min = 1, .max = 45 } },
        .{ .tool = .lsp, .config = .{ .default = 20, .min = 5, .max = 60 } },
        .{ .tool = .debug, .config = .{ .default = 30, .min = 5, .max = 300 } },
    };

    for (expected) |entry| {
        try std.testing.expectEqual(entry.config, TOOL_TIMEOUTS.get(entry.tool));
        try std.testing.expectEqual(entry.config.default, clampTimeout(entry.tool, null));
        try std.testing.expectEqual(entry.config.min, clampTimeout(entry.tool, 0));
        try std.testing.expectEqual(entry.config.max, clampTimeout(entry.tool, std.math.inf(f64)));
        try std.testing.expectEqual(entry.config.min, clampTimeout(entry.tool, entry.config.min));
        try std.testing.expectEqual(entry.config.max, clampTimeout(entry.tool, entry.config.max));
    }
    try std.testing.expectEqual(@as(f64, 30.25), clampTimeout(.eval, 30.25));
}
