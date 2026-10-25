const std = @import("std");

const cst = @import("../cst.zig");
const Lexer = @import("../Lexer.zig");
const Node = cst.CstNode;

/// build @exports[:name] = name (cst form: assign{target=index, value=ident})
fn buildSetExport(alloc: std.mem.Allocator, span: Lexer.Span, name: []const u8) !*Node {
    const exports_ref = try cst.allocIdent(alloc, span, "@exports");
    const atom_tok = cst.syntheticToken(name, span);

    // atom text habe the leading `:` for lowering parity
    // name here is bare so synthesize `:name`
    // callers pass bare names from pubName
    const colon_name = try alloc.print(":{s}", .{name});
    const key = try cst.allocNode(alloc, span, .{ .atom = .{ .tok = .{
        .type = .atom,
        .text = colon_name,
        .line = span.line,
        .column = span.column,
        .start = span.start,
        .end = span.end,
    } } });
    _ = atom_tok;
    const index = try cst.allocNode(alloc, span, .{ .index = .{
        .object = exports_ref,
        .lbracket_tok = cst.syntheticToken("[", span),
        .key = key,
        .rbracket_tok = cst.syntheticToken("]", span),
    } });
    const value = try cst.allocIdent(alloc, span, name);
    return cst.allocNode(alloc, span, .{ .assign = .{
        .target = index,
        .eq_tok = cst.syntheticToken("=", span),
        .value = value,
    } });
}

/// extract exported name from a pub decl or import
fn pubName(item: *Node) ?[]const u8 {
    return switch (item.kind) {
        .decl => |d| if (d.pub_) switch (d.inner.kind) {
            .binding => |b| if (b.target.kind == .ident) b.target.kind.ident.tok.text else null,
            else => null,
        } else null,
        .import => |im| {
            // single autobind import exports its stem name when pub
            if (im.pub_ and im.items.len == 1) {
                const it = im.items[0];
                if (it.name_tok) |nt| return nt.text;
                // autobind: stem of path
                return std.Io.Dir.path.stem(it.path.text);
            }
            return null;
        },
        else => null,
    };
}

/// copy a node without its pub_ flag, leaves non-pub nodes unchanged
fn clearPub(item: *Node, alloc: std.mem.Allocator) !*Node {
    switch (item.kind) {
        .decl => |d| {
            const out = try cst.allocNode(alloc, item.span, .{ .decl = .{
                .pub_tok = d.pub_tok,
                .kind = d.kind,
                .inner = d.inner,
                .pub_ = false,
            } });
            // construction time, never on shared nodes
            if (item.doc_tok) |dt| cst.attachDoc(out, dt);
            out.attrs = item.attrs;
            return out;
        },
        .import => |im| {
            const items = try alloc.dupe(cst.CstImportItem, im.items);
            for (items) |*it| it.pub_ = false;
            return cst.allocNode(alloc, item.span, .{ .import = .{
                .import_tok = im.import_tok,
                .lbrace_tok = im.lbrace_tok,
                .items = items,
                .commas = im.commas,
                .rbrace_tok = im.rbrace_tok,
                .pub_ = false,
            } });
        },
        else => return item,
    }
}

/// wrap cst for module scope: build exports table from pub decls only top-level decls export
/// a pub nested in a bare block has no scope to export from
/// , so it stays local and unexported
pub fn wrapModule(alloc: std.mem.Allocator, root: *Node) !*Node {
    const items: []const *Node = switch (root.kind) {
        .block => |b| b.stmts,
        .root => |r| r.stmts,
        else => &[_]*Node{root},
    };
    const is_single = items.len == 1 and items[0] == root;

    var has_pub = false;
    for (items) |item| {
        if (pubName(item) != null) {
            has_pub = true;
            break;
        }
    }
    if (!has_pub) return root;

    const span = root.span;

    // const @exports = {}
    const exports_ident = try cst.allocIdent(alloc, span, "@exports");
    const exports_table = try cst.allocNode(alloc, span, .{ .table = .{
        .lbrace_tok = cst.syntheticToken("{", span),
        .entries = &.{},
        .commas = &.{},
        .rbrace_tok = cst.syntheticToken("}", span),
    } });
    const kind_tok = cst.syntheticToken("const", span);
    const exports_binding = try cst.allocNode(alloc, span, .{ .binding = .{
        .kind_tok = kind_tok,
        .kind = .@"const",
        .target = exports_ident,
        .colon_tok = null,
        .type = null,
        .eq_tok = cst.syntheticToken("=", span),
        .value = exports_table,
    } });
    const exports_decl = try cst.allocNode(alloc, span, .{ .decl = .{
        .pub_tok = null,
        .kind = .@"const",
        .inner = exports_binding,
        .pub_ = false,
    } });

    var new_items = try std.ArrayList(*Node).initCapacity(alloc, items.len * 2 + 2); // upper bound: each item + export
    try new_items.append(alloc, exports_decl);

    for (items) |item| {
        if (pubName(item)) |name| {
            try new_items.append(alloc, try clearPub(item, alloc));
            try new_items.append(alloc, try buildSetExport(alloc, span, name));
        } else {
            try new_items.append(alloc, item);
        }
    }

    const final_exports = try cst.allocIdent(alloc, span, "@exports");
    try new_items.append(alloc, final_exports);

    _ = is_single;
    return cst.allocNode(alloc, span, .{ .block = .{
        .stmts = try new_items.toOwnedSlice(alloc),
        .semis = &.{},
    } });
}

/// this mirrors old lowering in that
/// `const m = import "./x"` names a single autobind import after its target,
/// so resolution, checking, and codegen all agree on `m` (not the path stem).
/// runs over the whole tree
pub fn bindImportNames(alloc: std.mem.Allocator, root: *Node) std.mem.Allocator.Error!*Node {
    return BindWalk.walk(.{}, alloc, root, .{});
}

const BindWalk = struct {
    pub fn walk(_: @This(), alloc: std.mem.Allocator, node: *Node, ctx: @This()) std.mem.Allocator.Error!*Node {
        if (node.kind == .decl) {
            const inner = cst.unwrapParenMut(node.kind.decl.inner);
            if (inner != null and inner.?.kind == .binding) {
                const b = &inner.?.kind.binding;
                const t = cst.unwrapParenMut(b.target);
                const v = cst.unwrapParenMut(b.value);
                if (t != null and v != null and t.?.kind == .ident and v.?.kind == .import and v.?.kind.import.items.len == 1 and v.?.kind.import.items[0].name_tok == null) {
                    v.?.kind.import.items[0].name_tok = cst.syntheticToken(t.?.kind.ident.tok.text, t.?.span);
                    v.?.kind.import.items[0].eq_tok = cst.syntheticToken("=", t.?.span);
                }
            }
        }
        return try cst.walkCstExpr(alloc, node, @This(), ctx);
    }
};

/// any fn whose body contains pub decls gets its body wrapped
/// so calling the closure returns @exports
const PubWrapCtx = struct {
    pub fn walk(_: PubWrapCtx, alloc: std.mem.Allocator, node: *Node, ctx: PubWrapCtx) std.mem.Allocator.Error!*Node {
        const walked = try cst.walkCstExpr(alloc, node, PubWrapCtx, ctx);
        // bodies rebuild already; only the body pointer changes here
        switch (walked.kind) {
            .fn_def => |*f| if (bodyHasPub(f.body)) {
                f.body = try wrapModule(alloc, f.body);
            },
            .fn_method => |*f| if (bodyHasPub(f.body)) {
                f.body = try wrapModule(alloc, f.body);
            },
            else => {},
        }
        return walked;
    }
};

pub fn wrapPubFunctions(alloc: std.mem.Allocator, node: *Node) !*Node {
    return PubWrapCtx.walk(.{}, alloc, node, .{});
}

fn bodyHasPub(node: *Node) bool {
    if (cst.blockStmts(node)) |items| {
        for (items) |item| if (pubName(item) != null) return true;
        return false;
    }
    return pubName(node) != null;
}
