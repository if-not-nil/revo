//! build + inspect caches and invalidation

const std = @import("std");

const common = @import("common.zig");
const diagnostic = @import("../diagnostic.zig");
const pipeline = @import("../pipeline.zig");
const store = @import("store.zig");

const W = @import("../Workspace.zig");
const Workspace = W.Workspace;
const FileId = W.FileId;
const Symbol = W.Symbol;
const FnSig = W.FnSig;
const CacheEntry = W.CacheEntry;
const InspectCacheEntry = W.InspectCacheEntry;

// store build bytecode in cache
pub fn putCache(
    self: *Workspace,
    id: FileId,
    version: u32,
    opts: pipeline.BuildOptions,
    bytecode: pipeline.Bytecode,
    symbols: []Symbol,
    warnings: ?diagnostic.Report,
) !void {
    const entry = CacheEntry{
        .version = version,
        .opts = opts,
        .bytecode = bytecode,
        .warnings = warnings,
        .symbols = symbols,
    };
    if (self.cache.getPtr(id)) |slot| {
        common.deinitBytecode(self.alloc, slot.bytecode);
        common.freeSymbols(self.alloc, slot.symbols);
        if (slot.warnings) |*w| w.deinit();
        slot.* = entry;
    } else {
        try self.cache.put(id, entry);
    }
}

/// invalidate a file and all its transitive dependents
pub fn invalidateCache(self: *Workspace, id: FileId) void {
    var visited = std.AutoHashMap(FileId, void).init(self.alloc);
    defer visited.deinit();
    invalidateCacheImpl(self, id, &visited);
}

/// recursive invalidate; visited prevents cycle chokes
pub fn invalidateCacheImpl(
    self: *Workspace,
    id: FileId,
    visited: *std.AutoHashMap(FileId, void),
) void {
    if (visited.contains(id)) return;
    visited.put(id, {}) catch return;

    store.dropParsed(self, id);

    if (self.cache.fetchRemove(id)) |kv| {
        var val = kv.value;
        common.deinitBytecode(self.alloc, val.bytecode);
        common.freeSymbols(self.alloc, val.symbols);
        if (val.warnings) |*w| w.deinit();
    }
    if (self.inspect_cache.fetchRemove(id)) |kv| {
        common.freeSymbols(self.alloc, kv.value.symbols);
        if (kv.value.diagnostics) |diag| pipeline.deinitError(diag);
        var e = kv.value;
        e.deinit(self.alloc);
    }

    if (self.reverse_deps.get(id)) |dependents| {
        for (dependents) |dep| invalidateCacheImpl(self, dep, visited);
    }
}

/// free all build and inspect caches
pub fn clearCache(self: *Workspace) void {
    var it = self.cache.iterator();
    while (it.next()) |entry| {
        common.deinitBytecode(self.alloc, entry.value_ptr.bytecode);
        common.freeSymbols(self.alloc, entry.value_ptr.symbols);
        if (entry.value_ptr.warnings) |*w| w.deinit();
    }
    var inspect_it = self.inspect_cache.iterator();
    while (inspect_it.next()) |entry| {
        common.freeSymbols(self.alloc, entry.value_ptr.symbols);
        if (entry.value_ptr.diagnostics) |diag| {
            pipeline.deinitError(diag);
        }
        var e = entry.value_ptr.*;
        e.deinit(self.alloc);
    }
    var parsed_it = self.parsed_cache.iterator();
    while (parsed_it.next()) |entry| entry.value_ptr.*.deinit(self.alloc);
    self.parsed_cache.clearRetainingCapacity();
}

/// store results in the inspect cache (symbols + deps + diagnostics)
pub fn putInspectCache(
    self: *Workspace,
    id: FileId,
    version: u32,
    opts: pipeline.BuildOptions,
    symbols: []Symbol,
    diag: ?pipeline.Error,
    sig_map: std.StringHashMapUnmanaged(FnSig),
    docs: std.StringHashMap([]const u8),
) !void {
    const entry = InspectCacheEntry{
        .version = version,
        .opts = opts,
        .symbols = symbols,
        .diagnostics = diag,
        .sig_map = sig_map,
        .docs = docs,
    };
    if (self.inspect_cache.getPtr(id)) |slot| {
        common.freeSymbols(self.alloc, slot.symbols);
        if (slot.diagnostics) |cached_d| pipeline.deinitError(cached_d);
        slot.deinit(self.alloc);
        slot.* = entry;
    } else {
        try self.inspect_cache.put(id, entry);
    }
}
