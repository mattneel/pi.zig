//! Real filesystem adapter shared by the local coding tools.
//!
//! The adapter owns no path storage. `cwd` and `home` are borrowed from the
//! session state and must outlive every filesystem call. Returned paths and
//! file contents are owned by the allocator supplied to the operation.

const std = @import("std");
const hashline = @import("../hashline/hashline.zig");

const Allocator = std.mem.Allocator;

pub const RealFs = struct {
    io: std.Io,
    cwd: []const u8,
    home: ?[]const u8 = null,

    pub fn init(io: std.Io, cwd: []const u8, home: ?[]const u8) RealFs {
        return .{ .io = io, .cwd = cwd, .home = home };
    }

    pub fn fs(self: *RealFs) hashline.Fs {
        return .{ .context = self, .vtable = &vtable };
    }

    pub fn resolve(self: *const RealFs, allocator: Allocator, path: []const u8) ![]u8 {
        const expanded = try self.expandTilde(allocator, path);
        defer allocator.free(expanded);
        if (std.fs.path.isAbsolute(expanded)) return std.fs.path.resolve(allocator, &.{expanded});
        return std.fs.path.resolve(allocator, &.{ self.cwd, expanded });
    }

    pub fn displayPath(self: *const RealFs, allocator: Allocator, absolute_path: []const u8) ![]u8 {
        const relative = try std.fs.path.relative(allocator, self.cwd, null, self.cwd, absolute_path);
        if (isOutside(relative)) {
            allocator.free(relative);
            return allocator.dupe(u8, absolute_path);
        }
        if (relative.len == 0) {
            allocator.free(relative);
            return allocator.dupe(u8, ".");
        }
        return relative;
    }

    pub fn shortPath(self: *const RealFs, allocator: Allocator, absolute_path: []const u8) ![]u8 {
        if (self.home) |home| {
            if (std.mem.eql(u8, absolute_path, home)) return allocator.dupe(u8, "~");
            if (absolute_path.len > home.len and
                std.mem.startsWith(u8, absolute_path, home) and
                std.fs.path.isSep(absolute_path[home.len]))
            {
                return std.fmt.allocPrint(allocator, "~{s}", .{absolute_path[home.len..]});
            }
        }
        return allocator.dupe(u8, absolute_path);
    }

    pub fn readFile(self: *const RealFs, allocator: Allocator, path: []const u8, limit: std.Io.Limit) ![]u8 {
        const absolute = try self.resolve(allocator, path);
        defer allocator.free(absolute);
        return std.Io.Dir.cwd().readFileAlloc(self.io, absolute, allocator, limit);
    }

    pub fn writeFile(self: *const RealFs, path: []const u8, content: []const u8) !void {
        const absolute = try self.resolve(std.heap.page_allocator, path);
        defer std.heap.page_allocator.free(absolute);
        try self.makeParent(absolute);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = absolute, .data = content });
    }

    pub fn makeParent(self: *const RealFs, absolute_path: []const u8) !void {
        const parent = std.fs.path.dirname(absolute_path) orelse return;
        if (parent.len == 0) return;
        try std.Io.Dir.cwd().createDirPath(self.io, parent);
    }

    pub fn stat(self: *const RealFs, allocator: Allocator, path: []const u8) !std.Io.File.Stat {
        const absolute = try self.resolve(allocator, path);
        defer allocator.free(absolute);
        return std.Io.Dir.cwd().statFile(self.io, absolute, .{});
    }

    fn expandTilde(self: *const RealFs, allocator: Allocator, path: []const u8) ![]u8 {
        if (path.len == 0 or path[0] != '~') return allocator.dupe(u8, path);
        const home = self.home orelse return allocator.dupe(u8, path);
        if (path.len == 1) return allocator.dupe(u8, home);
        if (std.fs.path.isSep(path[1])) return std.mem.concat(allocator, u8, &.{ home, path[1..] });
        return allocator.dupe(u8, path);
    }

    fn readErased(context: *anyopaque, allocator: Allocator, path: []const u8) ![]u8 {
        const self: *RealFs = @ptrCast(@alignCast(context));
        return self.readFile(allocator, path, .unlimited);
    }

    fn writeErased(context: *anyopaque, allocator: Allocator, path: []const u8, content: []const u8) ![]u8 {
        const self: *RealFs = @ptrCast(@alignCast(context));
        const absolute = try self.resolve(allocator, path);
        defer allocator.free(absolute);
        try self.makeParent(absolute);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = absolute, .data = content });
        return allocator.dupe(u8, content);
    }

    fn existsErased(context: *anyopaque, path: []const u8) !bool {
        const self: *RealFs = @ptrCast(@alignCast(context));
        const absolute = try self.resolve(std.heap.page_allocator, path);
        defer std.heap.page_allocator.free(absolute);
        _ = std.Io.Dir.cwd().statFile(self.io, absolute, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return false,
            else => return err,
        };
        return true;
    }

    fn renameErased(context: *anyopaque, from: []const u8, to: []const u8, content: ?[]const u8) !void {
        const self: *RealFs = @ptrCast(@alignCast(context));
        const allocator = std.heap.page_allocator;
        const source = try self.resolve(allocator, from);
        defer allocator.free(source);
        const destination = try self.resolve(allocator, to);
        defer allocator.free(destination);
        try self.makeParent(destination);
        if (content) |bytes| {
            try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = destination, .data = bytes });
            try std.Io.Dir.deleteFileAbsolute(self.io, source);
            return;
        }
        try std.Io.Dir.renameAbsolute(source, destination, self.io);
    }

    fn deleteErased(context: *anyopaque, path: []const u8) !void {
        const self: *RealFs = @ptrCast(@alignCast(context));
        const absolute = try self.resolve(std.heap.page_allocator, path);
        defer std.heap.page_allocator.free(absolute);
        try std.Io.Dir.deleteFileAbsolute(self.io, absolute);
    }

    fn canonicalPathErased(context: *anyopaque, allocator: Allocator, path: []const u8) ![]u8 {
        const self: *RealFs = @ptrCast(@alignCast(context));
        return self.resolve(allocator, path);
    }

    fn allowTagPathRecoveryErased(context: *anyopaque, _: []const u8, resolved_path: []const u8) bool {
        const self: *RealFs = @ptrCast(@alignCast(context));
        const relative = std.fs.path.relative(std.heap.page_allocator, self.cwd, null, self.cwd, resolved_path) catch return false;
        defer std.heap.page_allocator.free(relative);
        return !isOutside(relative);
    }

    fn errorMessageErased(_: *anyopaque, allocator: Allocator, err: anyerror) Allocator.Error![]const u8 {
        return allocator.dupe(u8, @errorName(err));
    }

    const vtable: hashline.Fs.VTable = .{
        .read = readErased,
        .write = writeErased,
        .exists = existsErased,
        .rename = renameErased,
        .delete = deleteErased,
        .canonical_path = canonicalPathErased,
        .allow_tag_path_recovery = allowTagPathRecoveryErased,
        .error_message = errorMessageErased,
    };
};

fn isOutside(relative: []const u8) bool {
    if (std.mem.eql(u8, relative, "..")) return true;
    return relative.len > 2 and
        std.mem.startsWith(u8, relative, "..") and
        std.fs.path.isSep(relative[2]);
}

pub fn dirRealPathAlloc(allocator: Allocator, io: std.Io, dir: std.Io.Dir) ![]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try dir.realPath(io, &buffer);
    return allocator.dupe(u8, buffer[0..length]);
}

test "fs_real resolves session paths and creates parents" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try dirRealPathAlloc(std.testing.allocator, io, tmp.dir);
    defer std.testing.allocator.free(cwd);
    var real = RealFs.init(io, cwd, null);
    const backend = real.fs();

    const written = try backend.write(std.testing.allocator, "nested/a.txt", "hello\n");
    defer std.testing.allocator.free(written);
    const read = try backend.read(std.testing.allocator, "nested/a.txt");
    defer std.testing.allocator.free(read);
    try std.testing.expectEqualStrings("hello\n", read);

    const canonical = try backend.canonicalPath(std.testing.allocator, "nested/a.txt");
    defer std.testing.allocator.free(canonical);
    try std.testing.expect(std.fs.path.isAbsolute(canonical));
}
