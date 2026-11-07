const std = @import("std");

const cst = @import("../cst.zig");
const diagnostic = @import("../diagnostic.zig");
const Lexer = @import("../Lexer.zig");
const Parser = @import("../Parser.zig");
const Node = cst.CstNode;

/// names a top-level pub decl exports: `pub const x`, `pub const {a, b}`
/// , empty for anything else
fn pubNames(alloc: std.mem.Allocator, item: *const Node) ![]const []const u8 {
    if (item.kind != .decl or !item.kind.decl.pub_) return &.{};
    const inner = item.kind.decl.inner;
    if (inner.kind != .binding) return &.{};

    const target = inner.kind.binding.target;
    switch (target.kind) {
        .ident => |n| return alloc.dupe([]const u8, &.{n.tok.text}),
        .table => |t| {
            var out = try std.ArrayList([]const u8).initCapacity(alloc, t.entries.len);
            for (t.entries) |e| switch (e) {
                .bare => |b| if (cst.identText(b.value)) |n| out.appendAssumeCapacity(n),
                else => {},
            };
            return out.toOwnedSlice(alloc);
        },
        else => return &.{},
    }
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
        else => return item,
    }
}

/// a body with pub decls ends in `{a = a, ...}:freeze()`, its record
/// , an explicit `return` still wins over it
pub fn wrapModule(alloc: std.mem.Allocator, root: *Node) !*Node {
    const items: []const *Node = switch (root.kind) {
        .block => |b| b.stmts,
        .root => |r| r.stmts,
        else => &[_]*Node{root},
    };

    var names = try std.ArrayList([]const u8).initCapacity(alloc, 4);
    var new_items = try std.ArrayList(*Node).initCapacity(alloc, items.len + 1);
    for (items) |item| {
        const exported = try pubNames(alloc, item);
        try names.appendSlice(alloc, exported);
        try new_items.append(alloc, if (exported.len > 0) try clearPub(item, alloc) else item);
    }

    if (names.items.len == 0) return root;

    const span = root.span;
    const entries = try alloc.alloc(cst.CstEntry, names.items.len);
    for (names.items, entries) |name, *e| e.* = .{ .keyed = .{
        .key = try cst.allocIdent(alloc, span, name),
        .eq_tok = cst.syntheticToken("=", span),
        .value = try cst.allocIdent(alloc, span, name),
    } };

    const record = try cst.allocNode(alloc, span, .{ .table = .{
        .lbrace_tok = cst.syntheticToken("{", span),
        .entries = entries,
        .commas = &.{},
        .rbrace_tok = cst.syntheticToken("}", span),
    } });

    // goes through the table metatable, so a user `table` binding can't shadow it (hopefully)
    try new_items.append(alloc, try cst.allocNode(alloc, span, .{ .method_call = .{
        .object = record,
        .atom_tok = cst.syntheticToken("freeze", span),
        .lparen_tok = cst.syntheticToken("(", span),
        .args = &.{},
        .commas = &.{},
        .rparen_tok = cst.syntheticToken(")", span),
    } }));

    return cst.allocNode(alloc, span, .{ .block = .{
        .stmts = try new_items.toOwnedSlice(alloc),
        .semis = &.{},
    } });
}

/// `pub` misuse, checked on the raw tree so build, lsp and loads agree
/// ; errors: `pub let`, `pub` outside the top of a file or fn body
/// ; warns: `pub` in a body that also returns explicitly
pub fn checkPub(
    alloc: std.mem.Allocator,
    root: *const Node,
    source: []const u8,
    warnings: ?*?diagnostic.Report,
) !?Parser.ParseFailure {
    var v = PubVisitor{ .alloc = alloc };
    try v.body(cst.blockStmts(root) orelse &.{});

    if (v.oom) return error.OutOfMemory;

    if (v.err) |e| {
        const parts = try alloc.dupe(diagnostic.Part, &.{
            .{ .@"error" = e.msg },
            .{ .span = .{ .span = e.span, .role = .primary, .message = e.label } },
        });
        return .{ .kind = .MisplacedPub, .report = .{ .parts = parts, .message = e.msg, .source = source } };
    }

    const out = warnings orelse return null;
    if (v.warns.items.len == 0) return null;
    const msg = "this body has `pub` but returns explicitly, so the pub record is ignored";
    var parts = try std.ArrayList(diagnostic.Part).initCapacity(alloc, v.warns.items.len * 2);
    if (out.*) |w| try parts.appendSlice(alloc, w.parts);
    for (v.warns.items) |span| {
        try parts.append(alloc, .{ .warn = msg });
        try parts.append(alloc, .{ .span = .{ .span = span, .role = .primary, .message = "explicit return" } });
    }

    out.* = .{
        .parts = try parts.toOwnedSlice(alloc),
        .message = if (out.*) |w| w.message else msg,
        .severity = .warning,
        .code = if (out.*) |w| w.code orelse "pub-with-return" else "pub-with-return",
        .source = source,
    };
    return null;
}

const PubVisitor = struct {
    alloc: std.mem.Allocator,
    err: ?struct { msg: []const u8, label: []const u8, span: Lexer.Span } = null,
    warns: std.ArrayList(Lexer.Span) = .empty,
    oom: bool = false,
    /// the body being walked: its first return, and whether it has pub
    ret: ?Lexer.Span = null,
    has_pub: bool = false,
    /// pub decls that sit at the top of a body, the only legal place
    top: ?*const Node = null,

    fn body(self: *PubVisitor, stmts: []const *Node) !void {
        const saved_ret = self.ret;
        const saved_pub = self.has_pub;
        self.ret = null;
        self.has_pub = false;
        defer {
            self.ret = saved_ret;
            self.has_pub = saved_pub;
        }

        for (stmts) |stmt| {
            self.top = stmt;
            self.visit(stmt);
            if (self.err != null) return;
        }

        if (self.has_pub) if (self.ret) |span| try self.warns.append(self.alloc, span);
    }

    pub fn visit(self: *PubVisitor, node: *const Node) void {
        if (self.err != null) return;
        switch (node.kind) {
            inline .fn_def, .fn_method => |f| {
                self.body(cst.blockStmts(f.body) orelse &.{f.body}) catch {
                    self.oom = true;
                };
                return;
            },
            .return_expr => if (self.ret == null) {
                self.ret = node.span;
            },
            .decl => |d| if (d.pub_) {
                if (self.top != node) {
                    self.err = .{ .msg = "`pub` only works at the top of a file or fn body", .label = "nothing to export from", .span = node.span };
                    return;
                }
                if (d.kind == .let or d.kind == .global) {
                    self.err = .{ .msg = "`pub` is const-only, expose state through a fn", .label = "make this `pub const`", .span = node.span };
                    return;
                }
                self.has_pub = true;
            },
            else => {},
        }
        self.top = null;

        cst.walkCst(PubVisitor, self, node);
    }
};

/// any fn whose body has pub decls gets its body wrapped,
/// so calling the closure returns its record
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
    const items = cst.blockStmts(node) orelse return isPub(node);
    for (items) |item| if (isPub(item)) return true;
    return false;
}

fn isPub(node: *const Node) bool {
    return node.kind == .decl and node.kind.decl.pub_;
}
