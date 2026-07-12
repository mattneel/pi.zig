//! Self-contained hashline edit engine.
//!
//! Parsed and applied values use caller-owned allocation. An arena scoped to a
//! parse/apply transaction is the recommended ownership model; persistent
//! filesystem and snapshot-store implementations own their own allocations.

const std = @import("std");

pub const types = @import("types.zig");
pub const format = @import("format.zig");
pub const normalize = @import("normalize.zig");
pub const messages = @import("messages.zig");
pub const prefixes = @import("prefixes.zig");
pub const tokenizer = @import("tokenizer.zig");
pub const parser = @import("parser.zig");
pub const input = @import("input.zig");
pub const apply_engine = @import("apply.zig");
pub const block = @import("block.zig");
pub const diff = @import("diff.zig");
pub const recovery = @import("recovery.zig");
pub const snapshots = @import("snapshots.zig");
pub const mismatch = @import("mismatch.zig");
pub const diff_preview = @import("diff_preview.zig");
pub const fs = @import("fs.zig");
pub const patcher = @import("patcher.zig");
pub const render = @import("render.zig");
pub const stream = @import("stream.zig");

pub const grammar = @embedFile("grammar.lark");

pub const Anchor = types.Anchor;
pub const Cursor = types.Cursor;
pub const Edit = types.Edit;
pub const FileOp = types.FileOp;
pub const ParsedRange = types.ParsedRange;
pub const InsertMode = types.InsertMode;
pub const BlockMode = types.BlockMode;
pub const Failure = types.Failure;
pub const FailureKind = types.FailureKind;
pub const Outcome = types.Outcome;
pub const ApplyResult = types.ApplyResult;
pub const CompactDiffPreview = types.CompactDiffPreview;
pub const BlockSpan = types.BlockSpan;
pub const BlockResolution = types.BlockResolution;
pub const BlockResolutionOp = types.BlockResolutionOp;
pub const BlockResolver = types.BlockResolver;
pub const BlockResolverRequest = types.BlockResolverRequest;

pub const Patch = input.Patch;
pub const PatchSection = input.PatchSection;
pub const SplitOptions = input.SplitOptions;
pub const parse = input.Patch.parse;
pub const parseSingle = input.Patch.parseSingle;
pub const containsRecognizableHashlineOperations = input.containsRecognizableHashlineOperations;
pub const ParseResult = parser.ParseResult;
pub const parsePatch = parser.parsePatch;
pub const parsePatchStreaming = parser.parsePatchStreaming;
pub const Token = tokenizer.Token;
pub const Tokenizer = tokenizer.Tokenizer;
pub const BlockTarget = tokenizer.BlockTarget;
pub const splitHashlineLines = tokenizer.splitHashlineLines;
pub const parseLid = tokenizer.parseLid;
pub const stripOneLeadingHashlinePrefix = prefixes.stripOneLeadingHashlinePrefix;
pub const stripNewLinePrefixes = prefixes.stripNewLinePrefixes;
pub const stripHashlinePrefixes = prefixes.stripHashlinePrefixes;
pub const hashlineParseText = prefixes.hashlineParseText;

pub const FileHash = format.FileHash;
pub const computeFileHash = format.computeFileHash;
pub const describeAnchorExamples = format.describeAnchorExamples;
pub const formatReplaceHeader = format.formatReplaceHeader;
pub const formatDeleteHeader = format.formatDeleteHeader;
pub const formatInsertHeader = format.formatInsertHeader;
pub const formatHashlineHeader = format.formatHashlineHeader;
pub const formatNumberedLine = format.formatNumberedLine;
pub const formatNumberedLines = format.formatNumberedLines;
pub const file_prefix = format.file_prefix;
pub const file_suffix = format.file_suffix;
pub const payload_replace = format.payload_replace;
pub const replace_keyword = format.replace_keyword;
pub const delete_keyword = format.delete_keyword;
pub const insert_keyword = format.insert_keyword;
pub const insert_before = format.insert_before;
pub const insert_after = format.insert_after;
pub const insert_head = format.insert_head;
pub const insert_tail = format.insert_tail;
pub const replace_block_keyword = format.replace_block_keyword;
pub const delete_block_keyword = format.delete_block_keyword;
pub const insert_after_block_keyword = format.insert_after_block_keyword;
pub const rem_keyword = format.rem_keyword;
pub const move_keyword = format.move_keyword;
pub const header_colon = format.header_colon;
pub const file_hash_separator = format.file_hash_separator;
pub const range_separator = format.range_separator;
pub const line_body_separator = format.line_body_separator;
pub const file_hash_length = format.file_hash_length;
pub const file_hash_examples = format.file_hash_examples;

pub const LineEnding = normalize.LineEnding;
pub const BomResult = normalize.BomResult;
pub const detectLineEnding = normalize.detectLineEnding;
pub const normalizeToLf = normalize.normalizeToLf;
pub const restoreLineEndings = normalize.restoreLineEndings;
pub const stripBom = normalize.stripBom;

pub const applyEdits = apply_engine.applyEdits;
pub const isStructuralCloserLine = apply_engine.isStructuralCloserLine;
pub const ResolveBlockEditsOptions = block.ResolveOptions;
pub const ResolveBlockEditsResult = block.ResolveResult;
pub const UnresolvedBlockMode = block.UnresolvedMode;
pub const resolveBlockEdits = block.resolveBlockEdits;
pub const hasBlockEdit = block.hasBlockEdit;

pub const Fs = fs.Fs;
pub const InMemoryFs = fs.InMemoryFs;
pub const Snapshot = snapshots.Snapshot;
pub const SnapshotStore = snapshots.SnapshotStore;
pub const SnapshotStoreOptions = snapshots.Options;
pub const snapshot_max_paths = snapshots.default_max_paths;
pub const snapshot_max_versions_per_path = snapshots.default_max_versions_per_path;
pub const snapshot_max_total_bytes = snapshots.default_max_total_bytes;

pub const Recovery = recovery.Recovery;
pub const RecoveryArgs = recovery.RecoveryArgs;
pub const RecoveryResult = recovery.RecoveryResult;
pub const MismatchError = mismatch.MismatchError;
pub const MismatchDetails = mismatch.MismatchDetails;
pub const formatFullAnchorRequirement = mismatch.formatFullAnchorRequirement;
pub const parseTag = mismatch.parseTag;
pub const validateLineRef = mismatch.validateLineRef;

pub const Patcher = patcher.Patcher;
pub const PatcherOptions = patcher.Options;
pub const PreparedSection = patcher.PreparedSection;
pub const PatchSectionResult = patcher.SectionResult;
pub const PatcherApplyResult = patcher.ApplyResult;
pub const PatchOperation = patcher.Operation;
pub const seen_line_reveal_cap = patcher.seen_line_reveal_cap;
pub const seen_line_reveal_max_columns = patcher.seen_line_reveal_max_columns;

pub const buildCompactDiffPreview = diff_preview.buildCompactDiffPreview;
pub const DiffPreviewOptions = diff_preview.Options;
pub const buildNumberedDiff = diff.buildNumberedDiff;
pub const createStructuredPatch = diff.createStructuredPatch;
pub const applyStructuredPatch = diff.applyStructuredPatch;
pub const buildLineMap = diff.buildLineMap;
pub const diffArrays = diff.diffArrays;
pub const diffText = diff.diffText;
pub const splitDiffLines = diff.splitLines;
pub const Change = diff.Change;
pub const ChangeKind = diff.ChangeKind;
pub const PatchLine = diff.PatchLine;
pub const PatchLineKind = diff.PatchLineKind;
pub const DiffHunk = diff.Hunk;
pub const LineMap = diff.LineMap;
pub const NumberedDiff = diff.NumberedDiff;
pub const StructuredPatch = diff.StructuredPatch;
pub const streamHashLines = stream.streamHashLines;
pub const HashLineStreamer = stream.Streamer;
pub const StreamOptions = stream.Options;
pub const renderAppliedSection = render.renderAppliedSection;
pub const renderDeletedSection = render.renderDeletedSection;
pub const noChangeDiagnostic = render.noChangeDiagnostic;

test {
    std.testing.refAllDecls(@This());
    _ = @import("apply_corpus_tests.zig");
    _ = @import("block_corpus_tests.zig");
    _ = @import("parser_format_corpus_tests.zig");
    _ = @import("patcher_corpus_tests.zig");
}
