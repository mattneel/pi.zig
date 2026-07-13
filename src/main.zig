const std = @import("std");
const pi = @import("pi");

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const allocator = std.heap.smp_allocator;
    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    var stderr_writer = std.Io.File.stderr().writerStreaming(init.io, &stderr_buffer);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    const exit_code = pi.cli.app.run(
        allocator,
        init.io,
        argv[1..],
        std.Io.File.stdin(),
        stdout,
        stderr,
        .{
            .environ = init.minimal.environ,
            .path_options = .{ .environ = init.minimal.environ },
        },
    ) catch |err| blk: {
        try stderr.print("Startup failed: {s}\n", .{@errorName(err)});
        try stderr.flush();
        break :blk @as(u8, 1);
    };
    try stdout.flush();
    try stderr.flush();
    if (exit_code != 0) std.process.exit(exit_code);
}

test "version text comes from the zon build option" {
    try std.testing.expectEqualStrings("0.0.0", pi.build_options.version);
}

test {
    std.testing.refAllDecls(pi);
}
