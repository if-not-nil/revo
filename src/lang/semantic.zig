// zlint-disable line-length
const std = @import("std");

const cst = @import("./cst.zig");
const diagnostic = @import("diagnostic.zig");
const import_types = @import("import_types.zig");
const Parser = @import("Parser.zig");
const Lexer = @import("Lexer.zig");
const revo = @import("revo");
const resmap = @import("resmap.zig");
const type_syntax = @import("type_syntax.zig");
const types_mod = @import("compiler/types.zig");

pub const Kind = enum {
    SemanticError,
};

pub const Failure = diagnostic.Diagnostic(Kind);

pub const ModuleResolver = struct {
    ptr: *anyopaque,
    resolveFn: *const fn (ptr: *anyopaque, path: []const u8, alloc: std.mem.Allocator) ?[]const u8,

    pub fn resolve(self: ModuleResolver, path: []const u8, alloc: std.mem.Allocator) ?[]const u8 {
        return self.resolveFn(self.ptr, path, alloc);
    }
};

/// known_globals are names that exist at runtime (builtins)
/// type_map , if set, is populated with name -> type_name during analysis
/// annotations, if set, intern every analyzed node into the table
/// module_resolver resolves import paths to source text
/// root must be lowered (hir.lower)
/// : paren/pipe arms below are unreachable
pub fn analyze(
    alloc: std.mem.Allocator,
    root: *const cst.CstNode,
    source_name: []const u8,
    source: []const u8,
    known_globals: []const []const u8,
    type_map: ?*std.StringHashMap(types_mod.TypeInfo),
    annotations: ?types_mod.Annotations,
    docs: ?*std.StringHashMap([]const u8),
    module_resolver: ModuleResolver,
    warnings: *?diagnostic.Report,
) !?Failure {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var checker = try SemanticChecker.init(arena_alloc, source_name, source, known_globals, type_map, annotations, docs, module_resolver);
    defer checker.deinit();

    if (warnings.*) |w| {
        if (w.parts.len > 0) try checker.warn_parts.appendSlice(arena_alloc, w.parts);
        if (checker.first_warn_code == null) checker.first_warn_code = w.code;
    }

    try checker.collectPredeclared(root);
    _ = try checker.analyzeNode(root);
    if (type_map) |tm| {
        try reparentMap([]const u8, std.StringHashMap(types_mod.TypeInfo), tm, alloc);
    }
    if (docs) |dm| try reparentDocs(dm, alloc);
    if (checker.errors.items.len == 0) {
        // warnings never fail the build; errors dominate so these drop with them
        if (checker.warn_parts.items.len > 0) {
            const wrep = try checker.finishWarnings();
            warnings.* = try wrep.copyOwned(alloc);
        }
        return null;
    }

    warnings.* = null;
    const report = try checker.finishReport();
    const copied = try report.copyOwned(alloc);
    return .{ .kind = .SemanticError, .report = copied };
}

/// string value of a literal pattern node (string or single-literal interp)
fn patternStringLit(node: *const cst.CstNode) ?[]const u8 {
    const unwrapped = cst.unwrapParen(node) orelse return null;
    switch (unwrapped.kind) {
        .string => |s| return s.tok.text,
        .interpolated => |t| {
            if (t.parts.len == 0) return "";
            return null;
        },
        else => return null,
    }
}

/// type of a literal pattern
/// , or null when the pattern is not one
fn patternLitType(pattern: *const cst.CstNode) ?types_mod.TypeInfo {
    const unwrapped = cst.unwrapParen(pattern) orelse return null;
    return switch (unwrapped.kind) {
        .atom => |a| .{ .tag = .{ .atom = a.tok.text[1..] } },
        .err => .{ .tag = .{ .atom = ":nil" } },
        .number => .{ .tag = .number },
        .string, .interpolated => .{ .tag = .string },
        else => null,
    };
}

///
/// prior pattern fires on every value cur could match
/// prior ascriptions prove nothing here, so those do nathan
fn patternSubsumes(prior: *const cst.CstNode, cur: *const cst.CstNode) bool {
    const p = cst.unwrapParen(prior) orelse return false;
    const c = cst.unwrapParen(cur) orelse return false;
    if (p.kind == .ident) return true;
    switch (p.kind) {
        .atom => |a| return c.kind == .atom and std.mem.eql(u8, cst.atomName(c.kind.atom.tok.text), cst.atomName(a.tok.text)),
        .err => return c.kind == .err,
        .number => |n| return c.kind == .number and c.kind.number.value == n.value,
        .string => |s| {
            const cs = patternStringLit(cur) orelse return false;
            return std.mem.eql(u8, cs, s.tok.text);
        },
        .interpolated => return patternStringLit(cur) != null,
        .table => |pt| {
            if (c.kind != .table) return false;
            const ct = c.kind.table;
            // only bare-vs-bare compares destructure
            var pn: usize = 0;
            for (pt.entries) |e| if (e == .bare) {
                pn += 1;
            } else return false;
            var cn: usize = 0;
            for (ct.entries) |e| if (e == .bare) {
                cn += 1;
            } else return false;
            if (pn != cn) return false;

            // heads are just element zero, no special case
            var pi: usize = 0;
            var ci: usize = 0;
            while (pi < pt.entries.len) : ({
                pi += 1;
                ci += 1;
            }) {
                if (!patternSubsumes(pt.entries[pi].bare.value, ct.entries[ci].bare.value)) return false;
            }

            return true;
        },
        else => return false,
    }
}

fn reparentMap(comptime K: type, comptime Map: type, map: *Map, alloc: std.mem.Allocator) !void {
    var keys = try std.ArrayList(K).initCapacity(alloc, map.count());
    defer keys.deinit(alloc);
    var vals = try std.ArrayList(types_mod.TypeInfo).initCapacity(alloc, map.count());
    defer vals.deinit(alloc);
    var it = map.iterator();
    while (it.next()) |entry| {
        if (comptime K == []const u8) {
            keys.appendAssumeCapacity(try alloc.dupe(u8, entry.key_ptr.*));
        } else {
            keys.appendAssumeCapacity(entry.key_ptr.*);
        }
        vals.appendAssumeCapacity(try types_mod.clone(entry.value_ptr.*, alloc));
    }
    map.clearRetainingCapacity();
    for (keys.items, vals.items) |k, v|
        try map.put(k, v);
}

/// docs point into the analysis arena; re-own keys and text for the caller
fn reparentDocs(map: *std.StringHashMap([]const u8), alloc: std.mem.Allocator) !void {
    var keys = try std.ArrayList([]const u8).initCapacity(alloc, map.count());
    defer keys.deinit(alloc);
    var vals = try std.ArrayList([]const u8).initCapacity(alloc, map.count());
    defer vals.deinit(alloc);
    var it = map.iterator();
    while (it.next()) |entry| {
        keys.appendAssumeCapacity(try alloc.dupe(u8, entry.key_ptr.*));
        vals.appendAssumeCapacity(try alloc.dupe(u8, entry.value_ptr.*));
    }
    map.clearRetainingCapacity();
    for (keys.items, vals.items) |k, v|
        try map.put(k, v);
}

const Scope = struct {
    values: std.StringHashMap(Entry),

    fn init(alloc: std.mem.Allocator) Scope {
        return .{ .values = std.StringHashMap(Entry).init(alloc) };
    }

    fn deinit(self: *Scope) void {
        self.values.deinit();
    }
};

/// a declaration's type plus doc; docs inherit through ident assignment
const Entry = struct {
    info: types_mod.TypeInfo,
    doc: ?[]const u8 = null,
};

const FnSig = types_mod.FunctionSignature;

const SemanticChecker = struct {
    alloc: std.mem.Allocator,
    source_name: []const u8,
    source: []const u8,
    errors: std.ArrayList(diagnostic.Part),
    /// code of the first error
    ///
    /// reports carry one code like they carry one message,
    /// for per-error codes u need to refactor the Diagnostic struct
    first_code: ?[]const u8 = null,
    /// code of the first warning, same first-wins as abve
    first_warn_code: ?[]const u8 = null,
    /// non-failing diagnostics; emitted alongside success, dropped on error
    warn_parts: std.ArrayList(diagnostic.Part),
    scopes: std.ArrayList(Scope),
    type_aliases: std.StringHashMap(types_mod.Alias),
    /// caller-owned out-map: declared name -> doc text, last declare wins
    docs: ?*std.StringHashMap([]const u8),
    /// one sig per baselib spec, keyed by the spec's const-storage address
    sig_cache: std.AutoHashMap(*const revo.baselib.specs.FnSpec, *const FnSig),
    return_types: std.ArrayList(types_mod.TypeInfo),
    type_map: ?*std.StringHashMap(types_mod.TypeInfo),
    annotations: ?types_mod.Annotations,
    typed_names: std.StringHashMap(void),
    table_field_map: std.StringHashMap(std.StringHashMap(types_mod.TypeInfo)),
    /// idents assigned inside fn bodies
    /// the closure may run anywhere, so their table shapes are no longer fully known
    /// (never cleared; may miss flags, never false-flags)
    escaped: std.StringHashMap(void),
    /// vm globals, module field resolution only applies to these so a
    /// local binding named `fs` shadows the baselib module
    known_globals: std.StringHashMap(void),
    /// known globals rebound by user code (shadowed by a local binding)
    shadowed_globals: std.StringHashMap(void),
    /// toplevel fn bindings only, so a fn may call a sibling defined below it
    /// (via `resmap.predeclFn`); plain values stay order dependent instead
    predeclared: std.StringHashMapUnmanaged(void) = .empty,
    current_type_params: []const []const u8 = &.{},
    /// > 0 while inside a fn body; gates type_map/docs exports
    fn_nesting: usize = 0,
    resolver: ModuleResolver,
    /// module name -> pub type aliases, for `a.T` annotations
    import_aliases: std.StringHashMap(std.StringHashMap(types_mod.TypeInfo)),
    /// import path -> parsed dep CST, filled on first use
    dep_csts: std.StringHashMapUnmanaged(*const cst.CstNode) = .empty,

    fn init(
        alloc: std.mem.Allocator,
        source_name: []const u8,
        source: []const u8,
        known_globals: []const []const u8,
        type_map: ?*std.StringHashMap(types_mod.TypeInfo),
        annotations: ?types_mod.Annotations,
        docs: ?*std.StringHashMap([]const u8),
        resolver: ModuleResolver,
    ) !SemanticChecker {
        var checker: SemanticChecker = .{
            .alloc = alloc,
            .source_name = source_name,
            .source = source,
            .errors = try .initCapacity(alloc, 8),
            .warn_parts = try .initCapacity(alloc, 4),
            .scopes = try .initCapacity(alloc, 4),
            .type_aliases = .init(alloc),
            .docs = docs,
            .sig_cache = .init(alloc),
            .return_types = try .initCapacity(alloc, 4),
            .type_map = type_map,
            .annotations = annotations,
            .typed_names = .init(alloc),
            .table_field_map = .init(alloc),
            .escaped = .init(alloc),
            .known_globals = .init(alloc),
            .shadowed_globals = .init(alloc),
            .resolver = resolver,
            .import_aliases = .init(alloc),
            .dep_csts = .empty,
        };

        try checker.scopes.append(checker.alloc, Scope.init(checker.alloc));
        // builtins never export to type_map/docs - real declarations must
        // win, and repl runtime globals re-enter here untyped
        for (known_globals) |name|
            try checker.declareBuiltin(name);
        for (known_globals) |name|
            try checker.known_globals.put(name, {});

        // registers baselib function types
        for (known_globals) |name| {
            const spec = find_global: {
                for (revo.baselib.specs.full_specs) |group| for (group) |*s| {
                    if (s.is_type) continue;
                    if (!std.mem.eql(u8, s.name, name)) continue;
                    if (s.head.kind == .global) break :find_global s;
                };
                break :find_global null;
            } orelse continue;
            if (try checker.makeStdlibSig(spec)) |sig| {
                try checker.scopes.items[checker.scopes.items.len - 1].values.put(name, .{ .info = .{ .tag = .{ .function = sig } } });
            }
        }

        for (revo.baselib.specs.full_specs) |group| {
            for (group) |*s| {
                if (!s.is_type) continue;
                const t = checker.evalCheckedTypeExpr(s.type) catch types_mod.TypeInfo{ .tag = .any };
                // aliases live where values live
                // : module heads seed the per-module table
                //   (`uri.Hi`, docs ride on the spec), bare names seed globals
                if (s.head.kind == .namespaced) {
                    const gop = try checker.import_aliases.getOrPut(s.head.module.?);
                    if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap(types_mod.TypeInfo).init(checker.alloc);
                    try gop.value_ptr.put(s.name, t);
                } else {
                    const entry: types_mod.Alias = .{ .info = t, .doc = if (s.doc.len > 0) s.doc else null };
                    try checker.type_aliases.put(s.name, entry);
                }
            }
        }

        return checker;
    }

    fn deinit(self: *SemanticChecker) void {
        for (self.scopes.items) |*scope| scope.deinit();
        self.scopes.deinit(self.alloc);
        self.predeclared.deinit(self.alloc);
        self.dep_csts.deinit(self.alloc);
    }

    /// collect top-level fn names so forward references between them don't
    /// read as unknown names (via `resmap.predeclFn`)
    fn collectPredeclared(self: *SemanticChecker, root: *const cst.CstNode) !void {
        const items: []const *const cst.CstNode = cst.blockStmts(root) orelse return;

        for (items) |item| {
            const pre = resmap.predeclFn(item) orelse continue;
            try self.predeclared.put(self.alloc, pre.name, {});
        }
    }

    /// dep file cst for an import path, null when unresolvable
    ///
    /// import arm builds a record type from it on demand
    /// ; parsed once per path, reused for later references
    fn resolveDepCst(self: *SemanticChecker, path: []const u8) ?*const cst.CstNode {
        if (self.dep_csts.get(path)) |root| return root;

        const source_alloc = self.resolver.resolve(path, self.alloc) orelse return null;
        defer self.alloc.free(source_alloc);

        const source = self.alloc.dupe(u8, source_alloc) catch return null;
        const root = Parser.parseSource(self.alloc, source, .{}) catch return null;
        self.dep_csts.put(self.alloc, path, root) catch return root;
        return root;
    }

    fn finishReport(self: *SemanticChecker) !diagnostic.Report {
        const parts = try self.errors.toOwnedSlice(self.alloc);
        const first_msg = for (parts) |p| {
            if (p == .@"error") break p.@"error";
        } else "";

        return .{
            .parts = parts,
            .message = if (first_msg.len > 0) try self.alloc.dupe(u8, first_msg) else "",
            .code = self.first_code,
            .source_name = try self.alloc.dupe(u8, self.source_name),
            .source = try self.alloc.dupe(u8, self.source),
        };
    }

    fn finishWarnings(self: *SemanticChecker) !diagnostic.Report {
        const parts = try self.warn_parts.toOwnedSlice(self.alloc);
        const first_msg = for (parts) |p| {
            if (p == .warn) break p.warn;
        } else "";

        return .{
            .parts = parts,
            .message = if (first_msg.len > 0) try self.alloc.dupe(u8, first_msg) else "",
            .severity = .warning,
            .code = self.first_warn_code,
            .source_name = try self.alloc.dupe(u8, self.source_name),
            .source = try self.alloc.dupe(u8, self.source),
        };
    }

    fn pushScope(self: *SemanticChecker) !void {
        try self.scopes.append(self.alloc, Scope.init(self.alloc));
    }

    fn popScope(self: *SemanticChecker) void {
        _ = self.scopes.pop();
    }

    fn declare(self: *SemanticChecker, name: []const u8, t: types_mod.TypeInfo, doc: ?[]const u8) !void {
        return self.declareInner(name, t, doc, true);
    }

    /// scope-only registration; never exports to type_map/docs
    fn declareBuiltin(self: *SemanticChecker, name: []const u8) !void {
        return self.declareInner(name, .{ .tag = .any }, null, false);
    }

    /// a declaration that lands on a name already in reach
    /// , newest wins silently, rarely meant, so say so, binding/param sites only
    fn warnShadow(self: *SemanticChecker, name: []const u8, span: Lexer.Span) !void {
        if (cst.isDiscardName(name)) return;
        // scope 0 holds the seeded baselib globals; shadowing one of those
        // is a normal thing to do, only warn once we are inside the file
        if (self.scopes.items.len <= 1) return;
        const here = self.scopes.items[self.scopes.items.len - 1].values;
        if (here.contains(name)) {
            try self.appendWarn(
                try self.alloc.print("`{s}` is already declared in this scope", .{name}),
                span,
                try self.alloc.dupe(u8, "already declared"),
                "duplicate-declaration",
            );
            return;
        }
        var i = self.scopes.items.len - 1;
        while (i > 1) {
            i -= 1;
            if (!self.scopes.items[i].values.contains(name)) continue;
            try self.appendWarn(
                try self.alloc.print("`{s}` shadows an outer binding", .{name}),
                span,
                try self.alloc.dupe(u8, "shadows outer binding"),
                "shadowed-binding",
            );
            return;
        }
    }

    fn declareInner(self: *SemanticChecker, name: []const u8, t: types_mod.TypeInfo, doc: ?[]const u8, export_type: bool) !void {
        if (self.scopes.items.len == 0) try self.pushScope();
        try self.scopes.items[self.scopes.items.len - 1].values.put(name, .{ .info = t, .doc = doc });
        if (self.known_globals.contains(name)) {
            try self.shadowed_globals.put(name, {});
        }

        // module surface: top-level re-declarations shadow (newest wins);
        // fn-local bindings only fill names the surface doesn't have yet
        if (export_type) {
            if (self.type_map) |tm| {
                if (self.fn_nesting == 0) {
                    if (tm.contains(name)) _ = tm.remove(name);
                    try tm.put(try self.alloc.dupe(u8, name), t);
                } else if (!tm.contains(name)) {
                    try tm.put(try self.alloc.dupe(u8, name), t);
                }
            }
            if (self.fn_nesting == 0) {
                if (doc) |d| {
                    if (self.docs) |dm| {
                        const key = try self.alloc.dupe(u8, name);
                        errdefer self.alloc.free(key);
                        try dm.put(key, d);
                    }
                }
            }
        }
    }

    fn lookup(self: *SemanticChecker, name: []const u8) ?types_mod.TypeInfo {
        return if (self.lookupEntry(name)) |e| e.info else null;
    }

    fn lookupEntry(self: *SemanticChecker, name: []const u8) ?Entry {
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].values.get(name)) |v| return v;
        }
        if (self.type_aliases.get(name)) |a| return .{ .info = a.info, .doc = a.doc };
        return null;
    }

    // the CheckCtx scope for types.zig inference
    pub fn check(self: *SemanticChecker) types_mod.CheckCtx {
        var ctx = types_mod.CheckCtx.init(self, self.alloc);
        ctx.scope = self.aliasScope();
        return ctx;
    }

    pub fn aliasScope(self: *SemanticChecker) types_mod.AliasScope {
        return .{
            .alloc = self.alloc,
            .type_params = self.current_type_params,
            .aliases = &self.type_aliases,
            .imports = &self.import_aliases,
        };
    }

    pub fn inferIdentType(self: *SemanticChecker, name: []const u8) types_mod.TypeInfo {
        return self.lookup(name) orelse .{ .tag = .any };
    }

    pub fn inferFnType(self: *SemanticChecker, params: []const cst.CstParam, return_type: ?*const cst.CstType, type_params: []const []const u8, doc: ?[]const u8) types_mod.TypeInfo {
        const combined = types_mod.combinedTypeParams(self.alloc, type_params, params) catch type_params;
        const saved = self.current_type_params;
        self.current_type_params = combined;
        defer self.current_type_params = saved;
        const sig = self.makeFnSig(params, return_type, type_params, doc) catch return .{ .tag = .any };
        return .{ .tag = .{ .function = sig } };
    }

    pub fn inferCallReturnType(
        self: *SemanticChecker,
        callee: *const cst.CstNode,
        args: []const *const cst.CstNode,
        type_args: []const []const u8,
        implicit_self: bool,
    ) types_mod.TypeInfo {
        const callee_type = types_mod.inferExprType(self.check(), callee);
        if (callee_type.tag == .function) {
            const sig = callee_type.tag.function;
            if (sig.type_params.len > 0 and sig.return_type.tag != .any) {
                return types_mod.substCallReturn(self.check(), sig, callee, args, type_args, implicit_self);
            }
            return sig.return_type;
        }
        return .{ .tag = .any };
    }

    /// an ident assigned inside a fn body could be mutated from anywhere
    ///   once the closure escapes
    ///
    /// only marks names bound outside the current scope
    ///   (locals assigned in their own scope r still precise)
    fn markEscaped(self: *SemanticChecker, name: []const u8) !void {
        if (self.fn_nesting == 0) return;
        if (self.scopes.items.len == 0) return;
        if (self.scopes.items[self.scopes.items.len - 1].values.contains(name)) return;
        try self.escaped.put(name, {});
    }

    /// unknown member access on a fully-known table shape
    /// so `t.a` where every field of t is known but lacks `a`
    /// ~ open tables with unknown shapes (fields == null) never flag
    /// ~ assigned and imported fields count via table_field_map
    /// ~ escaped tables (mutated through closures) never flag
    fn checkKnownField(self: *SemanticChecker, object: *const cst.CstNode, name: []const u8, span: Lexer.Span) !void {
        const object_type = types_mod.inferExprType(self.check(), object);
        switch (object_type.tag) {
            .table => |tbl| {
                if (cst.identText(object)) |oname| {
                    if (self.escaped.contains(oname)) return;
                }
                if (tbl.fields) |fs| {
                    if (types_mod.findField(fs, name) != null) return;
                    if (cst.identText(object)) |oname| {
                        if (self.table_field_map.get(oname)) |fields| {
                            if (fields.get(name) != null) return;
                        }
                    }
                    const obj_str = try type_syntax.formatTypeOpts(self.alloc, object_type, .{});
                    const msg = try self.alloc.print("field `{s}` is not defined on {s}", .{ name, obj_str });
                    try self.appendError(msg, span, "unknown field");
                }
            },
            else => {},
        }
    }

    /// `a.T` in type position: module must be known import carrying the alias
    /// , unresolvable modules stay silent, evalTypeExpr degrades those to any
    fn checkQualifiedTypes(self: *SemanticChecker, te: *const cst.CstType) !void {
        switch (te.kind) {
            .qualified => |q| {
                if (self.import_aliases.get(q.mod_tok.text)) |aliases| {
                    if (aliases.get(q.name_tok.text) == null) {
                        const msg = try self.alloc.print("unknown type `{s}` for module `{s}`", .{ q.name_tok.text, q.mod_tok.text });
                        try self.appendError(msg, te.span, "unknown type");
                    }
                }
            },
            .qualified_optional => |q| {
                // strip trailing `?` like lowering does
                const nm = q.name_tok.text;
                const bare = if (std.mem.endsWith(u8, nm, "?")) nm[0 .. nm.len - 1] else nm;
                if (self.import_aliases.get(q.mod_tok.text)) |aliases| {
                    if (aliases.get(bare) == null) {
                        const msg = try self.alloc.print("unknown type `{s}` for module `{s}`", .{ bare, q.mod_tok.text });
                        try self.appendError(msg, te.span, "unknown type");
                    }
                }
            },
            .union_of => |u| {
                try self.checkQualifiedTypes(u.first);
                for (u.rest) |v| try self.checkQualifiedTypes(v);
            },
            .record => |r| for (r.fields) |f| try self.checkQualifiedTypes(f.type),
            .function => |f| {
                for (f.params) |p| if (p.type) |t| try self.checkQualifiedTypes(t);
                if (f.ret) |ret| try self.checkQualifiedTypes(ret);
            },
            .parameterized => |p| for (p.args) |param| try self.checkQualifiedTypes(param),
            .error_union => |e| try self.checkQualifiedTypes(e.inner),
            .paren => |p| try self.checkQualifiedTypes(p.inner),
            .slashed => |s| try self.checkQualifiedTypes(s.inner),
            .named, .atom, .optional => {},
        }
    }

    /// user annotation: validate qualified names, then evaluate
    fn evalCheckedTypeExpr(self: *SemanticChecker, te: *const cst.CstType) !types_mod.TypeInfo {
        try self.checkQualifiedTypes(te);
        return try types_mod.evalTypeExpr(self.aliasScope(), te);
    }

    pub fn inferFieldType(self: *SemanticChecker, object: *const cst.CstNode, name: []const u8) types_mod.TypeInfo {
        const object_type = types_mod.inferExprType(self.check(), object);
        // user-defined table fields shadow baselib methods: literal shapes
        // first, flow-sensitive assignment tracking second
        if (object_type.tag == .table) {
            if (object_type.tag.table.fields) |fs| {
                if (types_mod.findField(fs, name)) |f| return f.field_type;
            }
            if (cst.identText(object)) |oname| {
                if (self.table_field_map.get(oname)) |fields| {
                    if (fields.get(name)) |ft| return ft;
                }
            }
        }
        // method lookup runs through the type's module table: the module
        // fn doubles as the method, e.g. `t:unwrap_err()` resolves
        // `table.unwrap_err` at runtime
        const target: ?revo.baselib.host.ParamType = switch (object_type.tag) {
            .number => .number,
            .string => .string,
            .table => .table,
            else => null,
        };
        if (target) |t| {
            if (findModuleByNameAndTarget(name, t)) |spec| {
                if (self.makeStdlibSig(spec) catch null) |sig| {
                    return .{ .tag = .{ .function = sig } };
                }
            }
        }
        // baselib module function lookup: fs.exists?, file.read, time.now
        // , only globals are modules, a local binding shadows the module
        if (cst.identText(object)) |oname| {
            if (self.known_globals.contains(oname) and !self.shadowed_globals.contains(oname)) {
                const module_name = oname;
                for (revo.baselib.specs.full_specs) |group| for (group) |*spec| {
                    if (spec.is_type) continue;
                    if (!std.mem.eql(u8, spec.name, name)) continue;
                    const head = spec.head;
                    if (head.kind == .namespaced and std.mem.eql(u8, head.module.?, module_name)) {
                        if (self.makeStdlibSig(spec) catch null) |sig| {
                            return .{ .tag = .{ .function = sig } };
                        }
                    }
                };
            }
        }
        return .{ .tag = .any };
    }

    /// `T?` lands as optional/union carrying `:nil`
    fn isNilableParam(te: ?*const cst.CstType) bool {
        const t = te orelse return false;
        switch (t.kind) {
            .optional, .qualified_optional => return true,
            .union_of => |u| {
                if (isNilableParam(u.first)) return true;
                for (u.rest) |v| if (isNilableParam(v)) return true;
                return false;
            },
            .atom => |a| return std.mem.startsWith(u8, a.tok.text, ":"),
            else => return false,
        }
    }

    /// params up to the first soft one: `?name:`, `name: T?`
    ///   tail, all of which the host fills in
    fn fixedPrefix(params: []const cst.CstParam) usize {
        var n: usize = 0;
        for (params) |p| {
            if (p.qmark_tok != null or isNilableParam(p.type)) break;
            n += 1;
        }
        return n;
    }

    /// type-level variant (spec function types): `?` and `...` tails
    fn fixedTypePrefix(params: []const cst.CstTypeParam) usize {
        var n: usize = 0;
        for (params) |p| {
            if (p.qmark_tok != null or p.dots.len > 0 or isNilableParam(p.type)) break;
            n += 1;
        }
        return n;
    }

    fn makeStdlibSig(self: *SemanticChecker, spec: *const revo.baselib.specs.FnSpec) !?*const FnSig {
        if (spec.is_type) return null;
        if (self.sig_cache.get(spec)) |sig| return sig;
        const saved = self.current_type_params;
        self.current_type_params = spec.type_params;
        defer self.current_type_params = saved;

        const ft = spec.type.kind.function;
        var param_types = try std.ArrayList(types_mod.TypeInfo).initCapacity(self.alloc, ft.params.len);
        var param_names = try std.ArrayList([]const u8).initCapacity(self.alloc, ft.params.len);

        for (ft.params) |p| {
            try param_names.append(self.alloc, p.name_tok.text);
            try param_types.append(self.alloc, if (p.type) |tn| types_mod.evalTypeExpr(self.aliasScope(), tn) catch types_mod.TypeInfo{ .tag = .any } else types_mod.TypeInfo{ .tag = .any });
        }

        const names_slice = try param_names.toOwnedSlice(self.alloc);
        const types_slice = try param_types.toOwnedSlice(self.alloc);

        // required is the host arity, not the `?` flags, since baselib
        // spells optionals as nilable; the fixed prefix is a floor on top,
        //   so `zip(a, b, rest...)` still wants two. keep in sync
        const ret = if (ft.ret) |r| types_mod.evalTypeExpr(self.aliasScope(), r) catch types_mod.TypeInfo{ .tag = .any } else types_mod.TypeInfo{ .tag = .any };
        const sig = try types_mod.newSignature(self.alloc, .{
            .param_names = names_slice,
            .params = types_slice,
            .return_type = ret,
            .required_count = @max(spec.f.arity, fixedTypePrefix(ft.params)),
            .type_params = spec.type_params,
            .doc = if (spec.doc.len > 0) spec.doc else null,
        });

        try self.sig_cache.put(spec, sig);
        return sig;
    }

    fn makeFnSig(
        self: *SemanticChecker,
        params: []const cst.CstParam,
        return_type: ?*const cst.CstType,
        type_params: []const []const u8,
        doc: ?[]const u8,
    ) !*FnSig {
        for (params) |p| if (p.type) |t| try self.checkQualifiedTypes(t);
        if (return_type) |rt| try self.checkQualifiedTypes(rt);

        return try types_mod.buildFnSig(
            self.alloc,
            self,
            params,
            return_type,
            type_params,
            doc,
            .{},
        );
    }

    /// true if candidate's return type eventually resolves to target's sig
    /// , so like adopting it would make one sig reference the other in a loop
    fn fnReturnCycles(candidate: *const FnSig, target: *const FnSig, depth: usize) bool {
        if (depth > 64) return true;
        if (candidate == target) return true;

        return switch (candidate.return_type.tag) {
            .function => |f| fnReturnCycles(f, target, depth + 1),
            else => false,
        };
    }

    fn analyzeFnBody(
        self: *SemanticChecker,
        params: []const cst.CstParam,
        body: *const cst.CstNode,
        sig: *FnSig,
    ) !types_mod.TypeInfo {
        try self.return_types.append(self.alloc, sig.return_type);
        defer _ = self.return_types.pop();

        self.fn_nesting += 1;
        defer self.fn_nesting -= 1;

        try self.pushScope();
        defer self.popScope();
        for (params, sig.params) |param, param_type| {
            const pname = param.name_tok.text;
            const pspan = param.name_tok.span();
            // the func scope is fresh, so anything already in it is a repeated
            // param; the second would just overwrite the first's slot
            if (!cst.isDiscardName(pname) and
                self.scopes.items[self.scopes.items.len - 1].values.contains(pname))
            {
                const msg = try self.alloc.print("duplicate parameter `{s}`", .{pname});
                if (self.first_code == null) self.first_code = "duplicate-parameter";
                try self.appendError(msg, pspan, "duplicate parameter");
            }
            try self.warnShadow(pname, pspan);
            try self.declare(pname, param_type, null);
        }
        // defaults can reference sibling params, so they analyze here where
        // params are declared; also annotates them for the compiler's default checks
        for (params) |param| {
            if (param.default) |d| _ = try self.analyzeNode(d);
        }
        const body_type = try self.analyzeNode(body);
        if (sig.return_type.tag == .any and body_type.tag != .any) {
            // a fn whose inferred return type is itself
            // (or cycles back thru other inferred fns)
            // would make the sig self-referential
            // and diverge every later clone/intern
            //
            // leave its return type open
            const cycles = switch (body_type.tag) {
                .function => |f| SemanticChecker.fnReturnCycles(f, sig, 0),
                else => false,
            };
            if (!cycles) sig.return_type = body_type;
        }
        // validate explicit return type against inferred body type
        if (sig.return_type.tag != .any and body_type.tag != .any and !types_mod.canCoerce(body_type, sig.return_type)) {
            try self.appendReturnMismatch(body.span, sig.return_type, body_type);
        }
        return .{ .tag = .{ .function = sig } };
    }

    fn analyzeFnDef(
        self: *SemanticChecker,
        params: []const cst.CstParam,
        return_type: ?*const cst.CstType,
        type_param_toks: []const @import("./Lexer.zig").Token,
        body: *const cst.CstNode,
        doc: ?[]const u8,
    ) !types_mod.TypeInfo {
        const tps = try cst.tokenTexts(self.alloc, type_param_toks);
        const combined = try types_mod.combinedTypeParams(self.alloc, tps, params);
        const saved = self.current_type_params;
        self.current_type_params = combined;
        defer self.current_type_params = saved;
        const sig = try self.makeFnSig(params, return_type, tps, doc);
        return self.analyzeFnBody(params, body, sig);
    }

    /// trimmed doc text of a node, null when none
    fn nodeDoc(node: *const cst.CstNode) ?[]const u8 {
        const tok = node.doc_tok orelse return null;
        return std.mem.trim(u8, tok.text, " \t\n\r");
    }

    /// one import item: dep interface becomes the binding's record type
    /// , member access, calls, and completions flow through the regular
    /// , table paths; unresolvable deps stay untyped. returns the declared type
    fn analyzeImportItem(self: *SemanticChecker, item: cst.CstImportItem) !types_mod.TypeInfo {
        return self.analyzeImportItemNamed(item, if (item.name_tok) |nt| nt.text else std.Io.Dir.path.stem(item.path.text));
    }

    fn analyzeImportItemNamed(self: *SemanticChecker, item: cst.CstImportItem, nm: []const u8) !types_mod.TypeInfo {
        if (self.resolveDepCst(item.path.text)) |dep| {
            const items: []const *const cst.CstNode = cst.blockStmts(dep) orelse &[_]*const cst.CstNode{dep};

            if (import_types.moduleInterface(self.alloc, items)) |iface| {
                var aliases = std.StringHashMap(types_mod.TypeInfo).init(self.alloc);
                for (iface.aliases) |a| try aliases.put(a.name, a.info);
                try self.import_aliases.put(nm, aliases);

                if (iface.record) |record| {
                    try self.declare(nm, record, null);
                    return record;
                }
            } else |_| {}
        }
        try self.declare(nm, .{ .tag = .any }, null);
        return .{ .tag = .any };
    }

    fn analyzeNode(self: *SemanticChecker, node: *const cst.CstNode) anyerror!types_mod.TypeInfo {
        const t: types_mod.TypeInfo = switch (node.kind) {
            .binding => |b| try self.analyzeBindingCst(b, null, node.span, node),
            .decl => |d| try self.analyzeDeclCst(d, node.span, node),
            .type_alias => |alias| try self.analyzeTypeAliasCst(alias, null, node.span),
            .fn_def => |f| try self.analyzeFnDef(f.params, f.return_type, f.type_params, f.body, nodeDoc(node)),
            .fn_method => |f| try self.analyzeFnMethod(f, node.span),
            .block => |b| try self.analyzeBlock(b.stmts, node.span),
            .root => |r| blk: {
                // the file body is its own scope (init holds the module
                // scope above it); this is what the old merge-wrap provided
                try self.pushScope();
                defer self.popScope();
                var last: types_mod.TypeInfo = .{ .tag = .any };
                for (r.stmts) |expr| {
                    last = try self.analyzeNode(expr);
                }
                break :blk last;
            },
            .do_block => |d| blk: {
                // labels only matter for codegen; checking is a plain block
                break :blk try self.analyzeBlock(d.stmts, node.span);
            },
            .paren => |p| blk: {
                // stripped by hir.lower; only `()` survives this far
                if (p.expr) |_| unreachable;
                break :blk .{ .tag = .any };
            },
            .pipe => unreachable, // desugared by hir.lower
            .assign => |a| try self.analyzeAssignCst(a.target, a.value, node.span),
            .compound => |c| try self.analyzeCompound(c.target, c.op, c.value, node.span),
            .return_expr => |r| try self.analyzeReturn(r.value, node.span),
            .call => |c| try self.analyzeCallCst(c.callee, c.args, &.{}, false, node.span),
            .bare_call => |b| try self.analyzeCallCst(b.callee, &[_]*const cst.CstNode{b.arg}, &.{}, false, node.span),
            .generic_call => |g| blk: {
                const targs = try cst.tokenTexts(self.alloc, g.type_args);
                defer self.alloc.free(targs);
                break :blk try self.analyzeCallCst(g.receiver, g.args, targs, false, node.span);
            },
            .method_call => |m| try self.analyzeMethodCall(m, node.span),
            .if_expr => |c| try self.analyzeBranch(c.cond, c.then, c.else_),
            .ident => |n| try self.analyzeIdent(n.tok.text, node.span),
            .unary => |u| blk: {
                _ = try self.analyzeNode(u.expr);
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .yield => types_mod.inferExprType(self.check(), node),
            .binary => |b| blk: {
                const l = try self.analyzeNode(b.left);
                const r = try self.analyzeNode(b.right);
                try self.checkBinaryOperands(b.op, l, r, node.span);
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .logical => |l| blk: {
                _ = try self.analyzeNode(l.left);
                _ = try self.analyzeNode(l.right);
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .try_expr => |tt| blk: {
                const inner_type = try self.analyzeNode(tt.expr);
                if (inner_type.tag != .any and !types_mod.isResultType(inner_type)) {
                    try self.appendError(
                        try self.alloc.print("try expects :ok/:err tagged result, got {s}", .{try type_syntax.formatTypeOpts(self.alloc, inner_type, .{})}),
                        tt.expr.span,
                        "not a result type",
                    );
                }
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .field => |f| blk: {
                _ = try self.analyzeNode(f.object);
                try self.checkKnownField(f.object, f.name_tok.text, node.span);
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .dotted_index => |d| blk: {
                _ = try self.analyzeNode(d.object);
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .index => |idx| blk: {
                _ = try self.analyzeNode(idx.object);
                _ = try self.analyzeNode(idx.key);
                // `t[:a]` / `t["a"]` with a static key check like `t.a`
                const key_unwrapped = cst.unwrapParen(idx.key);
                const static_key: ?[]const u8 = if (key_unwrapped) |k| switch (k.kind) {
                    .atom => |a| cst.atomName(a.tok.text),
                    .string => |s| s.tok.text,
                    else => null,
                } else null;
                if (static_key) |key| try self.checkKnownField(idx.object, key, node.span);
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .table => |tbl| blk: {
                for (tbl.entries) |entry| {
                    switch (entry) {
                        .computed => |cc| {
                            _ = try self.analyzeNode(cc.key);
                            _ = try self.analyzeNode(cc.value);
                        },
                        .keyed => |k| {
                            const ku = cst.unwrapParen(k.key);
                            const simple = if (ku) |u| u.kind == .ident or u.kind == .atom else false;
                            if (!simple) _ = try self.analyzeNode(k.key);
                            _ = try self.analyzeNode(k.value);
                        },
                        .bare => |b| _ = try self.analyzeNode(b.value),
                    }
                }
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .range => |r| blk: {
                _ = try self.analyzeNode(r.start);
                _ = try self.analyzeNode(r.mid);
                if (r.end) |e| _ = try self.analyzeNode(e);
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .for_range => |r| blk: {
                if (r.start) |s| _ = try self.analyzeNode(s);
                if (r.mid) |m| _ = try self.analyzeNode(m);
                if (r.end) |e| _ = try self.analyzeNode(e);
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .slice => |s| blk: {
                if (s.start) |st| _ = try self.analyzeNode(st);
                if (s.mid) |m| _ = try self.analyzeNode(m);
                if (s.end) |e| _ = try self.analyzeNode(e);
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .comp_block => |v| blk: {
                const inner_t = try self.analyzeNode(v.expr);
                break :blk inner_t;
            },
            .break_expr => |b| blk: {
                if (b.value) |v| _ = try self.analyzeNode(v);
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .continue_expr => types_mod.inferExprType(self.check(), node),
            .for_loop => |v| blk: {
                const iter_type = try self.analyzeNode(v.iter);
                try self.pushScope();
                const iter_unwrapped = cst.unwrapParen(v.iter);
                const is_range = if (iter_unwrapped) |u| u.kind == .range or u.kind == .for_range else false;
                const param_type: types_mod.TypeInfo = if (is_range)
                    .{ .tag = .number }
                else if (iter_type.tag == .string)
                    .{ .tag = .string }
                else
                    .{ .tag = .any };
                for (v.params) |param| {
                    try self.warnShadow(param.text, param.span());
                    try self.declare(param.text, param_type, null);
                }
                const body_type = try self.analyzeNode(v.body);
                self.popScope();
                break :blk body_type;
            },
            .match => |v| blk: {
                const subject_type = if (v.subject) |s| try self.analyzeNode(s) else types_mod.TypeInfo{ .tag = .any };
                var unified: types_mod.TypeInfo = .{ .tag = .never };

                // guardless prior covers + matchers, for dead-arm detection
                var covered = std.ArrayList(types_mod.MatchCover).initCapacity(self.alloc, 8) catch break :blk unified;
                defer covered.deinit(self.alloc);
                var prior = std.ArrayList(cst.CstMatcher).initCapacity(self.alloc, 8) catch break :blk unified;
                defer prior.deinit(self.alloc);

                for (v.arms) |arm| {
                    try self.pushScope();
                    for (arm.matchers) |matcher| {
                        if (matcher == .expr) {
                            _ = try self.declarePatternNames(matcher.expr);
                            try self.narrowPatternNames(matcher.expr, subject_type);
                        }
                    }
                    if (arm.guard) |g| _ = try self.analyzeNode(g);
                    const arm_type = try self.analyzeNode(arm.then);
                    self.popScope();
                    unified = types_mod.unifyBranchType(unified, arm_type);

                    var arm_span = node.span;
                    for (arm.matchers) |matcher| {
                        if (matcher == .expr) {
                            arm_span = matcher.expr.span;
                            break;
                        }
                    }

                    const arm_covers = try types_mod.buildArmCovers(self.aliasScope(), arm);
                    defer self.alloc.free(arm_covers);

                    // degenerate subject, every arm is trivially dead; do notih
                    if (subject_type.tag != .never and arm_covers.len > 0) {
                        var overlaps = false;
                        for (arm_covers) |c| {
                            if (types_mod.matchOverlaps(subject_type, c)) {
                                overlaps = true;
                                break;
                            }
                        }
                        if (!overlaps) {
                            const subject_str = try type_syntax.formatTypeOpts(self.alloc, subject_type, .{});

                            try self.appendWarn(
                                try self.alloc.print("match pattern never matches {s}", .{subject_str}),
                                arm_span,
                                "never matches",
                                "impossible-match-arm",
                            );
                        } else {
                            var dead = arm.matchers.len > 0;
                            for (arm.matchers) |m| {
                                if (!switch (m) {
                                    .wildcard => types_mod.matchCoversAll(subject_type, covered.items),
                                    .expr => |e| sub: {
                                        const eu = cst.unwrapParen(e) orelse break :sub false;
                                        if (eu.kind == .ident)
                                            break :sub types_mod.matchCoversAll(subject_type, covered.items);

                                        for (prior.items) |p| {
                                            const sub = switch (p) {
                                                .wildcard => true,
                                                .expr => |pe| patternSubsumes(pe, e),
                                            };
                                            if (sub) break :sub true;
                                            // wow we have a lot of nesting, 11 levels
                                            // , but what can i even do
                                        }
                                        if (eu.kind == .ascribed) {
                                            const ti = types_mod.evalTypeExpr(self.aliasScope(), eu.kind.ascribed.type) catch break :sub false;
                                            break :sub types_mod.matchCoversAll(ti, covered.items);
                                        }
                                        if (patternLitType(e)) |lt| break :sub types_mod.matchCoversAll(lt, covered.items);
                                        break :sub false;
                                    },
                                }) {
                                    dead = false;
                                    break;
                                }
                            }
                            if (dead) try self.appendWarn("unreachable match arm", arm_span, "unreachable", "unreachable-match-arm");
                        }
                    }
                    // guarded arms never contribute coverage, a guard can fail
                    if (arm.guard == null) {
                        try covered.appendSlice(self.alloc, arm_covers);
                        try prior.appendSlice(self.alloc, arm.matchers);
                    }
                }
                // miss falls through to nil at runtime
                // so a non-exhaustive match always carries :nil in its type
                if (!types_mod.matchCoversAll(subject_type, covered.items)) {
                    unified = types_mod.withNilMiss(self.alloc, unified);
                    var tags = std.ArrayList([]const u8).initCapacity(self.alloc, 4) catch break :blk unified;

                    defer tags.deinit(self.alloc);
                    try types_mod.uncoveredTags(self.alloc, subject_type, covered.items, &tags);

                    const msg = if (tags.items.len > 0) blk_msg: {
                        const listed = try std.mem.join(self.alloc, ", :", tags.items);
                        defer self.alloc.free(listed);
                        break :blk_msg try self.alloc.print(
                            "match is not exhaustive: :{s} not covered, miss yields :nil",
                            .{listed},
                        );
                    } else blk_msg: {
                        const subject_str = try type_syntax.formatTypeOpts(self.alloc, subject_type, .{});
                        break :blk_msg try self.alloc.print(
                            "match is not exhaustive for {s}, miss yields :nil",
                            .{subject_str},
                        );
                    };
                    try self.appendWarn(msg, node.span, "non-exhaustive match", "non-exhaustive-match");
                    // suggest the actual arms:
                    // a miss evaluates to nil already,
                    // one per uncovered tag when nameable
                    // , plain `_` otherwise
                    if (v.arms.len > 0) {
                        const last = v.arms[v.arms.len - 1];
                        const ins = @min(last.then.span.end, self.source.len);
                        var anchor: ?usize = null;
                        for (last.matchers) |matcher| {
                            if (matcher == .expr) {
                                anchor = matcher.expr.span.start;
                                break;
                            }
                        }

                        const anchor_off = @min(anchor orelse last.then.span.start, self.source.len);
                        var line_start = anchor_off;
                        while (line_start > 0 and self.source[line_start - 1] != '\n') : (line_start -= 1) {}
                        var indent_end = line_start;

                        while //
                        (indent_end < anchor_off and (self.source[indent_end] == ' ' //
                        or self.source[indent_end] == '\t')) //
                        : (indent_end += 1) {}

                        var sug_line: u32 = 1;
                        var sug_col: u32 = 1;
                        var idx: usize = 0;

                        while (idx < ins and idx < self.source.len) : (idx += 1) {
                            if (self.source[idx] == '\n') {
                                sug_line += 1;
                                sug_col = 1;
                            } else {
                                sug_col += 1;
                            }
                        }

                        var patterns = std.ArrayList([]const u8).initCapacity(self.alloc, tags.items.len) catch break :blk unified;
                        defer patterns.deinit(self.alloc);

                        for (tags.items) |tag| {
                            if (try types_mod.suggestArmPattern(self.alloc, subject_type, tag)) |pat| {
                                try patterns.append(self.alloc, pat);
                            }
                        }

                        if (patterns.items.len == 0) {
                            // tables suggest shape, so fix mirrors subject
                            const fallback = (try types_mod.suggestTablePattern(self.alloc, subject_type)) orelse "_";

                            try patterns.append(self.alloc, fallback);
                        }

                        var replacement = std.ArrayList(u8).initCapacity(self.alloc, 32) catch break :blk unified;
                        defer replacement.deinit(self.alloc);

                        const indent = self.source[line_start..indent_end];

                        for (patterns.items) |pat| {
                            try replacement.appendSlice(self.alloc, "\n");
                            try replacement.appendSlice(self.alloc, indent);
                            try replacement.appendSlice(self.alloc, "| ");
                            try replacement.appendSlice(self.alloc, pat);
                            try replacement.appendSlice(self.alloc, " => :nil");
                        }
                        try self.warn_parts.append(self.alloc, .{ .suggestion = .{
                            .span = .{ .start = ins, .end = ins, .line = sug_line, .column = sug_col },
                            .message = "add an explicit nil arm",
                            .replacement = try replacement.toOwnedSlice(self.alloc),
                        } });
                    }
                }
                break :blk unified;
            },
            .loop_expr => |v| blk: {
                try self.pushScope();
                _ = try self.analyzeNode(v.body);
                self.popScope();
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .while_loop => |v| blk: {
                const pred_type = try self.analyzeNode(v.pred);
                if (!types_mod.canCoerce(pred_type, .{ .tag = .bool })) {
                    try self.appendError(
                        try self.alloc.print("while predicate must be boolean, got {s}", .{try type_syntax.formatTypeOpts(self.alloc, pred_type, .{})}),
                        v.pred.span,
                        "expected bool",
                    );
                }
                try self.pushScope();
                _ = try self.analyzeNode(v.body);
                self.popScope();
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .import => |im| blk: {
                // the dep interface becomes the binding's record type, so
                // member access, calls, and completions flow through the
                // regular table paths; unresolvable deps stay untyped
                // block-like: the value is the last item's type
                var last: types_mod.TypeInfo = .{ .tag = .any };
                for (im.items) |item| {
                    last = try self.analyzeImportItem(item);
                }
                break :blk last;
            },
            .number, .string, .atom, .err, .interpolated, .test_block, .test_suite => blk: {
                if (node.kind == .interpolated) {
                    for (node.kind.interpolated.parts) |part| {
                        if (part == .interp) _ = try self.analyzeNode(part.interp.value);
                    }
                } else if (node.kind == .test_block or node.kind == .test_suite) {
                    const body = if (node.kind == .test_block) node.kind.test_block.body else node.kind.test_suite.body;
                    _ = try self.analyzeNode(body);
                }
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .ascribed => blk: {
                try self.appendError(
                    "type ascriptions only go in match patterns",
                    node.span,
                    "not a value",
                );

                break :blk .{ .tag = .any };
            },
        };

        return self.annotate(node, t);
    }

    /// every analyzed node leaves with an annotation
    ///   the compiler reads these instead of reinferring
    ///   , so narrowing and generics edges are here now
    fn annotate(self: *SemanticChecker, node: *const cst.CstNode, t: types_mod.TypeInfo) types_mod.TypeInfo {
        if (self.annotations) |ann| {
            const tv = self.annotatedType(node, t);
            if (ann.table.intern(tv)) |id| {
                ann.map.put(node, id) catch {};
            } else |_| {}
        }

        return t;
    }

    /// ident annotations go rite over flow-tracked fields onto the declared shape
    ///   mirrors inferFieldType,,, literal fields win, tracked fill gaps
    ///   transient in checker alloc, intern clones; never freed, arena-owned
    fn annotatedType(self: *SemanticChecker, node: *const cst.CstNode, declared: types_mod.TypeInfo) types_mod.TypeInfo {
        const unwrapped = cst.unwrapParen(node) orelse return declared;
        if (unwrapped.kind != .ident) return declared;
        if (declared.tag != .table) return declared;
        const tracked = self.table_field_map.get(unwrapped.kind.ident.tok.text) orelse return declared;
        if (tracked.count() == 0) return declared;

        const base = declared.tag.table.fields orelse &.{};
        var extra: usize = 0;
        var it = tracked.iterator();
        while (it.next()) |e| {
            var found = false;
            for (base) |f| {
                if (std.mem.eql(u8, f.name, e.key_ptr.*)) {
                    found = true;
                    break;
                }
            }
            if (!found) extra += 1;
        }
        if (extra == 0) return declared;

        var fields = std.ArrayList(types_mod.RecordField).initCapacity(self.alloc, base.len + extra) catch return declared;
        for (base) |f| fields.appendAssumeCapacity(f);
        var it2 = tracked.iterator();
        while (it2.next()) |e| {
            var found = false;
            for (base) |f| {
                if (std.mem.eql(u8, f.name, e.key_ptr.*)) {
                    found = true;
                    break;
                }
            }
            if (!found) fields.appendAssumeCapacity(.{
                .name = e.key_ptr.*,
                .field_type = e.value_ptr.*,
            });
        }

        return .{ .tag = .{ .table = .{
            .key = declared.tag.table.key,
            .value = declared.tag.table.value,
            .fields = fields.items,
        } } };
    }

    fn analyzeIdent(self: *SemanticChecker, name: []const u8, span: Lexer.Span) !types_mod.TypeInfo {
        // baselib fns are only declared into scope when the checker runs with
        // vm globals (repl); without them, fall back to the spec registry so
        // bare calls like `print(x)` don't read as unknown
        if (self.lookup(name) == null and !cst.isDiscardName(name) and
            !(self.fn_nesting > 0 and self.predeclared.contains(name)) and revo.baselib.specs.findFn(name) == null)
        {
            const msg = try self.alloc.print("name `{s}` is not defined", .{name});
            if (self.first_code == null) self.first_code = "unknown-name";
            try self.appendError(msg, span, "unknown name");
        }
        return self.inferIdentType(name);
    }

    fn analyzeBlock(self: *SemanticChecker, exprs: []const *const cst.CstNode, span: Lexer.Span) !types_mod.TypeInfo {
        _ = span;
        try self.pushScope();
        defer self.popScope();
        var last: types_mod.TypeInfo = .{ .tag = .any };
        for (exprs) |expr| {
            last = try self.analyzeNode(expr);
        }
        return last;
    }

    fn analyzeDeclCst(self: *SemanticChecker, decl: @FieldType(cst.CstKind, "decl"), span: Lexer.Span, node: *const cst.CstNode) !types_mod.TypeInfo {
        _ = span;
        const doc = nodeDoc(node);
        const inner = cst.unwrapParen(decl.inner) orelse return .{ .tag = .any };

        if (decl.kind == .declare_decl and inner.kind == .type_alias) {
            const t = try self.analyzeDeclareCst(inner.kind.type_alias, doc);
            return self.annotate(inner, t);
        }

        return switch (inner.kind) {
            .binding => |b| self.annotate(inner, try self.analyzeBindingCst(b, doc, inner.span, inner)),
            .type_alias => |alias| self.annotate(inner, try self.analyzeTypeAliasCst(alias, doc, inner.span)),
            .fn_def => |f| self.annotate(inner, try self.analyzeFnDef(f.params, f.return_type, f.type_params, f.body, doc)),
            else => try self.analyzeNode(decl.inner),
        };
    }

    fn analyzeDeclareCst(self: *SemanticChecker, alias: @FieldType(cst.CstKind, "type_alias"), doc: ?[]const u8) !types_mod.TypeInfo {
        // init pushes the module scope, the file body is the next scope in
        if (self.scopes.items.len != 2) {
            try self.appendError("declare must be a top-level statement", alias.eq_tok.span(), "declare scope");
            return .{ .tag = .any };
        }
        if (alias.segs.len == 0) return .{ .tag = .any };
        const name = alias.segs[0].text;
        if (self.lookup(name) != null) {
            const msg = try self.alloc.print("duplicate declaration of `{s}`", .{name});
            try self.appendError(msg, alias.eq_tok.span(), "duplicate declare");
            return .{ .tag = .any };
        }
        const t = self.evalCheckedTypeExpr(alias.type) catch types_mod.TypeInfo{ .tag = .any };
        try self.declare(name, t, doc);
        // also usable in type positions: `const x: MAX_ITEMS = 5`
        try self.type_aliases.put(name, .{ .info = t, .doc = doc });
        return .{ .tag = .any };
    }

    fn analyzeTypeAliasCst(self: *SemanticChecker, alias: @FieldType(cst.CstKind, "type_alias"), doc: ?[]const u8, span: Lexer.Span) !types_mod.TypeInfo {
        _ = span;
        if (alias.segs.len == 0) return .{ .tag = .any };
        const t = self.evalCheckedTypeExpr(alias.type) catch types_mod.TypeInfo{ .tag = .any };
        try self.type_aliases.put(cst.aliasName(alias), .{ .info = t, .doc = doc });
        return .{ .tag = .any };
    }

    /// `fn obj:m() ...` / `fn obj.m() ...` method definition: check the fn
    /// , and track the store into the object like an index assignment
    fn analyzeFnMethod(self: *SemanticChecker, f: @FieldType(cst.CstKind, "fn_method"), span: Lexer.Span) !types_mod.TypeInfo {
        _ = span;
        const tps = try cst.tokenTexts(self.alloc, f.type_params);
        const combined = try types_mod.combinedTypeParams(self.alloc, tps, f.params);
        const saved = self.current_type_params;
        self.current_type_params = combined;
        defer self.current_type_params = saved;
        const sig = try self.makeFnSig(f.params, f.return_type, tps, null);
        _ = try self.analyzeFnBody(f.params, f.body, sig);
        // mirror the old index-assign checking: analyze the object
        const obj_tok = switch (f.head) {
            .method_colon => |m| m.obj_tok,
            .method_dot => |m| m.obj_tok,
            else => return .{ .tag = .any },
        };
        _ = try self.analyzeIdent(obj_tok.text, obj_tok.span());
        return .{ .tag = .any };
    }

    fn analyzeBindingCst(
        self: *SemanticChecker,
        binding: @FieldType(cst.CstKind, "binding"),
        decl_doc: ?[]const u8,
        span: Lexer.Span,
        node: *const cst.CstNode,
    ) !types_mod.TypeInfo {
        _ = span;
        _ = node;
        const target_u = cst.unwrapParen(binding.target) orelse return .{ .tag = .any };
        if (target_u.kind != .ident) {
            if (cst.isTablePattern(binding.target)) {
                const value_type = try self.analyzeNode(binding.value);
                _ = try self.declarePatternNames(binding.target);
                try self.checkPatternAscriptions(binding.target, value_type);

                return .{ .tag = .any };
            }
            _ = try self.analyzeNode(binding.value);
            return .{ .tag = .any };
        }
        const name = target_u.kind.ident.tok.text;
        const value_u = cst.unwrapParen(binding.value);
        try self.warnShadow(name, binding.target.span);
        // docs ride on the decl wrapper; ident and field values inherit the source's doc
        const doc: ?[]const u8 = decl_doc orelse blk: {
            if (value_u) |vu| {
                if (vu.kind == .ident) {
                    if (self.lookupEntry(vu.kind.ident.tok.text)) |src| break :blk src.doc;
                } else if (vu.kind == .field) {
                    const ft = types_mod.inferExprType(self.check(), binding.value);
                    if (ft.tag == .function) break :blk ft.tag.function.doc;
                    break :blk ft.doc;
                }
            }
            break :blk null;
        };
        const vu = value_u orelse binding.value;
        if (vu.kind == .fn_def) {
            const f = vu.kind.fn_def;
            const tps = try cst.tokenTexts(self.alloc, f.type_params);
            const combined = try types_mod.combinedTypeParams(self.alloc, tps, f.params);
            const saved = self.current_type_params;
            self.current_type_params = combined;
            defer self.current_type_params = saved;
            const sig = try self.makeFnSig(f.params, f.return_type, tps, null);
            const fn_type: types_mod.TypeInfo = .{ .tag = .{ .function = sig } };
            if (binding.type) |type_expr| {
                try self.typed_names.put(name, {});
                const expected = try self.evalCheckedTypeExpr(type_expr);
                if (!types_mod.canCoerce(fn_type, expected)) {
                    try self.appendTypeMismatch(
                        binding.target.span,
                        name,
                        expected,
                        fn_type,
                    );
                }
                try self.declare(name, expected, doc);
            } else {
                try self.declare(name, fn_type, doc);
            }
            _ = try self.analyzeFnBody(f.params, f.body, sig);
            if (std.mem.endsWith(u8, name, "?") and sig.return_type.tag != .bool) {
                const msg = try self.alloc.print(
                    "function ending with ? must return bool, got {s}",
                    .{try type_syntax.formatTypeOpts(self.alloc, sig.return_type, .{})},
                );
                if (self.first_code == null) self.first_code = "predicate-return-type";
                try self.appendError(msg, binding.target.span, "expected bool");
            }
            if (self.type_map) |tm| {
                _ = tm.remove(name);
                try tm.put(try self.alloc.dupe(u8, name), fn_type);
            }
            return self.annotate(vu, fn_type);
        }

        // table literal -- analyze entries and record field types for method shadowing
        if (vu.kind == .table) {
            var fields = std.StringHashMap(types_mod.TypeInfo).init(self.alloc);
            var implicit_idx: u32 = 0;
            for (vu.kind.table.entries) |entry| {
                switch (entry) {
                    .computed => |cc| {
                        _ = try self.analyzeNode(cc.key);
                        _ = try self.analyzeNode(cc.value);
                    },
                    .keyed => |k| {
                        const ku = cst.unwrapParen(k.key);
                        const simple = if (ku) |u| u.kind == .ident or u.kind == .atom else false;
                        if (!simple) _ = try self.analyzeNode(k.key);
                        const field_type = try self.analyzeNode(k.value);
                        if (ku) |u| {
                            if (u.kind == .ident) try fields.put(u.kind.ident.tok.text, field_type);
                        }
                    },
                    .bare => |b| {
                        // `fn name() ...` decl values inside tables are methods
                        const bu = cst.unwrapParen(b.value);
                        if (bu) |u| {
                            if (u.kind == .decl and u.kind.decl.inner.kind == .binding) {
                                const mb = u.kind.decl.inner.kind.binding;
                                const mt = cst.unwrapParen(mb.target);
                                const mv = cst.unwrapParen(mb.value);
                                if (mt != null and mv != null and mt.?.kind == .ident and mv.?.kind == .fn_def) {
                                    const ft = try self.analyzeNode(b.value);
                                    try fields.put(mt.?.kind.ident.tok.text, ft);
                                    continue;
                                }
                            }
                        }
                        const ft = try self.analyzeNode(b.value);
                        const idx_name = try self.alloc.print("{d}", .{implicit_idx});
                        implicit_idx += 1;
                        try fields.put(idx_name, ft);
                    },
                }
            }
            try self.table_field_map.put(name, fields);
            const table_type = types_mod.inferExprType(self.check(), binding.value);
            _ = self.annotate(vu, table_type);

            if (binding.type) |type_expr| {
                try self.typed_names.put(name, {});
                const expected = try self.evalCheckedTypeExpr(type_expr);
                if (!types_mod.canCoerce(table_type, expected)) {
                    try self.appendTypeMismatch(
                        binding.target.span,
                        name,
                        expected,
                        table_type,
                    );
                }
                try self.declare(name, expected, doc);
                return expected;
            }
            try self.declare(name, table_type, doc);
            return table_type;
        }
        // propagate table fields through variable references
        if (vu.kind == .ident and !cst.isDiscardName(vu.kind.ident.tok.text)) {
            if (self.table_field_map.get(vu.kind.ident.tok.text)) |src| {
                const fields = try src.clone();
                try self.table_field_map.put(name, fields);
            }
        }

        const value_type = try self.analyzeNode(binding.value);
        if (binding.type) |type_expr| {
            try self.typed_names.put(name, {});
            const expected = try self.evalCheckedTypeExpr(type_expr);
            if (!types_mod.canCoerce(value_type, expected)) {
                try self.appendTypeMismatch(
                    binding.target.span,
                    name,
                    expected,
                    value_type,
                );
            }
            try self.declare(name, expected, doc);
            return expected;
        }

        try self.declare(name, value_type, doc);
        return value_type;
    }

    fn declarePatternNames(self: *SemanticChecker, pattern: *const cst.CstNode) !types_mod.TypeInfo {
        // seen is per-pattern, NOT per scope
        // : match arms deliberately bind the same name from several matchers
        // , a pattern binding it twice is a typo
        var seen = std.StringHashMap(void).init(self.alloc);
        defer seen.deinit();
        return self.declarePatternNamesSeen(pattern, &seen);
    }

    fn declarePatternNamesSeen(
        self: *SemanticChecker,
        pattern: *const cst.CstNode,
        seen: *std.StringHashMap(void),
    ) !types_mod.TypeInfo {
        const unwrapped = cst.unwrapParen(pattern) orelse return .{ .tag = .any };
        switch (unwrapped.kind) {
            .ident => |n| {
                const name = n.tok.text;
                if (!cst.isDiscardName(name)) {
                    if (seen.contains(name)) {
                        const msg = try self.alloc.print("duplicate name `{s}` in pattern", .{name});
                        if (self.first_code == null) self.first_code = "duplicate-pattern-name";
                        try self.appendError(msg, pattern.span, "duplicate name");
                        return .{ .tag = .any };
                    }
                    try seen.put(name, {});
                    try self.declare(name, .{ .tag = .any }, null);
                }
            },
            .table => |tbl| {
                for (tbl.entries) |entry| {
                    if (entry != .bare) continue;
                    _ = try self.declarePatternNamesSeen(entry.bare.value, seen);
                }
            },
            .ascribed => |a| {
                const inner_ti = types_mod.evalTypeExpr(self.aliasScope(), a.type) catch
                    types_mod.TypeInfo{ .tag = .any };

                const inner_u = cst.unwrapParen(a.expr);
                if (inner_u != null and inner_u.?.kind == .ident and !cst.isDiscardName(inner_u.?.kind.ident.tok.text)) {
                    const iname = inner_u.?.kind.ident.tok.text;
                    if (!seen.contains(iname)) {
                        try seen.put(iname, {});
                        try self.declare(iname, inner_ti, null);
                    }
                } else {
                    _ = try self.declarePatternNamesSeen(a.expr, seen);
                }
            },
            else => {},
        }

        return .{ .tag = .any };
    }

    /// binding patterns juty trust `: T` ascriptions at declaration
    /// ; this pass checks them against known element types so
    ///   `let {x: number} = {:ok}` fails instead of binding :ok as number
    ///
    /// unknown positions
    ///     (any, unions, dynamic tables)
    /// pass like nothinh happeneg since `canCoerce` treats `any` as top on both sides
    fn checkPatternAscriptions(self: *SemanticChecker, pattern: *const cst.CstNode, context: types_mod.TypeInfo) !void {
        const entries = cst.patternBareEntries(pattern) orelse return;

        var i: usize = 0;
        for (entries) |entry| {
            const item = entry.bare.value;
            const iu = cst.unwrapParen(item) orelse {
                i += 1;
                continue;
            };
            if (iu.kind != .ascribed and !cst.isTablePattern(item)) {
                i += 1;
                continue;
            }
            const elem = patternElemType(self, context, i) orelse {
                i += 1;
                continue;
            };

            if (iu.kind == .ascribed) {
                const a = iu.kind.ascribed;
                const expected = types_mod.evalTypeExpr(self.aliasScope(), a.type) catch types_mod.TypeInfo{ .tag = .any };

                if (!types_mod.canCoerce(elem, expected)) {
                    const au = cst.unwrapParen(a.expr);
                    const name = if (au != null and au.?.kind == .ident) au.?.kind.ident.tok.text else "?";
                    try self.appendTypeMismatch(item.span, name, expected, elem);
                }

                try self.checkPatternAscriptions(a.expr, elem);
            } else {
                try self.checkPatternAscriptions(item, elem);
            }
            i += 1;
        }
    }

    /// an `{a, b} = v` target already has a declared type from an bind
    ///   , so hold it to the element type
    ///
    /// only fires when the element type is actually known
    ///   , which needs a structurally annotated source
    fn checkPatternTargets(self: *SemanticChecker, pattern: *const cst.CstNode, context: types_mod.TypeInfo) !void {
        const entries = cst.patternBareEntries(pattern) orelse return;

        var i: usize = 0;
        for (entries) |entry| {
            const item = entry.bare.value;
            const iu = cst.unwrapParen(item) orelse {
                i += 1;
                continue;
            };
            const name: []const u8 = switch (iu.kind) {
                .ident => |n| n.tok.text,
                .ascribed => |a| blk: {
                    const au = cst.unwrapParen(a.expr) orelse break :blk "";
                    if (au.kind == .ident) break :blk au.kind.ident.tok.text;
                    break :blk "";
                },
                .table => {
                    const elem = patternElemType(self, context, i) orelse {
                        i += 1;
                        continue;
                    };
                    try self.checkPatternTargets(item, elem);
                    i += 1;
                    continue;
                },
                else => {
                    i += 1;
                    continue;
                },
            };
            if (name.len == 0) {
                i += 1;
                continue;
            }
            if (cst.isDiscardName(name)) {
                i += 1;
                continue;
            }
            if (!self.typed_names.contains(name)) {
                i += 1;
                continue;
            }

            const expected = self.lookup(name) orelse {
                i += 1;
                continue;
            };
            if (expected.tag == .any) {
                i += 1;
                continue;
            }
            const elem = patternElemType(self, context, i) orelse {
                i += 1;
                continue;
            };

            if (!types_mod.canCoerce(elem, expected)) {
                try self.appendTypeMismatch(item.span, name, expected, elem);
            }
            i += 1;
        }
    }

    /// positional element type of a destructured value, or null when unknown
    fn patternElemType(self: *SemanticChecker, context: types_mod.TypeInfo, i: usize) ?types_mod.TypeInfo {
        switch (context.tag) {
            .table => |tbl| {
                const fields = tbl.fields orelse return null;
                const key = self.alloc.print("{d}", .{i}) catch return null;
                if (types_mod.findField(fields, key)) |f| return f.field_type;
                return null;
            },

            else => return null,
        }
    }

    /// narrow match pattern bindings when the subject type is a tagged union
    /// `{:ok, v}` patterns against `{:ok, number} | {:err, string}`
    /// bind `v` as `.number`, not `.any`
    fn narrowPatternNames(self: *SemanticChecker, pattern: *const cst.CstNode, subject_type: types_mod.TypeInfo) !void {
        // ascriptions apply regardless of subject type
        //   ; and win over union narrowing
        const pu = cst.unwrapParen(pattern) orelse return;
        if (pu.kind == .ascribed) {
            const a = pu.kind.ascribed;
            const inner_ti = types_mod.evalTypeExpr(self.aliasScope(), a.type) catch types_mod.TypeInfo{ .tag = .any };

            const au = cst.unwrapParen(a.expr);
            if (au != null and au.?.kind == .ident and !cst.isDiscardName(au.?.kind.ident.tok.text)) {
                try self.declare(au.?.kind.ident.tok.text, inner_ti, null);

                return;
            }

            return try self.narrowPatternNames(a.expr, subject_type);
        }

        if (subject_type.tag == .any) return;

        const entries = cst.patternBareEntries(pattern) orelse return;
        if (entries.len == 0) return;
        const first_u = cst.unwrapParen(entries[0].bare.value) orelse return;
        const tag = if (first_u.kind == .atom) cst.atomName(first_u.kind.atom.tok.text) else return;
        const variants = switch (subject_type.tag) {
            .@"union" => |us| us,
            else => return,
        };
        for (variants) |variant| {
            if (!types_mod.unionVariantTagEql(variant, tag)) continue;
            var payload = std.ArrayList(types_mod.TypeInfo).initCapacity(self.alloc, 4) catch return;
            defer payload.deinit(self.alloc);
            try types_mod.appendUnionVariantPayload(self.alloc, variant, &payload);
            for (entries[1..], 0..) |entry, i| {
                const iu = cst.unwrapParen(entry.bare.value) orelse continue;
                if (iu.kind == .ident and !cst.isDiscardName(iu.kind.ident.tok.text)) {
                    const narrowed = if (i < payload.items.len) payload.items[i] else types_mod.TypeInfo{ .tag = .any };
                    try self.declare(iu.kind.ident.tok.text, narrowed, null);
                }
            }
            return;
        }
    }

    fn analyzeAssignCst(
        self: *SemanticChecker,
        target: *const cst.CstNode,
        value: *const cst.CstNode,
        span: Lexer.Span,
    ) !types_mod.TypeInfo {
        _ = span;
        const value_type = try self.analyzeNode(value);
        try self.trackAssignTarget(target, value_type, value.span);
        try self.annotatePatternTargets(target, value_type);

        return .{ .tag = .any };
    }

    /// annotate pat identifiers with the element type they store
    /// ; the compiler lowers `{a, b} = v` by reading each targets
    ///   annotation to refresh its local type hint
    fn annotatePatternTargets(self: *SemanticChecker, pattern: *const cst.CstNode, context: types_mod.TypeInfo) !void {
        const entries = cst.patternBareEntries(pattern) orelse return;
        for (entries, 0..) |entry, i| {
            const item = entry.bare.value;
            const iu = cst.unwrapParen(item) orelse continue;
            const elem = patternElemType(self, context, i) orelse types_mod.TypeInfo{ .tag = .any };

            switch (iu.kind) {
                .ident => _ = self.annotate(item, elem),
                .ascribed => |a| {
                    const declared = types_mod.evalTypeExpr(self.aliasScope(), a.type) catch types_mod.TypeInfo{ .tag = .any };
                    const inner = cst.unwrapParen(a.expr) orelse {
                        _ = self.annotate(item, declared);
                        continue;
                    };
                    if (inner.kind == .ident) {
                        _ = self.annotate(inner, declared);
                    } else {
                        try self.annotatePatternTargets(a.expr, elem);
                    }
                    _ = self.annotate(item, declared);
                },
                .table => try self.annotatePatternTargets(item, elem),
                else => {},
            }
        }
    }

    fn analyzeCompound(
        self: *SemanticChecker,
        target: *const cst.CstNode,
        op: cst.BinOp,
        value: *const cst.CstNode,
        span: Lexer.Span,
    ) !types_mod.TypeInfo {
        const tu = cst.unwrapParen(target);
        const assignable = if (tu) |u| u.kind == .ident or u.kind == .field or u.kind == .index or u.kind == .dotted_index else false;
        const lhs = if (assignable)
            try self.analyzeNode(target)
        else blk: {
            _ = try self.analyzeNode(value);
            const target_kind = if (tu) |u| @tagName(u.kind) else "nothing";
            try self.appendError(
                try self.alloc.print("cannot assign to {s}", .{target_kind}),
                target.span,
                "invalid assignment target",
            );
            break :blk types_mod.TypeInfo{ .tag = .any };
        };

        if (!assignable) return .{ .tag = .any };
        const rhs = try self.analyzeNode(value);

        try self.checkBinaryOperands(op, lhs, rhs, span);
        const result = types_mod.inferBinaryOp(op, lhs, rhs);

        try self.trackAssignTarget(target, result, value.span);
        return .{ .tag = .any };
    }

    /// shared operand checks for value-level binary ops
    /// ; `.binary` and `.compound_assign` lower to
    ///     the same opcodes so they check the same
    fn checkBinaryOperands(
        self: *SemanticChecker,
        op: cst.BinOp,
        l: types_mod.TypeInfo,
        r: types_mod.TypeInfo,
        span: Lexer.Span,
    ) !void {
        switch (op) {
            .add, .sub, .div, .int_div, .mod, .pow => {
                if ((l.tag == .number and r.tag == .string) or (l.tag == .string and r.tag == .number)) {
                    try self.appendError(
                        try self.alloc.print("cannot {s} {s} and {s}", .{ @tagName(op), try type_syntax.formatTypeOpts(self.alloc, l, .{}), try type_syntax.formatTypeOpts(self.alloc, r, .{}) }),
                        span,
                        "invalid operands",
                    );
                }
            },
            .mul => {
                if (!isOptimisticOperand(l) and !isOptimisticOperand(r) and (l.tag != .number or r.tag != .number)) {
                    try self.appendError(
                        try self.alloc.print("cannot multiply {s} and {s}", .{ try type_syntax.formatTypeOpts(self.alloc, l, .{}), try type_syntax.formatTypeOpts(self.alloc, r, .{}) }),
                        span,
                        "invalid operands",
                    );
                }
            },
            .concat => {},
            .band, .bor, .bxor, .shl, .shr => {
                if (!isOptimisticOperand(l) and !isOptimisticOperand(r) and (l.tag != .number or r.tag != .number)) {
                    try self.appendError(
                        try self.alloc.print("cannot apply {s} to {s} and {s}", .{ @tagName(op), try type_syntax.formatTypeOpts(self.alloc, l, .{}), try type_syntax.formatTypeOpts(self.alloc, r, .{}) }),
                        span,
                        "invalid operands",
                    );
                }
            },
            .eq, .neq, .lt, .gt, .lte, .gte => {},
            .@"union" => unreachable,
        }
    }

    fn trackAssignTarget(self: *SemanticChecker, target: *const cst.CstNode, value_type: types_mod.TypeInfo, value_span: Lexer.Span) !void {
        const tu = cst.unwrapParen(target) orelse {
            try self.appendError("cannot assign to nothing", target.span, "invalid assignment target");
            return;
        };
        switch (tu.kind) {
            .ident => |n| {
                const name = n.tok.text;
                if (self.typed_names.contains(name)) {
                    if (self.lookup(name)) |expected| {
                        if (!types_mod.canCoerce(value_type, expected)) {
                            try self.appendTypeMismatch(
                                value_span,
                                name,
                                expected,
                                value_type,
                            );
                        }
                    }
                }
                // reassignment keeps the binding's doc
                const prev_doc: ?[]const u8 = if (self.lookupEntry(name)) |e| e.doc else null;
                try self.declare(name, value_type, prev_doc);
            },
            .field => |field| {
                const object_type = try self.analyzeNode(field.object);

                if (object_type.tag == .table) {
                    if (cst.identText(field.object)) |oname| {
                        if (self.table_field_map.getPtr(oname)) |fields| {
                            try fields.put(field.name_tok.text, value_type);
                        }
                        try self.markEscaped(oname);
                    }
                }
            },
            .table => {
                try self.checkPatternTargets(target, value_type);
                try self.checkPatternAscriptions(target, value_type);
                _ = try self.declarePatternNames(target);
            },
            .dotted_index => |d| {
                _ = d;
                _ = try self.analyzeNode(tu);
            },
            .index => |idx| {
                // the key is an expression too
                // lowering reads its annotation
                _ = try self.analyzeNode(idx.key);

                // static keys join the known fields so later reads see
                // them; numbers stay untracked (never field names)
                if (cst.identText(idx.object)) |oname| {
                    const ku = cst.unwrapParen(idx.key);
                    const key_name: ?[]const u8 = if (ku) |k| switch (k.kind) {
                        .atom => |a| cst.atomName(a.tok.text),
                        .string => |s| s.tok.text,
                        else => null,
                    } else null;
                    if (key_name) |key| {
                        if (self.table_field_map.getPtr(oname)) |fields| {
                            try fields.put(key, value_type);
                        }
                    }
                }

                const actual_type = try self.analyzeNode(idx.object);
                // dynamic keys hide unknown content, known shape forgets fields
                // , so later reads stay sound, annotated bindings keep contract
                // mark first: redeclaring below shadows name into current scope
                // , which would defeat the outer-scope check
                if (cst.identText(idx.object)) |oname| {
                    if (actual_type.tag == .table and !self.typed_names.contains(oname)) {
                        try self.markEscaped(oname);
                        const ku = cst.unwrapParen(idx.key);
                        const static = if (ku) |k| k.kind == .atom or k.kind == .string else false;
                        if (!static and actual_type.tag.table.fields != null) {
                            var generic = actual_type;
                            generic.tag.table.fields = null;
                            const prev_doc = if (self.lookupEntry(oname)) |e| e.doc else null;
                            try self.declare(oname, generic, prev_doc);
                        }
                    }
                }
                if (!types_mod.canCoerce(types_mod.TABLE_GENERIC, actual_type)) {
                    const name_str = try type_syntax.formatTypeOpts(self.alloc, actual_type, .{});

                    try self.appendError(
                        try self.alloc.print("mutation is not allowed for {s}", .{name_str}),
                        idx.object.span,
                        "here",
                    );
                }
            },
            else => {
                const target_kind = @tagName(tu.kind);
                try self.appendError(
                    try self.alloc.print("cannot assign to {s}", .{target_kind}),
                    target.span,
                    "invalid assignment target",
                );
            },
        }
    }

    fn analyzeReturn(self: *SemanticChecker, val: ?*const cst.CstNode, span: Lexer.Span) !types_mod.TypeInfo {
        const expr = val orelse return .{ .tag = .any };
        const actual = try self.analyzeNode(expr);
        const expected = if (self.return_types.items.len != 0) self.return_types.items[self.return_types.items.len - 1] else types_mod.TypeInfo{ .tag = .any };
        if (expected.tag != .any and !types_mod.canCoerce(actual, expected)) {
            try self.appendReturnMismatch(span, expected, actual);
        }
        return .{ .tag = .any };
    }

    fn numberAccepts(expected: types_mod.TypeInfo, actual: types_mod.TypeInfo) bool {
        if (expected.tag == .number and actual.tag == .number) return true;
        return types_mod.canCoerce(actual, expected);
    }

    /// `any` and implicit `type_var` params are both optimistic
    /// : skip strict operand errors
    ///   , same as untyped code we had b4 generics
    fn isOptimisticOperand(t: types_mod.TypeInfo) bool {
        return t.tag == .any or t.tag == .type_var;
    }

    /// `obj:method(args)`, object is arg 0 at runtime
    fn analyzeMethodCall(
        self: *SemanticChecker,
        m: @FieldType(cst.CstKind, "method_call"),
        span: Lexer.Span,
    ) !types_mod.TypeInfo {
        _ = span;
        _ = try self.analyzeNode(m.object);
        const atom_text = m.atom_tok.text;
        const mname = if (atom_text.len > 0 and atom_text[0] == ':') atom_text[1..] else atom_text;
        // bang methods hit the compiler backstop; analyzing them would only
        // produce a worse error first
        if (std.mem.endsWith(u8, mname, "!")) return .{ .tag = .any };
        // build a transient field callee so the shared call path sees it
        const field_node = try cst.allocNode(self.alloc, m.atom_tok.span(), .{ .field = .{
            .object = m.object,
            .dot_tok = m.atom_tok,
            .name_tok = .{
                .type = .ident,
                .text = mname,
                .line = m.atom_tok.line,
                .column = m.atom_tok.column,
                .start = m.atom_tok.start,
                .end = m.atom_tok.end,
            },
        } });
        return try self.analyzeCallCst(field_node, m.args, &.{}, true, m.atom_tok.span());
    }

    fn analyzeCallCst(
        self: *SemanticChecker,
        callee: *const cst.CstNode,
        args: []const *const cst.CstNode,
        type_args: []const []const u8,
        implicit_self: bool,
        span: Lexer.Span,
    ) !types_mod.TypeInfo {
        _ = span;
        const callee_u = cst.unwrapParen(callee) orelse return .{ .tag = .any };
        // bare ident callees get the same unknown-name check as plain idents -
        // inferExprType would silently fall back to .any
        if (callee_u.kind == .ident) {
            const cname = callee_u.kind.ident.tok.text;
            // bang names are rejected by the compiler backstop; skip rather
            // than pile on a confusing unknown-name error
            if (std.mem.endsWith(u8, cname, "!")) {
                return .{ .tag = .any };
            }
            _ = try self.analyzeIdent(cname, callee.span);
        }
        if (callee_u.kind == .field) {
            const f = callee_u.kind.field;
            _ = try self.analyzeNode(f.object);
            // ~ dot-call callees read the field first (`t.f()`)
            // ~ colon-calls (`t:f()`) dispatch to methods
            // ~ `!` callees hit the compiler backstop; skip the field check
            // ~ a field that is also a baselib method (`t.len()`) dispatches
            //   at runtime, so only flag names that resolve to neither
            if (!implicit_self and !std.mem.endsWith(u8, f.name_tok.text, "!")) {
                const obj_type = types_mod.inferExprType(self.check(), f.object);
                // a dot-call matching a member of the object's module table
                // dispatches at runtime (`t.at(0)` finds `table.at`), so only
                // flag names that resolve to neither field nor module member
                const target: ?revo.baselib.host.ParamType = switch (obj_type.tag) {
                    .number => .number,
                    .string => .string,
                    .table => .table,
                    else => null,
                };
                const dispatches = if (target) |t| findModuleByNameAndTarget(f.name_tok.text, t) != null else false;
                if (!dispatches) try self.checkKnownField(f.object, f.name_tok.text, callee.span);
            }
        }

        const callee_type = switch (callee_u.kind) {
            .ident, .field => types_mod.inferExprType(self.check(), callee),
            else => try self.analyzeNode(callee),
        };

        // typed function call validation
        if (callee_type.tag == .function) {
            const sig_ptr = callee_type.tag.function;
            if (sig_ptr.is_any_fn_sig) {
                for (args) |arg| _ = try self.analyzeNode(arg);
                return .{ .tag = .any };
            }
            const sig = sig_ptr.*;
            const name: []const u8 = switch (callee_u.kind) {
                .ident => |n| n.tok.text,
                .field => |f| f.name_tok.text,
                .method_call => |m| blk: {
                    const t = m.atom_tok.text;
                    break :blk if (t.len > 0 and t[0] == ':') t[1..] else t;
                },
                else => "call",
            };
            const callee_obj: *const cst.CstNode = if (callee_u.kind == .field) callee_u.kind.field.object else callee;
            // method calls (implicit_self) prepend the object as arg 0 at runtime
            const self_offset: usize = if (implicit_self) 1 else 0;
            const total_args = args.len + self_offset;
            if (total_args < sig.required_count or (total_args > sig.params.len)) {
                const baselib_spec = find_spec: {
                    // same name can exist as both a global and a module
                    // member; match the call kind (`t:m()` prepends self,
                    // so only namespaced members pair with colon calls)
                    for (revo.baselib.specs.full_specs) |group| for (group) |*s| {
                        if (s.is_type) continue;
                        if (!std.mem.eql(u8, s.name, name)) continue;
                        const head = s.head;
                        if (implicit_self and head.kind == .namespaced) break :find_spec s;
                        if (!implicit_self and head.kind == .global) break :find_spec s;
                    };
                    break :find_spec revo.baselib.specs.findFn(name);
                };
                const is_variadic = if (baselib_spec) |sp| revo.baselib.specs.isVariadic(sp) else false;
                if (is_variadic and total_args >= sig.params.len -| 1) {
                    // variadic fns are fine with >= min
                } else if (total_args < sig.required_count) {
                    const label = try self.alloc.print("{d} missing args", .{
                        sig.required_count -| total_args,
                    });
                    try self.appendError(
                        try self.alloc.print("`{s}` wants at least {d} args, got {d}", .{
                            name, sig.required_count, total_args,
                        }),
                        callee.span,
                        label,
                    );
                } else if (total_args > sig.params.len) {
                    // point the caret at the arguments that don't fit instead
                    // of the callee; for a single-line call keep the header at
                    // the callee so `file:line:col` still points at the call
                    var extra_span = callee.span;
                    const params_in_args = sig.params.len -| self_offset;
                    if (params_in_args < args.len) {
                        extra_span = args[params_in_args].span;
                        for (args[params_in_args + 1 ..]) |arg| extra_span = Lexer.Span.merge(extra_span, arg.span);
                        if (extra_span.line == callee.span.line) extra_span.column = callee.span.column;
                    }
                    try self.appendError(
                        try self.alloc.print("`{s}` wants {d} args, got {d}", .{
                            name, sig.params.len, total_args,
                        }),
                        extra_span,
                        "extra args",
                    );
                }
            }
            // handle named arguments
            const has_named = for (args) |arg| {
                if (cst.namedArgName(arg) != null) break true;
            } else false;
            var named_seen = false;
            for (args, 0..) |arg, ai| {
                if (cst.namedArgName(arg) != null) {
                    named_seen = true;
                } else if (named_seen) {
                    try self.appendError(
                        try self.alloc.print("positional arg cannot follow named arg", .{}),
                        arg.span,
                        "here",
                    );
                }
                _ = ai;
            }
            for (args, 0..) |arg, i| {
                if (cst.namedArgName(arg)) |pn| {
                    for (args[i + 1 ..]) |later_arg| {
                        if (cst.namedArgName(later_arg)) |later_pn| {
                            if (std.mem.eql(u8, pn, later_pn)) {
                                try self.appendError(
                                    try self.alloc.print("duplicate named arg `{s}`", .{pn}),
                                    later_arg.span,
                                    "already specified",
                                );
                            }
                        }
                    }
                }
            }
            if (has_named) {
                for (0..sig.params.len) |i| {
                    if (implicit_self and i == 0) {
                        const actual = types_mod.inferExprType(self.check(), callee_obj);
                        const expected = sig.params[i];
                        if (!numberAccepts(expected, actual)) {
                            const expected_str = try type_syntax.formatTypeOpts(self.alloc, expected, .{});
                            const actual_str = try type_syntax.formatTypeOpts(self.alloc, actual, .{});
                            try self.appendError(
                                try self.alloc.print("arg 1 to `{s}` wants {s}, got {s}", .{
                                    name, expected_str, actual_str,
                                }),
                                callee_obj.span,
                                try self.alloc.print("not {s} (got {s})", .{
                                    expected_str, actual_str,
                                }),
                            );
                        }
                        continue;
                    }
                    const pi = i - self_offset;
                    const expected = sig.params[i];
                    var found = false;
                    for (args) |arg| {
                        if (cst.namedArgName(arg)) |pn| {
                            if (pi < sig.param_names.len and std.mem.eql(u8, sig.param_names[pi], pn)) {
                                const argv = cst.namedArgValue(arg) orelse continue;
                                _ = try self.analyzeNode(argv);
                                const actual = types_mod.inferExprType(self.check(), argv);
                                if (expected.tag == .type_var) continue;
                                if (!numberAccepts(expected, actual)) {
                                    const expected_str = try type_syntax.formatTypeOpts(self.alloc, expected, .{});
                                    const actual_str = try type_syntax.formatTypeOpts(self.alloc, actual, .{});
                                    try self.appendError(
                                        try self.alloc.print("arg `{s}` to `{s}` wants {s}, got {s}", .{
                                            pn, name, expected_str, actual_str,
                                        }),
                                        arg.span,
                                        try self.alloc.print("not {s} (got {s})", .{
                                            expected_str, actual_str,
                                        }),
                                    );
                                }
                                found = true;
                                break;
                            }
                        }
                    }
                    if (!found and pi < args.len) {
                        _ = try self.analyzeNode(args[pi]);
                        const actual = types_mod.inferExprType(self.check(), args[pi]);
                        if (expected.tag == .type_var) continue;
                        if (!numberAccepts(expected, actual)) {
                            const param_name = if (pi < sig.param_names.len and sig.param_names[pi].len > 0) sig.param_names[pi] else "";
                            const expected_str = try type_syntax.formatTypeOpts(self.alloc, expected, .{});
                            const actual_str = try type_syntax.formatTypeOpts(self.alloc, actual, .{});
                            try self.appendError(
                                try self.alloc.print("arg {d} (`{s}`) to `{s}` wants {s}, got {s}", .{
                                    pi + 1, param_name, name, expected_str, actual_str,
                                }),
                                args[pi].span,
                                try self.alloc.print("not {s} (got {s})", .{
                                    expected_str, actual_str,
                                }),
                            );
                        }
                    }
                }
                return self.substituteCallReturnType(sig_ptr, callee, args, type_args, implicit_self);
            }
            const count = if (total_args < sig.params.len) total_args else sig.params.len;
            for (0..count) |i| {
                const expected = sig.params[i];
                const actual = if (implicit_self and i == 0)
                    types_mod.inferExprType(self.check(), callee_obj)
                else
                    try self.analyzeNode(args[i - self_offset]);
                if (expected.tag == .type_var) continue;
                if (!numberAccepts(expected, actual)) {
                    const param_name = if (i < sig.param_names.len and sig.param_names[i].len > 0) sig.param_names[i] else "";
                    const expected_str = try type_syntax.formatTypeOpts(self.alloc, expected, .{});
                    const actual_str = try type_syntax.formatTypeOpts(self.alloc, actual, .{});
                    const msg = if (implicit_self and i == 0)
                        try self.alloc.print("arg 1 (`{s}`) to `{s}` wants {s}, got {s}", .{
                            param_name, name, expected_str, actual_str,
                        })
                    else
                        try self.alloc.print("arg {d} (`{s}`) to `{s}` wants {s}, got {s}", .{
                            i + 1, param_name, name, expected_str, actual_str,
                        });
                    try self.appendError(
                        msg,
                        if (implicit_self and i == 0) callee_obj.span else args[i - self_offset].span,
                        try self.alloc.print("not {s} (got {s})", .{
                            expected_str, actual_str,
                        }),
                    );
                }
            }
            return self.substituteCallReturnType(sig_ptr, callee, args, type_args, implicit_self);
        }

        for (args) |arg| _ = try self.analyzeNode(arg);
        return types_mod.TypeInfo{ .tag = .any };
    }

    fn substituteCallReturnType(
        self: *SemanticChecker,
        sig: *const types_mod.FunctionSignature,
        callee: *const cst.CstNode,
        args: []const *const cst.CstNode,
        type_args: []const []const u8,
        implicit_self: bool,
    ) types_mod.TypeInfo {
        if (sig.type_params.len == 0 or sig.return_type.tag == .any) return sig.return_type;
        // inside function body where these type params are in scope?
        // if so, keep type vars abstract (no substitution)
        for (sig.type_params) |tp| {
            for (self.current_type_params) |ctp| {
                if (std.mem.eql(u8, tp, ctp)) return sig.return_type;
            }
        }
        const eff = types_mod.effectiveArgs(self.alloc, sig.params.len, callee, args, implicit_self) catch return sig.return_type;
        return types_mod.substCallReturn(self.check(), sig, callee, eff, type_args, false);
    }

    fn findModuleByNameAndTarget(name: []const u8, target: revo.baselib.host.ParamType) ?*const revo.baselib.specs.FnSpec {
        const module_name = target.moduleName() orelse return null;
        for (revo.baselib.specs.full_specs) |group| {
            for (group) |*spec| {
                if (spec.is_type) continue;
                if (!std.mem.eql(u8, spec.name, name)) continue;
                const head = spec.head;
                if (head.kind == .namespaced and std.mem.eql(u8, head.module.?, module_name)) return spec;
            }
        }
        return null;
    }

    /// `if` and `unless` check identically; only codegen branches differently
    fn analyzeBranch(
        self: *SemanticChecker,
        cond: *const cst.CstNode,
        then: *const cst.CstNode,
        else_: ?*const cst.CstNode,
    ) !types_mod.TypeInfo {
        _ = try self.analyzeNode(cond);
        const then_type = try self.analyzeNode(then);
        if (else_) |else_expr| {
            const else_type = try self.analyzeNode(else_expr);

            return if (then_type.tag == .any) else_type else then_type;
        }
        return .{ .tag = .any };
    }

    fn appendTypeMismatch(
        self: *SemanticChecker,
        span: Lexer.Span,
        name: []const u8,
        expected: types_mod.TypeInfo,
        actual: types_mod.TypeInfo,
    ) !void {
        const expected_str = try type_syntax.formatTypeOpts(self.alloc, expected, .{});
        const actual_str = try type_syntax.formatTypeOpts(self.alloc, actual, .{});
        const msg = try self.alloc.print("`{s}` wants {s}, got {s}", .{
            name,
            expected_str,
            actual_str,
        });
        const label = try self.alloc.print(
            "wants {s}, got {s}",
            .{ expected_str, actual_str },
        );
        if (self.first_code == null) self.first_code = "type-mismatch";
        try self.appendError(msg, span, label);
    }

    fn appendReturnMismatch(self: *SemanticChecker, span: Lexer.Span, expected: types_mod.TypeInfo, actual: types_mod.TypeInfo) !void {
        const expected_str = try type_syntax.formatTypeOpts(self.alloc, expected, .{});
        const actual_str = try type_syntax.formatTypeOpts(self.alloc, actual, .{});
        const msg = try self.alloc.print("return type mismatch: wanted {s}, got {s}", .{
            expected_str,
            actual_str,
        });
        try self.appendError(msg, span, try self.alloc.print("return type not {s} (got {s})", .{
            expected_str,
            actual_str,
        }));
    }

    fn appendError(self: *SemanticChecker, message: []const u8, span: Lexer.Span, label: []const u8) !void {
        try self.errors.append(self.alloc, .{ .@"error" = message });
        try self.errors.append(self.alloc, .{ .span = .{ .span = span, .role = .primary, .message = try self.alloc.dupe(u8, label) } });
    }

    fn appendWarn(self: *SemanticChecker, message: []const u8, span: Lexer.Span, label: []const u8, code: []const u8) !void {
        if (self.first_warn_code == null) self.first_warn_code = code;
        try self.warn_parts.append(self.alloc, .{ .warn = message });
        try self.warn_parts.append(self.alloc, .{ .span = .{ .span = span, .role = .primary, .message = try self.alloc.dupe(u8, label) } });
    }
};
