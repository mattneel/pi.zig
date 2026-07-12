//! Pure data contracts shared by the hashline parser, applier, and patcher.
//!
//! Returned strings and slices are allocated by the caller-provided allocator.
//! The intended ownership model is an arena scoped to one parse/apply operation.

const std = @import("std");

pub const Anchor = struct {
    line: usize,
};

pub const Cursor = union(enum) {
    bof,
    eof,
    before_anchor: Anchor,
    after_anchor: Anchor,

    pub fn anchor(self: Cursor) ?Anchor {
        return switch (self) {
            .before_anchor => |value| value,
            .after_anchor => |value| value,
            .bof, .eof => null,
        };
    }
};

pub const InsertMode = enum {
    replacement,
};

pub const BlockMode = enum {
    insert_after,
};

pub const Edit = union(enum) {
    insert: Insert,
    delete: Delete,
    block: Block,

    pub const Insert = struct {
        cursor: Cursor,
        text: []const u8,
        source_line: usize,
        index: usize,
        mode: ?InsertMode = null,
        block_start: ?usize = null,
    };

    pub const Delete = struct {
        anchor: Anchor,
        source_line: usize,
        index: usize,
        old_assertion: ?[]const u8 = null,
    };

    pub const Block = struct {
        anchor: Anchor,
        payloads: []const []const u8,
        mode: ?BlockMode = null,
        source_line: usize,
        index: usize,
    };

    pub fn sourceLine(self: Edit) usize {
        return switch (self) {
            .insert => |value| value.source_line,
            .delete => |value| value.source_line,
            .block => |value| value.source_line,
        };
    }

    pub fn anchor(self: Edit) ?Anchor {
        return switch (self) {
            .insert => |value| value.cursor.anchor(),
            .delete => |value| value.anchor,
            .block => |value| value.anchor,
        };
    }
};

pub const FileOp = union(enum) {
    rem,
    move: []const u8,
};

pub const ParsedRange = struct {
    start: Anchor,
    end: Anchor,
};

pub const BlockSpan = struct {
    start: usize,
    end: usize,
};

pub const BlockResolutionOp = enum {
    replace,
    delete,
    insert_after,
};

pub const BlockResolution = struct {
    anchor_line: usize,
    start: usize,
    end: usize,
    op: BlockResolutionOp,
};

pub const BlockResolverRequest = struct {
    path: []const u8,
    text: []const u8,
    line: usize,
};

/// Pluggable block-resolution seam. The default is `null`; callers may inject
/// a tree-sitter-backed implementation in a later layer without coupling this
/// library to a parser dependency.
pub const BlockResolver = struct {
    context: ?*anyopaque = null,
    resolve_fn: *const fn (context: ?*anyopaque, request: BlockResolverRequest) ?BlockSpan,

    pub fn resolve(self: BlockResolver, request: BlockResolverRequest) ?BlockSpan {
        return self.resolve_fn(self.context, request);
    }

    pub fn fromFunction(comptime function: fn (BlockResolverRequest) ?BlockSpan) BlockResolver {
        return .{
            .resolve_fn = struct {
                fn call(_: ?*anyopaque, request: BlockResolverRequest) ?BlockSpan {
                    return function(request);
                }
            }.call,
        };
    }

    pub fn fromContext(
        context: anytype,
        comptime function: fn (@TypeOf(context), BlockResolverRequest) ?BlockSpan,
    ) BlockResolver {
        const Context = @TypeOf(context);
        const pointer_info = @typeInfo(Context).pointer;
        comptime std.debug.assert(pointer_info.size == .one);
        return .{
            .context = @ptrCast(context),
            .resolve_fn = struct {
                fn call(erased: ?*anyopaque, request: BlockResolverRequest) ?BlockSpan {
                    const typed: Context = @ptrCast(@alignCast(erased.?));
                    return function(typed, request);
                }
            }.call,
        };
    }
};

pub const ApplyResult = struct {
    text: []const u8,
    first_changed_line: ?usize = null,
    warnings: []const []const u8 = &.{},
    block_resolutions: []const BlockResolution = &.{},
};

pub const CompactDiffPreview = struct {
    preview: []const u8,
    added_lines: usize,
    removed_lines: usize,
};

pub const FailureKind = enum {
    invalid_input,
    mismatch,
    not_found,
    io,
};

pub const Failure = struct {
    kind: FailureKind = .invalid_input,
    message: []const u8,
};

/// Semantic failures carry allocated, byte-exact model-facing text. Allocation
/// failures remain ordinary Zig errors (`error.OutOfMemory`).
pub fn Outcome(comptime T: type) type {
    return union(enum) {
        success: T,
        failure: Failure,
    };
}

pub fn failure(message: []const u8) Failure {
    return .{ .message = message };
}

pub fn failureKind(kind: FailureKind, message: []const u8) Failure {
    return .{ .kind = kind, .message = message };
}
