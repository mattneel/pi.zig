//! Non-interactive session flag resolution.

const std = @import("std");
const args = @import("args.zig");
const message = @import("../core/message.zig");
const manager_module = @import("../session/manager.zig");
const session_paths = @import("../session/paths.zig");

const Allocator = std.mem.Allocator;

pub const Result = union(enum) {
    manager: manager_module.SessionManager,
    cross_project,
    resume_picker_deferred,
};

pub const Options = struct {
    path_options: session_paths.Options = .{},
};

pub fn resolve(
    allocator: Allocator,
    io: std.Io,
    parsed: args.Parsed,
    cwd: []const u8,
    options: Options,
) !Result {
    if (parsed.no_session) {
        return .{ .manager = try manager_module.SessionManager.inMemory(allocator, io, cwd) };
    }

    const resolved_session_dir = if (parsed.session_dir) |value|
        try resolveAgainst(allocator, cwd, value)
    else
        null;
    defer if (resolved_session_dir) |value| allocator.free(value);
    const open_options: manager_module.OpenOptions = .{
        .session_dir = resolved_session_dir,
        .path_options = options.path_options,
    };
    switch (parsed.resume_session) {
        .bare => return .resume_picker_deferred,
        .value => |value| {
            if (looksLikePath(value)) {
                const path = try resolveAgainst(allocator, cwd, value);
                defer allocator.free(path);
                _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
                    error.FileNotFound => return error.SessionNotFound,
                    else => return err,
                };
                var opened = try manager_module.SessionManager.open(allocator, io, path, open_options);
                if (!sameProject(allocator, cwd, opened.getHeader().cwd)) {
                    opened.deinit();
                    return .cross_project;
                }
                return .{ .manager = opened };
            }

            const local = try manager_module.SessionManager.list(allocator, io, cwd, open_options);
            defer manager_module.deinitSessionInfoSlice(allocator, local);
            if (findMatch(local, value)) |match| {
                if (!sameProject(allocator, cwd, match.cwd)) return .cross_project;
                return .{ .manager = try manager_module.SessionManager.open(allocator, io, match.path, open_options) };
            }

            if (parsed.session_dir == null) {
                const global = try manager_module.SessionManager.listAll(allocator, io, open_options);
                defer manager_module.deinitSessionInfoSlice(allocator, global);
                if (findMatch(global, value)) |match| {
                    if (!sameProject(allocator, cwd, match.cwd)) return .cross_project;
                    return .{ .manager = try manager_module.SessionManager.open(allocator, io, match.path, open_options) };
                }
            }
            return error.SessionNotFound;
        },
        .none => {},
    }

    if (parsed.continue_recent) {
        return .{ .manager = try manager_module.SessionManager.continueRecent(allocator, io, cwd, open_options) };
    }
    return .{ .manager = try manager_module.SessionManager.create(allocator, io, cwd, .{
        .session_dir = resolved_session_dir,
        .path_options = options.path_options,
    }) };
}

fn looksLikePath(value: []const u8) bool {
    return std.mem.indexOfAny(u8, value, "/\\") != null or std.mem.endsWith(u8, value, ".jsonl");
}

fn resolveAgainst(allocator: Allocator, cwd: []const u8, value: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(value)) return std.fs.path.resolve(allocator, &.{value});
    return std.fs.path.resolve(allocator, &.{ cwd, value });
}

fn findMatch(values: []const manager_module.SessionInfo, prefix: []const u8) ?*const manager_module.SessionInfo {
    for (values) |*value| {
        if (!value.resumable) continue;
        if (std.ascii.startsWithIgnoreCase(value.id, prefix)) return value;
        const filename = std.fs.path.basename(value.path);
        if (std.ascii.startsWithIgnoreCase(filename, prefix)) return value;
        if (std.mem.indexOfScalar(u8, filename, '_')) |separator| {
            if (std.ascii.startsWithIgnoreCase(filename[separator + 1 ..], prefix)) return value;
        }
    }
    return null;
}

fn sameProject(allocator: Allocator, left: []const u8, right: []const u8) bool {
    const resolved_left = std.fs.path.resolve(allocator, &.{left}) catch return false;
    defer allocator.free(resolved_left);
    const resolved_right = std.fs.path.resolve(allocator, &.{right}) catch return false;
    defer allocator.free(resolved_right);
    return if (@import("builtin").os.tag == .windows)
        std.ascii.eqlIgnoreCase(resolved_left, resolved_right)
    else
        std.mem.eql(u8, resolved_left, resolved_right);
}

fn persistedAssistant(text: []const u8) message.AgentMessage {
    return .{ .assistant = .{
        .content = &.{.{ .text = .{ .text = text } }},
        .api = "anthropic-messages",
        .provider = "anthropic",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 2,
    } };
}

fn persistConversation(manager: *manager_module.SessionManager, text: []const u8) !void {
    _ = try manager.appendMessage(.{ .user = .{ .content = .{ .string = text }, .timestamp = 1 } });
    _ = try manager.appendMessage(persistedAssistant("done"));
    try manager.flush();
}

test "session resolver no-session remains memory-only and session-dir chooses the path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const path_options: session_paths.Options = .{ .agent_dir = root, .home = root, .temp_dir = "/tmp" };

    var memory_result = try resolve(allocator, io, .{ .no_session = true }, root, .{ .path_options = path_options });
    var memory = &memory_result.manager;
    defer memory.deinit();
    try std.testing.expect(memory.path() == null);
    try persistConversation(memory, "memory");
    const listed = try manager_module.SessionManager.listAll(allocator, io, .{ .path_options = path_options });
    defer manager_module.deinitSessionInfoSlice(allocator, listed);
    try std.testing.expectEqual(@as(usize, 0), listed.len);

    const custom_dir = try std.fs.path.join(allocator, &.{ root, "chosen" });
    defer allocator.free(custom_dir);
    var disk_result = try resolve(allocator, io, .{ .session_dir = custom_dir }, root, .{ .path_options = path_options });
    var disk = &disk_result.manager;
    defer disk.deinit();
    try std.testing.expect(std.mem.startsWith(u8, disk.path().?, custom_dir));
}

test "session resolver continue selects newest and resume path round trips" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const path_options: session_paths.Options = .{ .agent_dir = root, .home = root, .temp_dir = "/tmp" };

    var first = try manager_module.SessionManager.create(allocator, io, root, .{ .path_options = path_options });
    try persistConversation(&first, "first");
    const first_path = try allocator.dupe(u8, first.path().?);
    defer allocator.free(first_path);
    first.deinit();
    try io.sleep(.fromMilliseconds(2), .awake);
    var second = try manager_module.SessionManager.create(allocator, io, root, .{ .path_options = path_options });
    try persistConversation(&second, "second");
    const second_path = try allocator.dupe(u8, second.path().?);
    defer allocator.free(second_path);
    second.deinit();

    var continued_result = try resolve(allocator, io, .{ .continue_recent = true }, root, .{ .path_options = path_options });
    var continued = &continued_result.manager;
    try std.testing.expectEqualStrings(second_path, continued.path().?);
    continued.deinit();

    var resumed_result = try resolve(allocator, io, .{ .resume_session = .{ .value = first_path } }, root, .{ .path_options = path_options });
    var resumed = &resumed_result.manager;
    defer resumed.deinit();
    try std.testing.expectEqualStrings(first_path, resumed.path().?);
    try std.testing.expectEqual(@as(usize, 2), resumed.getEntries().len);

    const filename = std.fs.path.basename(first_path);
    const filename_prefix = filename[0 .. filename.len - ".jsonl".len];
    var filename_result = try resolve(
        allocator,
        io,
        .{ .resume_session = .{ .value = filename_prefix } },
        root,
        .{ .path_options = path_options },
    );
    var filename_resumed = &filename_result.manager;
    defer filename_resumed.deinit();
    try std.testing.expectEqualStrings(first_path, filename_resumed.path().?);
}

test "session resolver finds case-insensitive id prefixes and declines cross-project resume" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "one");
    try tmp.dir.createDirPath(io, "two");
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const one = try std.fs.path.join(allocator, &.{ root, "one" });
    defer allocator.free(one);
    const two = try std.fs.path.join(allocator, &.{ root, "two" });
    defer allocator.free(two);
    const path_options: session_paths.Options = .{ .agent_dir = root, .home = root, .temp_dir = "/tmp" };
    var source = try manager_module.SessionManager.create(allocator, io, one, .{ .path_options = path_options });
    try persistConversation(&source, "source");
    const id_prefix = try allocator.dupe(u8, source.getHeader().id[0..8]);
    defer allocator.free(id_prefix);
    for (id_prefix) |*byte| byte.* = std.ascii.toUpper(byte.*);
    source.deinit();

    const result = try resolve(allocator, io, .{ .resume_session = .{ .value = id_prefix } }, two, .{ .path_options = path_options });
    try std.testing.expect(result == .cross_project);
}
