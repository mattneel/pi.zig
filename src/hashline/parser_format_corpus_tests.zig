const std = @import("std");
const apply = @import("apply.zig");
const format = @import("format.zig");
const fs_mod = @import("fs.zig");
const input = @import("input.zig");
const normalize = @import("normalize.zig");
const parser = @import("parser.zig");
const patcher_mod = @import("patcher.zig");
const recovery_mod = @import("recovery.zig");
const snapshots = @import("snapshots.zig");
const types = @import("types.zig");

fn expectParse(outcome: types.Outcome(parser.ParseResult)) !parser.ParseResult {
    return switch (outcome) {
        .success => |result| result,
        .failure => |failure| {
            std.debug.print("unexpected parse failure: {s}\n", .{failure.message});
            return error.TestUnexpectedResult;
        },
    };
}

fn expectParseFailure(outcome: types.Outcome(parser.ParseResult)) !types.Failure {
    return switch (outcome) {
        .failure => |failure| failure,
        .success => error.TestUnexpectedResult,
    };
}

fn expectPatch(outcome: types.Outcome(input.Patch)) !input.Patch {
    return switch (outcome) {
        .success => |patch| patch,
        .failure => |failure| {
            std.debug.print("unexpected patch failure: {s}\n", .{failure.message});
            return error.TestUnexpectedResult;
        },
    };
}

fn expectPatchFailure(outcome: types.Outcome(input.Patch)) !types.Failure {
    return switch (outcome) {
        .failure => |failure| failure,
        .success => error.TestUnexpectedResult,
    };
}

fn expectSection(outcome: types.Outcome(input.PatchSection)) !input.PatchSection {
    return switch (outcome) {
        .success => |section| section,
        .failure => |failure| {
            std.debug.print("unexpected section failure: {s}\n", .{failure.message});
            return error.TestUnexpectedResult;
        },
    };
}

fn expectSectionFailure(outcome: types.Outcome(input.PatchSection)) !types.Failure {
    return switch (outcome) {
        .failure => |failure| failure,
        .success => error.TestUnexpectedResult,
    };
}

fn expectApplied(outcome: types.Outcome(types.ApplyResult)) !types.ApplyResult {
    return switch (outcome) {
        .success => |result| result,
        .failure => |failure| {
            std.debug.print("unexpected apply failure: {s}\n", .{failure.message});
            return error.TestUnexpectedResult;
        },
    };
}

fn expectApplyFailure(outcome: types.Outcome(types.ApplyResult)) !types.Failure {
    return switch (outcome) {
        .failure => |failure| failure,
        .success => error.TestUnexpectedResult,
    };
}

fn applyPatch(allocator: std.mem.Allocator, text: []const u8, diff: []const u8) ![]const u8 {
    const parsed = try expectParse(try parser.parsePatch(allocator, diff));
    return (try expectApplied(try apply.applyEdits(allocator, text, parsed.edits))).text;
}

fn failureContains(failure: types.Failure, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, failure.message, needle) != null);
}

fn warningsContain(warnings: []const []const u8, needle: []const u8) bool {
    for (warnings) |warning| if (std.mem.indexOf(u8, warning, needle) != null) return true;
    return false;
}

const BlockingFs = struct {
    inner: *fs_mod.InMemoryFs,
    blocked_path: []const u8,

    fn fs(self: *BlockingFs) fs_mod.Fs {
        return .{ .context = self, .vtable = &vtable };
    }

    fn selfFrom(context: *anyopaque) *BlockingFs {
        return @ptrCast(@alignCast(context));
    }

    fn read(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return selfFrom(context).inner.fs().read(allocator, path);
    }

    fn write(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8, content: []const u8) ![]u8 {
        return selfFrom(context).inner.fs().write(allocator, path, content);
    }

    fn exists(context: *anyopaque, path: []const u8) !bool {
        return selfFrom(context).inner.fs().exists(path);
    }

    fn rename(context: *anyopaque, from: []const u8, to: []const u8, content: ?[]const u8) !void {
        return selfFrom(context).inner.fs().rename(from, to, content);
    }

    fn delete(context: *anyopaque, path: []const u8) !void {
        return selfFrom(context).inner.fs().delete(path);
    }

    fn canonicalPath(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return selfFrom(context).inner.fs().canonicalPath(allocator, path);
    }

    fn preflightWrite(context: *anyopaque, path: []const u8, _: ?types.FileOp) !void {
        const self = selfFrom(context);
        if (std.mem.eql(u8, path, self.blocked_path)) return error.@"blocked write: b.ts";
    }

    const vtable: fs_mod.Fs.VTable = .{
        .read = read,
        .write = write,
        .exists = exists,
        .rename = rename,
        .delete = delete,
        .canonical_path = canonicalPath,
        .preflight_write = preflightWrite,
    };
};

// core-contracts.test.ts (20 declarations)

test "hashline core-contracts: preserves the first newline style when restoring mixed-ending files" {
    try std.testing.expectEqual(normalize.LineEnding.crlf, normalize.detectLineEnding("a\r\nb\nc"));
    try std.testing.expectEqual(normalize.LineEnding.lf, normalize.detectLineEnding("a\nb\r\nc"));
}

test "hashline core-contracts: keeps parsed sections reusable across target snapshots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const section = try expectSection(try input.Patch.parseSingle(arena.allocator(), "[a.ts]\nINS.POST 2:\n+tail", .{}));
    const first = try expectApplied(try section.applyTo(arena.allocator(), "aaa\nbbb", null));
    const second = try expectApplied(try section.applyTo(arena.allocator(), "aaa\nbbb\nccc", null));
    try std.testing.expectEqualStrings("aaa\nbbb\ntail", first.text);
    try std.testing.expectEqualStrings("aaa\nbbb\ntail\nccc", second.text);
}

test "hashline core-contracts: applies replace/delete/insert operations against concrete anchors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = "aaa\nbbb\nccc";
    try std.testing.expectEqualStrings(
        "top\naaa\nbefore b\nbbb\nafter b\nccc\ntail",
        try applyPatch(arena.allocator(), text, "INS.PRE 2:\n+before b\nINS.POST 2:\n+after b\nINS.HEAD:\n+top\nINS.TAIL:\n+tail"),
    );
    try std.testing.expectEqualStrings("aaa\nccc", try applyPatch(arena.allocator(), text, "DEL 2"));
    try std.testing.expectEqualStrings("aaa", try applyPatch(arena.allocator(), text, "DEL 2..3"));
    try std.testing.expectEqualStrings("aaa\nBBB\nccc", try applyPatch(arena.allocator(), text, "SWAP 2..2:\n+BBB"));
}

test "hashline core-contracts: inserts after the final line without falling off the file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "aaa\nbbb\nccc\ntail",
        try applyPatch(arena.allocator(), "aaa\nbbb\nccc", "INS.POST 3:\n+tail"),
    );
}

test "hashline core-contracts: preserves whitespace-bearing and sigil-leading payload exactly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const payload = "\tconst streamKeepaliveMs = opts.streamKeepaliveMs;";
    try std.testing.expectEqualStrings(
        "aaa\nbbb\n\tconst streamKeepaliveMs = opts.streamKeepaliveMs;\nccc",
        try applyPatch(arena.allocator(), "aaa\nbbb\nccc", "INS.POST 2:\n+\tconst streamKeepaliveMs = opts.streamKeepaliveMs;"),
    );
    _ = payload;
    try std.testing.expectEqualStrings(
        "aaa\n|literal\n^literal\n↓literal\nccc",
        try applyPatch(arena.allocator(), "aaa\nbbb\nccc", "SWAP 2..2:\n+|literal\n+^literal\n+↓literal"),
    );
}

test "hashline core-contracts: strips copied read-output prefixes only inside pasted bare body rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try expectParse(try parser.parsePatch(arena.allocator(), "SWAP 2..4:\n+line one\n3:line two"));
    const result = try expectApplied(try apply.applyEdits(arena.allocator(), "aaa\nbbb\nccc\nddd\neee", parsed.edits));
    try std.testing.expectEqualStrings("aaa\nline one\nline two\neee", result.text);
    try std.testing.expect(warningsContain(parsed.warnings, "Auto-prefixed bare body row"));
}

test "hashline core-contracts: rejects overlapping replacement ranges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const failure = try expectParseFailure(try parser.parsePatch(
        arena.allocator(),
        "SWAP 2..4:\n+NEW1\nSWAP 3..5:\n+NEW2",
    ));
    try failureContains(failure, "anchor line 3 is already targeted by another hunk on line 1");
}

test "hashline core-contracts: rejects obsolete line-hash anchors and applies line-number anchors without per-anchor hashes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const failure = try expectParseFailure(try parser.parsePatch(arena.allocator(), "2ab:\n+BBB"));
    try failureContains(failure, "payload line has no preceding");
    try std.testing.expectEqualStrings(
        "aaa\nBBB\nccc",
        try applyPatch(arena.allocator(), "aaa\nbbb\nccc", "SWAP 2..2:\n+BBB"),
    );
}

test "hashline core-contracts: extracts path, snapshot tag, and diff body from bracket headers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const section = try expectSection(try input.Patch.parseSingle(
        arena.allocator(),
        "[src/foo.ts#1A2B]\nSWAP 2..2:\n+BBB",
        .{},
    ));
    try std.testing.expectEqualStrings("src/foo.ts", section.path);
    try std.testing.expectEqualStrings("1A2B", &section.file_hash.?);
    try std.testing.expectEqualStrings("SWAP 2..2:\n+BBB", section.diff);
}

test "hashline core-contracts: normalizes leading blanks, cwd-relative paths, and explicit fallback paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const leading = try expectSection(try input.Patch.parseSingle(arena.allocator(), "\n[foo.ts]\nINS.HEAD:\n+x", .{}));
    try std.testing.expectEqualStrings("foo.ts", leading.path);
    try std.testing.expectEqualStrings("INS.HEAD:\n+x", leading.diff);
    const relative = try expectSection(try input.Patch.parseSingle(
        arena.allocator(),
        "[/tmp/hashline-root/src/foo.ts]\nINS.HEAD:\n+x",
        .{ .cwd = "/tmp/hashline-root" },
    ));
    try std.testing.expectEqualStrings("src/foo.ts", relative.path);
    const fallback = try expectSection(try input.Patch.parseSingle(
        arena.allocator(),
        "INS.HEAD:\n+x",
        .{ .path = "a.ts" },
    ));
    try std.testing.expectEqualStrings("a.ts", fallback.path);
    try std.testing.expectEqualStrings("INS.HEAD:\n+x", fallback.diff);
    const failure = try expectSectionFailure(try input.Patch.parseSingle(arena.allocator(), "plain text", .{ .path = "a.ts" }));
    try failureContains(failure, "must begin with");
}

test "hashline core-contracts: splits multiple sections and drops a trailing header without operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const patch = try expectPatch(try input.Patch.parse(
        arena.allocator(),
        "[a.ts]\nINS.HEAD:\n+a\n[b.ts]\nINS.TAIL:\n+b",
        .{},
    ));
    try std.testing.expectEqual(@as(usize, 2), patch.sections.len);
    try std.testing.expectEqualStrings("a.ts", patch.sections[0].path);
    try std.testing.expectEqualStrings("INS.HEAD:\n+a", patch.sections[0].diff);
    try std.testing.expectEqualStrings("b.ts", patch.sections[1].path);
    try std.testing.expectEqualStrings("INS.TAIL:\n+b", patch.sections[1].diff);
    const trailing = try expectPatch(try input.Patch.parse(
        arena.allocator(),
        "[a.ts]\nINS.HEAD:\n+a\n[b.ts]",
        .{},
    ));
    try std.testing.expectEqual(@as(usize, 1), trailing.sections.len);
}

test "hashline core-contracts: rejects unified-diff hunk headers on the first line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const failure = try expectPatchFailure(try input.Patch.parse(
        arena.allocator(),
        "@@ -1,3 +1,3 @@\nINS.HEAD:\n+x",
        .{},
    ));
    try failureContains(failure, "unified-diff hunk header");
}

test "hashline core-contracts: preflights write policy for every section before committing a batch" {
    var memory = fs_mod.InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    try memory.put("a.ts", "aaa\n");
    try memory.put("b.ts", "bbb\n");
    var blocking = BlockingFs{ .inner = &memory, .blocked_path = "b.ts" };
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const a_tag = try store.record("a.ts", "aaa\n", null);
    const b_tag = try store.record("b.ts", "bbb\n", null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const patch_text = try std.fmt.allocPrint(
        arena.allocator(),
        "[a.ts#{s}]\nSWAP 1..1:\n+AAA\n[b.ts#{s}]\nSWAP 1..1:\n+BBB",
        .{ &a_tag, &b_tag },
    );
    const patch = try expectPatch(try input.Patch.parse(arena.allocator(), patch_text, .{}));
    var patcher = patcher_mod.Patcher.init(.{ .fs = blocking.fs(), .snapshot_store = &store });
    const outcome = try patcher.apply(arena.allocator(), patch);
    const failure = switch (outcome) {
        .failure => |value| value,
        .success => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("blocked write: b.ts", failure.message);
    try std.testing.expectEqualStrings("aaa\n", memory.get("a.ts").?);
    try std.testing.expectEqualStrings("bbb\n", memory.get("b.ts").?);
}

test "hashline core-contracts: returns null when neither patch recovery nor replay can land" {
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const path = "/tmp/__hashline-recovery-applypatch__.ts";
    const snapshot_text = "alpha\nbeta\ngamma\ndelta\nepsilon";
    const tag = try store.record(path, snapshot_text, null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try expectParse(try parser.parsePatch(arena.allocator(), "SWAP 2..2:\n+BETA-MODEL"));
    var recovery = recovery_mod.Recovery.init(&store);
    const recovered = try recovery.tryRecover(arena.allocator(), .{
        .path = path,
        .current_text = "totally\nunrelated\ncontent\nhere\nnow\n",
        .file_hash = &tag,
        .edits = parsed.edits,
    });
    try std.testing.expect(recovered == null);
}

test "hashline core-contracts: recovers from an older in-session snapshot after the current file advanced" {
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const path = "/tmp/__hashline-cache-ring-recovery__.ts";
    const v0 = "L1\nL2\nL3\nL4\nL5\nL6\nL7\nL8\nL9\nL10\n";
    const v1 = "L1\nL2-EDITED\nL3\nL4\nL5\nL6\nL7\nL8\nL9\nL10\n";
    const current = "L1\nL2-EDITED\nL3\nL4\nL5\nL6\nL7\nL8\nL9\nL10\nTRAILER\n";
    const v0_tag = try store.record(path, v0, null);
    _ = try store.record(path, v1, null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try expectParse(try parser.parsePatch(arena.allocator(), "SWAP 10.=10:\n+L10-EDITED"));
    var recovery = recovery_mod.Recovery.init(&store);
    const recovered = try recovery.tryRecover(arena.allocator(), .{
        .path = path,
        .current_text = current,
        .file_hash = &v0_tag,
        .edits = parsed.edits,
    });
    try std.testing.expect(recovered != null);
    try std.testing.expect(std.mem.indexOf(u8, recovered.?.text, "L10-EDITED") != null);
}

test "hashline core-contracts: terminates parsing without surfacing a warning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try expectParse(try parser.parsePatch(
        arena.allocator(),
        "INS.POST 1:\n+HELLO\n*** Abort\nINS.POST 99:\n+never",
    ));
    try std.testing.expectEqual(@as(usize, 1), parsed.edits.len);
    try std.testing.expectEqualStrings("HELLO", parsed.edits[0].insert.text);
    try std.testing.expectEqual(@as(usize, 0), parsed.warnings.len);
}

test "hashline core-contracts: stops the input splitter before later sections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const patch = try expectPatch(try input.Patch.parse(
        arena.allocator(),
        "[a.ts]\nINS.POST 1:\n+a-payload\n*** Abort\n[b.ts]\nINS.POST 1:\n+never",
        .{},
    ));
    try std.testing.expectEqual(@as(usize, 1), patch.sections.len);
    try std.testing.expectEqualStrings("a.ts", patch.sections[0].path);
    try std.testing.expect(std.mem.indexOf(u8, patch.sections[0].diff, "never") == null);
}

test "hashline core-contracts: applies inline delete and empty replace operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const single = try expectSection(try input.Patch.parseSingle(arena.allocator(), "[a.ts]\nDEL 2\n", .{}));
    try std.testing.expectEqualStrings("line1\nline3\n", try applyPatch(arena.allocator(), "line1\nline2\nline3\n", single.diff));
    const range = try expectSection(try input.Patch.parseSingle(arena.allocator(), "[a.ts]\nDEL 2.=3\n", .{}));
    try std.testing.expectEqualStrings(
        "line1\nline4\n",
        try applyPatch(arena.allocator(), "line1\nline2\nline3\nline4\n", range.diff),
    );
    const replacement = try expectSection(try input.Patch.parseSingle(arena.allocator(), "[a.ts]\nSWAP 2.=2:\n", .{}));
    try std.testing.expectEqualStrings(
        "line1\nline3\n",
        try applyPatch(arena.allocator(), "line1\nline2\nline3\n", replacement.diff),
    );
}

test "hashline core-contracts: treats old inline replacement syntax as orphan body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Upstream exposes this from the section's lazy `parsePatch` call. Zig's
    // owned PatchSection eagerly validates the body, so the same diagnostic is
    // returned by parseSingle.
    const failure = try expectSectionFailure(try input.Patch.parseSingle(
        arena.allocator(),
        "[a.ts]\n2.=2=replacement\n",
        .{},
    ));
    try failureContains(failure, "payload line has no preceding hunk header");
}

test "hashline core-contracts: preserves explicit blank replacement rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const first = try expectSection(try input.Patch.parseSingle(
        arena.allocator(),
        "[a.ts]\nSWAP 2.=2:\n+\n+\nSWAP 4.=4:\n+D\n",
        .{},
    ));
    try std.testing.expectEqualStrings("a\n\n\nc\nD\ne\n", try applyPatch(arena.allocator(), "a\nb\nc\nd\ne\n", first.diff));
    const embedded = try expectSection(try input.Patch.parseSingle(
        arena.allocator(),
        "[a.ts]\nSWAP 2.=2:\n+first\n+\n+second\n",
        .{},
    ));
    try std.testing.expectEqualStrings(
        "a\nfirst\n\nsecond\nc\n",
        try applyPatch(arena.allocator(), "a\nb\nc\n", embedded.diff),
    );
}

// format-v2.test.ts (17 declarations)

test "hashline format-v2: replaces a concrete range with literal body rows in textual order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a\nbefore\nafter\nc", try applyPatch(arena.allocator(), "a\nb\nc", "SWAP 2.=2:\n+before\n+after"));
}

test "hashline format-v2: deletes a single source line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a\nc", try applyPatch(arena.allocator(), "a\nb\nc", "DEL 2"));
}

test "hashline format-v2: deletes a concrete range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a\nd", try applyPatch(arena.allocator(), "a\nb\nc\nd", "DEL 2.=3"));
}

test "hashline format-v2: inserts before and after concrete anchors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "a\nbefore\nb\nafter\nc",
        try applyPatch(arena.allocator(), "a\nb\nc", "INS.PRE 2:\n+before\nINS.POST 2:\n+after"),
    );
}

test "hashline format-v2: inserts at head and tail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("HEAD\na\nb", try applyPatch(arena.allocator(), "a\nb", "INS.HEAD:\n+HEAD"));
    try std.testing.expectEqualStrings("a\nb\nTAIL", try applyPatch(arena.allocator(), "a\nb", "INS.TAIL:\n+TAIL"));
}

test "hashline format-v2: treats an empty replace hunk as a delete and still rejects empty inserts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a\nc", try applyPatch(arena.allocator(), "a\nb\nc", "SWAP 2.=2:"));
    const failure = try expectParseFailure(try parser.parsePatch(arena.allocator(), "INS.HEAD:"));
    try failureContains(failure, "needs at least one");
}

test "hashline format-v2: rejects body rows under delete" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const failure = try expectParseFailure(try parser.parsePatch(arena.allocator(), "DEL 2\n+replacement"));
    try failureContains(failure, "does not take body rows");
}

test "hashline format-v2: auto-pipes bare body rows as literal text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a\nraw\nc", try applyPatch(arena.allocator(), "a\nb\nc", "SWAP 2.=2:\nraw"));
    const parsed = try expectParse(try parser.parsePatch(arena.allocator(), "SWAP 2.=2:\nraw"));
    try std.testing.expect(warningsContain(parsed.warnings, "Auto-prefixed bare body row"));
}

test "hashline format-v2: strips read-output line number prefix from auto-piped bare body rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try expectParse(try parser.parsePatch(arena.allocator(), "SWAP 2.=2:\n3:replaced"));
    try std.testing.expectEqualStrings("a\nreplaced\nc", (try expectApplied(try apply.applyEdits(arena.allocator(), "a\nb\nc", parsed.edits))).text);
    try std.testing.expect(warningsContain(parsed.warnings, "Auto-prefixed bare body row"));
}

test "hashline format-v2: validates insert anchors against file bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try expectParse(try parser.parsePatch(arena.allocator(), "INS.PRE 4:\n+x"));
    const failure = try expectApplyFailure(try apply.applyEdits(arena.allocator(), "a\nb", parsed.edits));
    try failureContains(failure, "Line 4 does not exist");
}

test "hashline format-v2: ignores deleting the trailing blank sentinel of a newline-terminated file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a\nb\n", try applyPatch(arena.allocator(), "a\nb\n", "DEL 3"));
}

test "hashline format-v2: treats a delete range ending at the trailing sentinel as ending at the last real line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a\n", try applyPatch(arena.allocator(), "a\nb\n", "DEL 2.=3"));
}

test "hashline format-v2: treats a replace range ending at the trailing sentinel as ending at the last real line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a\nB\n", try applyPatch(arena.allocator(), "a\nb\n", "SWAP 2.=3:\n+B"));
}

test "hashline format-v2: still allows inserts anchored on the trailing blank sentinel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a\nb\n\ntail", try applyPatch(arena.allocator(), "a\nb\n", "INS.POST 3:\n+tail"));
}

test "hashline format-v2: still deletes a genuine empty last line of a non-newline-terminated file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a", try applyPatch(arena.allocator(), "a\nb", "DEL 2"));
}

test "hashline format-v2: does not flush a trailing streaming pending empty replace hunk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try expectParse(try parser.parsePatchStreaming(arena.allocator(), "SWAP 5.=5:\n"));
    try std.testing.expectEqual(@as(usize, 0), parsed.edits.len);
}

test "hashline format-v2: flushes a streaming empty replace hunk when another hunk starts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try expectParse(try parser.parsePatchStreaming(arena.allocator(), "SWAP 2.=2:\nINS.TAIL:\n"));
    try std.testing.expectEqual(@as(usize, 1), parsed.edits.len);
    try std.testing.expect(parsed.edits[0] == .delete);
    try std.testing.expectEqual(@as(usize, 2), parsed.edits[0].delete.anchor.line);
    try std.testing.expectEqual(@as(usize, 1), parsed.edits[0].delete.source_line);
    try std.testing.expectEqual(@as(usize, 0), parsed.edits[0].delete.index);
}

// leniency.test.ts (34 declarations)

const leniency_file = "a\nb\nc\nd\ne";

test "hashline leniency: accepts paths with spaces in anchored section headers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const section = try expectSection(try input.Patch.parseSingle(
        arena.allocator(),
        "[dir with spaces/file.ts#1a2b]\nSWAP 1.=1:\n+after",
        .{},
    ));
    try std.testing.expectEqualStrings("dir with spaces/file.ts", section.path);
    try std.testing.expectEqualStrings("1A2B", &section.file_hash.?);
    try std.testing.expectEqualStrings("after", (try expectApplied(try section.applyTo(arena.allocator(), "before", null))).text);
}

test "hashline leniency: recovers apply_patch-contaminated headers whose paths contain spaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const section = try expectSection(try input.Patch.parseSingle(
        arena.allocator(),
        "[*** Update File: dir with spaces/file.ts#1A2B]\nSWAP 1.=1:\n+after",
        .{},
    ));
    try std.testing.expectEqualStrings("dir with spaces/file.ts", section.path);
    try std.testing.expectEqualStrings("1A2B", &section.file_hash.?);
    try std.testing.expectEqualStrings("after", (try expectApplied(try section.applyTo(arena.allocator(), "before", null))).text);
}

test "hashline leniency: rejects trailing junk after a snapshot tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_][]const u8{
        "[src/a.ts#1A2B copied from read]\nSWAP 1.=1:\n+after",
        "[src/a.ts#1A2B:812]\nSWAP 1.=1:\n+after",
    };
    for (cases) |case| try failureContains(try expectPatchFailure(try input.Patch.parse(arena.allocator(), case, .{})), "Input header must be");
}

test "hashline leniency: rejects trailing junk after a snapshot tag even with apply_patch noise" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_][]const u8{
        "[Update File: src/a.ts#1A2B copied from read]\nSWAP 1.=1:\n+after",
        "[Update File: src/a.ts#1A2B:812]\nSWAP 1.=1:\n+after",
    };
    for (cases) |case| try failureContains(try expectPatchFailure(try input.Patch.parse(arena.allocator(), case, .{})), "Input header must be");
}

test "hashline leniency: rejects malformed snapshot tags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_][]const u8{
        "[src/a.ts#1A2]\nSWAP 1.=1:\n+after",
        "[src/a.ts#1A2G]\nSWAP 1.=1:\n+after",
        "[src/a.ts#1A2B5]\nSWAP 1.=1:\n+after",
    };
    for (cases) |case| try failureContains(try expectPatchFailure(try input.Patch.parse(arena.allocator(), case, .{})), "Input header must be");
}

test "hashline leniency: rejects malformed snapshot tags even with apply_patch noise" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const failure = try expectPatchFailure(try input.Patch.parse(
        arena.allocator(),
        "[Update File: src/a.ts#1A2G]\nSWAP 1.=1:\n+after",
        .{},
    ));
    try failureContains(failure, "Input header must be");
}

test "hashline leniency: reports bracket syntax with a 4-hex example when the header is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const failure = try expectPatchFailure(try input.Patch.parse(arena.allocator(), "DEL 38.=40", .{}));
    try failureContains(failure, "input must begin with \"[PATH#HASH]\"");
    try failureContains(failure, "Example: \"[src/foo.ts#1A2B]\"");
    try std.testing.expect(std.mem.indexOf(u8, failure.message, "#0A3") == null);
}

test "hashline leniency: rejects a bare single-number hunk header with verb guidance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try failureContains(try expectParseFailure(try parser.parsePatch(arena.allocator(), "2\n+B")), "hunk headers need a verb");
}

test "hashline leniency: rejects a bare numeric range with verb guidance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try failureContains(try expectParseFailure(try parser.parsePatch(arena.allocator(), "2 3\n+X")), "Hunk headers need a verb");
}

test "hashline leniency: accepts canonical replace/delete/insert forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a\nX\nd\ne", try applyPatch(arena.allocator(), leniency_file, "SWAP 2.=3:\n+X"));
    try std.testing.expectEqualStrings("a\nd\ne", try applyPatch(arena.allocator(), leniency_file, "DEL 2.=3"));
    try std.testing.expectEqualStrings("a\nX\nb\nc\nd\ne", try applyPatch(arena.allocator(), leniency_file, "INS.PRE 2:\n+X"));
    try std.testing.expectEqualStrings("a\nb\nX\nc\nd\ne", try applyPatch(arena.allocator(), leniency_file, "INS.POST 2:\n+X"));
    try std.testing.expectEqualStrings("X\na\nb\nc\nd\ne", try applyPatch(arena.allocator(), leniency_file, "INS.HEAD:\n+X"));
    try std.testing.expectEqualStrings("a\nb\nc\nd\ne\nX", try applyPatch(arena.allocator(), leniency_file, "INS.TAIL:\n+X"));
}

test "hashline leniency: accepts single-number replace and delete shorthand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a\nX\nc\nd\ne", try applyPatch(arena.allocator(), leniency_file, "SWAP 2:\n+X"));
    try std.testing.expectEqualStrings("a\nc\nd\ne", try applyPatch(arena.allocator(), leniency_file, "DEL 2"));
}

test "hashline leniency: accepts alternate replace range separators and missing colon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_][]const u8{
        "SWAP 2-3:\n+X",
        "SWAP 2…3:\n+X",
        "SWAP 2 3:\n+X",
        "SWAP 2..3:\n+X",
        "SWAP 2.=3\n+X",
    };
    for (cases) |case| try std.testing.expectEqualStrings("a\nX\nd\ne", try applyPatch(arena.allocator(), leniency_file, case));
}

test "hashline leniency: accepts missing colon on insert headers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a\nX\nb\nc\nd\ne", try applyPatch(arena.allocator(), leniency_file, "INS.PRE 2\n+X"));
    try std.testing.expectEqualStrings("X\na\nb\nc\nd\ne", try applyPatch(arena.allocator(), leniency_file, "INS.HEAD\n+X"));
}

test "hashline leniency: tolerates GLM 5.2 stray dot before the trailing colon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a\nX\nd\ne", try applyPatch(arena.allocator(), leniency_file, "SWAP 2.=3.:\n+X"));
    try std.testing.expectEqualStrings("a\nX\nc\nd\ne", try applyPatch(arena.allocator(), leniency_file, "SWAP 2.=2.:\n+X"));
    try std.testing.expectEqualStrings("a\nb\nX\nc\nd\ne", try applyPatch(arena.allocator(), leniency_file, "INS.POST 2.:\n+X"));
    try std.testing.expectEqualStrings("a\nX\nb\nc\nd\ne", try applyPatch(arena.allocator(), leniency_file, "INS.PRE 2.:\n+X"));
    try std.testing.expectEqualStrings("a\nd\ne", try applyPatch(arena.allocator(), leniency_file, "DEL 2.=3."));
    try std.testing.expectEqualStrings("X\na\nb\nc\nd\ne", try applyPatch(arena.allocator(), leniency_file, "INS.HEAD.:\n+X"));
    try std.testing.expectEqualStrings("a\nb\nc\nd\ne\nX", try applyPatch(arena.allocator(), leniency_file, "INS.TAIL.:\n+X"));
}

test "hashline leniency: auto-pipes a bare body row while warning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try expectParse(try parser.parsePatch(arena.allocator(), "SWAP 2.=2:\n  hello"));
    try std.testing.expectEqualStrings("a\n  hello\nc\nd\ne", (try expectApplied(try apply.applyEdits(arena.allocator(), leniency_file, parsed.edits))).text);
    try std.testing.expect(warningsContain(parsed.warnings, "Auto-prefixed bare body row"));
}

test "hashline leniency: strips read-output line number prefix from auto-piped bare body rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try expectParse(try parser.parsePatch(arena.allocator(), "SWAP 2.=2:\n2:hello"));
    try std.testing.expectEqualStrings("a\nhello\nc\nd\ne", (try expectApplied(try apply.applyEdits(arena.allocator(), leniency_file, parsed.edits))).text);
    try std.testing.expect(warningsContain(parsed.warnings, "Auto-prefixed bare body row"));
}

test "hashline leniency: preserves `+N:` literal payloads without stripping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try expectParse(try parser.parsePatch(arena.allocator(), "SWAP 2.=2:\n+3:keep"));
    try std.testing.expectEqualStrings("a\n3:keep\nc\nd\ne", (try expectApplied(try apply.applyEdits(arena.allocator(), leniency_file, parsed.edits))).text);
    try std.testing.expect(!warningsContain(parsed.warnings, "Auto-prefixed"));
}

test "hashline leniency: strips only one N: prefix from bare body rows (preserves nested digits:colon)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "a\n42:hello\nc\nd\ne",
        try applyPatch(arena.allocator(), leniency_file, "SWAP 2.=2:\n2:42:hello"),
    );
}

test "hashline leniency: strips N: prefixes only when every bare body row carries one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "a\nfoo\nbar\nd\ne",
        try applyPatch(arena.allocator(), leniency_file, "SWAP 2.=3:\n2:foo\n3:bar"),
    );
}

test "hashline leniency: leaves bare body rows untouched when only some carry an N: prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "a\n3:keep\nplain\nd\ne",
        try applyPatch(arena.allocator(), leniency_file, "SWAP 2.=3:\n3:keep\nplain"),
    );
}

test "hashline leniency: keeps interior blank rows in a bare replace body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "a\nfoo\n\nbar\nd\ne",
        try applyPatch(arena.allocator(), leniency_file, "SWAP 2.=3:\nfoo\n\nbar"),
    );
}

test "hashline leniency: drops trailing blank rows between a bare body and the next hunk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "a\nfoo\nc\nbaz\ne",
        try applyPatch(arena.allocator(), leniency_file, "SWAP 2.=2:\nfoo\n\nSWAP 4.=4:\n+baz"),
    );
}

test "hashline leniency: skips blank rows when checking N: prefix uniformity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "a\nfoo\n\nbar\nd\ne",
        try applyPatch(arena.allocator(), leniency_file, "SWAP 2.=3:\n2:foo\n\n3:bar"),
    );
}

test "hashline leniency: leaves numeric-keyed literal bodies untouched (dict/YAML shape)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "a\n1: \"one\",\n2: \"two\",\nd\ne",
        try applyPatch(arena.allocator(), leniency_file, "SWAP 2.=3:\n1: \"one\",\n2: \"two\","),
    );
}

test "hashline leniency: rejects `-` body rows with Markdown bullet escape guidance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const failure = try expectParseFailure(try parser.parsePatch(arena.allocator(), "SWAP 2.=2:\n-old\n+new"));
    try failureContains(failure, "Markdown bullets or other literal `-` lines");
    try failureContains(failure, "`+- item`");
}

test "hashline leniency: allows literal Markdown bullets and plus-prefixed text when prefixed with `+`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "a\n- item\n  - nested\n+plus\nc\nd\ne",
        try applyPatch(arena.allocator(), leniency_file, "SWAP 2.=2:\n+- item\n+  - nested\n++plus"),
    );
}

test "hashline leniency: treats empty replace as delete and still rejects empty insert" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a\nc\nd\ne", try applyPatch(arena.allocator(), leniency_file, "SWAP 2.=2:"));
    try failureContains(try expectParseFailure(try parser.parsePatch(arena.allocator(), "INS.TAIL:")), "`INS` needs");
}

test "hashline leniency: rejects delete with a body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try failureContains(try expectParseFailure(try parser.parsePatch(arena.allocator(), "DEL 2\n+X")), "does not take body rows");
}

test "hashline leniency: rejects delete with a colon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try failureContains(try expectParseFailure(try parser.parsePatch(arena.allocator(), "DEL 2:\n+X")), "has no colon");
}

test "hashline leniency: rejects apply_patch sentinels as contamination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try failureContains(
        try expectParseFailure(try parser.parsePatch(arena.allocator(), "*** Update File: a.ts\nSWAP 2.=2:\n+X")),
        "apply_patch sentinel",
    );
    try failureContains(
        try expectParseFailure(try parser.parsePatch(arena.allocator(), "*** Add File: a.ts\nSWAP 2.=2:\n+X")),
        "apply_patch sentinel",
    );
}

test "hashline leniency: rejects unified-diff hunk headers as contamination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try failureContains(
        try expectParseFailure(try parser.parsePatch(arena.allocator(), "@@ -1,3 +1,3 @@\nSWAP 2.=2:\n+X")),
        "unified-diff hunk header",
    );
}

test "hashline leniency: treats top-level `+TEXT` as an orphan literal payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try failureContains(
        try expectParseFailure(try parser.parsePatch(arena.allocator(), "+const X = 1;\nSWAP 2.=2:")),
        "payload line has no preceding hunk header",
    );
}

test "hashline leniency: keeps replacement boundary echoes literal unless balance repair applies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "// one\n// two\n// one\n// two\nnew();",
        try applyPatch(arena.allocator(), "// one\n// two\nold();", "SWAP 3.=3:\n+// one\n+// two\n+new();"),
    );
}

test "hashline leniency: keeps pure-insert context echoes literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "aaa\nbbb\nccc\nbbb\nccc\nNEW",
        try applyPatch(arena.allocator(), "aaa\nbbb\nccc", "INS.TAIL:\n+bbb\n+ccc\n+NEW"),
    );
}
