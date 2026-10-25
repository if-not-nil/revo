const cst = @import("cst.zig");
const std = @import("std");
const types = @import("compiler/types.zig");
const TypeInfo = types.TypeInfo;

/// ======================= pub iface of mod cst ==========================
/// this bhv shold be
/// ~ record type for the import binding & resolved type aliases
/// ~ pub fn bindings get signature types (dep generics scoped correctly)
/// ~ pub consts get literal-inferred types (or any)
/// ~ pub re-exports get any
/// ~ non pub items are skipped
///
/// ~ type aliases are compile-time only (not values)
/// ~ record is null unless a pub export or an ascribed tail types it
///   (TOOD: give them types like all real closures)
/// ~ dep-local names resolve inside the dep, never in importer scope,,, all hermetic
/// ~ names borrow dep src
/// =======================================================================
pub const ModuleAlias = struct {
    name: []const u8,
    info: TypeInfo,
};

pub const ModuleIface = struct {
    record: ?TypeInfo,
    aliases: []const ModuleAlias,
};

pub fn moduleInterface(alloc: std.mem.Allocator, items: []const *const cst.CstNode) !ModuleIface {
    var mctx = ModuleCtx{
        .alloc = alloc,
        .raws = std.StringHashMap(*cst.CstType).init(alloc),
        .resolved = std.StringHashMap(types.Alias).init(alloc),
    };
    defer mctx.raws.deinit();
    defer mctx.resolved.deinit();

    for (items) |item| {
        if (item.kind != .decl) continue;
        const d = item.kind.decl;

        if (d.inner.kind == .type_alias) {
            const t = d.inner.kind.type_alias;
            if (t.segs.len == 0) continue;
            try mctx.raws.put(cst.aliasName(t), t.type);
        }
    }
    // resolve in file order, repeating until stable
    // later aliases see earlier ones, so the longest dep chain fits in count+1 passes and
    // cycles settle on whatever completed instead of recursing forever
    var round: usize = 0;
    var stable = false;

    while (!stable and round <= mctx.raws.count()) : (round += 1) {
        stable = true;

        for (items) |item| {
            if (item.kind != .decl) continue;
            const d = item.kind.decl;
            if (d.inner.kind != .type_alias) continue;

            const t = d.inner.kind.type_alias;
            if (t.segs.len == 0) continue;
            const name = cst.aliasName(t);
            const ti = mctx.resolveOne(name) orelse continue;

            if (mctx.resolved.get(name)) |old| {
                if (!types.eqlExact(old.info, ti)) {
                    try mctx.resolved.put(name, .{ .info = ti });
                    stable = false;
                }
            } else {
                try mctx.resolved.put(name, .{ .info = ti });
                stable = false;
            }
        }
    }

    var out = try std.ArrayList(types.RecordField).initCapacity(alloc, items.len);
    errdefer out.deinit(alloc);
    for (items) |item| try moduleExportInto(&mctx, item, &out);
    var aliases = try std.ArrayList(ModuleAlias).initCapacity(alloc, mctx.raws.count());
    errdefer aliases.deinit(alloc);

    for (items) |item| {
        if (item.kind != .decl) continue;
        const d = item.kind.decl;
        if (!d.pub_ or d.inner.kind != .type_alias) continue;

        const t = d.inner.kind.type_alias;
        if (t.segs.len == 0) continue;
        const name = cst.aliasName(t);

        if (mctx.resolved.get(name)) |a| {
            try aliases.append(alloc, .{ .name = name, .info = a.info });
        }
    }
    if (out.items.len == 0) {
        // a pub-less module is its last expression, so an ascribed tail
        // binding types the import flat, no declare needed:
        //   const e: { add: fn(number) -> number } = import "./ext.so"
        //   e
        const tail = tailBindingType(&mctx, items);
        return .{ .record = tail, .aliases = try aliases.toOwnedSlice(alloc) };
    }
    const value = try alloc.create(TypeInfo);
    value.* = .{ .tag = .any };
    return .{
        .record = types.makeTable(null, value, try out.toOwnedSlice(alloc)),
        .aliases = try aliases.toOwnedSlice(alloc),
    };
}

/// evaluation scope for one module's interface
/// ~ dep aliases resolve here  (never in the importer's scope)
/// ~ fn type params scope per fn
const ModuleCtx = struct {
    alloc: std.mem.Allocator,
    raws: std.StringHashMap(*cst.CstType),
    resolved: std.StringHashMap(types.Alias),
    type_params: []const []const u8 = &.{},

    pub fn aliasScope(self: *ModuleCtx) types.AliasScope {
        return .{
            .alloc = self.alloc,
            .type_params = self.type_params,
            .aliases = &self.resolved,
        };
    }

    pub fn check(self: *ModuleCtx) types.CheckCtx {
        var ctx = types.CheckCtx.init(self, self.alloc);
        ctx.scope = self.aliasScope();
        return ctx;
    }

    fn resolveOne(self: *ModuleCtx, name: []const u8) ?TypeInfo {
        const raw = self.raws.get(name) orelse return null;
        return types.evalTypeExpr(self.aliasScope(), raw) catch null;
    }

    pub fn inferIdentType(_: *ModuleCtx, _: []const u8) TypeInfo {
        return .{ .tag = .any };
    }

    pub fn inferCallReturnType(
        _: *ModuleCtx,
        _: *const cst.CstNode,
        _: []const *const cst.CstNode,
        _: []const []const u8,
        _: bool,
    ) TypeInfo {
        return .{ .tag = .any };
    }

    pub fn inferFieldType(_: *ModuleCtx, _: *const cst.CstNode, _: []const u8) TypeInfo {
        return .{ .tag = .any };
    }

    pub fn inferFnType(
        self: *ModuleCtx,
        params: []const cst.CstParam,
        return_type: ?*const cst.CstType,
        type_params: []const []const u8,
        doc: ?[]const u8,
    ) TypeInfo {
        const saved = self.type_params;
        const combined = types.combinedTypeParams(self.alloc, type_params, params) catch type_params;
        self.type_params = combined;
        defer self.type_params = saved;

        const sig = types.buildFnSig(
            self.alloc,
            self,
            params,
            return_type,
            combined,
            doc,
            .{ .degrade_param = true },
        ) catch return .{ .tag = .any };

        return .{ .tag = .{ .function = sig } };
    }
};

fn moduleExportInto(mctx: *ModuleCtx, node: *const cst.CstNode, out: *std.ArrayList(types.RecordField)) !void {
    const alloc = mctx.alloc;
    switch (node.kind) {
        .decl => |d| {
            // host contracts, no runtime value
            if (d.kind == .declare_decl and d.inner.kind == .type_alias) {
                if (!d.pub_) return;
                const t = d.inner.kind.type_alias;
                if (t.segs.len == 0) return;
                const ft = types.evalTypeExpr(mctx.aliasScope(), t.type) catch TypeInfo{ .tag = .any };
                try out.append(alloc, .{ .name = t.segs[0].text, .field_type = ft });
                return;
            }
            if (!d.pub_) return;
            switch (d.inner.kind) {
                .binding => |b| {
                    if (b.target.kind != .ident) return;
                    // ascription wins over inference, as in analyzeBinding
                    const inferred = types.inferExprType(mctx.check(), b.value);
                    const field_type = if (b.type) |tn|
                        types.evalTypeExpr(mctx.aliasScope(), tn) catch inferred
                    else
                        inferred;
                    try out.append(alloc, .{
                        .name = b.target.kind.ident.tok.text,
                        // inferred with the module ctx: unknown names
                        // degrade to any inside inference, so nothing
                        // leaks across scopes
                        .field_type = field_type,
                    });
                },
                // type aliases are compile-time only so skip them
                else => {},
            }
        },
        // re-exports resolve in sub-dep scope, not here
        // were it not any-typed, the reads could false-flag
        .import => |im| {
            if (!(im.pub_ or false)) {
                // check per-item pub too
                var any_pub = im.pub_;
                for (im.items) |it| if (it.pub_) {
                    any_pub = true;
                    break;
                };
                if (!any_pub) return;
            }
            for (im.items) |it| {
                const is_pub = it.pub_ or im.pub_;
                if (!is_pub) continue;
                const nm: []const u8 = if (it.name_tok) |nt| nt.text else std.Io.Dir.path.stem(it.path.text);
                try out.append(alloc, .{
                    .name = nm,
                    .field_type = .{ .tag = .any },
                });
            }
        },
        else => {},
    }
}
/// the name a pub-less module evaluates to: a trailing `return e`, `e` or
///   `const e = ...`, null otherwise
fn tailBindingName(items: []const *const cst.CstNode) ?[]const u8 {
    if (items.len == 0) return null;
    const last = items[items.len - 1];
    const unwrapped = cst.unwrapParen(last) orelse return null;
    if (unwrapped.kind == .decl and unwrapped.kind.decl.inner.kind == .binding) {
        const b = unwrapped.kind.decl.inner.kind.binding;
        if (b.target.kind == .ident and !cst.isDiscardName(b.target.kind.ident.tok.text)) return b.target.kind.ident.tok.text;
        return null;
    }
    switch (unwrapped.kind) {
        .return_expr => |r| {
            const v = r.value orelse return null;
            const inner = cst.unwrapParen(v) orelse return null;
            if (inner.kind != .ident or cst.isDiscardName(inner.kind.ident.tok.text)) return null;
            return inner.kind.ident.tok.text;
        },
        .ident => |n| {
            if (cst.isDiscardName(n.tok.text)) return null;
            return n.tok.text;
        },
        else => return null,
    }
}

/// the tail binding's ascription, newest binding first
fn tailBindingType(mctx: *ModuleCtx, items: []const *const cst.CstNode) ?TypeInfo {
    const name = tailBindingName(items) orelse return null;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        const item = items[i];
        const unwrapped = cst.unwrapParen(item) orelse continue;
        if (unwrapped.kind == .decl and unwrapped.kind.decl.inner.kind == .binding) {
            const b = unwrapped.kind.decl.inner.kind.binding;
            if (b.target.kind == .ident and std.mem.eql(u8, b.target.kind.ident.tok.text, name)) {
                if (b.type) |tn| {
                    return types.evalTypeExpr(mctx.aliasScope(), tn) catch null;
                }
                return null;
            }
        }
        if (unwrapped.kind == .import) {
            const im = unwrapped.kind.import;
            for (im.items) |it| {
                const nm: []const u8 = if (it.name_tok) |nt| nt.text else std.Io.Dir.path.stem(it.path.text);
                if (std.mem.eql(u8, nm, name)) return null;
            }
        }
    }
    return null;
}
