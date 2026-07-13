//! Append-only session trees backed by the upstream JSONL wire format.

const std = @import("std");
const catalog_types = @import("../catalog/types.zig");
const message = @import("../core/message.zig");
const entry_wire = @import("entries.zig");
const paths = @import("paths.zig");

const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;

pub const PERSISTENCE_TRUNCATION_MARKER = "[Session persistence truncated large content]";
pub const MAX_PERSISTED_STRING_UTF16: usize = 500_000;
pub const BLOB_THRESHOLD: usize = 1024;
pub const LIST_PREFIX_BYTES: usize = 4 * 1024;
pub const LIST_TAIL_BYTES: usize = 32 * 1024;

pub const CreateOptions = struct {
    session_dir: ?[]const u8 = null,
    path_options: paths.Options = .{},
};

pub const OpenOptions = struct {
    session_dir: ?[]const u8 = null,
    path_options: paths.Options = .{},
};

pub const SessionInfo = struct {
    path: []u8,
    id: []u8,
    cwd: []u8,
    title: ?[]u8,
    created: []u8,
    modified_ns: i128,
    message_count: usize,
    size: u64,
    first_message: ?[]u8,
    resumable: bool,
    draft_only: bool,

    pub fn deinit(self: *SessionInfo, allocator: Allocator) void {
        allocator.free(self.path);
        allocator.free(self.id);
        allocator.free(self.cwd);
        if (self.title) |value| allocator.free(value);
        allocator.free(self.created);
        if (self.first_message) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const UsageTotals = catalog_types.Usage;

pub const SessionManager = struct {
    gpa: Allocator,
    io: std.Io,
    arena_state: std.heap.ArenaAllocator,
    header: entry_wire.SessionHeader,
    title: ?[]const u8 = null,
    title_source: ?entry_wire.SessionTitleSource = null,
    session_path: ?[]const u8 = null,
    blob_dir: ?[]const u8 = null,
    persistent: bool,
    persisted: bool = false,
    rewrite_required: bool = false,
    disk_error: ?anyerror = null,

    entries: std.ArrayList(entry_wire.SessionEntry) = .empty,
    by_id: std.StringHashMapUnmanaged(usize) = .empty,
    children: std.StringHashMapUnmanaged(std.ArrayList(usize)) = .empty,
    leaf: ?[]const u8 = null,
    usage: UsageTotals = .{},

    writer: ?std.Io.File = null,
    writer_offset: u64 = 0,
    mutex: std.Io.Mutex = .init,
    prng: std.Random.DefaultPrng,

    pub fn create(
        gpa: Allocator,
        io: std.Io,
        cwd: []const u8,
        options: CreateOptions,
    ) !SessionManager {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();
        const timestamp = try nowIsoAlloc(arena, io);
        const id = try uuidV7Alloc(arena, io);
        const canonical_cwd = try std.fs.path.resolve(arena, &.{cwd});
        const session_dir = if (options.session_dir) |value|
            try std.fs.path.resolve(arena, &.{value})
        else
            try paths.defaultSessionDirAlloc(arena, io, canonical_cwd, options.path_options);
        const safe_timestamp = try paths.fileSafeTimestampAlloc(arena, timestamp);
        const filename = try std.fmt.allocPrint(arena, "{s}_{s}.jsonl", .{ safe_timestamp, id });
        const session_path = try std.fs.path.join(arena, &.{ session_dir, filename });
        const blob_dir = try paths.blobsDirAlloc(arena, options.path_options);
        return initValue(gpa, io, arena_state, .{
            .id = id,
            .timestamp = timestamp,
            .cwd = canonical_cwd,
        }, session_path, blob_dir, true);
    }

    pub fn inMemory(gpa: Allocator, io: std.Io, cwd: []const u8) !SessionManager {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();
        const header: entry_wire.SessionHeader = .{
            .id = try uuidV7Alloc(arena, io),
            .timestamp = try nowIsoAlloc(arena, io),
            .cwd = try std.fs.path.resolve(arena, &.{cwd}),
        };
        return initValue(gpa, io, arena_state, header, null, null, false);
    }

    pub fn open(
        gpa: Allocator,
        io: std.Io,
        session_path: []const u8,
        options: OpenOptions,
    ) !SessionManager {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        var arena_transferred = false;
        errdefer if (!arena_transferred) arena_state.deinit();
        const arena = arena_state.allocator();
        const resolved_path = try std.fs.path.resolve(arena, &.{session_path});
        const blob_dir = try paths.blobsDirAlloc(arena, options.path_options);

        const loaded = try loadFile(gpa, io, arena, resolved_path, blob_dir);
        const header: entry_wire.SessionHeader = loaded.header orelse .{
            .id = try uuidV7Alloc(arena, io),
            .timestamp = try nowIsoAlloc(arena, io),
            .cwd = try defaultCwdForPath(arena, resolved_path),
        };
        var result = initValue(gpa, io, arena_state, header, resolved_path, blob_dir, true);
        arena_transferred = true;
        errdefer result.deinit();
        result.title = loaded.title;
        result.title_source = loaded.title_source;
        result.persisted = loaded.file_exists and loaded.header != null;
        result.rewrite_required = loaded.rewrite_required;
        for (loaded.entries) |entry| result.insertLoaded(entry) catch |err| switch (err) {
            error.DuplicateSessionEntryId, error.SessionTreeInconsistent => continue,
            else => return err,
        };
        return result;
    }

    fn initValue(
        gpa: Allocator,
        io: std.Io,
        arena_state: std.heap.ArenaAllocator,
        header: entry_wire.SessionHeader,
        session_path: ?[]const u8,
        blob_dir: ?[]const u8,
        persistent: bool,
    ) SessionManager {
        var seed: u64 = undefined;
        io.random(std.mem.asBytes(&seed));
        return .{
            .gpa = gpa,
            .io = io,
            .arena_state = arena_state,
            .header = header,
            .session_path = session_path,
            .blob_dir = blob_dir,
            .persistent = persistent,
            .prng = std.Random.DefaultPrng.init(seed),
        };
    }

    pub fn deinit(self: *SessionManager) void {
        if (self.writer) |file| file.close(self.io);
        var child_it = self.children.valueIterator();
        while (child_it.next()) |child_list| child_list.deinit(self.gpa);
        self.children.deinit(self.gpa);
        self.by_id.deinit(self.gpa);
        self.entries.deinit(self.gpa);
        self.arena_state.deinit();
        self.* = undefined;
    }

    pub fn path(self: *const SessionManager) ?[]const u8 {
        return self.session_path;
    }

    pub fn getHeader(self: *const SessionManager) entry_wire.SessionHeader {
        var header = self.header;
        header.title = self.title;
        header.titleSource = self.title_source;
        return header;
    }

    pub fn continueRecent(
        gpa: Allocator,
        io: std.Io,
        cwd: []const u8,
        options: OpenOptions,
    ) !SessionManager {
        const found = try list(gpa, io, cwd, options);
        defer deinitSessionInfoSlice(gpa, found);
        for (found) |info| {
            if (info.resumable) return open(gpa, io, info.path, options);
        }
        return create(gpa, io, cwd, .{
            .session_dir = options.session_dir,
            .path_options = options.path_options,
        });
    }

    pub fn list(
        gpa: Allocator,
        io: std.Io,
        cwd: []const u8,
        options: OpenOptions,
    ) ![]SessionInfo {
        const directory = if (options.session_dir) |value|
            try std.fs.path.resolve(gpa, &.{value})
        else
            try paths.defaultSessionDirAlloc(gpa, io, cwd, options.path_options);
        defer gpa.free(directory);
        return listDirectory(gpa, io, directory, false);
    }

    pub fn listAll(gpa: Allocator, io: std.Io, options: OpenOptions) ![]SessionInfo {
        const root = try paths.sessionsRootAlloc(gpa, options.path_options);
        defer gpa.free(root);
        return listDirectory(gpa, io, root, true);
    }

    pub fn getEntries(self: *const SessionManager) []const entry_wire.SessionEntry {
        return self.entries.items;
    }

    pub fn currentLeaf(self: *const SessionManager) ?[]const u8 {
        return self.leaf;
    }

    pub fn usageTotals(self: *const SessionManager) UsageTotals {
        return self.usage;
    }

    pub fn isResumable(self: *const SessionManager) bool {
        return self.entries.items.len != 0 and !self.isDraftOnly();
    }

    pub fn isDraftOnly(self: *const SessionManager) bool {
        if (self.entries.items.len == 0) return false;
        for (self.entries.items) |entry| switch (entry) {
            .model_change, .thinking_level_change, .service_tier_change, .mode_change => {},
            else => return false,
        };
        return true;
    }

    pub fn branch(self: *SessionManager, entry_id: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.checkDiskError() catch |err| return err;
        const index = self.by_id.get(entry_id) orelse return error.SessionEntryNotFound;
        self.leaf = self.entries.items[index].envelope().id;
    }

    pub fn resetLeaf(self: *SessionManager) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.checkDiskError() catch |err| return err;
        self.leaf = null;
    }

    pub fn moveLeafToParent(self: *SessionManager) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.checkDiskError();
        const leaf = self.leaf orelse return;
        const index = self.by_id.get(leaf) orelse return error.SessionTreeInconsistent;
        self.leaf = self.entries.items[index].envelope().parentId;
    }

    pub fn childrenOf(self: *const SessionManager, entry_id: []const u8) []const usize {
        const value = self.children.get(entry_id) orelse return &.{};
        return value.items;
    }

    pub fn activePathAlloc(self: *const SessionManager, allocator: Allocator) ![]entry_wire.SessionEntry {
        var reversed: std.ArrayList(entry_wire.SessionEntry) = .empty;
        defer reversed.deinit(allocator);
        var cursor = self.leaf;
        while (cursor) |id| {
            const index = self.by_id.get(id) orelse return error.SessionTreeInconsistent;
            const entry = self.entries.items[index];
            try reversed.append(allocator, entry);
            cursor = entry.envelope().parentId;
        }
        const output = try allocator.alloc(entry_wire.SessionEntry, reversed.items.len);
        for (reversed.items, 0..) |entry, index| output[output.len - index - 1] = entry;
        return output;
    }

    pub fn appendMessage(self: *SessionManager, value: message.AgentMessage) ![]const u8 {
        const encoded_message = try message.stringifyAlloc(self.gpa, value);
        defer self.gpa.free(encoded_message);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.checkDiskError();
        const id = try self.newEntryIdLocked();
        const timestamp = try nowIsoAlloc(self.arena_state.allocator(), self.io);
        const owned_message = try message.parse(self.arena_state.allocator(), encoded_message);
        return self.appendOwnedLocked(.{ .message = .{
            .id = id,
            .parentId = self.leaf,
            .timestamp = timestamp,
            .message = owned_message,
        } });
    }

    pub fn appendModelChange(self: *SessionManager, model_id: []const u8, role: ?[]const u8) ![]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.checkDiskError();
        const arena = self.arena_state.allocator();
        return self.appendOwnedLocked(.{ .model_change = .{
            .id = try self.newEntryIdLocked(),
            .parentId = self.leaf,
            .timestamp = try nowIsoAlloc(arena, self.io),
            .model = try arena.dupe(u8, model_id),
            .role = if (role) |value| try arena.dupe(u8, value) else null,
        } });
    }

    pub fn appendThinkingChange(self: *SessionManager, level: ?[]const u8) ![]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.checkDiskError();
        const arena = self.arena_state.allocator();
        const field: entry_wire.NullableStringField = if (level) |value|
            .{ .value = try arena.dupe(u8, value) }
        else
            .null_value;
        return self.appendOwnedLocked(.{ .thinking_level_change = .{
            .id = try self.newEntryIdLocked(),
            .parentId = self.leaf,
            .timestamp = try nowIsoAlloc(arena, self.io),
            .thinkingLevel = field,
            .configured = field,
        } });
    }

    pub fn appendModeChange(self: *SessionManager, mode: []const u8) ![]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.checkDiskError();
        const arena = self.arena_state.allocator();
        return self.appendOwnedLocked(.{ .mode_change = .{
            .id = try self.newEntryIdLocked(),
            .parentId = self.leaf,
            .timestamp = try nowIsoAlloc(arena, self.io),
            .mode = try arena.dupe(u8, mode),
        } });
    }

    pub fn appendServiceTierChange(
        self: *SessionManager,
        tiers: ?entry_wire.ServiceTierByFamily,
    ) ![]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.checkDiskError();
        return self.appendOwnedLocked(.{ .service_tier_change = .{
            .id = try self.newEntryIdLocked(),
            .parentId = self.leaf,
            .timestamp = try nowIsoAlloc(self.arena_state.allocator(), self.io),
            .serviceTier = tiers,
        } });
    }

    pub fn setTitle(self: *SessionManager, title: []const u8, source: entry_wire.SessionTitleSource) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.checkDiskError();
        const arena = self.arena_state.allocator();
        self.title = try arena.dupe(u8, title);
        self.title_source = source;
        if (!self.persisted) return;
        if (self.rewrite_required) {
            self.rewriteFull() catch |err| {
                self.latch(err);
                return err;
            };
            return;
        }
        const updated_at = try nowIsoAlloc(self.gpa, self.io);
        defer self.gpa.free(updated_at);
        const slot = try entry_wire.serializeTitleSlotAlloc(
            self.gpa,
            self.title.?,
            self.title_source,
            updated_at,
        );
        defer self.gpa.free(slot);
        self.closeWriter();
        const file = std.Io.Dir.openFileAbsolute(self.io, self.session_path.?, .{ .mode = .read_write }) catch |err| {
            self.latch(err);
            return err;
        };
        defer file.close(self.io);
        file.writePositionalAll(self.io, slot, 0) catch |err| {
            self.latch(err);
            return err;
        };
        file.sync(self.io) catch |err| {
            self.latch(err);
            return err;
        };
    }

    pub fn flush(self: *SessionManager) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.checkDiskError();
        if (self.writer) |file| file.sync(self.io) catch |err| {
            self.latch(err);
            return err;
        };
    }

    pub fn flushSync(self: *SessionManager) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.checkDiskError();
        if (!self.persistent or !self.persistenceGateOpen()) return;
        if (self.persisted and !self.rewrite_required) {
            if (self.writer) |file| file.sync(self.io) catch |err| {
                self.latch(err);
                return err;
            };
            return;
        }
        self.rewriteFull() catch |err| {
            self.latch(err);
            return err;
        };
    }

    fn appendOwnedLocked(self: *SessionManager, value: entry_wire.SessionEntry) ![]const u8 {
        try self.insertLoaded(value);
        if (self.persistent) {
            if (!self.persisted and value == .message and value.message.message == .assistant) {
                self.rewriteFull() catch |err| {
                    self.latch(err);
                    return err;
                };
            } else if (self.persisted) {
                if (self.rewrite_required) {
                    self.rewriteFull() catch |err| {
                        self.latch(err);
                        return err;
                    };
                } else {
                    self.appendRecord(value) catch |err| {
                        self.latch(err);
                        return err;
                    };
                }
            }
        }
        return value.envelope().id;
    }

    fn insertLoaded(self: *SessionManager, value: entry_wire.SessionEntry) !void {
        const envelope = value.envelope();
        if (self.by_id.contains(envelope.id)) return error.DuplicateSessionEntryId;
        if (envelope.parentId) |parent| if (!self.by_id.contains(parent)) return error.SessionTreeInconsistent;
        const index = self.entries.items.len;
        try self.entries.append(self.gpa, value);
        errdefer _ = self.entries.pop();
        try self.by_id.put(self.gpa, envelope.id, index);
        if (envelope.parentId) |parent| {
            const result = try self.children.getOrPut(self.gpa, parent);
            if (!result.found_existing) result.value_ptr.* = .empty;
            try result.value_ptr.append(self.gpa, index);
        }
        self.leaf = envelope.id;
        if (value == .message and value.message.message == .assistant) addUsage(&self.usage, value.message.message.assistant.usage);
    }

    fn newEntryIdLocked(self: *SessionManager) ![]const u8 {
        const arena = self.arena_state.allocator();
        var attempts: usize = 0;
        while (attempts < 100) : (attempts += 1) {
            const candidate = try entry_wire.generateId(self.gpa, self.prng.random());
            defer self.gpa.free(candidate);
            if (!self.by_id.contains(candidate)) return arena.dupe(u8, candidate);
        }
        return error.SessionEntryIdCollision;
    }

    fn persistenceGateOpen(self: *const SessionManager) bool {
        for (self.entries.items) |entry| {
            if (entry == .message and entry.message.message == .assistant) return true;
        }
        return false;
    }

    fn checkDiskError(self: *const SessionManager) !void {
        if (self.disk_error) |err| return err;
    }

    fn latch(self: *SessionManager, err: anyerror) void {
        if (self.disk_error == null) self.disk_error = err;
    }

    fn closeWriter(self: *SessionManager) void {
        if (self.writer) |file| file.close(self.io);
        self.writer = null;
        self.writer_offset = 0;
    }

    fn rewriteFull(self: *SessionManager) !void {
        const target = self.session_path orelse return;
        self.closeWriter();
        var atomic = try std.Io.Dir.cwd().createFileAtomic(self.io, target, .{
            .make_path = true,
            .replace = true,
        });
        defer atomic.deinit(self.io);
        var buffer: [64 * 1024]u8 = undefined;
        var writer = atomic.file.writer(self.io, &buffer);
        const updated_at = try nowIsoAlloc(self.gpa, self.io);
        defer self.gpa.free(updated_at);
        const slot = try entry_wire.serializeTitleSlotAlloc(
            self.gpa,
            self.title orelse "",
            self.title_source,
            updated_at,
        );
        defer self.gpa.free(slot);
        try writer.interface.writeAll(slot);
        const header_line = try entry_wire.stringifyHeaderAlloc(self.gpa, self.header);
        defer self.gpa.free(header_line);
        try writer.interface.writeAll(header_line);
        try writer.interface.writeByte('\n');
        for (self.entries.items) |entry| {
            const line = try self.persistedEntryAlloc(entry);
            defer self.gpa.free(line);
            try writer.interface.writeAll(line);
            try writer.interface.writeByte('\n');
        }
        try writer.flush();
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
        self.persisted = true;
        self.rewrite_required = false;
        try self.openWriter();
    }

    fn openWriter(self: *SessionManager) !void {
        if (self.writer != null) return;
        const file = try std.Io.Dir.createFileAbsolute(self.io, self.session_path.?, .{
            .read = true,
            .truncate = false,
        });
        self.writer_offset = try file.length(self.io);
        self.writer = file;
    }

    fn appendRecord(self: *SessionManager, value: entry_wire.SessionEntry) !void {
        try self.openWriter();
        const line = try self.persistedEntryAlloc(value);
        defer self.gpa.free(line);
        const file = self.writer.?;
        try file.writePositionalAll(self.io, line, self.writer_offset);
        self.writer_offset += line.len;
        try file.writePositionalAll(self.io, "\n", self.writer_offset);
        self.writer_offset += 1;
    }

    fn persistedEntryAlloc(self: *SessionManager, value: entry_wire.SessionEntry) ![]u8 {
        const encoded = try entry_wire.stringifyEntryAlloc(self.gpa, value);
        defer self.gpa.free(encoded);
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var json = try std.json.parseFromSliceLeaky(JsonValue, arena, encoded, .{ .allocate = .alloc_always });
        try prepareJsonForPersistence(self, arena, &json, null);
        return std.json.Stringify.valueAlloc(self.gpa, json, .{});
    }
};

pub fn deinitSessionInfoSlice(allocator: Allocator, values: []SessionInfo) void {
    for (values) |*value| value.deinit(allocator);
    allocator.free(values);
}

const LoadedFile = struct {
    file_exists: bool = false,
    header: ?entry_wire.SessionHeader = null,
    title: ?[]const u8 = null,
    title_source: ?entry_wire.SessionTitleSource = null,
    entries: []const entry_wire.SessionEntry = &.{},
    rewrite_required: bool = false,
};

fn loadFile(
    scratch: Allocator,
    io: std.Io,
    arena: Allocator,
    session_path: []const u8,
    blob_dir: []const u8,
) !LoadedFile {
    var file = std.Io.Dir.openFileAbsolute(io, session_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer file.close(io);
    const length = try file.length(io);
    if (length == 0) return .{ .file_exists = true };
    if (length > std.math.maxInt(usize)) return error.FileTooBig;
    const bytes = try scratch.alloc(u8, @intCast(length));
    defer scratch.free(bytes);
    const read = try file.readPositionalAll(io, bytes, 0);
    const content = bytes[0..read];
    var lines = std.mem.splitScalar(u8, content, '\n');
    const physical_first = lines.next() orelse return .{ .file_exists = true };
    if (physical_first.len == 0) return .{ .file_exists = true };

    var first_value = std.json.parseFromSliceLeaky(JsonValue, arena, physical_first, .{
        .allocate = .alloc_always,
    }) catch return .{ .file_exists = true };
    try resolveBlobRefs(io, arena, &first_value, blob_dir);
    const first_type = objectString(first_value, "type") orelse return .{ .file_exists = true };
    var result: LoadedFile = .{ .file_exists = true };
    var header_value: JsonValue = undefined;
    if (std.mem.eql(u8, first_type, "title")) {
        const slot = entry_wire.parseTitleSlotValue(arena, first_value) catch return .{ .file_exists = true };
        result.title = slot.title;
        result.title_source = slot.source;
        const header_line = lines.next() orelse return result;
        header_value = std.json.parseFromSliceLeaky(JsonValue, arena, header_line, .{
            .allocate = .alloc_always,
        }) catch return result;
    } else if (std.mem.eql(u8, first_type, "session")) {
        header_value = first_value;
        result.rewrite_required = true;
    } else return result;

    const version = objectU32(header_value, "version") orelse 1;
    if (version > entry_wire.CURRENT_SESSION_VERSION) return result;
    if (version < entry_wire.CURRENT_SESSION_VERSION) result.rewrite_required = true;
    try setObjectInteger(arena, &header_value, "version", entry_wire.CURRENT_SESSION_VERSION);
    if (objectString(header_value, "id") == null) {
        try setObjectString(arena, &header_value, "id", try uuidV7Alloc(arena, io));
        result.rewrite_required = true;
    }
    result.header = entry_wire.parseHeaderValue(arena, header_value) catch return .{ .file_exists = true };

    var parsed_entries: std.ArrayList(entry_wire.SessionEntry) = .empty;
    defer parsed_entries.deinit(scratch);
    var previous_id: ?[]const u8 = null;
    var raw_index: usize = 1;
    while (lines.next()) |line| : (raw_index += 1) {
        if (line.len == 0) continue;
        var value = std.json.parseFromSliceLeaky(JsonValue, arena, line, .{
            .allocate = .alloc_always,
        }) catch continue;
        if (version < 2) {
            const id = try uniqueMigrationId(arena, io, parsed_entries.items);
            try setObjectString(arena, &value, "id", id);
            try setObjectNullableString(arena, &value, "parentId", previous_id);
            if (objectString(value, "type")) |kind| if (std.mem.eql(u8, kind, "compaction")) {
                try migrateCompactionIndex(arena, &value, parsed_entries.items, raw_index);
            };
        }
        if (version < 3) try migrateHookRole(arena, &value);
        try resolveBlobRefs(io, arena, &value, blob_dir);
        const parsed = entry_wire.parseEntryValue(arena, value) catch continue;
        try parsed_entries.append(scratch, parsed);
        if (version < 2) previous_id = parsed.envelope().id;
    }
    result.entries = try arena.dupe(entry_wire.SessionEntry, parsed_entries.items);
    return result;
}

fn listDirectory(allocator: Allocator, io: std.Io, directory: []const u8, recursive: bool) ![]SessionInfo {
    var dir = std.Io.Dir.openDirAbsolute(io, directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(SessionInfo, 0),
        else => return err,
    };
    defer dir.close(io);
    var result: std.ArrayList(SessionInfo) = .empty;
    errdefer {
        for (result.items) |*value| value.deinit(allocator);
        result.deinit(allocator);
    }
    if (recursive) {
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".jsonl")) continue;
            const full_path = try std.fs.path.join(allocator, &.{ directory, entry.path });
            defer allocator.free(full_path);
            if (try readSessionInfo(allocator, io, full_path)) |info| {
                errdefer {
                    var mutable_info = info;
                    mutable_info.deinit(allocator);
                }
                try result.append(allocator, info);
            }
        }
    } else {
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
            const full_path = try std.fs.path.join(allocator, &.{ directory, entry.name });
            defer allocator.free(full_path);
            if (try readSessionInfo(allocator, io, full_path)) |info| {
                errdefer {
                    var mutable_info = info;
                    mutable_info.deinit(allocator);
                }
                try result.append(allocator, info);
            }
        }
    }
    std.mem.sort(SessionInfo, result.items, {}, struct {
        fn lessThan(_: void, left: SessionInfo, right: SessionInfo) bool {
            return left.modified_ns > right.modified_ns;
        }
    }.lessThan);
    return result.toOwnedSlice(allocator);
}

fn readSessionInfo(allocator: Allocator, io: std.Io, file_path: []const u8) !?SessionInfo {
    var file = std.Io.Dir.openFileAbsolute(io, file_path, .{}) catch return null;
    defer file.close(io);
    const stat = file.stat(io) catch return null;
    if (stat.size == 0) return null;
    var prefix_buffer: [LIST_PREFIX_BYTES]u8 = undefined;
    const prefix_len: usize = @intCast(@min(stat.size, LIST_PREFIX_BYTES));
    const prefix_read = file.readPositionalAll(io, prefix_buffer[0..prefix_len], 0) catch return null;
    const prefix = prefix_buffer[0..prefix_read];
    var tail_buffer: [LIST_TAIL_BYTES]u8 = undefined;
    const tail_offset: u64 = @max(
        prefix_read,
        if (stat.size > LIST_TAIL_BYTES) stat.size - LIST_TAIL_BYTES else 0,
    );
    const tail_len: usize = @intCast(stat.size - tail_offset);
    const tail_read = file.readPositionalAll(io, tail_buffer[0..tail_len], tail_offset) catch 0;
    const tail = tail_buffer[0..tail_read];

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lines = std.mem.splitScalar(u8, prefix, '\n');
    const first_line = lines.next() orelse return null;
    const first_value = std.json.parseFromSliceLeaky(JsonValue, arena, first_line, .{
        .allocate = .alloc_always,
    }) catch return null;
    const first_type = objectString(first_value, "type") orelse return null;
    var slot_title: ?[]const u8 = null;
    var header_value: JsonValue = undefined;
    var header_end: u64 = @intCast(first_line.len + 1);
    if (std.mem.eql(u8, first_type, "title")) {
        const slot = entry_wire.parseTitleSlotValue(arena, first_value) catch return null;
        slot_title = slot.title;
        const header_line = lines.next() orelse return null;
        header_end += @intCast(header_line.len + 1);
        header_value = std.json.parseFromSliceLeaky(JsonValue, arena, header_line, .{
            .allocate = .alloc_always,
        }) catch return null;
    } else if (std.mem.eql(u8, first_type, "session")) {
        header_value = first_value;
    } else return null;
    const header = entry_wire.parseHeaderValue(arena, header_value) catch return null;

    var scan = ListingScan{};
    scanListingWindow(arena, prefix, &scan);
    if (tail.len != 0) scanListingWindow(arena, tail, &scan);
    const resumable = scan.has_conversation or
        (scan.entry_count == 0 and stat.size > header_end);
    const draft_only = scan.entry_count != 0 and !scan.has_conversation;
    const owned_path = try allocator.dupe(u8, file_path);
    errdefer allocator.free(owned_path);
    const id = try allocator.dupe(u8, header.id);
    errdefer allocator.free(id);
    const cwd = try allocator.dupe(u8, header.cwd);
    errdefer allocator.free(cwd);
    const title: ?[]u8 = if (slot_title) |value|
        if (value.len == 0) null else try allocator.dupe(u8, value)
    else if (header.title) |value|
        try allocator.dupe(u8, value)
    else
        null;
    errdefer if (title) |value| allocator.free(value);
    const created = try allocator.dupe(u8, header.timestamp);
    errdefer allocator.free(created);
    const first_message: ?[]u8 = if (scan.first_message) |value|
        try allocator.dupe(u8, value)
    else
        null;
    errdefer if (first_message) |value| allocator.free(value);
    return .{
        .path = owned_path,
        .id = id,
        .cwd = cwd,
        .title = title,
        .created = created,
        .modified_ns = stat.mtime.nanoseconds,
        .message_count = scan.message_count,
        .size = stat.size,
        .first_message = first_message,
        .resumable = resumable,
        .draft_only = draft_only,
    };
}

const ListingScan = struct {
    entry_count: usize = 0,
    message_count: usize = 0,
    has_conversation: bool = false,
    first_message: ?[]const u8 = null,
};

fn scanListingWindow(arena: Allocator, bytes: []const u8, scan: *ListingScan) void {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const value = std.json.parseFromSliceLeaky(JsonValue, arena, line, .{
            .allocate = .alloc_always,
        }) catch continue;
        const kind = objectString(value, "type") orelse continue;
        if (std.mem.eql(u8, kind, "title") or std.mem.eql(u8, kind, "session")) continue;
        scan.entry_count += 1;
        const selector = std.mem.eql(u8, kind, "model_change") or
            std.mem.eql(u8, kind, "thinking_level_change") or
            std.mem.eql(u8, kind, "service_tier_change") or
            std.mem.eql(u8, kind, "mode_change");
        if (!selector) scan.has_conversation = true;
        if (!std.mem.eql(u8, kind, "message")) continue;
        scan.message_count += 1;
        if (scan.first_message != null) continue;
        const parsed = entry_wire.parseEntryValue(arena, value) catch continue;
        if (parsed != .message) continue;
        scan.first_message = messageText(parsed.message.message);
    }
}

fn messageText(value: message.AgentMessage) ?[]const u8 {
    const content: message.TextImageContent = switch (value) {
        .user => |item| item.content,
        .developer => |item| item.content,
        else => return null,
    };
    return switch (content) {
        .string => |text| if (text.len == 0) null else text,
        .blocks => |blocks| blk: {
            for (blocks) |block| switch (block) {
                .text => |text| if (text.text.len != 0) break :blk text.text,
                else => {},
            };
            break :blk null;
        },
    };
}

fn prepareJsonForPersistence(
    manager: *SessionManager,
    arena: Allocator,
    value: *JsonValue,
    field_name: ?[]const u8,
) !void {
    switch (value.*) {
        .string => |text| {
            if (isSignedField(field_name)) return;
            if (utf16Units(text) <= MAX_PERSISTED_STRING_UTF16) return;
            value.* = .{ .string = try truncateUtf16Alloc(arena, text) };
        },
        .array => |*array| for (array.items) |*item| try prepareJsonForPersistence(manager, arena, item, field_name),
        .object => |*object| {
            if (isProtectedWireBlock(object.*)) return;
            const is_image = (if (object.get("type")) |kind|
                kind == .string and std.mem.eql(u8, kind.string, "image")
            else
                false) or (field_name != null and std.mem.eql(u8, field_name.?, "images") and
                hasImageMimeType(object.*));
            if (is_image) if (object.getPtr("data")) |data| if (data.* == .string and data.string.len >= BLOB_THRESHOLD) {
                if (manager.blob_dir) |blob_dir| {
                    data.* = .{ .string = try writeBlobRef(manager, arena, blob_dir, data.string) };
                }
            };
            var iterator = object.iterator();
            while (iterator.next()) |item| {
                try prepareJsonForPersistence(manager, arena, item.value_ptr, item.key_ptr.*);
            }
        },
        else => {},
    }
}

fn isProtectedWireBlock(object: std.json.ObjectMap) bool {
    const block_type = object.get("type") orelse return false;
    if (block_type != .string) return false;
    if (std.mem.eql(u8, block_type.string, "thinking")) return hasNonemptyString(object, "thinkingSignature");
    if (std.mem.eql(u8, block_type.string, "text")) return hasNonemptyString(object, "textSignature");
    if (std.mem.eql(u8, block_type.string, "toolCall")) return hasNonemptyString(object, "thoughtSignature");
    if (std.mem.eql(u8, block_type.string, "redactedThinking")) return hasNonemptyString(object, "data");
    if (std.mem.eql(u8, block_type.string, "reasoning")) return hasNonemptyString(object, "encrypted_content");
    return false;
}

fn hasNonemptyString(object: std.json.ObjectMap, name: []const u8) bool {
    const value = object.get(name) orelse return false;
    return value == .string and value.string.len != 0;
}

fn hasImageMimeType(object: std.json.ObjectMap) bool {
    const value = object.get("mimeType") orelse return false;
    return value == .string and std.ascii.startsWithIgnoreCase(value.string, "image/");
}

fn writeBlobRef(manager: *SessionManager, arena: Allocator, blob_dir: []const u8, encoded: []const u8) ![]const u8 {
    const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return encoded;
    const decoded = try arena.alloc(u8, decoded_size);
    std.base64.standard.Decoder.decode(decoded, encoded) catch return encoded;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(decoded, &digest, .{});
    const hash = try std.fmt.allocPrint(arena, "{x}", .{digest});
    const blob_path = try std.fs.path.join(arena, &.{ blob_dir, hash });
    std.Io.Dir.accessAbsolute(manager.io, blob_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            var atomic = try std.Io.Dir.cwd().createFileAtomic(manager.io, blob_path, .{
                .make_path = true,
                .replace = false,
            });
            defer atomic.deinit(manager.io);
            try atomic.file.writePositionalAll(manager.io, decoded, 0);
            try atomic.file.sync(manager.io);
            atomic.link(manager.io) catch |link_err| switch (link_err) {
                error.PathAlreadyExists => {},
                else => return link_err,
            };
        },
        else => return err,
    };
    return std.fmt.allocPrint(arena, "blob:sha256:{s}", .{hash});
}

fn resolveBlobRefs(io: std.Io, arena: Allocator, value: *JsonValue, blob_dir: []const u8) !void {
    switch (value.*) {
        .string => |text| {
            const prefix = "blob:sha256:";
            if (!std.mem.startsWith(u8, text, prefix)) return;
            const hash = text[prefix.len..];
            if (hash.len != 64) return;
            const blob_path = try std.fs.path.join(arena, &.{ blob_dir, hash });
            var file = std.Io.Dir.openFileAbsolute(io, blob_path, .{}) catch |err| switch (err) {
                error.FileNotFound => return,
                else => return err,
            };
            defer file.close(io);
            const length = try file.length(io);
            if (length > std.math.maxInt(usize)) return error.FileTooBig;
            const raw = try arena.alloc(u8, @intCast(length));
            const read = try file.readPositionalAll(io, raw, 0);
            const encoded = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(read));
            _ = std.base64.standard.Encoder.encode(encoded, raw[0..read]);
            value.* = .{ .string = encoded };
        },
        .array => |*array| for (array.items) |*item| try resolveBlobRefs(io, arena, item, blob_dir),
        .object => |*object| {
            var iterator = object.iterator();
            while (iterator.next()) |item| try resolveBlobRefs(io, arena, item.value_ptr, blob_dir);
        },
        else => {},
    }
}

fn truncateUtf16Alloc(arena: Allocator, text: []const u8) ![]const u8 {
    const suffix = "\n\n" ++ PERSISTENCE_TRUNCATION_MARKER;
    const limit = MAX_PERSISTED_STRING_UTF16 - utf16Units(suffix);
    var index: usize = 0;
    var units: usize = 0;
    while (index < text.len) {
        const sequence_length = try std.unicode.utf8ByteSequenceLength(text[index]);
        const scalar = try std.unicode.utf8Decode(text[index..][0..sequence_length]);
        const scalar_units: usize = if (scalar > 0xffff) 2 else 1;
        if (units + scalar_units > limit) break;
        units += scalar_units;
        index += sequence_length;
    }
    return std.mem.concat(arena, u8, &.{ text[0..index], suffix });
}

fn utf16Units(text: []const u8) usize {
    var index: usize = 0;
    var units: usize = 0;
    while (index < text.len) {
        const sequence_length = std.unicode.utf8ByteSequenceLength(text[index]) catch return text.len;
        const scalar = std.unicode.utf8Decode(text[index..][0..sequence_length]) catch return text.len;
        units += if (scalar > 0xffff) 2 else 1;
        index += sequence_length;
    }
    return units;
}

fn isSignedField(name: ?[]const u8) bool {
    const value = name orelse return false;
    return std.mem.eql(u8, value, "signature") or
        std.mem.eql(u8, value, "textSignature") or
        std.mem.eql(u8, value, "thinkingSignature") or
        std.mem.eql(u8, value, "thoughtSignature") or
        std.mem.eql(u8, value, "rawBlock");
}

fn addUsage(total: *UsageTotals, value: UsageTotals) void {
    total.input += value.input;
    total.output += value.output;
    total.cache_read += value.cache_read;
    total.cache_write += value.cache_write;
    if (value.total_tokens) |amount| total.total_tokens = (total.total_tokens orelse 0) + amount;
    if (value.reasoning_tokens) |amount| total.reasoning_tokens = (total.reasoning_tokens orelse 0) + amount;
    if (value.premium_requests) |amount| total.premium_requests = (total.premium_requests orelse 0) + amount;
    if (value.orchestration) |usage| {
        if (total.orchestration == null) total.orchestration = .{};
        total.orchestration.?.input += usage.input;
        total.orchestration.?.cache_read += usage.cache_read;
        total.orchestration.?.output += usage.output;
    }
    total.cost.input += value.cost.input;
    total.cost.output += value.cost.output;
    total.cost.cache_read += value.cost.cache_read;
    total.cost.cache_write += value.cost.cache_write;
    total.cost.total += value.cost.total;
}

fn nowIsoAlloc(allocator: Allocator, io: std.Io) ![]u8 {
    const milliseconds = std.Io.Timestamp.now(io, .real).toMilliseconds();
    if (milliseconds < 0) return error.TimestampBeforeUnixEpoch;
    const seconds: u64 = @intCast(@divFloor(milliseconds, 1000));
    const millis: u16 = @intCast(@mod(milliseconds, 1000));
    const epoch = std.time.epoch.EpochSeconds{ .secs = seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
            millis,
        },
    );
}

fn uuidV7Alloc(allocator: Allocator, io: std.Io) ![]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    const now = std.Io.Timestamp.now(io, .real).toMilliseconds();
    if (now < 0) return error.TimestampBeforeUnixEpoch;
    const timestamp: u64 = @intCast(now);
    bytes[0] = @truncate(timestamp >> 40);
    bytes[1] = @truncate(timestamp >> 32);
    bytes[2] = @truncate(timestamp >> 24);
    bytes[3] = @truncate(timestamp >> 16);
    bytes[4] = @truncate(timestamp >> 8);
    bytes[5] = @truncate(timestamp);
    bytes[6] = (bytes[6] & 0x0f) | 0x70;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = "0123456789abcdef";
    const output = try allocator.alloc(u8, 36);
    var out_index: usize = 0;
    for (bytes, 0..) |byte, index| {
        if (index == 4 or index == 6 or index == 8 or index == 10) {
            output[out_index] = '-';
            out_index += 1;
        }
        output[out_index] = hex[byte >> 4];
        output[out_index + 1] = hex[byte & 0x0f];
        out_index += 2;
    }
    return output;
}

fn defaultCwdForPath(arena: Allocator, session_path: []const u8) ![]const u8 {
    _ = session_path;
    return std.fs.path.resolve(arena, &.{"."});
}

fn objectString(value: JsonValue, name: []const u8) ?[]const u8 {
    const object = switch (value) {
        .object => |item| item,
        else => return null,
    };
    const field = object.get(name) orelse return null;
    return switch (field) {
        .string => |text| text,
        else => null,
    };
}

fn objectU32(value: JsonValue, name: []const u8) ?u32 {
    const object = switch (value) {
        .object => |item| item,
        else => return null,
    };
    const field = object.get(name) orelse return null;
    return switch (field) {
        .integer => |number| if (number >= 0 and number <= std.math.maxInt(u32)) @intCast(number) else null,
        else => null,
    };
}

fn setObjectInteger(arena: Allocator, value: *JsonValue, name: []const u8, number: u64) !void {
    const object = switch (value.*) {
        .object => |*item| item,
        else => return error.InvalidSessionEntry,
    };
    try object.put(arena, try arena.dupe(u8, name), .{ .integer = @intCast(number) });
}

fn setObjectString(arena: Allocator, value: *JsonValue, name: []const u8, text: []const u8) !void {
    const object = switch (value.*) {
        .object => |*item| item,
        else => return error.InvalidSessionEntry,
    };
    try object.put(arena, try arena.dupe(u8, name), .{ .string = try arena.dupe(u8, text) });
}

fn setObjectNullableString(arena: Allocator, value: *JsonValue, name: []const u8, text: ?[]const u8) !void {
    const object = switch (value.*) {
        .object => |*item| item,
        else => return error.InvalidSessionEntry,
    };
    try object.put(arena, try arena.dupe(u8, name), if (text) |item|
        .{ .string = try arena.dupe(u8, item) }
    else
        .null);
}

fn migrateHookRole(arena: Allocator, value: *JsonValue) !void {
    const object = switch (value.*) {
        .object => |*item| item,
        else => return,
    };
    const message_value = object.getPtr("message") orelse return;
    const message_object = switch (message_value.*) {
        .object => |*item| item,
        else => return,
    };
    const role = message_object.get("role") orelse return;
    if (role != .string or !std.mem.eql(u8, role.string, "hookMessage")) return;
    try message_object.put(arena, try arena.dupe(u8, "role"), .{ .string = try arena.dupe(u8, "custom") });
}

fn migrateCompactionIndex(
    arena: Allocator,
    value: *JsonValue,
    parsed: []const entry_wire.SessionEntry,
    raw_index: usize,
) !void {
    _ = raw_index;
    const object = switch (value.*) {
        .object => |*item| item,
        else => return,
    };
    const index_value = object.get("firstKeptEntryIndex") orelse return;
    if (index_value != .integer or index_value.integer < 1) {
        _ = object.orderedRemove("firstKeptEntryIndex");
        return;
    }
    const index: usize = @intCast(index_value.integer - 1);
    if (index < parsed.len) try object.put(
        arena,
        try arena.dupe(u8, "firstKeptEntryId"),
        .{ .string = try arena.dupe(u8, parsed[index].envelope().id) },
    );
    _ = object.orderedRemove("firstKeptEntryIndex");
}

fn uniqueMigrationId(
    arena: Allocator,
    io: std.Io,
    parsed: []const entry_wire.SessionEntry,
) ![]const u8 {
    var seed: u64 = undefined;
    io.random(std.mem.asBytes(&seed));
    var prng = std.Random.DefaultPrng.init(seed);
    while (true) {
        const id = try entry_wire.generateId(arena, prng.random());
        var found = false;
        for (parsed) |entry| if (std.mem.eql(u8, entry.envelope().id, id)) {
            found = true;
            break;
        };
        if (!found) return id;
    }
}

test "session UUIDv7 has canonical version and variant" {
    const value = try uuidV7Alloc(std.testing.allocator, std.testing.io);
    defer std.testing.allocator.free(value);
    try std.testing.expectEqual(@as(usize, 36), value.len);
    try std.testing.expectEqual(@as(u8, '7'), value[14]);
    try std.testing.expect(std.mem.indexOfScalar(u8, "89ab", value[19]) != null);
}

test "session tree branch and reset move only the mutable leaf" {
    const allocator = std.testing.allocator;
    var manager = try SessionManager.inMemory(allocator, std.testing.io, ".");
    defer manager.deinit();
    const root_id = try manager.appendMessage(.{ .user = .{
        .content = .{ .string = "root" },
        .timestamp = 1,
    } });
    const assistant_id = try manager.appendMessage(testAssistant("first branch", 2));
    try manager.branch(root_id);
    const selector_id = try manager.appendModelChange("anthropic/claude-haiku", null);
    try std.testing.expectEqual(@as(usize, 2), manager.childrenOf(root_id).len);
    try std.testing.expectEqualStrings(root_id, manager.getEntries()[manager.childrenOf(root_id)[0]].envelope().parentId.?);
    try std.testing.expectEqualStrings(root_id, manager.getEntries()[manager.childrenOf(root_id)[1]].envelope().parentId.?);
    try std.testing.expectEqualStrings(selector_id, manager.currentLeaf().?);
    try manager.resetLeaf();
    const new_root = try manager.appendModeChange("fresh");
    try std.testing.expect(manager.getEntries()[manager.getEntries().len - 1].envelope().parentId == null);
    try std.testing.expectEqualStrings(new_root, manager.currentLeaf().?);
    try std.testing.expect(!std.mem.eql(u8, assistant_id, manager.currentLeaf().?));
}

test "session manager defers user-only files and round trips after an assistant" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_length = try tmp.dir.realPath(io, &path_buffer);
    const root = path_buffer[0..path_length];

    var manager = try SessionManager.create(allocator, io, root, .{
        .path_options = .{ .agent_dir = root, .home = root, .temp_dir = "/tmp" },
    });
    const file_path = try allocator.dupe(u8, manager.path().?);
    defer allocator.free(file_path);
    _ = try manager.appendMessage(.{ .user = .{
        .content = .{ .string = "hello" },
        .timestamp = 1,
    } });
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(io, file_path, .{}),
    );
    _ = try manager.appendMessage(.{ .assistant = .{
        .content = &.{.{ .text = .{ .text = "hi" } }},
        .api = "anthropic-messages",
        .provider = "anthropic",
        .model = "claude-haiku",
        .usage = .{ .input = 2, .output = 3, .cost = .{ .total = 0.01 } },
        .stop_reason = .stop,
        .timestamp = 2,
    } });
    try manager.flush();
    manager.deinit();

    var reopened = try SessionManager.open(allocator, io, file_path, .{
        .path_options = .{ .agent_dir = root, .home = root, .temp_dir = "/tmp" },
    });
    defer reopened.deinit();
    try std.testing.expectEqual(@as(usize, 2), reopened.getEntries().len);
    try std.testing.expectEqual(@as(u64, 2), reopened.usageTotals().input);
    try std.testing.expectEqual(@as(u64, 3), reopened.usageTotals().output);
    try std.testing.expectEqualStrings(reopened.getEntries()[1].envelope().id, reopened.currentLeaf().?);

    const listed = try SessionManager.listAll(allocator, io, .{
        .path_options = .{ .agent_dir = root, .home = root, .temp_dir = "/tmp" },
    });
    defer deinitSessionInfoSlice(allocator, listed);
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expect(listed[0].resumable);
    try std.testing.expectEqual(@as(usize, 2), listed[0].message_count);

    var recent = try SessionManager.continueRecent(allocator, io, root, .{
        .path_options = .{ .agent_dir = root, .home = root, .temp_dir = "/tmp" },
    });
    defer recent.deinit();
    try std.testing.expectEqualStrings(file_path, recent.path().?);
}

test "session listing marks selector-only files as draft-only and not resumable" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    const directory = try std.fs.path.join(allocator, &.{ root, "sessions", "-draft" });
    defer allocator.free(directory);
    try std.Io.Dir.cwd().createDirPath(io, directory);
    const file_path = try std.fs.path.join(allocator, &.{ directory, "draft.jsonl" });
    defer allocator.free(file_path);
    const slot = try entry_wire.serializeTitleSlotAlloc(
        allocator,
        "draft",
        .user,
        "2026-01-01T00:00:00.000Z",
    );
    defer allocator.free(slot);
    const header = try entry_wire.stringifyHeaderAlloc(allocator, .{
        .id = "draft-session",
        .timestamp = "2026-01-01T00:00:00.000Z",
        .cwd = "/work",
    });
    defer allocator.free(header);
    const selector = try entry_wire.stringifyEntryAlloc(allocator, .{ .model_change = .{
        .id = "12345678",
        .parentId = null,
        .timestamp = "2026-01-01T00:00:01.000Z",
        .model = "anthropic/claude-haiku",
    } });
    defer allocator.free(selector);
    const contents = try std.mem.concat(allocator, u8, &.{ slot, header, "\n", selector, "\n" });
    defer allocator.free(contents);
    try writeFileAbsolute(io, file_path, contents);

    const listed = try SessionManager.listAll(allocator, io, .{
        .path_options = .{ .agent_dir = root, .home = root, .temp_dir = "/tmp" },
    });
    defer deinitSessionInfoSlice(allocator, listed);
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expect(listed[0].draft_only);
    try std.testing.expect(!listed[0].resumable);
    try std.testing.expectEqualStrings("draft", listed[0].title.?);
}

test "bounded session listing resumes a large final message line when no entry fits a scan window" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    const path_options: paths.Options = .{
        .agent_dir = root,
        .home = root,
        .temp_dir = "/tmp",
    };
    const directory = try paths.defaultSessionDirAlloc(allocator, io, root, path_options);
    defer allocator.free(directory);
    try std.Io.Dir.cwd().createDirPath(io, directory);
    const file_path = try std.fs.path.join(allocator, &.{ directory, "large-message.jsonl" });
    defer allocator.free(file_path);

    const slot = try entry_wire.serializeTitleSlotAlloc(
        allocator,
        "large message",
        .user,
        "2026-01-02T00:00:00.000Z",
    );
    defer allocator.free(slot);
    const header = try entry_wire.stringifyHeaderAlloc(allocator, .{
        .id = "large-session",
        .timestamp = "2026-01-02T00:00:00.000Z",
        .cwd = root,
    });
    defer allocator.free(header);
    const long_text = try allocator.alloc(u8, LIST_PREFIX_BYTES + LIST_TAIL_BYTES + 8 * 1024);
    defer allocator.free(long_text);
    @memset(long_text, 'x');
    const entry = try entry_wire.stringifyEntryAlloc(allocator, .{ .message = .{
        .id = "12345678",
        .parentId = null,
        .timestamp = "2026-01-02T00:00:01.000Z",
        .message = .{ .user = .{ .content = .{ .string = long_text }, .timestamp = 1 } },
    } });
    defer allocator.free(entry);
    try std.testing.expect(entry.len > LIST_TAIL_BYTES);
    const contents = try std.mem.concat(allocator, u8, &.{ slot, header, "\n", entry, "\n" });
    defer allocator.free(contents);
    try std.testing.expect(contents.len > LIST_PREFIX_BYTES + LIST_TAIL_BYTES);
    try writeFileAbsolute(io, file_path, contents);

    const listed = try SessionManager.list(allocator, io, root, .{ .path_options = path_options });
    defer deinitSessionInfoSlice(allocator, listed);
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expect(listed[0].resumable);
    try std.testing.expect(!listed[0].draft_only);
    try std.testing.expectEqual(@as(usize, 0), listed[0].message_count);
    try std.testing.expectEqualStrings("large-session", listed[0].id);
    try std.testing.expectEqualStrings(root, listed[0].cwd);
    try std.testing.expectEqualStrings("large message", listed[0].title.?);
    try std.testing.expectEqualStrings("2026-01-02T00:00:00.000Z", listed[0].created);

    var recent = try SessionManager.continueRecent(allocator, io, root, .{ .path_options = path_options });
    defer recent.deinit();
    try std.testing.expectEqualStrings(file_path, recent.path().?);
    try std.testing.expectEqualStrings("large-session", recent.header.id);
    try std.testing.expectEqual(@as(usize, 1), recent.getEntries().len);
    try std.testing.expectEqualStrings("12345678", recent.currentLeaf().?);
}

test "bounded session listing resumes one assistant entry split across contiguous scan windows" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    const path_options: paths.Options = .{
        .agent_dir = root,
        .home = root,
        .temp_dir = "/tmp",
    };
    const assistant_text = try allocator.alloc(u8, 8 * 1024);
    defer allocator.free(assistant_text);
    @memset(assistant_text, 'm');
    const assistant_blocks = [_]message.AssistantBlock{.{ .text = .{ .text = assistant_text } }};

    var manager = try SessionManager.create(allocator, io, root, .{ .path_options = path_options });
    const file_path = try allocator.dupe(u8, manager.path().?);
    defer allocator.free(file_path);
    _ = try manager.appendMessage(.{ .assistant = .{
        .content = &assistant_blocks,
        .api = "anthropic-messages",
        .provider = "anthropic",
        .model = "claude-haiku",
        .usage = .{ .input = 2, .output = 3, .cost = .{ .total = 0.01 } },
        .stop_reason = .stop,
        .timestamp = 1,
    } });
    try manager.flush();
    manager.deinit();

    const stat = try std.Io.Dir.cwd().statFile(io, file_path, .{});
    try std.testing.expect(stat.size > LIST_PREFIX_BYTES);
    try std.testing.expect(stat.size < LIST_PREFIX_BYTES + LIST_TAIL_BYTES);
    const listed = try SessionManager.list(allocator, io, root, .{ .path_options = path_options });
    defer deinitSessionInfoSlice(allocator, listed);
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expect(listed[0].resumable);
    try std.testing.expect(!listed[0].draft_only);
    try std.testing.expectEqual(@as(usize, 0), listed[0].message_count);

    var recent = try SessionManager.continueRecent(allocator, io, root, .{ .path_options = path_options });
    defer recent.deinit();
    try std.testing.expectEqualStrings(file_path, recent.path().?);
    try std.testing.expectEqual(@as(usize, 1), recent.getEntries().len);
}

test "session JSONL validator and title rewrite preserve the immutable tail" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    var manager = try SessionManager.create(allocator, io, root, .{
        .path_options = .{ .agent_dir = root, .home = root, .temp_dir = "/tmp" },
    });
    defer manager.deinit();
    _ = try manager.appendMessage(.{ .user = .{ .content = .{ .string = "validate" }, .timestamp = 1 } });
    _ = try manager.appendMessage(testAssistant("validated", 2));
    try manager.flush();

    const before = try readFileAlloc(allocator, io, manager.path().?);
    defer allocator.free(before);
    try std.testing.expect(before.len > entry_wire.SESSION_TITLE_SLOT_BYTES);
    try std.testing.expectEqual(@as(u8, '\n'), before[entry_wire.SESSION_TITLE_SLOT_BYTES - 1]);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = try entry_wire.parseTitleSlot(arena, before[0 .. entry_wire.SESSION_TITLE_SLOT_BYTES - 1]);
    var lines = std.mem.splitScalar(u8, before[entry_wire.SESSION_TITLE_SLOT_BYTES..], '\n');
    const header = try entry_wire.parseHeader(arena, lines.next().?);
    try std.testing.expectEqual(@as(?u32, 3), header.version);
    var entry_count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const entry = try entry_wire.parseEntry(arena, line);
        const envelope = entry.envelope();
        try std.testing.expectEqual(@as(usize, 8), envelope.id.len);
        try std.testing.expect(envelope.timestamp.len != 0);
        entry_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), entry_count);

    try manager.setTitle("renamed in place", .user);
    const after = try readFileAlloc(allocator, io, manager.path().?);
    defer allocator.free(after);
    try std.testing.expectEqual(before.len, after.len);
    try std.testing.expect(!std.mem.eql(
        u8,
        before[0..entry_wire.SESSION_TITLE_SLOT_BYTES],
        after[0..entry_wire.SESSION_TITLE_SLOT_BYTES],
    ));
    try std.testing.expectEqualSlices(
        u8,
        before[entry_wire.SESSION_TITLE_SLOT_BYTES..],
        after[entry_wire.SESSION_TITLE_SLOT_BYTES..],
    );
    const title_slot = try entry_wire.parseTitleSlot(
        arena,
        after[0 .. entry_wire.SESSION_TITLE_SLOT_BYTES - 1],
    );
    try std.testing.expectEqualStrings("renamed in place", title_slot.title);
}

test "setTitle atomically adds a title slot to a slot-less v3 session" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    const file_path = try std.fs.path.join(allocator, &.{ root, "slotless-v3.jsonl" });
    defer allocator.free(file_path);
    const path_options: paths.Options = .{
        .agent_dir = root,
        .home = root,
        .temp_dir = "/tmp",
    };

    const header_line = try entry_wire.stringifyHeaderAlloc(allocator, .{
        .id = "slotless-v3",
        .timestamp = "2026-01-03T00:00:00.000Z",
        .cwd = root,
    });
    defer allocator.free(header_line);
    const user_line = try entry_wire.stringifyEntryAlloc(allocator, .{ .message = .{
        .id = "11111111",
        .parentId = null,
        .timestamp = "2026-01-03T00:00:01.000Z",
        .message = .{ .user = .{ .content = .{ .string = "hello" }, .timestamp = 1 } },
    } });
    defer allocator.free(user_line);
    const assistant_line = try entry_wire.stringifyEntryAlloc(allocator, .{ .message = .{
        .id = "22222222",
        .parentId = "11111111",
        .timestamp = "2026-01-03T00:00:02.000Z",
        .message = testAssistant("reply", 2),
    } });
    defer allocator.free(assistant_line);
    const fixture = try std.mem.concat(allocator, u8, &.{
        header_line,
        "\n",
        user_line,
        "\n",
        assistant_line,
        "\n",
    });
    defer allocator.free(fixture);
    try writeFileAbsolute(io, file_path, fixture);

    var manager = try SessionManager.open(allocator, io, file_path, .{ .path_options = path_options });
    try std.testing.expect(manager.rewrite_required);
    try std.testing.expectEqualStrings("slotless-v3", manager.header.id);
    try std.testing.expectEqual(@as(usize, 2), manager.getEntries().len);
    try std.testing.expectEqualStrings("22222222", manager.currentLeaf().?);
    try manager.setTitle("preserved session", .user);
    try std.testing.expect(!manager.rewrite_required);
    manager.deinit();

    const rewritten = try readFileAlloc(allocator, io, file_path);
    defer allocator.free(rewritten);
    try std.testing.expect(rewritten.len > entry_wire.SESSION_TITLE_SLOT_BYTES);
    try std.testing.expectEqual(@as(u8, '\n'), rewritten[entry_wire.SESSION_TITLE_SLOT_BYTES - 1]);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const slot = try entry_wire.parseTitleSlot(
        arena,
        rewritten[0 .. entry_wire.SESSION_TITLE_SLOT_BYTES - 1],
    );
    try std.testing.expectEqualStrings("preserved session", slot.title);
    var lines = std.mem.splitScalar(u8, rewritten[entry_wire.SESSION_TITLE_SLOT_BYTES..], '\n');
    const header = try entry_wire.parseHeader(arena, lines.next().?);
    try std.testing.expectEqualStrings("slotless-v3", header.id);

    var reopened = try SessionManager.open(allocator, io, file_path, .{ .path_options = path_options });
    defer reopened.deinit();
    try std.testing.expectEqualStrings("slotless-v3", reopened.header.id);
    try std.testing.expectEqualStrings("preserved session", reopened.title.?);
    try std.testing.expectEqual(@as(usize, 2), reopened.getEntries().len);
    try std.testing.expectEqualStrings("11111111", reopened.getEntries()[1].envelope().parentId.?);
    try std.testing.expectEqualStrings("22222222", reopened.currentLeaf().?);
}

test "a synthesized header id is persisted by the next title rewrite" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    const file_path = try std.fs.path.join(allocator, &.{ root, "missing-id.jsonl" });
    defer allocator.free(file_path);
    const path_options: paths.Options = .{
        .agent_dir = root,
        .home = root,
        .temp_dir = "/tmp",
    };
    const slot = try entry_wire.serializeTitleSlotAlloc(
        allocator,
        "before",
        .user,
        "2026-01-04T00:00:00.000Z",
    );
    defer allocator.free(slot);
    const header = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"session\",\"version\":3,\"timestamp\":\"2026-01-04T00:00:00.000Z\",\"cwd\":\"{s}\"}}\n",
        .{root},
    );
    defer allocator.free(header);
    const fixture = try std.mem.concat(allocator, u8, &.{ slot, header });
    defer allocator.free(fixture);
    try writeFileAbsolute(io, file_path, fixture);

    var manager = try SessionManager.open(allocator, io, file_path, .{ .path_options = path_options });
    try std.testing.expect(manager.rewrite_required);
    const synthesized_id = try allocator.dupe(u8, manager.header.id);
    defer allocator.free(synthesized_id);
    try manager.setTitle("after", .user);
    try std.testing.expect(!manager.rewrite_required);
    manager.deinit();

    var reopened = try SessionManager.open(allocator, io, file_path, .{ .path_options = path_options });
    defer reopened.deinit();
    try std.testing.expectEqualStrings(synthesized_id, reopened.header.id);
    try std.testing.expectEqualStrings("after", reopened.title.?);
    try std.testing.expect(!reopened.rewrite_required);
}

test "flushSync synchronizes an already-current session without replacing the file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    var manager = try SessionManager.create(allocator, io, root, .{
        .path_options = .{ .agent_dir = root, .home = root, .temp_dir = "/tmp" },
    });
    defer manager.deinit();
    _ = try manager.appendMessage(.{ .user = .{ .content = .{ .string = "keep current" }, .timestamp = 1 } });
    _ = try manager.appendMessage(testAssistant("kept", 2));
    try manager.flush();

    const before = try readFileAlloc(allocator, io, manager.path().?);
    defer allocator.free(before);
    const before_stat = try std.Io.Dir.cwd().statFile(io, manager.path().?, .{});
    try manager.flushSync();
    const after = try readFileAlloc(allocator, io, manager.path().?);
    defer allocator.free(after);
    const after_stat = try std.Io.Dir.cwd().statFile(io, manager.path().?, .{});
    try std.testing.expectEqualSlices(u8, before, after);
    try std.testing.expectEqual(before_stat.inode, after_stat.inode);
}

test "session persistence truncates large strings and externalizes base64 images" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];

    const long_text = try allocator.alloc(u8, MAX_PERSISTED_STRING_UTF16 + 250);
    defer allocator.free(long_text);
    @memset(long_text, 'x');
    var raw_image: [800]u8 = undefined;
    for (&raw_image, 0..) |*byte, index| byte.* = @truncate(index);
    const base64_image = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(raw_image.len));
    defer allocator.free(base64_image);
    _ = std.base64.standard.Encoder.encode(base64_image, &raw_image);
    const image_blocks = [_]message.TextImageBlock{.{ .image = .{
        .data = base64_image,
        .mime_type = "image/png",
    } }};

    var manager = try SessionManager.create(allocator, io, root, .{
        .path_options = .{ .agent_dir = root, .home = root, .temp_dir = "/tmp" },
    });
    const session_path = try allocator.dupe(u8, manager.path().?);
    defer allocator.free(session_path);
    _ = try manager.appendMessage(.{ .user = .{ .content = .{ .string = long_text }, .timestamp = 1 } });
    _ = try manager.appendMessage(.{ .user = .{ .content = .{ .blocks = &image_blocks }, .timestamp = 2 } });
    _ = try manager.appendMessage(testAssistant("done", 3));
    try manager.flush();
    manager.deinit();

    const disk = try readFileAlloc(allocator, io, session_path);
    defer allocator.free(disk);
    try std.testing.expect(std.mem.indexOf(u8, disk, PERSISTENCE_TRUNCATION_MARKER) != null);
    try std.testing.expect(std.mem.indexOf(u8, disk, "blob:sha256:") != null);
    try std.testing.expect(std.mem.indexOf(u8, disk, base64_image) == null);

    var reopened = try SessionManager.open(allocator, io, session_path, .{
        .path_options = .{ .agent_dir = root, .home = root, .temp_dir = "/tmp" },
    });
    defer reopened.deinit();
    const restored_text = reopened.getEntries()[0].message.message.user.content.string;
    try std.testing.expectEqual(MAX_PERSISTED_STRING_UTF16, utf16Units(restored_text));
    try std.testing.expect(std.mem.endsWith(u8, restored_text, PERSISTENCE_TRUNCATION_MARKER));
    const restored_image = reopened.getEntries()[1].message.message.user.content.blocks[0].image.data;
    try std.testing.expectEqualStrings(base64_image, restored_image);
}

test "session loader migrates v1 chains and v2 hook messages on next persist" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    const v1_path = try std.fs.path.join(allocator, &.{ root, "v1.jsonl" });
    defer allocator.free(v1_path);
    const v1_fixture =
        "{\"type\":\"session\",\"id\":\"legacy-v1\",\"timestamp\":\"2026-01-01T00:00:00.000Z\",\"cwd\":\"/work\"}\n" ++
        "{\"type\":\"message\",\"timestamp\":\"2026-01-01T00:00:01.000Z\",\"message\":{\"role\":\"user\",\"content\":\"hello\",\"timestamp\":1}}\n" ++
        "{\"type\":\"compaction\",\"timestamp\":\"2026-01-01T00:00:02.000Z\",\"summary\":\"summary\",\"firstKeptEntryIndex\":1,\"tokensBefore\":10}\n";
    try writeFileAbsolute(io, v1_path, v1_fixture);
    var v1 = try SessionManager.open(allocator, io, v1_path, .{
        .path_options = .{ .agent_dir = root, .home = root, .temp_dir = "/tmp" },
    });
    try std.testing.expectEqual(@as(usize, 2), v1.getEntries().len);
    try std.testing.expectEqualStrings(v1.getEntries()[0].envelope().id, v1.getEntries()[1].envelope().parentId.?);
    try std.testing.expectEqualStrings(
        v1.getEntries()[0].envelope().id,
        v1.getEntries()[1].compaction.firstKeptEntryId,
    );
    _ = try v1.appendModeChange("default");
    try v1.flush();
    v1.deinit();
    const v1_rewritten = try readFileAlloc(allocator, io, v1_path);
    defer allocator.free(v1_rewritten);
    try std.testing.expect(std.mem.indexOf(u8, v1_rewritten, "\"version\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, v1_rewritten, "firstKeptEntryIndex") == null);

    const v2_path = try std.fs.path.join(allocator, &.{ root, "v2.jsonl" });
    defer allocator.free(v2_path);
    const v2_fixture =
        "{\"type\":\"session\",\"version\":2,\"id\":\"legacy-v2\",\"timestamp\":\"2026-01-01T00:00:00.000Z\",\"cwd\":\"/work\"}\n" ++
        "{\"type\":\"message\",\"id\":\"12345678\",\"parentId\":null,\"timestamp\":\"2026-01-01T00:00:01.000Z\",\"message\":{\"role\":\"hookMessage\",\"customType\":\"hook\",\"content\":\"context\",\"display\":true,\"timestamp\":1}}\n";
    try writeFileAbsolute(io, v2_path, v2_fixture);
    var v2 = try SessionManager.open(allocator, io, v2_path, .{
        .path_options = .{ .agent_dir = root, .home = root, .temp_dir = "/tmp" },
    });
    try std.testing.expectEqual(@as(usize, 1), v2.getEntries().len);
    try std.testing.expect(v2.getEntries()[0].message.message == .custom);
    _ = try v2.appendModeChange("default");
    try v2.flush();
    v2.deinit();
    const v2_rewritten = try readFileAlloc(allocator, io, v2_path);
    defer allocator.free(v2_rewritten);
    try std.testing.expect(std.mem.indexOf(u8, v2_rewritten, "hookMessage") == null);
    try std.testing.expect(std.mem.indexOf(u8, v2_rewritten, "\"role\":\"custom\"") != null);
}

test "session loader keeps a valid prefix and resets invalid first records" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    const options: OpenOptions = .{ .path_options = .{
        .agent_dir = root,
        .home = root,
        .temp_dir = "/tmp",
    } };

    const missing_path = try std.fs.path.join(allocator, &.{ root, "missing.jsonl" });
    defer allocator.free(missing_path);
    var missing = try SessionManager.open(allocator, io, missing_path, options);
    try std.testing.expectEqual(@as(usize, 0), missing.getEntries().len);
    missing.deinit();

    const empty_path = try std.fs.path.join(allocator, &.{ root, "empty.jsonl" });
    defer allocator.free(empty_path);
    try writeFileAbsolute(io, empty_path, "");
    var empty = try SessionManager.open(allocator, io, empty_path, options);
    try std.testing.expectEqual(@as(usize, 0), empty.getEntries().len);
    empty.deinit();

    const invalid_path = try std.fs.path.join(allocator, &.{ root, "invalid.jsonl" });
    defer allocator.free(invalid_path);
    try writeFileAbsolute(
        io,
        invalid_path,
        "{not-json}\n{\"type\":\"session\",\"version\":3,\"id\":\"ignored\",\"timestamp\":\"2026-01-01T00:00:00.000Z\",\"cwd\":\"/work\"}\n",
    );
    var invalid = try SessionManager.open(allocator, io, invalid_path, options);
    try std.testing.expectEqual(@as(usize, 0), invalid.getEntries().len);
    try std.testing.expect(!std.mem.eql(u8, invalid.header.id, "ignored"));
    invalid.deinit();

    var source = try SessionManager.create(allocator, io, root, .{ .path_options = options.path_options });
    const torn_path = try allocator.dupe(u8, source.path().?);
    defer allocator.free(torn_path);
    _ = try source.appendMessage(.{ .user = .{ .content = .{ .string = "kept" }, .timestamp = 1 } });
    _ = try source.appendMessage(testAssistant("kept", 2));
    try source.flush();
    source.deinit();
    var torn_file = try std.Io.Dir.createFileAbsolute(io, torn_path, .{ .read = true, .truncate = false });
    const torn_offset = try torn_file.length(io);
    try torn_file.writePositionalAll(io, "{\"type\":\"message\"", torn_offset);
    torn_file.close(io);
    var torn = try SessionManager.open(allocator, io, torn_path, options);
    defer torn.deinit();
    try std.testing.expectEqual(@as(usize, 2), torn.getEntries().len);
    try std.testing.expectEqualStrings(torn.getEntries()[1].envelope().id, torn.currentLeaf().?);
}

test "session loader recovers a consistent prefix after abrupt termination" {
    const build_options = @import("build_options");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    const session_path = try std.fs.path.join(allocator, &.{ root, "abrupt.jsonl" });
    defer allocator.free(session_path);
    var child = try std.process.spawn(io, .{
        .argv = &.{ build_options.session_crash_helper_path, session_path, root },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(io);

    const deadline = std.Io.Timestamp.now(io, .awake).addDuration(.fromSeconds(10));
    var observed_size: u64 = 0;
    while (std.Io.Timestamp.now(io, .awake).nanoseconds < deadline.nanoseconds) {
        const stat = std.Io.Dir.cwd().statFile(io, session_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try io.sleep(.fromMilliseconds(1), .awake);
                continue;
            },
            else => return err,
        };
        observed_size = stat.size;
        if (observed_size > 256 + 3 * 64 * 1024) break;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(observed_size > 256 + 3 * 64 * 1024);
    child.kill(io);

    var recovered = try SessionManager.open(allocator, io, session_path, .{
        .path_options = .{ .agent_dir = root, .home = root, .temp_dir = "/tmp" },
    });
    defer recovered.deinit();
    try std.testing.expect(recovered.getEntries().len >= 2);
    var expected_parent: ?[]const u8 = null;
    for (recovered.getEntries()) |entry| {
        const envelope = entry.envelope();
        if (expected_parent) |parent| {
            try std.testing.expectEqualStrings(parent, envelope.parentId.?);
        } else {
            try std.testing.expect(envelope.parentId == null);
        }
        expected_parent = envelope.id;
    }
    try std.testing.expectEqualStrings(expected_parent.?, recovered.currentLeaf().?);
}

fn testAssistant(comptime text: []const u8, timestamp: i64) message.AgentMessage {
    return .{ .assistant = .{
        .content = &.{.{ .text = .{ .text = text } }},
        .api = "anthropic-messages",
        .provider = "anthropic",
        .model = "claude-haiku",
        .usage = .{ .input = 2, .output = 3, .cost = .{ .total = 0.01 } },
        .stop_reason = .stop,
        .timestamp = timestamp,
    } };
}

fn readFileAlloc(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024));
}

fn writeFileAbsolute(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    try file.writePositionalAll(io, bytes, 0);
}
