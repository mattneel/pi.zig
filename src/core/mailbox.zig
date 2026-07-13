//! Bounded, thread-safe ownership boundaries between frontends and the agent.
//!
//! `push` deep-copies a value with its `dupeInto` method. A popped value is
//! owned by the receiver and must be released with its `deinit` method. Closing
//! rejects new pushes, wakes all waiters, and still permits buffered values to
//! drain before `pop` returns `null`.

const std = @import("std");
const events = @import("events.zig");

const Allocator = std.mem.Allocator;

pub const ClosedError = error{Closed};

pub fn BoundedMailbox(comptime T: type) type {
    return struct {
        allocator: Allocator,
        buffer: []T,
        head: usize = 0,
        len: usize = 0,
        closed: bool = false,
        mutex: std.Io.Mutex = .init,
        readable: std.Io.Condition = .init,
        writable: std.Io.Condition = .init,

        const Self = @This();

        pub fn init(allocator: Allocator, buffer_capacity: usize) !Self {
            if (buffer_capacity == 0) return error.InvalidCapacity;
            return .{
                .allocator = allocator,
                .buffer = try allocator.alloc(T, buffer_capacity),
            };
        }

        /// Requires all producers and consumers to have stopped. Remaining
        /// buffered values are released here.
        pub fn deinit(self: *Self) void {
            while (self.len != 0) {
                var value = self.takeLocked();
                value.deinit(self.allocator);
            }
            self.allocator.free(self.buffer);
            self.* = undefined;
        }

        pub fn capacity(self: *const Self) usize {
            return self.buffer.len;
        }

        pub fn count(self: *Self, io: std.Io) usize {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            return self.len;
        }

        pub fn isClosed(self: *Self, io: std.Io) bool {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            return self.closed;
        }

        pub fn push(self: *Self, io: std.Io, value: T) (Allocator.Error || ClosedError || std.Io.Cancelable)!void {
            var owned = try value.dupeInto(self.allocator);
            errdefer owned.deinit(self.allocator);

            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            while (self.len == self.buffer.len and !self.closed) {
                try self.writable.wait(io, &self.mutex);
            }
            if (self.closed) return error.Closed;

            const tail = (self.head + self.len) % self.buffer.len;
            self.buffer[tail] = owned;
            self.len += 1;
            self.readable.signal(io);
        }

        /// Non-blocking with respect to queue contents. Lock acquisition is
        /// uncancelable so an empty result never means "mutex was busy".
        pub fn tryPop(self: *Self, io: std.Io) ?T {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.len == 0) return null;
            const value = self.takeLocked();
            self.writable.signal(io);
            return value;
        }

        /// Returns `null` only after `close` and after every buffered value has
        /// been drained.
        pub fn pop(self: *Self, io: std.Io) std.Io.Cancelable!?T {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            while (self.len == 0 and !self.closed) {
                try self.readable.wait(io, &self.mutex);
            }
            if (self.len == 0) return null;
            const value = self.takeLocked();
            self.writable.signal(io);
            return value;
        }

        pub fn close(self: *Self, io: std.Io) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.closed) return;
            self.closed = true;
            self.readable.broadcast(io);
            self.writable.broadcast(io);
        }

        fn takeLocked(self: *Self) T {
            std.debug.assert(self.len != 0);
            const value = self.buffer[self.head];
            self.head = (self.head + 1) % self.buffer.len;
            self.len -= 1;
            return value;
        }
    };
}

pub const CommandInbox = BoundedMailbox(events.AgentCommand);
pub const EventOutbox = BoundedMailbox(events.AgentEvent);

test "mailbox cross-task push pop deep-copies and drains after close" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var inbox = try CommandInbox.init(allocator, 1);
    defer inbox.deinit();

    var prompt = try events.OwnedPrompt.init(allocator, "first", &.{}, false, .user);
    defer prompt.deinit(allocator);
    const Producer = struct {
        fn run(box: *CommandInbox, task_io: std.Io, source: *events.OwnedPrompt) anyerror!void {
            try box.push(task_io, .{ .prompt = source.* });
            source.text[0] = 'X';
            try box.push(task_io, .retry);
        }
    };
    var producer = io.async(Producer.run, .{ &inbox, io, &prompt });

    var first = (try inbox.pop(io)).?;
    defer first.deinit(allocator);
    try std.testing.expect(first == .prompt);
    try std.testing.expectEqualStrings("first", first.prompt.text);

    var second = (try inbox.pop(io)).?;
    defer second.deinit(allocator);
    try std.testing.expect(second == .retry);
    try producer.await(io);

    inbox.close(io);
    try std.testing.expect((try inbox.pop(io)) == null);
    try std.testing.expectError(error.Closed, inbox.push(io, .shutdown));
}

test "event outbox tryPop returns independently owned event" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var outbox = try EventOutbox.init(allocator, 2);
    defer outbox.deinit();

    var notice = try events.Notice.init(allocator, .info, "ready");
    defer notice.deinit(allocator);
    try outbox.push(io, .{ .notice = notice });
    notice.message[0] = 'X';

    var popped = outbox.tryPop(io).?;
    defer popped.deinit(allocator);
    try std.testing.expectEqualStrings("ready", popped.notice.message);
    try std.testing.expect(outbox.tryPop(io) == null);
}
