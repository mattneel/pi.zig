//! Pure lowering from session `AgentMessage` values to fresh arena-owned
//! `ai.ModelMessage` values.
//!
//! ai.zig exposes opaque per-part `provider_options` rather than dedicated
//! replay fields. Signed reasoning is therefore carried as
//! `anthropic.signature`, redacted reasoning as `anthropic.redactedData`,
//! Gemini replay as `google.thoughtSignature`, and Responses replay as
//! `openai.itemId` plus `openai.reasoningEncryptedContent`. Text response IDs
//! use `openai.itemId`/`phase`; image detail uses `openai.imageDetail`.

const std = @import("std");
const ai = @import("ai");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const message = @import("message.zig");
const tool_output = @import("../tools/output.zig");

const Allocator = std.mem.Allocator;

const compaction_summary_template = @embedFile("../prompts/compaction-summary-context.md");
const branch_summary_template = @embedFile("../prompts/branch-summary-context.md");

pub const Options = struct {
    target_provider: ?[]const u8 = null,
    target_model: ?[]const u8 = null,
};

pub fn toModelMessages(
    arena: Allocator,
    messages: []const message.AgentMessage,
    options: Options,
) ![]ai.ModelMessage {
    var result: std.ArrayList(ai.ModelMessage) = .empty;
    defer result.deinit(arena);

    var index: usize = 0;
    while (index < messages.len) : (index += 1) switch (messages[index]) {
        .user => |value| if (try lowerUser(arena, value.content)) |lowered| {
            try result.append(arena, .{ .user = lowered });
        },
        .developer => |value| try appendDeveloper(arena, &result, value.content),
        .assistant => |value| {
            var source = value;
            if (followedByInterruptedThinking(messages, index)) {
                source.content = stripDemotedThinkingForLlm(value.content);
            }
            if (try lowerAssistant(arena, source, options)) |lowered| try result.append(arena, lowered);
        },
        .tool_result => {
            index = try appendToolResultRun(arena, &result, messages, index) - 1;
        },
        .bash_execution => |value| {
            if (value.exclude_from_context == true) continue;
            const text = try bashExecutionToText(arena, value);
            const parts = try arena.alloc(ai.message.UserContentPart, 1);
            parts[0] = .{ .text = .{ .text = text } };
            try result.append(arena, .{ .user = .{ .content = .{ .parts = parts } } });
        },
        .file_mention => |value| try appendFileMention(arena, &result, value),
        .custom => |value| try appendCustom(arena, &result, value),
        .branch_summary => |value| {
            const text = try renderTemplate(arena, branch_summary_template, value.summary);
            try result.append(arena, .{ .user = try userText(arena, text) });
        },
        .compaction_summary => |value| {
            try appendCompactionSummary(arena, &result, value);
        },
        .unknown => {},
    };

    return result.toOwnedSlice(arena);
}

fn followedByInterruptedThinking(messages: []const message.AgentMessage, index: usize) bool {
    if (index + 1 >= messages.len) return false;
    return switch (messages[index + 1]) {
        .custom => |custom| std.mem.eql(u8, custom.custom_type, "interrupted-thinking"),
        else => false,
    };
}

/// Returns the model-facing prefix after removing the final contiguous run of
/// non-empty, unsigned thinking blocks. Trailing empty text placeholders are
/// removed only when such a run exists, matching upstream's persisted/display
/// versus provider-request split.
fn stripDemotedThinkingForLlm(content: []const message.AssistantBlock) []const message.AssistantBlock {
    var scan_end = content.len;
    while (scan_end > 0) {
        const trailing_is_empty_text = switch (content[scan_end - 1]) {
            .text => |text| std.mem.trim(u8, text.text, " \t\r\n").len == 0,
            else => false,
        };
        if (!trailing_is_empty_text) break;
        scan_end -= 1;
    }

    var run_start = scan_end;
    while (run_start > 0) {
        const joins_run = switch (content[run_start - 1]) {
            .thinking => |thinking| std.mem.trim(u8, thinking.thinking, " \t\r\n").len != 0 and
                thinking.thinking_signature == null,
            else => false,
        };
        if (!joins_run) break;
        run_start -= 1;
    }

    return if (run_start == scan_end) content else content[0..run_start];
}

pub fn bashExecutionToText(arena: Allocator, value: message.BashExecutionMessage) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(arena);
    defer output.deinit();

    try output.writer.print("Ran `{s}`\n", .{value.command});
    if (value.output.len != 0) {
        try output.writer.print("```\n{s}\n```", .{value.output});
    } else {
        try output.writer.writeAll("(no output)");
    }
    if (value.cancelled) {
        try output.writer.writeAll("\n\n(command cancelled)");
    } else if (value.exit_code) |exit_code| {
        if (exit_code != 0) try output.writer.print("\n\nCommand exited with code {d}", .{exit_code});
    }
    if (value.meta) |meta| {
        const notice = try tool_output.formatOutputMetaNoticeValue(arena, meta);
        try output.writer.writeAll(notice);
    }
    return output.toOwnedSlice();
}

pub fn renderBranchSummary(arena: Allocator, summary: []const u8) ![]const u8 {
    return renderTemplate(arena, branch_summary_template, summary);
}

pub fn renderCompactionSummary(arena: Allocator, summary: []const u8) ![]const u8 {
    return renderTemplate(arena, compaction_summary_template, summary);
}

fn lowerUser(arena: Allocator, content: message.TextImageContent) !?ai.message.UserModelMessage {
    return switch (content) {
        .string => |text| .{ .content = .{ .text = try arena.dupe(u8, text) } },
        .blocks => |blocks| blk: {
            const parts = try lowerUserBlocks(arena, blocks);
            if (parts.len == 0) break :blk null;
            break :blk .{ .content = .{ .parts = parts } };
        },
    };
}

fn userText(arena: Allocator, text: []const u8) !ai.message.UserModelMessage {
    const parts = try arena.alloc(ai.message.UserContentPart, 1);
    parts[0] = .{ .text = .{ .text = try arena.dupe(u8, text) } };
    return .{ .content = .{ .parts = parts } };
}

fn lowerUserBlocks(arena: Allocator, blocks: []const message.TextImageBlock) ![]const ai.message.UserContentPart {
    var parts: std.ArrayList(ai.message.UserContentPart) = .empty;
    defer parts.deinit(arena);
    for (blocks) |block| switch (block) {
        .text => |text| try parts.append(arena, .{ .text = .{
            .text = try arena.dupe(u8, text.text),
            .provider_options = try genericTextOptions(arena, text.text_signature),
        } }),
        .image => |image| try parts.append(arena, .{ .file = try lowerImage(arena, image) }),
        .unknown => {},
    };
    return parts.toOwnedSlice(arena);
}

fn lowerImage(arena: Allocator, image: message.ImageContent) !ai.message.FilePart {
    return .{
        .data = .{ .data = .{ .base64 = try arena.dupe(u8, image.data) } },
        .media_type = try arena.dupe(u8, image.mime_type),
        .provider_options = if (image.detail) |detail|
            try makeStringOptions(arena, "openai", &.{.{
                .name = "imageDetail",
                .value = @tagName(detail),
            }})
        else
            null,
    };
}

fn appendDeveloper(
    arena: Allocator,
    result: *std.ArrayList(ai.ModelMessage),
    content: message.TextImageContent,
) !void {
    if (try lowerUser(arena, content)) |lowered| try result.append(arena, .{ .user = lowered });
}

fn lowerAssistant(
    arena: Allocator,
    assistant: message.AssistantMessage,
    options: Options,
) !?ai.ModelMessage {
    var parts: std.ArrayList(ai.message.AssistantContentPart) = .empty;
    defer parts.deinit(arena);
    const native_replay = canReplayNativeThinking(assistant, options);
    for (assistant.content) |block| switch (block) {
        .text => |text| try parts.append(arena, .{ .text = .{
            .text = try arena.dupe(u8, text.text),
            .provider_options = try assistantTextOptions(arena, assistant, text),
        } }),
        .thinking => |thinking| {
            if (!native_replay) {
                if (std.mem.trim(u8, thinking.thinking, " \t\r\n").len == 0) continue;
                try parts.append(arena, .{ .text = .{
                    .text = try renderDemotedThinking(arena, options, thinking.thinking),
                } });
            } else {
                try parts.append(arena, .{ .reasoning = .{
                    .text = try arena.dupe(u8, thinking.thinking),
                    .provider_options = try thinkingOptions(arena, assistant, thinking),
                } });
            }
        },
        .redacted_thinking => |redacted| if (native_replay) try parts.append(arena, .{ .reasoning = .{
            .text = "",
            .provider_options = try makeStringOptions(arena, "anthropic", &.{.{
                .name = "redactedData",
                .value = redacted.data,
            }}),
        } }),
        .fallback => {},
        .unknown => |raw| if (try lowerRawAssistantBlock(arena, raw)) |part| try parts.append(arena, part),
        .tool_call => |call| try parts.append(arena, .{ .tool_call = .{
            .tool_call_id = try arena.dupe(u8, call.id),
            .tool_name = try arena.dupe(u8, call.name),
            .input = try provider_utils.cloneJsonValue(arena, call.arguments),
            .provider_options = try toolCallOptions(arena, assistant, call),
        } }),
    };
    if (parts.items.len == 0) return null;
    return .{ .assistant = .{ .content = .{ .parts = try parts.toOwnedSlice(arena) } } };
}

fn lowerRawAssistantBlock(arena: Allocator, raw: std.json.Value) !?ai.message.AssistantContentPart {
    if (raw != .object) return null;
    const type_value = raw.object.get("type") orelse return null;
    if (type_value != .string or !std.mem.eql(u8, type_value.string, "custom")) return null;
    const kind_value = raw.object.get("kind") orelse return null;
    if (kind_value != .string) return null;
    const metadata = raw.object.get("providerMetadata") orelse raw.object.get("providerOptions");
    return .{ .custom = .{
        .kind = try arena.dupe(u8, kind_value.string),
        .provider_options = if (metadata) |value| try provider_utils.cloneJsonValue(arena, value) else null,
    } };
}

fn appendToolResultRun(
    arena: Allocator,
    result: *std.ArrayList(ai.ModelMessage),
    messages: []const message.AgentMessage,
    start: usize,
) !usize {
    var end = start;
    while (end < messages.len and messages[end] == .tool_result) : (end += 1) {}

    var tool_parts: std.ArrayList(ai.message.ToolContentPart) = .empty;
    defer tool_parts.deinit(arena);
    var hoisted_images: std.ArrayList(message.ImageContent) = .empty;
    defer hoisted_images.deinit(arena);

    for (messages[start..end]) |item| {
        const tool_result = item.tool_result;
        const content = if (tool_result.pruned_at == null)
            tool_result.content
        else
            try prunedContent(arena, tool_result.content);
        const output = try lowerToolResultOutput(arena, content, tool_result.is_error, &hoisted_images);
        try tool_parts.append(arena, .{ .tool_result = .{
            .tool_call_id = try arena.dupe(u8, tool_result.tool_call_id),
            .tool_name = try arena.dupe(u8, tool_result.tool_name),
            .output = output,
        } });
    }

    try result.append(arena, .{ .tool = .{ .content = try tool_parts.toOwnedSlice(arena) } });
    if (hoisted_images.items.len != 0) {
        const parts = try arena.alloc(ai.message.UserContentPart, hoisted_images.items.len + 1);
        parts[0] = .{ .text = .{ .text = "Attached image(s) from the tool result(s) above:" } };
        for (hoisted_images.items, parts[1..]) |image, *part| {
            part.* = .{ .file = try lowerImage(arena, image) };
        }
        try result.append(arena, .{ .user = .{ .content = .{ .parts = parts } } });
    }
    return end;
}

fn lowerToolResultOutput(
    arena: Allocator,
    blocks: []const message.TextImageBlock,
    is_error: bool,
    hoisted_images: *std.ArrayList(message.ImageContent),
) !ai.message.ToolResultOutput {
    if (!is_error) return .{ .content = .{ .value = try lowerToolResultParts(arena, blocks, null) } };

    var text_count: usize = 0;
    for (blocks) |block| switch (block) {
        .text => text_count += 1,
        .image => |image| try hoisted_images.append(arena, image),
        .unknown => {},
    };
    if (text_count == 0) return .{ .error_text = .{ .value = "Tool failed with no output." } };
    if (text_count == 1) {
        for (blocks) |block| switch (block) {
            .text => |text| return .{ .error_text = .{ .value = try arena.dupe(u8, text.text) } },
            else => {},
        };
        unreachable;
    }
    return .{ .content = .{ .value = try lowerToolResultParts(arena, blocks, .text_only) } };
}

const ToolPartFilter = enum { text_only };

fn lowerToolResultParts(
    arena: Allocator,
    blocks: []const message.TextImageBlock,
    filter: ?ToolPartFilter,
) ![]const ai.message.ToolResultContentPart {
    var parts: std.ArrayList(ai.message.ToolResultContentPart) = .empty;
    defer parts.deinit(arena);
    for (blocks) |block| switch (block) {
        .text => |text| try parts.append(arena, .{ .text = .{ .text = try arena.dupe(u8, text.text) } }),
        .image => |image| if (filter == null) try parts.append(arena, .{ .file = .{
            .data = .{ .data = .{ .base64 = try arena.dupe(u8, image.data) } },
            .media_type = try arena.dupe(u8, image.mime_type),
            .provider_options = if (image.detail) |detail|
                try makeStringOptions(arena, "openai", &.{.{
                    .name = "imageDetail",
                    .value = @tagName(detail),
                }})
            else
                null,
        } }),
        .unknown => {},
    };
    return parts.toOwnedSlice(arena);
}

fn prunedContent(arena: Allocator, blocks: []const message.TextImageBlock) ![]const message.TextImageBlock {
    const text = try joinedText(arena, blocks, "[Output truncated]");
    const result = try arena.alloc(message.TextImageBlock, 1);
    result[0] = .{ .text = .{ .text = text } };
    return result;
}

fn joinedText(
    arena: Allocator,
    blocks: []const message.TextImageBlock,
    fallback: []const u8,
) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(arena);
    defer output.deinit();
    for (blocks) |block| switch (block) {
        .text => |text| try output.writer.writeAll(text.text),
        .image, .unknown => {},
    };
    if (output.written().len == 0) try output.writer.writeAll(fallback);
    return output.toOwnedSlice();
}

fn appendFileMention(
    arena: Allocator,
    result: *std.ArrayList(ai.ModelMessage),
    mention: message.FileMentionMessage,
) !void {
    var text_files: std.ArrayList(message.FileMention) = .empty;
    defer text_files.deinit(arena);
    var image_files: std.ArrayList(message.FileMention) = .empty;
    defer image_files.deinit(arena);
    for (mention.files) |file| {
        if (file.image == null)
            try text_files.append(arena, file)
        else
            try image_files.append(arena, file);
    }

    if (text_files.items.len != 0) {
        const text = try renderFiles(arena, text_files.items);
        try result.append(arena, .{ .user = try userText(arena, text) });
    }
    if (image_files.items.len != 0) {
        const parts = try arena.alloc(ai.message.UserContentPart, 1 + image_files.items.len);
        parts[0] = .{ .text = .{ .text = try renderFiles(arena, image_files.items) } };
        for (image_files.items, parts[1..]) |file, *part| {
            part.* = .{ .file = try lowerImage(arena, file.image.?) };
        }
        try result.append(arena, .{ .user = .{ .content = .{ .parts = parts } } });
    }
}

fn renderFiles(arena: Allocator, files: []const message.FileMention) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(arena);
    defer output.deinit();
    for (files, 0..) |file, index| {
        if (index != 0) try output.writer.writeByte('\n');
        if (file.content.len != 0) {
            try output.writer.print("<file path=\"{s}\">\n{s}\n</file>", .{ file.path, file.content });
        } else {
            try output.writer.print("<file path=\"{s}\">\n</file>", .{file.path});
        }
    }
    return output.toOwnedSlice();
}

fn appendCustom(
    arena: Allocator,
    result: *std.ArrayList(ai.ModelMessage),
    custom: message.CustomMessage,
) !void {
    const user_invoked_skill = std.mem.eql(u8, custom.custom_type, "skill-prompt") and
        custom.attribution == .user;
    if (user_invoked_skill) {
        if (try lowerUser(arena, custom.content)) |lowered| {
            try result.append(arena, .{ .user = lowered });
        }
        return;
    }

    switch (custom.content) {
        .string => try appendDeveloper(arena, result, custom.content),
        .blocks => |blocks| {
            var text_count: usize = 0;
            var image_count: usize = 0;
            for (blocks) |block| switch (block) {
                .text => text_count += 1,
                .image => image_count += 1,
                .unknown => {},
            };
            if (image_count == 0) {
                try appendDeveloper(arena, result, custom.content);
                return;
            }
            if (text_count != 0) {
                const text_blocks = try arena.alloc(message.TextImageBlock, text_count);
                var index: usize = 0;
                for (blocks) |block| switch (block) {
                    .text => |text| {
                        text_blocks[index] = .{ .text = text };
                        index += 1;
                    },
                    .image, .unknown => {},
                };
                try appendDeveloper(arena, result, .{ .blocks = text_blocks });
            }

            const image_parts = try arena.alloc(ai.message.UserContentPart, image_count + 1);
            image_parts[0] = .{ .text = .{ .text = try std.fmt.allocPrint(
                arena,
                "Images attached to {s}.",
                .{custom.custom_type},
            ) } };
            var index: usize = 1;
            for (blocks) |block| switch (block) {
                .image => |image| {
                    image_parts[index] = .{ .file = try lowerImage(arena, image) };
                    index += 1;
                },
                .text, .unknown => {},
            };
            try result.append(arena, .{ .user = .{ .content = .{ .parts = image_parts } } });
        },
    }
}

fn appendCompactionSummary(
    arena: Allocator,
    result: *std.ArrayList(ai.ModelMessage),
    summary: message.CompactionSummaryMessage,
) !void {
    const source_blocks = summary.blocks orelse blk: {
        const images = summary.images orelse &.{};
        const blocks = try arena.alloc(message.TextImageBlock, images.len);
        for (images, blocks) |image, *block| block.* = .{ .image = image };
        break :blk blocks;
    };
    const text = if (summary.blocks != null)
        try arena.dupe(u8, summary.summary)
    else
        try renderTemplate(arena, compaction_summary_template, summary.summary);
    const lowered_blocks = try lowerUserBlocks(arena, source_blocks);
    const parts = try arena.alloc(ai.message.UserContentPart, lowered_blocks.len + 1);
    parts[0] = .{ .text = .{ .text = text } };
    @memcpy(parts[1..], lowered_blocks);
    try result.append(arena, .{ .user = .{ .content = .{ .parts = parts } } });
}

fn canReplayNativeThinking(assistant: message.AssistantMessage, options: Options) bool {
    const target_provider = options.target_provider orelse return true;
    const target_model = options.target_model orelse return true;
    return std.mem.eql(u8, assistant.provider, target_provider) and
        std.mem.eql(u8, assistant.model, target_model);
}

fn renderDemotedThinking(arena: Allocator, options: Options, text: []const u8) ![]const u8 {
    const target_provider = options.target_provider orelse "";
    const target_model = options.target_model orelse "";
    if (contains(target_provider, "anthropic") or contains(target_model, "claude")) {
        return arena.dupe(u8, text);
    }
    return std.fmt.allocPrint(arena, "<think>\n{s}\n</think>", .{text});
}

fn renderTemplate(arena: Allocator, template: []const u8, summary: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, arena, template, "{{summary}}", summary);
}

const StringOption = struct {
    name: []const u8,
    value: []const u8,
};

fn makeStringOptions(
    arena: Allocator,
    namespace: []const u8,
    entries: []const StringOption,
) !provider.ProviderOptions {
    var inner: std.json.ObjectMap = .empty;
    for (entries) |entry| try inner.put(
        arena,
        try arena.dupe(u8, entry.name),
        .{ .string = try arena.dupe(u8, entry.value) },
    );
    var root: std.json.ObjectMap = .empty;
    try root.put(arena, try arena.dupe(u8, namespace), .{ .object = inner });
    return .{ .object = root };
}

fn genericTextOptions(arena: Allocator, signature: ?[]const u8) !?provider.ProviderOptions {
    const value = signature orelse return null;
    var root: std.json.ObjectMap = .empty;

    var google: std.json.ObjectMap = .empty;
    try google.put(
        arena,
        "thoughtSignature",
        .{ .string = try arena.dupe(u8, value) },
    );
    try root.put(arena, "google", .{ .object = google });

    var openai: std.json.ObjectMap = .empty;
    if (try parseTextSignature(arena, value)) |parsed| {
        try openai.put(arena, "itemId", .{ .string = try arena.dupe(u8, parsed.id) });
        if (parsed.phase) |phase| {
            try openai.put(arena, "phase", .{ .string = try arena.dupe(u8, phase) });
        }
    } else {
        try openai.put(arena, "itemId", .{ .string = try arena.dupe(u8, value) });
    }
    try root.put(arena, "openai", .{ .object = openai });
    return .{ .object = root };
}

fn assistantTextOptions(
    arena: Allocator,
    assistant: message.AssistantMessage,
    text: message.TextContent,
) !?provider.ProviderOptions {
    const signature = text.text_signature orelse return null;
    if (isGoogle(assistant)) return try makeStringOptions(arena, "google", &.{.{
        .name = "thoughtSignature",
        .value = signature,
    }});
    if (isOpenAi(assistant)) {
        var entries: [2]StringOption = undefined;
        var count: usize = 0;
        if (try parseTextSignature(arena, signature)) |parsed| {
            entries[count] = .{ .name = "itemId", .value = parsed.id };
            count += 1;
            if (parsed.phase) |phase| {
                entries[count] = .{ .name = "phase", .value = phase };
                count += 1;
            }
        } else {
            entries[count] = .{ .name = "itemId", .value = signature };
            count += 1;
        }
        return try makeStringOptions(arena, "openai", entries[0..count]);
    }
    return null;
}

fn thinkingOptions(
    arena: Allocator,
    assistant: message.AssistantMessage,
    thinking: message.ThinkingContent,
) !?provider.ProviderOptions {
    if (isAnthropic(assistant)) {
        const signature = thinking.thinking_signature orelse return null;
        return try makeStringOptions(arena, "anthropic", &.{.{
            .name = "signature",
            .value = signature,
        }});
    }
    if (isGoogle(assistant)) {
        const signature = thinking.thinking_signature orelse return null;
        return try makeStringOptions(arena, "google", &.{.{
            .name = "thoughtSignature",
            .value = signature,
        }});
    }
    if (isOpenAi(assistant)) {
        var entries: [2]StringOption = undefined;
        var count: usize = 0;
        var item_id = thinking.item_id;
        var encrypted: ?[]const u8 = null;
        if (thinking.thinking_signature) |signature| {
            if (try parseJsonObject(arena, signature)) |object| {
                if (item_id == null) item_id = objectString(object, "id");
                encrypted = objectString(object, "encrypted_content");
            } else if (item_id == null) {
                item_id = signature;
            }
        }
        if (item_id) |value| {
            entries[count] = .{ .name = "itemId", .value = value };
            count += 1;
        }
        if (encrypted) |value| {
            entries[count] = .{ .name = "reasoningEncryptedContent", .value = value };
            count += 1;
        }
        if (count != 0) return try makeStringOptions(arena, "openai", entries[0..count]);
    }
    return null;
}

fn toolCallOptions(
    arena: Allocator,
    assistant: message.AssistantMessage,
    call: message.ToolCallContent,
) !?provider.ProviderOptions {
    const signature = call.thought_signature orelse return null;
    if (isGoogle(assistant)) return try makeStringOptions(arena, "google", &.{.{
        .name = "thoughtSignature",
        .value = signature,
    }});
    if (isOpenAi(assistant)) return try makeStringOptions(arena, "openai", &.{.{
        .name = "itemId",
        .value = signature,
    }});
    return null;
}

const ParsedTextSignature = struct {
    id: []const u8,
    phase: ?[]const u8,
};

fn parseTextSignature(arena: Allocator, signature: []const u8) !?ParsedTextSignature {
    const object = (try parseJsonObject(arena, signature)) orelse return null;
    const id = objectString(object, "id") orelse return null;
    return .{ .id = id, .phase = objectString(object, "phase") };
}

fn parseJsonObject(arena: Allocator, text: []const u8) !?std.json.ObjectMap {
    const value: std.json.Value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    return if (value == .object) value.object else null;
}

fn objectString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn isAnthropic(assistant: message.AssistantMessage) bool {
    return contains(assistant.api, "anthropic") or contains(assistant.provider, "anthropic");
}

fn isGoogle(assistant: message.AssistantMessage) bool {
    return contains(assistant.api, "google") or
        contains(assistant.api, "gemini") or
        contains(assistant.provider, "google") or
        contains(assistant.provider, "gemini");
}

fn isOpenAi(assistant: message.AssistantMessage) bool {
    return contains(assistant.api, "openai") or contains(assistant.provider, "openai");
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "lower bash execution uses the exact upstream template" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const messages = [_]message.AgentMessage{
        .{ .bash_execution = .{
            .command = "printf hi",
            .output = "hi",
            .exit_code = 7,
            .cancelled = false,
            .truncated = false,
            .timestamp = 1,
        } },
        .{ .bash_execution = .{
            .command = "ignored",
            .output = "secret",
            .cancelled = false,
            .truncated = false,
            .exclude_from_context = true,
            .timestamp = 2,
        } },
    };
    const lowered = try toModelMessages(arena, &messages, .{});
    const json = try provider.wire.stringifyAlloc(arena, lowered);
    try std.testing.expectEqualStrings(
        \\[{"role":"user","content":[{"type":"text","text":"Ran `printf hi`\n```\nhi\n```\n\nCommand exited with code 7"}]}]
    , json);
}

test "lower file mentions split developer text and user images" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const files = [_]message.FileMention{
        .{ .path = "notes.md", .content = "hello" },
        .{ .path = "shot.png", .content = "", .image = .{
            .data = "aGVsbG8=",
            .mime_type = "image/png",
        } },
    };
    const lowered = try toModelMessages(arena, &.{.{ .file_mention = .{
        .files = &files,
        .timestamp = 1,
    } }}, .{});
    const json = try provider.wire.stringifyAlloc(arena, lowered);
    try std.testing.expectEqualStrings(
        \\[{"role":"user","content":[{"type":"text","text":"<file path=\"notes.md\">\nhello\n</file>"}]},{"role":"user","content":[{"type":"text","text":"<file path=\"shot.png\">\n</file>"},{"type":"file","data":{"type":"data","data":"aGVsbG8="},"mediaType":"image/png"}]}]
    , json);
}

test "lower custom images split and user-invoked skills stay user messages" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const blocks = [_]message.TextImageBlock{
        .{ .text = .{ .text = "context" } },
        .{ .image = .{ .data = "aA==", .mime_type = "image/png" } },
    };
    const lowered = try toModelMessages(arena, &.{
        .{ .custom = .{
            .custom_type = "attachment",
            .content = .{ .blocks = &blocks },
            .display = true,
            .timestamp = 1,
        } },
        .{ .custom = .{
            .custom_type = "skill-prompt",
            .content = .{ .string = "do the thing" },
            .display = true,
            .attribution = .user,
            .timestamp = 2,
        } },
    }, .{});
    const json = try provider.wire.stringifyAlloc(arena, lowered);
    try std.testing.expectEqualStrings(
        \\[{"role":"user","content":[{"type":"text","text":"context"}]},{"role":"user","content":[{"type":"text","text":"Images attached to attachment."},{"type":"file","data":{"type":"data","data":"aA=="},"mediaType":"image/png"}]},{"role":"user","content":"do the thing"}]
    , json);
}

test "lower direct core roles preserve content tool arguments and failures" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const arguments = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"path\":\"src/main.zig\"}",
        .{},
    );
    const usage: message.Usage = .{
        .input = 2,
        .output = 3,
        .cache_read = 4,
        .cache_write = 5,
        .cost = .{},
    };
    const lowered = try toModelMessages(arena, &.{
        .{ .user = .{ .content = .{ .string = "inspect" }, .timestamp = 1 } },
        .{ .developer = .{ .content = .{ .string = "be precise" }, .timestamp = 2 } },
        .{ .assistant = .{
            .content = &.{
                .{ .text = .{ .text = "checking" } },
                .{ .tool_call = .{ .id = "call-1", .name = "read", .arguments = arguments } },
            },
            .api = "anthropic-messages",
            .provider = "anthropic",
            .model = "claude",
            .usage = usage,
            .stop_reason = .tool_use,
            .timestamp = 3,
        } },
        .{ .tool_result = .{
            .tool_call_id = "call-1",
            .tool_name = "read",
            .content = &.{.{ .text = .{ .text = "not found" } }},
            .is_error = true,
            .timestamp = 4,
        } },
    }, .{});
    const json = try provider.wire.stringifyAlloc(arena, lowered);
    try std.testing.expectEqualStrings(
        \\[{"role":"user","content":"inspect"},{"role":"user","content":"be precise"},{"role":"assistant","content":[{"type":"text","text":"checking"},{"type":"tool-call","toolCallId":"call-1","toolName":"read","input":{"path":"src/main.zig"}}]},{"role":"tool","content":[{"type":"tool-result","toolCallId":"call-1","toolName":"read","output":{"type":"error-text","value":"not found"}}]}]
    , json);
}

test "lower summary templates are byte-identical embedded prompts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const branch = try renderBranchSummary(arena, "branch state");
    try std.testing.expectEqualStrings(
        "The following is a summary of a branch that this conversation came back from:\n\n<summary>\nbranch state\n</summary>\n",
        branch,
    );
    const compact = try renderCompactionSummary(arena, "prior work");
    try std.testing.expect(std.mem.startsWith(
        u8,
        compact,
        "Another language model started to solve this problem",
    ));
    try std.testing.expect(std.mem.endsWith(u8, compact, "<summary>\nprior work\n</summary>\n"));
}

test "lower assistant carries Anthropic and OpenAI replay metadata through provider options" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const empty_usage: message.Usage = .{
        .input = 0,
        .output = 0,
        .cache_read = 0,
        .cache_write = 0,
        .cost = .{},
    };

    const anthropic = try toModelMessages(arena, &.{.{ .assistant = .{
        .content = &.{.{ .thinking = .{
            .thinking = "Think",
            .thinking_signature = "sig-1",
        } }},
        .api = "anthropic-messages",
        .provider = "anthropic",
        .model = "claude",
        .usage = empty_usage,
        .stop_reason = .stop,
        .timestamp = 1,
    } }}, .{});
    const anthropic_json = try provider.wire.stringifyAlloc(arena, anthropic);
    try std.testing.expectEqualStrings(
        \\[{"role":"assistant","content":[{"type":"reasoning","text":"Think","providerOptions":{"anthropic":{"signature":"sig-1"}}}]}]
    , anthropic_json);

    const openai = try toModelMessages(arena, &.{.{ .assistant = .{
        .content = &.{.{ .thinking = .{
            .thinking = "Reason",
            .thinking_signature = "{\"id\":\"rs_1\",\"encrypted_content\":\"enc\"}",
        } }},
        .api = "openai-responses",
        .provider = "openai",
        .model = "gpt",
        .usage = empty_usage,
        .stop_reason = .stop,
        .timestamp = 2,
    } }}, .{});
    const openai_json = try provider.wire.stringifyAlloc(arena, openai);
    try std.testing.expectEqualStrings(
        \\[{"role":"assistant","content":[{"type":"reasoning","text":"Reason","providerOptions":{"openai":{"itemId":"rs_1","reasoningEncryptedContent":"enc"}}}]}]
    , openai_json);
}

// Fixture shape ported from
// inspiration/packages/coding-agent/test/session/interrupted-thinking-demote.test.ts
// and its provider-view assertion in agent-session-interrupted-thinking.test.ts.
test "lower interrupted thinking strips only the marked unsigned trailing run" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const empty_usage: message.Usage = .{
        .input = 0,
        .output = 0,
        .cache_read = 0,
        .cache_write = 0,
        .cost = .{},
    };

    const lowered = try toModelMessages(arena, &.{
        .{ .assistant = .{
            .content = &.{
                .{ .text = .{ .text = "Visible answer." } },
                .{ .thinking = .{ .thinking = " First thought " } },
                .{ .thinking = .{ .thinking = "Second thought\n" } },
                .{ .text = .{ .text = " \n\t" } },
            },
            .api = "anthropic-messages",
            .provider = "anthropic",
            .model = "claude",
            .usage = empty_usage,
            .stop_reason = .aborted,
            .timestamp = 1,
        } },
        .{ .custom = .{
            .custom_type = "interrupted-thinking",
            .content = .{ .string = "First thought\n\nSecond thought" },
            .display = false,
            .attribution = .agent,
            .timestamp = 2,
        } },
        .{ .assistant = .{
            .content = &.{.{ .thinking = .{ .thinking = "Unmarked reasoning stays" } }},
            .api = "anthropic-messages",
            .provider = "anthropic",
            .model = "claude",
            .usage = empty_usage,
            .stop_reason = .aborted,
            .timestamp = 3,
        } },
    }, .{});
    const json = try provider.wire.stringifyAlloc(arena, lowered);
    try std.testing.expectEqualStrings(
        \\[{"role":"assistant","content":[{"type":"text","text":"Visible answer."}]},{"role":"user","content":"First thought\n\nSecond thought"},{"role":"assistant","content":[{"type":"reasoning","text":"Unmarked reasoning stays"}]}]
    , json);
}

test "lower developer-origin messages use user role and preserve text block boundaries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const blocks = [_]message.TextImageBlock{
        .{ .text = .{ .text = "A" } },
        .{ .text = .{ .text = "B" } },
    };

    const lowered = try toModelMessages(arena, &.{.{ .developer = .{
        .content = .{ .blocks = &blocks },
        .timestamp = 1,
    } }}, .{});
    const json = try provider.wire.stringifyAlloc(arena, lowered);
    try std.testing.expectEqualStrings(
        \\[{"role":"user","content":[{"type":"text","text":"A"},{"type":"text","text":"B"}]}]
    , json);
}

test "lower cross-model GPT thinking to Claude as assistant prose" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const lowered = try toModelMessages(arena, &.{.{ .assistant = .{
        .content = &.{.{ .thinking = .{
            .thinking = "Reason from the prior model.",
            .thinking_signature = "encrypted-gpt-signature",
            .item_id = "rs_1",
        } }},
        .api = "openai-responses",
        .provider = "openai",
        .model = "gpt-5",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 1,
    } }}, .{
        .target_provider = "anthropic",
        .target_model = "claude-sonnet-4-6",
    });
    const json = try provider.wire.stringifyAlloc(arena, lowered);
    try std.testing.expectEqualStrings(
        \\[{"role":"assistant","content":[{"type":"text","text":"Reason from the prior model."}]}]
    , json);
}

test "lower drops an interrupted assistant turn with no remaining parts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const lowered = try toModelMessages(arena, &.{
        .{ .assistant = .{
            .content = &.{.{ .thinking = .{ .thinking = "unfinished" } }},
            .api = "anthropic-messages",
            .provider = "anthropic",
            .model = "claude-sonnet-4-6",
            .usage = .{},
            .stop_reason = .aborted,
            .timestamp = 1,
        } },
        .{ .custom = .{
            .custom_type = "interrupted-thinking",
            .content = .{ .string = "unfinished" },
            .display = false,
            .timestamp = 2,
        } },
    }, .{});
    const json = try provider.wire.stringifyAlloc(arena, lowered);
    try std.testing.expectEqualStrings(
        \\[{"role":"user","content":"unfinished"}]
    , json);
}

test "lower compaction summaries use snapcompact blocks or legacy images" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const snap_blocks = [_]message.TextImageBlock{
        .{ .text = .{ .text = "archive text" } },
        .{ .image = .{ .data = "aA==", .mime_type = "image/png" } },
    };
    const legacy_images = [_]message.ImageContent{
        .{ .data = "aQ==", .mime_type = "image/jpeg" },
    };

    const lowered = try toModelMessages(arena, &.{
        .{ .compaction_summary = .{
            .summary = "raw lead-in",
            .tokens_before = 100,
            .blocks = &snap_blocks,
            .timestamp = 1,
        } },
        .{ .compaction_summary = .{
            .summary = "legacy summary",
            .tokens_before = 200,
            .images = &legacy_images,
            .timestamp = 2,
        } },
    }, .{});
    const json = try provider.wire.stringifyAlloc(arena, lowered);
    try std.testing.expect(std.mem.indexOf(u8, json,
        \\{"role":"user","content":[{"type":"text","text":"raw lead-in"},{"type":"text","text":"archive text"},{"type":"file","data":{"type":"data","data":"aA=="},"mediaType":"image/png"}]}
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Another language model started to solve this problem") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"data\":\"aQ==\"") != null);
}

test "lower bash execution appends the structured output notice" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const meta = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"truncation":{"direction":"tail","truncatedBy":"bytes","totalLines":100,"totalBytes":100000,"outputLines":13,"outputBytes":1000,"maxBytes":51200,"shownRange":{"start":88,"end":100}}}
    , .{});

    const lowered = try toModelMessages(arena, &.{.{ .bash_execution = .{
        .command = "build",
        .output = "tail",
        .cancelled = false,
        .truncated = true,
        .meta = meta,
        .timestamp = 1,
    } }}, .{});
    const json = try provider.wire.stringifyAlloc(arena, lowered);
    try std.testing.expect(std.mem.indexOf(u8, json, "\\n\\n[Showing lines 88-100 of 100 (50.0KB limit)]") != null);
}

test "lower consecutive error tool results preserve blocks and hoist images once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const first_content = [_]message.TextImageBlock{
        .{ .text = .{ .text = "first" } },
        .{ .text = .{ .text = "second" } },
        .{ .image = .{ .data = "aA==", .mime_type = "image/png" } },
    };

    const lowered = try toModelMessages(arena, &.{
        .{ .tool_result = .{
            .tool_call_id = "call-1",
            .tool_name = "one",
            .content = &first_content,
            .is_error = true,
            .timestamp = 1,
        } },
        .{ .tool_result = .{
            .tool_call_id = "call-2",
            .tool_name = "two",
            .content = &.{},
            .is_error = true,
            .timestamp = 2,
        } },
    }, .{});
    const json = try provider.wire.stringifyAlloc(arena, lowered);
    try std.testing.expectEqualStrings(
        \\[{"role":"tool","content":[{"type":"tool-result","toolCallId":"call-1","toolName":"one","output":{"type":"content","value":[{"type":"text","text":"first"},{"type":"text","text":"second"}]}},{"type":"tool-result","toolCallId":"call-2","toolName":"two","output":{"type":"error-text","value":"Tool failed with no output."}}]},{"role":"user","content":[{"type":"text","text":"Attached image(s) from the tool result(s) above:"},{"type":"file","data":{"type":"data","data":"aA=="},"mediaType":"image/png"}]}]
    , json);
}
