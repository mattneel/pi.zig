const std = @import("std");
const build_options = @import("build_options");
const pi = @import("pi");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and isVersionFlag(args[1])) {
        try std.Io.File.stdout().writeStreamingAll(init.io, build_options.version ++ "\n");
        return;
    }

    try std.Io.File.stderr().writeStreamingAll(init.io, "pi.zig — phase 0 skeleton\n");
}

fn isVersionFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v");
}

test "version flags" {
    try std.testing.expect(isVersionFlag("--version"));
    try std.testing.expect(isVersionFlag("-v"));
    try std.testing.expect(!isVersionFlag("version"));
    try std.testing.expectEqualStrings("0.0.0", build_options.version);
}

test {
    std.testing.refAllDecls(pi);
}
