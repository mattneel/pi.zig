//! Phases 3 and 5: ZigZag terminal frontend and interactive UI depth.

const std = @import("std");
const zigzag = @import("zigzag");

const TestModel = struct {
    pub const Msg = union(enum) { noop };

    pub fn init(_: *TestModel, _: *zigzag.Context) zigzag.Cmd(Msg) {
        return .none;
    }

    pub fn update(_: *TestModel, _: Msg, _: *zigzag.Context) zigzag.Cmd(Msg) {
        return .none;
    }

    pub fn view(_: *const TestModel, _: *const zigzag.Context) []const u8 {
        return "";
    }
};

test "ZigZag Program and Options surface" {
    const TestProgram = zigzag.Program(TestModel);
    try std.testing.expect(@sizeOf(TestProgram) > 0);

    const options: zigzag.Options = .{
        .fps = 30,
        .mouse = true,
        .cursor = true,
        .alt_screen = false,
        .bracketed_paste = false,
        .kitty_keyboard = true,
        .suspend_enabled = false,
    };
    try std.testing.expectEqual(@as(u32, 30), options.fps);
    try std.testing.expect(options.mouse and options.cursor and options.kitty_keyboard);
    try std.testing.expect(!options.alt_screen and !options.bracketed_paste and !options.suspend_enabled);
}
