//! symbol collection, sig maps, workspace symbol index

const std = @import("std");

const revo = @import("revo");

const cst = @import("../cst.zig");
const Lexer = @import("../Lexer.zig");
const common = @import("common.zig");
const pipeline = @import("../pipeline.zig");
const txt = @import("text.zig");
const type_syntax = @import("../type_syntax.zig");
const types = @import("../compiler/types.zig");

const W = @import("../Workspace.zig");
const Workspace = W.Workspace;
const FileId = W.FileId;
const Location = W.Location;
const Snapshot = W.Snapshot;
const Symbol = W.Symbol;
const SymbolKind = W.SymbolKind;
const FnSig = W.FnSig;
const ParamInfo = W.ParamInfo;
const IndexedSymbol = W.IndexedSymbol;

pub fn rebuildSymbolIndex(self: *Workspace) void {
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

/// outline syms for a file
pub fn documentSymbols(
    self: *Workspace,
    alloc: std.mem.Allocator,
    id: FileId,
    opts: pipeline.BuildOptions,
) ![]Symbol {
    const entry = try self.ensureInspect(alloc, id, opts);
    // params resolve for hover/def but dont outline
    return common.copyFilteredSymbols(alloc, entry.symbols, true);
}

///
/// walk cst & collect
///     bindings, functions, type aliases
///
pub fn collectSymbolsFromParsed(self: *Workspace, root: *cst.CstNode, text: []const u8) ![]Symbol {
    var out = try std.ArrayList(Symbol).initCapacity(self.alloc, 8);
    errdefer out.deinit(self.alloc);
    var visitor = SymbolVisitor{ .alloc = self.alloc, .out = &out, .text = text };
    visitor.visit(root);
    return out.toOwnedSlice(self.alloc);
}

/// walk cst for fn_expr bindings and populate sig_map with ParamInfo slices
pub fn collectSigsFromParsed(
    self: *Workspace,
    root: *const cst.CstNode,
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

    /// evalTypeExpr can return shared comptime sentinels or types borrowing cst
    /// sig_map can outlive both so we need deepcopy
    fn ownedType(self: *@This(), te: *const cst.CstType) ?types.TypeInfo {
        const t = types.evalBare(self.alloc, te) catch return null;
        return types.clone(t, self.alloc) catch null;
    }

    fn paramInfos(self: *@This(), params: []const cst.CstParam) ?[]ParamInfo {
        const out = self.alloc.alloc(ParamInfo, params.len) catch return null;
        errdefer self.alloc.free(out);
        for (params, out) |src, *dst| {
            dst.* = .{
                .name = self.alloc.dupe(u8, src.name_tok.text) catch return null,
                .type_name = if (src.type) |te| self.ownedType(te) else null,
                .optional = src.qmark_tok != null or src.default != null,
            };
        }
        return out;
    }

    fn typeParamTexts(self: *@This(), toks: []const revo.lang.Token) ?[]const u8 {
        const texts = self.alloc.alloc([]const u8, toks.len) catch return null;
        for (toks, texts) |tok, *dst| dst.* = tok.text;
        return common.formatTypeParams(self.alloc, texts) catch return null;
    }

    pub fn visit(self: *@This(), node: *const cst.CstNode) void {
        const u = cst.unwrapParen(node) orelse return;
        switch (u.kind) {
            .type_alias => |t| {
                if (t.segs.len == 0) return;
                if (t.type.kind != .function) return;
                const f = t.type.kind.function;
                const name = t.segs[t.segs.len - 1].text;

                const params = self.alloc.alloc(ParamInfo, f.params.len) catch return;
                errdefer self.alloc.free(params);
                for (f.params, params) |src, *dst| {
                    dst.* = .{
                        .name = self.alloc.dupe(u8, src.name_tok.text) catch return,
                        .type_name = if (src.type) |te| self.ownedType(te) else null,
                        .optional = src.qmark_tok != null or src.dots.len > 0,
                    };
                }

                const return_type: ?types.TypeInfo = if (f.ret) |rt| self.ownedType(rt) else null;

                const name_owned = self.alloc.dupe(u8, name) catch return;
                self.sig_map.put(self.alloc, name_owned, .{
                    .params = params,
                    .return_type = return_type,
                }) catch return;
            },
            .binding => |b| {
                const bt = cst.unwrapParen(b.target) orelse return;
                if (bt.kind != .ident) return;
                const name = bt.kind.ident.tok.text;
                const bv = cst.unwrapParen(b.value) orelse return;
                if (bv.kind == .fn_def) {
                    const f = bv.kind.fn_def;

                    const params = self.paramInfos(f.params) orelse return;

                    const name_owned = self.alloc.dupe(u8, name) catch return;
                    self.sig_map.put(self.alloc, name_owned, .{
                        .params = params,
                        .return_type = null,
                        .type_params_text = self.typeParamTexts(f.type_params),
                    }) catch return;
                    return;
                }
                // ascribed re-export:
                // the value isn't a literal fn, so the sig comes from the annotation instead
                const tn = b.type orelse return;
                const ft_owned = self.ownedType(tn) orelse return;
                var ft = ft_owned;

                defer types.deinitType(&ft, self.alloc);
                if (ft.tag != .function) return;

                const fsig = ft.tag.function;
                const params = self.alloc.alloc(ParamInfo, fsig.params.len) catch return;
                errdefer self.alloc.free(params);

                for (fsig.params, fsig.param_names, params, 0..) |pt, pn, *dst, i| {
                    dst.* = .{
                        .name = self.alloc.dupe(u8, pn) catch return,
                        .type_name = types.clone(pt, self.alloc) catch return,
                        .optional = i >= fsig.required_count,
                    };
                }

                const return_type: ?types.TypeInfo = types.clone(fsig.return_type, self.alloc) catch null;
                const name_owned = self.alloc.dupe(u8, name) catch return;
                self.sig_map.put(self.alloc, name_owned, .{
                    .params = params,
                    .return_type = return_type,
                    .type_params_text = common.formatTypeParams(self.alloc, fsig.type_params) catch return,
                }) catch return;
            },
            .assign => |ae| {
                const av = cst.unwrapParen(ae.value) orelse return;
                if (av.kind != .fn_def) return;
                const at = cst.unwrapParen(ae.target) orelse return;

                const name: []const u8 = switch (at.kind) {
                    .field => |f| f.name_tok.text,
                    .ident => |i| i.tok.text,
                    else => return,
                };

                const params = self.paramInfos(av.kind.fn_def.params) orelse return;

                const return_type: ?types.TypeInfo = null;
                const name_owned = self.alloc.dupe(u8, name) catch return;
                self.sig_map.put(self.alloc, name_owned, .{
                    .params = params,
                    .return_type = return_type,
                    .type_params_text = self.typeParamTexts(av.kind.fn_def.type_params),
                }) catch return;
            },
            .fn_def => |f| {
                // anon fns contribute no named sig; named ones arrive via binding
                _ = f;
            },
            else => cst.walkCst(@This(), self, node),
        }
    }
};

/// walk cst for import expressions and resolve them to FileIds
pub fn collectDepsFromParsed(self: *Workspace, snap: Snapshot, root: *cst.CstNode) ![]FileId {
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

const SymbolVisitor = struct {
    alloc: std.mem.Allocator,
    out: *std.ArrayList(Symbol),
    text: []const u8,
    /// a binding like `const x = import "foo"` names the module itself
    import_named: bool = false,

    pub fn visit(self: *@This(), node: *const cst.CstNode) void {
        const u = cst.unwrapParen(node) orelse return;
        switch (u.kind) {
            .binding => |b| self.addBinding(b),
            .fn_def => |f| for (f.params) |param| self.addName(param.name_tok.text, .param, param.name_tok.span()),
            .type_alias => |t| if (t.segs.len > 0) self.addName(t.segs[t.segs.len - 1].text, .type_alias, t.segs[0].span()),
            .import => |im| {
                if (self.import_named) {
                    self.import_named = false;
                    if (im.items.len != 1) {
                        for (im.items) |item| {
                            const nm: []const u8 = if (item.name_tok) |nt| nt.text else std.Io.Dir.path.stem(item.path.text);
                            self.addName(nm, .binding, self.importNameSpan(node, nm));
                        }
                    }
                } else {
                    for (im.items) |item| {
                        const nm: []const u8 = if (item.name_tok) |nt| nt.text else std.Io.Dir.path.stem(item.path.text);
                        self.addName(nm, .binding, self.importNameSpan(node, nm));
                    }
                }
            },
            else => {},
        }
        // decls fall through
        // walkCst reaches every binding exactly once
        cst.walkCst(SymbolVisitor, self, node);
    }

    fn addBinding(self: *@This(), b: @FieldType(cst.CstKind, "binding")) void {
        const bv = cst.unwrapParen(b.value);
        self.import_named = if (bv) |v| v.kind == .import else false;
        const bt = cst.unwrapParen(b.target) orelse return;
        switch (bt.kind) {
            .ident => |n| {
                const name = n.tok.text;
                const before = self.out.items.len;
                self.addName(name, .binding, b.target.span);
                // table literals carry hover previews on the just-added
                // symbol (append-only, so a failed addName leaves len alone)
                if (bv != null and bv.?.kind == .table and self.out.items.len > before) {
                    if (self.tableFieldPreviews(bv.?.kind.table.entries)) |previews| {
                        self.out.items[self.out.items.len - 1].field_values = previews;
                    }
                }
            },
            .table => |tbl| {
                for (tbl.entries) |entry| {
                    if (entry != .bare) continue;
                    const item = entry.bare.value;
                    const iu = cst.unwrapParen(item) orelse continue;
                    if (iu.kind == .ident and !cst.isDiscardName(iu.kind.ident.tok.text))
                        self.addName(iu.kind.ident.tok.text, .binding, item.span);
                }
            },
            else => {},
        }
    }

    /// condensed `{k = v}` source slices for single-line literal fields;
    /// null when nothing previewable
    fn tableFieldPreviews(self: *@This(), entries: []const cst.CstEntry) ?[]type_syntax.FieldPreview {
        var out = std.ArrayList(type_syntax.FieldPreview).initCapacity(self.alloc, entries.len) catch return null;
        var implicit_idx: u32 = 0;
        for (entries) |entry| {
            if (entry == .bare) {
                const bu = cst.unwrapParen(entry.bare.value);
                if (bu != null and bu.?.kind == .decl) {
                    const inner = cst.unwrapParen(bu.?.kind.decl.inner);
                    if (inner != null and inner.?.kind == .binding) {
                        const bv = cst.unwrapParen(inner.?.kind.binding.value);
                        if (bv != null and bv.?.kind == .fn_def) continue;
                    }
                }
            }

            const name: ?[]const u8 = switch (entry) {
                .computed => null,
                .keyed => |k| blk: {
                    const ku = cst.unwrapParen(k.key) orelse break :blk null;
                    break :blk switch (ku.kind) {
                        .ident => |n| n.tok.text,
                        .atom => |a| cst.atomName(a.tok.text),
                        else => null,
                    };
                },
                .bare => null,
            };
            if (name) |n| {
                const vnode = switch (entry) {
                    .computed => |cc| cc.value,
                    .keyed => |k| k.value,
                    .bare => |b| b.value,
                };
                const span = vnode.span;
                if (span.end > self.text.len or span.start > span.end) continue;
                const slice = self.text[span.start..span.end];
                if (slice.len == 0 or std.mem.findScalar(u8, slice, '\n') != null) continue;

                out.append(self.alloc, .{
                    .name = self.alloc.dupe(u8, n) catch return null,
                    .preview = self.alloc.dupe(u8, slice) catch return null,
                }) catch return null;
            } else {
                const idx = implicit_idx;
                implicit_idx += 1;
                const vnode2 = switch (entry) {
                    .computed => |cc| cc.value,
                    .keyed => |k| k.value,
                    .bare => |b| b.value,
                };
                const span = vnode2.span;

                if (span.end > self.text.len or span.start > span.end) continue;
                const slice = self.text[span.start..span.end];
                if (slice.len == 0 or std.mem.findScalar(u8, slice, '\n') != null) continue;

                out.append(self.alloc, .{
                    .name = self.alloc.print("{d}", .{idx}) catch return null,
                    .preview = self.alloc.dupe(u8, slice) catch return null,
                }) catch return null;
            }
        }
        if (out.items.len == 0) return null;
        return out.toOwnedSlice(self.alloc) catch null;
    }

    /// module name = right after the path's opening quote; fall back to the
    /// whole statement (subdir paths, table form)
    fn importNameSpan(self: *@This(), node: *const cst.CstNode, name: []const u8) Lexer.Span {
        var q = node.span.start;
        while (q < node.span.end and self.text[q] != '\'' and self.text[q] != '"') q += 1;
        const start = q + 1;

        if (q >= node.span.end or start + name.len > node.span.end) return node.span;
        if (!std.mem.eql(u8, self.text[start .. start + name.len], name)) return node.span;
        if (start + name.len < node.span.end and txt.isWordChar(self.text[start + name.len])) return node.span;

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

    fn addName(self: *@This(), name: []const u8, kind: SymbolKind, span: Lexer.Span) void {
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

//
// import visitor
//

const ImportVisitor = struct {
    ws: *Workspace,
    out: *std.ArrayList(FileId),
    base: []const u8,
    mode: pipeline.ProjectMode,
    project_root: []const u8,
    failed: bool,

    // walk the cst; collect import statements and resolve them
    pub fn visit(self: *@This(), node: *const cst.CstNode) void {
        const u = cst.unwrapParen(node) orelse return;
        if (u.kind == .import) {
            const raw = if (u.kind.import.items.len > 0) u.kind.import.items[0].path.text else "";
            if (raw.len != 0) {
                const id = self.ws.resolveOpenImport(self.base, raw, self.mode, self.project_root) orelse
                    self.ws.resolveOpenImportOrOpen(self.base, raw, self.mode, self.project_root);
                if (id) |resolved| {
                    if (!txt.containsId(self.out.items, resolved)) {
                        self.out.append(self.ws.alloc, resolved) catch {
                            self.failed = true;
                        };
                    }
                }
            }
        }
        cst.walkCst(ImportVisitor, self, node);
    }
};

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
