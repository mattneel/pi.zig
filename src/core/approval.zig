//! Pure tool-approval policy resolution.
//!
//! `ToolApprovalDecl` is already resolved for the current call. Dynamic tool
//! declarations stay at the caller boundary; this module only applies the
//! upstream mode/user-policy precedence table.

const std = @import("std");

pub const default_prompt_truncate_chars: usize = 2000;

/// Keep approval details bounded using JavaScript string-length semantics.
/// The prefix ends on a complete UTF-8 code point because Zig strings cannot
/// represent the unpaired surrogate that JavaScript may produce at a boundary.
pub fn truncateForPrompt(
    allocator: std.mem.Allocator,
    value: []const u8,
    max_chars: usize,
) ![]const u8 {
    const total_chars = utf16CodeUnits(value);
    if (total_chars <= max_chars) return value;

    var index: usize = 0;
    var chars: usize = 0;
    while (index < value.len) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(value[index]) catch 1;
        if (index + sequence_len > value.len) break;
        const codepoint = std.unicode.utf8Decode(value[index .. index + sequence_len]) catch {
            if (chars + 1 > max_chars) break;
            chars += 1;
            index += 1;
            continue;
        };
        const width: usize = if (codepoint > 0xFFFF) 2 else 1;
        if (chars + width > max_chars) break;
        chars += width;
        index += sequence_len;
    }
    return std.fmt.allocPrint(
        allocator,
        "{s}[…{d}ch elided…]",
        .{ value[0..index], total_chars - max_chars },
    );
}

fn utf16CodeUnits(value: []const u8) usize {
    var index: usize = 0;
    var count: usize = 0;
    while (index < value.len) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(value[index]) catch 1;
        if (index + sequence_len > value.len) return count + value.len - index;
        const codepoint = std.unicode.utf8Decode(value[index .. index + sequence_len]) catch {
            count += 1;
            index += 1;
            continue;
        };
        count += if (codepoint > 0xFFFF) 2 else 1;
        index += sequence_len;
    }
    return count;
}

pub const ToolTier = enum(u2) {
    read,
    write,
    exec,
};

pub const ApprovalMode = enum {
    always_ask,
    write,
    yolo,
};

pub const UserPolicy = enum {
    allow,
    deny,
    prompt,
};

pub const ResolvedDecl = struct {
    tier: ToolTier,
    reason: ?[]const u8 = null,
    override: bool = false,
};

/// Object-form declarations use `.resolved`; simple declarations use `.tier`.
/// String slices are borrowed and must outlive the resolution result.
pub const ToolApprovalDecl = union(enum) {
    tier: ToolTier,
    resolved: ResolvedDecl,

    pub fn decision(self: ToolApprovalDecl) ResolvedDecl {
        return switch (self) {
            .tier => |tier| .{ .tier = tier },
            .resolved => |resolved| resolved,
        };
    }
};

pub const Prompt = struct {
    reason: ?[]const u8 = null,
};

pub const Resolution = union(enum) {
    allow,
    deny,
    prompt: Prompt,
};

/// Resolve a call in the exact order documented by upstream:
/// yolo first, then non-yolo safety override, then user policy, then tier.
pub fn resolve(
    decl: ToolApprovalDecl,
    mode: ApprovalMode,
    user_policy: ?UserPolicy,
) Resolution {
    const resolved = decl.decision();

    if (mode == .yolo) {
        return policyResolution(user_policy orelse .allow, null);
    }

    if (resolved.override) {
        if (user_policy == .deny) return .deny;
        return .{ .prompt = .{ .reason = resolved.reason } };
    }

    if (user_policy) |policy| return policyResolution(policy, null);

    if (modeApprovesTier(mode, resolved.tier)) return .allow;
    return .{ .prompt = .{ .reason = resolved.reason } };
}

fn policyResolution(policy: UserPolicy, reason: ?[]const u8) Resolution {
    return switch (policy) {
        .allow => .allow,
        .deny => .deny,
        .prompt => .{ .prompt = .{ .reason = reason } },
    };
}

fn modeApprovesTier(mode: ApprovalMode, tier: ToolTier) bool {
    const maximum: ToolTier = switch (mode) {
        .always_ask => .read,
        .write => .write,
        .yolo => .exec,
    };
    return @intFromEnum(tier) <= @intFromEnum(maximum);
}

fn expectedResolution(
    tier: ToolTier,
    mode: ApprovalMode,
    user_policy: ?UserPolicy,
    has_override: bool,
) Resolution {
    if (mode == .yolo) {
        return switch (user_policy orelse .allow) {
            .allow => .allow,
            .deny => .deny,
            .prompt => .{ .prompt = .{} },
        };
    }
    if (has_override) {
        if (user_policy == .deny) return .deny;
        return .{ .prompt = .{ .reason = "safety" } };
    }
    if (user_policy) |policy| {
        return switch (policy) {
            .allow => .allow,
            .deny => .deny,
            .prompt => .{ .prompt = .{} },
        };
    }
    const default_allow = switch (mode) {
        .always_ask => tier == .read,
        .write => tier != .exec,
        .yolo => true,
    };
    if (default_allow) return .allow;
    return .{ .prompt = .{ .reason = "safety" } };
}

test "approval full tier mode policy override matrix" {
    const tiers = [_]ToolTier{ .read, .write, .exec };
    const modes = [_]ApprovalMode{ .always_ask, .write, .yolo };
    const policies = [_]?UserPolicy{ null, .allow, .deny, .prompt };
    const overrides = [_]bool{ false, true };

    var cases: usize = 0;
    for (tiers) |tier| {
        for (modes) |mode| {
            for (policies) |policy| {
                for (overrides) |has_override| {
                    const decl: ToolApprovalDecl = .{ .resolved = .{
                        .tier = tier,
                        .reason = "safety",
                        .override = has_override,
                    } };
                    try std.testing.expectEqualDeep(
                        expectedResolution(tier, mode, policy, has_override),
                        resolve(decl, mode, policy),
                    );
                    cases += 1;
                }
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 3 * 3 * 4 * 2), cases);
}

test "approval simple tier declarations carry no prompt reason" {
    const result = resolve(.{ .tier = .exec }, .write, null);
    try std.testing.expectEqualDeep(
        Resolution{ .prompt = .{} },
        result,
    );
}
