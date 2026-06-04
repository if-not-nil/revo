const std = @import("std");

const revo = @import("revo");
const lang = @import("./root.zig");
const semantic = @import("semantic.zig");
const VM = revo.VM;

//
// types
//

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
    mode: lang.RunMode = .script,
    project_root: []u8 = &.{},
};

// cache for analyzeDetailed (full build)
const CacheEntry = struct {
    version: u32,
    opts: lang.BuildOptions,
    artifact: lang.Artifact,
    symbols: []Symbol,
};

/// cached fn sig: params as name+type pairs, return type, doc
pub const FnSig = struct {
    params: []ParamInfo,
    return_type: []const u8,
    doc: ?[]const u8,
};

// cache for inspectDetailed (quick inspect)
const InspectCacheEntry = struct {
    version: u32,
    opts: lang.BuildOptions,
    symbols: []Symbol,
    dependencies: []FileId,
    diagnostics: ?lang.Error = null,
    sig_map: std.StringHashMapUnmanaged(FnSig) = .empty,
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
        freeSymbols(alloc, self.symbols);
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
    type_name: []const u8 = "",
};

pub const Hover = struct {
    text: []u8,
    range: Range,

    pub fn deinit(self: *Hover, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
    }
};

pub const ParamInfo = struct {
    name: []const u8,
    type_name: []const u8,
};

pub const SignatureHelp = struct {
    name: []const u8,
    params: []ParamInfo,
    return_type: []const u8,
    doc: ?[]const u8,
    active_param: u32,

    pub fn deinit(self: *SignatureHelp, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        for (self.params) |p| {
            alloc.free(p.name);
            alloc.free(p.type_name);
        }
        alloc.free(self.params);
        alloc.free(self.return_type);
        if (self.doc) |d| alloc.free(d);
    }
};

pub const IndexedSymbol = struct {
    file_id: FileId,
    range: Range,
    kind: SymbolKind,
};

pub const OpenOptions = struct {
    mode: lang.RunMode = .script,
    project_root: []const u8 = &.{},
};

//
// workspace
//

pub const Workspace = struct {
    alloc: std.mem.Allocator,
    vm: ?*VM,
    files: std.ArrayList(FileEntry), // open file entries
    file_index: std.AutoHashMap(FileId, usize),
    file_names: std.StringHashMap(FileId),
    dependencies: std.AutoHashMap(FileId, []FileId),
    reverse_deps: std.AutoHashMap(FileId, []FileId),
    cache: std.AutoHashMap(FileId, CacheEntry), // full build cache
    inspect_cache: std.AutoHashMap(FileId, InspectCacheEntry), // quick inspect cache
    symbol_index: std.StringHashMap([]IndexedSymbol),
    symbol_index_dirty: bool = true,
    next_file_id: FileId = 1,

    // alloc workspace; vm must be put on later
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
            .symbol_index = std.StringHashMap([]IndexedSymbol).init(alloc),
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
        {
            var it = self.symbol_index.iterator();
            while (it.next()) |entry| {
                self.alloc.free(entry.value_ptr.*);
                self.alloc.free(entry.key_ptr.*);
            }
        }
        self.symbol_index.deinit();
    }

    /// ...in script mode
    pub fn open(self: *Workspace, name: []const u8, text: []const u8) !FileId {
        return self.openWith(name, text, .{});
    }

    /// ...with explicit mode/options
    pub fn openWith(self: *Workspace, name: []const u8, text: []const u8, opts: OpenOptions) !FileId {
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
        return id;
    }

    /// replace file text; invalidates caches
    pub fn change(self: *Workspace, id: FileId, text: []const u8) !void {
        const entry = try self.entryPtr(id);
        const text_copy = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(text_copy);
        self.alloc.free(entry.text);
        entry.text = text_copy;
        entry.version += 1;
        self.invalidateCache(id);
        self.symbol_index_dirty = true;
    }

    /// close file; free its memory
    pub fn close(self: *Workspace, id: FileId) void {
        const index = self.file_index.get(id) orelse return;
        const removed = self.files.swapRemove(index);
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

    pub fn currentVersion(self: *Workspace, id: FileId) ?u32 {
        return self.snapshot(id).?.version;
    }

    /// check if cached version is outdated
    pub fn isStale(self: *Workspace, id: FileId, version: u32) bool {
        return !(self.currentVersion(id) == version);
    }

    fn rebuildSymbolIndex(self: *Workspace) void {
        {
            var it = self.symbol_index.iterator();
            while (it.next()) |entry| {
                self.alloc.free(entry.value_ptr.*);
                self.alloc.free(entry.key_ptr.*);
            }
        }
        self.symbol_index.clearRetainingCapacity();

        for (self.files.items) |file| {
            const cached = self.inspect_cache.get(file.id) orelse continue;
            for (cached.symbols) |sym| {
                const name_copy = self.alloc.dupe(u8, sym.name) catch continue;
                const entry = IndexedSymbol{
                    .file_id = file.id,
                    .range = sym.range,
                    .kind = sym.kind,
                };
                if (self.symbol_index.getPtr(name_copy)) |list| {
                    self.alloc.free(name_copy);
                    const new_len = list.len + 1;
                    const new_list = self.alloc.realloc(list.*, new_len) catch {
                        continue;
                    };
                    new_list[new_len - 1] = entry;
                    list.* = new_list;
                } else {
                    const new_list = self.alloc.alloc(IndexedSymbol, 1) catch {
                        self.alloc.free(name_copy);
                        continue;
                    };
                    new_list[0] = entry;
                    self.symbol_index.put(name_copy, new_list) catch {
                        self.alloc.free(new_list);
                        self.alloc.free(name_copy);
                        continue;
                    };
                }
            }
        }
        self.symbol_index_dirty = false;
    }

    /// workspace/symbol lookup across all open files
    pub fn findSymbols(self: *Workspace, alloc: std.mem.Allocator, name: []const u8) ![]Location {
        if (self.symbol_index_dirty) self.rebuildSymbolIndex();
        const syms = self.symbol_index.get(name) orelse return alloc.alloc(Location, 0);
        const locations = try alloc.alloc(Location, syms.len);
        for (syms, locations) |sym, *loc| {
            const snap = self.snapshot(sym.file_id) orelse {
                alloc.free(locations);
                return error.FileNotOpen;
            };
            loc.* = .{
                .file_id = sym.file_id,
                .name = try alloc.dupe(u8, snap.name),
                .range = sym.range,
            };
        }
        return locations;
    }

    /// full compile; returns BuildResult (ok/err)
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

    /// full compile
    /// ret: detailed Analysis with artifact + diagnostics
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
                    .dependencies = try self.copyDeps(alloc, id),
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
                .symbols = try alloc.alloc(Symbol, 0),
                .dependencies = try alloc.alloc(FileId, 0),
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
                defer deinitArtifact(vm.runtime.alloc, artifact);
                const cache_artifact = try copyArtifact(self.alloc, artifact);
                errdefer deinitArtifact(self.alloc, cache_artifact);
                const cache_symbols = try copySymbols(self.alloc, symbols);
                errdefer freeSymbols(self.alloc, cache_symbols);
                try self.putCache(id, snap.version, opts, cache_artifact, cache_symbols);
                const copy = try copyArtifact(alloc, artifact);
                errdefer deinitArtifact(alloc, copy);
                break :blk .{
                    .snapshot = snap,
                    .artifact = copy,
                    .cached = false,
                    .symbols = try copySymbols(alloc, symbols),
                    .dependencies = try self.copyDeps(alloc, id),
                };
            },
            .err => |err| .{
                .snapshot = snap,
                .diagnostics = try copyError(alloc, err, snap.name, snap.text),
                .cached = false,
                .symbols = try copySymbols(alloc, symbols),
                .dependencies = try self.copyDeps(alloc, id),
            },
        };
    }

    /// convenience: open + analyze
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

    /// get diagnostics for a file (or null if clean)
    /// runs both semantic and full compile to catch all errors
    pub fn diagnostics(
        self: *Workspace,
        alloc: std.mem.Allocator,
        id: FileId,
        opts: lang.BuildOptions,
    ) !?lang.Error {
        var sem = try self.inspectDetailed(alloc, id, opts);
        errdefer sem.deinit(alloc);
        var full = self.analyzeDetailed(alloc, id, opts) catch |err| switch (err) {
            error.VmUnavailable => {
                if (sem.diagnostics) |diag| {
                    sem.diagnostics = null;
                    return diag;
                }
                return null;
            },
            else => |e| return e,
        };
        errdefer full.deinit(alloc);

        // if both have diagnostics, merge the reports
        if (full.diagnostics) |full_diag| {
            if (sem.diagnostics) |sem_diag| {
                const merged_report = try mergeReports(alloc, sem_diag, full_diag);
                // keep the error variant from the full compile, but swap the report
                // errorKind doesn't matter much for diagnostics display
                full.diagnostics = null;
                sem.diagnostics = null;
                return lang.Error{ .lower = .{ .kind = .ParseError, .report = merged_report } };
            }
            full.diagnostics = null;
            return full_diag;
        }

        if (sem.diagnostics) |diag| {
            sem.diagnostics = null;
            return diag;
        }

        return null;
    }

    /// returns syms defined in a file
    pub fn documentSymbols(
        self: *Workspace,
        alloc: std.mem.Allocator,
        id: FileId,
        opts: lang.BuildOptions,
    ) ![]Symbol {
        var analysis = try self.inspectDetailed(alloc, id, opts);
        defer analysis.deinit(alloc);
        return try copySymbols(alloc, analysis.symbols);
    }

    /// go-to-definition: find the binding that a word at `pos` refers to
    pub fn definition(
        self: *Workspace,
        alloc: std.mem.Allocator,
        id: FileId,
        pos: Position,
        opts: lang.BuildOptions,
    ) !?Location {
        var analysis = try self.inspectDetailed(alloc, id, opts);
        defer analysis.deinit(alloc);
        const snap = analysis.snapshot;
        const name = wordAtPosition(snap.text, pos) orelse return null;
        return bestLocation(self, alloc, name, id, pos, opts);
    }

    /// markdown hover: kind, type, definition source, location
    pub fn hover(
        self: *Workspace,
        alloc: std.mem.Allocator,
        id: FileId,
        pos: Position,
        opts: lang.BuildOptions,
    ) !?Hover {
        var analysis = try self.inspectDetailed(alloc, id, opts);
        defer analysis.deinit(alloc);
        const snap = analysis.snapshot;
        const name = wordAtPosition(snap.text, pos) orelse return null;

        // stdlib fallback; when name not bound in the ast
        if (try self.definition(alloc, id, pos, opts) == null) {
            if (revo.std_lib.api.find(name)) |spec| {
                var buf = std.Io.Writer.Allocating.init(alloc);
                defer buf.deinit();
                try buf.writer.writeAll("`");
                try revo.std_lib.api.renderSignature(&buf.writer, spec);
                try buf.writer.writeAll("`");
                if (spec.doc.len > 0) {
                    try buf.writer.writeAll("\n");
                    try buf.writer.writeAll(spec.doc);
                }
                const text = try buf.toOwnedSlice();
                return .{
                    .text = text,
                    .range = .{
                        .start = pos,
                        .end = .{
                            .line = pos.line,
                            .character = pos.character + @as(u32, @intCast(name.len)),
                        },
                    },
                };
            }
            return null;
        }
        const def = try self.definition(alloc, id, pos, opts) orelse return null;

        // find symbol kind and type from analysis
        var kind: []const u8 = "value";
        var type_name: []const u8 = "";
        for (analysis.symbols) |sym| {
            if (std.mem.eql(u8, sym.name, name) and
                sym.range.start.line == def.range.start.line)
            {
                kind = switch (sym.kind) {
                    .binding => "binding",
                    .function => "function",
                    .struct_type => "struct",
                    .type_alias => "type alias",
                };
                type_name = sym.type_name;
                break;
            }
        }

        // extract the definition source line
        var def_source: []const u8 = "";
        {
            var i: usize = 0;
            var cur: u32 = 1;
            while (i < snap.text.len) : (i += 1) {
                if (cur == def.range.start.line) {
                    const start = i;
                    const end = std.mem.indexOfScalarPos(u8, snap.text, i, '\n') orelse snap.text.len;
                    def_source = std.mem.trim(u8, snap.text[start..end], " \t\r");
                    break;
                }
                if (snap.text[i] == '\n') cur += 1;
            }
        }

        const text = if (type_name.len > 0)
            try std.fmt.allocPrint(alloc,
                \\**{s}** -- {s}
                \\_type: {s}_
                \\```text
                \\{s}
                \\```
                \\_at {s}:{d}:{d}_
            , .{ name, kind, type_name, def_source, def.name, def.range.start.line, def.range.start.character })
        else
            try std.fmt.allocPrint(alloc,
                \\**{s}** -- {s}
                \\```text
                \\{s}
                \\```
                \\_at {s}:{d}:{d}_
            , .{ name, kind, def_source, def.name, def.range.start.line, def.range.start.character });
        return .{
            .text = text,
            .range = def.range,
        };
    }

    /// signature help: call-site function signature with param info and doc
    pub fn signatureHelp(
        self: *Workspace,
        alloc: std.mem.Allocator,
        id: FileId,
        pos: Position,
        opts: lang.BuildOptions,
    ) !?SignatureHelp {
        const snap = self.snapshot(id) orelse return null;
        const call_info = findCallAtPosition(snap.text, pos) orelse return null;

        // stdlib fallback: name not bound in any AST
        if (try self.bestLocation(alloc, call_info.name, id, pos, opts) == null) {
            if (revo.std_lib.api.find(call_info.name)) |spec| {
                const name = try alloc.dupe(u8, spec.name);
                errdefer alloc.free(name);

                const params = try alloc.alloc(ParamInfo, spec.params.len);
                errdefer alloc.free(params);
                for (spec.params, 0..) |p, i| {
                    params[i] = .{
                        .name = try alloc.dupe(u8, p[0]),
                        .type_name = try alloc.dupe(u8, p[1]),
                    };
                }

                const ret = try alloc.dupe(u8, spec.ret);
                errdefer alloc.free(ret);

                const doc: ?[]const u8 = if (spec.doc.len > 0) try alloc.dupe(u8, spec.doc) else null;
                errdefer if (doc) |d| alloc.free(d);

                return .{
                    .name = name,
                    .params = params,
                    .return_type = ret,
                    .doc = doc,
                    .active_param = call_info.active_param,
                };
            }
            return null;
        }
        const def = try self.bestLocation(alloc, call_info.name, id, pos, opts) orelse return null;
        _ = try self.inspectDetailed(alloc, def.file_id, opts);

        const cache = self.inspect_cache.getPtr(def.file_id) orelse return null;
        const sig = cache.sig_map.get(call_info.name) orelse return null;

        const name_copy = try alloc.dupe(u8, call_info.name);
        errdefer alloc.free(name_copy);
        const params_copy = try alloc.alloc(ParamInfo, sig.params.len);
        errdefer alloc.free(params_copy);
        for (sig.params, 0..) |p, i| {
            params_copy[i] = .{
                .name = try alloc.dupe(u8, p.name),
                .type_name = try alloc.dupe(u8, p.type_name),
            };
        }
        const ret_copy = try alloc.dupe(u8, sig.return_type);
        errdefer alloc.free(ret_copy);
        const doc_copy = if (sig.doc) |d| try alloc.dupe(u8, d) else null;
        errdefer if (doc_copy) |d| alloc.free(d);

        return SignatureHelp{
            .name = name_copy,
            .params = params_copy,
            .return_type = ret_copy,
            .doc = doc_copy,
            .active_param = call_info.active_param,
        };
    }

    /// all references to a name in all dependencies
    pub fn references(
        self: *Workspace,
        alloc: std.mem.Allocator,
        id: FileId,
        pos: Position,
        opts: lang.BuildOptions,
    ) ![]Location {
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

    // quick inspection via inspect cache (no full compile)
    pub fn inspectDetailed(
        self: *Workspace,
        alloc: std.mem.Allocator,
        id: FileId,
        opts: lang.BuildOptions,
    ) !Analysis {
        const snap = self.snapshot(id) orelse return error.FileNotOpen;
        if (try self.inspectCached(alloc, snap, id, opts)) |cached| return cached;

        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();

        const parsed = try lang.parse(arena.allocator(), .{
            .name = snap.name,
            .text = snap.text,
        }, .{
            .include_default_macros = opts.include_default_macros,
        });

        if (parsed == .err) {
            return self.inspectParseError(alloc, snap, id, opts, parsed.err);
        }

        const root = parsed.ok.root;
        const symbols = try self.collectSymbolsFromParsed(root);
        errdefer freeSymbols(self.alloc, symbols);
        const deps = try self.collectDepsFromParsed(snap, root);
        errdefer self.alloc.free(deps);
        try self.updateDeps(id, deps);
        const known_globals = try getKnownGlobals(self, alloc);
        defer alloc.free(known_globals);

        // name -> type_name, populated by sem checker
        var type_map = std.StringHashMap([]const u8).init(alloc);
        defer {
            var it = type_map.iterator();
            while (it.next()) |entry| {
                alloc.free(entry.key_ptr.*);
                alloc.free(entry.value_ptr.*);
            }
            type_map.deinit();
        }

        const semantic_error = try semantic.analyze(alloc, root, snap.name, snap.text, known_globals, &type_map);
        const cache_diag = if (semantic_error) |err|
            try copyError(self.alloc, err, snap.name, snap.text)
        else
            null;
        errdefer if (cache_diag) |d| lang.deinitError(self.alloc, d);

        for (symbols) |*sym| {
            if (type_map.get(sym.name)) |t| {
                sym.type_name = try self.alloc.dupe(u8, t);
            }
        }

        // collect fn signatures from ast
        var sig_map: std.StringHashMapUnmanaged(FnSig) = .empty;
        errdefer if (sig_map.size > 0) freeSigMap(self.alloc, &sig_map);
        self.collectSigsFromParsed(root, &sig_map);

        // annotate param types from type_map where not explicitly set
        var sig_it = sig_map.iterator();
        while (sig_it.next()) |sig_entry| {
            for (sig_entry.value_ptr.params) |*p| {
                if (p.type_name.len == 0) {
                    if (type_map.get(p.name)) |t| {
                        p.type_name = try self.alloc.dupe(u8, t);
                    }
                }
            }
        }

        const cache_symbols = try copySymbols(self.alloc, symbols);
        errdefer freeSymbols(self.alloc, cache_symbols);
        const cache_deps = try self.copyDeps(self.alloc, id);
        errdefer self.alloc.free(cache_deps);
        try self.putInspectCache(id, snap.version, opts, cache_symbols, cache_deps, cache_diag, sig_map);

        defer freeSymbols(self.alloc, symbols);
        if (semantic_error) |err| {
            return .{
                .snapshot = snap,
                .diagnostics = err,
                .cached = false,
                .symbols = try copySymbols(alloc, symbols),
                .dependencies = try self.copyDeps(alloc, id),
            };
        }

        return .{
            .snapshot = snap,
            .cached = false,
            .symbols = try copySymbols(alloc, symbols),
            .dependencies = try self.copyDeps(alloc, id),
        };
    }

    /// lookup a function signature from the inspect cache for file `id`
    /// returns null if file hasn't been inspected, or name isn't in sig_map
    pub fn fnSig(self: *Workspace, alloc: std.mem.Allocator, id: FileId, name: []const u8) !?FnSig {
        _ = try self.inspectDetailed(alloc, id, .{});
        const cache = self.inspect_cache.getPtr(id) orelse return null;
        return cache.sig_map.get(name);
    }

    /// check inspect cache and return cached Analysis if valid
    fn inspectCached(
        self: *Workspace,
        alloc: std.mem.Allocator,
        snap: Snapshot,
        id: FileId,
        opts: lang.BuildOptions,
    ) !?Analysis {
        const cached = self.inspect_cache.get(id) orelse return null;
        if (cached.version != snap.version or !sameOpts(cached.opts, opts)) return null;
        const cached_diag = if (cached.diagnostics) |diag|
            try copyError(alloc, diag, snap.name, snap.text)
        else
            null;
        return Analysis{
            .snapshot = snap,
            .diagnostics = cached_diag,
            .cached = true,
            .symbols = try copySymbols(alloc, cached.symbols),
            .dependencies = try self.copyDeps(alloc, id),
        };
    }

    /// cache error state and return Analysis with diags
    fn inspectParseError(
        self: *Workspace,
        alloc: std.mem.Allocator,
        snap: Snapshot,
        id: FileId,
        opts: lang.BuildOptions,
        err: lang.ParseFailure,
    ) !Analysis {
        self.removeDeps(id);
        var report = try err.report.copy(alloc);
        report.source_name = try alloc.dupe(u8, snap.name);
        report.source = try alloc.dupe(u8, snap.text);

        const parse_error: lang.Error = .{ .parse = .{ .kind = err.kind, .report = report } };
        const cache_diag = try copyError(self.alloc, parse_error, snap.name, snap.text);
        errdefer lang.deinitError(self.alloc, cache_diag);

        const empty_syms = try self.alloc.alloc(Symbol, 0);
        errdefer self.alloc.free(empty_syms);

        const empty_deps = try self.alloc.alloc(FileId, 0);
        errdefer self.alloc.free(empty_deps);

        try self.putInspectCache(id, snap.version, opts, empty_syms, empty_deps, cache_diag, .empty);
        return .{
            .snapshot = snap,
            .diagnostics = parse_error,
            .cached = false,
            .symbols = try alloc.alloc(Symbol, 0),
            .dependencies = try alloc.alloc(FileId, 0),
        };
    }

    // store build artifact in cache
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
            freeSymbols(self.alloc, slot.symbols);
            slot.* = entry;
        } else {
            try self.cache.put(id, entry);
        }
    }

    /// invalidate a file and all its transitive dependents
    fn invalidateCache(self: *Workspace, id: FileId) void {
        var visited = std.AutoHashMap(FileId, void).init(self.alloc);
        defer visited.deinit();
        self.invalidateCacheImpl(id, &visited);
    }

    /// recursive invalidate; visited prevents cycle chokes
    fn invalidateCacheImpl(
        self: *Workspace,
        id: FileId,
        visited: *std.AutoHashMap(FileId, void),
    ) void {
        if (visited.contains(id)) return;
        visited.put(id, {}) catch return;

        if (self.cache.fetchRemove(id)) |kv| {
            deinitArtifact(self.alloc, kv.value.artifact);
            freeSymbols(self.alloc, kv.value.symbols);
        }
        if (self.inspect_cache.fetchRemove(id)) |kv| {
            freeSymbols(self.alloc, kv.value.symbols);
            self.alloc.free(kv.value.dependencies);
            if (kv.value.diagnostics) |diag| lang.deinitError(self.alloc, diag);
            if (kv.value.sig_map.size > 0) freeSigMap(self.alloc, &kv.value.sig_map);
        }

        if (self.reverse_deps.get(id)) |dependents| {
            for (dependents) |dep| self.invalidateCacheImpl(dep, visited);
        }
    }

    /// import path to an open file, checking both source dir and project root
    fn resolveOpenImport(
        self: *Workspace,
        source_name: []const u8,
        raw_path: []const u8,
        mode: lang.RunMode,
        project_root: []const u8,
    ) ?FileId {
        if (self.resolveImportPath(source_name, raw_path)) |resolved| {
            defer self.alloc.free(resolved);
            if (self.file_names.get(resolved)) |id| return id;
        }
        if (mode == .project and project_root.len > 0) {
            if (self.resolveImportPath(project_root, raw_path)) |resolved| {
                defer self.alloc.free(resolved);
                if (self.file_names.get(resolved)) |id| return id;
            }
        }
        return null;
    }

    /// resolve a relative import path to an absolute one; appends .rv if missing
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

    /// replace a file's dependency set; add/remove reverse deps as needed
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

    /// remove all deps for a file and clear reverse deps
    fn removeDeps(self: *Workspace, id: FileId) void {
        if (self.dependencies.fetchRemove(id)) |kv| {
            for (kv.value) |dep| self.removeReverseDep(dep, id) catch {};
            self.alloc.free(kv.value);
        }
    }

    /// mark `id` as a dependent of `dep`
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

    /// remove `id` from `dep`'s reverse dependency list
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
            const entry = self.files.pop() orelse unreachable;
            self.alloc.free(entry.name);
            self.alloc.free(entry.text);
        }
    }

    /// free all build and inspect caches
    fn clearCache(self: *Workspace) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            deinitArtifact(self.alloc, entry.value_ptr.artifact);
            freeSymbols(self.alloc, entry.value_ptr.symbols);
        }
        var inspect_it = self.inspect_cache.iterator();
        while (inspect_it.next()) |entry| {
            freeSymbols(self.alloc, entry.value_ptr.symbols);
            self.alloc.free(entry.value_ptr.dependencies);
            if (entry.value_ptr.diagnostics) |diag| {
                lang.deinitError(self.alloc, diag);
            }
            if (entry.value_ptr.sig_map.size > 0) freeSigMap(self.alloc, &entry.value_ptr.sig_map);
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

    fn copyDeps(self: *Workspace, alloc: std.mem.Allocator, id: FileId) ![]FileId {
        const deps = self.dependencies.get(id) orelse return alloc.alloc(FileId, 0);
        return alloc.dupe(FileId, deps);
    }

    /// store results in the inspect cache (symbols + deps + diagnostics)
    fn putInspectCache(
        self: *Workspace,
        id: FileId,
        version: u32,
        opts: lang.BuildOptions,
        symbols: []Symbol,
        dependencies: []FileId,
        diag: ?lang.Error,
        sig_map: std.StringHashMapUnmanaged(FnSig),
    ) !void {
        const entry = InspectCacheEntry{
            .version = version,
            .opts = opts,
            .symbols = symbols,
            .dependencies = dependencies,
            .diagnostics = diag,
            .sig_map = sig_map,
        };
        if (self.inspect_cache.getPtr(id)) |slot| {
            freeSymbols(self.alloc, slot.symbols);
            self.alloc.free(slot.dependencies);
            if (slot.diagnostics) |cached_d| lang.deinitError(self.alloc, cached_d);
            if (slot.sig_map.size > 0) freeSigMap(self.alloc, &slot.sig_map);
            slot.* = entry;
        } else {
            try self.inspect_cache.put(id, entry);
        }
    }

    /// transitive closure of all dependencies
    fn dependencyClosure(self: *Workspace, alloc: std.mem.Allocator, id: FileId) ![]FileId {
        var visited = std.AutoHashMap(FileId, void).init(alloc);
        defer visited.deinit();

        var out = try std.ArrayList(FileId).initCapacity(alloc, 4);
        errdefer out.deinit(alloc);

        try self.collectDependencyClosure(id, alloc, &visited, &out);
        return out.toOwnedSlice(alloc);
    }

    /// recursive deps walker; visited prevents cycles
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

    /// walk AST and collect bindings, functions, structs, type aliases
    fn collectSymbolsFromParsed(self: *Workspace, root: *lang.Node) ![]Symbol {
        var out = try std.ArrayList(Symbol).initCapacity(self.alloc, 8);
        errdefer out.deinit(self.alloc);
        var visitor = SymbolVisitor{ .alloc = self.alloc, .out = &out };
        visitor.visit(root);
        return out.toOwnedSlice(self.alloc);
    }

    /// walk AST for fn_expr bindings and populate sig_map with ParamInfo slices
    fn collectSigsFromParsed(
        self: *Workspace,
        root: *const lang.Node,
        sig_map: *std.StringHashMapUnmanaged(FnSig),
    ) void {
        var visitor = SigVisitor{
            .ws = self,
            .sig_map = sig_map,
            .alloc = self.alloc,
        };
        visitor.visit(root);
    }

    const SigVisitor = struct {
        ws: *Workspace,
        sig_map: *std.StringHashMapUnmanaged(FnSig),
        alloc: std.mem.Allocator,

        pub fn visit(self: *@This(), node: *const lang.Node) void {
            switch (node.expr) {
                .binding => |b| {
                    if (b.target.expr != .ident) return;
                    if (b.value.expr != .fn_expr) return;
                    const fn_expr = b.value.expr.fn_expr;
                    const name = b.target.expr.ident;

                    const params = self.alloc.alloc(ParamInfo, fn_expr.params.len) catch return;
                    errdefer self.alloc.free(params);
                    for (fn_expr.params, params) |src, *dst| {
                        dst.* = .{
                            .name = self.alloc.dupe(u8, src.name) catch return,
                            .type_name = if (src.type_name) |tn| switch (tn.kind) {
                                .named => |n| self.alloc.dupe(u8, n) catch return,
                                else => self.alloc.dupe(u8, @tagName(tn.kind)) catch return,
                            } else "",
                        };
                    }

                    const return_type = if (fn_expr.return_type) |rt|
                        switch (rt.kind) {
                            .named => |n| self.alloc.dupe(u8, n) catch return,
                            else => self.alloc.dupe(u8, @tagName(rt.kind)) catch return,
                        }
                    else
                        "";
                    const doc = if (fn_expr.doc) |d|
                        self.alloc.dupe(u8, d) catch return
                    else
                        null;

                    const name_owned = self.alloc.dupe(u8, name) catch return;
                    self.sig_map.put(self.alloc, name_owned, .{
                        .params = params,
                        .return_type = return_type,
                        .doc = doc,
                    }) catch return;
                },
                else => lang.ast.walkAST(@This(), self, node),
            }
        }
    };

    /// walk AST for import expressions and resolve them to FileIds
    fn collectDepsFromParsed(self: *Workspace, snap: Snapshot, root: *lang.Node) ![]FileId {
        var out = try std.ArrayList(FileId).initCapacity(self.alloc, 4);
        errdefer out.deinit(self.alloc);
        const file_entry = self.entryPtr(snap.id) catch return out.toOwnedSlice(self.alloc);
        var visitor = ImportVisitor{
            .ws = self,
            .out = &out,
            .base = snap.name,
            .mode = file_entry.mode,
            .project_root = file_entry.project_root,
            .failed = false,
        };
        visitor.visit(root);
        if (visitor.failed) return error.OutOfMemory;
        return out.toOwnedSlice(self.alloc);
    }

    /// find all occurrences of `name` in a file (text search)
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

    /// find the best (closest but before cursor) definition of `name`
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

    /// search symbols in one file for the best definition match
    fn pickBestFromFile(
        self: *Workspace,
        alloc: std.mem.Allocator,
        id: FileId,
        name: []const u8,
        pos: Position,
        opts: lang.BuildOptions,
        best: *?Location,
    ) !void {
        const snap_name = (self.snapshot(id) orelse return).name;
        var analysis = try self.inspectDetailed(alloc, id, opts);
        defer analysis.deinit(alloc);
        for (analysis.symbols) |sym| {
            if (!std.mem.eql(u8, sym.name, name)) continue;
            if (positionBefore(sym.range.start, pos)) {
                if (best.* == null or positionBefore(best.*.?.range.start, sym.range.start)) {
                    best.* = .{
                        .file_id = id,
                        .name = snap_name,
                        .range = sym.range,
                    };
                }
            }
        }
    }

    /// id -> mut *FileEntry
    fn entryPtr(self: *Workspace, id: FileId) !*FileEntry {
        const index = self.file_index.get(id) orelse return error.FileNotOpen;
        return &self.files.items[index];
    }
};

//
// helpers
//

fn sameOpts(a: lang.BuildOptions, b: lang.BuildOptions) bool {
    return a.include_default_macros == b.include_default_macros and
        a.install_debug_info == b.install_debug_info and
        a.test_mode == b.test_mode and
        a.mode == b.mode;
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

/// merge two error reports into one (all parts from both)
fn mergeReports(alloc: std.mem.Allocator, a: lang.Error, b: lang.Error) !lang.diagnostic.Report {
    const a_report = switch (a) {
        .parse => |f| f.report,
        .expand => |f| f.report,
        .lower => |f| f.report,
        .semantic => |f| f.report,
    };
    const b_report = switch (b) {
        .parse => |f| f.report,
        .expand => |f| f.report,
        .lower => |f| f.report,
        .semantic => |f| f.report,
    };
    const total = a_report.parts.len + b_report.parts.len;
    var all_parts = try std.ArrayList(lang.diagnostic.Part).initCapacity(alloc, total);
    for (a_report.parts) |p| all_parts.appendAssumeCapacity(p);
    for (b_report.parts) |p| all_parts.appendAssumeCapacity(p);
    const message = if (a_report.message.len > 0)
        try alloc.dupe(u8, a_report.message)
    else if (b_report.message.len > 0)
        try alloc.dupe(u8, b_report.message)
    else
        "";
    return .{
        .parts = try all_parts.toOwnedSlice(alloc),
        .message = message,
        .source_name = try alloc.dupe(u8, a_report.source_name orelse b_report.source_name orelse ""),
        .source = try alloc.dupe(u8, a_report.source orelse b_report.source orelse ""),
    };
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
    const dupes = try alloc.dupe(Symbol, symbols);
    for (dupes) |*s| {
        if (s.type_name.len > 0) {
            s.type_name = try alloc.dupe(u8, s.type_name);
        }
    }
    return dupes;
}

fn freeSymbols(alloc: std.mem.Allocator, symbols: []Symbol) void {
    for (symbols) |sym| {
        if (sym.type_name.len > 0) alloc.free(sym.type_name);
    }
    alloc.free(symbols);
}

fn freeSigMap(alloc: std.mem.Allocator, map: *const std.StringHashMapUnmanaged(FnSig)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        alloc.free(entry.key_ptr.*);
        for (entry.value_ptr.params) |p| {
            if (p.name.len > 0) alloc.free(p.name);
            if (p.type_name.len > 0) alloc.free(p.type_name);
        }
        alloc.free(entry.value_ptr.params);
        if (entry.value_ptr.return_type.len > 0) alloc.free(entry.value_ptr.return_type);
        if (entry.value_ptr.doc) |d| alloc.free(d);
    }
    const mut = @constCast(map);
    mut.deinit(alloc);
}

fn positionBefore(a: Position, b: Position) bool {
    return a.line < b.line or (a.line == b.line and a.character <= b.character);
}

/// get known global names from the vm
fn getKnownGlobals(ws: *Workspace, alloc: std.mem.Allocator) ![]const []const u8 {
    const vm = ws.vm orelse return &.{};
    var list = try std.ArrayList([]const u8).initCapacity(alloc, 64);
    var cit = vm.const_globals.keyIterator();
    while (cit.next()) |atom_id| {
        try list.append(alloc, vm.atomName(atom_id.*));
    }
    var git = vm.globals.iterator();
    while (git.next()) |entry| {
        try list.append(alloc, vm.atomName(entry.key_ptr.*));
    }
    return list.toOwnedSlice(alloc);
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

/// result from text scan for a call at cursor
const CallAtPos = struct {
    name: []const u8,
    active_param: u32,
};

/// TODO: botch
/// scan backward from pos to find the enclosing function call, return
/// the callee name and which argument the cursor is inside
fn findCallAtPosition(text: []const u8, pos: Position) ?CallAtPos {
    const offset = positionToOffset(text, pos) orelse return null;
    if (offset == 0 or offset > text.len) return null;

    var depth: i32 = 0;
    var i = offset;
    if (i == text.len) i -= 1;
    while (i > 0) : (i -= 1) {
        switch (text[i]) {
            ')' => depth += 1,
            '(' => {
                if (depth == 0) {
                    // found opening paren, so scan left for identifier
                    var start = i;
                    while (start > 0 and isWordChar(text[start - 1])) start -= 1;
                    if (start < i) {
                        const name = text[start..i];
                        // count commas between ( and cursor at depth 0
                        var active: u32 = 0;
                        var j = i + 1;
                        var inner_depth: i32 = 0;
                        while (j < offset) : (j += 1) {
                            switch (text[j]) {
                                '(' => inner_depth += 1,
                                ')' => inner_depth -= 1,
                                ',' => {
                                    if (inner_depth == 0) active += 1;
                                },
                                else => {},
                            }
                        }
                        return .{ .name = name, .active_param = active };
                    }
                }
                if (depth > 0) depth -= 1;
            },
            else => {},
        }
    }
    return null;
}

const SymbolVisitor = struct {
    alloc: std.mem.Allocator,
    out: *std.ArrayList(Symbol),
    in_decl: bool = false,

    pub fn visit(self: *@This(), node: *const lang.Node) void {
        switch (node.expr) {
            .decl => |d| {
                self.in_decl = true;
                defer self.in_decl = false;
                switch (d.inner.expr) {
                    .binding => |b| self.addBinding(b),
                    .struct_def => |def| self.addName(def.name, .struct_type, node.span),
                    .type_alias => |t| self.addName(t.name, .type_alias, node.span),
                    else => {},
                }
                // walkAST would re-visit d.inner; it's already handled above
            },
            .binding => |b| if (!self.in_decl) self.addBinding(b),
            .struct_def => |def| if (!self.in_decl) self.addName(def.name, .struct_type, node.span),
            .type_alias => |t| if (!self.in_decl) self.addName(t.name, .type_alias, node.span),
            else => {},
        }
        if (node.expr != .decl) lang.ast.walkAST(SymbolVisitor, self, node);
    }

    fn addBinding(self: *@This(), b: lang.ast.Binding) void {
        switch (b.target.expr) {
            .ident => |name| self.addName(name, .binding, b.target.span),
            .tuple_pattern => |items| {
                for (items) |item| {
                    if (item.expr == .ident and !lang.ast.isDiscardName(item.expr.ident))
                        self.addName(item.expr.ident, .binding, item.span);
                }
            },
            else => {},
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

//
// import visitor
//

const ImportVisitor = struct {
    ws: *Workspace,
    out: *std.ArrayList(FileId),
    base: []const u8,
    mode: lang.RunMode,
    project_root: []const u8,
    failed: bool,

    // walk the AST; collect import exprs and resolve them
    pub fn visit(self: *@This(), node: *const lang.Node) void {
        if (node.expr == .import_expr) {
            const path = node.expr.import_expr;
            const raw = switch (path.expr) {
                .string => path.expr.string,
                .multiline_string => path.expr.multiline_string,
                else => "",
            };
            if (raw.len != 0) {
                if (self.ws.resolveOpenImport(self.base, raw, self.mode, self.project_root)) |id| {
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

//
// tests
//

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
    try std.testing.expect(std.mem.indexOf(u8, hov.?.text, "int") != null);
    try std.testing.expect(std.mem.indexOf(u8, hov.?.text, "_type:") != null);
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

test "workspace diagnostics clean file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ws = try Workspace.init(alloc);
    defer ws.deinit();

    const id = try ws.open("<test>", "let x = 1\nprint(x)");
    const diag = try ws.diagnostics(alloc, id, .{});
    try std.testing.expect(diag == null);
}

test "workspace diagnostics undefined name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ws = try Workspace.init(alloc);
    defer ws.deinit();

    const id = try ws.open("<test>", "hiasdhfasduf");
    const diag = try ws.diagnostics(alloc, id, .{});
    try std.testing.expect(diag != null);
}

test "workspace stale version tracking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ws = try Workspace.init(alloc);
    defer ws.deinit();

    const id = try ws.open("<test>", "1 + 1");
    const v1 = ws.currentVersion(id).?;
    try std.testing.expectEqual(@as(u32, 1), v1);
    try std.testing.expect(!ws.isStale(id, v1));

    try ws.change(id, "1 + 2");
    try std.testing.expect(ws.isStale(id, v1));
    const v2 = ws.currentVersion(id).?;
    try std.testing.expectEqual(@as(u32, 2), v2);
    try std.testing.expect(!ws.isStale(id, v2));
}

test "workspace cross-file symbol index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ws = try Workspace.init(alloc);
    defer ws.deinit();

    // *opens two files with overlapping symbol names*
    const a = try ws.open("<a>", "const x = 1\nconst y = 2");
    const b = try ws.open("<b>", "const x = 3\nconst z = 4");

    // *populates inspect caches*
    _ = try ws.inspectDetailed(alloc, a, .{});
    _ = try ws.inspectDetailed(alloc, b, .{});

    // findSymbols works across files
    const xs = try ws.findSymbols(alloc, "x");
    defer alloc.free(xs);
    try std.testing.expectEqual(@as(usize, 2), xs.len);

    const ys = try ws.findSymbols(alloc, "y");
    defer alloc.free(ys);
    try std.testing.expectEqual(@as(usize, 1), ys.len);

    const zs = try ws.findSymbols(alloc, "z");
    defer alloc.free(zs);
    try std.testing.expectEqual(@as(usize, 1), zs.len);

    // unknown name returns empty
    const ws2 = try ws.findSymbols(alloc, "nobody");
    defer alloc.free(ws2);
    try std.testing.expectEqual(@as(usize, 0), ws2.len);

    // after change, index is rebuilt
    try ws.change(a, "const x = 10");
    _ = try ws.inspectDetailed(alloc, a, .{});
    const xs2 = try ws.findSymbols(alloc, "x");
    defer alloc.free(xs2);
    try std.testing.expectEqual(@as(usize, 2), xs2.len);
}
