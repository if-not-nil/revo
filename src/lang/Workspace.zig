const std = @import("std");

const revo = @import("revo");
const VM = revo.VM;

const lang = @import("./root.zig");
const types = lang.types;
const type_serde = @import("type_serde.zig");
const semantic = @import("semantic.zig");

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
    return_type: ?types.TypeInfo = null,
    /// pre-rendered `[T, U]` or null
    type_params_text: ?[]const u8 = null,
};

// cache for inspectDetailed (quick inspect)
const InspectCacheEntry = struct {
    version: u32,
    opts: lang.BuildOptions,
    symbols: []Symbol,
    dependencies: []FileId,
    diagnostics: ?lang.Error = null,
    sig_map: std.StringHashMapUnmanaged(FnSig) = .empty,
    /// declared name -> doc text, from the semantic pass
    docs: std.StringHashMap([]const u8),

    fn deinit(self: *InspectCacheEntry, alloc: std.mem.Allocator) void {
        if (self.sig_map.size > 0) freeSigMap(alloc, &self.sig_map);
        var dit = self.docs.iterator();
        while (dit.next()) |e| {
            alloc.free(e.key_ptr.*);
            alloc.free(e.value_ptr.*);
        }
        self.docs.deinit();
    }
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
    param,
    type_alias,
    macro,
};

pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    range: Range,
    type_name: ?types.TypeInfo = null,
    /// condensed literal values per field (`name` -> `"me"`)
    /// for value-showing hover
    /// no default so every constructor decides
    field_values: ?[]type_serde.FieldPreview,
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
    type_name: ?types.TypeInfo = null,
    optional: bool = false,
};

pub const SignatureHelp = struct {
    name: []const u8,
    params: []ParamInfo,
    return_type: ?types.TypeInfo = null,
    /// pre-rendered `[T, U]` or null; kept as text since no consumer
    /// needs the params structurally
    type_params_text: ?[]const u8 = null,
    doc: ?[]const u8,
    active_param: u32,

    pub fn deinit(self: *SignatureHelp, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        for (self.params) |*p| {
            alloc.free(p.name);
            if (p.type_name) |*ti| types.deinitType(ti, alloc);
        }
        alloc.free(self.params);
        if (self.return_type) |*ti| types.deinitType(ti, alloc);
        if (self.type_params_text) |t| alloc.free(t);
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

pub const Workspace = @This();
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

/// check if cached version is outdated
pub fn isStale(self: *Workspace, id: FileId, version: u32) bool {
    return !(self.snapshot(id).?.version == version);
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
        _ = self.snapshot(sym.file_id) orelse {
            alloc.free(locations);
            return error.FileNotOpen;
        };
        loc.* = .{
            .file_id = sym.file_id,
            .name = try alloc.dupe(u8, name),
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
        .include_stdlib_macros = opts.include_stdlib_macros,
    });

    if (parsed == .err) {
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
    const symbols = try self.collectSymbolsFromParsed(root, snap.text);
    defer freeSymbols(self.alloc, symbols);
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
            return lang.Error{ .lower = .{ .kind = .CompileError, .report = merged_report } };
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

    // params resolve for hover/definition but stay out of the outline
    var out = try std.ArrayList(Symbol).initCapacity(alloc, analysis.symbols.len);
    errdefer {
        for (out.items) |*sym| {
            alloc.free(sym.name);
            if (sym.type_name) |*ti| types.deinitType(ti, alloc);
        }
        out.deinit(alloc);
    }
    for (analysis.symbols) |sym| {
        if (sym.kind == .param) continue;
        try out.append(alloc, .{
            .name = try alloc.dupe(u8, sym.name),
            .kind = sym.kind,
            .range = sym.range,
            .type_name = if (sym.type_name) |ti| try types.clone(ti, alloc) else null,
            .field_values = if (sym.field_values) |fvs| try cloneFieldPreviews(alloc, fvs) else null,
        });
    }
    return out.toOwnedSlice(alloc);
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
            try buf.writer.writeAll("```revo\n");
            try revo.std_lib.api.renderSignature(&buf.writer, spec.*);
            try buf.writer.writeAll("\n```");
            if (spec.doc.len > 0) {
                try buf.writer.print("\n\n{s}", .{spec.doc});
            }
            const text = try buf.toOwnedSlice();
            return .{
                .text = text,
                .range = wordRangeAt(snap.text, pos) orelse .{
                    .start = pos,
                    .end = .{
                        .line = pos.line,
                        .character = pos.character + @as(u32, @intCast(name.len)),
                    },
                },
            };
        }
        //
        // member of an imported module: `mod.member` - show its definition
        if (moduleMemberAt(snap.text, pos)) |mod_name| {
            const fid = self.resolveDepId(alloc, id, mod_name) orelse id;
            const mod_syms = self.symbolsFromDep(alloc, fid) catch null;
            if (mod_syms) |ms| {
                defer freeSymbols(alloc, @constCast(ms));
                for (ms) |s| {
                    if (!std.mem.eql(u8, s.name, name)) continue;
                    const sym_tn = if (s.type_name) |ti| try type_serde.formatType(alloc, ti) else "";
                    defer if (sym_tn.len > 0) alloc.free(sym_tn);

                    const display = try renderDefinition(alloc, name, sym_tn, self, fid);
                    defer alloc.free(display);
                    var buf = std.Io.Writer.Allocating.init(alloc);
                    defer buf.deinit();

                    try buf.writer.print("```revo\n{s}\n```", .{display});
                    return .{
                        .text = try buf.toOwnedSlice(),
                        .range = wordRangeAt(snap.text, pos) orelse .{
                            .start = pos,
                            .end = .{
                                .line = pos.line,
                                .character = pos.character + @as(u32, @intCast(name.len)),
                            },
                        },
                    };
                }
            }
        }
        return null;
    }
    const def = try self.definition(alloc, id, pos, opts) orelse return null;

    // look up type in the definition file (may differ from current file)
    var type_name: []const u8 = "";
    var record_display: []const u8 = "";
    if (def.file_id == id) {
        for (analysis.symbols) |sym| {
            if (std.mem.eql(u8, sym.name, name) and
                sym.range.start.line == def.range.start.line)
            {
                type_name = if (sym.type_name) |ti| try type_serde.formatType(alloc, ti) else "";
                record_display = try renderRecordDisplay(alloc, sym);
                break;
            }
        }
    } else {
        var def_analysis = try self.inspectDetailed(alloc, def.file_id, opts);
        defer def_analysis.deinit(alloc);
        for (def_analysis.symbols) |sym| {
            if (std.mem.eql(u8, sym.name, name)) {
                type_name = if (sym.type_name) |ti| try type_serde.formatType(alloc, ti) else "";
                record_display = try renderRecordDisplay(alloc, sym);
                break;
            }
        }
    }
    defer if (type_name.len > 0) alloc.free(type_name);
    defer if (record_display.len > 0) alloc.free(record_display);

    // for import modules, show exported symbols with full signatures
    if (self.resolveDepId(alloc, id, name)) |dep_id| {
        const mod_syms = self.symbolsFromDep(alloc, dep_id) catch null;
        if (mod_syms) |ms| {
            defer freeSymbols(alloc, @constCast(ms));

            if (ms.len > 0) {
                var buf = std.Io.Writer.Allocating.init(alloc);
                defer buf.deinit();
                try buf.writer.print("module `{s}`\n\n```revo\n", .{name});

                for (ms) |s| {
                    if (try self.fnSig(alloc, dep_id, s.name) != null) {
                        const sym_tn = if (s.type_name) |ti| try type_serde.formatType(alloc, ti) else "";
                        defer if (sym_tn.len > 0) alloc.free(sym_tn);

                        const display = try renderDefinition(alloc, s.name, sym_tn, self, dep_id);
                        defer alloc.free(display);

                        try buf.writer.writeAll(display);
                    } else {
                        if (self.snapshot(dep_id)) |ss| {
                            var line = sourceLine(ss.text, s.range.start.line);
                            line = std.mem.trim(u8, line, " \t\r");
                            line = stripPub(line);
                            try buf.writer.writeAll(line);
                        } else try buf.writer.writeAll(s.name);
                    }
                    try buf.writer.writeByte('\n');
                }
                try buf.writer.writeAll("```");

                return .{
                    .text = try buf.toOwnedSlice(),
                    .range = def.range,
                };
            }
        }
    }

    var doc_text: []const u8 = "";
    if (self.inspect_cache.getPtr(def.file_id)) |cache| {
        if (cache.docs.get(name)) |d| doc_text = d;
    }
    const display = blk: {
        if (try self.fnSig(alloc, def.file_id, name) != null)
            break :blk try renderDefinition(alloc, name, type_name, self, def.file_id);
        if (record_display.len > 0) break :blk try alloc.dupe(u8, record_display);
        if (self.snapshot(def.file_id)) |ss|
            break :blk try renderBindingLine(alloc, ss.text, def.range, type_name);
        break :blk try renderDefinition(alloc, name, type_name, self, def.file_id);
    };
    defer alloc.free(display);
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();
    try buf.writer.writeAll("```revo\n");
    try buf.writer.writeAll(display);
    try buf.writer.writeAll("\n```");
    if (doc_text.len > 0) {
        try buf.writer.print("\n\n{s}", .{doc_text});
    }
    // cross-file defs: their range is meaningless in this file
    const range: Range = if (def.file_id == id)
        def.range
    else
        (wordRangeAt(snap.text, pos) orelse def.range);
    return .{
        .text = try buf.toOwnedSlice(),
        .range = range,
    };
}

/// extract a single source line by line index (1-based)
pub fn sourceLine(text: []const u8, line: u32) []const u8 {
    var pos: usize = 0;
    var cur: u32 = 1;
    while (cur < line and pos < text.len) {
        if (text[pos] == '\n') cur += 1;
        pos += 1;
    }
    const end = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
    return text[pos..end];
}

/// strip leading `pub ` from a line
fn stripPub(line: []const u8) []const u8 {
    if (std.mem.startsWith(u8, line, "pub ")) return line[4..];
    return line;
}

/// `t: {name: string = "me"}`
///
/// for record-typed bindings with known literal values
/// "" when inapplicable (caller falls back)
fn renderRecordDisplay(alloc: std.mem.Allocator, sym: Symbol) ![]const u8 {
    const ti = sym.type_name orelse return "";
    if (ti.tag != .table) return "";
    if (ti.tag.table.fields == null) return "";
    const previews = sym.field_values orelse return "";
    if (previews.len == 0) return "";

    var buf = std.Io.Writer.Allocating.init(alloc);
    errdefer buf.deinit();
    try type_serde.printType(ti, &buf.writer, .{ .values = previews });
    const record = try buf.toOwnedSlice();
    defer alloc.free(record);

    return try std.fmt.allocPrint(alloc, "{s}: {s}", .{ sym.name, record });
}

/// a value binding's source line, pub-stripped, `(type = t)` appended if
/// the inferred type isn't visible in it
fn renderBindingLine(
    alloc: std.mem.Allocator,
    text: []const u8,
    def_range: Range,
    type_name: []const u8,
) ![]const u8 {
    var line = sourceLine(text, def_range.start.line);
    line = std.mem.trim(u8, line, " \t\r");
    line = stripPub(line);
    if (type_name.len > 0 and std.mem.indexOf(u8, line, type_name) == null)
        return std.fmt.allocPrint(alloc, "{s}\n(type = {s})", .{ line, type_name });
    return alloc.dupe(u8, line);
}

/// format a definition line: fn name(p1: t1, ...) -> ret when fnSig
/// is available, otherwise just name or type_name
pub fn renderDefinition(
    alloc: std.mem.Allocator,
    name: []const u8,
    type_name: []const u8,
    ws: *Workspace,
    file_id: FileId,
) ![]const u8 {
    if (try ws.fnSig(alloc, file_id, name)) |sig| {
        var buf = std.Io.Writer.Allocating.init(alloc);
        defer buf.deinit();

        try buf.writer.print("fn {s}", .{name});
        if (sig.type_params_text) |tps| try buf.writer.writeAll(tps);
        try buf.writer.writeByte('(');

        for (sig.params, 0..) |p, i| {
            if (i > 0) try buf.writer.print(", ", .{});
            try buf.writer.writeAll(p.name);
            if (p.optional) try buf.writer.writeByte('?');
            if (p.type_name) |ti| {
                const pt = try type_serde.formatType(alloc, ti);
                defer alloc.free(pt);
                try buf.writer.print(": {s}", .{pt});
            }
        }

        try buf.writer.writeByte(')');
        if (sig.return_type) |rt| {
            const rt_str = try type_serde.formatType(alloc, rt);
            try buf.writer.print(" -> {s}", .{rt_str});
        }

        return buf.toOwnedSlice();
    }
    if (type_name.len > 0 and std.mem.startsWith(u8, type_name, "fn(")) {
        return std.fmt.allocPrint(alloc, "fn {s}{s}", .{ name, type_name[2..] });
    }
    if (type_name.len > 0)
        return alloc.dupe(u8, type_name);
    return alloc.dupe(u8, name);
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
        if (revo.std_lib.api.findFn(call_info.name)) |spec| {
            const ft = spec.type.kind.function;
            const name = try alloc.dupe(u8, spec.name);
            errdefer alloc.free(name);

            const params = try alloc.alloc(ParamInfo, ft.params.len);
            errdefer alloc.free(params);

            for (ft.params, 0..) |p, i| {
                // evalTypeExpr can return shared comptime sentinels
                const pt: ?types.TypeInfo = if (p.type_name) |tn| pt: {
                    const t = try type_serde.evalTypeExpr(type_serde.BareCtx{ .alloc = alloc }, tn);
                    break :pt try types.clone(t, alloc);
                } else null;
                params[i] = .{
                    .name = try alloc.dupe(u8, p.name),
                    .type_name = pt,
                };
            }

            const ret: ?types.TypeInfo = if (ft.return_type) |r| ret: {
                const t = try type_serde.evalTypeExpr(type_serde.BareCtx{ .alloc = alloc }, r);
                break :ret try types.clone(t, alloc);
            } else null;

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
            .type_name = if (p.type_name) |ti| try types.clone(ti, alloc) else null,
            .optional = p.optional,
        };
    }

    const ret_copy = if (sig.return_type) |rt| try types.clone(rt, alloc) else null;
    const tps_copy = if (sig.type_params_text) |t| try alloc.dupe(u8, t) else null;

    errdefer if (tps_copy) |t| alloc.free(t);
    // docs come from the semantic layer, not the sig
    const doc_copy: ?[]const u8 = if (self.inspect_cache.getPtr(def.file_id)) |dc|
        if (dc.docs.get(call_info.name)) |d| try alloc.dupe(u8, d) else null
    else
        null;
    errdefer if (doc_copy) |d| alloc.free(d);

    return SignatureHelp{
        .name = name_copy,
        .params = params_copy,
        .return_type = ret_copy,
        .type_params_text = tps_copy,
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

    self.collectReferencesInFile(alloc, id, name, &out, opts);
    const deps_it = try self.dependencyClosure(alloc, id);
    defer alloc.free(deps_it);
    for (deps_it) |dep| self.collectReferencesInFile(alloc, dep, name, &out, opts);
    return out.toOwnedSlice(alloc);
}

/// validate that the word at pos is renameable, returning its range
pub fn prepareRename(
    self: *Workspace,
    alloc: std.mem.Allocator,
    id: FileId,
    pos: Position,
    opts: lang.BuildOptions,
) !?Range {
    _ = try self.definition(alloc, id, pos, opts) orelse return null;
    const snap = self.snapshot(id) orelse return null;
    return wordRangeAt(snap.text, pos);
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

    //
    // analysis never merges manifest macros
    //
    //   their spans point into the embedded sources,
    //   so theyd comw up as weird symbols/hovers with
    //   wrong lines
    //      (expansion and lowering keep merging; completions
    //      derive the names from the same manifest sources instead)
    //
    const parsed = try lang.parse(arena.allocator(), .{
        .name = snap.name,
        .text = snap.text,
    }, .{
        .include_stdlib_macros = false,
    });

    if (parsed == .err) {
        return self.inspectParseError(alloc, snap, id, opts, parsed.err);
    }

    const root = parsed.ok.root;
    const symbols = try self.collectSymbolsFromParsed(root, snap.text);
    defer freeSymbols(self.alloc, symbols);
    const deps = try self.collectDepsFromParsed(snap, root);
    errdefer self.alloc.free(deps);
    try self.updateDeps(id, deps);
    const known_globals = try getKnownGlobals(self, alloc);
    defer alloc.free(known_globals);

    // name -> type, populated by sem checker
    var type_map = std.StringHashMap(lang.types.TypeInfo).init(alloc);
    defer {
        var it = type_map.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            lang.types.deinitType(entry.value_ptr, alloc);
        }
        type_map.deinit();
    }

    var type_annotations = std.AutoHashMap(*const lang.Node, lang.types.TypeInfo).init(alloc);
    defer {
        var it = type_annotations.iterator();
        while (it.next()) |entry| lang.types.deinitType(@constCast(entry.value_ptr), alloc);
        type_annotations.deinit();
    }

    const WorkspaceResolver = struct {
        ws: *Workspace,
        source_name: []const u8,
        mode: lang.RunMode,
        project_root: []const u8,
        fn resolve(ptr: *anyopaque, path: []const u8, a: std.mem.Allocator) ?[]const u8 {
            const s: *@This() = @ptrCast(@alignCast(ptr));
            const file_id = s.ws.resolveOpenImport(s.source_name, path, s.mode, s.project_root) orelse return null;
            const snap2 = s.ws.snapshot(file_id) orelse return null;
            return a.dupe(u8, snap2.text) catch null;
        }
    };
    const project_root = blk: {
        const entry = self.entryPtr(snap.id) catch break :blk "";
        break :blk entry.project_root;
    };
    var ws_resolver = WorkspaceResolver{
        .ws = self,
        .source_name = snap.name,
        .mode = opts.mode,
        .project_root = project_root,
    };

    var docs = std.StringHashMap([]const u8).init(self.alloc);
    errdefer {
        var dit = docs.iterator();
        while (dit.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        docs.deinit();
    }

    const semantic_error = try semantic.analyze(
        alloc,
        root,
        snap.name,
        snap.text,
        known_globals,
        &type_map,
        &type_annotations,
        &docs,
        .{ .ptr = &ws_resolver, .resolveFn = WorkspaceResolver.resolve },
    );

    const cache_diag = if (semantic_error) |err|
        try copyError(self.alloc, err, snap.name, snap.text)
    else
        null;
    errdefer if (cache_diag) |d| lang.deinitError(self.alloc, d);

    for (symbols) |*sym| {
        if (type_map.get(sym.name)) |t| {
            sym.type_name = try lang.types.clone(t, self.alloc);
        }
    }

    // collect fn signatures from ast
    var sig_map: std.StringHashMapUnmanaged(FnSig) = .empty;
    errdefer if (sig_map.size > 0) freeSigMap(self.alloc, &sig_map);
    self.collectSigsFromParsed(root, &sig_map);

    // doc strings live in the request arena; re-own them for the cache
    var cache_docs = std.StringHashMap([]const u8).init(self.alloc);
    errdefer {
        var cit = cache_docs.iterator();
        while (cit.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        cache_docs.deinit();
    }
    var doc_it = docs.iterator();
    while (doc_it.next()) |e| {
        try cache_docs.put(
            try self.alloc.dupe(u8, e.key_ptr.*),
            try self.alloc.dupe(u8, e.value_ptr.*),
        );
    }

    // annotate param and return types from type_map where not explicitly set
    var sig_it = sig_map.iterator();
    while (sig_it.next()) |sig_entry| {
        for (sig_entry.value_ptr.params) |*p| {
            if (p.type_name == null) {
                if (type_map.get(p.name)) |t| {
                    p.type_name = try types.clone(t, self.alloc);
                }
            }
        }
        if (sig_entry.value_ptr.return_type == null) {
            if (type_map.get(sig_entry.key_ptr.*)) |t| {
                if (t.tag == .function) {
                    sig_entry.value_ptr.return_type = try types.clone(t.tag.function.return_type, self.alloc);
                }
            }
        }
    }

    const cache_symbols = try copySymbols(self.alloc, symbols);
    errdefer freeSymbols(self.alloc, cache_symbols);
    const cache_deps = try self.copyDeps(self.alloc, id);
    errdefer self.alloc.free(cache_deps);
    try self.putInspectCache(id, snap.version, opts, cache_symbols, cache_deps, cache_diag, sig_map, cache_docs);

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

pub const InlayHint = struct {
    position: Position,
    label: []const u8,
    kind: enum { type, parameter },
};

/// compute type inlay hints for a range in a file
pub fn inlayHints(
    self: *Workspace,
    alloc: std.mem.Allocator,
    id: FileId,
    range: Range,
    opts: lang.BuildOptions,
) ![]InlayHint {
    var analysis = try self.inspectDetailed(alloc, id, opts);
    defer analysis.deinit(alloc);
    const snap = analysis.snapshot;

    var hints: std.ArrayList(InlayHint) = .empty;
    errdefer hints.deinit(alloc);

    for (analysis.symbols) |sym| {
        const ti = sym.type_name orelse continue;
        if (ti.tag == .any or ti.tag == .never) continue;
        if (sym.range.end.line < range.start.line or sym.range.start.line > range.end.line) continue;

        const line = sourceLine(snap.text, sym.range.start.line);

        // fn declarations get `-> ret` after the params; aliases fall
        // through to the generic `: type` hint below
        if (ti.tag == .function) {
            const decl_needle = try std.fmt.allocPrint(alloc, "fn {s}(", .{sym.name});
            defer alloc.free(decl_needle);
            if (std.mem.indexOf(u8, line, decl_needle) != null) {
                if (std.mem.indexOf(u8, line, "->") != null or ti.tag.function.return_type.tag == .any) continue;
                const ret = try type_serde.formatType(alloc, ti.tag.function.return_type);
                defer alloc.free(ret);

                var paren = sym.range.end.character;
                while (paren < line.len and line[paren] != ')') paren += 1;
                if (paren >= line.len) continue;

                try hints.append(alloc, .{
                    .position = .{ .line = sym.range.start.line, .character = paren + 1 },
                    .label = try std.fmt.allocPrint(alloc, " -> {s}", .{ret}),
                    .kind = .type,
                });
                continue;
            }
        }

        const tn = try type_serde.formatType(alloc, ti);
        defer alloc.free(tn);
        const needle = try std.fmt.allocPrint(alloc, ": {s}", .{tn});
        defer alloc.free(needle);
        if (std.mem.indexOf(u8, line, needle) != null) continue;

        try hints.append(alloc, .{
            .position = sym.range.end,
            .label = try std.fmt.allocPrint(alloc, ": {s}", .{tn}),
            .kind = .type,
        });
    }

    try appendParamHints(self, alloc, &hints, id, snap.text);

    return hints.toOwnedSlice(alloc);
}

/// local fns via the sig map, stdlib globals as fallback
const ParamHintVisitor = struct {
    ws: *Workspace,
    id: FileId,
    hints: *std.ArrayList(InlayHint),
    alloc: std.mem.Allocator,

    pub fn visit(self: *@This(), node: *const lang.Node) void {
        switch (node.expr) {
            .call => |c| if (c.callee.expr == .ident and !c.implicit_self and c.args.len > 0) {
                const names = self.paramNames(c.callee.expr.ident);
                for (c.args, 0..) |arg, i| {
                    if (i >= names.len) break;
                    self.hints.append(self.alloc, .{
                        .position = .{ .line = arg.span.line, .character = arg.span.column },
                        .label = names[i],
                        .kind = .parameter,
                    }) catch return;
                }
            },
            else => {},
        }
        lang.ast.walkAST(@This(), self, node);
    }

    fn paramNames(self: *@This(), name: []const u8) []const []const u8 {
        if (self.ws.inspect_cache.getPtr(self.id)) |cache| {
            if (cache.sig_map.get(name)) |sig| {
                var out = std.ArrayList([]const u8).empty;
                for (sig.params) |p| out.append(self.alloc, p.name) catch return &.{};
                return out.toOwnedSlice(self.alloc) catch &.{};
            }
        }

        if (revo.std_lib.api.findFn(name)) |spec| {
            var out = std.ArrayList([]const u8).empty;
            for (spec.type.kind.function.params) |p| out.append(self.alloc, p.name) catch return &.{};
            return out.toOwnedSlice(self.alloc) catch &.{};
        }
        return &.{};
    }
};

fn appendParamHints(
    ws: *Workspace,
    alloc: std.mem.Allocator,
    hints: *std.ArrayList(InlayHint),
    id: FileId,
    text: []const u8,
) !void {
    const parsed = lang.parseSourceReport(alloc, text) catch return;
    const root = switch (parsed) {
        .ok => |r| r,
        .err => return,
    };
    var visitor = ParamHintVisitor{ .ws = ws, .id = id, .hints = hints, .alloc = alloc };
    visitor.visit(root);
}

/// lookup a function signature from the inspect cache for file `id`
pub fn fnSig(self: *Workspace, alloc: std.mem.Allocator, id: FileId, name: []const u8) !?FnSig {
    _ = try self.inspectDetailed(alloc, id, .{});
    const cache = self.inspect_cache.getPtr(id) orelse return null;
    return cache.sig_map.get(name);
}

/// hover rendering for a name declared in file `id`, null if not declared there
pub fn hoverByName(
    self: *Workspace,
    alloc: std.mem.Allocator,
    id: FileId,
    name: []const u8,
) !?[]const u8 {
    _ = try self.inspectDetailed(alloc, id, .{});
    const cache = self.inspect_cache.getPtr(id) orelse return null;

    const doc = cache.docs.get(name);
    const sig = cache.sig_map.get(name);

    var sym_range: ?Range = null;
    var type_name: []const u8 = "";
    defer if (type_name.len > 0) alloc.free(type_name);
    for (cache.symbols) |sym| {
        if (!std.mem.eql(u8, sym.name, name)) continue;
        sym_range = sym.range; // last binding wins
        if (sym.type_name) |ti| {
            if (type_name.len > 0) alloc.free(type_name);
            type_name = try type_serde.formatType(alloc, ti);
        }
    }
    if (doc == null and sig == null and sym_range == null) return null;

    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();
    if (sig != null) {
        const display = try renderDefinition(alloc, name, type_name, self, id);
        defer alloc.free(display);
        try buf.writer.writeAll(display);
    } else if (sym_range) |def_range| {
        if (self.snapshot(id)) |ss| {
            const line = try renderBindingLine(alloc, ss.text, def_range, type_name);
            defer alloc.free(line);
            try buf.writer.writeAll(line);
        } else {
            try buf.writer.writeAll(name);
        }
    } else {
        try buf.writer.writeAll(name);
    }
    if (doc) |d| try buf.writer.print("\n\n{s}", .{d});
    return try buf.toOwnedSlice();
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

    try self.putInspectCache(id, snap.version, opts, empty_syms, empty_deps, cache_diag, .empty, .init(self.alloc));
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
        var e = kv.value;
        e.deinit(self.alloc);
    }

    if (self.reverse_deps.get(id)) |dependents| {
        for (dependents) |dep| self.invalidateCacheImpl(dep, visited);
    }
}

/// import path to an open file, checking both source dir and project root
pub fn resolveOpenImport(
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
) ?[]const u8 {
    const base_dir = std.fs.path.dirname(source_name) orelse ".";
    // strip leading ./ from relative paths so join produces a clean path
    var clean = raw_path;
    while (clean.len >= 2 and clean[0] == '.' and clean[1] == '/') clean = clean[2..];
    const joined = if (std.fs.path.isAbsolute(clean))
        self.alloc.dupe(u8, clean) catch return null
    else
        std.fs.path.join(self.alloc, &.{ base_dir, clean }) catch return null;
    const ext = std.fs.path.extension(joined);
    if (ext.len != 0 and isLibExtension(ext)) {
        // a shared library import is described by its sibling manifest
        const manifest = revo.extensionManifestPath(self.alloc, joined) catch {
            self.alloc.free(joined);
            return null;
        };
        self.alloc.free(joined);
        return manifest;
    }
    if (ext.len != 0) return joined;
    const with_ext = std.fmt.allocPrint(self.alloc, "{s}.rv", .{joined}) catch {
        self.alloc.free(joined);
        return null;
    };
    self.alloc.free(joined);
    return with_ext;
}

/// shared library extensions; the type interface for these is a sibling manifest
fn isLibExtension(ext: []const u8) bool {
    return std.mem.eql(u8, ext, ".so") or
        std.mem.eql(u8, ext, ".dylib") or
        std.mem.eql(u8, ext, ".dll");
}

/// given a file and the name of an import binding, return the symbols
/// exported by the imported module. relies on file stem matching the
/// auto-derived import binding name (the common case for bare imports)
pub fn importedModuleSymbols(
    self: *Workspace,
    alloc: std.mem.Allocator,
    file_id: FileId,
    name: []const u8,
) ![]const Symbol {
    const dep_id = self.resolveDepId(alloc, file_id, name) orelse return &.{};
    return self.symbolsFromDep(alloc, dep_id);
}

/// copy symbols from a resolved dep file id (caller frees)
fn symbolsFromDep(self: *Workspace, alloc: std.mem.Allocator, dep_id: FileId) ![]const Symbol {
    var dep_analysis = try self.inspectDetailed(alloc, dep_id, .{});
    defer dep_analysis.deinit(alloc);

    const src = dep_analysis.symbols;
    var out = try std.ArrayList(Symbol).initCapacity(alloc, src.len);

    // params resolve for hover/definition but are not module members;
    // without this they render their definition line as phantom members
    for (src) |s| {
        if (s.kind == .param) continue;
        try out.append(alloc, .{
            .name = try alloc.dupe(u8, s.name),
            .kind = s.kind,
            .range = s.range,
            .type_name = if (s.type_name) |ti| try types.clone(ti, alloc) else null,
            .field_values = if (s.field_values) |fvs| try cloneFieldPreviews(alloc, fvs) else null,
        });
    }
    return out.toOwnedSlice(alloc);
}

/// TODO: botch. kill commit after e6f877ea when structural tables exist
/// walk asdf of file_id looking for `const <name> = import '<path>'`
/// and return the resolved import path (caller frees)
fn findImportPathForBinding(self: *Workspace, alloc: std.mem.Allocator, file_id: FileId, name: []const u8) ?[]const u8 {
    const snap = self.snapshot(file_id) orelse return null;
    // the buffer usually ends mid-access (`mod.<cursor>`)
    //   , which never parses
    //     : retry once without the last line, where imports live
    const texts: [2][]const u8 = .{ snap.text, stripLastLine(snap.text) };
    for (texts) |text| {
        const parsed = lang.parseSourceReport(alloc, text) catch continue;
        const root = switch (parsed) {
            .ok => |n| n,
            .err => continue,
        };
        defer alloc.destroy(root);
        const result = FindImportVisitor.find(root, name) orelse continue;
        return alloc.dupe(u8, result) catch null;
    }
    return null;
}

/// text before the final newline
/// : the in-progress line cannot parse
///   , so dep lookups during completion ignore it
fn stripLastLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, text, "\r\n");
    const idx = std.mem.lastIndexOfScalar(u8, trimmed, '\n') orelse return "";
    return trimmed[0..idx];
}

const FindImportVisitor = struct {
    target: []const u8,
    result: ?[]const u8,

    fn find(root: *const lang.Node, name: []const u8) ?[]const u8 {
        var visitor = FindImportVisitor{ .target = name, .result = null };
        lang.ast.walkAST(FindImportVisitor, &visitor, root);
        return visitor.result;
    }

    pub fn visit(self: *@This(), node: *const lang.Node) void {
        if (self.result != null) return;
        if (node.expr == .decl) {
            const d = node.expr.decl;
            if (d.inner.expr == .binding) {
                const b = d.inner.expr.binding;
                if (b.target.expr == .ident and std.mem.eql(u8, b.target.expr.ident, self.target)) {
                    if (b.value.expr == .import_stmt) {
                        self.result = b.value.expr.import_stmt.path;
                    }
                }
            }
        }
        // bare `import "path"`: auto-bound name is the path stem
        if (node.expr == .import_stmt) {
            const stmt = node.expr.import_stmt;
            if (std.mem.eql(u8, autoImportName(stmt.path), self.target)) {
                self.result = stmt.path;
            }
        }
        lang.ast.walkAST(FindImportVisitor, self, node);
    }
};

/// auto-bound name for a bare `import "path"`, mirroring Parser
fn autoImportName(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".d.rv")) return path[0 .. path.len - ".d.rv".len];
    return std.fs.path.stem(path);
}

fn resolveDepId(
    self: *Workspace,
    alloc: std.mem.Allocator,
    file_id: FileId,
    mod_name: []const u8,
) ?FileId {
    const deps = self.dependencyClosure(alloc, file_id) catch return null;
    defer alloc.free(deps);
    for (deps) |dep_id| {
        const dep_snap = self.snapshot(dep_id) orelse continue;
        if (moduleFileNameMatches(dep_snap.name, mod_name)) return dep_id;
    }

    // fallback: resolve via const binding import path
    const import_path = self.findImportPathForBinding(alloc, file_id, mod_name) orelse return null;
    defer alloc.free(import_path);
    const snap = self.snapshot(file_id) orelse return null;
    const file_entry = self.entryPtr(file_id) catch return null;

    return self.resolveOpenImportOrOpen(snap.name, import_path, .project, file_entry.project_root);
}

/// resolve an import and open the file from disk if not already open, checking
/// both the source dir and project root; returns null if not found or unreadable
fn resolveOpenImportOrOpen(
    self: *Workspace,
    source_name: []const u8,
    raw_path: []const u8,
    mode: lang.RunMode,
    project_root: []const u8,
) ?FileId {
    if (self.resolveImportPath(source_name, raw_path)) |resolved| {
        defer self.alloc.free(resolved);
        if (self.file_names.get(resolved)) |id| return id;
        if (self.openFromDisk(resolved)) |id| return id;
    }
    if (mode == .project and project_root.len > 0) {
        if (self.resolveImportPath(project_root, raw_path)) |resolved| {
            defer self.alloc.free(resolved);
            if (self.file_names.get(resolved)) |id| return id;
            if (self.openFromDisk(resolved)) |id| return id;
        }
    }
    return null;
}

/// read a file from disk and open it in the workspace. requires vm with I/O.
fn openFromDisk(self: *Workspace, path: []const u8) ?FileId {
    const vm = self.vm orelse return null;
    const io = vm.runtime.io;
    const text = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        self.alloc,
        .limited(std.math.maxInt(usize)),
    ) catch return null;

    defer self.alloc.free(text);
    _ = self.open(path, text, .{}) catch return null;
    return self.file_names.get(path);
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
        if (entry.project_root.len > 0) self.alloc.free(entry.project_root);
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
        var e = entry.value_ptr.*;
        e.deinit(self.alloc);
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
    docs: std.StringHashMap([]const u8),
) !void {
    const entry = InspectCacheEntry{
        .version = version,
        .opts = opts,
        .symbols = symbols,
        .dependencies = dependencies,
        .diagnostics = diag,
        .sig_map = sig_map,
        .docs = docs,
    };
    if (self.inspect_cache.getPtr(id)) |slot| {
        freeSymbols(self.alloc, slot.symbols);
        self.alloc.free(slot.dependencies);
        if (slot.diagnostics) |cached_d| lang.deinitError(self.alloc, cached_d);
        slot.deinit(self.alloc);
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

///
/// walk ast & collect
///     bindings, functions, type aliases
///
/// full dotted macro names from stdlib manifests
///     (`uri.asdf!`, `ok?!`)
///
/// names borrow the embedded sources (static)
/// ; only the list is owned
/// . callers split scope from member
/// ; the parser caps heads at one dot.
///
fn stdlibMacroNames(self: *Workspace, arena: std.mem.Allocator) [][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    const srcs = revo.std_lib.api.macroSources(arena) catch return out.items;

    for (srcs) |src| {
        const parsed = lang.parse(arena, .{ .name = "<stdlib-macros>", .text = src }, .{ .include_stdlib_macros = false }) catch continue;
        if (parsed != .ok) continue;
        const syms = self.collectSymbolsFromParsed(parsed.ok.root, src) catch continue;
        defer freeSymbols(self.alloc, @constCast(syms));

        for (syms) |sym| {
            if (sym.kind != .macro) continue;
            const owned = arena.dupe(u8, sym.name) catch return out.items;
            out.append(arena, owned) catch return out.items;
        }
    }
    return out.items;
}

fn collectSymbolsFromParsed(self: *Workspace, root: *lang.Node, text: []const u8) ![]Symbol {
    var out = try std.ArrayList(Symbol).initCapacity(self.alloc, 8);
    errdefer out.deinit(self.alloc);
    var visitor = SymbolVisitor{ .alloc = self.alloc, .out = &out, .text = text };
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

    /// evalTypeExpr can return shared comptime sentinels or types borrowing ast
    /// sig_map can outlive both so we need deepcopy
    fn ownedType(self: *@This(), te: *const lang.ast.TypeExpr) ?types.TypeInfo {
        const t = type_serde.evalTypeExpr(type_serde.BareCtx{ .alloc = self.alloc }, te) catch return null;
        return types.clone(t, self.alloc) catch null;
    }

    fn paramInfos(self: *@This(), fn_expr: anytype) ?[]ParamInfo {
        const params = self.alloc.alloc(ParamInfo, fn_expr.params.len) catch return null;
        errdefer self.alloc.free(params);
        for (fn_expr.params, params) |src, *dst| {
            dst.* = .{
                .name = self.alloc.dupe(u8, src.name) catch return null,
                .type_name = if (src.type_name) |te| self.ownedType(te) else null,
                .optional = src.optional or src.default_value != null,
            };
        }
        return params;
    }

    pub fn visit(self: *@This(), node: *const lang.Node) void {
        switch (node.expr) {
            .type_alias => |t| {
                switch (t.type_expr.kind) {
                    .function => |f| {
                        const name = t.name;

                        const params = self.alloc.alloc(ParamInfo, f.params.len) catch return;
                        errdefer self.alloc.free(params);
                        for (f.params, params) |src, *dst| {
                            dst.* = .{
                                .name = self.alloc.dupe(u8, src.name) catch return,
                                .type_name = if (src.type_name) |te| self.ownedType(te) else null,
                                .optional = src.optional or src.default_value != null,
                            };
                        }

                        const return_type: ?types.TypeInfo = if (f.return_type) |rt| self.ownedType(rt) else null;

                        const name_owned = self.alloc.dupe(u8, name) catch return;
                        self.sig_map.put(self.alloc, name_owned, .{
                            .params = params,
                            .return_type = return_type,
                        }) catch return;
                    },
                    else => {},
                }
            },
            .binding => |b| {
                if (b.target.expr != .ident) return;
                if (b.value.expr != .fn_expr) return;
                const fn_expr = b.value.expr.fn_expr;
                const name = b.target.expr.ident;

                const params = self.paramInfos(fn_expr) orelse return;

                const name_owned = self.alloc.dupe(u8, name) catch return;
                self.sig_map.put(self.alloc, name_owned, .{
                    .params = params,
                    .return_type = null,
                    .type_params_text = formatTypeParams(self.alloc, fn_expr.type_params) catch return,
                }) catch return;
            },
            .assign_expr => |ae| {
                if (ae.value.expr != .fn_expr) return;
                const fn_expr = ae.value.expr.fn_expr;
                if (fn_expr.doc == null) return;

                const name: []const u8 = switch (ae.target.expr) {
                    .field => |f| f.name,
                    .ident => |i| i,
                    else => return,
                };

                const params = self.paramInfos(fn_expr) orelse return;

                const return_type: ?types.TypeInfo = null;
                const name_owned = self.alloc.dupe(u8, name) catch return;
                self.sig_map.put(self.alloc, name_owned, .{
                    .params = params,
                    .return_type = return_type,
                    .type_params_text = formatTypeParams(self.alloc, fn_expr.type_params) catch return,
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

/// walk AST for `.ident` nodes matching `name`
fn collectReferencesInFile(
    self: *Workspace,
    alloc: std.mem.Allocator,
    id: FileId,
    name: []const u8,
    out: *std.ArrayList(Location),
    opts: lang.BuildOptions,
) void {
    const snap = self.snapshot(id) orelse return;
    _ = opts;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const parsed = lang.parseSourceReport(arena_alloc, snap.text) catch return;
    const root = switch (parsed) {
        .ok => |r| r,
        .err => return,
    };

    var collector = IdentCollector{
        .name = name,
        .out = out,
        .alloc = alloc,
        .file_id = id,
        .snap_name = snap.name,
        .text = snap.text,
    };
    collector.visit(root);
}

const IdentCollector = struct {
    name: []const u8,
    out: *std.ArrayList(Location),
    alloc: std.mem.Allocator,
    file_id: FileId,
    snap_name: []const u8,
    text: []const u8,

    pub fn visit(self: *@This(), node: *const lang.Node) void {
        if (node.expr == .fn_expr) {
            for (node.expr.fn_expr.params) |p| {
                if (std.mem.eql(u8, p.name, self.name)) {
                    const start = offsetToPosition(self.text, p.name_span.start);
                    const end = offsetToPosition(self.text, p.name_span.end);
                    self.out.append(self.alloc, .{
                        .file_id = self.file_id,
                        .name = self.snap_name,
                        .range = .{ .start = start, .end = end },
                    }) catch {};
                }
            }
        }
        if (node.expr == .ident) {
            if (std.mem.eql(u8, node.expr.ident, self.name)) {
                const start = offsetToPosition(self.text, node.span.start);
                const end = offsetToPosition(self.text, node.span.end);
                self.out.append(self.alloc, .{
                    .file_id = self.file_id,
                    .name = self.snap_name,
                    .range = .{ .start = start, .end = end },
                }) catch {};
            }
        }
        lang.ast.walkAST(@This(), self, node);
    }
};

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

//
// helpers
//

fn sameOpts(a: lang.BuildOptions, b: lang.BuildOptions) bool {
    inline for (std.meta.fields(lang.BuildOptions)) |f| {
        if (@field(a, f.name) != @field(b, f.name)) return false;
    }
    return true;
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

/// merge two error reports into one (dedup span parts by range+message)
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
    for (b_report.parts) |p| {
        var dup = false;
        if (p == .span) {
            for (a_report.parts) |ap| {
                if (ap == .span and
                    ap.span.span.start == p.span.span.start and
                    ap.span.span.end == p.span.span.end and
                    std.mem.eql(u8, ap.span.message, p.span.message))
                {
                    dup = true;
                    break;
                }
            }
        }
        if (!dup) all_parts.appendAssumeCapacity(p);
    }
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
        s.name = try alloc.dupe(u8, s.name);
        if (s.type_name) |ti| {
            s.type_name = try types.clone(ti, alloc);
        }
        if (s.field_values) |fvs| {
            s.field_values = try cloneFieldPreviews(alloc, fvs);
        }
    }
    return dupes;
}

fn cloneFieldPreviews(alloc: std.mem.Allocator, fvs: []const type_serde.FieldPreview) ![]type_serde.FieldPreview {
    const owned = try alloc.alloc(type_serde.FieldPreview, fvs.len);
    for (fvs, owned) |fv, *dst| dst.* = .{
        .name = try alloc.dupe(u8, fv.name),
        .preview = try alloc.dupe(u8, fv.preview),
    };
    return owned;
}

fn freeSymbols(alloc: std.mem.Allocator, symbols: []Symbol) void {
    for (symbols) |*sym| {
        alloc.free(sym.name);
        if (sym.type_name) |*ti| types.deinitType(ti, alloc);
        if (sym.field_values) |fvs| {
            for (fvs) |fv| {
                alloc.free(fv.name);
                alloc.free(fv.preview);
            }
            alloc.free(fvs);
        }
    }
    alloc.free(symbols);
}

fn freeSigMap(alloc: std.mem.Allocator, map: *const std.StringHashMapUnmanaged(FnSig)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        alloc.free(entry.key_ptr.*);
        for (entry.value_ptr.params) |*p| {
            if (p.name.len > 0) alloc.free(p.name);
            if (p.type_name) |*ti| types.deinitType(ti, alloc);
        }
        alloc.free(entry.value_ptr.params);
        if (entry.value_ptr.return_type) |*rt| types.deinitType(rt, alloc);
        if (entry.value_ptr.type_params_text) |t| alloc.free(t);
    }
    const mut = @constCast(map);
    mut.deinit(alloc);
}

/// `[T, U]` or null when empty
/// caller owns the result
fn formatTypeParams(alloc: std.mem.Allocator, type_params: []const []const u8) !?[]const u8 {
    if (type_params.len == 0) return null;
    var buf = std.Io.Writer.Allocating.init(alloc);
    errdefer buf.deinit();
    try buf.writer.writeByte('[');

    for (type_params, 0..) |tp, i| {
        if (i > 0) try buf.writer.writeAll(", ");
        try buf.writer.writeAll(tp);
    }

    try buf.writer.writeByte(']');
    const owned: []const u8 = try buf.toOwnedSlice();
    return owned;
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
        try list.append(alloc, vm.stringValue(atom_id.*));
    }
    var git = vm.globals.iterator();
    while (git.next()) |entry| {
        try list.append(alloc, vm.stringValue(entry.key_ptr.*));
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
    // `?`/`!` suffix names (`exists?`) are single identifiers
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '?' or c == '!';
}

/// the whole word under pos, wherever the cursor sits inside it
fn wordRangeAt(text: []const u8, pos: Position) ?Range {
    const offset = positionToOffset(text, pos) orelse return null;
    if (offset >= text.len) return null;
    var start = offset;
    while (start > 0 and isWordChar(text[start - 1])) start -= 1;
    var end = offset;
    while (end < text.len and isWordChar(text[end])) end += 1;
    if (end <= start) return null;
    return .{
        .start = offsetToPosition(text, start),
        .end = offsetToPosition(text, end),
    };
}

/// if the word at pos is a member of an import binding (`mod.member`),
/// return the module name
fn moduleMemberAt(text: []const u8, pos: Position) ?[]const u8 {
    const offset = positionToOffset(text, pos) orelse return null;
    var start = offset;
    while (start > 0 and isWordChar(text[start - 1])) start -= 1;
    if (start >= offset) return null;
    var i = start;
    while (i > 0 and (text[i - 1] == ' ' or text[i - 1] == '\t')) i -= 1;
    if (i == 0 or text[i - 1] != '.') return null;
    i -= 1;
    while (i > 0 and (text[i - 1] == ' ' or text[i - 1] == '\t')) i -= 1;
    var mod_start = i;
    while (mod_start > 0 and isWordChar(text[mod_start - 1])) mod_start -= 1;
    if (mod_start >= i) return null;
    return text[mod_start..i];
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
    text: []const u8,
    /// a binding like `const x = import "foo"` names the module itself
    import_named: bool = false,

    pub fn visit(self: *@This(), node: *const lang.Node) void {
        switch (node.expr) {
            .binding => |b| self.addBinding(b),
            .fn_expr => |f| for (f.params) |p| self.addName(p.name, .param, p.name_span),
            .type_alias => |t| self.addName(lang.ast.bareName(t), .type_alias, t.name_span),
            // proc and template macros share the kind
            // ; node span lands on the decl start
            //   (neither carries a name span)
            // . bare member names, like type aliases: `q.macc!`
            //   in a dep file completes as `macc!` under import name
            .proc_macro => |pm| self.addName(lang.ast.bareMacroName(pm.name), .macro, node.span),
            .macro_expr => |m| self.addName(lang.ast.bareMacroName(m.name), .macro, node.span),
            .import_stmt => |is| {
                if (self.import_named) {
                    self.import_named = false;
                } else {
                    self.addName(is.name, .binding, self.importNameSpan(node, is.name));
                }
            },
            else => {},
        }
        // decls fall through - walkAST reaches every binding exactly once
        lang.ast.walkAST(SymbolVisitor, self, node);
    }

    fn addBinding(self: *@This(), b: lang.ast.Binding) void {
        self.import_named = b.value.expr == .import_stmt;
        switch (b.target.expr) {
            .ident => |name| {
                const before = self.out.items.len;
                self.addName(name, .binding, b.target.span);
                // table literals carry hover previews on the just-added
                // symbol (append-only, so a failed addName leaves len alone)
                if (b.value.expr == .table and self.out.items.len > before) {
                    if (self.tableFieldPreviews(b.value.expr.table)) |previews| {
                        self.out.items[self.out.items.len - 1].field_values = previews;
                    }
                }
            },
            .table_pattern => |items| {
                for (items) |item| {
                    if (item.expr == .ident and !lang.ast.isDiscardName(item.expr.ident))
                        self.addName(item.expr.ident, .binding, item.span);
                }
            },
            else => {},
        }
    }

    /// condensed `{k = v}` source slices for single-line literal fields;
    /// null when nothing previewable
    fn tableFieldPreviews(self: *@This(), entries: []const lang.ast.TableEntry) ?[]type_serde.FieldPreview {
        var out = std.ArrayList(type_serde.FieldPreview).initCapacity(self.alloc, entries.len) catch return null;
        var implicit_idx: u32 = 0;
        for (entries) |entry| {
            if (entry.key == null and entry.value.expr == .decl and
                entry.value.expr.decl.inner.expr == .binding and
                entry.value.expr.decl.inner.expr.binding.value.expr == .fn_expr)
                continue;

            const name = lang.ast.staticFieldName(entry);
            if (name) |n| {
                const span = entry.value.span;
                if (span.end > self.text.len or span.start > span.end) continue;
                const slice = self.text[span.start..span.end];
                if (slice.len == 0 or std.mem.indexOfScalar(u8, slice, '\n') != null) continue;

                out.append(self.alloc, .{
                    .name = self.alloc.dupe(u8, n) catch return null,
                    .preview = self.alloc.dupe(u8, slice) catch return null,
                }) catch return null;
            } else {
                const idx = implicit_idx;
                implicit_idx += 1;
                const span = entry.value.span;

                if (span.end > self.text.len or span.start > span.end) continue;
                const slice = self.text[span.start..span.end];
                if (slice.len == 0 or std.mem.indexOfScalar(u8, slice, '\n') != null) continue;

                out.append(self.alloc, .{
                    .name = std.fmt.allocPrint(self.alloc, "{d}", .{idx}) catch return null,
                    .preview = self.alloc.dupe(u8, slice) catch return null,
                }) catch return null;
            }
        }
        if (out.items.len == 0) return null;
        return out.toOwnedSlice(self.alloc) catch null;
    }

    /// module name = right after the path's opening quote; fall back to the
    /// whole statement (subdir paths, table form)
    fn importNameSpan(self: *@This(), node: *const lang.Node, name: []const u8) lang.Span {
        var q = node.span.start;
        while (q < node.span.end and self.text[q] != '\'' and self.text[q] != '"') q += 1;
        const start = q + 1;

        if (q >= node.span.end or start + name.len > node.span.end) return node.span;
        if (!std.mem.eql(u8, self.text[start .. start + name.len], name)) return node.span;
        if (start + name.len < node.span.end and isWordChar(self.text[start + name.len])) return node.span;

        var line = node.span.line;
        var column = node.span.column;
        var i = node.span.start;

        while (i < start) : (i += 1) {
            if (self.text[i] == '\n') {
                line += 1;
                column = 1;
            } else {
                column += 1;
            }
        }
        return .{ .start = start, .end = start + name.len, .line = line, .column = column };
    }

    fn addName(self: *@This(), name: []const u8, kind: SymbolKind, span: lang.Span) void {
        const owned = self.alloc.dupe(u8, name) catch return;
        self.out.append(self.alloc, .{
            .name = owned,
            .kind = kind,
            .range = .{
                .start = .{ .line = span.line, .character = @intCast(span.column) },
                .end = .{ .line = span.line, .character = @intCast(span.column + name.len) },
            },
            .field_values = null,
        }) catch {};
    }
};

fn containsId(items: []const FileId, id: FileId) bool {
    for (items) |item|
        if (item == id) return true;

    return false;
}

/// does a dep file serve as the module named `name`? plain modules match by
/// stem (`foo.rv` -> `foo`), lib manifests by `<name>.d.rv`
fn moduleFileNameMatches(snap_name: []const u8, name: []const u8) bool {
    const base = std.fs.path.basename(snap_name);
    const ext = std.fs.path.extension(snap_name);
    if (std.mem.eql(u8, std.fs.path.stem(snap_name), name)) return true;
    if (ext.len > 0 and std.mem.endsWith(u8, base, ".d.rv") and
        std.mem.eql(u8, base[0 .. base.len - 5], name)) return true;
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

    // walk the AST; collect import statements and resolve them
    pub fn visit(self: *@This(), node: *const lang.Node) void {
        if (node.expr == .import_stmt) {
            const raw = node.expr.import_stmt.path;
            if (raw.len != 0) {
                const id = self.ws.resolveOpenImport(self.base, raw, self.mode, self.project_root) orelse
                    self.ws.resolveOpenImportOrOpen(self.base, raw, self.mode, self.project_root);
                if (id) |resolved| {
                    if (!containsId(self.out.items, resolved)) {
                        self.out.append(self.ws.alloc, resolved) catch {
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
// ast span map for semantic highlighting
//

/// walk ast to build a map of byte offset -> semantic token type
pub fn buildASTSpanMap(arena: std.mem.Allocator, source: []const u8) ?std.AutoHashMap(usize, u32) {
    const parsed = lang.parseSourceReport(arena, source) catch return null;
    const root = switch (parsed) {
        .ok => |n| n,
        .err => return null,
    };
    var map = std.AutoHashMap(usize, u32).init(arena);
    walkRoles(root, &map) catch return null;
    return map;
}

fn walkRoles(n: *const lang.Node, m: *std.AutoHashMap(usize, u32)) !void {
    switch (n.expr) {
        .call => |c| {
            try walkRoles(c.callee, m);
            switch (c.callee.expr) {
                .ident => try m.put(c.callee.span.start, @intFromEnum(lang.TokenClass.function)),
                .field => |f| try m.put(c.callee.span.end - f.name.len, @intFromEnum(lang.TokenClass.function)),
                else => {},
            }
            if (c.implicit_self and c.callee.expr == .field)
                try m.put(c.callee.span.end - c.callee.expr.field.name.len - 1, @intFromEnum(lang.TokenClass.function));
            for (c.args) |a| try walkRoles(a, m);
        },
        .binding => |b| {
            if (b.target.expr == .ident)
                try m.put(b.target.span.start, if (b.value.expr == .fn_expr) @intFromEnum(lang.TokenClass.function) else @intFromEnum(lang.TokenClass.variable));
            try walkRoles(b.value, m);
        },
        .field => |f| {
            try m.put(n.span.end - f.name.len, @intFromEnum(lang.TokenClass.variable));
            try walkRoles(f.object, m);
        },
        .unary => |u| try walkRoles(u.expr, m),
        .binary => |b| {
            try walkRoles(b.left, m);
            try walkRoles(b.right, m);
        },
        .and_expr => |v| {
            try walkRoles(v.left, m);
            try walkRoles(v.right, m);
        },
        .or_expr => |v| {
            try walkRoles(v.left, m);
            try walkRoles(v.right, m);
        },
        .orelse_expr => |v| {
            try walkRoles(v.left, m);
            try walkRoles(v.right, m);
        },
        .if_expr => |v| {
            try walkRoles(v.condition, m);
            try walkRoles(v.then_expr, m);
            if (v.else_expr) |e| try walkRoles(e, m);
        },
        .unless_expr => |v| {
            try walkRoles(v.condition, m);
            try walkRoles(v.then_expr, m);
            if (v.else_expr) |e| try walkRoles(e, m);
        },
        .index => |idx| {
            try walkRoles(idx.object, m);
            try walkRoles(idx.key, m);
        },
        .return_expr => |v| {
            if (v) |e| try walkRoles(e, m);
        },
        .break_expr => |v| {
            if (v.value) |e| try walkRoles(e, m);
        },
        .match_expr => |v| {
            try walkRoles(v.subject, m);
            for (v.arms) |arm| {
                for (arm.matchers) |matcher| {
                    if (matcher == .expr) try walkRoles(matcher.expr, m);
                }
                if (arm.guard) |g| try walkRoles(g, m);
                try walkRoles(arm.then, m);
            }
        },
        .for_loop => |v| {
            try walkRoles(v.iter, m);
            try walkRoles(v.body, m);
        },
        .while_loop => |v| {
            try walkRoles(v.predicate, m);
            try walkRoles(v.body, m);
        },
        .loop_expr => |v| try walkRoles(v.body, m),
        .labeled_block => |v| try walkRoles(v.body, m),
        .range_literal => |v| {
            try walkRoles(v.start, m);
            try walkRoles(v.end, m);
        },
        .table => |entries| {
            for (entries) |e| {
                if (e.key) |k| try walkRoles(k, m);
                try walkRoles(e.value, m);
            }
        },
        .comp_block => |v| try walkRoles(v.expr, m),
        .block => |exprs| {
            for (exprs) |e| try walkRoles(e, m);
        },
        .try_expr => |inner| try walkRoles(inner, m),
        .test_block => |v| try walkRoles(v.body, m),
        .test_suite => |v| try walkRoles(v.body, m),
        .assign_expr => |a| try walkRoles(a.value, m),
        .compound_assign => |a| {
            try walkRoles(a.target, m);
            try walkRoles(a.value, m);
        },
        .decl => |d| try walkRoles(d.inner, m),
        .fn_expr => |f| try walkRoles(f.body, m),
        else => {},
    }
}

//
// completions
//

pub const CompletionKind = enum {
    keyword,
    function,
    module,
    variable,
    field,
    class,
};

pub const Completion = struct {
    label: []const u8,
    kind: CompletionKind = .variable,
    detail: ?[]const u8 = null,
    insert_text: ?[]const u8 = null,
    documentation: ?[]const u8 = null,
};

const CallSig = struct {
    detail: []const u8,
    insert_text: []const u8,
};

/// `detail` = name(p1: t1, ...) -> ret, `insert_text` = name(${1:p1}, ...)
fn callSignature(
    arena: std.mem.Allocator,
    name: []const u8,
    param_names: []const []const u8,
    param_types: []const []const u8,
    ret: ?[]const u8,
) !CallSig {
    var buf = std.Io.Writer.Allocating.init(arena);
    try buf.writer.print("{s}(", .{name});
    for (param_names, 0..) |n, i| {
        if (i > 0) try buf.writer.print(", ", .{});
        try buf.writer.print("{s}: {s}", .{ n, param_types[i] });
    }
    try buf.writer.print(")", .{});
    if (ret) |r| try buf.writer.print(" -> {s}", .{r});
    const detail = buf.written();

    if (param_names.len == 0) return .{
        .detail = detail,
        .insert_text = try std.fmt.allocPrint(arena, "{s}()", .{name}),
    };

    var sbuf = std.Io.Writer.Allocating.init(arena);
    try sbuf.writer.print("{s}(", .{name});
    for (param_names, 1..) |n, i| {
        if (i > 1) try sbuf.writer.print(", ", .{});
        try sbuf.writer.writeByte('$');
        try sbuf.writer.writeByte('{');
        try sbuf.writer.print("{d}", .{i});
        try sbuf.writer.writeByte(':');
        try sbuf.writer.print("{s}", .{n});
        try sbuf.writer.writeByte('}');
    }
    try sbuf.writer.print(")", .{});
    return .{ .detail = detail, .insert_text = sbuf.written() };
}

/// complete identifiers at cursor position in `text`
pub fn completions(
    self: *Workspace,
    arena: std.mem.Allocator,
    file_id: FileId,
    text: []const u8,
    cursor_off: usize,
) ![]Completion {
    const vm = self.vm orelse return &.{};

    // scan backward from cursor to find prefix start
    var start = cursor_off;
    while (start > 0 and lang.Lexer.isIdentContinue(text[start - 1])) start -= 1;
    const prefix = text[start..cursor_off];

    // check for '.' before the prefix (field completion)
    const dot_target = if (start > 0 and text[start - 1] == '.') blk: {
        var dot_start = start - 1;
        while (dot_start > 0 and lang.Lexer.isIdentContinue(text[dot_start - 1])) dot_start -= 1;
        break :blk text[dot_start .. start - 1];
    } else null;

    var items = try std.ArrayList(Completion).initCapacity(arena, 128);

    if (dot_target) |target| {
        try addFieldCompletions(self, vm, arena, &items, target, prefix, file_id, text, start - 1);
    } else {
        try addGeneralCompletions(self, vm, arena, &items, prefix, file_id);
    }

    return items.items;
}

/// document-local table fields for dot-completion; true when anything
/// was added (caller skips the untyped import-symbols path then)
fn localFieldCompletions(
    self: *Workspace,
    arena: std.mem.Allocator,
    items: *std.ArrayList(Completion),
    file_id: FileId,
    text: []const u8,
    dot_pos: usize,
    target: []const u8,
    prefix: []const u8,
) bool {
    const t = self.completionTargetType(arena, file_id, text, dot_pos, target) orelse return false;
    if (t.tag != .table) return false;
    const fields = t.tag.table.fields orelse return false;
    var added = false;
    for (fields) |f| {
        if (!std.mem.startsWith(u8, f.name, prefix)) continue;
        const detail = type_serde.formatType(arena, f.field_type) catch return added;
        items.append(arena, .{
            .label = f.name,
            .kind = .field,
            .detail = detail,
        }) catch return added;
        added = true;
    }
    return added;
}

/// type of a document local, analyzed from the buffer truncated before
/// the incomplete access (which never parses). dep members resolve to
/// any here; the import-symbols path covers those
fn completionTargetType(
    self: *Workspace,
    arena: std.mem.Allocator,
    file_id: FileId,
    text: []const u8,
    dot_pos: usize,
    target: []const u8,
) ?lang.types.TypeInfo {
    const snap = self.snapshot(file_id) orelse return null;
    const truncated = text[0..@min(dot_pos, text.len)];
    const parsed = lang.parse(arena, .{ .name = snap.name, .text = truncated }, .{}) catch return null;
    const root = switch (parsed) {
        .ok => |ok| ok.root,
        .err => return null,
    };
    const known_globals = getKnownGlobals(self, arena) catch return null;
    var type_map = std.StringHashMap(lang.types.TypeInfo).init(arena);
    var anchor: u8 = 0;
    _ = semantic.analyze(arena, root, snap.name, truncated, known_globals, &type_map, null, null, .{
        .ptr = @ptrCast(&anchor),
        .resolveFn = nullResolve,
    }) catch return null;
    return type_map.get(target);
}

fn nullResolve(_: *anyopaque, _: []const u8, _: std.mem.Allocator) ?[]const u8 {
    return null;
}

/// completions for fields of a table (after a dot); nested
/// receivers stay silent for now
fn addFieldCompletions(
    self: *Workspace,
    vm: *VM,
    arena: std.mem.Allocator,
    items: *std.ArrayList(Completion),
    target: []const u8,
    prefix: []const u8,
    file_id: FileId,
    text: []const u8,
    dot_pos: usize,
) !void {
    const target_atom = vm.internAtom(target) catch return;
    // stdlib modules registered as globals
    //   (string, table, math, etc.)
    //
    // : the module is its runtime table PLUS its declared surface
    // , so type-only aliases
    //      (never runtime values)
    //   complete here too
    if (vm.globals.get(target_atom)) |val| {
        if (val.tag() == .table) {
            const table = try vm.tables.get(val.asTable().?);
            var hash_it = table.hash.orderedIterator();

            while (hash_it.next()) |entry| {
                if (entry.key.tag() == .atom) {
                    const name = vm.stringValue(entry.key.asAtom().?);
                    if (std.mem.startsWith(u8, name, prefix)) {
                        var doc: ?[]const u8 = null;
                        if (revo.std_lib.api.findFn(name)) |spec| {
                            if (spec.doc.len > 0) doc = spec.doc;
                        }

                        items.append(arena, .{
                            .label = name,
                            .kind = .field,
                            .documentation = doc,
                        }) catch return;
                    }
                }
            }
            // declared members the runtime table cannot hold
            // : aliases and any fn missing at runtime
            // . `__` keys stay out
            // , they are not field accesses
            for (revo.std_lib.api.full_specs) |group| {
                for (group) |*spec| {
                    if (spec.head.kind != .module) continue;
                    if (!std.mem.eql(u8, spec.head.module.?, target)) continue;
                    if (std.mem.startsWith(u8, spec.name, "__")) continue;
                    if (!std.mem.startsWith(u8, spec.name, prefix)) continue;
                    var seen = false;

                    for (items.items) |it| {
                        if (std.mem.eql(u8, it.label, spec.name)) {
                            seen = true;
                            break;
                        }
                    }
                    if (seen) continue;

                    items.append(arena, .{
                        .label = spec.name,
                        .kind = if (spec.is_type) .class else .field,
                        .documentation = if (spec.doc.len > 0) spec.doc else null,
                    }) catch return;
                }
            }
            // manifest macros scoped to this module (`uri.asdf!`
            // completes as `asdf!` under `uri.`); globals complete bare
            // above, never qualified
            for (self.stdlibMacroNames(arena)) |name| {
                if (!std.mem.startsWith(u8, name, target)) continue;

                const rest = name[target.len..];
                if (rest.len < 2 or rest[0] != '.') continue;

                const member = rest[1..];
                if (!std.mem.startsWith(u8, member, prefix)) continue;

                items.append(arena, .{
                    .label = member,
                    .kind = .function,
                }) catch return;
            }
            return;
        }
    }
    // document locals with known table shapes; shadowing a stdlib
    // name with a table still completes stdlib members above (runtime
    // dispatches on type, not name)
    if (self.localFieldCompletions(arena, items, file_id, text, dot_pos, target, prefix)) return;
    // user-imported modules (e.g. `import "one.rv"` creates a local binding)
    const imported_syms = self.importedModuleSymbols(arena, file_id, target) catch return;
    for (imported_syms) |sym| {
        if (std.mem.startsWith(u8, sym.name, prefix)) {
            items.append(arena, .{
                .label = sym.name,
                .kind = .field,
            }) catch return;
        }
    }
}

/// completions from keywords, globals, and document symbols
fn addGeneralCompletions(
    self: *Workspace,
    vm: *VM,
    arena: std.mem.Allocator,
    items: *std.ArrayList(Completion),
    prefix: []const u8,
    file_id: FileId,
) !void {
    // keywords
    for (lang.Lexer.TokenType.of_string.keys()) |kw| {
        if (std.mem.startsWith(u8, kw, prefix)) {
            items.append(arena, .{ .label = kw, .kind = .keyword }) catch return;
        }
    }

    // manifest macros
    // , derived from the same sources the build merges
    //   (analysis parses without them by design, so names come from here
    //      instead of the inspect cache
    //      ; a few dozen lines per request is
    //      noise next to the semantic pass below)
    // . dotted names stay scoped
    //   : only bare macros complete bare
    for (self.stdlibMacroNames(arena)) |name| {
        if (std.mem.indexOfScalar(u8, name, '.') != null) continue;
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        items.append(arena, .{ .label = name, .kind = .function }) catch return;
    }

    // note:
    //   global type aliases resolve bare but don't complete here yet
    //   ; no stdlib group declares one, so there is nothing to cover
    //   . when the first lands, mirror the dot-path union below:
    //      is_type + global head as .class
    //        (values keep winning same-named collisions)

    // globals from vm (stdlib + user)
    {
        var git = vm.globals.iterator();
        while (git.next()) |entry| {
            const name = vm.stringValue(entry.key_ptr.*);
            if (!std.mem.startsWith(u8, name, prefix)) continue;
            const kind: CompletionKind = if (entry.value_ptr.tag() == .function)
                .function
            else if (entry.value_ptr.tag() == .table)
                .module
            else
                .variable;

            var insert_text: ?[]const u8 = null;
            var detail: ?[]const u8 = null;
            var doc_copy: ?[]const u8 = null;

            if (entry.value_ptr.tag() == .function) {
                // findFn skips type-only aliases, so kind is always function
                if (revo.std_lib.api.findFn(name)) |spec| {
                    doc_copy = if (spec.doc.len > 0) (arena.dupe(u8, spec.doc) catch null) else null;
                    const ft = spec.type.kind.function;
                    const names = try arena.alloc([]const u8, ft.params.len);
                    const param_types = try arena.alloc([]const u8, ft.params.len);

                    for (ft.params, 0..) |p, i| {
                        names[i] = p.name;
                        var type_buf = std.Io.Writer.Allocating.init(arena);
                        defer type_buf.deinit();
                        if (p.type_name) |tn| try type_serde.printTypeExpr(tn, &type_buf.writer);
                        if (p.variadic) try type_buf.writer.writeAll("...");
                        param_types[i] = try type_buf.toOwnedSlice();
                    }

                    const sig = try callSignature(
                        arena,
                        name,
                        names,
                        param_types,
                        if (ft.return_type) |r| blk: {
                            var ret_buf = std.Io.Writer.Allocating.init(arena);
                            defer ret_buf.deinit();
                            try type_serde.printTypeExpr(r, &ret_buf.writer);
                            break :blk try ret_buf.toOwnedSlice();
                        } else null,
                    );

                    detail = sig.detail;
                    insert_text = sig.insert_text;
                }
            }

            items.append(arena, .{
                .label = name,
                .kind = kind,
                .detail = detail,
                .insert_text = insert_text,
                .documentation = doc_copy,
            }) catch return;
        }
    }

    // document-local symbols (from inspect cache)
    {
        var analysis = self.inspectDetailed(arena, file_id, .{}) catch return;
        defer analysis.deinit(arena);
        for (analysis.symbols) |sym| {
            if (!std.mem.startsWith(u8, sym.name, prefix)) continue;
            const kind: CompletionKind = switch (sym.kind) {
                .function, .macro => .function,
                .type_alias => .class,
                .binding, .param => .variable,
            };
            // avoid exact dupes with globals (prefer local)
            var duped = false;
            var git = vm.globals.iterator();
            while (git.next()) |entry| {
                if (std.mem.eql(u8, sym.name, vm.stringValue(entry.key_ptr.*))) {
                    duped = true;
                    break;
                }
            }
            if (!duped) {
                const label = try arena.dupe(u8, sym.name);

                var insert_text: ?[]const u8 = null;
                var detail: ?[]const u8 = null;

                if (kind == .function) {
                    if (try self.fnSig(arena, file_id, sym.name)) |sig| {
                        const names = try arena.alloc([]const u8, sig.params.len);
                        const param_types = try arena.alloc([]const u8, sig.params.len);
                        for (sig.params, 0..) |p, i| {
                            names[i] = p.name;
                            param_types[i] = if (p.type_name) |ti| try type_serde.formatType(arena, ti) else "";
                        }
                        const cs = try callSignature(
                            arena,
                            sym.name,
                            names,
                            param_types,
                            if (sig.return_type) |rt| try type_serde.formatType(arena, rt) else null,
                        );
                        detail = cs.detail;
                        insert_text = cs.insert_text;
                    }
                }

                items.append(arena, .{
                    .label = label,
                    .kind = kind,
                    .detail = detail,
                    .insert_text = insert_text,
                }) catch return;
            }
        }
    }
}

//
// tests
//

test "workspace caches repeated analysis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var vm = try VM.init(.{ .alloc = alloc, .io = std.testing.io, .diag_alloc = alloc });
    defer vm.deinit();

    var ws = try Workspace.initWithVm(&vm, alloc);
    defer ws.deinit();

    const id = try ws.open("<test>", "1 + 1", .{});
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

    var vm = try VM.init(.{ .alloc = alloc, .io = std.testing.io, .diag_alloc = alloc });
    defer vm.deinit();

    var ws = try Workspace.initWithVm(&vm, alloc);
    defer ws.deinit();

    const id = try ws.open("<test>", "1 + 1", .{});
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

    var vm = try VM.init(.{ .alloc = alloc, .io = std.testing.io, .diag_alloc = alloc });
    defer vm.deinit();

    var ws = try Workspace.initWithVm(&vm, alloc);
    defer ws.deinit();

    const a = try ws.open("dir/a.rv", "1", .{});
    const b = try ws.open("dir/b.rv", "import \"a\"", .{});
    const c = try ws.open("dir/c.rv", "import \"b\"", .{});

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

    var vm = try VM.init(.{ .alloc = alloc, .io = std.testing.io, .diag_alloc = alloc });
    defer vm.deinit();

    var ws = try Workspace.initWithVm(&vm, alloc);
    defer ws.deinit();

    const id = try ws.open("<test>", "1 + 1", .{});
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
    const id = try ws.open("<test>", source, .{});
    const query_opts: lang.BuildOptions = .{
        .include_stdlib_macros = false,
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
    try std.testing.expect(std.mem.find(u8, hov.?.text, "number") != null);
    try std.testing.expect(std.mem.find(u8, hov.?.text, "```revo") != null);
}

test "workspace hover shows record field values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ws = try Workspace.init(alloc);
    defer ws.deinit();

    const source =
        \\let t = {
        \\  name = "me",
        \\}
        \\t
    ;
    const id = try ws.open("<test>", source, .{});
    const query_opts: lang.BuildOptions = .{
        .include_stdlib_macros = false,
        .install_debug_info = false,
        .test_mode = false,
    };

    var hov = try ws.hover(alloc, id, .{ .line = 4, .character = 1 }, query_opts);
    try std.testing.expect(hov != null);
    defer if (hov) |*h| h.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, hov.?.text, "{name: string = \"me\"}") != null);
}

test "workspace hover over lib import manifest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const query_opts: lang.BuildOptions = .{
        .include_stdlib_macros = false,
        .install_debug_info = false,
        .test_mode = true,
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "extension.so", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "extension.d.rv", .data =
        \\pub declare add = fn(a: number, b: number) -> number
        \\pub declare concat = fn(parts: table, sep: string) -> string
    });
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_n = try tmp.dir.realPath(std.testing.io, &dir_buf);
    const dir_path = dir_buf[0..dir_n];

    var vm = try VM.init(.{ .alloc = alloc, .io = std.testing.io, .diag_alloc = alloc });
    defer vm.deinit();
    var ws = try Workspace.initWithVm(&vm, alloc);
    defer ws.deinit();

    const script = try std.fmt.allocPrint(alloc, "{s}/app.rv", .{dir_path});
    defer alloc.free(script);
    const id = try ws.open(script,
        \\import "extension.so"
        \\print(extension.concat ({"a", "b"}, "-"))
    , .{});

    var hov = try ws.hover(alloc, id, .{ .line = 1, .character = 11 }, query_opts);
    defer if (hov) |*h| h.deinit(alloc);
    try std.testing.expect(hov != null);
    try std.testing.expect(std.mem.find(u8, hov.?.text, "module `extension`") != null);
    try std.testing.expect(std.mem.find(u8, hov.?.text, "concat") != null);
    // range covers just the module name inside the import statement
    try std.testing.expectEqual(@as(u32, 1), hov.?.range.start.line);
    try std.testing.expectEqual(@as(u32, 9), hov.?.range.start.character);
    try std.testing.expectEqual(@as(u32, 18), hov.?.range.end.character);

    var hov2 = try ws.hover(alloc, id, .{ .line = 2, .character = 22 }, query_opts);
    defer if (hov2) |*h| h.deinit(alloc);
    try std.testing.expect(hov2 != null);
    try std.testing.expect(std.mem.find(u8, hov2.?.text, "fn concat(parts: table, sep: string) -> string") != null);
    // member def lives in the manifest; the range must be the call-site word
    try std.testing.expectEqual(@as(u32, 2), hov2.?.range.start.line);
    try std.testing.expectEqual(@as(u32, 17), hov2.?.range.start.character);
    try std.testing.expectEqual(@as(u32, 23), hov2.?.range.end.character);
}

test "workspace diagnostics query" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ws = try Workspace.init(alloc);
    defer ws.deinit();

    const id = try ws.open("<test>", "const x =", .{});
    const diag = try ws.diagnostics(alloc, id, .{});
    try std.testing.expect(diag != null);
}

test "workspace diagnostics clean file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // *vm attached like the lsp does, stdlib fns come from its globals*
    var vm = try VM.init(.{ .alloc = alloc, .io = std.testing.io, .diag_alloc = alloc });
    defer vm.deinit();
    var ws = try Workspace.initWithVm(&vm, alloc);
    defer ws.deinit();

    const id = try ws.open("<test>", "let x = 1\nprint(x)", .{});
    const diag = try ws.diagnostics(alloc, id, .{});
    try std.testing.expect(diag == null);
}

test "workspace diagnostics undefined name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ws = try Workspace.init(alloc);
    defer ws.deinit();

    const id = try ws.open("<test>", "hiasdhfasduf", .{});
    const diag = try ws.diagnostics(alloc, id, .{});
    try std.testing.expect(diag != null);
}

test "workspace diagnostics warn on missing return arrow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ws = try Workspace.init(alloc);
    defer ws.deinit();

    const id = try ws.open("<test>",
        \\ fn demo() string do
        \\   "ok"
        \\ end
    , .{});
    const diag = try ws.diagnostics(alloc, id, .{});
    try std.testing.expect(diag != null);
}

test "workspace diagnostics merge semantic and lower failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ws = try Workspace.init(alloc);
    defer ws.deinit();

    const source =
        \\ type Result = {:ok, any} | {:err, atom}
        \\ fn bind(what: any, where: num) -> Result do
        \\   "ok"
        \\ end
        \\ bind(1, "hi")
    ;
    const id = try ws.open("<test>", source, .{});
    const diag = try ws.diagnostics(alloc, id, .{});
    try std.testing.expect(diag != null);

    const report = switch (diag.?) {
        .parse => |f| f.report,
        .expand => |f| f.report,
        .lower => |f| f.report,
        .semantic => |f| f.report,
    };

    var err_count: usize = 0;
    for (report.parts) |part| {
        if (part == .@"error") err_count += 1;
    }
    try std.testing.expect(err_count >= 2);
    try std.testing.expect(report.message.len != 0);
    try std.testing.expect(std.mem.find(u8, report.message, "return type") != null);
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

test "workspace cross-file symbol index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ws = try Workspace.init(alloc);
    defer ws.deinit();

    // *opens two files with overlapping symbol names*
    const a = try ws.open("<a>", "const x = 1\nconst y = 2", .{});
    const b = try ws.open("<b>", "const x = 3\nconst z = 4", .{});

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

test "workspace hover over bare fn definition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const query_opts: lang.BuildOptions = .{
        .include_stdlib_macros = false,
        .install_debug_info = false,
        .test_mode = true,
    };

    var ws = try Workspace.init(alloc);
    defer ws.deinit();

    const id = try ws.open("<test>", "let x = 42\n\nfn say_hi(name) do\n  print(\"hello \" + name)\nend\n", .{});
    _ = try ws.inspectDetailed(alloc, id, query_opts);

    var hov = try ws.hover(alloc, id, .{ .line = 3, .character = 5 }, query_opts);
    defer if (hov) |*h| h.deinit(alloc);
    try std.testing.expect(hov != null);
}

test "workspace sig map survives typed fn invalidation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ws = try Workspace.init(alloc);
    defer ws.deinit();

    const id = try ws.open("<sig>",
        \\const f = fn(x: table, y: fn(num) -> str) x
        \\type T = fn(table<int>, num) -> table<string, int>
        \\
    , .{});
    _ = try ws.inspectDetailed(alloc, id, .{});

    try ws.change(id, "const f = fn(x: table) x");
    _ = try ws.inspectDetailed(alloc, id, .{});

    const cache = ws.inspect_cache.getPtr(id) orelse return error.TestUnexpectedResult;
    const sig = cache.sig_map.get("f") orelse return error.TestUnexpectedResult;
    const p = sig.params[0].type_name.?;
    try std.testing.expect(p.tag == .table);
    try std.testing.expect(p.tag.table.key == null);
    try std.testing.expect(p.tag.table.value.*.tag == .any);
}

fn expectCompletion(items: []const Completion, label: []const u8, kind: CompletionKind) !void {
    for (items) |it| {
        if (std.mem.eql(u8, it.label, label)) {
            try std.testing.expectEqual(kind, it.kind);
            return;
        }
    }
    std.debug.print("missing completion {s}, had:", .{label});
    for (items) |it| std.debug.print(" [{s}]", .{it.label});
    std.debug.print("\n", .{});
    return error.TestUnexpectedResult;
}

test "stdlib dot completion unions runtime table w declared aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var vm = try VM.init(.{ .alloc = alloc, .io = std.testing.io, .diag_alloc = alloc });
    defer vm.deinit();
    var ws = try Workspace.initWithVm(&vm, alloc);
    defer ws.deinit();

    const text = "uri.";
    const id = try ws.open("<test>", text, .{});
    const items = try ws.completions(arena.allocator(), id, text, text.len);
    // Hi is type-only: no runtime key, only a declared spec
    try expectCompletion(items, "Hi", .class);
    // runtime members still come first without dupes
    var decodes: usize = 0;
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "decode")) decodes += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), decodes);
}

test "manifest macros complete w/o a hardcoded list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var vm = try VM.init(.{ .alloc = alloc, .io = std.testing.io, .diag_alloc = alloc });
    defer vm.deinit();
    var ws = try Workspace.initWithVm(&vm, alloc);
    defer ws.deinit();

    const text = "ok?";
    const id = try ws.open("<test>", text, .{});
    const items = try ws.completions(arena.allocator(), id, text, text.len);
    try expectCompletion(items, "ok?!", .function);

    const text2 = "pr";
    const id2 = try ws.open("<test2>", text2, .{});
    const items2 = try ws.completions(arena.allocator(), id2, text2, text2.len);
    try expectCompletion(items2, "print!", .function);
    try expectCompletion(items2, "print", .function);
}

test "imported manifest members complete by bare name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.d.rv", .data =
        \\pub type geo.Point = num
        \\pub macro geo.macc! `(%w:expr)` `%w`
    });
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_n = try tmp.dir.realPath(std.testing.io, &dir_buf);
    const dir_path = dir_buf[0..dir_n];

    var vm = try VM.init(.{ .alloc = alloc, .io = std.testing.io, .diag_alloc = alloc });
    defer vm.deinit();
    var ws = try Workspace.initWithVm(&vm, alloc);
    defer ws.deinit();

    const script = try std.fmt.allocPrint(alloc, "{s}/app.rv", .{dir_path});
    defer alloc.free(script);
    const text = "const shapes = import \"shapes.d.rv\"\nshapes.";
    const id = try ws.open(script, text, .{});
    const items = try ws.completions(arena.allocator(), id, text, text.len);
    try expectCompletion(items, "Point", .field);
    try expectCompletion(items, "macc!", .field);
}
