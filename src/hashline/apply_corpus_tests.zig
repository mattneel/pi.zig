const std = @import("std");
const apply_mod = @import("apply.zig");
const block = @import("block.zig");
const parser = @import("parser.zig");
const recovery_mod = @import("recovery.zig");
const snapshots = @import("snapshots.zig");
const types = @import("types.zig");

fn parseOrFail(allocator: std.mem.Allocator, diff: []const u8) !parser.ParseResult {
    const outcome = try parser.parsePatch(allocator, diff);
    return switch (outcome) {
        .success => |result| result,
        .failure => |failure| {
            std.debug.print("unexpected parse failure: {s}\n", .{failure.message});
            return error.UnexpectedParseFailure;
        },
    };
}

fn applyOrFail(
    allocator: std.mem.Allocator,
    text: []const u8,
    edits: []const types.Edit,
) !types.ApplyResult {
    const outcome = try apply_mod.applyEdits(allocator, text, edits);
    return switch (outcome) {
        .success => |result| result,
        .failure => |failure| {
            std.debug.print("unexpected apply failure: {s}\n", .{failure.message});
            return error.UnexpectedApplyFailure;
        },
    };
}

fn applyPatch(allocator: std.mem.Allocator, text: []const u8, diff: []const u8) !types.ApplyResult {
    const parsed = try parseOrFail(allocator, diff);
    return applyOrFail(allocator, text, parsed.edits);
}

fn resolveAndApply(
    allocator: std.mem.Allocator,
    text: []const u8,
    diff: []const u8,
    resolver: types.BlockResolver,
) !types.ApplyResult {
    const parsed = try parseOrFail(allocator, diff);
    const resolved_outcome = try block.resolveBlockEdits(
        allocator,
        parsed.edits,
        text,
        "x.ts",
        resolver,
        .{},
    );
    const resolved = switch (resolved_outcome) {
        .success => |result| result,
        .failure => |failure| {
            std.debug.print("unexpected block resolution failure: {s}\n", .{failure.message});
            return error.UnexpectedBlockResolutionFailure;
        },
    };
    return applyOrFail(allocator, text, resolved.edits);
}

fn hasWarning(result: types.ApplyResult, needle: []const u8) bool {
    for (result.warnings) |warning| {
        if (std.mem.indexOf(u8, warning, needle) != null) return true;
    }
    return false;
}

fn warningCount(result: types.ApplyResult, needle: []const u8) usize {
    var count: usize = 0;
    for (result.warnings) |warning| {
        if (std.mem.indexOf(u8, warning, needle) != null) count += 1;
    }
    return count;
}

fn lineCount(text: []const u8, exact_line: []const u8) usize {
    var count: usize = 0;
    var iterator = std.mem.splitScalar(u8, text, '\n');
    while (iterator.next()) |line| {
        if (std.mem.eql(u8, line, exact_line)) count += 1;
    }
    return count;
}

fn lineAt(text: []const u8, index: usize) []const u8 {
    var iterator = std.mem.splitScalar(u8, text, '\n');
    var current: usize = 0;
    while (iterator.next()) |line| : (current += 1) {
        if (current == index) return line;
    }
    return "";
}

fn spanPlusOne(request: types.BlockResolverRequest) ?types.BlockSpan {
    return .{ .start = request.line, .end = request.line + 1 };
}

fn spanPlusTwo(request: types.BlockResolverRequest) ?types.BlockSpan {
    return .{ .start = request.line, .end = request.line + 2 };
}

fn spanOneToFive(_: types.BlockResolverRequest) ?types.BlockSpan {
    return .{ .start = 1, .end = 5 };
}

test "hashline: boundary repair drops a duplicated multi-line closing block (the Root.tsx incident)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const file =
        "import type React from \"react\";\n" ++
        "import { Composition } from \"remotion\";\n" ++
        "import { Sizzle, type SizzleProps } from \"./compositions/Sizzle\";\n" ++
        "import { FPS, totalDurationInFrames } from \"./lib/scenes\";\n\n" ++
        "export const RemotionRoot: React.FC = () => {\n" ++
        "\tconst durationInFrames = totalDurationInFrames();\n" ++
        "\treturn (\n\t\t<>\n\t\t\t<Composition\n" ++
        "\t\t\t\tid=\"Sizzle\"\n\t\t\t\tcomponent={Sizzle}\n" ++
        "\t\t\t\tdurationInFrames={durationInFrames}\n\t\t\t\twidth={1920}\n" ++
        "\t\t\t\tdefaultProps={{ layout: \"landscape\" }}\n" ++
        "\t\t\t/>\n\t\t</>\n\t);\n};";
    const diff =
        "SWAP 7.=16:\n+\treturn (\n+\t\t<>\n+\t\t\t<Composition\n" ++
        "+\t\t\t\tid=\"Sizzle\"\n+\t\t\t\tcomponent={Sizzle}\n" ++
        "+\t\t\t\tdurationInFrames={durationInFrames}\n+\t\t\t\twidth={1920}\n" ++
        "+\t\t\t\tdefaultProps={{ layout: \"landscape\" } satisfies SizzleProps}\n" ++
        "+\t\t\t/>\n+\t\t</>\n+\t);";
    const result = try applyPatch(arena.allocator(), file, diff);
    try std.testing.expectEqual(@as(usize, 1), lineCount(result.text, "\t\t</>"));
    try std.testing.expectEqual(@as(usize, 1), lineCount(result.text, "\t);"));
    try std.testing.expect(std.mem.endsWith(u8, result.text, "\t\t</>\n\t);\n};"));
    try std.testing.expect(hasWarning(result, "delimiter-balance"));
}

test "hashline: boundary repair drops a single duplicated structural closer (`});`)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(
        arena.allocator(),
        "it('a', () => {\n\tsetup();\n\trun();\n});\nafter();",
        "SWAP 2.=3:\n+\tsetup2();\n+\trun2();\n+});",
    );
    try std.testing.expectEqualStrings("it('a', () => {\n\tsetup2();\n\trun2();\n});\nafter();", result.text);
    try std.testing.expect(hasWarning(result, "delimiter-balance"));
}

test "hashline: boundary repair drops a single duplicated structural opener (`planRender(`)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const file =
        "class Foo {\n\t/** doc */\n\tplanRender(\n\t\ta: string[],\n" ++
        "\t\tb: boolean,\n\t): Intent {\n\t\treturn x;\n\t}\n}";
    const diff =
        "SWAP 4.=6:\n+\tplanRender(\n+\t\ta: string[],\n+\t\tb: boolean,\n" ++
        "+\t\tc: number,\n+\t): Intent {";
    const result = try applyPatch(arena.allocator(), file, diff);
    try std.testing.expectEqualStrings(
        "class Foo {\n\t/** doc */\n\tplanRender(\n\t\ta: string[],\n\t\tb: boolean,\n" ++
            "\t\tc: number,\n\t): Intent {\n\t\treturn x;\n\t}\n}",
        result.text,
    );
    try std.testing.expectEqual(@as(usize, 1), lineCount(result.text, "\tplanRender("));
    try std.testing.expect(hasWarning(result, "delimiter-balance"));
}

test "hashline: boundary repair preserves a duplicated opener when it does not account for the imbalance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(
        arena.allocator(),
        "if (a) {\n\tfoo();\n}\nbar();",
        "SWAP 2.=2:\n+if (a) {\n+\tif (b) {\n+\t\tfoo();",
    );
    try std.testing.expectEqualStrings("if (a) {\nif (a) {\n\tif (b) {\n\t\tfoo();\n}\nbar();", result.text);
    try std.testing.expectEqual(@as(usize, 0), result.warnings.len);
}

test "hashline: boundary repair spares the deleted closing line when the payload omits it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(
        arena.allocator(),
        "const handlers = {\n\ta() {\n\t\treturn 1;\n\t},\n};",
        "SWAP 5.=5:\n+\tb() {\n+\t\treturn 2;\n+\t},",
    );
    try std.testing.expectEqualStrings(
        "const handlers = {\n\ta() {\n\t\treturn 1;\n\t},\n\tb() {\n\t\treturn 2;\n\t},\n};",
        result.text,
    );
    try std.testing.expect(hasWarning(result, "delimiter-balance"));
}

test "hashline: boundary repair does not spare a deleted closing line that the payload already restates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(
        arena.allocator(),
        "class Foo {\n\tok();\n\t}\n}",
        "SWAP 1.=4:\n+class Foo {\n+\tok();\n+}",
    );
    try std.testing.expectEqualStrings("class Foo {\n\tok();\n}", result.text);
    try std.testing.expectEqual(@as(usize, 1), lineCount(result.text, "}"));
    try std.testing.expectEqual(@as(usize, 0), result.warnings.len);
}

test "hashline: boundary repair drops duplicated leading and trailing boundary lines around a range replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(
        arena.allocator(),
        "func _cmd_travel_homeworld():\n\tvar destination = get_homeworld()\n\ttravel_to(destination)\n\tprint_status()",
        "SWAP 2.=3:\n+func _cmd_travel_homeworld():\n+\tvar destination = find_homeworld()\n+\ttravel_to(destination)\n+\tprint_status()",
    );
    try std.testing.expectEqualStrings(
        "func _cmd_travel_homeworld():\n\tvar destination = find_homeworld()\n\ttravel_to(destination)\n\tprint_status()",
        result.text,
    );
    try std.testing.expect(hasWarning(result, "boundary echo"));
}

test "hashline: boundary repair preserves payloads where multi-line boundary echoes cover every line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(arena.allocator(), "A\nB\nold\nC\nD", "SWAP 3.=3:\n+A\n+B\n+C\n+D");
    try std.testing.expectEqualStrings("A\nB\nA\nB\nC\nD\nC\nD", result.text);
    try std.testing.expectEqual(@as(usize, 0), result.warnings.len);
}

test "hashline: boundary repair preserves payloads made only of lines matching both replacement neighbors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(arena.allocator(), "a\nold\nc", "SWAP 2.=2:\n+a\n+c");
    try std.testing.expectEqualStrings("a\na\nc\nc", result.text);
    try std.testing.expectEqual(@as(usize, 0), result.warnings.len);
}

test "hashline: boundary repair preserves balance-shifting boundary echoes that do not explain the delta" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(
        arena.allocator(),
        "}\nold();\n}",
        "SWAP 2.=2:\n+}\n+if (a) {\n+if (b) {\n+x();\n+}",
    );
    try std.testing.expectEqualStrings("}\n}\nif (a) {\nif (b) {\nx();\n}\n}", result.text);
    try std.testing.expectEqual(@as(usize, 0), result.warnings.len);
}

test "hashline: boundary repair still drops a balance-neutral wrapper echo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(
        arena.allocator(),
        "function f() {\nold();\n}",
        "SWAP 2.=2:\n+function f() {\n+fresh();\n+}",
    );
    try std.testing.expectEqualStrings("function f() {\nfresh();\n}", result.text);
    try std.testing.expect(hasWarning(result, "boundary echo"));
}

test "hashline: boundary repair leaves a balance-preserving replacement alone (no false positive)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(
        arena.allocator(),
        "foo();\nbar();\nbar();\nbaz();",
        "SWAP 2.=2:\n+qux();\n+bar();",
    );
    try std.testing.expectEqualStrings("foo();\nqux();\nbar();\nbar();\nbaz();", result.text);
    try std.testing.expectEqual(@as(usize, 0), result.warnings.len);
}

test "hashline: boundary repair does not drop a balance-neutral duplicated statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(arena.allocator(), "a = 1;\nb = 2;\nc = 3;", "SWAP 1.=1:\n+a = 1;\n+b = 2;");
    try std.testing.expectEqualStrings("a = 1;\nb = 2;\nb = 2;\nc = 3;", result.text);
    try std.testing.expectEqual(@as(usize, 0), result.warnings.len);
}

test "hashline: boundary repair ignores brackets inside string literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(
        arena.allocator(),
        "const a = \"}\";\nconst b = \"x\";\nconst c = \"y\";",
        "SWAP 2.=2:\n+const b = \"}}}\";",
    );
    try std.testing.expectEqualStrings("const a = \"}\";\nconst b = \"}}}\";\nconst c = \"y\";", result.text);
    try std.testing.expectEqual(@as(usize, 0), result.warnings.len);
}

test "hashline: boundary repair drops a one-sided trailing keeper echo in a multi-line rewrite" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(
        arena.allocator(),
        "function f() {\n  a();\n  b();\n  const out = [];\n  return out;\n}",
        "SWAP 2.=3:\n+  a2();\n+  b2();\n+  const out = [];",
    );
    try std.testing.expectEqualStrings("function f() {\n  a2();\n  b2();\n  const out = [];\n  return out;\n}", result.text);
    try std.testing.expect(hasWarning(result, "boundary echo"));
}

test "hashline: boundary repair drops a one-sided JSX closer echo in a single-line expansion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(
        arena.allocator(),
        "const view = (\n  <section>\n    <Old />\n  </section>\n);",
        "SWAP 3.=3:\n+    <New />\n+  </section>",
    );
    try std.testing.expectEqualStrings("const view = (\n  <section>\n    <New />\n  </section>\n);", result.text);
    try std.testing.expectEqual(@as(usize, 1), lineCount(result.text, "  </section>"));
    try std.testing.expect(hasWarning(result, "boundary echo"));
}

test "hashline: boundary repair drops a JSX closer echo after a self-closing tag with a greater-than prop expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(
        arena.allocator(),
        "const view = (\n<Foo>\nold text\n</Foo>\n);",
        "SWAP 3.=3:\n+<Foo value={a > b} />\n+</Foo>",
    );
    try std.testing.expectEqualStrings("const view = (\n<Foo>\n<Foo value={a > b} />\n</Foo>\n);", result.text);
    try std.testing.expectEqual(@as(usize, 1), lineCount(result.text, "</Foo>"));
    try std.testing.expect(hasWarning(result, "boundary echo"));
}

test "hashline: boundary repair does not treat `<Foo / >` as a self-closing JSX tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(
        arena.allocator(),
        "const view = (\n<Foo>\nold text\n</Foo>\n);",
        "SWAP 3.=3:\n+<Foo / >\n+</Foo>",
    );
    try std.testing.expectEqualStrings(
        "const view = (\n<Foo>\n<Foo / >\n</Foo>\n</Foo>\n);",
        result.text,
    );
    try std.testing.expectEqual(@as(usize, 2), lineCount(result.text, "</Foo>"));
    try std.testing.expectEqual(@as(usize, 0), result.warnings.len);
}

test "hashline: boundary repair preserves a nested JSX closer that matches the surviving parent closer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(
        arena.allocator(),
        "const view = (\n<section className=\"outer\">\nold text\n</section>\n);",
        "SWAP 3.=3:\n+<section>\n+new text\n+</section>",
    );
    try std.testing.expectEqualStrings(
        "const view = (\n<section className=\"outer\">\n<section>\nnew text\n</section>\n</section>\n);",
        result.text,
    );
    try std.testing.expectEqual(@as(usize, 2), lineCount(result.text, "</section>"));
    try std.testing.expectEqual(@as(usize, 0), result.warnings.len);
}

test "hashline: boundary repair preserves a nested JSX closer when the opener spans payload lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(
        arena.allocator(),
        "const view = (\n<section className=\"outer\">\nold text\n</section>\n);",
        "SWAP 3.=3:\n+<section\n+  className=\"inner\"\n+>\n+new text\n+</section>",
    );
    try std.testing.expectEqualStrings(
        "const view = (\n<section className=\"outer\">\n<section\n  className=\"inner\"\n>\nnew text\n</section>\n</section>\n);",
        result.text,
    );
    try std.testing.expectEqual(@as(usize, 2), lineCount(result.text, "</section>"));
    try std.testing.expectEqual(@as(usize, 0), result.warnings.len);
}

test "hashline: boundary repair drops a one-sided leading keeper echo in a multi-line rewrite" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(
        arena.allocator(),
        "setup();\na();\nb();\nc();",
        "SWAP 3.=4:\n+a();\n+B();\n+C();",
    );
    try std.testing.expectEqualStrings("setup();\na();\nB();\nC();", result.text);
    try std.testing.expect(hasWarning(result, "boundary echo"));
}

test "hashline: boundary repair does not keep a deleted closer when another hunk removes its opener (#3142)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(
        arena.allocator(),
        "if enabled {\n\tText(\"Old\")\n}\n\tText(\"Tail\")",
        "DEL 1\nSWAP 2.=3:\n+Text(\"New\")",
    );
    try std.testing.expectEqualStrings("Text(\"New\")\n\tText(\"Tail\")", result.text);
    try std.testing.expectEqual(@as(usize, 0), warningCount(result, "structural closing line"));
}

test "hashline: boundary repair spends the missing-closer residual on the genuine hunk, not an earlier wrapper removal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(
        arena.allocator(),
        "if enabled {\n\tText(\"Old\")\n}\nconst config = {\n\ta: 1,\n};",
        "DEL 1\nSWAP 2.=3:\n+Text(\"New\")\nSWAP 6.=6:\n+\tb: 2,",
    );
    try std.testing.expectEqualStrings("Text(\"New\")\nconst config = {\n\ta: 1,\n\tb: 2,\n};", result.text);
    try std.testing.expectEqual(@as(usize, 1), warningCount(result, "structural closing line"));
}

test "hashline: boundary repair keeps the closer when the matching opener is replaced rather than removed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(
        arena.allocator(),
        "if (a) {\n\told();\n}",
        "SWAP 1.=1:\n+if (b) {\nSWAP 2.=3:\n+\tnew();",
    );
    try std.testing.expectEqualStrings("if (b) {\n\tnew();\n}", result.text);
    try std.testing.expectEqual(@as(usize, 1), warningCount(result, "structural closing line"));
}

test "hashline: boundary repair does not keep deleted closer suffixes whose tail the payload already restates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const file =
        "const REASONING_LABEL_PATTERN = /think/i;\n" ++
        "const NO_REASONING_LABEL_PATTERN = /no/i;\n\n" ++
        "\treturn config.supportsThinking === true;\n}\n}";
    const diff =
        "SWAP 3.=6:\n+function supportsDevinThinking(config: ClientModelConfig): boolean {\n" ++
        "+\tif (NO_REASONING_LABEL_PATTERN.test(config.label)) return false;\n" ++
        "+\treturn config.supportsThinking === true;\n+}";
    const result = try applyPatch(arena.allocator(), file, diff);
    try std.testing.expectEqualStrings(
        "const REASONING_LABEL_PATTERN = /think/i;\n" ++
            "const NO_REASONING_LABEL_PATTERN = /no/i;\n" ++
            "function supportsDevinThinking(config: ClientModelConfig): boolean {\n" ++
            "\tif (NO_REASONING_LABEL_PATTERN.test(config.label)) return false;\n" ++
            "\treturn config.supportsThinking === true;\n}",
        result.text,
    );
    try std.testing.expectEqual(@as(usize, 0), warningCount(result, "structural closing line"));
}

test "hashline: boundary repair keeps only the non-restated outer closer for a nested deleted suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(
        arena.allocator(),
        "class C {\n\told();\n\t}\n}",
        "SWAP 2.=4:\n+\tnewMethod() {\n+\t\treturn 1;\n+\t}",
    );
    try std.testing.expectEqualStrings("class C {\n\tnewMethod() {\n\t\treturn 1;\n\t}\n}", result.text);
    try std.testing.expectEqual(@as(usize, 1), warningCount(result, "structural closing line"));
}

test "hashline: boundary repair ignores non-contiguously deleted openers when choosing which closer to keep" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(
        arena.allocator(),
        "if (a) {\n\told();\n\tmore();\n}\nconst obj = {\n\ta: 1,\n};",
        "DEL 1\nSWAP 3.=4:\n+\tnew();\nSWAP 7.=7:\n+\tb: 2,",
    );
    try std.testing.expectEqualStrings("\told();\n\tnew();\nconst obj = {\n\ta: 1,\n\tb: 2,\n};", result.text);
    try std.testing.expectEqual(@as(usize, 1), warningCount(result, "structural closing line"));
}

test "hashline: boundary repair counts earlier kept closers in later projected prefixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const file =
        "if (a) {\n\told();\n}\n" ++
        "const NO_REASONING_LABEL_PATTERN = /no/i;\n" ++
        "\treturn config.supportsThinking === true;\n\t}";
    const diff =
        "SWAP 2.=3:\n+\tnew();\nSWAP 4.=6:\n" ++
        "+function supportsDevinThinking(config: ClientModelConfig): boolean {\n" ++
        "+\treturn config.supportsThinking === true;\n+}";
    const result = try applyPatch(arena.allocator(), file, diff);
    try std.testing.expectEqualStrings(
        "if (a) {\n\tnew();\n}\nfunction supportsDevinThinking(config: ClientModelConfig): boolean {\n" ++
            "\treturn config.supportsThinking === true;\n}",
        result.text,
    );
    try std.testing.expectEqual(@as(usize, 1), warningCount(result, "structural closing line"));
}

test "hashline: boundary repair does not let an earlier kept closer cover a later orphan closer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(
        arena.allocator(),
        "if (a) {\n\told();\n}\n}",
        "SWAP 2.=3:\n+\tnew();\nSWAP 4.=4:\n+after();",
    );
    try std.testing.expectEqualStrings("if (a) {\n\tnew();\n}\nafter();", result.text);
    try std.testing.expectEqual(@as(usize, 1), warningCount(result, "structural closing line"));
}

test "hashline: boundary repair does not keep a deleted outer closer when one survives below the range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(
        arena.allocator(),
        "class C {\n\tmethod() {\n\t\told();\n\t}\n}\n}",
        "SWAP 2.=5:\n+\tmethod() {\n+\t\tnew();\n+\t}",
    );
    try std.testing.expectEqualStrings("class C {\n\tmethod() {\n\t\tnew();\n\t}\n}", result.text);
    try std.testing.expectEqual(@as(usize, 0), warningCount(result, "structural closing line"));
}

test "hashline: boundary repair keeps an omitted inner closer when the outer closer survives below" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(
        arena.allocator(),
        "class C {\n\tmethod() {\n\t\told();\n\t}\n}\n}",
        "SWAP 2.=5:\n+\tmethod() {\n+\t\tnew();",
    );
    try std.testing.expectEqualStrings("class C {\n\tmethod() {\n\t\tnew();\n\t}\n}", result.text);
    try std.testing.expectEqual(@as(usize, 1), warningCount(result, "structural closing line"));
}

test "hashline: boundary repair counts same-line inserted prefixes before replacement payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(
        arena.allocator(),
        "\told();\n}",
        "INS.PRE 1:\n+if (a) {\nSWAP 1.=2:\n+\tnew();",
    );
    try std.testing.expectEqualStrings("if (a) {\n\tnew();\n}", result.text);
    try std.testing.expectEqual(@as(usize, 1), warningCount(result, "structural closing line"));
}

test "hashline: boundary repair counts a separately inserted closer immediately below the range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(
        arena.allocator(),
        "class C {\n\told();\n}\nafter();\nconst obj = {\n\ta: 1,\n};",
        "SWAP 2.=3:\n+\tnew();\nINS.PRE 4:\n+}\nSWAP 7.=7:\n+\tb: 2,",
    );
    try std.testing.expectEqualStrings("class C {\n\tnew();\n}\nafter();\nconst obj = {\n\ta: 1,\n\tb: 2,\n};", result.text);
    try std.testing.expectEqual(@as(usize, 1), warningCount(result, "structural closing line"));
}

test "hashline: boundary repair keeps an omitted outer closer even when the payload restates an inner closer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(
        arena.allocator(),
        "if (a) {\n\tif (b) {\n\t\told();\n\t}\n}\nafter();",
        "SWAP 1.=5:\n+if (a) {\n+\tif (c) {\n+\t\tnew();\n+\t}",
    );
    try std.testing.expectEqualStrings("if (a) {\n\tif (c) {\n\t\tnew();\n\t}\n}\nafter();", result.text);
    try std.testing.expectEqual(@as(usize, 1), warningCount(result, "structural closing line"));
}

test "hashline: boundary repair still keeps a missing closer when another hunk's dupSuffix repair masks the raw delta" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const file =
        "addEventListener(\"click\", () => {\n\tfoo();\n\tbar();\n});\n\n" ++
        "const config = {\n\ta: 1,\n};";
    const diff =
        "SWAP 2.=3:\n+\tsetup();\n+\tfoo();\n+\tbar();\n+});\n" ++
        "SWAP 8.=8:\n+\tb: 2,";
    const result = try applyPatch(arena.allocator(), file, diff);
    try std.testing.expectEqualStrings(
        "addEventListener(\"click\", () => {\n\tsetup();\n\tfoo();\n\tbar();\n});\n\n" ++
            "const config = {\n\ta: 1,\n\tb: 2,\n};",
        result.text,
    );
    try std.testing.expect(hasWarning(result, "trailing payload line"));
    try std.testing.expect(hasWarning(result, "structural closing line"));
}

test "hashline: boundary repair does not let an unterminated template in one hunk mask a missing closer in another" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(
        arena.allocator(),
        "const log = makeLog(`\nprefix\n`);\nconst obj = {\n\ta: 1\n};",
        "SWAP 1.=1:\n+const log = createLog(`\nSWAP 5.=6:\n+\ta: 2",
    );
    try std.testing.expectEqualStrings("const log = createLog(`\nprefix\n`);\nconst obj = {\n\ta: 2\n};", result.text);
    try std.testing.expectEqual(@as(usize, 1), warningCount(result, "structural closing line"));
}

test "hashline: boundary repair de-duplicates a closer while recovering from a drifted file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const snapshot_text =
        "import { x } from \"y\";\n\n" ++
        "it('a', () => {\n\tsetup();\n\trun();\n});\n\n" ++
        "function filler1() { return 1; }\n" ++
        "function filler2() { return 2; }\n" ++
        "function filler3() { return 3; }\n" ++
        "function filler4() { return 4; }\n" ++
        "function filler5() { return 5; }\n" ++
        "const tail = 0;\nexport { tail };\n";
    const current_text = try std.mem.replaceOwned(u8, allocator, snapshot_text, "const tail = 0;", "const tail = 99;");
    var store = snapshots.SnapshotStore.init(allocator, .{});
    defer store.deinit();
    const file_hash = try store.record("/tmp/__hashline-boundary-recovery__.ts", snapshot_text, null);
    const parsed = try parseOrFail(allocator, "SWAP 4.=5:\n+\tsetup2();\n+\trun2();\n+});");
    var recovery = recovery_mod.Recovery.init(&store);
    const recovered = (try recovery.tryRecover(allocator, .{
        .path = "/tmp/__hashline-boundary-recovery__.ts",
        .current_text = current_text,
        .file_hash = &file_hash,
        .edits = parsed.edits,
    })) orelse return error.ExpectedRecovery;
    try std.testing.expectEqual(@as(usize, 1), lineCount(recovered.text, "});"));
    try std.testing.expect(std.mem.indexOf(u8, recovered.text, "setup2();") != null);
    try std.testing.expect(std.mem.indexOf(u8, recovered.text, "run2();") != null);
    try std.testing.expect(std.mem.indexOf(u8, recovered.text, "const tail = 99;") != null);
    var found = false;
    for (recovered.warnings) |warning| {
        if (std.mem.indexOf(u8, warning, "delimiter-balance") != null) found = true;
    }
    try std.testing.expect(found);
}

test "hashline: after-insert landing shift slides a shallower body past the closing line and warns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const file = "function f() {\n    if (x) {\n        a();\n    }\n    b();\n}\n";
    const result = try applyPatch(arena.allocator(), file, "INS.POST 3:\n+    c();");
    try std.testing.expectEqualStrings(
        "function f() {\n    if (x) {\n        a();\n    }\n    c();\n    b();\n}\n",
        result.text,
    );
    try std.testing.expectEqual(@as(usize, 1), result.warnings.len);
    try std.testing.expect(hasWarning(result, "moved past 1 closing line to after line 4"));
}

test "hashline: after-insert landing shift recognizes a closer followed by Unicode no-break space" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const file = "function f() {\n    if (x) {\n        a();\n    }\xc2\xa0\n    b();\n}\n";
    const result = try applyPatch(arena.allocator(), file, "INS.POST 3:\n+    c();");
    try std.testing.expectEqualStrings(
        "function f() {\n    if (x) {\n        a();\n    }\xc2\xa0\n    c();\n    b();\n}\n",
        result.text,
    );
    try std.testing.expectEqual(@as(usize, 1), result.warnings.len);
    try std.testing.expect(hasWarning(result, "moved past 1 closing line to after line 4"));
}

test "hashline: after-insert landing shift crosses multiple closer levels and stops when depth returns to the body's" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const file =
        "function f() {\n    if (x) {\n        for (y) {\n            a();\n" ++
        "        }\n    }\n    b();\n}\n";
    const outer = try applyPatch(arena.allocator(), file, "INS.POST 4:\n+    c();");
    try std.testing.expectEqualStrings("    c();", lineAt(outer.text, 6));
    try std.testing.expect(hasWarning(outer, "moved past 2 closing lines to after line 6"));

    const inner = try applyPatch(arena.allocator(), file, "INS.POST 4:\n+        c();");
    try std.testing.expectEqualStrings("        c();", lineAt(inner.text, 5));
    try std.testing.expect(hasWarning(inner, "moved past 1 closing line to after line 5"));
}

test "hashline: after-insert landing shift does not shift when the body matches the anchor's depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const file = "function f() {\n    if (x) {\n        a();\n    }\n    b();\n}\n";
    const result = try applyPatch(arena.allocator(), file, "INS.POST 3:\n+        c();");
    try std.testing.expectEqualStrings("        c();", lineAt(result.text, 3));
}

test "hashline: after-insert landing shift never crosses content lines (indentation-only languages stay put)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try applyPatch(
        arena.allocator(),
        "def f():\n    if x:\n        a()\n    b()\n",
        "INS.POST 3:\n+    c()",
    );
    try std.testing.expectEqualStrings("def f():\n    if x:\n        a()\n    c()\n    b()\n", result.text);
    try std.testing.expectEqual(@as(usize, 0), result.warnings.len);
}

test "hashline: after-insert landing shift treats a body of pure closers as depth-neutral" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const file = "function f() {\n    if (x) {\n        a();\n    }\n    b();\n}\n";
    const result = try applyPatch(arena.allocator(), file, "INS.POST 3:\n+    }");
    try std.testing.expectEqualStrings("    }", lineAt(result.text, 3));
    try std.testing.expectEqual(@as(usize, 0), result.warnings.len);
}

test "hashline: after-insert landing shift skips incomparable indentation styles (tabs file, spaces body)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const file = "function f() {\n\tif (x) {\n\t\ta();\n\t}\n\tb();\n}\n";
    const result = try applyPatch(arena.allocator(), file, "INS.POST 3:\n+    c();");
    try std.testing.expectEqualStrings("    c();", lineAt(result.text, 3));
}

test "hashline: after-insert landing shift refuses to cross a line targeted by another hunk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const file = "function f() {\n    if (x) {\n        a();\n    }\n    b();\n}\n";
    const result = try applyPatch(arena.allocator(), file, "INS.POST 3:\n+    c();\nDEL 4");
    try std.testing.expectEqualStrings("function f() {\n    if (x) {\n        a();\n    c();\n    b();\n}\n", result.text);
    try std.testing.expectEqual(@as(usize, 0), result.warnings.len);
}

test "hashline: after-insert landing shift looks past blank lines between the anchor and the closer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const file = "function f() {\n    if (x) {\n        a();\n\n    }\n    b();\n}\n";
    const result = try applyPatch(arena.allocator(), file, "INS.POST 3:\n+    c();");
    try std.testing.expectEqualStrings(
        "function f() {\n    if (x) {\n        a();\n\n    }\n    c();\n    b();\n}\n",
        result.text,
    );
    try std.testing.expect(hasWarning(result, "after line 5"));
}

test "hashline: after-insert landing shift leaves `INS.PRE N:` untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const file = "function f() {\n    if (x) {\n        a();\n    }\n    b();\n}\n";
    const result = try applyPatch(arena.allocator(), file, "INS.PRE 4:\n+    c();");
    try std.testing.expectEqualStrings("    c();", lineAt(result.text, 3));
    try std.testing.expectEqual(@as(usize, 0), result.warnings.len);
}

test "hashline: after-insert landing shift composes with `INS.BLK.POST N:` to escape enclosing closers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const file = "function f() {\n    const t = mk({\n    });\n}\nx();\n";
    const result = try resolveAndApply(
        arena.allocator(),
        file,
        "INS.BLK.POST 2:\n+ref = t;",
        types.BlockResolver.fromFunction(spanPlusOne),
    );
    try std.testing.expectEqualStrings("function f() {\n    const t = mk({\n    });\n}\nref = t;\nx();\n", result.text);
    try std.testing.expect(hasWarning(result, "moved past 1 closing line to after line 4"));
}

test "hashline: insert-after-block inward landing shift pulls a deeper body inside the block, after its last content line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const file = "function f() {\n    afterEach(() => {\n        destroy();\n    });\n}\n";
    const result = try resolveAndApply(
        arena.allocator(),
        file,
        "INS.BLK.POST 2:\n+        setup();",
        types.BlockResolver.fromFunction(spanPlusTwo),
    );
    try std.testing.expectEqualStrings(
        "function f() {\n    afterEach(() => {\n        destroy();\n        setup();\n    });\n}\n",
        result.text,
    );
    try std.testing.expect(hasWarning(result, "placed inside the block, after line 3"));
}

test "hashline: insert-after-block inward landing shift lands right after the opener of an empty block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const file = "function f() {\n    afterEach(() => {\n    });\n}\n";
    const result = try resolveAndApply(
        arena.allocator(),
        file,
        "INS.BLK.POST 2:\n+        setup();",
        types.BlockResolver.fromFunction(spanPlusOne),
    );
    try std.testing.expectEqualStrings("function f() {\n    afterEach(() => {\n        setup();\n    });\n}\n", result.text);
    try std.testing.expect(hasWarning(result, "placed inside the block, after line 2"));
}

test "hashline: insert-after-block inward landing shift crosses nested trailing closers and stops at the body's claimed depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const file = "foo(() => {\n    bar(() => {\n        x();\n    });\n});\n";
    const result = try resolveAndApply(
        arena.allocator(),
        file,
        "INS.BLK.POST 1:\n+    baz();",
        types.BlockResolver.fromFunction(spanOneToFive),
    );
    try std.testing.expectEqualStrings("foo(() => {\n    bar(() => {\n        x();\n    });\n    baz();\n});\n", result.text);
    try std.testing.expect(hasWarning(result, "placed inside the block, after line 4"));
}

test "hashline: insert-after-block inward landing shift leaves a sibling-depth body after the block (the literal contract)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const file = "function f() {\n    afterEach(() => {\n        destroy();\n    });\n}\n";
    const result = try resolveAndApply(
        arena.allocator(),
        file,
        "INS.BLK.POST 2:\n+    cleanup();",
        types.BlockResolver.fromFunction(spanPlusTwo),
    );
    try std.testing.expectEqualStrings(
        "function f() {\n    afterEach(() => {\n        destroy();\n    });\n    cleanup();\n}\n",
        result.text,
    );
    try std.testing.expectEqual(@as(usize, 0), result.warnings.len);
}

test "hashline: insert-after-block inward landing shift never shifts a plain `INS.POST M:` anchored on a closer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const file = "function f() {\n    afterEach(() => {\n        destroy();\n    });\n}\n";
    const result = try applyPatch(arena.allocator(), file, "INS.POST 4:\n+        leak();");
    try std.testing.expectEqualStrings("        leak();", lineAt(result.text, 4));
    try std.testing.expectEqual(@as(usize, 0), result.warnings.len);
}

test "hashline: insert-after-block inward landing shift refuses to cross a closer targeted by another hunk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const file = "foo(() => {\n    bar(() => {\n        x();\n    });\n});\n";
    const result = try resolveAndApply(
        arena.allocator(),
        file,
        "SWAP 4.=4:\n+    }); // bar\nINS.BLK.POST 1:\n+        y();",
        types.BlockResolver.fromFunction(spanOneToFive),
    );
    try std.testing.expectEqualStrings(
        "foo(() => {\n    bar(() => {\n        x();\n    }); // bar\n});\n        y();\n",
        result.text,
    );
    try std.testing.expect(!hasWarning(result, "placed inside the block"));
}
