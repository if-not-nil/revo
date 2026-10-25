//!
//! workspace godstruct
//! this is the public api
//!
//! yes there are hella re-exports and its 100% intentional
//! dont hit "organize @import"
//!

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
parsed_cache: std.AutoHashMap(FileId, *ParsedEntry), // lazy parse per content version
query_db: query_mod.QueryDb, // content hashes, guards no-op changes
symbol_index: std.StringHashMap([]IndexedSymbol),
symbol_index_dirty: bool = true,
next_file_id: FileId = 1,

//
// types
//

pub const Snapshot = struct {
    id: FileId,
    version: u32,
    name: []const u8,
    text: []const u8,
};

pub const FileEntry = struct {
    id: FileId,
    version: u32,
    name: []u8,
    text: []u8,
    mode: pipeline.ProjectMode = .script,
    project_root: []u8 = &.{},
};

// cache for analyzeDetailed (full build)
pub const CacheEntry = struct {
    version: u32,
    opts: pipeline.BuildOptions,
    bytecode: pipeline.Bytecode,
    warnings: ?diagnostic.Report = null,
    symbols: []Symbol,
};

/// held per content version
///   arena owns the whole cst + failure report
pub const ParsedEntry = struct {
    version: u32,
    repl_mode: bool,
    arena: std.heap.ArenaAllocator,
    result: pipeline.ParseResult,
    warnings: ?diagnostic.Report = null,

    pub fn deinit(self: *ParsedEntry, alloc: std.mem.Allocator) void {
        self.arena.deinit();
        alloc.destroy(self);
    }
};

/// cached fn sig: params as name+type pairs, return type, doc
pub const FnSig = struct {
    params: []ParamInfo,
    return_type: ?types.TypeInfo = null,
    /// pre-rendered `<T, U>` or null
    type_params_text: ?[]const u8 = null,
};

// cache for inspectDetailed (quick inspect)
pub const InspectCacheEntry = struct {
    version: u32,
    opts: pipeline.BuildOptions,
    symbols: []Symbol,
    diagnostics: ?pipeline.Error = null,
    sig_map: std.StringHashMapUnmanaged(FnSig) = .empty,
    /// declared name -> doc text, from the semantic pass
    docs: std.StringHashMap([]const u8),

    pub fn deinit(self: *InspectCacheEntry, alloc: std.mem.Allocator) void {
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
    bytecode: ?pipeline.Bytecode = null,
    diagnostics: ?pipeline.Error = null,
    /// non-failing warnings; only set on success, dropped on error
    warnings: ?diagnostic.Report = null,
    cached: bool = false,
    symbols: []Symbol = &.{},
    dependencies: []FileId = &.{},

    pub fn deinit(self: *Analysis, alloc: std.mem.Allocator) void {
        if (self.bytecode) |bytecode| {
            alloc.free(bytecode.instructions);
            alloc.free(bytecode.spans);
        }
        if (self.diagnostics) |err| {
            pipeline.deinitError(err);
        }
        if (self.warnings) |*w| {
            w.deinit();
        }
        freeSymbols(alloc, self.symbols);
        alloc.free(self.dependencies);
    }
};

pub const SymbolKind = enum {
    binding,
    function,
    param,
    type_alias,
};

pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    range: Range,
    type_name: ?types.TypeInfo = null,
    /// condensed literal values per field (`name` -> `"me"`)
    /// for value-showing hover
    /// no default so every constructor decides
    field_values: ?[]type_syntax.FieldPreview,
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
    /// pre-rendered `<T, U>` or null; kept as text since no consumer
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
    mode: pipeline.ProjectMode = .script,
    project_root: []const u8 = &.{},
};

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
        .parsed_cache = std.AutoHashMap(FileId, *ParsedEntry).init(alloc),
        .query_db = query_mod.QueryDb.init(alloc),
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
    store.clearFiles(self);
    self.query_db.deinit();
    self.clearCache();
    deps_mod.clearDeps(self);
    self.files.deinit(self.alloc);
    self.file_index.deinit();
    self.file_names.deinit();
    self.dependencies.deinit();
    self.reverse_deps.deinit();
    self.cache.deinit();
    self.inspect_cache.deinit();
    self.parsed_cache.deinit();
    {
        var it = self.symbol_index.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.value_ptr.*);
            self.alloc.free(entry.key_ptr.*);
        }
    }
    self.symbol_index.deinit();
}

pub const open = store.open;

/// replace file text; invalidates caches
pub const change = store.change;

/// close file; free its memory
pub const close = store.close;

/// ret: borrow of file metadata
pub const snapshot = store.snapshot;

/// lazy parse for a file/version; parses on first use and caches the CST
pub const parsed = store.parsed;

/// check if cached version is outdated
pub const isStale = store.isStale;

pub const rebuildSymbolIndex = symbols_mod.rebuildSymbolIndex;

/// workspace/symbol lookup across all open files
pub const findSymbols = symbols_mod.findSymbols;

/// full compile; returns BuildResult (ok/err)
pub const analyze = analyze_mod.analyze;

/// full compile
/// ret: detailed Analysis with bytecode + diagnostics
pub const analyzeDetailed = analyze_mod.analyzeDetailed;

/// get diagnostics for a file (or null if clean)
/// runs both semantic and full compile to catch all errors
pub const diagnostics = analyze_mod.diagnostics;

pub const DiagnosticsBundle = struct {
    err: ?pipeline.Error = null,
    warnings: ?diagnostic.Report = null,
};

/// same as diagnostics,
/// but also lifts non-failing warnings from th full build
pub const diagnosticsWithWarnings = analyze_mod.diagnosticsWithWarnings;

/// returns syms defined in a file
pub const documentSymbols = symbols_mod.documentSymbols;

/// go-to-definition: find the binding that a word at `pos` refers to
pub const definition = defn.definition;
pub const references = defn.references;
pub const prepareRename = defn.prepareRename;
pub const bestLocation = defn.bestLocation;

/// markdown hover: kind, type, definition source, location
pub const hover = hover_mod.hover;
pub const hoverByName = hover_mod.hoverByName;
pub const renderDefinition = hover_mod.renderDefinition;
pub const signatureHelp = signature.signatureHelp;

// quick inspection via inspect cache (no full compile)
pub const inspectDetailed = analyze_mod.inspectDetailed;

/// borrowed inspect, no copies
///   ensures cache then hands back `*InspectCacheEntry`
///   borrows `self`, good til next change/close/put/invalidate
///   copy only at edge (`copySymbols`, `copyError`, `copyDeps`)
///   same guts as `inspectDetailed`, fewer recomputes
pub const ensureInspect = analyze_mod.ensureInspect;

pub const InlayHint = struct {
    position: Position,
    label: []const u8,
    kind: enum { type, parameter },
};

pub const inlayHints = inlay.inlayHints;

/// lookup a function signature from the inspect cache for file `id`
pub const fnSig = analyze_mod.fnSig;

/// opts-aware `fnSig`, same lookup
///   prefer it when you already hold `opts`
///   keeps cache from thrashing
pub const fnSigOpts = analyze_mod.fnSigOpts;

// store build bytecode in cache
pub const putCache = cache_mod.putCache;

/// invalidate a file and all its transitive dependents
pub const invalidateCache = cache_mod.invalidateCache;

/// recursive invalidate; visited prevents cycle chokes
pub const invalidateCacheImpl = cache_mod.invalidateCacheImpl;

/// import path to an open file, checking both source dir and project root
pub const resolveOpenImport = imports.resolveOpenImport;

/// given a file and the name of an import binding, return the symbols
/// exported by the imported module. relies on file stem matching the
/// auto-derived import binding name (the common case for bare imports)
pub const importedModuleSymbols = imports.importedModuleSymbols;

/// copy symbols from a resolved dep file id (caller frees)
pub const symbolsFromDep = imports.symbolsFromDep;

/// TODO: botch. kill commit after e6f877ea when structural tables exist
/// walk asdf of file_id looking for `const <name> = import '<path>'`
/// and return the resolved import path (caller frees)
pub const findImportPathForBinding = imports.findImportPathForBinding;

pub const resolveDepId = imports.resolveDepId;

/// resolve an import and open the file from disk if not already open, checking
/// both the source dir and project root; returns null if not found or unreadable
pub const resolveOpenImportOrOpen = imports.resolveOpenImportOrOpen;

/// replace a file's dependency set; add/remove reverse deps as needed
pub const updateDeps = deps_mod.updateDeps;

/// remove all deps for a file and clear reverse deps
pub const removeDeps = deps_mod.removeDeps;

/// mark `id` as a dependent of `dep`
pub const addReverseDep = deps_mod.addReverseDep;

/// remove `id` from `dep`'s reverse dependency list
pub const removeReverseDep = deps_mod.removeReverseDep;

/// free all build and inspect caches
pub const clearCache = cache_mod.clearCache;

pub const copyDeps = deps_mod.copyDeps;

/// store results in the inspect cache (symbols + deps + diagnostics)
pub const putInspectCache = cache_mod.putInspectCache;

/// transitive closure of all dependencies
pub const dependencyClosure = deps_mod.dependencyClosure;

/// recursive deps walker; visited prevents cycles
pub const collectDependencyClosure = deps_mod.collectDependencyClosure;

/// walk cst & collect
///   bindings, functions, type aliases
pub const collectSymbolsFromParsed = symbols_mod.collectSymbolsFromParsed;

/// walk cst for fn_expr bindings and populate sig_map with ParamInfo slices
pub const collectSigsFromParsed = symbols_mod.collectSigsFromParsed;

/// walk cst for import expressions and resolve them to FileIds
pub const collectDepsFromParsed = symbols_mod.collectDepsFromParsed;

/// id -> mut *FileEntry
pub const entryPtr = store.entryPtr;

//
// helpers
//

const freeSymbols = common.freeSymbols;

const freeSigMap = common.freeSigMap;

pub const CallAtPos = txt.CallAtPos;
pub const moduleMemberAt = txt.moduleMemberAt;
pub const findCallAtPosition = txt.findCallAtPosition;
pub const stripPub = txt.stripPub;

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

pub const completions = completion_mod.completions;

const std = @import("std");

const revo = @import("revo");
const VM = revo.VM;

const analyze_mod = @import("workspace/analyze.zig");
const cache_mod = @import("workspace/cache.zig");
const common = @import("workspace/common.zig");
const completion_mod = @import("workspace/completion.zig");
const defn = @import("workspace/definition.zig");
const deps_mod = @import("workspace/deps.zig");
const diagnostic = @import("diagnostic.zig");
const hover_mod = @import("workspace/hover.zig");
const imports = @import("workspace/imports.zig");
const inlay = @import("workspace/inlay.zig");
const pipeline = @import("pipeline.zig");
const query_mod = @import("workspace/query.zig");
const signature = @import("workspace/signature.zig");
const store = @import("workspace/store.zig");
const symbols_mod = @import("workspace/symbols.zig");
const txt = @import("workspace/text.zig");
const type_syntax = @import("type_syntax.zig");
const types = @import("compiler/types.zig");

pub const FileId = txt.FileId;
pub const Position = txt.Position;
pub const Range = txt.Range;
pub const Location = txt.Location;
pub const buildCstSpanMap = txt.buildCstSpanMap;
pub const cstSpanMap = analyze_mod.cstSpanMap;
pub const QueryDb = query_mod.QueryDb;
pub const hashText = query_mod.hashText;
