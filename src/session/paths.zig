//! Session-root resolution and upstream-compatible cwd bucket encoding.

const builtin = @import("builtin");
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// Explicit agent root. When absent, `OMP_ZIG_AGENT_DIR` is consulted.
    agent_dir: ?[]const u8 = null,
    home: ?[]const u8 = null,
    temp_dir: ?[]const u8 = null,
    environ: ?std.process.Environ = null,
};

pub fn defaultEnvironment() ?std.process.Environ {
    if (builtin.is_test) return std.testing.environ;
    return null;
}

pub fn agentDirAlloc(allocator: Allocator, options: Options) ![]u8 {
    if (options.agent_dir) |value| return std.fs.path.resolve(allocator, &.{value});

    const environ = options.environ orelse defaultEnvironment();
    if (try envValueAlloc(allocator, environ, "OMP_ZIG_AGENT_DIR")) |value| {
        defer allocator.free(value);
        if (value.len != 0) return std.fs.path.resolve(allocator, &.{value});
    }

    const home = if (options.home) |value|
        try allocator.dupe(u8, value)
    else
        (try envValueAlloc(allocator, environ, "HOME")) orelse return error.HomeDirectoryUnavailable;
    defer allocator.free(home);
    return std.fs.path.resolve(allocator, &.{ home, ".omp-zig", "agent" });
}

pub fn sessionsRootAlloc(allocator: Allocator, options: Options) ![]u8 {
    const agent_dir = try agentDirAlloc(allocator, options);
    defer allocator.free(agent_dir);
    return std.fs.path.join(allocator, &.{ agent_dir, "sessions" });
}

pub fn blobsDirAlloc(allocator: Allocator, options: Options) ![]u8 {
    const agent_dir = try agentDirAlloc(allocator, options);
    defer allocator.free(agent_dir);
    return std.fs.path.join(allocator, &.{ agent_dir, "blobs" });
}

pub fn defaultSessionDirAlloc(
    allocator: Allocator,
    io: std.Io,
    cwd: []const u8,
    options: Options,
) ![]u8 {
    const sessions_root = try sessionsRootAlloc(allocator, options);
    defer allocator.free(sessions_root);
    const encoded = try encodeCwdAlloc(allocator, io, cwd, options);
    defer allocator.free(encoded);
    return std.fs.path.join(allocator, &.{ sessions_root, encoded });
}

/// Encode a cwd using `session-paths.ts`: home-relative `-*`, temp-relative
/// `-tmp-*`, and legacy absolute `--*--` buckets.
pub fn encodeCwdAlloc(
    allocator: Allocator,
    io: std.Io,
    cwd: []const u8,
    options: Options,
) ![]u8 {
    const resolved_cwd = try canonicalPathAlloc(allocator, io, cwd);
    defer allocator.free(resolved_cwd);

    const environ = options.environ orelse defaultEnvironment();
    const home_raw = if (options.home) |value|
        try allocator.dupe(u8, value)
    else
        (try envValueAlloc(allocator, environ, "HOME")) orelse return error.HomeDirectoryUnavailable;
    defer allocator.free(home_raw);
    const home = try canonicalPathAlloc(allocator, io, home_raw);
    defer allocator.free(home);

    const temp_raw = if (options.temp_dir) |value|
        try allocator.dupe(u8, value)
    else
        (try envValueAlloc(allocator, environ, "TMPDIR")) orelse try allocator.dupe(u8, "/tmp");
    defer allocator.free(temp_raw);
    const temp_root = try canonicalPathAlloc(allocator, io, temp_raw);
    defer allocator.free(temp_root);

    const home_relative = try std.fs.path.relative(
        allocator,
        home,
        null,
        home,
        resolved_cwd,
    );
    defer allocator.free(home_relative);
    if (isContainedRelative(home_relative)) return encodeRelativeAlloc(allocator, "-", home_relative);

    const temp_relative = try std.fs.path.relative(
        allocator,
        temp_root,
        null,
        temp_root,
        resolved_cwd,
    );
    defer allocator.free(temp_relative);
    if (isContainedRelative(temp_relative)) return encodeRelativeAlloc(allocator, "-tmp", temp_relative);

    const root_length: usize = if (resolved_cwd.len != 0 and std.fs.path.isSep(resolved_cwd[0])) 1 else 0;
    const without_root = resolved_cwd[root_length..];
    const encoded = try replaceSeparatorsAlloc(allocator, without_root);
    defer allocator.free(encoded);
    return std.fmt.allocPrint(allocator, "--{s}--", .{encoded});
}

pub fn fileSafeTimestampAlloc(allocator: Allocator, iso: []const u8) ![]u8 {
    const result = try allocator.dupe(u8, iso);
    for (result) |*byte| if (byte.* == ':' or byte.* == '.') {
        byte.* = '-';
    };
    return result;
}

fn envValueAlloc(
    allocator: Allocator,
    environ: ?std.process.Environ,
    name: []const u8,
) !?[]u8 {
    const source = environ orelse return null;
    return std.process.Environ.getAlloc(source, allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => return err,
    };
}

fn canonicalPathAlloc(allocator: Allocator, io: std.Io, input: []const u8) ![]u8 {
    const resolved = try std.fs.path.resolve(allocator, &.{input});
    errdefer allocator.free(resolved);
    var dir = std.Io.Dir.openDirAbsolute(io, resolved, .{}) catch return resolved;
    defer dir.close(io);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = dir.realPath(io, &buffer) catch return resolved;
    allocator.free(resolved);
    return allocator.dupe(u8, buffer[0..length]);
}

fn isContainedRelative(relative: []const u8) bool {
    return !std.fs.path.isAbsolute(relative) and
        !std.mem.startsWith(u8, relative, "..");
}

fn encodeRelativeAlloc(allocator: Allocator, prefix: []const u8, relative: []const u8) ![]u8 {
    if (relative.len == 0 or std.mem.eql(u8, relative, ".")) return allocator.dupe(u8, prefix);
    const encoded = try replaceSeparatorsAlloc(allocator, relative);
    defer allocator.free(encoded);
    if (std.mem.endsWith(u8, prefix, "-")) return std.mem.concat(allocator, u8, &.{ prefix, encoded });
    return std.mem.concat(allocator, u8, &.{ prefix, "-", encoded });
}

fn replaceSeparatorsAlloc(allocator: Allocator, value: []const u8) ![]u8 {
    const result = try allocator.dupe(u8, value);
    for (result) |*byte| if (byte.* == '/' or byte.* == '\\' or byte.* == ':') {
        byte.* = '-';
    };
    return result;
}

test "session cwd encoding matches home temp and absolute upstream buckets" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const home = try encodeCwdAlloc(allocator, io, "/home/tester/src/pi", .{
        .home = "/home/tester",
        .temp_dir = "/tmp",
    });
    defer allocator.free(home);
    try std.testing.expectEqualStrings("-src-pi", home);

    const home_root = try encodeCwdAlloc(allocator, io, "/home/tester", .{
        .home = "/home/tester",
        .temp_dir = "/tmp",
    });
    defer allocator.free(home_root);
    try std.testing.expectEqualStrings("-", home_root);

    const temp = try encodeCwdAlloc(allocator, io, "/tmp/work/a", .{
        .home = "/home/tester",
        .temp_dir = "/tmp",
    });
    defer allocator.free(temp);
    try std.testing.expectEqualStrings("-tmp-work-a", temp);

    const absolute = try encodeCwdAlloc(allocator, io, "/opt/work:a", .{
        .home = "/home/tester",
        .temp_dir = "/tmp",
    });
    defer allocator.free(absolute);
    try std.testing.expectEqualStrings("--opt-work-a--", absolute);

    const dotdot_prefix = try encodeCwdAlloc(allocator, io, "/home/tester/..foo", .{
        .home = "/home/tester",
        .temp_dir = "/tmp",
    });
    defer allocator.free(dotdot_prefix);
    try std.testing.expectEqualStrings("--home-tester-..foo--", dotdot_prefix);
}

test "session timestamp replaces colon and period only" {
    const value = try fileSafeTimestampAlloc(std.testing.allocator, "2026-02-16T10:20:30.000Z");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("2026-02-16T10-20-30-000Z", value);
}

test "session agent root honors OMP_ZIG_AGENT_DIR" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var environment_map = std.process.Environ.Map.init(allocator);
    defer environment_map.deinit();
    try environment_map.put("OMP_ZIG_AGENT_DIR", "/tmp/pi-zig-agent-override");
    const block = try environment_map.createPosixBlock(allocator, .{});
    defer block.deinit(allocator);
    const result = try agentDirAlloc(allocator, .{ .environ = .{ .block = block } });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/tmp/pi-zig-agent-override", result);
}
