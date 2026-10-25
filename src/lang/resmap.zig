//! name resolution rules that both checkers share

const std = @import("std");

const cst = @import("cst.zig");

/// a top-level `const NAME = fn...` eligible for forward references
/// todo we dont have paren unwrapping yet, so `const f = (fn() 42)` is still unknown-name
pub const PredeclFn = struct {
    name: []const u8,
    is_let: bool,
    func: @FieldType(cst.CstKind, "fn_def"),
};

/// null unless `item` is exactly `decl(non-global, binding(ident, fn_def))`
/// with a real name; both checkers traverse their own scopes
pub fn predeclFn(item: *const cst.CstNode) ?PredeclFn {
    const decl = switch (item.kind) {
        .decl => |d| d,
        else => return null,
    };
    if (decl.kind == .global or decl.kind == .global_const) return null;
    const binding = switch (decl.inner.kind) {
        .binding => |b| b,
        else => return null,
    };
    const target = switch (binding.target.kind) {
        .ident => |i| i,
        else => return null,
    };
    const func = switch (binding.value.kind) {
        .fn_def => |f| f,
        else => return null,
    };
    if (cst.isDiscardName(target.tok.text)) return null;
    return .{ .name = target.tok.text, .is_let = decl.kind == .let, .func = func };
}

test "predeclFn finds plain top-level fn bindings" {
    const Parser = @import("Parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try Parser.parseSource(arena.allocator(), "const f = fn() 42\nlet g = fn(x) x", .{});
    const stmts = root.kind.root.stmts;
    try std.testing.expectEqual(@as(usize, 2), stmts.len);
    const f = predeclFn(stmts[0]) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("f", f.name);
    try std.testing.expect(!f.is_let);
    const g = predeclFn(stmts[1]) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("g", g.name);
    try std.testing.expect(f.func.body != g.func.body);
}

test "predeclFn skips non-eligible shapes" {
    const Parser = @import("Parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_][]const u8{
        "const x = 42", // not a fn
        "global g = fn() 1", // globals are not locals
        "const _ = fn() 1", // discards bind nothing
        "const f = (fn() 42)", // parenthesized value
        "(const f = fn() 42)", // parenthesized decl
        "type T = number", // not a binding
        "42", // not a decl
    };
    for (cases) |src| {
        const root = try Parser.parseSource(arena.allocator(), src, .{});
        const stmts = root.kind.root.stmts;
        try std.testing.expectEqual(@as(usize, 1), stmts.len);
        try std.testing.expect(predeclFn(stmts[0]) == null);
    }
}
