//! Upstream-compatible v3 session wire records.
//!
//! Parsed values are arena-owned: every string and arbitrary JSON subtree is
//! copied into the allocator passed to `parse*`/`parse*Value`. Manually
//! constructed values borrow their slices. Serialization never takes ownership.
//! Session storage, tree indexing, migrations, and collision handling live in
//! later phases.

const std = @import("std");
const agent_message = @import("../core/message.zig");

const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;
const JsonObject = std.json.ObjectMap;

pub const CURRENT_SESSION_VERSION: u32 = 3;
pub const SESSION_TITLE_SLOT_BYTES: usize = 256;
pub const SESSION_TITLE_SLOT_ENTRY_TYPE = "title";
pub const TITLE_CHANGE_ENTRY_TYPE = "title_change";
pub const EPHEMERAL_MODEL_CHANGE_ROLE = "fallback";

pub const SessionTitleSlotType = enum { title };
pub const SessionHeaderType = enum { session };

pub const SessionTitleSource = enum {
    auto,
    user,
};

pub const MessageAttribution = enum {
    user,
    agent,
};

pub const ServiceTier = enum {
    auto,
    default,
    flex,
    scale,
    priority,
};

/// Current persisted service-tier representation. The containing entry keeps
/// this nullable because `null` means that no family has an active tier.
pub const ServiceTierByFamily = struct {
    openai: ?ServiceTier = null,
    anthropic: ?ServiceTier = null,
    google: ?ServiceTier = null,

    pub fn jsonStringify(self: ServiceTierByFamily, jw: anytype) !void {
        try jw.beginObject();
        if (self.openai) |value| try writeField(jw, "openai", value);
        if (self.anthropic) |value| try writeField(jw, "anthropic", value);
        if (self.google) |value| try writeField(jw, "google", value);
        try jw.endObject();
    }
};

/// Fixed-width physical line zero. Use `serializeTitleSlotAlloc` to produce the
/// required 256 UTF-8 bytes including the trailing newline.
pub const SessionTitleSlotEntry = struct {
    type: SessionTitleSlotType = .title,
    v: u8 = 1,
    title: []const u8,
    source: ?SessionTitleSource = null,
    updatedAt: []const u8,
    pad: []const u8,

    pub fn jsonStringify(self: SessionTitleSlotEntry, jw: anytype) !void {
        try jw.beginObject();
        try writeField(jw, "type", self.type);
        try writeField(jw, "v", self.v);
        try writeField(jw, "title", self.title);
        if (self.source) |source| try writeField(jw, "source", source);
        try writeField(jw, "updatedAt", self.updatedAt);
        try writeField(jw, "pad", self.pad);
        try jw.endObject();
    }
};

pub const SessionHeader = struct {
    type: SessionHeaderType = .session,
    version: ?u32 = CURRENT_SESSION_VERSION,
    id: []const u8,
    title: ?[]const u8 = null,
    titleSource: ?SessionTitleSource = null,
    timestamp: []const u8,
    cwd: []const u8,
    parentSession: ?[]const u8 = null,
    providerPromptCacheKey: ?[]const u8 = null,

    pub fn jsonStringify(self: SessionHeader, jw: anytype) !void {
        try jw.beginObject();
        try writeField(jw, "type", self.type);
        if (self.version) |version| try writeField(jw, "version", version);
        try writeField(jw, "id", self.id);
        if (self.title) |title| try writeField(jw, "title", title);
        if (self.titleSource) |source| try writeField(jw, "titleSource", source);
        try writeField(jw, "timestamp", self.timestamp);
        try writeField(jw, "cwd", self.cwd);
        if (self.parentSession) |parent| try writeField(jw, "parentSession", parent);
        if (self.providerPromptCacheKey) |key| try writeField(jw, "providerPromptCacheKey", key);
        try jw.endObject();
    }
};

pub const SessionEntryType = enum {
    message,
    thinking_level_change,
    model_change,
    service_tier_change,
    compaction,
    branch_summary,
    custom,
    custom_message,
    label,
    title_change,
    ttsr_injection,
    mcp_tool_selection,
    session_init,
    mode_change,
    unknown,
};

pub const EntryEnvelope = struct {
    type: SessionEntryType,
    id: []const u8,
    parentId: ?[]const u8,
    timestamp: []const u8,
};

/// Optional-and-nullable string used by thinking selector records. `absent`
/// models old entries without a field; `null_value` models current writes that
/// explicitly persist an unset selector as JSON null.
pub const NullableStringField = union(enum) {
    absent,
    null_value,
    value: []const u8,
};

pub const MessageEntry = struct {
    id: []const u8,
    parentId: ?[]const u8,
    timestamp: []const u8,
    message: agent_message.AgentMessage,
};

pub const ThinkingLevelChangeEntry = struct {
    id: []const u8,
    parentId: ?[]const u8,
    timestamp: []const u8,
    thinkingLevel: NullableStringField = .absent,
    configured: NullableStringField = .absent,
};

pub const ModelChangeEntry = struct {
    id: []const u8,
    parentId: ?[]const u8,
    timestamp: []const u8,
    model: []const u8,
    role: ?[]const u8 = null,
};

pub const ServiceTierChangeEntry = struct {
    id: []const u8,
    parentId: ?[]const u8,
    timestamp: []const u8,
    serviceTier: ?ServiceTierByFamily,
};

pub const CompactionEntry = struct {
    id: []const u8,
    parentId: ?[]const u8,
    timestamp: []const u8,
    summary: []const u8,
    shortSummary: ?[]const u8 = null,
    firstKeptEntryId: []const u8,
    tokensBefore: u64,
    details: ?JsonValue = null,
    preserveData: ?JsonValue = null,
    fromExtension: ?bool = null,
};

pub const BranchSummaryEntry = struct {
    id: []const u8,
    parentId: ?[]const u8,
    timestamp: []const u8,
    fromId: []const u8,
    summary: []const u8,
    details: ?JsonValue = null,
    fromExtension: ?bool = null,
};

pub const CustomEntry = struct {
    id: []const u8,
    parentId: ?[]const u8,
    timestamp: []const u8,
    customType: []const u8,
    data: ?JsonValue = null,
};

pub const CustomMessageEntry = struct {
    id: []const u8,
    parentId: ?[]const u8,
    timestamp: []const u8,
    customType: []const u8,
    content: agent_message.TextImageContent,
    display: bool,
    details: ?JsonValue = null,
    attribution: ?MessageAttribution = null,
};

pub const LabelEntry = struct {
    id: []const u8,
    parentId: ?[]const u8,
    timestamp: []const u8,
    targetId: []const u8,
    /// An omitted label clears the effective label for `targetId` upstream.
    label: ?[]const u8 = null,
};

pub const TitleChangeEntry = struct {
    id: []const u8,
    parentId: ?[]const u8,
    timestamp: []const u8,
    title: []const u8,
    previousTitle: ?[]const u8 = null,
    source: SessionTitleSource,
    trigger: ?[]const u8 = null,
};

pub const TtsrInjectionEntry = struct {
    id: []const u8,
    parentId: ?[]const u8,
    timestamp: []const u8,
    injectedRules: []const []const u8,
};

pub const McpToolSelectionEntry = struct {
    id: []const u8,
    parentId: ?[]const u8,
    timestamp: []const u8,
    selectedToolNames: []const []const u8,
};

pub const SessionInitEntry = struct {
    id: []const u8,
    parentId: ?[]const u8,
    timestamp: []const u8,
    systemPrompt: []const u8,
    task: []const u8,
    tools: []const []const u8,
    outputSchema: ?JsonValue = null,
    spawns: ?[]const u8 = null,
    readSummarize: ?bool = null,
};

pub const ModeChangeEntry = struct {
    id: []const u8,
    parentId: ?[]const u8,
    timestamp: []const u8,
    mode: []const u8,
    data: ?JsonValue = null,
};

pub const UnknownEntry = struct {
    id: []const u8,
    parentId: ?[]const u8,
    timestamp: []const u8,
    raw: JsonValue,
};

pub const SessionEntry = union(SessionEntryType) {
    message: MessageEntry,
    thinking_level_change: ThinkingLevelChangeEntry,
    model_change: ModelChangeEntry,
    service_tier_change: ServiceTierChangeEntry,
    compaction: CompactionEntry,
    branch_summary: BranchSummaryEntry,
    custom: CustomEntry,
    custom_message: CustomMessageEntry,
    label: LabelEntry,
    title_change: TitleChangeEntry,
    ttsr_injection: TtsrInjectionEntry,
    mcp_tool_selection: McpToolSelectionEntry,
    session_init: SessionInitEntry,
    mode_change: ModeChangeEntry,
    unknown: UnknownEntry,

    pub fn envelope(self: SessionEntry) EntryEnvelope {
        return switch (self) {
            .unknown => |entry| .{
                .type = .unknown,
                .id = entry.id,
                .parentId = entry.parentId,
                .timestamp = entry.timestamp,
            },
            inline else => |entry| .{
                .type = std.meta.activeTag(self),
                .id = entry.id,
                .parentId = entry.parentId,
                .timestamp = entry.timestamp,
            },
        };
    }

    pub fn jsonStringify(self: SessionEntry, jw: anytype) !void {
        switch (self) {
            .unknown => |entry| return jw.write(entry.raw),
            else => {},
        }
        try jw.beginObject();
        switch (self) {
            .message => |entry| {
                try writeEntryEnvelope(jw, "message", entry.id, entry.parentId, entry.timestamp);
                try jw.objectField("message");
                try agent_message.write(entry.message, jw);
            },
            .thinking_level_change => |entry| {
                try writeEntryEnvelope(jw, "thinking_level_change", entry.id, entry.parentId, entry.timestamp);
                try writeNullableStringField(jw, "thinkingLevel", entry.thinkingLevel);
                try writeNullableStringField(jw, "configured", entry.configured);
            },
            .model_change => |entry| {
                try writeEntryEnvelope(jw, "model_change", entry.id, entry.parentId, entry.timestamp);
                try writeField(jw, "model", entry.model);
                if (entry.role) |role| try writeField(jw, "role", role);
            },
            .service_tier_change => |entry| {
                try writeEntryEnvelope(jw, "service_tier_change", entry.id, entry.parentId, entry.timestamp);
                try jw.objectField("serviceTier");
                if (entry.serviceTier) |tiers| {
                    try jw.write(tiers);
                } else {
                    try jw.write(null);
                }
            },
            .compaction => |entry| {
                try writeEntryEnvelope(jw, "compaction", entry.id, entry.parentId, entry.timestamp);
                try writeField(jw, "summary", entry.summary);
                if (entry.shortSummary) |summary| try writeField(jw, "shortSummary", summary);
                try writeField(jw, "firstKeptEntryId", entry.firstKeptEntryId);
                try writeField(jw, "tokensBefore", entry.tokensBefore);
                if (entry.details) |details| try writeField(jw, "details", details);
                if (entry.preserveData) |data| try writeField(jw, "preserveData", data);
                if (entry.fromExtension) |value| try writeField(jw, "fromExtension", value);
            },
            .branch_summary => |entry| {
                try writeEntryEnvelope(jw, "branch_summary", entry.id, entry.parentId, entry.timestamp);
                try writeField(jw, "fromId", entry.fromId);
                try writeField(jw, "summary", entry.summary);
                if (entry.details) |details| try writeField(jw, "details", details);
                if (entry.fromExtension) |value| try writeField(jw, "fromExtension", value);
            },
            .custom => |entry| {
                try writeEntryEnvelope(jw, "custom", entry.id, entry.parentId, entry.timestamp);
                try writeField(jw, "customType", entry.customType);
                if (entry.data) |data| try writeField(jw, "data", data);
            },
            .custom_message => |entry| {
                try writeEntryEnvelope(jw, "custom_message", entry.id, entry.parentId, entry.timestamp);
                try writeField(jw, "customType", entry.customType);
                try jw.objectField("content");
                try entry.content.wireWrite(jw);
                try writeField(jw, "display", entry.display);
                if (entry.details) |details| try writeField(jw, "details", details);
                if (entry.attribution) |attribution| try writeField(jw, "attribution", attribution);
            },
            .label => |entry| {
                try writeEntryEnvelope(jw, "label", entry.id, entry.parentId, entry.timestamp);
                try writeField(jw, "targetId", entry.targetId);
                if (entry.label) |label| try writeField(jw, "label", label);
            },
            .title_change => |entry| {
                try writeEntryEnvelope(jw, TITLE_CHANGE_ENTRY_TYPE, entry.id, entry.parentId, entry.timestamp);
                try writeField(jw, "title", entry.title);
                if (entry.previousTitle) |title| try writeField(jw, "previousTitle", title);
                try writeField(jw, "source", entry.source);
                if (entry.trigger) |trigger| try writeField(jw, "trigger", trigger);
            },
            .ttsr_injection => |entry| {
                try writeEntryEnvelope(jw, "ttsr_injection", entry.id, entry.parentId, entry.timestamp);
                try writeField(jw, "injectedRules", entry.injectedRules);
            },
            .mcp_tool_selection => |entry| {
                try writeEntryEnvelope(jw, "mcp_tool_selection", entry.id, entry.parentId, entry.timestamp);
                try writeField(jw, "selectedToolNames", entry.selectedToolNames);
            },
            .session_init => |entry| {
                try writeEntryEnvelope(jw, "session_init", entry.id, entry.parentId, entry.timestamp);
                try writeField(jw, "systemPrompt", entry.systemPrompt);
                try writeField(jw, "task", entry.task);
                try writeField(jw, "tools", entry.tools);
                if (entry.outputSchema) |schema| try writeField(jw, "outputSchema", schema);
                if (entry.spawns) |spawns| try writeField(jw, "spawns", spawns);
                if (entry.readSummarize) |value| try writeField(jw, "readSummarize", value);
            },
            .mode_change => |entry| {
                try writeEntryEnvelope(jw, "mode_change", entry.id, entry.parentId, entry.timestamp);
                try writeField(jw, "mode", entry.mode);
                if (entry.data) |data| try writeField(jw, "data", data);
            },
            .unknown => unreachable,
        }
        try jw.endObject();
    }
};

pub const FileEntry = union(enum) {
    session: SessionHeader,
    entry: SessionEntry,

    pub fn jsonStringify(self: FileEntry, jw: anytype) !void {
        switch (self) {
            .session => |header| try jw.write(header),
            .entry => |entry| try jw.write(entry),
        }
    }
};

pub const RawFileEntry = union(enum) {
    title: SessionTitleSlotEntry,
    session: SessionHeader,
    entry: SessionEntry,

    pub fn jsonStringify(self: RawFileEntry, jw: anytype) !void {
        switch (self) {
            .title => |slot| try jw.write(slot),
            .session => |header| try jw.write(header),
            .entry => |entry| try jw.write(entry),
        }
    }
};

/// Generate the upstream short entry ID: the final eight lowercase hex
/// characters of a UUIDv4. The future store must collision-check and retry.
pub fn generateId(allocator: Allocator, random: std.Random) Allocator.Error![]u8 {
    var uuid: [16]u8 = undefined;
    random.bytes(&uuid);
    uuid[6] = (uuid[6] & 0x0f) | 0x40;
    uuid[8] = (uuid[8] & 0x3f) | 0x80;
    const suffix = idSuffixFromUuidBytes(uuid);
    return allocator.dupe(u8, &suffix);
}

pub fn idSuffixFromUuidBytes(uuid: [16]u8) [8]u8 {
    const hex = "0123456789abcdef";
    var result: [8]u8 = undefined;
    for (uuid[12..16], 0..) |byte, index| {
        result[index * 2] = hex[byte >> 4];
        result[index * 2 + 1] = hex[byte & 0x0f];
    }
    return result;
}

pub fn stringifyEntryAlloc(allocator: Allocator, entry: SessionEntry) ![]u8 {
    return stringifyAlloc(allocator, entry);
}

pub fn stringifyHeaderAlloc(allocator: Allocator, header: SessionHeader) ![]u8 {
    return stringifyAlloc(allocator, header);
}

pub fn stringifyRawFileEntryAlloc(allocator: Allocator, entry: RawFileEntry) ![]u8 {
    return stringifyAlloc(allocator, entry);
}

pub fn parseEntry(arena: Allocator, json_text: []const u8) !SessionEntry {
    const value = try std.json.parseFromSliceLeaky(JsonValue, arena, json_text, .{
        .allocate = .alloc_always,
    });
    return parseEntryValue(arena, value);
}

pub fn parseHeader(arena: Allocator, json_text: []const u8) !SessionHeader {
    const value = try std.json.parseFromSliceLeaky(JsonValue, arena, json_text, .{
        .allocate = .alloc_always,
    });
    return parseHeaderValue(arena, value);
}

pub fn parseRawFileEntry(arena: Allocator, json_text: []const u8) !RawFileEntry {
    const value = try std.json.parseFromSliceLeaky(JsonValue, arena, json_text, .{
        .allocate = .alloc_always,
    });
    return parseRawFileEntryValue(arena, value);
}

pub fn parseRawFileEntryValue(arena: Allocator, value: JsonValue) !RawFileEntry {
    const object = try expectObject(value);
    const entry_type = try requiredStringBorrowed(object, "type");
    if (std.mem.eql(u8, entry_type, SESSION_TITLE_SLOT_ENTRY_TYPE)) {
        return .{ .title = try parseTitleSlotValue(arena, value) };
    }
    if (std.mem.eql(u8, entry_type, "session")) {
        return .{ .session = try parseHeaderValue(arena, value) };
    }
    return .{ .entry = try parseEntryValue(arena, value) };
}

pub fn parseHeaderValue(arena: Allocator, value: JsonValue) !SessionHeader {
    const object = try expectObject(value);
    try expectType(object, "session");
    return .{
        .version = try optionalU32(object, "version"),
        .id = try requiredString(arena, object, "id"),
        .title = try optionalString(arena, object, "title"),
        .titleSource = try optionalTitleSource(object, "titleSource"),
        .timestamp = try requiredString(arena, object, "timestamp"),
        .cwd = try requiredString(arena, object, "cwd"),
        .parentSession = try optionalString(arena, object, "parentSession"),
        .providerPromptCacheKey = try optionalString(arena, object, "providerPromptCacheKey"),
    };
}

pub fn parseTitleSlot(arena: Allocator, json_text: []const u8) !SessionTitleSlotEntry {
    const value = try std.json.parseFromSliceLeaky(JsonValue, arena, json_text, .{
        .allocate = .alloc_always,
    });
    return parseTitleSlotValue(arena, value);
}

pub fn parseTitleSlotValue(arena: Allocator, value: JsonValue) !SessionTitleSlotEntry {
    const object = try expectObject(value);
    try expectType(object, SESSION_TITLE_SLOT_ENTRY_TYPE);
    const version = try requiredU64(object, "v");
    if (version != 1) return error.InvalidEnumTag;
    return .{
        .title = try requiredString(arena, object, "title"),
        .source = try optionalTitleSource(object, "source"),
        .updatedAt = try requiredString(arena, object, "updatedAt"),
        .pad = try requiredString(arena, object, "pad"),
    };
}

/// Serialize the mutable title record exactly as upstream: 256 UTF-8 bytes,
/// including its newline. Overlong titles are truncated on code-point
/// boundaries before space padding is calculated.
pub fn serializeTitleSlotAlloc(
    allocator: Allocator,
    title: []const u8,
    source: ?SessionTitleSource,
    updated_at: []const u8,
) ![]u8 {
    if (!std.unicode.utf8ValidateSlice(title)) return error.InvalidUtf8;

    const codepoint_count = try std.unicode.utf8CountCodepoints(title);
    var low: usize = 0;
    var high: usize = codepoint_count;
    var best_byte_len: usize = 0;

    while (low <= high) {
        const middle = low + (high - low) / 2;
        const byte_len = utf8PrefixByteLen(title, middle);
        const candidate = SessionTitleSlotEntry{
            .title = title[0..byte_len],
            .source = source,
            .updatedAt = updated_at,
            .pad = "",
        };
        const encoded = try stringifyAlloc(allocator, candidate);
        defer allocator.free(encoded);
        if (encoded.len + 1 <= SESSION_TITLE_SLOT_BYTES) {
            best_byte_len = byte_len;
            low = middle + 1;
        } else if (middle == 0) {
            break;
        } else {
            high = middle - 1;
        }
    }

    const unpadded = try stringifyAlloc(allocator, SessionTitleSlotEntry{
        .title = title[0..best_byte_len],
        .source = source,
        .updatedAt = updated_at,
        .pad = "",
    });
    defer allocator.free(unpadded);
    if (unpadded.len + 1 > SESSION_TITLE_SLOT_BYTES) return error.TitleSlotMetadataTooLarge;

    const pad_len = SESSION_TITLE_SLOT_BYTES - (unpadded.len + 1);
    const pad = try allocator.alloc(u8, pad_len);
    defer allocator.free(pad);
    @memset(pad, ' ');

    const encoded = try stringifyAlloc(allocator, SessionTitleSlotEntry{
        .title = title[0..best_byte_len],
        .source = source,
        .updatedAt = updated_at,
        .pad = pad,
    });
    defer allocator.free(encoded);
    if (encoded.len + 1 != SESSION_TITLE_SLOT_BYTES) return error.TitleSlotSerializationFailed;

    const result = try allocator.alloc(u8, SESSION_TITLE_SLOT_BYTES);
    @memcpy(result[0..encoded.len], encoded);
    result[encoded.len] = '\n';
    return result;
}

pub fn parseEntryValue(arena: Allocator, value: JsonValue) !SessionEntry {
    const object = try expectObject(value);
    const entry_type = try requiredStringBorrowed(object, "type");
    const id = try requiredString(arena, object, "id");
    const parent_id = try requiredNullableString(arena, object, "parentId");
    const timestamp = try requiredString(arena, object, "timestamp");

    if (std.mem.eql(u8, entry_type, "message")) {
        return .{ .message = .{
            .id = id,
            .parentId = parent_id,
            .timestamp = timestamp,
            .message = try agent_message.parseValue(arena, try requiredValue(object, "message")),
        } };
    }
    if (std.mem.eql(u8, entry_type, "thinking_level_change")) {
        return .{ .thinking_level_change = .{
            .id = id,
            .parentId = parent_id,
            .timestamp = timestamp,
            .thinkingLevel = try nullableStringField(arena, object, "thinkingLevel"),
            .configured = try nullableStringField(arena, object, "configured"),
        } };
    }
    if (std.mem.eql(u8, entry_type, "model_change")) {
        return .{ .model_change = .{
            .id = id,
            .parentId = parent_id,
            .timestamp = timestamp,
            .model = try requiredString(arena, object, "model"),
            .role = try optionalString(arena, object, "role"),
        } };
    }
    if (std.mem.eql(u8, entry_type, "service_tier_change")) {
        return .{ .service_tier_change = .{
            .id = id,
            .parentId = parent_id,
            .timestamp = timestamp,
            .serviceTier = try requiredServiceTiers(object, "serviceTier"),
        } };
    }
    if (std.mem.eql(u8, entry_type, "compaction")) {
        return .{ .compaction = .{
            .id = id,
            .parentId = parent_id,
            .timestamp = timestamp,
            .summary = try requiredString(arena, object, "summary"),
            .shortSummary = try optionalString(arena, object, "shortSummary"),
            .firstKeptEntryId = try requiredString(arena, object, "firstKeptEntryId"),
            .tokensBefore = try requiredU64(object, "tokensBefore"),
            .details = try optionalJson(arena, object, "details"),
            .preserveData = try optionalJson(arena, object, "preserveData"),
            .fromExtension = try optionalBool(object, "fromExtension"),
        } };
    }
    if (std.mem.eql(u8, entry_type, "branch_summary")) {
        return .{ .branch_summary = .{
            .id = id,
            .parentId = parent_id,
            .timestamp = timestamp,
            .fromId = try requiredString(arena, object, "fromId"),
            .summary = try requiredString(arena, object, "summary"),
            .details = try optionalJson(arena, object, "details"),
            .fromExtension = try optionalBool(object, "fromExtension"),
        } };
    }
    if (std.mem.eql(u8, entry_type, "custom")) {
        return .{ .custom = .{
            .id = id,
            .parentId = parent_id,
            .timestamp = timestamp,
            .customType = try requiredString(arena, object, "customType"),
            .data = try optionalJson(arena, object, "data"),
        } };
    }
    if (std.mem.eql(u8, entry_type, "custom_message")) {
        return .{ .custom_message = .{
            .id = id,
            .parentId = parent_id,
            .timestamp = timestamp,
            .customType = try requiredString(arena, object, "customType"),
            .content = try agent_message.TextImageContent.wireParse(
                arena,
                try requiredValue(object, "content"),
            ),
            .display = try requiredBool(object, "display"),
            .details = try optionalJson(arena, object, "details"),
            .attribution = try optionalAttribution(object, "attribution"),
        } };
    }
    if (std.mem.eql(u8, entry_type, "label")) {
        return .{ .label = .{
            .id = id,
            .parentId = parent_id,
            .timestamp = timestamp,
            .targetId = try requiredString(arena, object, "targetId"),
            .label = try optionalString(arena, object, "label"),
        } };
    }
    if (std.mem.eql(u8, entry_type, TITLE_CHANGE_ENTRY_TYPE)) {
        return .{ .title_change = .{
            .id = id,
            .parentId = parent_id,
            .timestamp = timestamp,
            .title = try requiredString(arena, object, "title"),
            .previousTitle = try optionalString(arena, object, "previousTitle"),
            .source = try requiredTitleSource(object, "source"),
            .trigger = try optionalString(arena, object, "trigger"),
        } };
    }
    if (std.mem.eql(u8, entry_type, "ttsr_injection")) {
        return .{ .ttsr_injection = .{
            .id = id,
            .parentId = parent_id,
            .timestamp = timestamp,
            .injectedRules = try requiredStringArray(arena, object, "injectedRules"),
        } };
    }
    if (std.mem.eql(u8, entry_type, "mcp_tool_selection")) {
        return .{ .mcp_tool_selection = .{
            .id = id,
            .parentId = parent_id,
            .timestamp = timestamp,
            .selectedToolNames = try requiredStringArray(arena, object, "selectedToolNames"),
        } };
    }
    if (std.mem.eql(u8, entry_type, "session_init")) {
        return .{ .session_init = .{
            .id = id,
            .parentId = parent_id,
            .timestamp = timestamp,
            .systemPrompt = try requiredString(arena, object, "systemPrompt"),
            .task = try requiredString(arena, object, "task"),
            .tools = try requiredStringArray(arena, object, "tools"),
            .outputSchema = try optionalJson(arena, object, "outputSchema"),
            .spawns = try optionalString(arena, object, "spawns"),
            .readSummarize = try optionalBool(object, "readSummarize"),
        } };
    }
    if (std.mem.eql(u8, entry_type, "mode_change")) {
        return .{ .mode_change = .{
            .id = id,
            .parentId = parent_id,
            .timestamp = timestamp,
            .mode = try requiredString(arena, object, "mode"),
            .data = try optionalJson(arena, object, "data"),
        } };
    }
    return .{ .unknown = .{
        .id = id,
        .parentId = parent_id,
        .timestamp = timestamp,
        .raw = try cloneJsonValue(arena, value),
    } };
}

fn stringifyAlloc(allocator: Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{
        .emit_null_optional_fields = false,
    });
}

fn writeField(jw: anytype, name: []const u8, value: anytype) !void {
    try jw.objectField(name);
    try jw.write(value);
}

fn writeEntryEnvelope(
    jw: anytype,
    entry_type: []const u8,
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
) !void {
    try writeField(jw, "type", entry_type);
    try writeField(jw, "id", id);
    try jw.objectField("parentId");
    if (parent_id) |parent| {
        try jw.write(parent);
    } else {
        try jw.write(null);
    }
    try writeField(jw, "timestamp", timestamp);
}

fn writeNullableStringField(jw: anytype, name: []const u8, field: NullableStringField) !void {
    switch (field) {
        .absent => {},
        .null_value => {
            try jw.objectField(name);
            try jw.write(null);
        },
        .value => |value| try writeField(jw, name, value),
    }
}

fn expectObject(value: JsonValue) !JsonObject {
    return switch (value) {
        .object => |object| object,
        else => error.UnexpectedToken,
    };
}

fn expectType(object: JsonObject, expected: []const u8) !void {
    const actual = try requiredStringBorrowed(object, "type");
    if (!std.mem.eql(u8, actual, expected)) return error.InvalidEnumTag;
}

fn requiredValue(object: JsonObject, name: []const u8) !JsonValue {
    return object.get(name) orelse error.MissingField;
}

fn requiredStringBorrowed(object: JsonObject, name: []const u8) ![]const u8 {
    return switch (try requiredValue(object, name)) {
        .string => |value| value,
        else => error.UnexpectedToken,
    };
}

fn requiredString(arena: Allocator, object: JsonObject, name: []const u8) ![]const u8 {
    return arena.dupe(u8, try requiredStringBorrowed(object, name));
}

fn optionalString(arena: Allocator, object: JsonObject, name: []const u8) !?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| try arena.dupe(u8, text),
        else => error.UnexpectedToken,
    };
}

fn requiredNullableString(arena: Allocator, object: JsonObject, name: []const u8) !?[]const u8 {
    return switch (try requiredValue(object, name)) {
        .null => null,
        .string => |text| try arena.dupe(u8, text),
        else => error.UnexpectedToken,
    };
}

fn nullableStringField(arena: Allocator, object: JsonObject, name: []const u8) !NullableStringField {
    const value = object.get(name) orelse return .absent;
    return switch (value) {
        .null => .null_value,
        .string => |text| .{ .value = try arena.dupe(u8, text) },
        else => error.UnexpectedToken,
    };
}

fn requiredBool(object: JsonObject, name: []const u8) !bool {
    return switch (try requiredValue(object, name)) {
        .bool => |value| value,
        else => error.UnexpectedToken,
    };
}

fn optionalBool(object: JsonObject, name: []const u8) !?bool {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .bool => |boolean| boolean,
        else => error.UnexpectedToken,
    };
}

fn requiredU64(object: JsonObject, name: []const u8) !u64 {
    return switch (try requiredValue(object, name)) {
        .integer => |value| if (value >= 0) @intCast(value) else error.Overflow,
        else => error.UnexpectedToken,
    };
}

fn optionalU32(object: JsonObject, name: []const u8) !?u32 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |integer| if (integer >= 0 and integer <= std.math.maxInt(u32))
            @intCast(integer)
        else
            error.Overflow,
        else => error.UnexpectedToken,
    };
}

fn optionalJson(arena: Allocator, object: JsonObject, name: []const u8) !?JsonValue {
    const value = object.get(name) orelse return null;
    return try cloneJsonValue(arena, value);
}

fn requiredStringArray(arena: Allocator, object: JsonObject, name: []const u8) ![]const []const u8 {
    const array = switch (try requiredValue(object, name)) {
        .array => |value| value,
        else => return error.UnexpectedToken,
    };
    const result = try arena.alloc([]const u8, array.items.len);
    for (array.items, result) |item, *destination| {
        destination.* = switch (item) {
            .string => |text| try arena.dupe(u8, text),
            else => return error.UnexpectedToken,
        };
    }
    return result;
}

fn parseTitleSource(value: JsonValue) !SessionTitleSource {
    const text = switch (value) {
        .string => |item| item,
        else => return error.UnexpectedToken,
    };
    if (std.mem.eql(u8, text, "auto")) return .auto;
    if (std.mem.eql(u8, text, "user")) return .user;
    return error.InvalidEnumTag;
}

fn requiredTitleSource(object: JsonObject, name: []const u8) !SessionTitleSource {
    return parseTitleSource(try requiredValue(object, name));
}

fn optionalTitleSource(object: JsonObject, name: []const u8) !?SessionTitleSource {
    const value = object.get(name) orelse return null;
    return try parseTitleSource(value);
}

fn optionalAttribution(object: JsonObject, name: []const u8) !?MessageAttribution {
    const value = object.get(name) orelse return null;
    const text = switch (value) {
        .string => |item| item,
        else => return error.UnexpectedToken,
    };
    if (std.mem.eql(u8, text, "user")) return .user;
    if (std.mem.eql(u8, text, "agent")) return .agent;
    return error.InvalidEnumTag;
}

fn parseServiceTier(value: JsonValue) !ServiceTier {
    const text = switch (value) {
        .string => |item| item,
        else => return error.UnexpectedToken,
    };
    if (std.mem.eql(u8, text, "auto")) return .auto;
    if (std.mem.eql(u8, text, "default")) return .default;
    if (std.mem.eql(u8, text, "flex")) return .flex;
    if (std.mem.eql(u8, text, "scale")) return .scale;
    if (std.mem.eql(u8, text, "priority")) return .priority;
    return error.InvalidEnumTag;
}

fn requiredServiceTiers(object: JsonObject, name: []const u8) !?ServiceTierByFamily {
    const value = try requiredValue(object, name);
    if (value == .null) return null;
    const tiers = try expectObject(value);
    return .{
        .openai = if (tiers.get("openai")) |tier| try parseServiceTier(tier) else null,
        .anthropic = if (tiers.get("anthropic")) |tier| try parseServiceTier(tier) else null,
        .google = if (tiers.get("google")) |tier| try parseServiceTier(tier) else null,
    };
}

fn cloneJsonValue(arena: Allocator, value: JsonValue) !JsonValue {
    return switch (value) {
        .null => .null,
        .bool => |item| .{ .bool = item },
        .integer => |item| .{ .integer = item },
        .float => |item| .{ .float = item },
        .number_string => |item| .{ .number_string = try arena.dupe(u8, item) },
        .string => |item| .{ .string = try arena.dupe(u8, item) },
        .array => |item| blk: {
            var array = std.json.Array.init(arena);
            for (item.items) |element| try array.append(try cloneJsonValue(arena, element));
            break :blk .{ .array = array };
        },
        .object => |item| blk: {
            var object: JsonObject = .empty;
            var iterator = item.iterator();
            while (iterator.next()) |entry| {
                try object.put(
                    arena,
                    try arena.dupe(u8, entry.key_ptr.*),
                    try cloneJsonValue(arena, entry.value_ptr.*),
                );
            }
            break :blk .{ .object = object };
        },
    };
}

fn utf8PrefixByteLen(text: []const u8, codepoint_count: usize) usize {
    var index: usize = 0;
    var count: usize = 0;
    while (count < codepoint_count) : (count += 1) {
        index += std.unicode.utf8ByteSequenceLength(text[index]) catch unreachable;
    }
    return index;
}

test "session id uses final eight lowercase UUID hex characters" {
    const uuid = [_]u8{
        0x12, 0x34, 0x56, 0x78,
        0x9a, 0xbc, 0x4d, 0xef,
        0x8a, 0xbc, 0xde, 0xf0,
        0x01, 0x23, 0xab, 0xcd,
    };
    try std.testing.expectEqualStrings("0123abcd", &idSuffixFromUuidBytes(uuid));

    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const generated = try generateId(std.testing.allocator, prng.random());
    defer std.testing.allocator.free(generated);
    try std.testing.expectEqual(@as(usize, 8), generated.len);
    for (generated) |byte| try std.testing.expect(std.ascii.isHex(byte) and !std.ascii.isUpper(byte));
}

test "session title slot is exactly 256 UTF-8 bytes" {
    const original_title = "A long multibyte title 🚀 你好" ** 16;
    const slot = try serializeTitleSlotAlloc(
        std.testing.allocator,
        original_title,
        .user,
        "2026-02-16T10:20:30.000Z",
    );
    defer std.testing.allocator.free(slot);

    try std.testing.expectEqual(SESSION_TITLE_SLOT_BYTES, slot.len);
    try std.testing.expectEqual(@as(u8, '\n'), slot[slot.len - 1]);
    try std.testing.expect(std.unicode.utf8ValidateSlice(slot));

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const parsed = try parseTitleSlot(arena_state.allocator(), slot[0 .. slot.len - 1]);
    try std.testing.expectEqual(SessionTitleSource.user, parsed.source.?);
    try std.testing.expectEqualStrings("2026-02-16T10:20:30.000Z", parsed.updatedAt);
    try std.testing.expect(parsed.title.len < original_title.len);
}

test "session JSONL fixtures round trip with upstream wire fields" {
    // Fixtures are copied from inspiration/docs/session.md, Entry Taxonomy.
    // The documentation's illustrative assistant message omits api and
    // stopReason; those two required fields are completed from the pinned
    // packages/ai/src/types.ts wire shape.
    const fixtures = [_][]const u8{
        \\{"type":"session","version":3,"id":"1f9d2a6b9c0d1234","timestamp":"2026-02-16T10:20:30.000Z","cwd":"/work/pi","title":"optional session title","titleSource":"auto","parentSession":"optional lineage marker"}
        ,
        \\{"type":"message","id":"a1b2c3d4","parentId":null,"timestamp":"2026-02-16T10:21:00.000Z","message":{"role":"assistant","api":"anthropic-messages","provider":"anthropic","model":"claude-sonnet-4-5","content":[{"type":"text","text":"Done."}],"usage":{"input":100,"output":20,"cacheRead":0,"cacheWrite":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"stop","timestamp":1760000000000}}
        ,
        \\{"type":"model_change","id":"b1c2d3e4","parentId":"a1b2c3d4","timestamp":"2026-02-16T10:21:30.000Z","model":"openai/gpt-4o","role":"default"}
        ,
        \\{"type":"service_tier_change","id":"c1d2e3f4","parentId":"b1c2d3e4","timestamp":"2026-02-16T10:21:45.000Z","serviceTier":{"openai":"priority","google":"flex"}}
        ,
        \\{"type":"thinking_level_change","id":"c1d2e3f4","parentId":"b1c2d3e4","timestamp":"2026-02-16T10:22:00.000Z","thinkingLevel":"high"}
        ,
        \\{"type":"compaction","id":"d1e2f3a4","parentId":"c1d2e3f4","timestamp":"2026-02-16T10:23:00.000Z","summary":"Conversation summary","shortSummary":"Short recap","firstKeptEntryId":"a1b2c3d4","tokensBefore":42000,"details":{"readFiles":["src/a.ts"]},"preserveData":{"hookState":true},"fromExtension":false}
        ,
        \\{"type":"branch_summary","id":"e1f2a3b4","parentId":"a1b2c3d4","timestamp":"2026-02-16T10:24:00.000Z","fromId":"a1b2c3d4","summary":"Summary of abandoned path","details":{"note":"optional"},"fromExtension":true}
        ,
        \\{"type":"custom","id":"f1a2b3c4","parentId":"e1f2a3b4","timestamp":"2026-02-16T10:25:00.000Z","customType":"my-extension","data":{"state":1}}
        ,
        \\{"type":"custom_message","id":"a2b3c4d5","parentId":"f1a2b3c4","timestamp":"2026-02-16T10:26:00.000Z","customType":"my-extension","content":"Injected context","display":true,"details":{"debug":false},"attribution":"agent"}
        ,
        \\{"type":"label","id":"b2c3d4e5","parentId":"a2b3c4d5","timestamp":"2026-02-16T10:27:00.000Z","targetId":"a1b2c3d4","label":"checkpoint"}
        ,
        \\{"type":"ttsr_injection","id":"c2d3e4f5","parentId":"b2c3d4e5","timestamp":"2026-02-16T10:28:00.000Z","injectedRules":["ruleA","ruleB"]}
        ,
        \\{"type":"mcp_tool_selection","id":"d2e3f4a5","parentId":"c2d3e4f5","timestamp":"2026-02-16T10:28:30.000Z","selectedToolNames":["server.tool"]}
        ,
        \\{"type":"session_init","id":"d2e3f4a5","parentId":"c2d3e4f5","timestamp":"2026-02-16T10:29:00.000Z","systemPrompt":"...","task":"...","tools":["read","edit"],"outputSchema":{"type":"object"},"spawns":"*","readSummarize":false}
        ,
        \\{"type":"mode_change","id":"e2f3a4b5","parentId":"d2e3f4a5","timestamp":"2026-02-16T10:30:00.000Z","mode":"plan","data":{"planFile":"/tmp/plan.md"}}
        ,
        // title-source-persistence.test.ts asserts this audit-entry shape.
        \\{"type":"title_change","id":"f2a3b4c5","parentId":"e2f3a4b5","timestamp":"2026-02-16T10:31:00.000Z","title":"Manual title","previousTitle":"Auto title","source":"user","trigger":"rename"}
        ,
    };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var jsonl: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer jsonl.deinit();

    for (fixtures) |fixture| {
        const first = try parseRawFileEntry(arena, fixture);
        const encoded = try stringifyRawFileEntryAlloc(std.testing.allocator, first);
        defer std.testing.allocator.free(encoded);
        const second = try parseRawFileEntry(arena, encoded);
        const reencoded = try stringifyRawFileEntryAlloc(std.testing.allocator, second);
        defer std.testing.allocator.free(reencoded);
        try std.testing.expectEqualStrings(encoded, reencoded);
        try jsonl.writer.writeAll(encoded);
        try jsonl.writer.writeByte('\n');
    }

    var lines = std.mem.splitScalar(u8, jsonl.written(), '\n');
    var line_count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        _ = try parseRawFileEntry(arena, line);
        line_count += 1;
    }
    try std.testing.expectEqual(fixtures.len, line_count);

    const header_record = try parseRawFileEntry(arena, fixtures[0]);
    try std.testing.expect(header_record == .session);
    try std.testing.expectEqual(@as(?u32, 3), header_record.session.version);
    try std.testing.expectEqualStrings("1f9d2a6b9c0d1234", header_record.session.id);
    try std.testing.expectEqual(SessionTitleSource.auto, header_record.session.titleSource.?);

    const compaction = try parseEntry(arena, fixtures[5]);
    try std.testing.expect(compaction == .compaction);
    try std.testing.expectEqual(@as(u64, 42_000), compaction.compaction.tokensBefore);
    try std.testing.expectEqualStrings("a1b2c3d4", compaction.compaction.firstKeptEntryId);
    try std.testing.expectEqual(false, compaction.compaction.fromExtension.?);

    const custom_message = try parseEntry(arena, fixtures[8]);
    try std.testing.expect(custom_message == .custom_message);
    try std.testing.expectEqualStrings("Injected context", custom_message.custom_message.content.string);
    try std.testing.expectEqual(MessageAttribution.agent, custom_message.custom_message.attribution.?);

    const session_init = try parseEntry(arena, fixtures[12]);
    try std.testing.expect(session_init == .session_init);
    try std.testing.expectEqual(@as(usize, 2), session_init.session_init.tools.len);
    try std.testing.expectEqual(false, session_init.session_init.readSummarize.?);
}

test "session optional fields are omitted and nullable thinking fields are preserved" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entry = try parseEntry(arena,
        \\{"type":"thinking_level_change","id":"1234abcd","parentId":null,"timestamp":"2026-02-16T10:22:00.000Z","thinkingLevel":null}
    );
    const encoded = try stringifyEntryAlloc(std.testing.allocator, entry);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings(
        \\{"type":"thinking_level_change","id":"1234abcd","parentId":null,"timestamp":"2026-02-16T10:22:00.000Z","thinkingLevel":null}
    , encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "configured") == null);

    const header = try parseHeader(arena,
        \\{"type":"session","id":"legacy","timestamp":"2026-02-16T10:20:30.000Z","cwd":"/work/pi"}
    );
    const header_json = try stringifyHeaderAlloc(std.testing.allocator, header);
    defer std.testing.allocator.free(header_json);
    try std.testing.expect(std.mem.indexOf(u8, header_json, "version") == null);
    try std.testing.expect(std.mem.indexOf(u8, header_json, "title") == null);
    try std.testing.expect(std.mem.indexOf(u8, header_json, "parentSession") == null);
}

test "session unknown entry tags round trip as raw records" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fixture =
        \\{"type":"future_entry","id":"a1b2c3d4","parentId":null,"timestamp":"2026-02-16T10:21:00.000Z","payload":{"mode":"new"},"enabled":true}
    ;
    const parsed = try parseEntry(arena, fixture);
    try std.testing.expect(parsed == .unknown);
    try std.testing.expectEqualStrings("a1b2c3d4", parsed.unknown.id);
    const encoded = try stringifyEntryAlloc(arena, parsed);
    try std.testing.expectEqualStrings(fixture, encoded);
}
