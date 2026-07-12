//! Line-level Myers diff and strict structured-patch application.
//!
//! All returned slices are allocated by the caller-provided allocator. The
//! implementation intentionally matches jsdiff's shortest-edit-path tie rule:
//! when add/remove paths reach the same old-file position, removal wins.

const std = @import("std");

pub const ChangeKind = enum {
    equal,
    add,
    remove,
};

pub const Change = struct {
    kind: ChangeKind,
    lines: []const []const u8,
};

pub const PatchLineKind = enum {
    context,
    add,
    remove,
};

pub const PatchLine = struct {
    kind: PatchLineKind,
    text: []const u8,
};

pub const Hunk = struct {
    old_start: usize,
    old_lines: usize,
    new_start: usize,
    new_lines: usize,
    lines: []const PatchLine,
};

pub const StructuredPatch = struct {
    hunks: []const Hunk,
};

pub const LineMap = struct {
    /// Dense 1-indexed mapping. Slot zero is always null.
    old_to_new: []const ?usize,

    pub fn get(self: LineMap, old_line: usize) ?usize {
        if (old_line == 0 or old_line >= self.old_to_new.len) return null;
        return self.old_to_new[old_line];
    }
};

pub const NumberedDiff = struct {
    diff: []const u8,
    first_changed_line: ?usize,
};

const Atomic = struct {
    kind: ChangeKind,
    line: []const u8,
};

/// Split LF text exactly like JavaScript's `text.split("\n")`, retaining the
/// final empty row when the text ends in a newline and returning one empty row
/// for an empty string.
pub fn splitLines(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var iterator = std.mem.splitScalar(u8, text, '\n');
    while (iterator.next()) |line| try lines.append(allocator, line);
    return lines.toOwnedSlice(allocator);
}

/// Myers shortest-edit-path diff over line arrays with strict byte equality.
pub fn diffArrays(
    allocator: std.mem.Allocator,
    old_lines: []const []const u8,
    new_lines: []const []const u8,
) ![]const Change {
    const max_edit = try std.math.add(usize, old_lines.len, new_lines.len);
    const diagonal_count = try std.math.add(usize, try std.math.mul(usize, max_edit, 2), 3);
    const offset: isize = @intCast(max_edit + 1);
    const old_len: isize = @intCast(old_lines.len);
    const new_len: isize = @intCast(new_lines.len);

    var frontier = try allocator.alloc(isize, diagonal_count);
    defer allocator.free(frontier);
    @memset(frontier, -1);
    frontier[diagonalIndex(offset, 1)] = 0;

    var trace: std.ArrayList([]isize) = .empty;
    defer {
        for (trace.items) |snapshot| allocator.free(snapshot);
        trace.deinit(allocator);
    }

    var final_distance: usize = 0;
    var found = false;
    var distance: usize = 0;
    while (distance <= max_edit) : (distance += 1) {
        const signed_distance: isize = @intCast(distance);
        var diagonal = -signed_distance;
        while (diagonal <= signed_distance) : (diagonal += 2) {
            // Same tie rule as jsdiff: add only when it reaches strictly farther
            // in the old input; equal positions choose removal.
            const came_from_add = diagonal == -signed_distance or
                (diagonal != signed_distance and
                    frontier[diagonalIndex(offset, diagonal - 1)] < frontier[diagonalIndex(offset, diagonal + 1)]);
            var x: isize = if (came_from_add)
                frontier[diagonalIndex(offset, diagonal + 1)]
            else
                frontier[diagonalIndex(offset, diagonal - 1)] + 1;
            var y = x - diagonal;
            while (x < old_len and y < new_len and x >= 0 and y >= 0 and
                std.mem.eql(u8, old_lines[@intCast(x)], new_lines[@intCast(y)]))
            {
                x += 1;
                y += 1;
            }
            frontier[diagonalIndex(offset, diagonal)] = x;
            if (x >= old_len and y >= new_len) {
                found = true;
                final_distance = distance;
                break;
            }
        }
        try trace.append(allocator, try allocator.dupe(isize, frontier));
        if (found) break;
    }
    std.debug.assert(found);

    var reversed: std.ArrayList(Atomic) = .empty;
    defer reversed.deinit(allocator);
    var x: isize = old_len;
    var y: isize = new_len;
    var d = final_distance;
    while (d > 0) : (d -= 1) {
        const signed_d: isize = @intCast(d);
        const diagonal = x - y;
        const previous = trace.items[d - 1];
        const came_from_add = diagonal == -signed_d or
            (diagonal != signed_d and
                previous[diagonalIndex(offset, diagonal - 1)] < previous[diagonalIndex(offset, diagonal + 1)]);
        const previous_diagonal = if (came_from_add) diagonal + 1 else diagonal - 1;
        const previous_x = previous[diagonalIndex(offset, previous_diagonal)];
        const previous_y = previous_x - previous_diagonal;

        while (x > previous_x and y > previous_y) {
            x -= 1;
            y -= 1;
            try reversed.append(allocator, .{ .kind = .equal, .line = new_lines[@intCast(y)] });
        }
        if (came_from_add) {
            y -= 1;
            try reversed.append(allocator, .{ .kind = .add, .line = new_lines[@intCast(y)] });
        } else {
            x -= 1;
            try reversed.append(allocator, .{ .kind = .remove, .line = old_lines[@intCast(x)] });
        }
    }
    while (x > 0 and y > 0) {
        x -= 1;
        y -= 1;
        try reversed.append(allocator, .{ .kind = .equal, .line = new_lines[@intCast(y)] });
    }
    while (x > 0) {
        x -= 1;
        try reversed.append(allocator, .{ .kind = .remove, .line = old_lines[@intCast(x)] });
    }
    while (y > 0) {
        y -= 1;
        try reversed.append(allocator, .{ .kind = .add, .line = new_lines[@intCast(y)] });
    }
    std.mem.reverse(Atomic, reversed.items);

    var changes: std.ArrayList(Change) = .empty;
    var index: usize = 0;
    while (index < reversed.items.len) {
        const kind = reversed.items[index].kind;
        var end = index + 1;
        while (end < reversed.items.len and reversed.items[end].kind == kind) : (end += 1) {}
        const values = try allocator.alloc([]const u8, end - index);
        for (values, reversed.items[index..end]) |*slot, atom| slot.* = atom.line;
        try changes.append(allocator, .{ .kind = kind, .lines = values });
        index = end;
    }
    return changes.toOwnedSlice(allocator);
}

pub fn diffText(
    allocator: std.mem.Allocator,
    old_text: []const u8,
    new_text: []const u8,
) ![]const Change {
    const old_lines = try splitLines(allocator, old_text);
    const new_lines = try splitLines(allocator, new_text);
    return diffArrays(allocator, old_lines, new_lines);
}

/// Produce the numbered diff rows consumed by the compact preview renderer.
/// Context and removed rows use old-file coordinates; added rows use new-file
/// coordinates. Unchanged regions are clipped to `context_lines` around edits.
pub fn buildNumberedDiff(
    allocator: std.mem.Allocator,
    old_text: []const u8,
    new_text: []const u8,
    context_lines: usize,
) !NumberedDiff {
    const old_tokens = try splitLineTokens(allocator, old_text);
    const new_tokens = try splitLineTokens(allocator, new_text);
    const changes = try diffArrays(allocator, old_tokens, new_tokens);
    var output: std.ArrayList(u8) = .empty;
    var old_line: usize = 1;
    var new_line: usize = 1;
    var first_changed_line: ?usize = null;
    var last_was_change = false;

    for (changes, 0..) |change, index| {
        if (change.kind != .equal) {
            if (first_changed_line == null) first_changed_line = new_line;
            for (change.lines) |token| {
                if (change.kind == .add) {
                    try appendNumberedRow(allocator, &output, '+', new_line, tokenContent(token));
                    new_line += 1;
                } else {
                    try appendNumberedRow(allocator, &output, '-', old_line, tokenContent(token));
                    old_line += 1;
                }
            }
            last_was_change = true;
            continue;
        }

        const next_is_change = index + 1 < changes.len and changes[index + 1].kind != .equal;
        if (!last_was_change and !next_is_change) {
            old_line += change.lines.len;
            new_line += change.lines.len;
            last_was_change = false;
            continue;
        }

        if (last_was_change and next_is_change) {
            const doubled_context = context_lines *| 2;
            if (change.lines.len > doubled_context) {
                for (change.lines[0..context_lines]) |token| {
                    try appendNumberedRow(allocator, &output, ' ', old_line, tokenContent(token));
                    old_line += 1;
                    new_line += 1;
                }
                const skipped = change.lines.len - doubled_context;
                old_line += skipped;
                new_line += skipped;
                for (change.lines[change.lines.len - context_lines ..]) |token| {
                    try appendNumberedRow(allocator, &output, ' ', old_line, tokenContent(token));
                    old_line += 1;
                    new_line += 1;
                }
            } else {
                for (change.lines) |token| {
                    try appendNumberedRow(allocator, &output, ' ', old_line, tokenContent(token));
                    old_line += 1;
                    new_line += 1;
                }
            }
        } else if (next_is_change) {
            const skipped = change.lines.len - @min(context_lines, change.lines.len);
            old_line += skipped;
            new_line += skipped;
            for (change.lines[skipped..]) |token| {
                try appendNumberedRow(allocator, &output, ' ', old_line, tokenContent(token));
                old_line += 1;
                new_line += 1;
            }
        } else {
            const shown = @min(context_lines, change.lines.len);
            for (change.lines[0..shown]) |token| {
                try appendNumberedRow(allocator, &output, ' ', old_line, tokenContent(token));
                old_line += 1;
                new_line += 1;
            }
            const skipped = change.lines.len - shown;
            old_line += skipped;
            new_line += skipped;
        }
        last_was_change = false;
    }
    const numbered = try output.toOwnedSlice(allocator);
    return .{
        .diff = try addMatchingBracketContextRows(allocator, numbered, old_text, new_text),
        .first_changed_line = first_changed_line,
    };
}

const ParsedNumberedRow = struct {
    prefix: u8,
    line_number: usize,
    content: []const u8,
};

const ContextRow = struct {
    line_number: usize,
    text: []const u8,
};

const ChangePosition = struct {
    new_position: isize,
    delta: isize,
};

const BracketStackEntry = struct {
    opener: u8,
    line_number: usize,
    text: []const u8,
    visible: bool,
};

const ScannerMode = enum {
    code,
    single,
    double,
    template,
    block_comment,
};

/// Surface matching block boundaries outside the ordinary diff window. This
/// is the lexical fallback from coding-agent's block-context helper; the Zig
/// hashline library deliberately has no tree-sitter dependency.
fn addMatchingBracketContextRows(
    allocator: std.mem.Allocator,
    numbered: []const u8,
    old_text: []const u8,
    new_text: []const u8,
) ![]const u8 {
    if (numbered.len == 0) return allocator.dupe(u8, numbered);

    var rows: std.ArrayList([]const u8) = .empty;
    var row_iterator = std.mem.splitScalar(u8, numbered, '\n');
    while (row_iterator.next()) |row| try rows.append(allocator, row);

    var old_visible: std.ArrayList(usize) = .empty;
    var new_visible: std.ArrayList(usize) = .empty;
    var changes: std.ArrayList(ChangePosition) = .empty;
    var offset: isize = 0;

    for (rows.items) |row| {
        const parsed = parseNumberedDiffRow(row) orelse continue;
        const line_number: isize = @intCast(parsed.line_number);
        switch (parsed.prefix) {
            '-' => {
                try old_visible.append(allocator, parsed.line_number);
                try changes.append(allocator, .{ .new_position = line_number + offset, .delta = -1 });
                offset -= 1;
            },
            '+' => {
                try new_visible.append(allocator, parsed.line_number);
                try changes.append(allocator, .{ .new_position = line_number, .delta = 1 });
                offset += 1;
            },
            ' ' => {
                try old_visible.append(allocator, parsed.line_number);
                const new_line_number = line_number + offset;
                if (new_line_number > 0) try new_visible.append(allocator, @intCast(new_line_number));
            },
            else => {},
        }
    }

    const old_lines = try splitLines(allocator, old_text);
    const new_lines = try splitLines(allocator, new_text);
    var context_rows: std.ArrayList(ContextRow) = .empty;
    try lexicalBracketContext(allocator, old_lines, old_visible.items, &context_rows);

    var new_context: std.ArrayList(ContextRow) = .empty;
    try lexicalBracketContext(allocator, new_lines, new_visible.items, &new_context);
    for (new_context.items) |entry| {
        const new_line_number: isize = @intCast(entry.line_number);
        var shift: isize = 0;
        for (changes.items) |change| {
            if (change.new_position <= new_line_number) shift += change.delta;
        }
        const old_line_number = new_line_number - shift;
        if (old_line_number > 0) {
            try appendContextRowIfAbsent(allocator, &context_rows, .{
                .line_number = @intCast(old_line_number),
                .text = entry.text,
            });
        }
    }

    std.mem.sort(ContextRow, context_rows.items, {}, struct {
        fn lessThan(_: void, left: ContextRow, right: ContextRow) bool {
            return left.line_number < right.line_number;
        }
    }.lessThan);

    for (context_rows.items) |entry| {
        if (hasContextRow(rows.items, entry)) continue;

        var insert_index = rows.items.len;
        var previous_source_line: ?usize = null;
        var next_source_line: ?usize = null;
        for (rows.items, 0..) |row, row_index| {
            const source_line = parseSourceRowLineNumber(row) orelse continue;
            if (source_line < entry.line_number) {
                previous_source_line = source_line;
                continue;
            }
            next_source_line = source_line;
            insert_index = row_index;
            break;
        }

        const context_row = try std.fmt.allocPrint(allocator, " {d}|{s}", .{ entry.line_number, entry.text });
        var chunk: [3][]const u8 = undefined;
        var chunk_len: usize = 0;
        if (previous_source_line) |previous| {
            if (entry.line_number > previous + 1) {
                chunk[chunk_len] = "";
                chunk_len += 1;
            }
        }
        chunk[chunk_len] = context_row;
        chunk_len += 1;
        if (next_source_line) |next| {
            if (next > entry.line_number + 1) {
                chunk[chunk_len] = "";
                chunk_len += 1;
            }
        }

        try rows.insertSlice(allocator, adjustedContextInsertIndex(rows.items, insert_index), chunk[0..chunk_len]);
    }

    normalizeDiffGapRows(&rows);
    var expanded: std.ArrayList(u8) = .empty;
    for (rows.items, 0..) |row, index| {
        if (index > 0) try expanded.append(allocator, '\n');
        try expanded.appendSlice(allocator, row);
    }
    return expanded.toOwnedSlice(allocator);
}

fn parseNumberedDiffRow(row: []const u8) ?ParsedNumberedRow {
    if (row.len < 3 or (row[0] != '+' and row[0] != '-' and row[0] != ' ')) return null;
    const separator = std.mem.indexOfScalarPos(u8, row, 1, '|') orelse return null;
    if (separator == 1) return null;
    const line_number = std.fmt.parseInt(usize, row[1..separator], 10) catch return null;
    return .{ .prefix = row[0], .line_number = line_number, .content = row[separator + 1 ..] };
}

fn parseSourceRowLineNumber(row: []const u8) ?usize {
    const parsed = parseNumberedDiffRow(row) orelse return null;
    return if (parsed.prefix == '+') null else parsed.line_number;
}

fn isDiffChangeRow(row: []const u8) bool {
    return row.len > 0 and (row[0] == '+' or row[0] == '-');
}

fn adjustedContextInsertIndex(rows: []const []const u8, index: usize) usize {
    var start = index;
    while (start > 0 and isDiffChangeRow(rows[start - 1])) start -= 1;
    var end = index;
    while (end < rows.len and isDiffChangeRow(rows[end])) end += 1;
    return if (index > start and index < end) end else index;
}

fn normalizeDiffGapRows(rows: *std.ArrayList([]const u8)) void {
    var write_index: usize = 0;
    for (0..rows.items.len) |read_index| {
        const row = rows.items[read_index];
        if (row.len != 0) {
            rows.items[write_index] = row;
            write_index += 1;
            continue;
        }
        if (write_index == 0 or rows.items[write_index - 1].len == 0) continue;

        var before: ?usize = null;
        var before_index = write_index;
        while (before_index > 0 and before == null) {
            before_index -= 1;
            before = parseSourceRowLineNumber(rows.items[before_index]);
        }
        var after: ?usize = null;
        var after_index = read_index + 1;
        while (after_index < rows.items.len and after == null) : (after_index += 1) {
            if (rows.items[after_index].len == 0) continue;
            after = parseSourceRowLineNumber(rows.items[after_index]);
        }
        if (before == null or after == null or after.? <= before.? + 1) continue;
        rows.items[write_index] = row;
        write_index += 1;
    }
    rows.shrinkRetainingCapacity(write_index);
}

fn hasContextRow(rows: []const []const u8, entry: ContextRow) bool {
    for (rows) |row| {
        const parsed = parseNumberedDiffRow(row) orelse continue;
        if (parsed.prefix == ' ' and parsed.line_number == entry.line_number and
            std.mem.eql(u8, parsed.content, entry.text)) return true;
    }
    return false;
}

fn appendContextRowIfAbsent(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(ContextRow),
    entry: ContextRow,
) !void {
    for (rows.items) |existing| if (existing.line_number == entry.line_number) return;
    try rows.append(allocator, entry);
}

fn lexicalBracketContext(
    allocator: std.mem.Allocator,
    full_lines: []const []const u8,
    visible_lines: []const usize,
    context: *std.ArrayList(ContextRow),
) !void {
    if (visible_lines.len == 0 or visible_lines.len >= full_lines.len) return;
    const visible = try allocator.alloc(bool, full_lines.len + 1);
    @memset(visible, false);
    for (visible_lines) |line_number| {
        if (line_number > 0 and line_number <= full_lines.len) visible[line_number] = true;
    }

    var stack: std.ArrayList(BracketStackEntry) = .empty;
    var mode: ScannerMode = .code;
    var escaped = false;

    for (full_lines, 1..) |line, line_number| {
        const line_visible = visible[line_number];
        var index: usize = 0;
        while (index < line.len) {
            const character = line[index];
            const next = if (index + 1 < line.len) line[index + 1] else 0;

            if (mode == .block_comment) {
                if (character == '*' and next == '/') {
                    mode = .code;
                    index += 2;
                } else {
                    index += 1;
                }
                continue;
            }

            if (mode == .single or mode == .double or mode == .template) {
                if (escaped) {
                    escaped = false;
                    index += 1;
                    continue;
                }
                if (character == '\\') {
                    escaped = true;
                    index += 1;
                    continue;
                }
                if ((mode == .single and character == '\'') or
                    (mode == .double and character == '"') or
                    (mode == .template and character == '`')) mode = .code;
                index += 1;
                continue;
            }

            if (character == '/' and next == '/') break;
            if (character == '/' and next == '*') {
                mode = .block_comment;
                index += 2;
                continue;
            }
            if (isHashCommentStart(line, index)) break;
            if (character == '\'') {
                mode = .single;
                escaped = false;
                index += 1;
                continue;
            }
            if (character == '"') {
                mode = .double;
                escaped = false;
                index += 1;
                continue;
            }
            if (character == '`') {
                mode = .template;
                escaped = false;
                index += 1;
                continue;
            }

            if (isOpeningBracket(character)) {
                try stack.append(allocator, .{
                    .opener = character,
                    .line_number = line_number,
                    .text = line,
                    .visible = line_visible,
                });
                index += 1;
                continue;
            }

            if (matchingOpener(character)) |opener| {
                if (findMatchingStackIndex(stack.items, opener)) |match_index| {
                    const matched = stack.items[match_index];
                    stack.shrinkRetainingCapacity(match_index);
                    if (line_visible and !matched.visible) {
                        try appendContextRowIfAbsent(allocator, context, .{
                            .line_number = matched.line_number,
                            .text = matched.text,
                        });
                    }
                    if (matched.visible and !line_visible) {
                        try appendContextRowIfAbsent(allocator, context, .{
                            .line_number = line_number,
                            .text = line,
                        });
                    }
                }
            }
            index += 1;
        }

        if (mode == .single or mode == .double) {
            mode = .code;
            escaped = false;
        }
    }
}

fn isOpeningBracket(character: u8) bool {
    return character == '(' or character == '[' or character == '{';
}

fn matchingOpener(character: u8) ?u8 {
    return switch (character) {
        ')' => '(',
        ']' => '[',
        '}' => '{',
        else => null,
    };
}

fn findMatchingStackIndex(stack: []const BracketStackEntry, opener: u8) ?usize {
    var index = stack.len;
    while (index > 0) {
        index -= 1;
        if (stack[index].opener == opener) return index;
    }
    return null;
}

fn isHashCommentStart(line: []const u8, index: usize) bool {
    if (line[index] != '#') return false;
    for (line[0..index]) |character| {
        if (character != ' ' and character != '\t') return false;
    }
    return true;
}

const WorkingHunk = struct {
    old_start: usize,
    new_start: usize,
    lines: std.ArrayList(PatchLine) = .empty,
};

/// Build structured line hunks with the requested number of unchanged context
/// rows. Recovery uses three, matching upstream.
pub fn createStructuredPatch(
    allocator: std.mem.Allocator,
    old_text: []const u8,
    new_text: []const u8,
    context: usize,
) !StructuredPatch {
    // Patch generation follows jsdiff's `diffLines`: newline delimiters are
    // part of each token, so a normal trailing newline is not a phantom context
    // row and EOF-newline-only changes remain observable.
    const old_tokens = try splitLineTokens(allocator, old_text);
    const new_tokens = try splitLineTokens(allocator, new_text);
    const changes = try diffArrays(allocator, old_tokens, new_tokens);
    var hunks: std.ArrayList(Hunk) = .empty;
    var active: ?WorkingHunk = null;
    var previous_equal: []const []const u8 = &.{};
    var old_line: usize = 1;
    var new_line: usize = 1;

    for (changes, 0..) |change, change_index| {
        switch (change.kind) {
            .equal => {
                if (active) |*working| {
                    const later_change = hasAuthoredChange(changes[change_index + 1 ..]);
                    if (later_change and change.lines.len <= context *| 2) {
                        for (change.lines) |line| try working.lines.append(allocator, .{ .kind = .context, .text = line });
                    } else {
                        const trailing = @min(context, change.lines.len);
                        for (change.lines[0..trailing]) |line| try working.lines.append(allocator, .{ .kind = .context, .text = line });
                        try finishHunk(allocator, &hunks, working);
                        active = null;
                    }
                }
                old_line += change.lines.len;
                new_line += change.lines.len;
                previous_equal = change.lines;
            },
            .add, .remove => {
                if (active == null) {
                    const leading = @min(context, previous_equal.len);
                    active = .{
                        .old_start = old_line - leading,
                        .new_start = new_line - leading,
                    };
                    if (leading > 0) {
                        for (previous_equal[previous_equal.len - leading ..]) |line| {
                            try active.?.lines.append(allocator, .{ .kind = .context, .text = line });
                        }
                    }
                }
                const kind: PatchLineKind = if (change.kind == .add) .add else .remove;
                for (change.lines) |line| try active.?.lines.append(allocator, .{ .kind = kind, .text = line });
                if (change.kind == .add) new_line += change.lines.len else old_line += change.lines.len;
            },
        }
    }
    if (active) |*working| try finishHunk(allocator, &hunks, working);
    return .{ .hunks = try hunks.toOwnedSlice(allocator) };
}

/// Apply structured hunks with fuzz zero: every context/removal row must match
/// byte-for-byte. As in jsdiff, an exact hunk may relocate; candidates are tried
/// at the authored position, then +1, -1, +2, -2, and so on.
pub fn applyStructuredPatch(
    allocator: std.mem.Allocator,
    source: []const u8,
    patch: StructuredPatch,
) !?[]const u8 {
    if (patch.hunks.len == 0) return @as(?[]const u8, try allocator.dupe(u8, source));
    const source_lines = try splitLineTokens(allocator, source);
    const placements = try allocator.alloc(usize, patch.hunks.len);
    var minimum_line: usize = 0;
    var previous_offset: isize = 0;

    for (patch.hunks, 0..) |hunk, hunk_index| {
        if (source_lines.len < hunk.old_lines) return null;
        const maximum_line = source_lines.len - hunk.old_lines;
        const expected = @as(isize, @intCast(hunk.old_start)) + previous_offset - 1;
        const placement = findExactPlacement(source_lines, hunk, expected, minimum_line, maximum_line) orelse return null;
        placements[hunk_index] = placement;
        minimum_line = placement + hunk.old_lines;
        previous_offset = @as(isize, @intCast(placement + 1)) - @as(isize, @intCast(hunk.old_start));
    }

    var output_lines: std.ArrayList([]const u8) = .empty;
    var source_index: usize = 0;
    for (patch.hunks, placements) |hunk, placement| {
        while (source_index < placement) : (source_index += 1) try output_lines.append(allocator, source_lines[source_index]);
        for (hunk.lines) |line| switch (line.kind) {
            .context => {
                try output_lines.append(allocator, source_lines[source_index]);
                source_index += 1;
            },
            .remove => source_index += 1,
            .add => try output_lines.append(allocator, line.text),
        };
    }
    while (source_index < source_lines.len) : (source_index += 1) try output_lines.append(allocator, source_lines[source_index]);
    return @as(?[]const u8, try joinTokens(allocator, output_lines.items));
}

/// Map each unchanged old line to its corresponding current line through the
/// Myers diff. Changed/deleted old lines remain null.
pub fn buildLineMap(
    allocator: std.mem.Allocator,
    old_text: []const u8,
    current_text: []const u8,
) !LineMap {
    const old_lines = try splitLines(allocator, old_text);
    const current_lines = try splitLines(allocator, current_text);
    const changes = try diffArrays(allocator, old_lines, current_lines);
    const mapping = try allocator.alloc(?usize, old_lines.len + 1);
    @memset(mapping, null);
    var old_line: usize = 1;
    var current_line: usize = 1;
    for (changes) |change| switch (change.kind) {
        .add => current_line += change.lines.len,
        .remove => old_line += change.lines.len,
        .equal => {
            for (0..change.lines.len) |line_offset| mapping[old_line + line_offset] = current_line + line_offset;
            old_line += change.lines.len;
            current_line += change.lines.len;
        },
    };
    return .{ .old_to_new = mapping };
}

fn diagonalIndex(offset: isize, diagonal: isize) usize {
    return @intCast(offset + diagonal);
}

fn splitLineTokens(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var tokens: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, start, '\n')) |newline| {
        try tokens.append(allocator, text[start .. newline + 1]);
        start = newline + 1;
    }
    if (start < text.len) try tokens.append(allocator, text[start..]);
    return tokens.toOwnedSlice(allocator);
}

fn tokenContent(token: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, token, "\n")) token[0 .. token.len - 1] else token;
}

fn appendNumberedRow(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    prefix: u8,
    line_number: usize,
    content: []const u8,
) !void {
    if (output.items.len > 0) try output.append(allocator, '\n');
    try output.print(allocator, "{c}{d}|{s}", .{ prefix, line_number, content });
}

fn hasAuthoredChange(changes: []const Change) bool {
    for (changes) |change| if (change.kind != .equal) return true;
    return false;
}

fn finishHunk(
    allocator: std.mem.Allocator,
    hunks: *std.ArrayList(Hunk),
    working: *WorkingHunk,
) !void {
    var old_count: usize = 0;
    var new_count: usize = 0;
    for (working.lines.items) |line| switch (line.kind) {
        .context => {
            old_count += 1;
            new_count += 1;
        },
        .remove => old_count += 1,
        .add => new_count += 1,
    };
    try hunks.append(allocator, .{
        .old_start = working.old_start,
        .old_lines = old_count,
        .new_start = working.new_start,
        .new_lines = new_count,
        .lines = try working.lines.toOwnedSlice(allocator),
    });
}

fn hunkFits(source_lines: []const []const u8, hunk: Hunk, placement: usize) bool {
    var source_index = placement;
    for (hunk.lines) |line| switch (line.kind) {
        .add => {},
        .context, .remove => {
            if (source_index >= source_lines.len or !std.mem.eql(u8, source_lines[source_index], line.text)) return false;
            source_index += 1;
        },
    };
    return true;
}

fn findExactPlacement(
    source_lines: []const []const u8,
    hunk: Hunk,
    expected: isize,
    minimum: usize,
    maximum: usize,
) ?usize {
    const minimum_signed: isize = @intCast(minimum);
    const maximum_signed: isize = @intCast(maximum);
    const lower_distance: usize = @intCast(if (expected >= minimum_signed) expected - minimum_signed else minimum_signed - expected);
    const upper_distance: usize = @intCast(if (expected >= maximum_signed) expected - maximum_signed else maximum_signed - expected);
    const furthest = @max(lower_distance, upper_distance);
    var distance: usize = 0;
    while (distance <= furthest) : (distance += 1) {
        const signed_distance: isize = @intCast(distance);
        const forward = expected + signed_distance;
        if (forward >= minimum_signed and forward <= maximum_signed and
            hunkFits(source_lines, hunk, @intCast(forward))) return @intCast(forward);
        if (distance == 0) continue;
        const backward = expected - signed_distance;
        if (backward >= minimum_signed and backward <= maximum_signed and
            hunkFits(source_lines, hunk, @intCast(backward))) return @intCast(backward);
    }
    return null;
}

fn joinTokens(allocator: std.mem.Allocator, tokens: []const []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    for (tokens) |token| try output.appendSlice(allocator, token);
    return output.toOwnedSlice(allocator);
}

test "hashline diff: Myers keeps jsdiff removal-before-addition tie behavior" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const changes = try diffArrays(arena.allocator(), &.{"A"}, &.{"B"});
    try std.testing.expectEqual(@as(usize, 2), changes.len);
    try std.testing.expectEqual(ChangeKind.remove, changes[0].kind);
    try std.testing.expectEqualStrings("A", changes[0].lines[0]);
    try std.testing.expectEqual(ChangeKind.add, changes[1].kind);
    try std.testing.expectEqualStrings("B", changes[1].lines[0]);
}

test "hashline diff: Myers duplicate tie keeps the earliest shared row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const changes = try diffArrays(arena.allocator(), &.{ "a", "a" }, &.{"a"});
    try std.testing.expectEqual(@as(usize, 2), changes.len);
    try std.testing.expectEqual(ChangeKind.equal, changes[0].kind);
    try std.testing.expectEqual(ChangeKind.remove, changes[1].kind);
}

test "hashline diff: Myers line map preserves duplicate-line alignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const map = try buildLineMap(
        arena.allocator(),
        "alpha\nDUP\nbeta\nDUP\nomega\n",
        "alpha\nINSERTED\nDUP\nbeta\nDUP\nomega\n",
    );
    try std.testing.expectEqual(@as(?usize, 1), map.get(1));
    try std.testing.expectEqual(@as(?usize, 3), map.get(2));
    try std.testing.expectEqual(@as(?usize, 5), map.get(4));
    try std.testing.expectEqual(@as(?usize, 6), map.get(5));
}

test "hashline diff: fuzz-zero patch searches + before - at equal distance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const patch = try createStructuredPatch(arena.allocator(), "a\nx\nz", "a\nX\nz", 0);
    const merged = (try applyStructuredPatch(arena.allocator(), "x\na\nx\nz", patch)).?;
    try std.testing.expectEqualStrings("x\na\nX\nz", merged);
}

test "hashline diff: context-three fuzz-zero patch refuses changed context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const patch = try createStructuredPatch(
        arena.allocator(),
        "a\nb\nc\nd\ne\nf\ng\nh\n",
        "a\nb\nc\nd\nE\nf\ng\nh\n",
        3,
    );
    try std.testing.expect((try applyStructuredPatch(
        arena.allocator(),
        "a\nb\nc\nCHANGED\ne\nf\ng\nh\n",
        patch,
    )) == null);
}

test "hashline diff: structured patch preserves EOF newline changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const add_newline = try createStructuredPatch(arena.allocator(), "a", "a\n", 3);
    try std.testing.expectEqualStrings("a\n", (try applyStructuredPatch(arena.allocator(), "a", add_newline)).?);
    const remove_newline = try createStructuredPatch(arena.allocator(), "a\n", "a", 3);
    try std.testing.expectEqualStrings("a", (try applyStructuredPatch(arena.allocator(), "a\n", remove_newline)).?);
}

test "hashline diff: numbered rows expose old context and new additions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try buildNumberedDiff(arena.allocator(), "alpha\nbeta\ngamma\n", "alpha\nDELTA\nEPSILON\ngamma\n", 2);
    try std.testing.expectEqual(@as(?usize, 2), result.first_changed_line);
    try std.testing.expectEqualStrings(
        " 1|alpha\n-2|beta\n+2|DELTA\n+3|EPSILON\n 3|gamma",
        result.diff,
    );
}

test "hashline diff: numbered rows expose an EOF-newline-only change" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try buildNumberedDiff(arena.allocator(), "a", "a\n", 2);
    try std.testing.expectEqual(@as(?usize, 1), result.first_changed_line);
    try std.testing.expectEqualStrings("-1|a\n+1|a", result.diff);
}

test "hashline diff: numbered rows add an off-window matching bracket with a gap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const old =
        \\fn oldName() {
        \\    const first = 1;
        \\    const second = 2;
        \\    const third = 3;
        \\    const fourth = 4;
        \\    return first + second + third + fourth;
        \\}
    ;
    const new =
        \\fn newName() {
        \\    const first = 1;
        \\    const second = 2;
        \\    const third = 3;
        \\    const fourth = 4;
        \\    return first + second + third + fourth;
        \\}
    ;
    const result = try buildNumberedDiff(arena.allocator(), old, new, 2);
    try std.testing.expectEqualStrings(
        "-1|fn oldName() {\n+1|fn newName() {\n 2|    const first = 1;\n 3|    const second = 2;\n\n 7|}",
        result.diff,
    );
}

test "hashline diff: lexical bracket context ignores string and comment closers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const old =
        \\fn oldName() {
        \\    const first = 1;
        \\    const quoted = "}";
        \\    // }
        \\    /* } */
        \\    return first;
        \\}
    ;
    const new =
        \\fn newName() {
        \\    const first = 1;
        \\    const quoted = "}";
        \\    // }
        \\    /* } */
        \\    return first;
        \\}
    ;
    const result = try buildNumberedDiff(arena.allocator(), old, new, 1);
    try std.testing.expectEqualStrings(
        "-1|fn oldName() {\n+1|fn newName() {\n 2|    const first = 1;\n\n 7|}",
        result.diff,
    );
}
