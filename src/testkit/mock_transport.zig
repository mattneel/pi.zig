const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");

pub const canned_text = "Hello";

const canned_sse =
    "data: {\"id\":\"chatcmpl-phase-0\",\"created\":1711115037,\"model\":\"smoke-model\",\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: [DONE]\n\n";

pub const MockTransport = struct {
    request_count: usize = 0,
    saw_stream_request: bool = false,

    pub fn transport(self: *MockTransport) provider_utils.HttpTransport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: provider_utils.HttpTransportVTable = .{ .request = request };

    const BodyState = struct {
        reader: std.Io.Reader,

        fn deinit(_: *anyopaque, _: std.Io) void {}
    };

    fn request(
        raw: *anyopaque,
        _: std.Io,
        arena: std.mem.Allocator,
        spec: provider_utils.RequestSpec,
        _: ?*provider.Diagnostics,
    ) provider_utils.RequestError!provider_utils.Response {
        const self: *MockTransport = @ptrCast(@alignCast(raw));
        self.request_count += 1;
        self.saw_stream_request = spec.body != null and
            std.mem.indexOf(u8, spec.body.?, "\"stream\":true") != null;

        const state = try arena.create(BodyState);
        state.* = .{ .reader = std.Io.Reader.fixed(canned_sse) };
        return .{
            .status = 200,
            .status_text = "OK",
            .headers = &.{.{ .name = "content-type", .value = "text/event-stream" }},
            .body = .{
                .ctx = state,
                .reader_ptr = &state.reader,
                .deinit_fn = BodyState.deinit,
            },
        };
    }
};
