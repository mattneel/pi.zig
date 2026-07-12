//! Phases 6 and 7: QuickJS evaluation and extension hosting.

const std = @import("std");
const quickjs = @import("quickjs");

test "QuickJS evaluates an expression" {
    const runtime: *quickjs.Runtime = try .init();
    runtime.setDumpFlags(.abort_on_leaks);
    defer runtime.deinit();

    const context = try runtime.newContext();
    defer context.deinit();

    const result = context.eval("1+1", "<phase-0-smoke>", .{});
    defer result.deinit(context);

    try std.testing.expect(!result.isException());
    try std.testing.expectEqual(@as(i32, 2), try result.toInt32(context));
}

test "QuickJS interrupt handler stops unbounded evaluation" {
    const runtime: *quickjs.Runtime = try .init();
    runtime.setDumpFlags(.abort_on_leaks);
    defer runtime.deinit();

    const context = try runtime.newContext();
    defer context.deinit();

    const InterruptState = struct {
        calls: usize = 0,

        fn interrupt(self: ?*@This(), _: *quickjs.Runtime) bool {
            self.?.calls += 1;
            return self.?.calls > 100;
        }
    };
    var state: InterruptState = .{};
    runtime.setInterruptHandler(InterruptState, &state, InterruptState.interrupt);
    defer runtime.setInterruptHandler(InterruptState, null, null);

    const result = context.eval("while(true){}", "<phase-0-interrupt>", .{});
    defer result.deinit(context);

    try std.testing.expect(result.isException());
    try std.testing.expect(state.calls > 100);

    const exception = context.getException();
    defer exception.deinit(context);
    try std.testing.expect(exception.isUncatchableError());
}
