//! import resolution: paths, dep ids, module symbols

const std = @import("std");

const common = @import("common.zig");
const import_graph = @import("../import_graph.zig");
const revo = @import("revo");

const W = @import("../Workspace.zig");
const Workspace = W.Workspace;
const FileId = W.FileId;
const Symbol = W.Symbol;

/// open file an import names, rules in `revo.import_path`
pub fn resolveOpenImport(self: *Workspace, source_name: []const u8, raw_path: []const u8) ?FileId {
    return resolveImport(self, source_name, raw_path, false) catch null;
}

/// `resolveOpenImport`, reading from disk when no buffer has it
pub fn resolveOpenImportOrOpen(self: *Workspace, source_name: []const u8, raw_path: []const u8) ?FileId {
    return resolveImport(self, source_name, raw_path, true) catch null;
}

/// open buffers first, then the disk when `open`
/// ; errors say why, see `revo.import_path.message`
pub fn resolveImport(self: *Workspace, source_name: []const u8, raw_path: []const u8, open: bool) !FileId {
    const collections: []const revo.import_path.Collection =
        if (self.vm) |vm| vm.collections.items else &.{};

    const importer_dir = std.Io.Dir.path.dirname(source_name) orelse ".";
    const cands = try revo.import_path.candidates(self.alloc, raw_path, importer_dir, collections, .static);
    defer cands.deinit(self.alloc);

    // open files go by realpath when they're on disk, see `store.open`
    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    for (cands.paths()) |p| {
        if (self.file_names.get(p)) |id| return id;
        const vm = self.vm orelse continue;
        const n = std.Io.Dir.cwd().realPathFile(vm.runtime.io, p, &real_buf) catch continue;
        if (self.file_names.get(real_buf[0..n])) |id| return id;
    }

    if (open) for (cands.paths()) |p| {
        if (openFromDisk(self, p)) |id| return id;
    };

    return error.FileNotFound;
}

/// symbols of the module bound by `name = import("x")` in `file_id`
pub fn importedModuleSymbols(
    self: *Workspace,
    alloc: std.mem.Allocator,
    file_id: FileId,
    name: []const u8,
) ![]const Symbol {
    const dep_id = resolveDepId(self, alloc, file_id, name) orelse return &.{};
    return symbolsFromDep(self, alloc, dep_id);
}

/// syms off a dep file, caller frees
pub fn symbolsFromDep(self: *Workspace, alloc: std.mem.Allocator, dep_id: FileId) ![]const Symbol {
    const entry = try self.ensureInspect(alloc, dep_id, .{});
    return common.copyFilteredSymbols(alloc, entry.symbols, true);
}

/// realpath `name` is bound to in `file_id`, `const name = import("x")`
/// ; from the checker's graph, the last good analysis when mid-edit (caller frees)
pub fn findImportPathForBinding(self: *Workspace, alloc: std.mem.Allocator, file_id: FileId, name: []const u8) ?[]const u8 {
    if (!self.import_bindings.contains(file_id)) _ = self.ensureInspect(alloc, file_id, .{}) catch return null;
    const bindings = self.import_bindings.getPtr(file_id) orelse return null;
    const path = bindings.get(name) orelse return null;
    return alloc.dupe(u8, path) catch null;
}

/// the last analysis that parsed decides, so `m.<cursor>` still knows `m`
pub fn setImportBindings(self: *Workspace, id: FileId, graph: *const import_graph.Graph) !void {
    var next: std.StringHashMapUnmanaged([]const u8) = .empty;
    errdefer common.freeImports(self.alloc, &next);
    var it = graph.bindings.iterator();
    while (it.next()) |e| {
        const k = try self.alloc.dupe(u8, e.key_ptr.*);
        errdefer self.alloc.free(k);
        const v = try self.alloc.dupe(u8, e.value_ptr.*);
        errdefer self.alloc.free(v);
        try next.put(self.alloc, k, v);
    }
    const gop = try self.import_bindings.getOrPut(self.alloc, id);
    if (gop.found_existing) common.freeImports(self.alloc, gop.value_ptr);
    gop.value_ptr.* = next;
}

/// the open file of the module bound to `mod_name` in `file_id`
pub fn resolveDepId(
    self: *Workspace,
    alloc: std.mem.Allocator,
    file_id: FileId,
    mod_name: []const u8,
) ?FileId {
    const path = findImportPathForBinding(self, alloc, file_id, mod_name) orelse return null;
    defer alloc.free(path);
    return self.file_names.get(path) orelse openFromDisk(self, path);
}

/// read a file from disk and open it under its realpath, the name builds use
fn openFromDisk(self: *Workspace, path: []const u8) ?FileId {
    const vm = self.vm orelse return null;
    const io = vm.runtime.io;
    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.cwd().realPathFile(io, path, &real_buf) catch return null;
    const real = real_buf[0..n];
    if (self.file_names.get(real)) |id| return id;

    const text = std.Io.Dir.cwd().readFileAlloc(io, real, self.alloc, .limited(std.math.maxInt(usize))) catch return null;
    defer self.alloc.free(text);
    return self.open(real, text) catch null;
}
