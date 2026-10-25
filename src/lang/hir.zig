//!
//! hir is just desugared cst for now
//! same node types and canonical shapes
//!

const std = @import("std");

const cst = @import("cst.zig");
const Lexer = @import("Lexer.zig");
const Node = cst.CstNode;
const Span = Lexer.Span;

/// desugar once: parens stripped, pipes desugared, all else rebuilt
/// span-preserving; stripped parens take the inner span
pub fn lower(alloc: std.mem.Allocator, root: *const cst.CstNode) std.mem.Allocator.Error!*Node {
    return Lower.walk(.{}, alloc, @constCast(root), .{});
}

const Lower = struct {
    pub fn walk(_: Lower, allocator: std.mem.Allocator, node: *Node, _: Lower) std.mem.Allocator.Error!*Node {
        switch (node.kind) {
            .paren => |p| {
                // empty parens have no inner; they stay for null-tolerant paths
                const inner = p.expr orelse return node;
                // stripped parens keep the inner span
                return walk(.{}, allocator, inner, .{});
            },
            .pipe => |p| {
                // walk the result so nested sugar inside desugared output lowers too
                const desugared = try cst.desugarPipe(allocator, p.left, p.right, node.span);
                return walk(.{}, allocator, desugared, .{});
            },
            else => return cst.walkCstExpr(allocator, node, Lower, .{}),
        }
    }
};

test "lower strips parens keeping inner spans" {
    const Parser = @import("Parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try Parser.parseSource(alloc, "((40 + 2))", .{});
    const out = try lower(alloc, root);
    try std.testing.expect(out.kind == .root);
    try std.testing.expectEqual(@as(usize, 1), out.kind.root.stmts.len);
    const stmt = out.kind.root.stmts[0];
    // stripped to binary with the inner span, not the paren span
    try std.testing.expect(stmt.kind == .binary);
    try std.testing.expectEqual(@as(usize, 2), stmt.span.start);
    try std.testing.expectEqual(@as(usize, 8), stmt.span.end);
}

test "lower keeps empty parens for null-tolerant paths" {
    const Parser = @import("Parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try Parser.parseSource(alloc, "let x = ()", .{});
    const out = try lower(alloc, root);
    const value = out.kind.root.stmts[0].kind.decl.inner.kind.binding.value;
    try std.testing.expect(value.kind == .paren);
    try std.testing.expect(value.kind.paren.expr == null);
}

test "lower desugars pipes to calls" {
    const Parser = @import("Parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try Parser.parseSource(alloc, "x |> f", .{});
    const out = try lower(alloc, root);
    const stmt = out.kind.root.stmts[0];
    try std.testing.expect(stmt.kind == .call);
}

test "lower is idempotent and preserves tokens" {
    const Parser = @import("Parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src = "let y = (10 + 2) |> f\n#* doc *#\nconst z = 1";
    const root = try Parser.parseSource(alloc, src, .{});
    const once = try lower(alloc, root);
    const twice = try lower(alloc, once);
    const kept_once = try cst.retainedTokens(alloc, once);
    defer alloc.free(kept_once);
    const kept_twice = try cst.retainedTokens(alloc, twice);
    defer alloc.free(kept_twice);
    try std.testing.expectEqual(kept_once.len, kept_twice.len);
    for (kept_once, kept_twice) |a, b| {
        try std.testing.expectEqual(a.type, b.type);
        try std.testing.expectEqual(a.start, b.start);
        try std.testing.expectEqual(a.end, b.end);
    }
    // docs survive lowering (walkCstExpr carries them on all 5 kinds)
    var found_doc = false;
    for (kept_once) |t| {
        if (t.type == Lexer.TokenType.doc_comment) found_doc = true;
    }
    try std.testing.expect(found_doc);
}
