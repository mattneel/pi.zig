const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");

pub const canned_text = "Hello";

pub const canned_sse =
    "data: {\"id\":\"chatcmpl-phase-0\",\"created\":1711115037,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: [DONE]\n\n";

pub const HttpError = struct {
    status: u16,
    status_text: []const u8 = "Error",
    body: []const u8 = "{\"error\":{\"message\":\"scripted provider error\"}}",
    retry_after_ms: ?[]const u8 = null,
};

pub const SplitSse = struct {
    prefix: []const u8,
    gate: *std.Io.Event,
    entered: ?*std.Io.Event = null,
    suffix: []const u8 = "",
};

pub const ScriptedResponse = union(enum) {
    sse: []const u8,
    blocked_sse: struct {
        gate: *std.Io.Event,
        entered: ?*std.Io.Event = null,
        body: []const u8,
    },
    split_sse: SplitSse,
    http_error: HttpError,
};

pub const RequestObserver = struct {
    ctx: ?*anyopaque = null,
    observe_fn: *const fn (ctx: ?*anyopaque, request_index: usize, body: ?[]const u8) void,
};

pub const MockTransport = struct {
    request_count: usize = 0,
    saw_stream_request: bool = false,
    script: []const ScriptedResponse = &.{},
    script_index: usize = 0,
    observer: ?RequestObserver = null,

    pub fn init(script: []const ScriptedResponse) MockTransport {
        return .{ .script = script };
    }

    pub fn transport(self: *MockTransport) provider_utils.HttpTransport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: provider_utils.HttpTransportVTable = .{ .request = request };

    const BodyState = struct {
        reader: std.Io.Reader,
        buffer: [4096]u8 = undefined,
        io: ?std.Io = null,
        prefix: []const u8 = "",
        suffix: []const u8 = "",
        offset: usize = 0,
        gate: ?*std.Io.Event = null,
        entered: ?*std.Io.Event = null,
        released: bool = false,

        const split_vtable: std.Io.Reader.VTable = .{ .stream = streamSplit };

        fn initSplit(io: std.Io, split: SplitSse) BodyState {
            return .{
                .reader = .{ .vtable = &split_vtable, .buffer = &.{}, .seek = 0, .end = 0 },
                .io = io,
                .prefix = split.prefix,
                .suffix = split.suffix,
                .gate = split.gate,
                .entered = split.entered,
            };
        }

        fn streamSplit(
            reader: *std.Io.Reader,
            writer: *std.Io.Writer,
            limit: std.Io.Limit,
        ) std.Io.Reader.StreamError!usize {
            const self: *BodyState = @alignCast(@fieldParentPtr("reader", reader));
            if (self.offset < self.prefix.len) return self.writeFrom(writer, limit, self.prefix);
            if (!self.released) {
                if (self.entered) |entered| entered.set(self.io.?);
                self.gate.?.wait(self.io.?) catch return error.ReadFailed;
                self.released = true;
                self.offset = 0;
            }
            if (self.offset < self.suffix.len) return self.writeFrom(writer, limit, self.suffix);
            return error.EndOfStream;
        }

        fn writeFrom(
            self: *BodyState,
            writer: *std.Io.Writer,
            limit: std.Io.Limit,
            source: []const u8,
        ) std.Io.Reader.StreamError!usize {
            const remaining = source[self.offset..];
            const bytes = remaining[0..limit.minInt(remaining.len)];
            const written = try writer.write(bytes);
            self.offset += written;
            return written;
        }

        fn deinit(_: *anyopaque, _: std.Io) void {}
    };

    fn request(
        raw: *anyopaque,
        io: std.Io,
        arena: std.mem.Allocator,
        spec: provider_utils.RequestSpec,
        _: ?*provider.Diagnostics,
    ) provider_utils.RequestError!provider_utils.Response {
        const self: *MockTransport = @ptrCast(@alignCast(raw));
        const request_index = self.request_count;
        self.request_count += 1;
        self.saw_stream_request = spec.body != null and
            std.mem.indexOf(u8, spec.body.?, "\"stream\":true") != null;

        if (self.observer) |observer| observer.observe_fn(observer.ctx, request_index, spec.body);

        const response: ScriptedResponse = if (self.script.len == 0)
            .{ .sse = canned_sse }
        else blk: {
            if (self.script_index >= self.script.len) return error.InvalidArgumentError;
            const item = self.script[self.script_index];
            self.script_index += 1;
            break :blk item;
        };

        const body, const status, const status_text, const content_type, const retry_after_ms = switch (response) {
            .sse => |body| .{ body, @as(u16, 200), "OK", "text/event-stream", @as(?[]const u8, null) },
            .blocked_sse => |blocked| blk: {
                if (blocked.entered) |entered| entered.set(io);
                try blocked.gate.wait(io);
                break :blk .{ blocked.body, @as(u16, 200), "OK", "text/event-stream", @as(?[]const u8, null) };
            },
            .split_sse => .{ "", @as(u16, 200), "OK", "text/event-stream", @as(?[]const u8, null) },
            .http_error => |failure| .{
                failure.body,
                failure.status,
                failure.status_text,
                "application/json",
                failure.retry_after_ms,
            },
        };

        const state = try arena.create(BodyState);
        state.* = switch (response) {
            .split_sse => |split| BodyState.initSplit(io, split),
            else => .{ .reader = std.Io.Reader.fixed(body) },
        };
        if (response == .split_sse) state.reader.buffer = &state.buffer;
        const headers = try arena.alloc(provider.Header, if (retry_after_ms == null) 1 else 2);
        headers[0] = .{ .name = "content-type", .value = content_type };
        if (retry_after_ms) |value| headers[1] = .{ .name = "retry-after-ms", .value = value };
        return .{
            .status = status,
            .status_text = status_text,
            .headers = headers,
            .body = .{
                .ctx = state,
                .reader_ptr = &state.reader,
                .deinit_fn = BodyState.deinit,
            },
        };
    }
};

test "scriptable mock transport serves ordered SSE and retryable HTTP errors" {
    const script = [_]ScriptedResponse{
        .{ .http_error = .{ .status = 429, .status_text = "Too Many Requests", .retry_after_ms = "1" } },
        .{ .sse = canned_sse },
    };
    var mock = MockTransport.init(&script);
    var first_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer first_arena_state.deinit();
    var first = try mock.transport().request(std.testing.io, first_arena_state.allocator(), .{
        .method = .POST,
        .url = "https://example.test",
        .body = "{\"stream\":true}",
    }, null);
    defer first.body.deinit(std.testing.io);
    try std.testing.expectEqual(@as(u16, 429), first.status);
    try std.testing.expectEqualStrings("1", first.headers[1].value);

    var second_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer second_arena_state.deinit();
    var second = try mock.transport().request(std.testing.io, second_arena_state.allocator(), .{
        .method = .POST,
        .url = "https://example.test",
    }, null);
    defer second.body.deinit(std.testing.io);
    try std.testing.expectEqual(@as(u16, 200), second.status);
    try std.testing.expectEqual(@as(usize, 2), mock.request_count);
}
