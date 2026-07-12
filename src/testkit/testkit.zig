//! Phase 0: Offline transports and fixtures for dependency and behavior tests.

const std = @import("std");
const ai = @import("ai");
const openai_compatible = @import("openai_compatible");
const provider = @import("provider");

pub const mock_transport = @import("mock_transport.zig");

test "ai.zig streams an OpenAI-compatible response through the mock transport" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var mock: mock_transport.MockTransport = .{};
    const factory = openai_compatible.createOpenAiCompatible(.{
        .provider_name = "phase-0",
        .base_url = "https://example.test/v1",
        .api_key = "dummy-key",
        .transport = mock.transport(),
    });
    var chat = try factory.chatModel("smoke-model", null);
    const language_model = chat.languageModel();

    var result = try ai.streamText(io, allocator, .{
        .model = .{ .model = language_model },
        .prompt = .{ .text = "hi" },
    });
    defer result.deinit(io);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    while (try result.next(io)) |part| switch (part) {
        .text_delta => |delta| try text.appendSlice(allocator, delta.text),
        else => {},
    };

    try std.testing.expectEqualStrings(mock_transport.canned_text, text.items);
    const finish_reason = try result.finishReason(io);
    try std.testing.expectEqual(provider.FinishReasonUnified.stop, finish_reason.unified);
    try std.testing.expectEqualStrings("stop", finish_reason.raw.?);
    try std.testing.expectEqual(@as(usize, 1), mock.request_count);
    try std.testing.expect(mock.saw_stream_request);
}
