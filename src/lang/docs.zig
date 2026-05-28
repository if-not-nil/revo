const std = @import("std");
const Allocator = std.mem.Allocator;
const lang = @import("./root.zig");
const Node = lang.Node;
const ast = lang.ast;

pub const DocItem = struct {
    name: []const u8,
    arity: usize,
    doc: []const u8,
    line: u32,
};

fn targetName(alloc: Allocator, node: *const Node) ![]u8 {
    switch (node.expr) {
        .ident => |name| return alloc.dupe(u8, name),
        .field => |field| {
            if (field.object.expr == .ident) {
                return std.fmt.allocPrint(alloc, "{s}.{s}", .{
                    field.object.expr.ident,
                    field.name,
                });
            }
        },
        .index => |idx| {
            if (idx.object.expr == .ident and idx.key.expr == .hash) {
                return std.fmt.allocPrint(alloc, "{s}.{s}", .{
                    idx.object.expr.ident,
                    idx.key.expr.hash,
                });
            }
        },
        else => {},
    }
    return alloc.dupe(u8, "<anon>");
}

const DocVisitor = struct {
    alloc: Allocator,
    items: *std.ArrayList(DocItem),
    seen: *std.AutoHashMap(usize, void),

    fn addFn(self: *DocVisitor, key: usize, name: []u8, node: *const Node) !void {
        if (self.seen.contains(key)) {
            self.alloc.free(name);
            return;
        }
        try self.seen.put(key, {});
        const f = node.expr.fn_expr;
        try self.items.append(self.alloc, .{
            .name = name,
            .arity = f.params.len,
            .doc = f.doc.?,
            .line = f.body.span.line,
        });
    }

    pub fn visit(self: *DocVisitor, node: *const Node) void {
        switch (node.expr) {
            .decl => |decl| {
                self.visit(decl.inner);
            },
            .binding => |binding| {
                if (binding.value.expr == .fn_expr and binding.value.expr.fn_expr.doc != null) {
                    const key = @intFromPtr(binding.value);
                    const name = targetName(self.alloc, binding.target) catch return;
                    self.addFn(key, name, binding.value) catch return;
                }
            },
            .assign_expr => |assign| {
                if (assign.value.expr == .fn_expr and assign.value.expr.fn_expr.doc != null) {
                    const key = @intFromPtr(assign.value);
                    const name = targetName(self.alloc, assign.target) catch return;
                    self.addFn(key, name, assign.value) catch return;
                }
            },
            .fn_expr => {
                if (node.expr.fn_expr.doc != null) {
                    const key = @intFromPtr(node);
                    const name = self.alloc.dupe(u8, "<anon>") catch return;
                    self.addFn(key, name, node) catch return;
                }
            },
            else => {},
        }
        ast.walkAST(DocVisitor, self, node);
    }
};

pub fn extractDocs(alloc: Allocator, source: []const u8) !struct { items: []DocItem, arena: std.heap.ArenaAllocator } {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    const parsed = try lang.parseSourceReport(arena_alloc, source);
    const root = switch (parsed) {
        .ok => |node| node,
        .err => return error.ParseFailed,
    };

    var items = try std.ArrayList(DocItem).initCapacity(alloc, 8);
    var seen = std.AutoHashMap(usize, void).init(alloc);
    defer seen.deinit();

    var visitor = DocVisitor{
        .alloc = alloc,
        .items = &items,
        .seen = &seen,
    };
    visitor.visit(root);

    std.mem.sort(DocItem, items.items, {}, struct {
        fn less(_: void, a: DocItem, b: DocItem) bool {
            return a.line < b.line;
        }
    }.less);

    return .{ .items = try items.toOwnedSlice(alloc), .arena = arena };
}

test "extractDocs returns doc items from source" {
    const src =
        \\ @doc "adds nums"
        \\ fn add(a, b) a + b
        \\
        \\ @doc "greets"
        \\ const greet = fn(name) "hi " + name
    ;

    const res = try extractDocs(std.testing.allocator, src);
    defer {
        for (res.items) |it| std.testing.allocator.free(it.name);
        std.testing.allocator.free(res.items);
        res.arena.deinit();
    }

    try std.testing.expectEqual(@as(usize, 2), res.items.len);
    try std.testing.expectEqualStrings("add", res.items[0].name);
    try std.testing.expectEqual(@as(usize, 2), res.items[0].arity);
    try std.testing.expectEqualStrings("adds nums", res.items[0].doc);
    try std.testing.expectEqualStrings("greet", res.items[1].name);
    try std.testing.expectEqual(@as(usize, 1), res.items[1].arity);
    try std.testing.expectEqualStrings("greets", res.items[1].doc);
}

test "extractDocs returns empty for source without @doc" {
    const src = "fn add(a, b) a + b\nprint(add(1, 2))\n";

    const res = try extractDocs(std.testing.allocator, src);
    defer {
        for (res.items) |it| std.testing.allocator.free(it.name);
        std.testing.allocator.free(res.items);
        res.arena.deinit();
    }

    try std.testing.expectEqual(@as(usize, 0), res.items.len);
}

test "extractDocs handles multiline string @doc" {
    const src =
        \\ @doc """
        \\adds numbers
        \\returns sum
        \\"""
        \\ fn add(a, b) a + b
    ;

    const res = try extractDocs(std.testing.allocator, src);
    defer {
        for (res.items) |it| std.testing.allocator.free(it.name);
        std.testing.allocator.free(res.items);
        res.arena.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), res.items.len);
    try std.testing.expectEqualStrings("add", res.items[0].name);
    try std.testing.expectEqualStrings("adds numbers\nreturns sum", res.items[0].doc);
}
