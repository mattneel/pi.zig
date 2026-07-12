//! Centralized, byte-exact hashline diagnostics.

const std = @import("std");
const format = @import("format.zig");
const types = @import("types.zig");

pub const mismatch_context = 2;

pub const begin_patch_marker = "*** Begin Patch";
pub const end_patch_marker = "*** End Patch";
pub const abort_marker = "*** Abort";

pub const replace_pair_coalesced_warning =
    "Two hunks targeted the same range; kept only the second. One `SWAP N.=M:` hunk per range — the body is the final content, never old+new.";
pub const bare_body_auto_piped_warning =
    "Auto-prefixed bare body row(s) with `+`. Body rows must be `+TEXT` literal lines.";
pub const minus_row_rejected =
    "`-` rows are not valid; the range already names the lines being changed. For Markdown bullets or other literal `-` lines, prefix the literal row with `+`: `+- item`.";
pub const empty_replace =
    "`SWAP N.=M:` needs at least one `+TEXT` body row. To delete lines, use `DEL N.=M`.";
pub const empty_block =
    "`SWAP.BLK N:` needs at least one `+TEXT` body row. To delete a block, use `DEL.BLK N`.";
pub const block_resolver_unavailable =
    "`SWAP.BLK`/`DEL.BLK`/`INS.BLK.POST` are not available here (no block resolver configured). Use a concrete line range.";
pub const unresolved_block_internal =
    "internal error: unresolved `SWAP.BLK` edit reached the applier (resolveBlockEdits was not run).";
pub const delete_takes_no_body =
    "`DEL N.=M` does not take body rows. Remove the body, or use `SWAP N.=M:`.";
pub const rem_takes_no_body =
    "`REM` deletes the whole file and takes no body rows or line ops. Issue it alone under the header.";
pub const move_takes_no_body =
    "`MV DEST` does not take body rows. Put line edits above the `MV` row; the destination path follows `MV` on the same line.";
pub const delete_block_takes_no_body =
    "`DEL.BLK N` does not take body rows. Remove the body, or use `SWAP.BLK N:`.";
pub const empty_insert = "`INS` needs at least one `+TEXT` body row.";

pub const invalid_hashline_patch = "invalid hashline patch";
pub const invalid_hashline_input = "invalid hashline input";
pub const patch_input_no_sections = "Patch input did not produce any sections.";
pub const rem_cannot_combine = "`REM` deletes the whole file and cannot be combined with line ops.";
pub const input_header_empty = "Input header \"[]\" is empty; provide a file path.";
pub const parser_unified_diff_header =
    "unified-diff hunk header (`@@ -N,M +N,M @@`) is not valid in hashline. Use `SWAP N.=M:`, `DEL N.=M`, or `INS.PRE|POST|HEAD|TAIL:` ops.";
pub const input_unified_diff_header =
    "unified-diff hunk header (`@@ -N,M +N,M @@`) is not valid in hashline. File sections start with `[path#HASH]`; use `replace`, `delete`, or `insert` ops.";
pub const delete_colon_rejected =
    "`DEL N.=M` has no colon and no body. Remove the colon and body rows.";

/// JSON string quoting used by upstream diagnostics (`JSON.stringify`).
pub fn jsonQuote(allocator: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]const u8 {
    const hex = "0123456789abcdef";
    var output: std.ArrayList(u8) = .empty;
    try output.append(allocator, '"');
    for (value) |byte| switch (byte) {
        '"' => try output.appendSlice(allocator, "\\\""),
        '\\' => try output.appendSlice(allocator, "\\\\"),
        '\x08' => try output.appendSlice(allocator, "\\b"),
        '\x0c' => try output.appendSlice(allocator, "\\f"),
        '\n' => try output.appendSlice(allocator, "\\n"),
        '\r' => try output.appendSlice(allocator, "\\r"),
        '\t' => try output.appendSlice(allocator, "\\t"),
        0...7, 11, 14...31 => {
            try output.appendSlice(allocator, "\\u00");
            try output.append(allocator, hex[byte >> 4]);
            try output.append(allocator, hex[byte & 0x0f]);
        },
        else => try output.append(allocator, byte),
    };
    try output.append(allocator, '"');
    return output.toOwnedSlice(allocator);
}

/// Match `JSON.stringify(value.slice(0, maxUnits))` without ever emitting
/// invalid UTF-8. When JavaScript would cut an astral code point between its
/// UTF-16 surrogate halves, emit the retained high surrogate as `\uXXXX`.
fn jsonQuoteUtf16Slice(
    allocator: std.mem.Allocator,
    value: []const u8,
    max_units: usize,
    append_ellipsis_when_truncated: bool,
) std.mem.Allocator.Error![]const u8 {
    const hex = "0123456789abcdef";
    var output: std.ArrayList(u8) = .empty;
    try output.append(allocator, '"');
    var index: usize = 0;
    var units: usize = 0;
    while (index < value.len and units < max_units) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(value[index]) catch 1;
        if (sequence_len == 1 and value[index] >= 0x80) {
            try output.appendSlice(allocator, std.unicode.replacement_character_utf8[0..]);
            index += 1;
            units += 1;
            continue;
        }
        if (index + sequence_len > value.len) {
            try output.appendSlice(allocator, std.unicode.replacement_character_utf8[0..]);
            index = value.len;
            units += 1;
            continue;
        }
        const codepoint = std.unicode.utf8Decode(value[index .. index + sequence_len]) catch {
            try output.appendSlice(allocator, std.unicode.replacement_character_utf8[0..]);
            index += 1;
            units += 1;
            continue;
        };
        const width: usize = if (codepoint > 0xFFFF) 2 else 1;
        if (units + width > max_units) {
            const high_surrogate: u16 = @intCast(0xD800 + ((codepoint - 0x10000) >> 10));
            try output.appendSlice(allocator, "\\u");
            try output.append(allocator, hex[(high_surrogate >> 12) & 0xF]);
            try output.append(allocator, hex[(high_surrogate >> 8) & 0xF]);
            try output.append(allocator, hex[(high_surrogate >> 4) & 0xF]);
            try output.append(allocator, hex[high_surrogate & 0xF]);
            units += 1;
            break;
        }
        if (sequence_len == 1) {
            const byte = value[index];
            switch (byte) {
                '"' => try output.appendSlice(allocator, "\\\""),
                '\\' => try output.appendSlice(allocator, "\\\\"),
                '\x08' => try output.appendSlice(allocator, "\\b"),
                '\x0c' => try output.appendSlice(allocator, "\\f"),
                '\n' => try output.appendSlice(allocator, "\\n"),
                '\r' => try output.appendSlice(allocator, "\\r"),
                '\t' => try output.appendSlice(allocator, "\\t"),
                0...7, 11, 14...31 => {
                    try output.appendSlice(allocator, "\\u00");
                    try output.append(allocator, hex[byte >> 4]);
                    try output.append(allocator, hex[byte & 0x0F]);
                },
                else => try output.append(allocator, byte),
            }
        } else {
            try output.appendSlice(allocator, value[index .. index + sequence_len]);
        }
        index += sequence_len;
        units += width;
    }
    if (append_ellipsis_when_truncated and index < value.len) {
        try output.appendSlice(allocator, "…");
    }
    try output.append(allocator, '"');
    return output.toOwnedSlice(allocator);
}

pub fn lineMessage(
    allocator: std.mem.Allocator,
    line_num: usize,
    detail: []const u8,
) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "line {d}: {s}", .{ line_num, detail });
}

pub fn expectedLineNumberMessage(
    allocator: std.mem.Allocator,
    line_num: usize,
    raw: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const quoted = try jsonQuote(allocator, raw);
    return std.fmt.allocPrint(
        allocator,
        "line {d}: expected a line number such as \"119\", \"112\", \"7\"; got {s}. Use [PATH#hash] from your latest read for file-version binding.",
        .{ line_num, quoted },
    );
}

pub fn invertedRangeMessage(
    allocator: std.mem.Allocator,
    line_num: usize,
    start_line: usize,
    end_line: usize,
) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "line {d}: range {d}{s}{d} ends before it starts.",
        .{ line_num, start_line, format.range_separator, end_line },
    );
}

pub fn duplicateFileOpMessage(
    allocator: std.mem.Allocator,
    line_num: usize,
) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "line {d}: only one file-level op (`REM` or `MV`) per section. Merge them under one header.",
        .{line_num},
    );
}

pub fn overlappingHunkMessage(
    allocator: std.mem.Allocator,
    second_source_line: usize,
    anchor_line: usize,
    first_source_line: usize,
) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "line {d}: anchor line {d} is already targeted by another hunk on line {d}. Issue ONE hunk per range; payload is only the final desired content, never a before/after pair.",
        .{ second_source_line, anchor_line, first_source_line },
    );
}

pub fn orphanLiteralPayloadMessage(
    allocator: std.mem.Allocator,
    line_num: usize,
    text: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const payload = try std.fmt.allocPrint(allocator, "{s}{s}", .{ format.payload_replace, text });
    const quoted = try jsonQuote(allocator, payload);
    return std.fmt.allocPrint(
        allocator,
        "line {d}: payload line has no preceding hunk header. Got {s}.",
        .{ line_num, quoted },
    );
}

pub fn orphanRawPayloadMessage(
    allocator: std.mem.Allocator,
    line_num: usize,
    text: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const quoted = try jsonQuote(allocator, text);
    return std.fmt.allocPrint(
        allocator,
        "line {d}: payload line has no preceding hunk header. Use `SWAP N.=M:`, `DEL N.=M`, or `INS.PRE|POST|HEAD|TAIL:` above the body. Got {s}.",
        .{ line_num, quoted },
    );
}

pub fn applyPatchSentinelMessage(
    allocator: std.mem.Allocator,
    value: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const quoted = try jsonQuoteUtf16Slice(allocator, value, 48, true);
    return std.fmt.allocPrint(
        allocator,
        "apply_patch sentinel {s} is not valid in hashline. File sections start with `[path#HASH]` (no `Update File:` / `Add File:` keyword). Use `SWAP N.=M:`, `DEL N.=M`, or `INS.PRE|POST|HEAD|TAIL:` ops.",
        .{quoted},
    );
}

pub fn atAtHeaderMessage(
    allocator: std.mem.Allocator,
    value: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const quoted = try jsonQuoteUtf16Slice(allocator, value, 48, true);
    return std.fmt.allocPrint(
        allocator,
        "`@@`-bracketed hunk header {s} is not valid in hashline. Drop the `@@ ... @@` brackets and write a verb header such as `SWAP N.=M:`.",
        .{quoted},
    );
}

pub fn bareLineHeaderMessage(
    allocator: std.mem.Allocator,
    value: []const u8,
) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "hunk headers need a verb. Use `SWAP {s}.={s}:` to replace, or `DEL {s}` to delete.",
        .{ value, value, value },
    );
}

pub fn bareRangeHeaderMessage(
    allocator: std.mem.Allocator,
    value: []const u8,
    start_line: []const u8,
    end_line: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const quoted = try jsonQuote(allocator, value);
    return std.fmt.allocPrint(
        allocator,
        "bare range hunk header {s} is not valid. Hunk headers need a verb: write `SWAP {s}.={s}:` or `DEL {s}.={s}`.",
        .{ quoted, start_line, end_line, start_line, end_line },
    );
}

pub fn malformedInputHeaderMessage(
    allocator: std.mem.Allocator,
    header: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const quoted = try jsonQuote(allocator, header);
    return std.fmt.allocPrint(
        allocator,
        "Input header must be [PATH] or [PATH#TAG] with a 4-hex content-hash tag; got {s}.",
        .{quoted},
    );
}

pub fn missingInputHeaderMessage(
    allocator: std.mem.Allocator,
    first_line: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const quoted = try jsonQuoteUtf16Slice(allocator, first_line, 120, false);
    return std.fmt.allocPrint(
        allocator,
        "input must begin with \"[PATH#HASH]\" on the first non-blank line for anchored edits; got: {s}. Example: \"[src/foo.ts#1A2B]\" then edit ops.",
        .{quoted},
    );
}

pub fn conflictingSnapshotTagsMessage(
    allocator: std.mem.Allocator,
    path: []const u8,
    first_tag: []const u8,
    second_tag: []const u8,
) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "Conflicting hashline snapshot tags for {s}: #{s} and #{s}. Re-read the file and retry with one current header.",
        .{ path, first_tag, second_tag },
    );
}

pub const warnings_block_header = "\n\nWarnings:\n";

pub fn lineOutOfBoundsMessage(
    allocator: std.mem.Allocator,
    line: usize,
    file_line_count: usize,
) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "Line {d} does not exist (file has {d} lines)",
        .{ line, file_line_count },
    );
}

pub fn fullAnchorRequirementMessage(
    allocator: std.mem.Allocator,
    raw: ?[]const u8,
) std.mem.Allocator.Error![]const u8 {
    const received = if (raw) |value|
        try std.fmt.allocPrint(allocator, " Received {s}.", .{try jsonQuote(allocator, value)})
    else
        "";
    return std.fmt.allocPrint(
        allocator,
        "a bare line number from read/search output plus the section header content-hash tag " ++
            "(for example [src/foo.ts#1A2B] and line \"160\"){s}",
        .{received},
    );
}

pub fn invalidLineReferenceMessage(
    allocator: std.mem.Allocator,
    raw: []const u8,
) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "Invalid line reference. Expected {s}.",
        .{try fullAnchorRequirementMessage(allocator, raw)},
    );
}

pub fn lineNumberMinimumMessage(
    allocator: std.mem.Allocator,
    line: usize,
    raw: []const u8,
) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "Line number must be >= 1, got {d} in \"{s}\".",
        .{ line, raw },
    );
}

pub fn duplicatedTrailingPayloadAction(
    allocator: std.mem.Allocator,
    count: usize,
) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "dropped {d} duplicated trailing payload line(s) already present below the range",
        .{count},
    );
}

pub fn duplicatedLeadingPayloadAction(
    allocator: std.mem.Allocator,
    count: usize,
) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "dropped {d} duplicated leading payload line(s) already present above the range",
        .{count},
    );
}

pub fn keptStructuralClosersAction(
    allocator: std.mem.Allocator,
    count: usize,
) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "kept {d} structural closing line(s) the range deleted without restating",
        .{count},
    );
}

pub fn mismatchRecognizedMessage(
    allocator: std.mem.Allocator,
    path: ?[]const u8,
    expected_hash: []const u8,
    actual_hash: []const u8,
) std.mem.Allocator.Error![]const u8 {
    if (path) |value| {
        return std.fmt.allocPrint(
            allocator,
            "Edit rejected for {s}: file changed between read and edit.\n" ++
                "Section is bound to #{s}, but the current file hashes to #{s}. If a prior edit in this session modified this file, copy the [path#newhash] header from that edit's response; otherwise re-read the file with `read` to refresh the tag before retrying.",
            .{ value, expected_hash, actual_hash },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "Edit rejected: file changed between read and edit.\n" ++
            "Section is bound to #{s}, but the current file hashes to #{s}. If a prior edit in this session modified this file, copy the [path#newhash] header from that edit's response; otherwise re-read the file with `read` to refresh the tag before retrying.",
        .{ expected_hash, actual_hash },
    );
}

pub fn mismatchUnrecognizedMessage(
    allocator: std.mem.Allocator,
    path: ?[]const u8,
    expected_hash: []const u8,
    actual_hash: []const u8,
) std.mem.Allocator.Error![]const u8 {
    if (path) |value| {
        return std.fmt.allocPrint(
            allocator,
            "Edit rejected for {s}: hash #{s} is not from this session.\n" ++
                "The current file hashes to #{s}. Re-read the file with `read` to copy a current [path#tag] header — never invent the tag and never reuse one from a prior session.",
            .{ value, expected_hash, actual_hash },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "Edit rejected: hash #{s} is not from this session.\n" ++
            "The current file hashes to #{s}. Re-read the file with `read` to copy a current [path#tag] header — never invent the tag and never reuse one from a prior session.",
        .{ expected_hash, actual_hash },
    );
}

pub fn noChangesMadeMessage(
    allocator: std.mem.Allocator,
    path: []const u8,
) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "Edits to {s} resulted in no changes being made.", .{path});
}

pub fn noChangeDiagnosticMessage(
    allocator: std.mem.Allocator,
    path: []const u8,
) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "Edits to {s} parsed and applied cleanly, but produced no change: your body row(s) are byte-identical to the file at the targeted lines. The bug is somewhere else — re-read the file before issuing another edit. Do NOT widen the payload or add lines; verify the anchor first.",
        .{path},
    );
}

pub fn fileNotFoundMessage(
    allocator: std.mem.Allocator,
    path: []const u8,
) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "File not found: {s}. Use the write tool to create new files.",
        .{path},
    );
}

pub fn moveDestinationSameMessage(
    allocator: std.mem.Allocator,
    path: []const u8,
) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "MV destination is the same as {s}.", .{path});
}

pub fn duplicateCanonicalPathMessage(
    allocator: std.mem.Allocator,
    first_path: []const u8,
    second_path: []const u8,
) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "Multiple hashline sections resolve to the same file ({s} and {s}). Merge their ops under one header before applying.",
        .{ first_path, second_path },
    );
}

pub fn aggregateCommitFailureMessage(
    allocator: std.mem.Allocator,
    failed_path: []const u8,
    cause: []const u8,
    already_applied: []const []const u8,
    not_applied: []const []const u8,
) std.mem.Allocator.Error![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    try output.print(allocator, "Error editing {s}: {s}", .{ failed_path, cause });
    if (already_applied.len > 0) {
        try output.appendSlice(allocator, "\nFiles already applied: ");
        for (already_applied, 0..) |path, index| {
            if (index > 0) try output.appendSlice(allocator, ", ");
            try output.appendSlice(allocator, path);
        }
        try output.append(allocator, '.');
    }
    if (not_applied.len > 0) {
        try output.appendSlice(allocator, "\nFiles NOT applied: ");
        for (not_applied, 0..) |path, index| {
            if (index > 0) try output.appendSlice(allocator, ", ");
            try output.appendSlice(allocator, path);
        }
        try output.appendSlice(
            allocator,
            "; re-read the affected files and re-issue only the failed and unapplied files.",
        );
    }
    return output.toOwnedSlice(allocator);
}

pub fn deletedSectionMessage(
    allocator: std.mem.Allocator,
    path: []const u8,
) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "Deleted {s}", .{path});
}

pub fn movedToMessage(
    allocator: std.mem.Allocator,
    destination: []const u8,
) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "Moved to {s}", .{destination});
}

pub fn blockResolutionEchoMessage(
    allocator: std.mem.Allocator,
    resolution: types.BlockResolution,
) std.mem.Allocator.Error![]const u8 {
    const op = switch (resolution.op) {
        .delete => "DEL.BLK",
        .insert_after => "INS.BLK.POST",
        .replace => "SWAP.BLK",
    };
    const line_count = resolution.end - resolution.start + 1;
    var output: std.ArrayList(u8) = .empty;
    try output.print(allocator, "{s} {d} → resolved ", .{ op, resolution.anchor_line });
    if (resolution.start == resolution.end) {
        try output.print(allocator, "line {d}", .{resolution.start});
    } else {
        try output.print(allocator, "lines {d}-{d}", .{ resolution.start, resolution.end });
    }
    try output.print(allocator, " ({d} line{s})", .{ line_count, if (line_count == 1) "" else "s" });
    if (resolution.op == .insert_after) {
        try output.print(allocator, "; body lands after line {d}", .{resolution.end});
    }
    return output.toOwnedSlice(allocator);
}

pub const recovery_external_warning =
    "Recovered from a stale file hash using a previous read snapshot (file changed externally between read and edit).";
pub const recovery_session_chain_warning =
    "Recovered from a stale file hash using an earlier in-session snapshot (a prior edit in this session advanced the hash).";
pub const recovery_session_replay_warning =
    "Recovered by replaying your edits onto the current file content (a prior in-session edit changed the lines you re-targeted with a stale hash). Verify the diff matches your intent.";
pub const recovery_line_remap_warning =
    "Recovered by remapping stale line anchors to unchanged current lines (file changed since the tagged read). Verify the diff matches your intent.";
pub const headtail_drift_warning =
    "Applied the `INS.HEAD:`/`INS.TAIL:` edit despite a stale snapshot tag (file changed since your read) — head/tail position is content-independent. Re-read if the drift was unexpected.";

pub const RevealedLine = struct {
    line: usize,
    text: []const u8,
};

pub const UnseenLinesReveal = struct {
    lines: []const RevealedLine = &.{},
    truncated: bool = false,
};

pub fn formatAnchoredContext(
    allocator: std.mem.Allocator,
    anchor_lines: []const usize,
    file_lines: []const []const u8,
) ![]const []const u8 {
    if (file_lines.len == 0 or anchor_lines.len == 0) return &.{};
    const display = try allocator.alloc(bool, file_lines.len);
    @memset(display, false);
    const anchors = try allocator.alloc(bool, file_lines.len);
    @memset(anchors, false);
    for (anchor_lines) |line| {
        if (line < 1 or line > file_lines.len) continue;
        anchors[line - 1] = true;
        const low = if (line > mismatch_context) line - mismatch_context else 1;
        const high = @min(file_lines.len, line + mismatch_context);
        for (low..high + 1) |line_number| display[line_number - 1] = true;
    }

    var rows: std.ArrayList([]const u8) = .empty;
    var previous: ?usize = null;
    for (display, 0..) |shown, index| {
        if (!shown) continue;
        const line_number = index + 1;
        if (previous) |prior| {
            if (line_number > prior + 1) try rows.append(allocator, "...");
        }
        const marker: u8 = if (anchors[index]) '*' else ' ';
        try rows.append(allocator, try std.fmt.allocPrint(allocator, "{c}{d}:{s}", .{
            marker,
            line_number,
            file_lines[index],
        }));
        previous = line_number;
    }
    return rows.toOwnedSlice(allocator);
}

pub fn blockUnresolvedMessage(
    allocator: std.mem.Allocator,
    line: usize,
    op: types.BlockResolutionOp,
    file_lines: ?[]const []const u8,
) ![]const u8 {
    const phrase = switch (op) {
        .delete => try std.fmt.allocPrint(allocator, "DEL.BLK {d}", .{line}),
        else => try std.fmt.allocPrint(allocator, "SWAP.BLK {d}:", .{line}),
    };
    const fallback = switch (op) {
        .delete => try std.fmt.allocPrint(allocator, "DEL {d}.=M", .{line}),
        else => try std.fmt.allocPrint(allocator, "SWAP {d}.=M:", .{line}),
    };
    var output: std.ArrayList(u8) = .empty;
    try output.print(
        allocator,
        "`{s}` could not resolve a syntactic block beginning on line {d} (unsupported language, blank/closer line, or parse error). Use `{s}` with explicit lines.",
        .{ phrase, line, fallback },
    );
    if (file_lines) |lines| {
        const context = try formatAnchoredContext(allocator, &.{line}, lines);
        if (context.len > 0) {
            try output.appendSlice(allocator, "\n\n");
            for (context, 0..) |row, index| {
                if (index > 0) try output.append(allocator, '\n');
                try output.appendSlice(allocator, row);
            }
        }
    }
    return output.toOwnedSlice(allocator);
}

pub fn insertAfterBlockCloserLoweredWarning(allocator: std.mem.Allocator, line: usize) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "`INS.BLK.POST {d}:` anchors on a closing delimiter, so it was applied as plain `INS.POST {d}:`. Anchor on the line that OPENS the construct.",
        .{ line, line },
    );
}

pub fn insertAfterBlockUnresolvedLoweredWarning(allocator: std.mem.Allocator, line: usize) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "`INS.BLK.POST {d}:` could not resolve a syntactic block on line {d}, so it was applied as plain `INS.POST {d}:`. Verify the landing line; anchor on a line that OPENS a construct.",
        .{ line, line, line },
    );
}

pub fn afterInsertLandingShiftWarning(
    allocator: std.mem.Allocator,
    anchor_line: usize,
    landing_line: usize,
    crossed: usize,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "INS.POST {d}: body indented shallower than the anchor, so the landing moved past {d} closing line{s} to after line {d}. For the deeper position inside the block, re-issue with the body indented to match.",
        .{ anchor_line, crossed, if (crossed == 1) "" else "s", landing_line },
    );
}

pub fn blockInsertLandingShiftWarning(
    allocator: std.mem.Allocator,
    block_start: usize,
    closer_line: usize,
    landing_line: usize,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "INS.BLK.POST {d}: body indented deeper than closing line {d}, so it was placed inside the block, after line {d}. `INS.BLK.POST` lands AFTER the block at sibling depth — if inside was intended, use plain `INS.POST {d}:`.",
        .{ block_start, closer_line, landing_line, closer_line },
    );
}

pub fn missingSnapshotTagMessage(allocator: std.mem.Allocator, section_path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "Missing hashline snapshot tag for {s}; use `[{s}#tag]` from your latest read/search output. To create a new file, use the write tool.",
        .{ section_path, section_path },
    );
}

pub fn pathRecoveredFromTagMessage(
    allocator: std.mem.Allocator,
    authored_path: []const u8,
    resolved_path: []const u8,
    tag: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "Path \"{s}\" does not exist; matched its filename and snapshot tag #{s} to {s} (read earlier this session). Anchor future edits on [{s}#TAG].",
        .{ authored_path, tag, resolved_path, resolved_path },
    );
}

pub fn unseenLinesMessage(
    allocator: std.mem.Allocator,
    section_path: []const u8,
    unseen_lines: []const usize,
    tag: []const u8,
    reveal: UnseenLinesReveal,
) ![]const u8 {
    const ranges = try formatLineRanges(allocator, unseen_lines, ", ");
    const selector = try formatLineRanges(allocator, unseen_lines, ",");
    var output: std.ArrayList(u8) = .empty;
    try output.print(
        allocator,
        "This edit anchors to lines {s} of {s} that [{s}#{s}] never displayed (it showed a partial range, a search hit, or a folded summary).",
        .{ ranges, section_path, section_path, tag },
    );
    if (reveal.lines.len == 0) {
        try output.print(
            allocator,
            " Re-read them in full first with a ranged read like `{s}:{s}` — it skips summarization and mints a fresh tag (a plain re-read just re-folds them) — then re-issue the edit.",
            .{ section_path, selector },
        );
        return output.toOwnedSlice(allocator);
    }

    if (reveal.truncated) {
        try output.print(
            allocator,
            " Preview of the actual file content at the first {d} unseen line(s):\n",
            .{reveal.lines.len},
        );
    } else {
        try output.appendSlice(allocator, " Actual file content at those lines:\n");
    }
    for (reveal.lines, 0..) |entry, index| {
        if (index > 0) try output.append(allocator, '\n');
        try output.print(allocator, "  {d}:{s}", .{ entry.line, entry.text });
    }
    if (reveal.truncated) {
        try output.print(
            allocator,
            "\nThe range exceeds the inline preview cap — re-read the remainder with `{s}:{s}` before re-issuing the edit.",
            .{ section_path, selector },
        );
    } else {
        try output.appendSlice(
            allocator,
            "\nVerify the content matches what you intend to touch, then re-issue the edit with the same [path#tag] header — a straight retry now succeeds without a re-read. If the content does NOT match, fix your line numbers.",
        );
    }
    return output.toOwnedSlice(allocator);
}

fn formatLineRanges(allocator: std.mem.Allocator, lines: []const usize, separator: []const u8) ![]const u8 {
    if (lines.len == 0) return allocator.dupe(u8, "");
    const sorted = try allocator.dupe(usize, lines);
    std.mem.sort(usize, sorted, {}, std.sort.asc(usize));
    var output: std.ArrayList(u8) = .empty;
    var start = sorted[0];
    var previous = sorted[0];
    var index: usize = 1;
    while (index <= sorted.len) : (index += 1) {
        const current = if (index < sorted.len) sorted[index] else 0;
        if (index < sorted.len and current == previous) continue;
        if (index < sorted.len and current == previous + 1) {
            previous = current;
            continue;
        }
        if (output.items.len > 0) try output.appendSlice(allocator, separator);
        if (start == previous) try output.print(allocator, "{d}", .{start}) else try output.print(allocator, "{d}-{d}", .{ start, previous });
        if (index < sorted.len) {
            start = current;
            previous = current;
        }
    }
    return output.toOwnedSlice(allocator);
}

pub fn blockSingleLineMessage(
    allocator: std.mem.Allocator,
    line: usize,
    op: types.BlockResolutionOp,
) ![]const u8 {
    const block_form = switch (op) {
        .insert_after => "INS.BLK.POST",
        .delete => "DEL.BLK",
        .replace => "SWAP.BLK",
    };
    const plain_form = switch (op) {
        .insert_after => try std.fmt.allocPrint(allocator, "INS.POST {d}:", .{line}),
        .delete => try std.fmt.allocPrint(allocator, "DEL {d}", .{line}),
        .replace => try std.fmt.allocPrint(allocator, "SWAP {d}.={d}:", .{ line, line }),
    };
    return std.fmt.allocPrint(
        allocator,
        "`{s} {d}` resolved a single-line block — line {d} is a bare statement, not the opening line of a multi-line construct. For that one line use `{s}`; to act on an enclosing construct, anchor {s} on the line that OPENS it (e.g. its `function`/`if`/`case` header), never a statement inside it.",
        .{ block_form, line, line, plain_form, block_form },
    );
}

pub fn boundaryEchoRepair(
    allocator: std.mem.Allocator,
    start_line: usize,
    leading: usize,
    trailing: usize,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "Auto-repaired a replacement boundary echo at line {d}: dropped {d} leading and {d} trailing payload line(s) already present outside the range. Issue the payload as the final desired content for the selected range only — never restate unchanged lines bordering the range.",
        .{ start_line, leading, trailing },
    );
}

pub fn delimiterBalanceRepair(
    allocator: std.mem.Allocator,
    start_line: usize,
    action: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "Auto-repaired a delimiter-balance mismatch in the replacement at line {d}: {s}. Issue the payload as the final desired content only — never restate or omit a closing bracket bordering the range.",
        .{ start_line, action },
    );
}

pub fn oneSidedBoundaryEchoRepair(
    allocator: std.mem.Allocator,
    start_line: usize,
    leading: bool,
    count: usize,
) ![]const u8 {
    const side = if (leading) "leading" else "trailing";
    const where = if (leading) "above" else "below";
    return std.fmt.allocPrint(
        allocator,
        "Auto-repaired a replacement boundary echo at line {d}: dropped {d} {s} payload line(s) identical to the surviving line(s) just {s} the range. The range was one line short of the content you retyped — issue the payload as the final content for the selected range only, and widen the range to consume any keeper you restate.",
        .{ start_line, count, side, where },
    );
}

test "hashline messages: missing snapshot tag is byte exact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const message = try missingSnapshotTagMessage(arena.allocator(), "src/a.ts");
    try std.testing.expectEqualStrings(
        "Missing hashline snapshot tag for src/a.ts; use `[src/a.ts#tag]` from your latest read/search output. To create a new file, use the write tool.",
        message,
    );
}

test "hashline messages: apply mismatch and patcher builders are byte exact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings(
        "Line 4 does not exist (file has 2 lines)",
        try lineOutOfBoundsMessage(allocator, 4, 2),
    );
    try std.testing.expectEqualStrings(
        "dropped 2 duplicated trailing payload line(s) already present below the range",
        try duplicatedTrailingPayloadAction(allocator, 2),
    );
    try std.testing.expectEqualStrings(
        "Edit rejected for a.ts: file changed between read and edit.\n" ++
            "Section is bound to #1A2B, but the current file hashes to #3C4D. If a prior edit in this session modified this file, copy the [path#newhash] header from that edit's response; otherwise re-read the file with `read` to refresh the tag before retrying.",
        try mismatchRecognizedMessage(allocator, "a.ts", "1A2B", "3C4D"),
    );
    try std.testing.expectEqualStrings(
        "Error editing b.ts: disk full\n" ++
            "Files already applied: a.ts.\n" ++
            "Files NOT applied: c.ts, d.ts; re-read the affected files and re-issue only the failed and unapplied files.",
        try aggregateCommitFailureMessage(
            allocator,
            "b.ts",
            "disk full",
            &.{"a.ts"},
            &.{ "c.ts", "d.ts" },
        ),
    );
}

test "hashline messages: render builders are byte exact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("Deleted a.ts", try deletedSectionMessage(allocator, "a.ts"));
    try std.testing.expectEqualStrings("Moved to b.ts", try movedToMessage(allocator, "b.ts"));
    try std.testing.expectEqualStrings(
        "INS.BLK.POST 2 → resolved lines 2-3 (2 lines); body lands after line 3",
        try blockResolutionEchoMessage(allocator, .{
            .anchor_line = 2,
            .start = 2,
            .end = 3,
            .op = .insert_after,
        }),
    );
}

test "hashline messages: UTF-16 diagnostic previews escape a split surrogate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const prefix47 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const sentinel = try std.mem.concat(allocator, u8, &.{ prefix47, "😀tail" });
    const sentinel_message = try applyPatchSentinelMessage(allocator, sentinel);
    try std.testing.expect(std.mem.indexOf(u8, sentinel_message, "\\ud83d…\"") != null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(sentinel_message));

    const prefix119 = try allocator.alloc(u8, 119);
    @memset(prefix119, 'a');
    const first_line = try std.mem.concat(allocator, u8, &.{ prefix119, "😀tail" });
    const header_message = try missingInputHeaderMessage(allocator, first_line);
    try std.testing.expect(std.mem.indexOf(u8, header_message, "\\ud83d\"") != null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(header_message));
}
