//! High-level prepare-all-then-commit hashline orchestrator.

const std = @import("std");
const apply_mod = @import("apply.zig");
const block = @import("block.zig");
const format = @import("format.zig");
const fs_mod = @import("fs.zig");
const input = @import("input.zig");
const messages = @import("messages.zig");
const mismatch = @import("mismatch.zig");
const normalize = @import("normalize.zig");
const recovery_mod = @import("recovery.zig");
const render_mod = @import("render.zig");
const snapshots = @import("snapshots.zig");
const types = @import("types.zig");

pub const seen_line_reveal_cap = 40;
pub const seen_line_reveal_max_columns = 512;

pub const Operation = enum {
    create,
    update,
    delete,
    noop,
};

pub const SectionResult = struct {
    path: []const u8,
    canonical_path: []const u8,
    op: Operation,
    before: []const u8,
    after: []const u8,
    persisted: []const u8,
    written: []const u8,
    file_hash: format.FileHash,
    header: []const u8,
    first_changed_line: ?usize = null,
    warnings: []const []const u8 = &.{},
    move_dest: ?[]const u8 = null,
    block_resolutions: []const types.BlockResolution = &.{},

    pub fn render(self: SectionResult, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self.op) {
            .delete => render_mod.renderDeletedSection(allocator, self.path),
            .noop => render_mod.noChangeDiagnostic(allocator, self.path),
            .create, .update => render_mod.renderAppliedSection(
                allocator,
                self.header,
                self.before,
                self.after,
                self.block_resolutions,
                self.move_dest,
                self.warnings,
            ),
        };
    }
};

pub const ApplyResult = struct {
    sections: []const SectionResult,

    pub fn render(self: ApplyResult, allocator: std.mem.Allocator) ![]const u8 {
        var rendered: std.ArrayList([]const u8) = .empty;
        for (self.sections) |section| try rendered.append(allocator, try section.render(allocator));
        return std.mem.join(allocator, "\n\n", rendered.items);
    }
};

pub const PreparedSection = struct {
    section: input.PatchSection,
    canonical_path: []const u8,
    exists: bool,
    raw_content: []const u8,
    bom: []const u8,
    line_ending: normalize.LineEnding,
    normalized: []const u8,
    apply_result: types.ApplyResult,
    parse_warnings: []const []const u8,
    file_op: ?types.FileOp,

    pub fn isNoop(self: PreparedSection) bool {
        return self.file_op == null and std.mem.eql(u8, self.apply_result.text, self.normalized);
    }
};

pub const Options = struct {
    fs: fs_mod.Fs,
    snapshot_store: *snapshots.SnapshotStore,
    block_resolver: ?types.BlockResolver = null,
    /// Working-tree root used to contain every tag-based path recovery.
    cwd: []const u8 = ".",
    allow_tag_path_recovery: bool = true,
};

pub const Patcher = struct {
    fs: fs_mod.Fs,
    snapshot_store: *snapshots.SnapshotStore,
    recovery: recovery_mod.Recovery,
    block_resolver: ?types.BlockResolver,
    cwd: []const u8,
    allow_tag_path_recovery: bool,

    pub fn init(options: Options) Patcher {
        return .{
            .fs = options.fs,
            .snapshot_store = options.snapshot_store,
            .recovery = recovery_mod.Recovery.init(options.snapshot_store),
            .block_resolver = options.block_resolver,
            .cwd = options.cwd,
            .allow_tag_path_recovery = options.allow_tag_path_recovery,
        };
    }

    pub fn applyText(
        self: *Patcher,
        allocator: std.mem.Allocator,
        patch_text: []const u8,
    ) !types.Outcome(ApplyResult) {
        const parsed = try input.Patch.parse(allocator, patch_text, .{ .cwd = self.cwd });
        return switch (parsed) {
            .failure => |failure| .{ .failure = failure },
            .success => |patch| self.apply(allocator, patch),
        };
    }

    pub fn apply(
        self: *Patcher,
        allocator: std.mem.Allocator,
        patch: input.Patch,
    ) !types.Outcome(ApplyResult) {
        if (patch.sections.len == 1) {
            const prepared_outcome = try self.prepare(allocator, patch.sections[0]);
            const prepared = switch (prepared_outcome) {
                .failure => |failure| return .{ .failure = failure },
                .success => |value| value,
            };
            const committed = try self.commit(allocator, prepared);
            return switch (committed) {
                .failure => |failure| .{ .failure = failure },
                .success => |section| .{ .success = .{ .sections = try allocator.dupe(SectionResult, &.{section}) } },
            };
        }

        var prepared: std.ArrayList(PreparedSection) = .empty;
        for (patch.sections) |section| {
            const outcome = try self.prepare(allocator, section);
            switch (outcome) {
                .failure => |failure| return .{ .failure = failure },
                .success => |value| try prepared.append(allocator, value),
            }
        }
        if (try assertUniqueCanonicalPaths(allocator, prepared.items)) |failure| return .{ .failure = failure };
        for (prepared.items) |entry| {
            if (entry.isNoop()) {
                return .{ .failure = types.failure(try messages.noChangesMadeMessage(
                    allocator,
                    entry.section.path,
                )) };
            }
        }

        var results: std.ArrayList(SectionResult) = .empty;
        for (prepared.items, 0..) |entry, index| {
            const committed = try self.commit(allocator, entry);
            switch (committed) {
                .success => |section| try results.append(allocator, section),
                .failure => |failure| {
                    const aggregate = try aggregateCommitFailure(
                        allocator,
                        prepared.items,
                        index,
                        failure.message,
                    );
                    return .{ .failure = types.failureKind(.io, aggregate) };
                },
            }
        }
        return .{ .success = .{ .sections = try results.toOwnedSlice(allocator) } };
    }

    pub fn preflight(
        self: *Patcher,
        allocator: std.mem.Allocator,
        patch: input.Patch,
    ) !types.Outcome(void) {
        var prepared: std.ArrayList(PreparedSection) = .empty;
        for (patch.sections) |section| {
            const outcome = try self.prepare(allocator, section);
            switch (outcome) {
                .failure => |failure| return .{ .failure = failure },
                .success => |value| try prepared.append(allocator, value),
            }
        }
        if (try assertUniqueCanonicalPaths(allocator, prepared.items)) |failure| return .{ .failure = failure };
        for (prepared.items) |entry| {
            if (entry.isNoop()) {
                return .{ .failure = types.failure(try messages.noChangesMadeMessage(
                    allocator,
                    entry.section.path,
                )) };
            }
        }
        return .{ .success = {} };
    }

    pub fn prepare(
        self: *Patcher,
        allocator: std.mem.Allocator,
        authored_section: input.PatchSection,
    ) !types.Outcome(PreparedSection) {
        if (authored_section.file_hash == null) {
            return .{ .failure = types.failure(try messages.missingSnapshotTagMessage(
                allocator,
                authored_section.path,
            )) };
        }

        var warning_list: std.ArrayList([]const u8) = .empty;
        try warning_list.appendSlice(allocator, authored_section.warnings);
        var section = authored_section;
        var canonical_path = switch (try self.canonicalPath(allocator, section.path)) {
            .failure => |failure| return .{ .failure = failure },
            .success => |path| path,
        };
        var read = try self.tryRead(allocator, section.path);
        if (read == .failure) return .{ .failure = read.failure };

        if (read == .missing and self.allow_tag_path_recovery) {
            const recovered = switch (try self.recoverSectionPathFromTag(allocator, section, canonical_path)) {
                .failure => |failure| return .{ .failure = failure },
                .success => |target| target,
            };
            if (recovered) |target| {
                if (try self.pathRecoveryAllowed(allocator, section.path, target.section.path)) {
                    try warning_list.append(allocator, try messages.pathRecoveredFromTagMessage(
                        allocator,
                        section.path,
                        target.section.path,
                        &section.file_hash.?,
                    ));
                    section = target.section;
                    canonical_path = target.canonical_path;
                    read = try self.tryRead(allocator, section.path);
                    if (read == .failure) return .{ .failure = read.failure };
                }
            }
        }

        self.fs.preflightWrite(section.path, section.file_op) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .failure = try self.ioFailure(allocator, err) };
        };
        if (read == .missing) {
            return .{ .failure = types.failureKind(
                .not_found,
                try messages.fileNotFoundMessage(allocator, section.path),
            ) };
        }

        if (section.file_op) |file_op| switch (file_op) {
            .move => |dest| {
                const destination = switch (try self.canonicalPath(allocator, dest)) {
                    .failure => |failure| return .{ .failure = failure },
                    .success => |path| path,
                };
                if (std.mem.eql(u8, destination, canonical_path)) {
                    return .{ .failure = types.failure(try messages.moveDestinationSameMessage(
                        allocator,
                        section.path,
                    )) };
                }
            },
            .rem => {},
        };

        const raw_content = read.found;
        const stripped = normalize.stripBom(raw_content);
        const line_ending = normalize.detectLineEnding(stripped.text);
        const normalized = try normalize.normalizeToLf(allocator, stripped.text);
        const edits: []const types.Edit = if (section.file_op != null and section.file_op.? == .rem) &.{} else section.edits;
        const applied = try self.applyWithRecovery(allocator, section, canonical_path, normalized, edits);
        const apply_result = switch (applied) {
            .failure => |failure| return .{ .failure = failure },
            .success => |result| result,
        };
        return .{ .success = .{
            .section = section,
            .canonical_path = canonical_path,
            .exists = true,
            .raw_content = raw_content,
            .bom = stripped.bom,
            .line_ending = line_ending,
            .normalized = normalized,
            .apply_result = apply_result,
            .parse_warnings = try warning_list.toOwnedSlice(allocator),
            .file_op = section.file_op,
        } };
    }

    pub fn commit(
        self: *Patcher,
        allocator: std.mem.Allocator,
        prepared: PreparedSection,
    ) !types.Outcome(SectionResult) {
        const section = prepared.section;
        const after = prepared.apply_result.text;
        const warnings = try mergeWarnings(
            allocator,
            &.{ prepared.parse_warnings, prepared.apply_result.warnings },
        );
        const move_dest: ?[]const u8 = if (prepared.file_op) |op| switch (op) {
            .move => |dest| dest,
            .rem => null,
        } else null;

        if (prepared.file_op != null and prepared.file_op.? == .rem) {
            self.fs.delete(section.path) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return .{ .failure = try self.ioFailure(allocator, err) };
            };
            self.snapshot_store.invalidate(prepared.canonical_path);
            const hash = format.computeFileHash(prepared.normalized);
            return .{ .success = .{
                .path = section.path,
                .canonical_path = prepared.canonical_path,
                .op = .delete,
                .before = prepared.normalized,
                .after = prepared.normalized,
                .persisted = prepared.raw_content,
                .written = prepared.raw_content,
                .file_hash = hash,
                .header = try format.formatHashlineHeader(allocator, section.path, &hash),
                .warnings = warnings,
            } };
        }

        if (std.mem.eql(u8, after, prepared.normalized) and move_dest == null) {
            const hash = try self.snapshot_store.record(prepared.canonical_path, prepared.normalized, null);
            return .{ .success = .{
                .path = section.path,
                .canonical_path = prepared.canonical_path,
                .op = .noop,
                .before = prepared.normalized,
                .after = prepared.normalized,
                .persisted = prepared.raw_content,
                .written = prepared.raw_content,
                .file_hash = hash,
                .header = try format.formatHashlineHeader(allocator, section.path, &hash),
                .warnings = warnings,
            } };
        }

        const restored = try normalize.restoreLineEndings(allocator, after, prepared.line_ending);
        const persisted = if (prepared.bom.len == 0)
            restored
        else
            try std.mem.concat(allocator, u8, &.{ prepared.bom, restored });

        if (move_dest) |dest| {
            const dest_canonical = switch (try self.canonicalPath(allocator, dest)) {
                .failure => |failure| return .{ .failure = failure },
                .success => |path| path,
            };
            try self.snapshot_store.relocate(prepared.canonical_path, dest_canonical);
            self.fs.rename(section.path, dest, persisted) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return .{ .failure = try self.ioFailure(allocator, err) };
            };
            const hash = try self.snapshot_store.record(dest_canonical, after, null);
            return .{ .success = .{
                .path = dest,
                .canonical_path = dest_canonical,
                .op = .update,
                .before = prepared.normalized,
                .after = after,
                .persisted = persisted,
                .written = persisted,
                .file_hash = hash,
                .header = try format.formatHashlineHeader(allocator, dest, &hash),
                .first_changed_line = prepared.apply_result.first_changed_line,
                .warnings = warnings,
                .move_dest = dest,
                .block_resolutions = prepared.apply_result.block_resolutions,
            } };
        }

        const written = self.fs.write(allocator, section.path, persisted) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .failure = try self.ioFailure(allocator, err) };
        };
        const hash = try self.snapshot_store.record(prepared.canonical_path, after, null);
        return .{ .success = .{
            .path = section.path,
            .canonical_path = prepared.canonical_path,
            .op = if (prepared.exists) .update else .create,
            .before = prepared.normalized,
            .after = after,
            .persisted = persisted,
            .written = written,
            .file_hash = hash,
            .header = try format.formatHashlineHeader(allocator, section.path, &hash),
            .first_changed_line = prepared.apply_result.first_changed_line,
            .warnings = warnings,
            .block_resolutions = prepared.apply_result.block_resolutions,
        } };
    }

    const ReadResult = union(enum) {
        found: []const u8,
        missing,
        failure: types.Failure,
    };

    fn tryRead(self: *Patcher, allocator: std.mem.Allocator, path: []const u8) !ReadResult {
        const content = self.fs.read(allocator, path) catch |err| switch (err) {
            error.FileNotFound => return .missing,
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .failure = try self.ioFailure(allocator, err) },
        };
        return .{ .found = content };
    }

    fn canonicalPath(
        self: *Patcher,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) !types.Outcome([]const u8) {
        const canonical = self.fs.canonicalPath(allocator, path) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .failure = try self.ioFailure(allocator, err) };
        };
        return .{ .success = canonical };
    }

    const RecoveredPath = struct {
        section: input.PatchSection,
        canonical_path: []const u8,
    };

    fn recoverSectionPathFromTag(
        self: *Patcher,
        allocator: std.mem.Allocator,
        section: input.PatchSection,
        original_canonical_path: []const u8,
    ) !types.Outcome(?RecoveredPath) {
        const hash = section.file_hash orelse return .{ .success = null };
        const authored_name = std.fs.path.basename(section.path);
        const matches = try self.snapshot_store.findByHash(allocator, &hash);
        var candidates: std.ArrayList(RecoveredPath) = .empty;
        for (matches) |snapshot| {
            if (!std.mem.eql(u8, std.fs.path.basename(snapshot.path), authored_name)) continue;
            const canonical = switch (try self.canonicalPath(allocator, snapshot.path)) {
                .failure => |failure| return .{ .failure = failure },
                .success => |path| path,
            };
            if (std.mem.eql(u8, canonical, original_canonical_path)) continue;
            var duplicate = false;
            for (candidates.items) |candidate| {
                if (std.mem.eql(u8, candidate.canonical_path, canonical)) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;
            try candidates.append(allocator, .{
                .section = try section.withPath(allocator, snapshot.path),
                .canonical_path = canonical,
            });
        }
        return .{ .success = if (candidates.items.len == 1) candidates.items[0] else null };
    }

    fn pathRecoveryAllowed(
        self: *Patcher,
        allocator: std.mem.Allocator,
        authored_path: []const u8,
        resolved_path: []const u8,
    ) !bool {
        if (!self.fs.allowTagPathRecovery(authored_path, resolved_path)) return false;
        if (!std.fs.path.isAbsolute(resolved_path)) return relativePathIsContained(resolved_path);
        if (!std.fs.path.isAbsolute(self.cwd)) return false;
        const cwd = try std.fs.path.resolve(allocator, &.{self.cwd});
        const resolved = try std.fs.path.resolve(allocator, &.{resolved_path});
        const relative = try std.fs.path.relative(allocator, cwd, null, cwd, resolved);
        return relative.len == 0 or (!std.fs.path.isAbsolute(relative) and !isParentRelative(relative));
    }

    fn applyWithRecovery(
        self: *Patcher,
        allocator: std.mem.Allocator,
        section: input.PatchSection,
        canonical_path: []const u8,
        normalized: []const u8,
        edits: []const types.Edit,
    ) !types.Outcome(types.ApplyResult) {
        const expected_hash = section.file_hash;
        const expected: ?[]const u8 = if (expected_hash) |*hash| hash else null;
        const stored_snapshot = if (expected) |hash| self.snapshot_store.byHash(canonical_path, hash) else null;
        const live_hash = format.computeFileHash(normalized);
        const live_matches = expected != null and std.mem.eql(u8, &live_hash, expected.?);
        const matched_snapshot = if (live_matches) self.snapshot_store.byContent(canonical_path, normalized) else null;

        var resolved_edits = edits;
        var block_resolutions: []const types.BlockResolution = &.{};
        var resolve_warnings: []const []const u8 = &.{};
        if (block.hasBlockEdit(edits)) {
            const base_text: ?[]const u8 = if (expected == null or live_matches)
                normalized
            else if (stored_snapshot) |snapshot|
                snapshot.text
            else
                null;
            if (base_text == null) {
                return .{ .failure = try self.mismatchFailure(
                    allocator,
                    section,
                    canonical_path,
                    normalized,
                    expected orelse "",
                    false,
                ) };
            }
            const outcome = try block.resolveBlockEdits(
                allocator,
                edits,
                base_text.?,
                section.path,
                self.block_resolver,
                .{},
            );
            const resolution = switch (outcome) {
                .failure => |failure| return .{ .failure = failure },
                .success => |value| value,
            };
            resolved_edits = resolution.edits;
            block_resolutions = resolution.resolutions;
            resolve_warnings = resolution.warnings;
        }

        if (expected == null or live_matches) {
            if (expected) |hash| {
                if (try self.assertSeenLines(allocator, section, hash, matched_snapshot)) |failure| {
                    return .{ .failure = failure };
                }
            }
            const outcome = try apply_mod.applyEdits(allocator, normalized, resolved_edits);
            const result = switch (outcome) {
                .failure => |failure| return .{ .failure = failure },
                .success => |value| value,
            };
            return .{ .success = .{
                .text = result.text,
                .first_changed_line = result.first_changed_line,
                .warnings = try mergeWarnings(allocator, &.{ resolve_warnings, result.warnings }),
                .block_resolutions = block_resolutions,
            } };
        }

        if (!hasAnchorScopedEdit(resolved_edits)) {
            const outcome = try apply_mod.applyEdits(allocator, normalized, resolved_edits);
            const result = switch (outcome) {
                .failure => |failure| return .{ .failure = failure },
                .success => |value| value,
            };
            return .{ .success = .{
                .text = result.text,
                .first_changed_line = result.first_changed_line,
                .warnings = try mergeWarnings(allocator, &.{
                    resolve_warnings,
                    &.{messages.headtail_drift_warning},
                    result.warnings,
                }),
            } };
        }

        if (try self.recovery.tryRecover(allocator, .{
            .path = canonical_path,
            .current_text = normalized,
            .file_hash = expected.?,
            .edits = resolved_edits,
        })) |recovered| {
            return .{ .success = .{
                .text = recovered.text,
                .first_changed_line = recovered.first_changed_line,
                .warnings = try mergeWarnings(allocator, &.{ resolve_warnings, recovered.warnings }),
            } };
        }
        const recognized = self.snapshot_store.byHash(canonical_path, expected.?) != null;
        return .{ .failure = try self.mismatchFailure(
            allocator,
            section,
            canonical_path,
            normalized,
            expected.?,
            recognized,
        ) };
    }

    fn ioFailure(self: *Patcher, allocator: std.mem.Allocator, err: anyerror) !types.Failure {
        return types.failureKind(.io, try self.fs.errorMessage(allocator, err));
    }

    fn assertSeenLines(
        self: *Patcher,
        allocator: std.mem.Allocator,
        section: input.PatchSection,
        expected: []const u8,
        matched_snapshot: ?*snapshots.Snapshot,
    ) !?types.Failure {
        const snapshot = matched_snapshot orelse return null;
        if (snapshot.seen_lines == null or snapshot.seen_lines.?.count() == 0) return null;
        var unseen: std.ArrayList(usize) = .empty;
        for (section.anchor_lines) |line| {
            if (!snapshot.seen_lines.?.contains(line)) try unseen.append(allocator, line);
        }
        if (unseen.items.len == 0) return null;

        const source_lines = try splitLines(allocator, snapshot.text);
        var revealed: std.ArrayList(messages.RevealedLine) = .empty;
        const reveal_count = @min(unseen.items.len, seen_line_reveal_cap);
        var column_truncated = false;
        for (unseen.items[0..reveal_count]) |line| {
            if (line < 1 or line > source_lines.len) continue;
            const source = source_lines[line - 1];
            const prefix_end = utf8PrefixForUtf16Units(source, seen_line_reveal_max_columns);
            if (prefix_end < source.len) {
                try revealed.append(allocator, .{
                    .line = line,
                    .text = try std.mem.concat(allocator, u8, &.{ source[0..prefix_end], "…" }),
                });
                column_truncated = true;
            } else {
                try revealed.append(allocator, .{ .line = line, .text = source });
            }
        }
        const truncated = unseen.items.len > revealed.items.len or column_truncated;
        if (!truncated) {
            for (revealed.items) |entry| try snapshot.seen_lines.?.put(self.snapshot_store.allocator, entry.line, {});
        }
        return types.failure(try messages.unseenLinesMessage(
            allocator,
            section.path,
            unseen.items,
            expected,
            .{ .lines = revealed.items, .truncated = truncated },
        ));
    }

    fn mismatchFailure(
        self: *Patcher,
        allocator: std.mem.Allocator,
        section: input.PatchSection,
        canonical_path: []const u8,
        normalized: []const u8,
        expected: []const u8,
        recognized: bool,
    ) !types.Failure {
        const actual = try self.snapshot_store.record(canonical_path, normalized, null);
        const file_lines = try splitLines(allocator, normalized);
        return mismatch.makeFailure(allocator, .{
            .path = section.path,
            .expected_file_hash = expected,
            .actual_file_hash = &actual,
            .file_lines = file_lines,
            .anchor_lines = section.anchor_lines,
            .hash_recognized = recognized,
        });
    }
};

fn hasAnchorScopedEdit(edits: []const types.Edit) bool {
    for (edits) |edit| if (edit.anchor() != null) return true;
    return false;
}

fn splitLines(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var iterator = std.mem.splitScalar(u8, text, '\n');
    while (iterator.next()) |line| try lines.append(allocator, line);
    return lines.toOwnedSlice(allocator);
}

fn mergeWarnings(
    allocator: std.mem.Allocator,
    sources: []const []const []const u8,
) ![]const []const u8 {
    var merged: std.ArrayList([]const u8) = .empty;
    for (sources) |source| try merged.appendSlice(allocator, source);
    return merged.toOwnedSlice(allocator);
}

fn assertUniqueCanonicalPaths(
    allocator: std.mem.Allocator,
    prepared: []const PreparedSection,
) !?types.Failure {
    for (prepared, 0..) |entry, index| {
        for (prepared[0..index]) |previous| {
            if (!std.mem.eql(u8, previous.canonical_path, entry.canonical_path)) continue;
            return types.failure(try messages.duplicateCanonicalPathMessage(
                allocator,
                previous.section.path,
                entry.section.path,
            ));
        }
    }
    return null;
}

fn aggregateCommitFailure(
    allocator: std.mem.Allocator,
    prepared: []const PreparedSection,
    failed_index: usize,
    cause: []const u8,
) ![]const u8 {
    var already_applied: std.ArrayList([]const u8) = .empty;
    if (failed_index > 0) {
        for (prepared[0..failed_index]) |entry| try already_applied.append(allocator, entry.section.path);
    }
    var not_applied: std.ArrayList([]const u8) = .empty;
    if (failed_index + 1 < prepared.len) {
        for (prepared[failed_index + 1 ..]) |entry| try not_applied.append(allocator, entry.section.path);
    }
    return messages.aggregateCommitFailureMessage(
        allocator,
        prepared[failed_index].section.path,
        cause,
        already_applied.items,
        not_applied.items,
    );
}

fn isParentRelative(path: []const u8) bool {
    if (std.mem.eql(u8, path, "..")) return true;
    return path.len >= 3 and std.mem.eql(u8, path[0..2], "..") and std.fs.path.isSep(path[2]);
}

fn relativePathIsContained(path: []const u8) bool {
    var depth: usize = 0;
    var component_start: usize = 0;
    var index: usize = 0;
    while (index <= path.len) : (index += 1) {
        if (index < path.len and !std.fs.path.isSep(path[index])) continue;
        const component = path[component_start..index];
        component_start = index + 1;
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            if (depth == 0) return false;
            depth -= 1;
        } else {
            depth += 1;
        }
    }
    return true;
}

/// Return a byte boundary that fits in `max_units` JavaScript UTF-16 code
/// units. A complete UTF-8 code point is either included or omitted; it is
/// never split.
fn utf8PrefixForUtf16Units(text: []const u8, max_units: usize) usize {
    var index: usize = 0;
    var units: usize = 0;
    while (index < text.len) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(text[index]) catch {
            if (units + 1 > max_units) break;
            units += 1;
            index += 1;
            continue;
        };
        if (index + sequence_len > text.len) break;
        const codepoint = std.unicode.utf8Decode(text[index .. index + sequence_len]) catch {
            if (units + 1 > max_units) break;
            units += 1;
            index += 1;
            continue;
        };
        const width: usize = if (codepoint > 0xFFFF) 2 else 1;
        if (units + width > max_units) break;
        units += width;
        index += sequence_len;
    }
    return index;
}

test "hashline patcher: live hash apply and fresh header" {
    var memory = fs_mod.InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    try memory.put("a.ts", "before\n");
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record("a.ts", "before\n", null);
    var patcher = Patcher.init(.{ .fs = memory.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const patch_text = try std.fmt.allocPrint(arena.allocator(), "[a.ts#{s}]\nSWAP 1.=1:\n+after", .{&tag});
    const outcome = try patcher.applyText(arena.allocator(), patch_text);
    const result = outcome.success.sections[0];
    try std.testing.expectEqual(Operation.update, result.op);
    try std.testing.expectEqualStrings("after\n", memory.get("a.ts").?);
    try std.testing.expect(!std.mem.eql(u8, &tag, &result.file_hash));
}

test "hashline patcher: BOM and CRLF round trip" {
    var memory = fs_mod.InMemoryFs.init(std.testing.allocator);
    defer memory.deinit();
    try memory.put("a.ts", "\xEF\xBB\xBFone\r\ntwo\r\n");
    var store = snapshots.SnapshotStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const tag = try store.record("a.ts", "one\ntwo\n", null);
    var patcher = Patcher.init(.{ .fs = memory.fs(), .snapshot_store = &store });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const patch_text = try std.fmt.allocPrint(arena.allocator(), "[a.ts#{s}]\nSWAP 2.=2:\n+TWO", .{&tag});
    const outcome = try patcher.applyText(arena.allocator(), patch_text);
    _ = outcome.success;
    try std.testing.expectEqualStrings("\xEF\xBB\xBFone\r\nTWO\r\n", memory.get("a.ts").?);
}
