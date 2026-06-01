const std = @import("std");

const revo = @import("revo");
const lang = @import("./root.zig");
const semantic = @import("semantic.zig");
const VM = revo.VM;

pub const FileId = u32;

pub const Snapshot = struct {
    id: FileId,
    version: u32,
    name: []const u8,
    text: []const u8,
};

const FileEntry = struct {
    id: FileId,
    version: u32,
    name: []u8,
    text: []u8,
};

const CacheEntry = struct {
    version: u32,
    opts: lang.BuildOptions,
    artifact: lang.Artifact,
    symbols: []Symbol,
};

const InspectCacheEntry = struct {
    version: u32,
    opts: lang.BuildOptions,
    symbols: []Symbol,
    dependencies: []FileId,
};

pub const Analysis = struct {
    snapshot: Snapshot,
    artifact: ?lang.Artifact = null,
    diagnostics: ?lang.Error = null,
    cached: bool = false,
    symbols: []Symbol = &.{},
    dependencies: []FileId = &.{},

    pub fn deinit(self: *Analysis, alloc: std.mem.Allocator) void {
        if (self.artifact) |artifact| {
            alloc.free(artifact.instructions);
            alloc.free(artifact.spans);
        }
        if (self.diagnostics) |err| {
            lang.deinitError(alloc, err);
        }
        alloc.free(self.symbols);
        alloc.free(self.dependencies);
    }
};

pub const Position = struct {
    line: u32,
    character: u32,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

pub const Location = struct {
    file_id: FileId,
    name: []const u8,
    range: Range,
};

pub const SymbolKind = enum {
    binding,
    function,
    struct_type,
    type_alias,
};

pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    range: Range,
};

pub const Hover = struct {
    text: []u8,
    range: Range,

    pub fn deinit(self: *Hover, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
    }
};

pub const Workspace = struct {
    alloc: std.mem.Allocator,
    vm: ?*VM,
    files: std.ArrayList(FileEntry),
    file_index: std.AutoHashMap(FileId, usize),
    file_names: std.StringHashMap(FileId),
    dependencies: std.AutoHashMap(FileId, []FileId),
    reverse_deps: std.AutoHashMap(FileId, []FileId),
    cache: std.AutoHashMap(FileId, CacheEntry),
    inspect_cache: std.AutoHashMap(FileId, InspectCacheEntry),
    next_file_id: FileId = 1,

    pub fn init(alloc: std.mem.Allocator) !Workspace {
        return .{
            .alloc = alloc,
            .vm = null,
            .files = try std.ArrayList(FileEntry).initCapacity(alloc, 8),
            .file_index = std.AutoHashMap(FileId, usize).init(alloc),
            .file_names = std.StringHashMap(FileId).init(alloc),
            .dependencies = std.AutoHashMap(FileId, []FileId).init(alloc),
            .reverse_deps = std.AutoHashMap(FileId, []FileId).init(alloc),
            .cache = std.AutoHashMap(FileId, CacheEntry).init(alloc),
            .inspect_cache = std.AutoHashMap(FileId, InspectCacheEntry).init(alloc),
        };
    }

    pub fn initWithVm(vm: *VM, alloc: std.mem.Allocator) !Workspace {
        var workspace = try Workspace.init(alloc);
        workspace.vm = vm;
        return workspace;
    }

    pub fn attachVm(self: *Workspace, vm: *VM) void {
        self.vm = vm;
    }

    pub fn deinit(self: *Workspace) void {
        self.clearFiles();
        self.clearCache();
        self.clearDeps();
        self.files.deinit(self.alloc);
        self.file_index.deinit();
        self.file_names.deinit();
        self.dependencies.deinit();
        self.reverse_deps.deinit();
        self.cache.deinit();
        self.inspect_cache.deinit();
    }

    pub fn open(self: *Workspace, name: []const u8, text: []const u8) !FileId {
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

        try self.files.append(self.alloc, .{
            .id = id,
            .version = 1,
            .name = name_copy,
            .text = text_copy,
        });
        stored = true;
        errdefer {
            const removed = self.files.pop().?;
            self.alloc.free(removed.name);
            self.alloc.free(removed.text);
        }
        const index = self.files.items.len - 1;

        try self.file_index.put(id, index);
        errdefer _ = self.file_index.remove(id);

        try self.file_names.put(name_copy, id);
        errdefer _ = self.file_names.remove(name_copy);

        return id;
    }

    pub fn change(self: *Workspace, id: FileId, text: []const u8) !void {
        const entry = try self.entryPtr(id);
        const text_copy = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(text_copy);
        self.alloc.free(entry.text);
        entry.text = text_copy;
        entry.version += 1;
        self.invalidateCache(id);
    }

    pub fn close(self: *Workspace, id: FileId) void {
        const index = self.file_index.get(id) orelse return;
        const removed = self.files.swapRemove(index).?;
        self.invalidateCache(id);
        self.removeDeps(id);
        if (self.reverse_deps.fetchRemove(id)) |kv| {
            self.alloc.free(kv.value);
        }
        _ = self.file_names.remove(removed.name);
        _ = self.file_index.remove(id);
        self.alloc.free(removed.name);
        self.alloc.free(removed.text);
        if (index < self.files.items.len) {
            const moved = self.files.items[index];
            self.file_index.put(moved.id, index) catch {};
        }
    }

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

    pub fn analyze(
        self: *Workspace,
        alloc: std.mem.Allocator,
        id: FileId,
        opts: lang.BuildOptions,
    ) !lang.BuildResult {
        var analysis = try self.analyzeDetailed(alloc, id, opts);
        if (analysis.artifact) |artifact| {
            analysis.artifact = null;
            defer analysis.deinit(alloc);
            return .{ .ok = artifact };
        }
        defer analysis.deinit(alloc);
        return .{ .err = analysis.diagnostics.? };
    }

    pub fn analyzeDetailed(
        self: *Workspace,
        alloc: std.mem.Allocator,
        id: FileId,
        opts: lang.BuildOptions,
    ) !Analysis {
        const snap = self.snapshot(id) orelse return error.FileNotOpen;
        const vm = self.vm orelse return error.VmUnavailable;
        if (self.cache.get(id)) |cached| {
            if (cached.version == snap.version and sameOpts(cached.opts, opts)) {
                const artifact = try copyArtifact(alloc, cached.artifact);
                errdefer deinitArtifact(alloc, artifact);
                if (opts.install_debug_info) {
                    try vm.setProgramDebugInfo(artifact.spans, snap.text, snap.name);
                }
                return .{
                    .snapshot = snap,
                    .artifact = artifact,
                    .cached = true,
                    .symbols = try copySymbols(alloc, cached.symbols),
                    .dependencies = try self.copyDeps(id),
                };
            }
        }

        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();

        const parsed = try lang.parse(arena.allocator(), .{
            .name = snap.name,
            .text = snap.text,
        }, .{
            .include_default_macros = opts.include_default_macros,
        });

        if (parsed == .err) {
            self.removeDeps(id);
            var report = try parsed.err.report.copy(alloc);
            report.source_name = try alloc.dupe(u8, snap.name);
            report.source = try alloc.dupe(u8, snap.text);
            return .{
                .snapshot = snap,
                .diagnostics = .{ .parse = .{
                    .kind = parsed.err.kind,
                    .report = report,
                } },
                .cached = false,
                .symbols = try self.alloc.alloc(Symbol, 0),
                .dependencies = try self.alloc.alloc(FileId, 0),
            };
        }

        const root = parsed.ok.root;
        const symbols = try self.collectSymbolsFromParsed(root);
        defer self.alloc.free(symbols);
        const deps = try self.collectDepsFromParsed(snap, root);
        errdefer self.alloc.free(deps);
        try self.updateDeps(id, deps);

        const build_result = try lang.build(vm, .{
            .name = snap.name,
            .text = snap.text,
        }, opts);

        return switch (build_result) {
            .ok => |artifact| blk: {
                errdefer deinitArtifact(vm.runtime.alloc, artifact);
                const cache_artifact = try copyArtifact(self.alloc, artifact);
                errdefer deinitArtifact(self.alloc, cache_artifact);
                const cache_symbols = try copySymbols(self.alloc, symbols);
                errdefer self.alloc.free(cache_symbols);
                try self.putCache(id, snap.version, opts, cache_artifact, cache_symbols);
                const copy = try copyArtifact(alloc, artifact);
                errdefer deinitArtifact(alloc, copy);
                break :blk .{
                    .snapshot = snap,
                    .artifact = copy,
                    .cached = false,
                    .symbols = try copySymbols(alloc, symbols),
                    .dependencies = try self.copyDeps(id),
                };
            },
            .err => |err| .{
                .snapshot = snap,
                .diagnostics = try copyError(alloc, err, snap.name, snap.text),
                .cached = false,
                .symbols = try copySymbols(alloc, symbols),
                .dependencies = try self.copyDeps(id),
            },
        };
    }

    pub fn analyzeSource(
        self: *Workspace,
        alloc: std.mem.Allocator,
        name: []const u8,
        text: []const u8,
        opts: lang.BuildOptions,
    ) !lang.BuildResult {
        const id = try self.open(name, text);
        return self.analyze(alloc, id, opts);
    }

    pub fn diagnostics(self: *Workspace, alloc: std.mem.Allocator, id: FileId, opts: lang.BuildOptions) !?lang.Error {
        var analysis = try self.inspectDetailed(alloc, id, opts);
        defer analysis.deinit(alloc);
        return analysis.diagnostics;
    }

    pub fn documentSymbols(self: *Workspace, alloc: std.mem.Allocator, id: FileId, opts: lang.BuildOptions) ![]Symbol {
        var analysis = try self.inspectDetailed(alloc, id, opts);
        defer analysis.deinit(alloc);
        return try copySymbols(alloc, analysis.symbols);
    }

    pub fn definition(self: *Workspace, alloc: std.mem.Allocator, id: FileId, pos: Position, opts: lang.BuildOptions) !?Location {
        var analysis = try self.inspectDetailed(alloc, id, opts);
        defer analysis.deinit(alloc);
        const snap = analysis.snapshot;
        const name = wordAtPosition(snap.text, pos) orelse return null;
        return bestLocation(self, alloc, name, id, pos, opts);
    }

    pub fn hover(self: *Workspace, alloc: std.mem.Allocator, id: FileId, pos: Position, opts: lang.BuildOptions) !?Hover {
        var analysis = try self.inspectDetailed(alloc, id, opts);
        defer analysis.deinit(alloc);
        const snap = analysis.snapshot;
        const name = wordAtPosition(snap.text, pos) orelse return null;
        const def = try self.definition(alloc, id, pos, opts) orelse return null;
        const text = try std.fmt.allocPrint(alloc, "{s} at {s}:{d}:{d}", .{
            name,
            def.name,
            def.range.start.line,
            def.range.start.character,
        });
        return .{
            .text = text,
            .range = def.range,
        };
    }

    pub fn references(self: *Workspace, alloc: std.mem.Allocator, id: FileId, pos: Position, opts: lang.BuildOptions) ![]Location {
        var analysis = try self.inspectDetailed(alloc, id, opts);
        defer analysis.deinit(alloc);
        const snap = analysis.snapshot;
        const name = wordAtPosition(snap.text, pos) orelse return self.alloc.alloc(Location, 0);
        var out = try std.ArrayList(Location).initCapacity(alloc, 4);
        errdefer out.deinit(alloc);

        try self.collectReferencesInFile(alloc, id, name, &out, opts);
        const deps_it = try self.dependencyClosure(alloc, id);
        defer alloc.free(deps_it);
        for (deps_it) |dep| try self.collectReferencesInFile(alloc, dep, name, &out, opts);
        return out.toOwnedSlice(alloc);
    }

    pub fn inspectDetailed(
        self: *Workspace,
        alloc: std.mem.Allocator,
        id: FileId,
        opts: lang.BuildOptions,
    ) !Analysis {
        const snap = self.snapshot(id) orelse return error.FileNotOpen;
        if (self.inspect_cache.get(id)) |cached| {
            if (cached.version == snap.version and sameOpts(cached.opts, opts)) {
                // cache hit: still parse n run semantic for fresh diagnostics,
                // but reuse cached syms and deps
                var arena = std.heap.ArenaAllocator.init(self.alloc);
                defer arena.deinit();

                const parsed = try lang.parse(arena.allocator(), .{
                    .name = snap.name,
                    .text = snap.text,
                }, .{ .include_default_macros = opts.include_default_macros });

                if (parsed == .err) {
                    self.removeDeps(id);
                    var report = try parsed.err.report.copy(alloc);
                    report.source_name = try alloc.dupe(u8, snap.name);
                    report.source = try alloc.dupe(u8, snap.text);
                    return .{
                        .snapshot = snap,
                        .diagnostics = .{ .parse = .{
                            .kind = parsed.err.kind,
                            .report = report,
                        } },
                        .cached = true,
                        .symbols = try copySymbols(alloc, cached.symbols),
                        .dependencies = try self.copyDeps(id),
                    };
                }

                const root = parsed.ok.root;
                const semantic_error = try semantic.analyze(alloc, root, snap.name, snap.text);
                return .{
                    .snapshot = snap,
                    .cached = true,
                    .diagnostics = semantic_error,
                    .symbols = try copySymbols(alloc, cached.symbols),
                    .dependencies = try self.copyDeps(id),
                };
            }
        }

        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();

        const parsed = try lang.parse(arena.allocator(), .{
            .name = snap.name,
            .text = snap.text,
        }, .{
            .include_default_macros = opts.include_default_macros,
        });

        if (parsed == .err) {
            self.removeDeps(id);
            var report = try parsed.err.report.copy(alloc);
            report.source_name = try alloc.dupe(u8, snap.name);
            report.source = try alloc.dupe(u8, snap.text);
            return .{
                .snapshot = snap,
                .diagnostics = .{ .parse = .{
                    .kind = parsed.err.kind,
                    .report = report,
                } },
                .cached = false,
                .symbols = try self.alloc.alloc(Symbol, 0),
                .dependencies = try self.alloc.alloc(FileId, 0),
            };
        }

        const root = parsed.ok.root;
        const symbols = try self.collectSymbolsFromParsed(root);
        errdefer self.alloc.free(symbols);
        const deps = try self.collectDepsFromParsed(snap, root);
        errdefer self.alloc.free(deps);
        try self.updateDeps(id, deps);
        const semantic_error = try semantic.analyze(alloc, root, snap.name, snap.text);
        const cache_symbols = try copySymbols(self.alloc, symbols);
        errdefer self.alloc.free(cache_symbols);
        const cache_deps = try self.copyDeps(id);
        errdefer self.alloc.free(cache_deps);
        try self.putInspectCache(id, snap.version, opts, cache_symbols, cache_deps);

        if (semantic_error) |err| {
            return .{
                .snapshot = snap,
                .diagnostics = err,
                .cached = false,
                .symbols = symbols,
                .dependencies = try self.copyDeps(id),
            };
        }

        return .{
            .snapshot = snap,
            .cached = false,
            .symbols = symbols,
            .dependencies = cache_deps,
        };
    }

    fn putCache(
        self: *Workspace,
        id: FileId,
        version: u32,
        opts: lang.BuildOptions,
        artifact: lang.Artifact,
        symbols: []Symbol,
    ) !void {
        const entry = CacheEntry{
            .version = version,
            .opts = opts,
            .artifact = artifact,
            .symbols = symbols,
        };
        if (self.cache.getPtr(id)) |slot| {
            deinitArtifact(self.alloc, slot.artifact);
            self.alloc.free(slot.symbols);
            slot.* = entry;
        } else {
            try self.cache.put(id, entry);
        }
    }

    fn invalidateCache(self: *Workspace, id: FileId) void {
        var visited = std.AutoHashMap(FileId, void).init(self.alloc);
        defer visited.deinit();
        self.invalidateCacheImpl(id, &visited);
    }

    fn invalidateCacheImpl(
        self: *Workspace,
        id: FileId,
        visited: *std.AutoHashMap(FileId, void),
    ) void {
        if (visited.contains(id)) return;
        visited.put(id, {}) catch return;

        if (self.cache.fetchRemove(id)) |kv| {
            deinitArtifact(self.alloc, kv.value.artifact);
            self.alloc.free(kv.value.symbols);
        }
        if (self.inspect_cache.fetchRemove(id)) |kv| {
            self.alloc.free(kv.value.symbols);
            self.alloc.free(kv.value.dependencies);
        }

        if (self.reverse_deps.get(id)) |dependents| {
            for (dependents) |dep| self.invalidateCacheImpl(dep, visited);
        }
    }

    fn collectDeps(
        self: *Workspace,
        snap: Snapshot,
        opts: lang.BuildOptions,
    ) ![]FileId {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();

        const parsed = try lang.parse(arena.allocator(), .{
            .name = snap.name,
            .text = snap.text,
        }, .{
            .include_default_macros = opts.include_default_macros,
        });

        const root = switch (parsed) {
            .ok => |ok| ok.root,
            .err => return try self.alloc.alloc(FileId, 0),
        };
        return self.collectDepsFromParsed(snap, root);
    }

    fn resolveOpenImport(
        self: *Workspace,
        source_name: []const u8,
        raw_path: []const u8,
    ) ?FileId {
        const resolved = self.resolveImportPath(source_name, raw_path) orelse return null;
        defer self.alloc.free(resolved);
        return self.file_names.get(resolved);
    }

    fn resolveImportPath(
        self: *Workspace,
        source_name: []const u8,
        raw_path: []const u8,
    ) ?[]u8 {
        const base_dir = std.fs.path.dirname(source_name) orelse ".";
        const joined = if (std.fs.path.isAbsolute(raw_path))
            self.alloc.dupe(u8, raw_path) catch return null
        else
            std.fs.path.join(self.alloc, &.{ base_dir, raw_path }) catch return null;
        if (std.fs.path.extension(joined).len != 0) return joined;
        const with_ext = std.fmt.allocPrint(self.alloc, "{s}.rv", .{joined}) catch {
            self.alloc.free(joined);
            return null;
        };
        self.alloc.free(joined);
        return with_ext;
    }

    fn updateDeps(self: *Workspace, id: FileId, new_deps: []FileId) !void {
        const old_deps = if (self.dependencies.fetchRemove(id)) |kv| kv.value else &.{};

        if (old_deps.len != 0) {
            for (old_deps) |dep| {
                if (!containsId(new_deps, dep)) try self.removeReverseDep(dep, id);
            }
        }

        if (new_deps.len != 0) {
            for (new_deps) |dep| {
                if (!containsId(old_deps, dep)) try self.addReverseDep(dep, id);
            }
            try self.dependencies.put(id, new_deps);
        } else {
            self.alloc.free(new_deps);
        }

        if (old_deps.len != 0) {
            self.alloc.free(old_deps);
        }
    }

    fn removeDeps(self: *Workspace, id: FileId) void {
        if (self.dependencies.fetchRemove(id)) |kv| {
            for (kv.value) |dep| self.removeReverseDep(dep, id) catch {};
            self.alloc.free(kv.value);
        }
    }

    fn addReverseDep(self: *Workspace, dep: FileId, id: FileId) !void {
        const current = self.reverse_deps.get(dep);
        if (current) |items| {
            if (containsId(items, id)) return;
            const next = try self.alloc.alloc(FileId, items.len + 1);
            @memcpy(next[0..items.len], items);
            next[items.len] = id;
            self.alloc.free(items);
            try self.reverse_deps.put(dep, next);
        } else {
            const next = try self.alloc.alloc(FileId, 1);
            next[0] = id;
            try self.reverse_deps.put(dep, next);
        }
    }

    fn removeReverseDep(self: *Workspace, dep: FileId, id: FileId) !void {
        const current = self.reverse_deps.get(dep) orelse return;
        var pos: ?usize = null;
        for (current, 0..) |item, idx| {
            if (item == id) {
                pos = idx;
                break;
            }
        }
        const idx = pos orelse return;
        if (current.len == 1) {
            self.alloc.free(current);
            _ = self.reverse_deps.remove(dep);
            return;
        }
        const next = try self.alloc.alloc(FileId, current.len - 1);
        @memcpy(next[0..idx], current[0..idx]);
        @memcpy(next[idx..], current[idx + 1 ..]);
        self.alloc.free(current);
        try self.reverse_deps.put(dep, next);
    }

    fn clearFiles(self: *Workspace) void {
        while (self.files.items.len != 0) {
            const entry = self.files.pop().?;
            self.alloc.free(entry.name);
            self.alloc.free(entry.text);
        }
    }

    fn clearCache(self: *Workspace) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            deinitArtifact(self.alloc, entry.value_ptr.artifact);
            self.alloc.free(entry.value_ptr.symbols);
        }
        var inspect_it = self.inspect_cache.iterator();
        while (inspect_it.next()) |entry| {
            self.alloc.free(entry.value_ptr.symbols);
            self.alloc.free(entry.value_ptr.dependencies);
        }
    }

    fn clearDeps(self: *Workspace) void {
        var it = self.dependencies.iterator();
        while (it.next()) |entry| self.alloc.free(entry.value_ptr.*);
        it = self.reverse_deps.iterator();
        while (it.next()) |entry| self.alloc.free(entry.value_ptr.*);
        self.dependencies.clearRetainingCapacity();
        self.reverse_deps.clearRetainingCapacity();
    }

    fn copyDeps(self: *Workspace, id: FileId) ![]FileId {
        const deps = self.dependencies.get(id) orelse return self.alloc.alloc(FileId, 0);
        return self.alloc.dupe(FileId, deps);
    }

    fn putInspectCache(
        self: *Workspace,
        id: FileId,
        version: u32,
        opts: lang.BuildOptions,
        symbols: []Symbol,
        dependencies: []FileId,
    ) !void {
        const entry = InspectCacheEntry{
            .version = version,
            .opts = opts,
            .symbols = symbols,
            .dependencies = dependencies,
        };
        if (self.inspect_cache.getPtr(id)) |slot| {
            self.alloc.free(slot.symbols);
            self.alloc.free(slot.dependencies);
            slot.* = entry;
        } else {
            try self.inspect_cache.put(id, entry);
        }
    }

    fn dependencyClosure(self: *Workspace, alloc: std.mem.Allocator, id: FileId) ![]FileId {
        var visited = std.AutoHashMap(FileId, void).init(alloc);
        defer visited.deinit();

        var out = try std.ArrayList(FileId).initCapacity(alloc, 4);
        errdefer out.deinit(alloc);

        try self.collectDependencyClosure(id, alloc, &visited, &out);
        return out.toOwnedSlice(alloc);
    }

    fn collectDependencyClosure(
        self: *Workspace,
        id: FileId,
        alloc: std.mem.Allocator,
        visited: *std.AutoHashMap(FileId, void),
        out: *std.ArrayList(FileId),
    ) !void {
        const deps = self.dependencies.get(id) orelse return;
        for (deps) |dep| {
            if (visited.contains(dep)) continue;
            try visited.put(dep, {});
            try out.append(alloc, dep);
            try self.collectDependencyClosure(dep, alloc, visited, out);
        }
    }

    fn collectSymbols(self: *Workspace, snap: Snapshot, opts: lang.BuildOptions) ![]Symbol {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();

        const parsed = try lang.parse(arena.allocator(), .{
            .name = snap.name,
            .text = snap.text,
        }, .{
            .include_default_macros = opts.include_default_macros,
        });

        const root = switch (parsed) {
            .ok => |ok| ok.root,
            .err => return self.alloc.alloc(Symbol, 0),
        };
        return self.collectSymbolsFromParsed(root);
    }

    fn collectSymbolsFromParsed(self: *Workspace, root: *lang.Node) ![]Symbol {
        var out = try std.ArrayList(Symbol).initCapacity(self.alloc, 8);
        errdefer out.deinit(self.alloc);
        var visitor = SymbolVisitor{ .alloc = self.alloc, .out = &out };
        visitor.visit(root);
        return out.toOwnedSlice(self.alloc);
    }

    fn collectDepsFromParsed(self: *Workspace, snap: Snapshot, root: *lang.Node) ![]FileId {
        var out = try std.ArrayList(FileId).initCapacity(self.alloc, 4);
        errdefer out.deinit(self.alloc);
        var visitor = ImportVisitor{
            .ws = self,
            .out = &out,
            .base = snap.name,
            .failed = false,
        };
        visitor.visit(root);
        if (visitor.failed) return error.OutOfMemory;
        return out.toOwnedSlice(self.alloc);
    }

    fn collectReferencesInFile(
        self: *Workspace,
        alloc: std.mem.Allocator,
        id: FileId,
        name: []const u8,
        out: *std.ArrayList(Location),
        opts: lang.BuildOptions,
    ) !void {
        const snap = self.snapshot(id) orelse return;
        _ = opts;
        var pos: usize = 0;
        while (wordIndexOf(snap.text, name, pos)) |idx| {
            const start = offsetToPosition(snap.text, idx);
            const end = offsetToPosition(snap.text, idx + name.len);
            try out.append(alloc, .{
                .file_id = id,
                .name = snap.name,
                .range = .{ .start = start, .end = end },
            });
            pos = idx + name.len;
        }
    }

    fn bestLocation(
        self: *Workspace,
        alloc: std.mem.Allocator,
        name: []const u8,
        id: FileId,
        pos: Position,
        opts: lang.BuildOptions,
    ) !?Location {
        var best: ?Location = null;
        try self.pickBestFromFile(alloc, id, name, pos, opts, &best);
        if (best != null) return best;

        const deps = try self.dependencyClosure(alloc, id);
        defer alloc.free(deps);
        for (deps) |dep| {
            try self.pickBestFromFile(alloc, dep, name, pos, opts, &best);
            if (best != null) return best;
        }

        return null;
    }

    fn pickBestFromFile(
        self: *Workspace,
        alloc: std.mem.Allocator,
        id: FileId,
        name: []const u8,
        pos: Position,
        opts: lang.BuildOptions,
        best: *?Location,
    ) !void {
        var analysis = try self.inspectDetailed(alloc, id, opts);
        defer analysis.deinit(alloc);
        for (analysis.symbols) |sym| {
            if (!std.mem.eql(u8, sym.name, name)) continue;
            if (positionBefore(sym.range.start, pos)) {
                if (best.* == null or positionBefore(best.*.?.range.start, sym.range.start)) {
                    best.* = .{
                        .file_id = id,
                        .name = self.snapshot(id).?.name,
                        .range = sym.range,
                    };
                }
            }
        }
    }

    fn entryPtr(self: *Workspace, id: FileId) !*FileEntry {
        const index = self.file_index.get(id) orelse return error.FileNotOpen;
        return &self.files.items[index];
    }
};

fn sameOpts(a: lang.BuildOptions, b: lang.BuildOptions) bool {
    return a.include_default_macros == b.include_default_macros and
        a.install_debug_info == b.install_debug_info and
        a.test_mode == b.test_mode;
}

fn copyArtifact(alloc: std.mem.Allocator, artifact: lang.Artifact) !lang.Artifact {
    return .{
        .instructions = try alloc.dupe(revo.Instruction, artifact.instructions),
        .spans = try alloc.dupe(lang.Span, artifact.spans),
    };
}

fn deinitArtifact(alloc: std.mem.Allocator, artifact: lang.Artifact) void {
    alloc.free(artifact.instructions);
    alloc.free(artifact.spans);
}

fn copyError(
    alloc: std.mem.Allocator,
    err: lang.Error,
    source_name: []const u8,
    source: []const u8,
) !lang.Error {
    return switch (err) {
        .parse => |failure| blk: {
            var report = try failure.report.copy(alloc);
            report.source_name = try alloc.dupe(u8, source_name);
            report.source = try alloc.dupe(u8, source);
            break :blk .{ .parse = .{ .kind = failure.kind, .report = report } };
        },
        .expand => |failure| blk: {
            var report = try failure.report.copy(alloc);
            report.source_name = try alloc.dupe(u8, source_name);
            report.source = try alloc.dupe(u8, source);
            break :blk .{ .expand = .{ .report = report } };
        },
        .lower => |failure| blk: {
            var report = try failure.report.copy(alloc);
            report.source_name = try alloc.dupe(u8, source_name);
            report.source = try alloc.dupe(u8, source);
            break :blk .{ .lower = .{ .kind = failure.kind, .report = report } };
        },
        .semantic => |failure| blk: {
            var report = try failure.report.copy(alloc);
            report.source_name = try alloc.dupe(u8, source_name);
            report.source = try alloc.dupe(u8, source);
            break :blk .{ .semantic = .{ .kind = failure.kind, .report = report } };
        },
    };
}

fn copySymbols(alloc: std.mem.Allocator, symbols: []const Symbol) ![]Symbol {
    return alloc.dupe(Symbol, symbols);
}

fn positionBefore(a: Position, b: Position) bool {
    return a.line < b.line or (a.line == b.line and a.character <= b.character);
}

fn offsetToPosition(text: []const u8, offset: usize) Position {
    var line: u32 = 1;
    var col: u32 = 1;
    var i: usize = 0;
    while (i < offset and i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .character = col };
}

fn wordAtPosition(text: []const u8, pos: Position) ?[]const u8 {
    const offset = positionToOffset(text, pos) orelse return null;
    if (offset >= text.len) return null;
    var start = offset;
    while (start > 0 and isWordChar(text[start - 1])) start -= 1;
    var end = offset;
    while (end < text.len and isWordChar(text[end])) end += 1;
    if (end <= start) return null;
    return text[start..end];
}

fn wordIndexOf(text: []const u8, name: []const u8, start: usize) ?usize {
    if (name.len == 0) return null;
    var idx = start;
    while (idx + name.len <= text.len) : (idx += 1) {
        if (!std.mem.eql(u8, text[idx .. idx + name.len], name)) continue;
        const before_ok = idx == 0 or !isWordChar(text[idx - 1]);
        const after_ok = idx + name.len == text.len or !isWordChar(text[idx + name.len]);
        if (before_ok and after_ok) return idx;
    }
    return null;
}

fn positionToOffset(text: []const u8, pos: Position) ?usize {
    var line: u32 = 1;
    var col: u32 = 1;
    for (text, 0..) |ch, idx| {
        if (line == pos.line and col == pos.character) return idx;
        if (ch == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    if (line == pos.line and col == pos.character) return text.len;
    return null;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

const SymbolVisitor = struct {
    alloc: std.mem.Allocator,
    out: *std.ArrayList(Symbol),

    pub fn visit(self: *@This(), node: *const lang.Node) void {
        switch (node.expr) {
            .decl => |d| switch (d.inner.expr) {
                .binding => |b| self.addBinding(b),
                .struct_def => |def| self.addName(def.name, .struct_type, node.span),
                .type_alias => |t| self.addName(t.name, .type_alias, node.span),
                else => {},
            },
            .binding => |b| self.addBinding(b),
            .struct_def => |def| self.addName(def.name, .struct_type, node.span),
            .type_alias => |t| self.addName(t.name, .type_alias, node.span),
            else => {},
        }
        lang.ast.walkAST(SymbolVisitor, self, node);
    }

    fn addBinding(self: *@This(), b: lang.ast.Binding) void {
        if (b.target.expr == .ident) {
            self.addName(b.target.expr.ident, .binding, b.target.span);
        }
    }

    fn addName(self: *@This(), name: []const u8, kind: SymbolKind, span: lang.Span) void {
        self.out.append(self.alloc, .{
            .name = name,
            .kind = kind,
            .range = .{
                .start = .{ .line = span.line, .character = @intCast(span.column) },
                .end = .{ .line = span.line, .character = @intCast(span.column + 1) },
            },
        }) catch {};
    }
};

fn containsId(items: []const FileId, id: FileId) bool {
    for (items) |item|
        if (item == id) return true;

    return false;
}

const ImportVisitor = struct {
    ws: *Workspace,
    out: *std.ArrayList(FileId),
    base: []const u8,
    failed: bool,

    pub fn visit(self: *@This(), node: *const lang.Node) void {
        if (node.expr == .import_expr) {
            const path = node.expr.import_expr;
            const raw = switch (path.expr) {
                .string => path.expr.string,
                .multiline_string => path.expr.multiline_string,
                else => "",
            };
            if (raw.len != 0) {
                if (self.ws.resolveOpenImport(self.base, raw)) |id| {
                    if (!containsId(self.out.items, id)) {
                        self.out.append(self.ws.alloc, id) catch {
                            self.failed = true;
                        };
                    }
                }
            }
        }
        lang.ast.walkAST(ImportVisitor, self, node);
    }
};

test "workspace caches repeated analysis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var vm = try VM.init(.{ .alloc = alloc, .io = std.testing.io });
    defer vm.deinit();

    var ws = try Workspace.initWithVm(&vm, alloc);
    defer ws.deinit();

    const id = try ws.open("<test>", "1 + 1");
    const first = try ws.analyze(alloc, id, .{});
    try std.testing.expect(first == .ok);

    const second = try ws.analyze(alloc, id, .{});
    try std.testing.expect(second == .ok);
    try std.testing.expectEqual(first.ok.instructions.len, second.ok.instructions.len);
}

test "workspace invalidates cache on change" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var vm = try VM.init(.{ .alloc = alloc, .io = std.testing.io });
    defer vm.deinit();

    var ws = try Workspace.initWithVm(&vm, alloc);
    defer ws.deinit();

    const id = try ws.open("<test>", "1 + 1");
    const first = try ws.analyze(alloc, id, .{});
    defer switch (first) {
        .ok => |artifact| {
            alloc.free(artifact.instructions);
            alloc.free(artifact.spans);
        },
        .err => |err| lang.deinitError(alloc, err),
    };

    try ws.change(id, "1 + 2");
    const snap = ws.snapshot(id).?;
    try std.testing.expectEqual(@as(u32, 2), snap.version);

    const second = try ws.analyze(alloc, id, .{});
    defer switch (second) {
        .ok => |artifact| {
            alloc.free(artifact.instructions);
            alloc.free(artifact.spans);
        },
        .err => |err| lang.deinitError(alloc, err),
    };
    try std.testing.expect(second == .ok);
}

test "workspace invalidates dependent caches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var vm = try VM.init(.{ .alloc = alloc, .io = std.testing.io });
    defer vm.deinit();

    var ws = try Workspace.initWithVm(&vm, alloc);
    defer ws.deinit();

    const a = try ws.open("dir/a.rv", "1");
    const b = try ws.open("dir/b.rv", "import \"a\"");
    const c = try ws.open("dir/c.rv", "import \"b\"");

    const res_b = try ws.analyze(alloc, b, .{});
    defer switch (res_b) {
        .ok => |artifact| {
            alloc.free(artifact.instructions);
            alloc.free(artifact.spans);
        },
        .err => |err| lang.deinitError(alloc, err),
    };

    const res_c = try ws.analyze(alloc, c, .{});
    defer switch (res_c) {
        .ok => |artifact| {
            alloc.free(artifact.instructions);
            alloc.free(artifact.spans);
        },
        .err => |err| lang.deinitError(alloc, err),
    };

    try std.testing.expect(ws.cache.get(b) != null);
    try std.testing.expect(ws.cache.get(c) != null);

    try ws.change(a, "2");

    try std.testing.expect(ws.cache.get(b) == null);
    try std.testing.expect(ws.cache.get(c) == null);
}

test "analysis returns snapshot and artifact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var vm = try VM.init(.{ .alloc = alloc, .io = std.testing.io });
    defer vm.deinit();

    var ws = try Workspace.initWithVm(&vm, alloc);
    defer ws.deinit();

    const id = try ws.open("<test>", "1 + 1");
    var analysis = try ws.analyzeDetailed(alloc, id, .{});
    defer analysis.deinit(alloc);

    try std.testing.expectEqualStrings("<test>", analysis.snapshot.name);
    try std.testing.expect(analysis.artifact != null);
    try std.testing.expect(analysis.diagnostics == null);
}

test "workspace query surface" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ws = try Workspace.init(alloc);
    defer ws.deinit();

    const source =
        \\const x = 1
        \\x
    ;
    const id = try ws.open("<test>", source);
    const query_opts: lang.BuildOptions = .{
        .include_default_macros = false,
        .install_debug_info = false,
        .test_mode = false,
    };

    const syms = try ws.documentSymbols(alloc, id, query_opts);
    defer alloc.free(syms);
    try std.testing.expect(syms.len != 0);
    var found_symbol = false;
    for (syms) |sym| {
        if (std.mem.eql(u8, sym.name, "x")) {
            found_symbol = true;
            break;
        }
    }
    try std.testing.expect(found_symbol);

    const def = try ws.definition(alloc, id, .{ .line = 2, .character = 1 }, query_opts);
    try std.testing.expect(def != null);
    try std.testing.expectEqualStrings("<test>", def.?.name);

    const refs = try ws.references(alloc, id, .{ .line = 2, .character = 1 }, query_opts);
    defer alloc.free(refs);
    try std.testing.expect(refs.len >= 2);

    var hov = try ws.hover(alloc, id, .{ .line = 2, .character = 1 }, query_opts);
    try std.testing.expect(hov != null);
    defer if (hov) |*h| h.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, hov.?.text, "x at") != null);
}

test "workspace diagnostics query" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ws = try Workspace.init(alloc);
    defer ws.deinit();

    const id = try ws.open("<test>", "const x =");
    const diag = try ws.diagnostics(alloc, id, .{});
    try std.testing.expect(diag != null);
}
