//! open file store: open/change/close/snapshot

const std = @import("std");

const W = @import("../Workspace.zig");
const Workspace = W.Workspace;
const FileId = W.FileId;
const Snapshot = W.Snapshot;
const OpenOptions = W.OpenOptions;
const FileEntry = W.FileEntry;
const ParsedEntry = W.ParsedEntry;
const pipeline = @import("../pipeline.zig");

pub fn open(self: *Workspace, name: []const u8, text: []const u8, opts: OpenOptions) !FileId {
    if (self.file_names.get(name)) |id| {
        try self.change(id, text);
        return id;
    }

    const name_copy = try self.alloc.dupe(u8, name);
    const text_copy = try self.alloc.dupe(u8, text);
    var stored = false;
    errdefer if (!stored) {
        self.alloc.free(name_copy);
        self.alloc.free(text_copy);
    };

    const id = self.next_file_id;
    self.next_file_id += 1;

    const project_root: []u8 = if (opts.mode == .project and opts.project_root.len > 0)
        try self.alloc.dupe(u8, opts.project_root)
    else
        &.{};

    try self.files.append(self.alloc, .{
        .id = id,
        .version = 1,
        .name = name_copy,
        .text = text_copy,
        .mode = opts.mode,
        .project_root = project_root,
    });
    stored = true;
    errdefer {
        const removed = self.files.pop().?;
        self.alloc.free(removed.name);
        self.alloc.free(removed.text);
        if (removed.project_root.len > 0) self.alloc.free(removed.project_root);
    }
    const index = self.files.items.len - 1;

    try self.file_index.put(id, index);
    errdefer _ = self.file_index.remove(id);

    try self.file_names.put(name_copy, id);
    errdefer _ = self.file_names.remove(name_copy);

    self.symbol_index_dirty = true;
    // query inputs track by content hash
    try self.query_db.track(id, text_copy);
    return id;
}

/// replace file text; invalidates caches
pub fn change(self: *Workspace, id: FileId, text: []const u8) !void {
    // same text changes nothing, version and caches survive
    if (!self.query_db.isDirty(id, text)) return;
    const entry = try entryPtr(self, id);
    const text_copy = try self.alloc.dupe(u8, text);
    errdefer self.alloc.free(text_copy);
    self.alloc.free(entry.text);
    entry.text = text_copy;
    entry.version += 1;
    try self.query_db.track(id, text_copy);
    self.invalidateCache(id);
    self.symbol_index_dirty = true;
}

/// close file; free its memory
pub fn close(self: *Workspace, id: FileId) void {
    const index = self.file_index.get(id) orelse return;
    const removed = self.files.swapRemove(index);
    self.query_db.evict(id);
    self.invalidateCache(id);
    self.removeDeps(id);
    if (self.reverse_deps.fetchRemove(id)) |kv| {
        self.alloc.free(kv.value);
    }
    _ = self.file_names.remove(removed.name);
    _ = self.file_index.remove(id);
    self.alloc.free(removed.name);
    self.alloc.free(removed.text);
    if (removed.project_root.len > 0) self.alloc.free(removed.project_root);
    if (index < self.files.items.len) {
        const moved = self.files.items[index];
        self.file_index.put(moved.id, index) catch {};
    }
    self.symbol_index_dirty = true;
}

/// ret: borrow of file metadata
pub fn snapshot(self: *Workspace, id: FileId) ?Snapshot {
    const index = self.file_index.get(id) orelse return null;
    const entry = self.files.items[index];
    return .{
        .id = entry.id,
        .version = entry.version,
        .name = entry.name,
        .text = entry.text,
    };
}

/// lex + parse on first use, then reuse for this content version
/// ; returned tree/report live until change/close
pub fn parsed(self: *Workspace, id: FileId, repl_mode: bool) !*ParsedEntry {
    const snap = self.snapshot(id) orelse return error.FileNotOpen;
    if (self.parsed_cache.get(id)) |entry| {
        if (entry.version == snap.version and entry.repl_mode == repl_mode) return entry;
        dropParsed(self, id);
    }

    const entry = try self.alloc.create(ParsedEntry);
    errdefer self.alloc.destroy(entry);
    entry.* = .{
        .version = snap.version,
        .repl_mode = repl_mode,
        .arena = std.heap.ArenaAllocator.init(self.alloc),
        .result = undefined,
        .warnings = null,
    };
    errdefer entry.arena.deinit();

    entry.result = try pipeline.parseWithWarnings(entry.arena.allocator(), .{
        .name = snap.name,
        .text = snap.text,
    }, .{ .repl_mode = repl_mode }, &entry.warnings);

    try self.parsed_cache.put(id, entry);
    return entry;
}

/// drop a cached parse, freeing its arena
pub fn dropParsed(self: *Workspace, id: FileId) void {
    if (self.parsed_cache.fetchRemove(id)) |kv| kv.value.deinit(self.alloc);
}

/// stale when cached version lags
///   false when closed, nothing to be stale against
pub fn isStale(self: *Workspace, id: FileId, version: u32) bool {
    const snap = self.snapshot(id) orelse return false;

    return snap.version != version;
}

/// id -> mut *FileEntry
pub fn entryPtr(self: *Workspace, id: FileId) !*FileEntry {
    const index = self.file_index.get(id) orelse return error.FileNotOpen;
    return &self.files.items[index];
}

pub fn clearFiles(self: *Workspace) void {
    while (self.files.items.len != 0) {
        const entry = self.files.pop() orelse unreachable;
        self.query_db.evict(entry.id);
        self.alloc.free(entry.name);
        self.alloc.free(entry.text);
        if (entry.project_root.len > 0) self.alloc.free(entry.project_root);
    }
}

test "workspace stale version tracking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ws = try Workspace.init(alloc);
    defer ws.deinit();

    const id = try ws.open("<test>", "1 + 1", .{});
    const v1 = ws.snapshot(id).?.version;
    try std.testing.expectEqual(@as(u32, 1), v1);
    try std.testing.expect(!ws.isStale(id, v1));

    try ws.change(id, "1 + 2");
    try std.testing.expect(ws.isStale(id, v1));
    const v2 = ws.snapshot(id).?.version;
    try std.testing.expectEqual(@as(u32, 2), v2);
    try std.testing.expect(!ws.isStale(id, v2));
}

test "workspace parse is lazy and cached per version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ws = try Workspace.init(alloc);
    defer ws.deinit();

    const id = try ws.open("<lazy>", "1 + 1", .{});
    // opening must not lex or parse
    try std.testing.expectEqual(@as(usize, 0), ws.parsed_cache.count());

    const first = try ws.parsed(id, false);
    try std.testing.expectEqual(@as(usize, 1), ws.parsed_cache.count());
    const again = try ws.parsed(id, false);
    try std.testing.expect(first == again);

    // edits drop the tree; next use reparses
    try ws.change(id, "1 + 2");
    try std.testing.expectEqual(@as(usize, 0), ws.parsed_cache.count());
    const next = try ws.parsed(id, false);
    try std.testing.expect(next != first);
}
