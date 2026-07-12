//! Type-erased filesystem seam and an owned in-memory implementation.

const std = @import("std");
const types = @import("types.zig");

pub const Fs = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8,
        write: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            path: []const u8,
            content: []const u8,
        ) anyerror![]u8,
        exists: *const fn (context: *anyopaque, path: []const u8) anyerror!bool,
        rename: *const fn (context: *anyopaque, from: []const u8, to: []const u8, content: ?[]const u8) anyerror!void,
        delete: *const fn (context: *anyopaque, path: []const u8) anyerror!void,
        canonical_path: ?*const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            path: []const u8,
        ) anyerror![]u8 = null,
        preflight_write: ?*const fn (context: *anyopaque, path: []const u8, file_op: ?types.FileOp) anyerror!void = null,
        allow_tag_path_recovery: ?*const fn (
            context: *anyopaque,
            authored_path: []const u8,
            resolved_path: []const u8,
        ) bool = null,
        /// Optional adapter-owned rendering for dynamic I/O failures. This
        /// keeps model-facing path/detail text intact instead of reducing every
        /// backend failure to a Zig error-set name.
        error_message: ?*const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            err: anyerror,
        ) std.mem.Allocator.Error![]const u8 = null,
    };

    pub fn read(self: Fs, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return self.vtable.read(self.context, allocator, path);
    }

    /// Returns the actual text persisted by the backend. The returned slice is
    /// allocated by `allocator`.
    pub fn write(self: Fs, allocator: std.mem.Allocator, path: []const u8, content: []const u8) ![]u8 {
        return self.vtable.write(self.context, allocator, path, content);
    }

    pub fn exists(self: Fs, path: []const u8) !bool {
        return self.vtable.exists(self.context, path);
    }

    pub fn rename(self: Fs, from: []const u8, to: []const u8, content: ?[]const u8) !void {
        return self.vtable.rename(self.context, from, to, content);
    }

    pub fn delete(self: Fs, path: []const u8) !void {
        return self.vtable.delete(self.context, path);
    }

    pub fn canonicalPath(self: Fs, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const function = self.vtable.canonical_path orelse return allocator.dupe(u8, path);
        return function(self.context, allocator, path);
    }

    pub fn preflightWrite(self: Fs, path: []const u8, file_op: ?types.FileOp) !void {
        if (self.vtable.preflight_write) |function| try function(self.context, path, file_op);
    }

    pub fn allowTagPathRecovery(self: Fs, authored_path: []const u8, resolved_path: []const u8) bool {
        const function = self.vtable.allow_tag_path_recovery orelse return true;
        return function(self.context, authored_path, resolved_path);
    }

    pub fn errorMessage(
        self: Fs,
        allocator: std.mem.Allocator,
        err: anyerror,
    ) std.mem.Allocator.Error![]const u8 {
        const function = self.vtable.error_message orelse return allocator.dupe(u8, @errorName(err));
        return function(self.context, allocator, err);
    }
};

pub const InMemoryFs = struct {
    allocator: std.mem.Allocator,
    files: std.StringHashMap([]u8),

    pub fn init(allocator: std.mem.Allocator) InMemoryFs {
        return .{
            .allocator = allocator,
            .files = std.StringHashMap([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *InMemoryFs) void {
        var iterator = self.files.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.files.deinit();
        self.* = undefined;
    }

    pub fn fs(self: *InMemoryFs) Fs {
        return .{ .context = self, .vtable = &vtable };
    }

    pub fn put(self: *InMemoryFs, path: []const u8, content: []const u8) !void {
        const value = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(value);
        if (self.files.getPtr(path)) |existing| {
            self.allocator.free(existing.*);
            existing.* = value;
            return;
        }
        const key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(key);
        try self.files.put(key, value);
    }

    pub fn get(self: *const InMemoryFs, path: []const u8) ?[]const u8 {
        return self.files.get(path);
    }

    pub fn clear(self: *InMemoryFs) void {
        var iterator = self.files.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.files.clearRetainingCapacity();
    }

    fn readErased(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const self: *InMemoryFs = @ptrCast(@alignCast(context));
        const content = self.files.get(path) orelse return error.FileNotFound;
        return allocator.dupe(u8, content);
    }

    fn writeErased(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        path: []const u8,
        content: []const u8,
    ) ![]u8 {
        const self: *InMemoryFs = @ptrCast(@alignCast(context));
        try self.put(path, content);
        return allocator.dupe(u8, content);
    }

    fn existsErased(context: *anyopaque, path: []const u8) !bool {
        const self: *InMemoryFs = @ptrCast(@alignCast(context));
        return self.files.contains(path);
    }

    fn renameErased(context: *anyopaque, from: []const u8, to: []const u8, content: ?[]const u8) !void {
        const self: *InMemoryFs = @ptrCast(@alignCast(context));
        const existing = self.files.get(from) orelse return error.FileNotFound;
        try self.put(to, content orelse existing);
        try self.deleteOwned(from);
    }

    fn deleteErased(context: *anyopaque, path: []const u8) !void {
        const self: *InMemoryFs = @ptrCast(@alignCast(context));
        try self.deleteOwned(path);
    }

    fn canonicalPathErased(_: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(allocator, &.{path});
        const absolute = try std.fs.path.resolve(allocator, &.{ "/", path });
        defer allocator.free(absolute);
        if (absolute.len <= 1) return allocator.dupe(u8, ".");
        return allocator.dupe(u8, absolute[1..]);
    }

    fn deleteOwned(self: *InMemoryFs, path: []const u8) !void {
        const removed = self.files.fetchRemove(path) orelse return error.FileNotFound;
        self.allocator.free(removed.key);
        self.allocator.free(removed.value);
    }

    const vtable: Fs.VTable = .{
        .read = readErased,
        .write = writeErased,
        .exists = existsErased,
        .rename = renameErased,
        .delete = deleteErased,
        .canonical_path = canonicalPathErased,
    };
};

test "hashline fs: in-memory read write rename delete" {
    var memory = InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    try memory.put("a.ts", "a\n");
    const backend = memory.fs();
    const read = try backend.read(std.testing.allocator, "a.ts");
    defer std.testing.allocator.free(read);
    try std.testing.expectEqualStrings("a\n", read);

    const written = try backend.write(std.testing.allocator, "a.ts", "b\n");
    defer std.testing.allocator.free(written);
    try backend.rename("a.ts", "b.ts", null);
    try std.testing.expectEqualStrings("b\n", memory.get("b.ts").?);
    try backend.delete("b.ts");
    try std.testing.expect(!try backend.exists("b.ts"));
}
