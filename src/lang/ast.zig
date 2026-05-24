const std = @import("std");

pub const Span = struct {
    start: usize,
    end: usize,
    line: u32,
    column: u32,

    pub fn merge(a: Span, b: Span) Span {
        return .{
            .start = @min(a.start, b.start),
            .end = @max(a.end, b.end),
            .line = if (a.start <= b.start) a.line else b.line,
            .column = if (a.start <= b.start) a.column else b.column,
        };
    }
};

pub const discard_name = "_";

pub inline fn isDiscardName(name: []const u8) bool {
    return std.mem.eql(u8, name, discard_name);
}

// they have to match opcode names. thankfully you get a compile error today
pub const BinOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    eq,
    neq,
    lt,
    gt,
    lte,
    gte,
    @"union",
};

pub const UnOp = enum {
    negate,
    not,
    spawn,
    join,
    yield,
};

pub const CaptureType = enum {
    expr, // any expression
    ident, // identifier only
    str, // string literal only
    number, // number literal only
    call, // function call only
};

pub const Quantifier = enum {
    zero_or_more, // *
    one_or_more, // +
    optional, // ?
};

pub const CaptureNode = struct {
    name: []const u8,
    capture_type: ?CaptureType = null,
};

pub const GroupNode = struct {
    name: []const u8,
    pattern: []const PatternNode,
    quantifier: Quantifier,
};

pub const PatternNode = union(enum) {
    literal: []const u8, // "if", "elif", "then", etc.
    capture: CaptureNode, // %x or %x:expr
    sequence: []const PatternNode, // (pattern pattern pattern)
    group: GroupNode, // %NAME(pattern*) with quantifier
};

pub const SingleCapture = struct {
    name: []const u8,
    expr: *Node,
};

pub const GroupCapture = struct {
    name: []const u8,
    captures: [][]*Node,
};

pub const MatchResult = struct {
    singles: []SingleCapture,
    groups: []GroupCapture,
};

pub const FnParam = struct {
    name: []const u8,
    type_name: ?[]const u8 = null,
};

pub const TableEntry = struct {
    key: ?*Node,
    computed: bool = false,
    value: *Node,
};

pub const StructField = struct {
    name: []const u8,
    type_name: ?[]const u8 = null,
    default_value: ?*Node = null,
};

pub const StructItem = union(enum) {
    field: StructField,
    binding: Binding,
};

pub const MatchMatcher = union(enum) {
    wildcard,
    expr: *Node,
};

pub const MatchArm = struct {
    matchers: []MatchMatcher,
    guard: ?*Node,
    then: *Node,
};

pub const Binding = struct {
    target: *Node,
    type_name: ?[]const u8 = null,
    value: *Node,

    fn printAt(self: *const Binding, writer: *std.Io.Writer, comptime tag: []const u8, depth: ?usize) anyerror!void {
        try writer.print("({s}", .{tag});
        if (depth) |d| {
            try writer.writeByte('\n');
            try writeIndent(writer, d + 1);
            try self.target.printAt(writer, d + 1);
            if (self.type_name) |t| try writer.print(":{s}", .{t});
            try writer.writeByte('\n');
            try writeIndent(writer, d + 1);
            try self.value.printAt(writer, d + 1);
            try writer.writeByte('\n');
            try writeIndent(writer, d);
        } else {
            try writer.writeByte(' ');
            try self.target.printAt(writer, null);
            if (self.type_name) |t| try writer.print(":{s}", .{t});
            try writer.writeByte(' ');
            try self.value.printAt(writer, null);
        }
        try writer.writeByte(')');
    }
};

pub const Expr = union(enum) {
    number: NumberLiteral, // (:number, 123) or (:number, 123.0)
    string: []const u8, // (:string, "asdf")
    multiline_string: []const u8,
    hash: []const u8,
    nil,
    ident: []const u8,
    unary: struct { op: UnOp, expr: *Node },
    binary: struct { op: BinOp, left: *Node, right: *Node },
    and_expr: struct { left: *Node, right: *Node },
    or_expr: struct { left: *Node, right: *Node },
    call: struct { callee: *Node, args: []*Node, implicit_self: bool = false },
    field: struct { object: *Node, name: []const u8 },
    index: struct { object: *Node, key: *Node },
    if_expr: struct { condition: *Node, then_expr: *Node, else_expr: ?*Node },
    match_expr: struct { subject: *Node, arms: []MatchArm },
    fn_expr: struct { params: []FnParam, return_type: ?[]const u8 = null, body: *Node },
    con_expr: Binding,
    let_expr: Binding,
    global: Binding,
    // ill probably ignore node's span field for now just do its expr
    // (:assign_expr, (:ident, "aaa"), (:ident, "bbb"))
    assign_expr: struct { target: *Node, value: *Node },
    loop_expr: struct { body: *Node },
    for_loop: struct { params: []FnParam, iter: *Node, body: *Node },
    comp_block: struct { expr: *Node, is_macro: bool = false },
    while_loop: struct { predicate: *Node, body: *Node },
    break_expr: ?*Node,
    return_expr: ?*Node,
    range_literal: struct {
        start: *Node,
        step: *Node, // TODO: actual steps
        end: *Node,
        // TODO: ...< for exclusive. but prolly not
        // inclusive: bool = true,
    },
    import_expr: *Node,
    macro_expr: struct { pattern: []const u8, template: []const u8 },
    test_block: struct { name: []const u8, body: *Node, skip: bool = false },
    test_suite: struct { name: []const u8, body: *Node },
    block: []*Node,
    tuple: []*Node,
    tuple_pattern: []*Node,
    table: []TableEntry,
    struct_def: struct { name: []const u8, items: []StructItem },
    proc_macro: struct { name: []const u8, param: FnParam, body: *Node },
    try_expr: *Node, // expr?
    orelse_expr: struct { left: *Node, right: *Node }, // expr orelse 42
    type_alias: struct { name: []const u8, type_expr: *Node },
};

pub const Node = struct {
    span: Span,
    expr: Expr,

    pub fn print(self: *const Node, writer: *std.Io.Writer) anyerror!void {
        return self.printAt(writer, null);
    }

    pub fn printPretty(self: *const Node, writer: *std.Io.Writer) anyerror!void {
        return self.printAt(writer, 0);
    }

    pub fn format(self: Node, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: *std.Io.Writer) !void {
        if (fmt.len == 0) return self.print(writer);
        if (std.mem.eql(u8, fmt, "p")) return self.printPretty(writer);
        @compileError("invalid format string for ast.Node; use {} or {p}");
    }

    fn printAt(self: *const Node, writer: *std.Io.Writer, depth: ?usize) anyerror!void {
        // sep/end helpers: in compact mode, just a space or nothing;
        // in pretty mode, newline + indent at d+1, or newline + indent at d
        const pretty = depth != null;

        switch (self.expr) {
            // atoms are same in both modes
            .number => |n| {
                if (std.math.isFinite(n.value) and @floor(n.value) == n.value and n.value >= @as(f64, @floatFromInt(std.math.minInt(i64))) and n.value <= @as(f64, @floatFromInt(std.math.maxInt(i64))) and !n.is_float) {
                    try writer.print("{d}", .{@as(i64, @intFromFloat(n.value))});
                } else {
                    try writer.print("{}", .{n.value});
                }
            },
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .multiline_string => |s| try writer.print("\"\"\"{s}\"\"\"", .{s}),
            .hash => |h| try writer.print(":{s}", .{h}),
            .nil => try writer.writeAll("nil"),
            .ident => |name| try writer.writeAll(name),
            .macro_expr => |m| try writer.print("(macro `{s}` `{s}`)", .{ m.pattern, m.template }),

            .range_literal => |r| {
                try writer.writeAll("(range ");
                try r.start.print(writer);
                try writer.writeAll(" ");
                try r.step.print(writer);
                try writer.writeAll(" ");
                try r.end.print(writer);
                try writer.writeAll(")");
            },
            .unary => |u| {
                try writer.print("({s}", .{@tagName(u.op)});
                try sep(writer, depth, 1);
                try u.expr.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .binary => |b| {
                try writer.print("({s}", .{binOpName(b.op)});
                try sep(writer, depth, 1);
                try b.left.printAt(writer, child(depth));
                try sep(writer, depth, 1);
                try b.right.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .and_expr => |v| {
                try writer.writeAll("(and");
                try sep(writer, depth, 1);
                try v.left.printAt(writer, child(depth));
                try sep(writer, depth, 1);
                try v.right.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .or_expr => |v| {
                try writer.writeAll("(or");
                try sep(writer, depth, 1);
                try v.left.printAt(writer, child(depth));
                try sep(writer, depth, 1);
                try v.right.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .call => |call| {
                try writer.writeAll("(call");
                try sep(writer, depth, 1);
                try call.callee.printAt(writer, child(depth));
                for (call.args) |arg| {
                    try sep(writer, depth, 1);
                    try arg.printAt(writer, child(depth));
                }
                try close(writer, depth);
            },
            .field => |field| {
                try writer.writeAll("(field");
                try sep(writer, depth, 1);
                try field.object.printAt(writer, child(depth));
                try sep(writer, depth, 1);
                try writer.writeAll(field.name);
                try close(writer, depth);
            },
            .index => |index| {
                try writer.writeAll("(index");
                try sep(writer, depth, 1);
                try index.object.printAt(writer, child(depth));
                try sep(writer, depth, 1);
                try index.key.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .if_expr => |v| {
                try writer.writeAll("(if");
                try sep(writer, depth, 1);
                try v.condition.printAt(writer, child(depth));
                try sep(writer, depth, 1);
                try v.then_expr.printAt(writer, child(depth));
                if (v.else_expr) |e| {
                    try sep(writer, depth, 1);
                    try e.printAt(writer, child(depth));
                }
                try close(writer, depth);
            },
            .match_expr => |m| {
                try writer.writeAll("(match");
                try sep(writer, depth, 1);
                try m.subject.printAt(writer, child(depth));
                for (m.arms) |arm| {
                    try sep(writer, depth, 1);
                    try printMatchArm(writer, arm, depth);
                }
                try close(writer, depth);
            },
            .fn_expr => |fn_expr| {
                try writer.writeAll("(fn (");
                for (fn_expr.params, 0..) |param, i| {
                    if (i != 0) try writer.writeByte(' ');
                    try writer.writeAll(param.name);
                    if (param.type_name) |t| try writer.print(":{s}", .{t});
                }
                try writer.writeByte(')');
                try sep(writer, depth, 1);
                try fn_expr.body.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .proc_macro => |pm| {
                try writer.writeAll("(proc ( ");
                try writer.writeAll(pm.param.name);
                try writer.writeByte(')');
                try sep(writer, depth, 1);
                try pm.body.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .test_block => |block| {
                try writer.print("(test {s}", .{block.name});
                if (block.skip) try writer.writeAll("/skip");
                try sep(writer, depth, 1);
                try block.body.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .test_suite => |suite| {
                try writer.print("(suite {s}", .{suite.name});
                try suite.body.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .con_expr => |binding| try binding.printAt(writer, "const", depth),
            .global => |binding| try binding.printAt(writer, "global", depth),
            .let_expr => |binding| try binding.printAt(writer, "let", depth),
            .assign_expr => |assign| {
                try writer.writeAll("(assign");
                try sep(writer, depth, 1);
                try assign.target.printAt(writer, child(depth));
                try sep(writer, depth, 1);
                try assign.value.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .loop_expr => |loop_expr| {
                try writer.writeAll("(loop");
                try sep(writer, depth, 1);
                try loop_expr.body.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .while_loop => |w| {
                try writer.writeAll("(while");
                try sep(writer, depth, 1);
                try w.predicate.print(writer);
                try sep(writer, depth, 1);
                try w.body.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .for_loop => |v| {
                try writer.writeAll("(for (");
                for (v.params, 0..) |param, i| {
                    if (i != 0) try writer.writeByte(' ');
                    try writer.writeAll(param.name);
                    if (param.type_name) |t| try writer.print(":{s}", .{t});
                }
                try writer.writeAll(" in ");
                // iter is inline with the header in both modes
                try v.iter.printAt(writer, if (pretty) child(depth) else null);
                try writer.writeByte(')');
                try sep(writer, depth, 1);
                try v.body.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .break_expr => |value| {
                if (value) |expr| {
                    try writer.writeAll("(break");
                    try sep(writer, depth, 1);
                    try expr.printAt(writer, child(depth));
                    try close(writer, depth);
                } else {
                    try writer.writeAll("(break)");
                }
            },
            .return_expr => |value| {
                if (value) |expr| {
                    try writer.writeAll("(return");
                    try sep(writer, depth, 1);
                    try expr.printAt(writer, child(depth));
                    try close(writer, depth);
                } else {
                    try writer.writeAll("(return)");
                }
            },
            .import_expr => |path| {
                try writer.writeAll("(import");
                try sep(writer, depth, 1);
                try path.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .comp_block => |cb| {
                try writer.writeAll("(comp");
                if (cb.is_macro) try writer.writeAll(" macro");
                try sep(writer, depth, 1);
                try cb.expr.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .struct_def => |def| {
                try writer.print("(struct {s}", .{def.name});
                for (def.items) |item| {
                    try sep(writer, depth, 1);
                    switch (item) {
                        .field => |field| {
                            try writer.print("(field {s}", .{field.name});
                            if (field.type_name) |t| try writer.print(":{s}", .{t});
                            if (field.default_value) |value| {
                                try sep(writer, child(depth), 1);
                                try value.printAt(writer, child(child(depth)));
                                try close(writer, child(depth));
                            } else {
                                try writer.writeByte(')');
                            }
                        },
                        .binding => |binding| try binding.printAt(writer, "entry", child(depth)),
                    }
                }
                try close(writer, depth);
            },
            .block => |exprs| try printNodeList(writer, "block", exprs, depth),
            .tuple => |items| try printNodeList(writer, "tuple", items, depth),
            .tuple_pattern => |items| try printNodeList(writer, "tuple-pattern", items, depth),
            .table => |entries| {
                if (entries.len == 0) {
                    try writer.writeAll("(table)");
                    return;
                }
                try writer.writeAll("(table");
                for (entries) |entry| {
                    try sep(writer, depth, 1);
                    if (entry.key) |key| {
                        try writer.writeAll("(entry");
                        if (pretty) {
                            try writer.writeByte('\n');
                            try writeIndent(writer, (if (depth) |d| d + 1 else 0) + 1);
                        } else if (entry.computed) {
                            try writer.writeAll("[ ");
                        } else {
                            try writer.writeByte(' ');
                        }
                        try key.printAt(writer, child(child(depth)));
                        if (!pretty and entry.computed) try writer.writeAll("]");
                        try sep(writer, child(depth), 1);
                        try entry.value.printAt(writer, child(child(depth)));
                        try close(writer, child(depth));
                    } else {
                        try entry.value.printAt(writer, child(depth));
                    }
                }
                try close(writer, depth);
            },
            .try_expr => |expr| {
                try writer.writeAll("(try");
                try sep(writer, depth, 1);
                try expr.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .orelse_expr => |binary| {
                try writer.writeAll("(orelse");
                try sep(writer, depth, 1);
                try binary.left.printAt(writer, child(depth));
                try sep(writer, depth, 1);
                try binary.right.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .type_alias => |t| {
                try writer.print("(type {s}", .{t.name});
                try sep(writer, depth, 1);
                try t.type_expr.printAt(writer, child(depth));
                try close(writer, depth);
            },
        }
    }
};

pub fn spanFromNodes(items: []const *Node, fallback: Span) Span {
    if (items.len == 0) return fallback;
    return Span.merge(items[0].span, items[items.len - 1].span);
}

// depth ariht helpers
fn child(depth: ?usize) ?usize {
    return if (depth) |d| d + 1 else null;
}

// sep: in compact mode write a space; in pretty mode write newline & indent at d+1
fn sep(writer: *std.Io.Writer, depth: ?usize, extra: usize) !void {
    if (depth) |d| {
        try writer.writeByte('\n');
        try writeIndent(writer, d + extra);
    } else {
        try writer.writeByte(' ');
    }
}

// close: in compact mode write ')'; in pretty mode do newline & indent at d then ')'
fn close(writer: *std.Io.Writer, depth: ?usize) !void {
    if (depth) |d| {
        try writer.writeByte('\n');
        try writeIndent(writer, d);
    }
    try writer.writeByte(')');
}

fn writeIndent(writer: *std.Io.Writer, depth: usize) !void {
    for (0..(depth * 2)) |_| try writer.writeByte(' ');
}

fn printNodeList(writer: *std.Io.Writer, comptime tag: []const u8, nodes: []const *Node, depth: ?usize) !void {
    if (nodes.len == 0) {
        try writer.print("({s})", .{tag});
        return;
    }
    try writer.print("({s}", .{tag});
    for (nodes) |node| {
        try sep(writer, depth, 1);
        try node.printAt(writer, child(depth));
    }
    try close(writer, depth);
}

fn printMatchArm(writer: *std.Io.Writer, arm: MatchArm, depth: ?usize) !void {
    try writer.writeAll("(arm");
    for (arm.matchers) |matcher| {
        try sep(writer, depth, 1);
        switch (matcher) {
            .wildcard => try writer.writeAll("_"),
            .expr => |expr| try expr.printAt(writer, child(depth)),
        }
    }
    if (arm.guard) |guard| {
        try sep(writer, depth, 1);
        try writer.writeAll("(when");
        try sep(writer, child(depth), 1);
        try guard.printAt(writer, child(child(depth)));
        try close(writer, child(depth));
    }
    try sep(writer, depth, 1);
    try arm.then.printAt(writer, child(depth));
    try close(writer, depth);
}

fn binOpName(op: BinOp) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .mod => "%",
        .eq => "==",
        .neq => "!=",
        .lt => "<",
        .gt => ">",
        .lte => "<=",
        .gte => ">=",
        .@"union" => "|",
    };
}

test "prints nested expression trees" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const span: Span = .{ .start = 0, .end = 0, .line = 1, .column = 1 };

    const one = try arena.allocator().create(Node);
    one.* = .{ .span = span, .expr = .{ .number = .{ .value = 1 } } };

    const zero = try arena.allocator().create(Node);
    zero.* = .{ .span = span, .expr = .{ .number = .{ .value = 0 } } };

    const call_ident = try arena.allocator().create(Node);
    call_ident.* = .{ .span = span, .expr = .{ .ident = "@foo" } };

    const call_args = try arena.allocator().alloc(*Node, 1);
    call_args[0] = zero;

    const call_expr = try arena.allocator().create(Node);
    call_expr.* = .{ .span = span, .expr = .{ .call = .{
        .callee = call_ident,
        .args = call_args,
    } } };

    const sum = try arena.allocator().create(Node);
    sum.* = .{ .span = span, .expr = .{ .binary = .{
        .op = .add,
        .left = one,
        .right = call_expr,
    } } };

    var buf = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer buf.deinit();
    try sum.print(&buf.writer);
    try std.testing.expectEqualStrings("(+ 1 (call @foo 0))", buf.written());
}

test "pretty prints nested expression trees" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const span: Span = .{ .start = 0, .end = 0, .line = 1, .column = 1 };

    const one = try arena.allocator().create(Node);
    one.* = .{ .span = span, .expr = .{ .number = .{ .value = 1 } } };

    const zero = try arena.allocator().create(Node);
    zero.* = .{ .span = span, .expr = .{ .number = .{ .value = 0 } } };

    const call_ident = try arena.allocator().create(Node);
    call_ident.* = .{ .span = span, .expr = .{ .ident = "@foo" } };

    const call_args = try arena.allocator().alloc(*Node, 1);
    call_args[0] = zero;

    const call_expr = try arena.allocator().create(Node);
    call_expr.* = .{ .span = span, .expr = .{ .call = .{
        .callee = call_ident,
        .args = call_args,
    } } };

    const sum = try arena.allocator().create(Node);
    sum.* = .{ .span = span, .expr = .{ .binary = .{
        .op = .add,
        .left = one,
        .right = call_expr,
    } } };

    var buf = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer buf.deinit();
    try sum.printPretty(&buf.writer);
    try std.testing.expectEqualStrings(
        \\(+
        \\  1
        \\  (call
        \\    @foo
        \\    0
        \\  )
        \\)
    , buf.written());
}

test "span merge keeps earliest start regardless argument order" {
    const left: Span = .{ .start = 10, .end = 20, .line = 2, .column = 5 };
    const right: Span = .{ .start = 2, .end = 8, .line = 1, .column = 3 };

    const merged_lr = Span.merge(left, right);
    const merged_rl = Span.merge(right, left);

    try std.testing.expectEqual(@as(usize, 2), merged_lr.start);
    try std.testing.expectEqual(@as(usize, 20), merged_lr.end);
    try std.testing.expectEqual(@as(u32, 1), merged_lr.line);
    try std.testing.expectEqual(@as(u32, 3), merged_lr.column);

    try std.testing.expectEqual(merged_lr.start, merged_rl.start);
    try std.testing.expectEqual(merged_lr.end, merged_rl.end);
    try std.testing.expectEqual(merged_lr.line, merged_rl.line);
    try std.testing.expectEqual(merged_lr.column, merged_rl.column);
}

test "prints break and return empty and valued forms" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const span: Span = .{ .start = 0, .end = 0, .line = 1, .column = 1 };
    const one = try arena.allocator().create(Node);
    one.* = .{ .span = span, .expr = .{ .number = .{ .value = 1 } } };

    const break_empty = Node{ .span = span, .expr = .{ .break_expr = null } };
    const break_value = Node{ .span = span, .expr = .{ .break_expr = one } };
    const return_empty = Node{ .span = span, .expr = .{ .return_expr = null } };
    const return_value = Node{ .span = span, .expr = .{ .return_expr = one } };

    var buf = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer buf.deinit();

    try break_empty.print(&buf.writer);
    try std.testing.expectEqualStrings("(break)", buf.written());
    buf.clearRetainingCapacity();

    try break_value.print(&buf.writer);
    try std.testing.expectEqualStrings("(break 1)", buf.written());
    buf.clearRetainingCapacity();

    try return_empty.print(&buf.writer);
    try std.testing.expectEqualStrings("(return)", buf.written());
    buf.clearRetainingCapacity();

    try return_value.print(&buf.writer);
    try std.testing.expectEqualStrings("(return 1)", buf.written());
}

pub fn walkAST(comptime Visitor: type, visitor: *Visitor, node: *const Node) void {
    if (@hasField(Visitor, "found") and visitor.found) return;

    switch (node.expr) {
        inline else => |payload| {
            const ExprType = @TypeOf(payload);

            if (ExprType == void or ExprType == f64 or ExprType == []const u8 or ExprType == bool) return;

            if (ExprType == []*Node) {
                for (payload) |c| {
                    if (@hasField(Visitor, "found") and visitor.found) return;
                    visitor.visit(c);
                }
                return;
            }
            if (ExprType == []TableEntry) {
                for (payload) |entry| {
                    if (@hasField(Visitor, "found") and visitor.found) return;
                    if (entry.key) |key| visitor.visit(key);
                    if (@hasField(Visitor, "found") and visitor.found) return;
                    visitor.visit(entry.value);
                }
                return;
            }

            const type_info = @typeInfo(ExprType);
            if (type_info != .@"struct" and type_info != .@"union") return;

            inline for (std.meta.fields(ExprType)) |field| {
                if (@hasField(Visitor, "found") and visitor.found) return;

                const FieldType = field.type;
                const value = @field(payload, field.name);

                switch (FieldType) {
                    *Node => {
                        visitor.visit(value);
                    },
                    []*Node => for (value) |c| {
                        if (@hasField(Visitor, "found") and visitor.found) return;
                        visitor.visit(c);
                    },
                    ?*Node => if (value) |c| visitor.visit(c),
                    []MatchArm => for (value) |arm| {
                        if (@hasField(Visitor, "found") and visitor.found) return;
                        for (arm.matchers) |matcher| visitor.visit(matcher.expr);
                        if (@hasField(Visitor, "found") and visitor.found) return;
                        if (arm.guard) |guard| visitor.visit(guard);
                        if (@hasField(Visitor, "found") and visitor.found) return;
                        visitor.visit(arm.then);
                    },
                    []StructItem => for (value) |item| {
                        if (@hasField(Visitor, "found") and visitor.found) return;
                        if (item == .binding) visitor.visit(item.binding.value) else if (item.field.default_value) |def| visitor.visit(def);
                    },
                    []TableEntry => for (value) |entry| {
                        if (@hasField(Visitor, "found") and visitor.found) return;
                        if (entry.key) |key| visitor.visit(key);
                        if (@hasField(Visitor, "found") and visitor.found) return;
                        visitor.visit(entry.value);
                    },
                    else => {},
                }
            }
        },
    }
}

const lang = @import("./root.zig");

const UnderscoreVisitor = struct {
    found: bool = false,

    pub fn visit(self: *UnderscoreVisitor, node: *const Node) void {
        if (self.found) return;

        // std.debug.print("visiting: {}\n", .{node.expr});

        switch (node.expr) {
            .ident => |name| {
                // std.debug.print("  ident: {s}\n", .{name});
                if (std.mem.eql(u8, name, "_")) {
                    self.found = true;
                }
            },
            else => {
                walkAST(UnderscoreVisitor, self, node);
            },
        }
    }
};

fn hasUnderscore(node: *const Node) bool {
    var visitor = UnderscoreVisitor{};
    visitor.visit(node);
    return visitor.found;
}

test "hasUnderscore" {
    var alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer alloc.deinit();
    const arena = alloc.allocator();
    var res = (try lang.parse(arena, .{ .text = "_", .name = "<>" }, .{})).ok;
    try std.testing.expect(hasUnderscore(res.root));
    res = (try lang.parse(arena, .{ .text = "x", .name = "<>" }, .{})).ok;
    try std.testing.expect(!hasUnderscore(res.root));
    res = (try lang.parse(arena, .{ .text = "(_, x)", .name = "<>" }, .{})).ok;
    // std.debug.print("is: {s}\n\n\n\n of len {d}\n\n", .{ res.root.expr.tuple[0].expr.ident, res.root.expr.tuple[0].expr.ident.len });
    try std.testing.expect(hasUnderscore(res.root));
    res = (try lang.parse(arena, .{ .text = "call{_, x}", .name = "<>" }, .{})).ok;
    try std.testing.expect(hasUnderscore(res.root));
    res = (try lang.parse(arena, .{ .text = "(a, b)", .name = "<>" }, .{})).ok;
    try std.testing.expect(!hasUnderscore(res.root));
    res = (try lang.parse(arena, .{ .text = "_:meth()", .name = "<>" }, .{})).ok;
    try std.testing.expect(hasUnderscore(res.root));
    res = (try lang.parse(arena, .{ .text = "_ + 42", .name = "<>" }, .{})).ok;
    try std.testing.expect(hasUnderscore(res.root));
}
pub const NumberLiteral = struct {
    value: f64,
    is_float: bool = false,
};
