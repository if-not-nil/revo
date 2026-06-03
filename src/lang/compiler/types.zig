const std = @import("std");
const revo = @import("revo");
const ast = @import("../ast.zig");

pub const UnionVariant = struct {
    name: []const u8,
    types: []const TypeInfo,
};

pub const TypeInfo = union(enum) {
    // TODO: remove
    void,
    bool,
    // TODO: maybe unify here maybe split at vm
    int,
    float,
    string,
    atom: []const u8,
    tuple: []const TypeInfo,
    @"union": []const UnionVariant,
    struct_type: []const u8,
    function: *const FunctionSignature,
    any,

    pub fn eql(self: TypeInfo, other: TypeInfo) bool {
        return switch (self) {
            .void => other == .void,
            .bool => other == .bool,
            .int => other == .int,
            .float => other == .float,
            .string => other == .string,
            .atom => |a| if (other == .atom) std.mem.eql(u8, atomPayload(a), atomPayload(other.atom)) else false,
            .struct_type => |s| if (other == .struct_type) std.mem.eql(u8, s, other.struct_type) else false,
            .tuple => |ts| if (other == .tuple) blk: {
                if (ts.len != other.tuple.len) break :blk false;
                for (ts, other.tuple) |a, b| if (!eql(a, b)) break :blk false;
                break :blk true;
            } else false,
            .@"union" => |us| if (other == .@"union") blk: {
                if (us.len != other.@"union".len) break :blk false;
                for (us, other.@"union") |a, b| {
                    if (!std.mem.eql(u8, a.name, b.name)) break :blk false;
                    if (a.types.len != b.types.len) break :blk false;
                    for (a.types, b.types) |at, bt| if (!eql(at, bt)) break :blk false;
                }
                break :blk true;
            } else false,
            .function => |f| if (other == .function) blk: {
                const o = other.function;
                // structural compare: pointer match is fast path
                if (f == o) break :blk true;
                if (!f.return_type.eql(o.return_type)) break :blk false;
                if (f.params.len != o.params.len) break :blk false;
                for (f.params, o.params) |a, b| if (!a.eql(b)) break :blk false;
                break :blk true;
            } else false,
            .any => true,
        };
    }
};

pub fn atomPayload(name: []const u8) []const u8 {
    return if (name.len > 0 and name[0] == ':') name[1..] else name;
}

pub const FunctionSignature = struct { params: []const TypeInfo, return_type: TypeInfo };

/// sentinel "any function" type,,,, matches any callable value
pub const ANY_FN_SIG: FunctionSignature = .{ .params = &.{}, .return_type = .any };

pub fn typeName(T: TypeInfo) []const u8 {
    return switch (T) {
        .struct_type => |s| s,
        .atom => |a| a,
        else => @tagName(T),
    };
}

pub fn isNumeric(T: TypeInfo) bool {
    return T == .int or T == .float;
}

pub fn canCoerce(from: TypeInfo, to: TypeInfo) bool {
    if (from.eql(to) or to == .any or from == .any) return true;
    // function subtyping: contravariant params, covariant return
    if (to == .function and from == .function) {
        const to_sig = to.function;
        const from_sig = from.function;
        // sentinel "any function" take and give any
        if (to_sig == &ANY_FN_SIG or from_sig == &ANY_FN_SIG) return true;
        // ret t: from's return must fit to's return
        if (!canCoerce(from_sig.return_type, to_sig.return_type)) return false;
        // params: to's params must fit from's params
        if (from_sig.params.len != to_sig.params.len) return false;
        for (from_sig.params, to_sig.params) |fp, tp| {
            if (!canCoerce(tp, fp)) return false;
        }
        return true;
    }
    // :true and :false are bool
    if (to == .bool and from == .atom) {
        const name = atomPayload(from.atom);
        return std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false");
    }
    if (to == .@"union") {
        // fast-path for atom literals vs atom-only variants
        if (from == .atom) {
            for (to.@"union") |variant| {
                if (variant.name.len == 0 and variant.types.len == 1 and variant.types[0] == .atom) {
                    if (std.mem.eql(u8, atomPayload(variant.types[0].atom), atomPayload(from.atom))) return true;
                }
                if (variant.name.len != 0 and variant.types.len == 0) {
                    if (std.mem.eql(u8, atomPayload(variant.name), atomPayload(from.atom))) return true;
                }
            }
        }
        for (to.@"union") |variant| {
            if (unionVariantAccepts(variant, from)) return true;
        }
    }
    if (from == .@"union") {
        if (from.@"union".len == 0) return false;
        for (from.@"union") |variant| {
            if (!targetAcceptsVariant(variant, to)) return false;
        }
        return true;
    }
    return from == .int and to == .float;
}

fn unionVariantAccepts(variant: UnionVariant, value: TypeInfo) bool {
    if (variant.name.len != 0) {
        // named (tagged) variant
        if (variant.types.len == 0) {
            // atom-only variant accepts plain atoms with matching payload
            return value == .atom and std.mem.eql(u8, atomPayload(value.atom), atomPayload(variant.name));
        }
        if (value != .tuple) return false;
        if (value.tuple.len != variant.types.len + 1) return false;
        if (value.tuple[0] != .atom) return false;
        if (!std.mem.eql(u8, atomPayload(value.tuple[0].atom), atomPayload(variant.name))) return false;
        for (variant.types, 0..) |expected, i| {
            if (!canCoerce(value.tuple[i + 1], expected)) return false;
        }
        return true;
    }

    if (variant.types.len == 1) return canCoerce(value, variant.types[0]);
    if (value != .tuple) return false;
    if (value.tuple.len != variant.types.len) return false;
    for (variant.types, value.tuple) |expected, actual| {
        if (!canCoerce(actual, expected)) return false;
    }
    return true;
}

fn targetAcceptsVariant(variant: UnionVariant, target: TypeInfo) bool {
    if (variant.name.len != 0) {
        // named variant
        if (variant.types.len == 0) {
            // atom-only variant is acceptable by plain atom target
            return target == .atom and std.mem.eql(u8, atomPayload(target.atom), atomPayload(variant.name));
        }
        if (target != .tuple) return false;
        if (target.tuple.len != variant.types.len + 1) return false;
        if (target.tuple[0] != .atom) return false;
        if (!std.mem.eql(u8, atomPayload(target.tuple[0].atom), atomPayload(variant.name))) return false;
        for (variant.types, 0..) |source, i| {
            if (!canCoerce(source, target.tuple[i + 1])) return false;
        }
        return true;
    }

    if (variant.types.len == 1) return canCoerce(variant.types[0], target);
    if (target != .tuple) return false;
    if (target.tuple.len != variant.types.len) return false;
    for (variant.types, target.tuple) |source, expected| {
        if (!canCoerce(source, expected)) return false;
    }
    return true;
}

pub fn inferBinaryOp(op: ast.BinOp, l: TypeInfo, r: TypeInfo) TypeInfo {
    return switch (op) {
        .@"union" => .any,
        .add, .sub, .mul, .div, .mod => blk: {
            if (l == .int and r == .int) break :blk .int;
            if (isNumeric(l) and isNumeric(r)) break :blk .float;
            break :blk .any;
        },
        .eq, .neq, .lt, .gt, .lte, .gte => .bool,
    };
}

pub fn inferUnaryOp(op: ast.UnOp, T: TypeInfo) TypeInfo {
    return switch (op) {
        .negate => if (isNumeric(T)) T else .any,
        .not => .bool,
        .spawn, .join, .yield => .any,
    };
}

pub fn inferIfType(then_type: TypeInfo, else_type: ?TypeInfo) TypeInfo {
    if (else_type) |et| {
        if (then_type.eql(et)) return then_type;
        if (then_type == .any) return et;
        if (et == .any) return then_type;
        return .any;
    }
    if (then_type == .void) return .void;
    return .any;
}

pub fn inferOrelseType(left: TypeInfo, right: TypeInfo) TypeInfo {
    if (left == .any) return right;
    if (right == .any) return left;
    if (left.eql(right)) return left;
    return .any;
}

pub fn collectVariants(alloc: std.mem.Allocator, ti: TypeInfo, variants: *std.ArrayList(UnionVariant)) !void {
    switch (ti) {
        .@"union" => |us| for (us) |u| try variants.append(alloc, u),
        .tuple => |types| try variants.append(alloc, .{ .name = "", .types = types }),
        else => {
            var one = try std.ArrayList(TypeInfo).initCapacity(alloc, 1);
            errdefer one.deinit(alloc);
            try one.append(alloc, ti);
            try variants.append(alloc, .{ .name = "", .types = try one.toOwnedSlice(alloc) });
        },
    }
}

pub fn inferExprType(ctx: anytype, node: *const ast.Node) TypeInfo {
    return switch (node.expr) {
        .number => |n| if (n.is_float) .float else .int,
        .string, .multiline_string => .string,
        .hash => |name| .{ .atom = name },
        .nil => .void,
        .ident => |name| ctx.inferIdentType(name),
        .unary => |u| inferUnaryOp(u.op, inferExprType(ctx, u.expr)),
        .binary => |b| inferBinaryOp(b.op, inferExprType(ctx, b.left), inferExprType(ctx, b.right)),
        .and_expr, .or_expr => .bool,
        .if_expr => |v| inferIfType(inferExprType(ctx, v.then_expr), if (v.else_expr) |e| inferExprType(ctx, e) else null),
        .tuple => |items| inferTupleType(ctx, items),
        .table => .{ .struct_type = "table" },
        .call => |call| ctx.inferCallReturnType(call.callee, @as([]const *ast.Node, call.args)),
        .field => |field| ctx.inferFieldType(field.object, field.name),
        .index => |index| inferIndexType(ctx, index.object, index.key),
        .fn_expr => |fn_expr| ctx.inferFnType(fn_expr.params, fn_expr.return_type),
        .block => |exprs| inferBlockResultType(ctx, exprs),
        .return_expr => .void,
        .loop_expr, .while_loop, .for_loop => .void,
        .break_expr => .void,
        .try_expr => |inner| inferExprType(ctx, inner),
        .orelse_expr => |v| inferOrelseType(inferExprType(ctx, v.left), inferExprType(ctx, v.right)),
        .comp_block, .import_expr, .test_block, .test_suite, .macro_expr, .proc_macro => .any,
        .range_literal, .match_expr, .assign_expr => .any,
        .decl, .binding => .void,
        .tuple_pattern => .any,
        .struct_def => |def| .{ .struct_type = def.name },
        .type_alias => .void,
    };
}

pub fn inferTupleType(ctx: anytype, items: []const *ast.Node) TypeInfo {
    if (items.len == 0) return .{ .tuple = &.{} };
    var types = std.ArrayList(TypeInfo).initCapacity(ctx.alloc, items.len) catch return .any;
    defer types.deinit(ctx.alloc);
    for (items) |item| types.append(ctx.alloc, inferExprType(ctx, item)) catch return .any;
    return .{ .tuple = types.toOwnedSlice(ctx.alloc) catch return .any };
}

pub fn inferIndexType(ctx: anytype, object: *const ast.Node, key: *const ast.Node) TypeInfo {
    return switch (inferExprType(ctx, object)) {
        .tuple => |items| if (key.expr == .number) blk: {
            const key_num = key.expr.number.value;
            if (std.math.isFinite(key_num) and @floor(key_num) == key_num and key_num >= 0) {
                const idx: usize = @intFromFloat(key_num);
                if (object.expr == .tuple) {
                    const tuple_items = object.expr.tuple;
                    if (idx < tuple_items.len) break :blk inferExprType(ctx, tuple_items[idx]);
                } else if (idx < items.len) {
                    break :blk items[idx];
                }
            }
            break :blk .any;
        } else .any,
        .string => .string,
        else => .any,
    };
}

pub fn inferBlockResultType(ctx: anytype, exprs: []const *ast.Node) TypeInfo {
    if (exprs.len == 0) return .void;
    return inferExprType(ctx, exprs[exprs.len - 1]);
}

pub fn evalTypeExpr(ctx: anytype, node: *const ast.Node) !TypeInfo {
    return switch (node.expr) {
        .ident => |name| ctx.resolveTypeName(name),
        .hash => |name| TypeInfo{ .atom = name },
        .tuple => |items| blk: {
            var types = try std.ArrayList(TypeInfo).initCapacity(ctx.alloc, items.len);
            errdefer types.deinit(ctx.alloc);
            for (items) |item| try types.append(ctx.alloc, try evalTypeExpr(ctx, item));
            break :blk TypeInfo{ .tuple = try types.toOwnedSlice(ctx.alloc) };
        },
        .binary => |b| switch (b.op) {
            .@"union" => blk: {
                var variants = try std.ArrayList(UnionVariant).initCapacity(ctx.alloc, 4);
                errdefer variants.deinit(ctx.alloc);
                try collectVariants(ctx.alloc, try evalTypeExpr(ctx, b.left), &variants);
                try collectVariants(ctx.alloc, try evalTypeExpr(ctx, b.right), &variants);
                break :blk TypeInfo{ .@"union" = try variants.toOwnedSlice(ctx.alloc) };
            },
            else => return error.UnsupportedSyntax,
        },
        else => return error.UnsupportedSyntax,
    };
}

test "types: TypeInfo equality" {
    const int_type: revo.lang.compiler.types.TypeInfo = .int;
    const any_type: revo.lang.compiler.types.TypeInfo = .any;

    try std.testing.expect(int_type.eql(.int));
    try std.testing.expect(!int_type.eql(.float));
    try std.testing.expect(any_type.eql(.any));
}

test "types: numeric type check" {
    const types = revo.lang.compiler.types;
    try std.testing.expect(types.isNumeric(.int));
    try std.testing.expect(types.isNumeric(.float));
    try std.testing.expect(!types.isNumeric(.string));
    try std.testing.expect(!types.isNumeric(.any));
}

test "types: type coercion" {
    const types = revo.lang.compiler.types;
    try std.testing.expect(types.canCoerce(.int, .int));
    try std.testing.expect(types.canCoerce(.int, .float));
    try std.testing.expect(!types.canCoerce(.float, .int)); // float doesn't coerce to int
    try std.testing.expect(types.canCoerce(.int, .any)); // anything to any
    try std.testing.expect(types.canCoerce(.any, .int)); // any to anything (optimistic)
}

test "types: binary op inference - arithmetic" {
    const types = revo.lang.compiler.types;
    const add_int_int = types.inferBinaryOp(.add, .int, .int);
    try std.testing.expect(add_int_int.eql(.int));

    const add_float_float = types.inferBinaryOp(.add, .float, .float);
    try std.testing.expect(add_float_float.eql(.float));

    const add_int_float = types.inferBinaryOp(.add, .int, .float);
    try std.testing.expect(add_int_float.eql(.float));
}

test "types: binary op inference - comparison" {
    const types = revo.lang.compiler.types;
    const cmp = types.inferBinaryOp(.eq, .int, .int);
    try std.testing.expect(cmp.eql(.bool));

    const cmp2 = types.inferBinaryOp(.lt, .float, .float);
    try std.testing.expect(cmp2.eql(.bool));
}

test "types: unary op inference" {
    const types = revo.lang.compiler.types;
    const negate_int = types.inferUnaryOp(.negate, .int);
    try std.testing.expect(negate_int.eql(.int));

    const not_bool = types.inferUnaryOp(.not, .bool);
    try std.testing.expect(not_bool.eql(.bool));
}

//
// type system
//
const lang = revo.lang;
const t = lang.testing;
const VM = revo.VM;

test "typed binding int accepts int literal" {
    try t.top_number(
        \\ let x: int = 42
        \\ x
    , 42);
}

test "typed binding float accepts float literal" {
    try t.top_number(
        \\ let x: float = 3.14
        \\ x
    , 3.14);
}

test "typed binding int accepts int literal coerced to float" {
    try t.top_number(
        \\ let x: float = 10
        \\ x
    , 10.0);
}

test "typed binding rejects string for int" {
    try t.expectCompileError(
        \\ let x: int = "hello"
    , .ParseError);
}

test "typed binding rejects float for int" {
    try t.expectCompileError(
        \\ let x: int = 3.14
    , .ParseError);
}

test "typed binding rejects int for string" {
    try t.expectCompileError(
        \\ let x: string = 42
    , .ParseError);
}

test "typed function params accept correct types" {
    try t.top_number(
        \\ const add = fn(a: int, b: int) a + b
        \\ add(3, 4)
    , 7);
}

test "typed function rejects wrong arg type" {
    try t.expectCompileError(
        \\ const add = fn(a: int, b: int) a + b
        \\ add(3, "wrong")
    , .ParseError);
}

test "typed function rejects first arg wrong type" {
    try t.expectCompileError(
        \\ const add = fn(a: int, b: int) a + b
        \\ add("wrong", 4)
    , .ParseError);
}

test "atom union alias accepts literal and alias value in calls" {
    try t.top_atom(
        \\ type A = :one | :two
        \\ fn pick(how: A) -> any do
        \\   how
        \\ end
        \\ let pred: A = :one
        \\ pick(pred)
    , "one");

    try t.top_atom(
        \\ type A = :one | :two
        \\ fn pick(how: A) -> any do
        \\   how
        \\ end
        \\ let pred: A = :one
        \\ pick(:two)
    , "two");
}

test "typed struct field access" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ struct User {
        \\     name: string = "",
        \\     age: number = 0,
        \\ }
        \\ let u: User = User { name = "alice", age = 30 }
        \\ u.age
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_get = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .struct_get_offset) saw_get = true;
    }
    try std.testing.expect(saw_get);
}

test "typed struct field assignment rejects wrong type" {
    try t.expectCompileError(
        \\ struct User {
        \\     name: string = "",
        \\     age: int = 0,
        \\ }
        \\ let u: User = User { name = "alice", age = 30 }
        \\ u.name = 42
    , .ParseError);
}

test "typed struct field assignment accepts correct type" {
    try t.top_number(
        \\ struct User {
        \\     name: string = "",
        \\     age: number = 0,
        \\ }
        \\ let u: User = User { name = "alice", age = 30 }
        \\ u.age = 42
        \\ u.age
    , 42);
}

test "binary int + int emits add_int" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let a: int = 5
        \\ let b: int = 3
        \\ a + b
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_int = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_int) saw_add_int = true;
    }
    try std.testing.expect(saw_add_int);
}

test "binary float + float emits add_int" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let a: float = 1.5
        \\ let b: float = 2.5
        \\ a + b
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_int = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_int) saw_add_int = true;
    }
    try std.testing.expect(saw_add_int);
}

test "negate int emits negate_int" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let x: int = 5
        \\ let y = -x
        \\ y
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_neg_int = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .negate_int) saw_neg_int = true;
    }
    try std.testing.expect(saw_neg_int);
}

test "comparison int == int emits eq_int" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let a: int = 5
        \\ let b: int = 5
        \\ a == b
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_eq_int = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .eq_int) saw_eq_int = true;
    }
    try std.testing.expect(saw_eq_int);
}

test "untyped code still works" {
    try t.top_number("1 + 2 * 3", 7);
    try t.top_number(
        \\ let x = 10
        \\ x + 5
    , 15);
    try t.top_string(
        \\ let s = "hello"
        \\ s
    , "hello");
}

test "mixed int and float falls back to generic add" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let a: int = 5
        \\ let b: float = 2.5
        \\ a + b
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_generic_add = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add) saw_generic_add = true;
    }
    try std.testing.expect(saw_generic_add);
}

test "nested function with typed params" {
    try t.top_number(
        \\ const outer = fn(x: int) do
        \\     const inner = fn(y: int) y * 2
        \\     inner(x) + 1
        \\ end
        \\ outer(5)
    , 11);
}

test "function call with multiple typed params" {
    try t.top_number(
        \\ const calc = fn(a: int, b: float, c: int) do
        \\     a + b + c
        \\ end
        \\ calc(1, 2.5, 3)
    , 6.5);
}

test "return type validation accepts correct type" {
    try t.top_number(
        \\ const get_num = fn() -> int do
        \\     return 42
        \\ end
        \\ get_num()
    , 42);
}

test "atoms<->any relationship" {
    try t.top_number(
        \\ const get_num = fn() -> int do
        \\     return 42
        \\ end
        \\ get_num()
    , 42);
}

//
// typed const bindings
//
test "typed const binding int" {
    try t.top_number(
        \\ const x: int = 42
        \\ x
    , 42);
}

test "typed const binding string" {
    try t.top_string(
        \\ const s: string = "hello"
        \\ s
    , "hello");
}

test "typed const binding float" {
    try t.top_number(
        \\ const x: float = 3.14
        \\ x
    , 3.14);
}

test "typed const binding rejects wrong type" {
    try t.expectCompileError(
        \\ const x: int = "hello"
    , .ParseError);
}

//
// typed global bindings
//
test "typed global binding int" {
    try t.top_number(
        \\ global x: int = 42
        \\ x
    , 42);
}

test "typed global binding float" {
    try t.top_number(
        \\ global x: float = 1.5
        \\ x
    , 1.5);
}

//
// type alias at call sites

//
// type alias at call sites
//
test "type alias used in function param" {
    try t.top_number(
        \\ type MyInt = int
        \\ const double = fn(x: MyInt) -> MyInt x * 2
        \\ double(21)
    , 42);
}

test "type alias used in binding" {
    try t.top_string(
        \\ type Name = string
        \\ let s: Name = "alice"
        \\ s
    , "alice");
}

test "type alias int | float accepts int" {
    try t.top_number(
        \\ type Num = int | float
        \\ const add = fn(a: Num, b: Num) -> float a + b
        \\ add(3, 4)
    , 7);
}

test "type alias int | float accepts float" {
    try t.top_number(
        \\ type Num = int | float
        \\ const add = fn(a: Num, b: Num) -> float a + b
        \\ add(3.5, 4.2)
    , 7.7);
}

test "type alias rejects type not in union" {
    try t.expectCompileError(
        \\ type MyInt = int
        \\ const x: MyInt = "string"
    , .ParseError);
}

//
// named union variants with payloads
//
test "named union variant ok result" {
    try t.top_atom(
        \\ type Result = :ok | :err
        \\ match 0
        \\ | 0 => :ok
        \\ | _ => :err
    , "ok");
}

test "named union variant err result" {
    try t.top_atom(
        \\ type Result = :ok | :err
        \\ match 1
        \\ | 0 => :ok
        \\ | _ => :err
    , "err");
}

//
// return type validation
//
test "return type mismatch detects wrong explicit return" {
    try t.expectCompileError(
        \\ fn get() -> int do
        \\     return "hello"
        \\ end
    , .ParseError);
}

test "coercion in return type int to float" {
    try t.top_number(
        \\ fn get() -> float do
        \\     return 42
        \\ end
        \\ get()
    , 42);
}

test "explicit return matches return type" {
    try t.top_number(
        \\ fn get() -> int do
        \\     return 99
        \\ end
        \\ get()
    , 99);
}

//
// if/else branch type unification
//
test "if/else typed branches unify to number" {
    try t.top_number(
        \\ let x: int = 5
        \\ let y = if x > 0 10 else 20
        \\ y
    , 10);
}

test "if/else typed branches unify to string" {
    try t.top_string(
        \\ let x: int = 0
        \\ let y = if x > 0 "pos" else "non-pos"
        \\ y
    , "non-pos");
}

//
// tuple type inference
//
test "tuple type inference and access" {
    try t.top_number(
        \\ let t = (1, "hi", 3.5)
        \\ t[0] + t[2]
    , 4.5);
}

test "tuple type with different types" {
    try t.top_number(
        \\ let t = (10, 20, 30)
        \\ t[0] + t[1] + t[2]
    , 60);
}

test "nested tuple type" {
    try t.top_number(
        \\ let t = ((1, 2), (3, 4))
        \\ t[0][0] + t[1][1]
    , 5);
}

//
// string indexing
//
test "string indexing returns string" {
    try t.top_string(
        \\ let s: string = "hello"
        \\ s[0]
    , "h");
}

//
// struct with nested struct fields
//
test "struct field access returns correct type" {
    try t.top_number(
        \\ struct User { name: string = "", age: int = 0 }
        \\ let u = User { name = "alice", age = 30 }
        \\ u.age + 12
    , 42);
}

//
// any type accepts everything
//
test "any typed param accepts int" {
    try t.top_number(
        \\ const id = fn(x: any) x
        \\ id(42)
    , 42);
}

test "any typed param accepts string" {
    try t.top_string(
        \\ const id = fn(x: any) x
        \\ id("hello")
    , "hello");
}

test "any typed param accepts table" {
    try t.top_number(
        \\ const get = fn(t: any, k: any) t[k]
        \\ get({x = 99}, :x)
    , 99);
}

test "any typed binding accepts anything" {
    try t.top_number(
        \\ let x: any = 42
        \\ let y: any = "str"
        \\ let z: any = {a = 1}
        \\ x
    , 42);
}

//
// block type propagation
//
test "block type propagates last expression type" {
    try t.top_number(
        \\ let x: int = do
        \\     let a = 1
        \\     let b = 2
        \\     a + b
        \\ end
        \\ x
    , 3);
}

test "block type error on type mismatch" {
    try t.expectCompileError(
        \\ let x: int = do
        \\     "hello"
        \\ end
    , .ParseError);
}

//
// chained typed ops preserve specialization
//
test "chained typed math emits add_int" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let a: int = 1
        \\ let b: int = 2
        \\ let c: int = 3
        \\ a + b * c
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_int = false;
    var saw_mul_spec = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_int) saw_add_int = true;
        if (inst.op == .mul_int) saw_mul_spec = true;
    }
    try std.testing.expect(saw_add_int);
    try std.testing.expect(saw_mul_spec);
}

//
// type alias union with multiple atom variants
//
test "multi-atom union alias in match" {
    try t.top_atom(
        \\ type Color = :red | :green | :blue
        \\ match :red
        \\ | :red => :green
        \\ | :green => :red
        \\ | _ => :blue
    , "green");
}

test "multi-atom union fn param accepts valid atom" {
    try t.top_atom(
        \\ type Color = :red | :green
        \\ fn pick(c: Color) c
        \\ pick(:green)
    , "green");
}

//
// void / nil type
//
test "nil typed fn body" {
    try t.top_nil(
        \\ fn nothing() do :nil end
        \\ nothing()
    );
}

test "typed binding with void returns nil" {
    try t.top_nil(
        \\ let x: any = :nil
        \\ x
    );
}

//
// bool type
//
test "bool typed binding" {
    try t.top_true(
        \\ let b: bool = 1 == 1
        \\ b
    );
}

test "bool typed binding rejects non-bool" {
    try t.expectCompileError(
        \\ let b: bool = 42
    , .ParseError);
}

test "not operator on bool stays bool" {
    try t.top_false(
        \\ let b: bool = not (1 == 1)
        \\ b
    );
}
