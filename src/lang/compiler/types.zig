const std = @import("std");
const revo = @import("revo");
const ast = @import("../ast.zig");

pub const UnionVariant = struct {
    name: []const u8,
    types: []const TypeInfo,
};

pub const TypeInfo = union(enum) {
    bool,
    // TODO: maybe unify here maybe split at vm
    int,
    float,
    string,
    atom: []const u8,
    tuple: []const TypeInfo,
    @"union": []const UnionVariant,
    table: struct {
        key: ?*const TypeInfo,
        value: *const TypeInfo,
    },
    struct_type: []const u8,
    function: *const FunctionSignature,
    any,
    type_var: []const u8,

    pub fn eql(self: TypeInfo, other: TypeInfo) bool {
        return switch (self) {
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
            .table => |ti| if (other == .table) blk: {
                const o = other.table;
                if (!eql(ti.value.*, o.value.*)) break :blk false;
                if (ti.key) |tk| break :blk if (o.key) |ok| eql(tk.*, ok.*) else false;
                break :blk o.key == null;
            } else false,
            .function => |f| if (other == .function) blk: {
                const o = other.function;
                if (f == o) break :blk true;
                if (!f.return_type.eql(o.return_type)) break :blk false;
                if (f.params.len != o.params.len) break :blk false;
                for (f.params, o.params) |a, b| if (!a.eql(b)) break :blk false;
                break :blk true;
            } else false,
            .type_var => |name| if (other == .type_var) std.mem.eql(u8, name, other.type_var) else false,
            .any => true,
        };
    }
};

pub fn atomPayload(name: []const u8) []const u8 {
    return if (name.len > 0 and name[0] == ':') name[1..] else name;
}

pub const FieldDef = struct {
    name: []const u8,
    field_type: TypeInfo,
    type_name: ?[]const u8 = null,
    default_val: ?revo.memory.Data = null,
};

pub const FunctionSignature = struct {
    params: []const TypeInfo,
    return_type: TypeInfo,
    param_names: []const []const u8 = &.{},
    is_any_fn_sig: bool = false,
    required_count: usize = 0,
    type_params: []const []const u8 = &.{},
};

/// sentinel "any function" type,,, matches any callable value
/// ptr identity;; only matches when &ANY_FN_SIG is used
pub const ANY_FN_SIG: FunctionSignature = .{ .params = &.{}, .return_type = .any, .param_names = &.{}, .is_any_fn_sig = true };

pub fn typeName(T: TypeInfo) []const u8 {
    return switch (T) {
        .struct_type, .atom, .type_var => |s| s,
        .table => "table",
        else => @tagName(T),
    };
}

/// alloc version of typeName, formats unions as well
pub fn formatType(alloc: std.mem.Allocator, ti: TypeInfo) ![]const u8 {
    return switch (ti) {
        .type_var => |n| try alloc.dupe(u8, n),
        .table => |tbl| blk: {
            if (tbl.key) |k| {
                break :blk try std.fmt.allocPrint(alloc, "table<{s}, {s}>", .{ typeName(k.*), typeName(tbl.value.*) });
            }
            break :blk try std.fmt.allocPrint(alloc, "table<{s}>", .{typeName(tbl.value.*)});
        },
        .@"union" => |variants| blk: {
            var buf = try std.ArrayList(u8).initCapacity(alloc, 64);
            errdefer buf.deinit(alloc);
            for (variants, 0..) |v, i| {
                if (i > 0) try buf.appendSlice(alloc, " | ");
                if (v.name.len > 0) {
                    try buf.append(alloc, ':');
                    try buf.appendSlice(alloc, v.name);
                }
                for (v.types, 0..) |vt, j| {
                    if (j > 0 or v.name.len > 0) try buf.append(alloc, ' ');
                    try buf.appendSlice(alloc, typeName(vt));
                }
            }
            break :blk try buf.toOwnedSlice(alloc);
        },
        else => try alloc.dupe(u8, typeName(ti)),
    };
}

pub fn isNumeric(T: TypeInfo) bool {
    return T == .int or T == .float;
}

pub fn canCoerce(from: TypeInfo, to: TypeInfo) bool {
    if (from.eql(to) or to == .any or from == .any or from == .type_var or to == .type_var) return true;
    // function subtyping: contravariant params, covariant return
    if (to == .function and from == .function) {
        const to_sig = to.function;
        const from_sig = from.function;
        // sentinel "any function" take and give any
        if (to_sig.is_any_fn_sig or from_sig.is_any_fn_sig) return true;
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
        .@"union", .concat => .any,
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
        else => .any,
    };
}

pub fn inferIfType(then_type: TypeInfo, else_type: ?TypeInfo) TypeInfo {
    if (else_type) |et| {
        if (then_type.eql(et)) return then_type;
        if (then_type == .any) return et;
        if (et == .any) return then_type;
        return .any;
    }
    return .any;
}

pub fn inferMatchType(ctx: anytype, subject: *const ast.Node, arms: []const ast.MatchArm) TypeInfo {
    _ = subject;
    var result: TypeInfo = .any;
    for (arms) |arm| {
        const arm_type = inferExprType(ctx, arm.then);
        if (result == .any) {
            result = arm_type;
        } else if (arm_type != .any) {
            if (!result.eql(arm_type)) return .any;
        }
    }
    return result;
}

pub fn inferOrelseType(left: TypeInfo, right: TypeInfo) TypeInfo {
    if (left == .any) return right;
    if (right == .any) return left;
    if (left.eql(right)) return left;
    return .any;
}

pub fn okTypeFromUnion(ti: TypeInfo) TypeInfo {
    const variants = switch (ti) {
        .@"union" => |us| us,
        else => return .any,
    };
    for (variants) |v| {
        if (v.types.len == 1 and (std.mem.eql(u8, v.name, ":ok") or std.mem.eql(u8, v.name, "ok"))) {
            return v.types[0];
        }
    }
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

pub const type_name_map: std.StaticStringMap(TypeInfo) = std.StaticStringMap(TypeInfo).initComptime(.{
    .{ "int", .int },
    .{ "float", .float },
    .{ "num", .int },
    .{ "number", .int },
    .{ "string", .string },
    .{ "bool", .bool },
    .{ "any", .any },
    .{ "nil", TypeInfo{ .atom = ":nil" } },
    .{ "tuple", .any },
    .{ "table", TypeInfo{ .struct_type = "table" } },
    .{ "function", .any },
    .{ "atom", .any },
    .{ "never", .any },
    .{ "parked", .any },
});

pub fn resolveTypeName(ctx: anytype, name: []const u8) TypeInfo {
    if (type_name_map.get(name)) |res| return res;
    if (std.mem.eql(u8, name, "function")) return .{ .function = &ANY_FN_SIG };
    if (name.len > 0 and name[0] == ':') return .{ .atom = name };
    if (ctx.resolveTypeAlias(name)) |aliased| return aliased;
    return .{ .struct_type = name };
}

pub fn inferExprType(ctx: anytype, node: *const ast.Node) TypeInfo {
    return switch (node.expr) {
        .number => |n| if (n.is_float) .float else .int,
        .string, .multiline_string => .string,
        .hash => |name| .{ .atom = name },
        .nil => .{ .atom = ":nil" },
        .ident => |name| ctx.inferIdentType(name),
        .unary => |u| inferUnaryOp(u.op, inferExprType(ctx, u.expr)),
        .binary => |b| inferBinaryOp(b.op, inferExprType(ctx, b.left), inferExprType(ctx, b.right)),
        .and_expr, .or_expr => .bool,
        .if_expr => |v| inferIfType(inferExprType(ctx, v.then_expr), if (v.else_expr) |e| inferExprType(ctx, e) else null),
        .tuple => |items| inferTupleType(ctx, items),
        .table => .{ .struct_type = "table" },
        .call => |call| ctx.inferCallReturnType(call.callee, @as([]const *ast.Node, call.args), call.type_args),
        .field => |field| ctx.inferFieldType(field.object, field.name),
        .index => |index| inferIndexType(ctx, index.object, index.key),
        .fn_expr => |fn_expr| ctx.inferFnType(fn_expr.params, fn_expr.return_type, fn_expr.type_params),
        .block => |exprs| inferBlockResultType(ctx, exprs),
        .return_expr => .any,
        .loop_expr => |v| inferExprType(ctx, v.body),
        .for_loop => |v| inferExprType(ctx, v.body),
        .while_loop => |v| inferExprType(ctx, v.body),
        .break_expr => |val| if (val) |v| inferExprType(ctx, v) else .any,
        .try_expr => |inner| blk: {
            const it = inferExprType(ctx, inner);
            break :blk if (it == .@"union") okTypeFromUnion(it) else it;
        },
        .orelse_expr => |v| inferOrelseType(inferExprType(ctx, v.left), inferExprType(ctx, v.right)),
        .comp_block => |cb| inferExprType(ctx, cb.expr),
        .import_stmt, .test_block, .test_suite, .macro_expr, .proc_macro, .quasiquote => .any,
        .match_expr => |v| inferMatchType(ctx, v.subject, v.arms),
        .range_literal => .int,
        .assign_expr, .decl, .binding, .tuple_pattern, .type_alias => .any,
        .struct_def => |def| .{ .struct_type = def.name },
    };
}

pub fn inferTupleType(ctx: anytype, items: []const *ast.Node) TypeInfo {
    if (items.len == 0) return .{ .tuple = &.{} };
    const types = ctx.alloc.alloc(TypeInfo, items.len) catch return .any;
    for (items, types) |item, *dst| dst.* = inferExprType(ctx, item);
    return .{ .tuple = types };
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
    if (exprs.len == 0) return .any;
    return inferExprType(ctx, exprs[exprs.len - 1]);
}


/// substitute type params in a TypeInfo tree
/// subst is any type with `get(key: []const u8) ?TypeInfo`
pub fn substituteTypeParams(alloc: std.mem.Allocator, ti: TypeInfo, subst: anytype) !TypeInfo {
    return switch (ti) {
        .type_var => |name| subst.get(name) orelse .any,
        .tuple => |items| blk: {
            const new_items = try alloc.alloc(TypeInfo, items.len);
            for (items, new_items) |item, *dst| dst.* = try substituteTypeParams(alloc, item, subst);
            break :blk TypeInfo{ .tuple = new_items };
        },
        .function => |fsig| blk: {
            const new_params = try alloc.alloc(TypeInfo, fsig.params.len);
            for (fsig.params, new_params) |p, *np| np.* = try substituteTypeParams(alloc, p, subst);
            const new_ret = try substituteTypeParams(alloc, fsig.return_type, subst);
            const new_sig = try alloc.create(FunctionSignature);
            new_sig.* = FunctionSignature{
                .params = new_params,
                .return_type = new_ret,
                .param_names = fsig.param_names,
                .type_params = fsig.type_params,
            };
            break :blk TypeInfo{ .function = new_sig };
        },
        else => ti,
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
    var vm = try VM.init(testRuntime());
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

test "binary int + int emits add" {
    var vm = try VM.init(testRuntime());
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

    var saw_add = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_int) saw_add = true;
    }
    try std.testing.expect(saw_add);
}

test "binary float + float emits add" {
    var vm = try VM.init(testRuntime());
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

    var saw_add = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add) saw_add = true;
    }
    try std.testing.expect(saw_add);
}

test "negate int emits negate_int" {
    var vm = try VM.init(testRuntime());
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

    var saw_neg = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .negate_int) saw_neg = true;
    }
    try std.testing.expect(saw_neg);
}

test "comparison int == int emits eq_int" {
    var vm = try VM.init(testRuntime());
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

    var saw_eq = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .eq_int) saw_eq = true;
    }
    try std.testing.expect(saw_eq);
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
    var vm = try VM.init(testRuntime());
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
test "chained typed math emits add and mul" {
    var vm = try VM.init(testRuntime());
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

    var saw_add = false;
    var saw_mul = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_int) saw_add = true;
        if (inst.op == .mul_int) saw_mul = true;
    }
    try std.testing.expect(saw_add);
    try std.testing.expect(saw_mul);
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

test "global typed binding rejects type mismatch" {
    try t.expectCompileError(
        \\ const x: int = "hello"
    , .ParseError);
}

test "global typed binding accepts matching type" {
    try t.top_number(
        \\ const x: int = 42
        \\ x
    , 42);
}

test "typed assignment rejects type mismatch" {
    try t.expectCompileError(
        \\ let x: int = 5
        \\ x = "hello"
    , .ParseError);
}

test "untyped assignment allows type change" {
    try t.top_string(
        \\ let x = 5
        \\ x = "hello"
        \\ x
    , "hello");
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

test "implicit return validates block-local variable type" {
    try t.expectCompileError(
        \\ fn f() -> int do
        \\   let x = "hello"
        \\   x
        \\ end
    , .ParseError);
}

test "loop expression infers correct return type" {
    try t.expectCompileError(
        \\ fn f() -> string do
        \\   for i in 0..10 do i end
        \\ end
    , .ParseError);
}

test "upvalue assignment respects type annotation" {
    try t.expectCompileError(
        \\ const outer = fn() do
        \\     let x: int = 5
        \\     const inner = fn() do x = "hello" end
        \\ end
    , .ParseError);
}

test "dynamic callee validates argument types" {
    try t.expectCompileError(
        \\ const f: function = fn(x: int) x
        \\ f("hello")
    , .ParseError);
}

test "tuple pattern binding respects type annotation" {
    try t.expectCompileError(
        \\ const tup: string = (1, 2)
    , .ParseError);
}

test "for loop expression produces int type" {
    try t.top_number(
        \\ fn f() -> int do
        \\   for i in 0..5 do i end
        \\ end
        \\ f()
    , 4);
}

test "type alias gets unaliased" {
    try t.top_true(
        \\ type Als =
        \\       (:aa, int)
        \\     | (:bb, float)
        \\ 
        \\ let x: Als = (:aa, 55)
        \\ let y: Als = (:bb, 100.1)
        \\ 
        \\ x[1] + y[1] == 155.1
    );
}

test "tuple type annotation" {
    try t.top_true(
        \\ let x: (:aa, int) | (:bb, float) = (:aa, 55)
        \\ let y: (:aa, int) | (:bb, float) = (:bb, 100.1)
        \\ 
        \\ x[1] + y[1] == 155.1
    );
}

test "comp block infers int from literal" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let x = comp 42
        \\ x + 1
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

test "match narrowing enables specialized add_int from union payload" {
    // narrowing should make `v` int instead of any, so `v + 1` should emit add_int
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ type Res = (:ok, int) | (:err, string)
        \\ let x: Res = (:ok, 42)
        \\ match x
        \\ | (:ok, v) => v + 1
        \\ | (:err, _) => 0
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

test "return type propagation: const binding with annotated fn" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ const add = fn(a: int, b: int) a + b
        \\ let x = add(3, 4)
        \\ x + 1
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

test "return type propagation: fn five() 5" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn five() 5
        \\ let x = five()
        \\ x + 1
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

test "annotated function return type propagates to caller via pointer" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn add(a: int, b: int) a + b
        \\ let x = add(3, 4)
        \\ x + 1
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

//
// generics / type_var tests
//

fn testRuntime() revo.Runtime {
    return .{
        .alloc = std.testing.allocator,
        .io = std.testing.io,
        .diag_alloc = undefined,
        .diag_arena = null,
    };
}

test "types: type_var equality" {
    const TI = revo.lang.compiler.types.TypeInfo;
    const a = TI{ .type_var = "T" };
    const b = TI{ .type_var = "T" };
    const c = TI{ .type_var = "U" };
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
    try std.testing.expect(!a.eql(.int));
}

test "types: type_var coercion" {
    const types = revo.lang.compiler.types;
    const tv = types.TypeInfo{ .type_var = "T" };
    try std.testing.expect(types.canCoerce(tv, .int));
    try std.testing.expect(types.canCoerce(.int, tv));
    try std.testing.expect(types.canCoerce(tv, .any));
    try std.testing.expect(types.canCoerce(.any, tv));
    try std.testing.expect(types.canCoerce(tv, tv));
}

test "substituteTypeParams direct type var" {
    const types = revo.lang.compiler.types;
    const alloc = std.testing.allocator;
    var subst = std.StringHashMap(types.TypeInfo).init(alloc);
    defer subst.deinit();
    try subst.put("T", .int);

    const result = try types.substituteTypeParams(alloc, types.TypeInfo{ .type_var = "T" }, subst);
    try std.testing.expect(result.eql(.int));
}

test "substituteTypeParams unknown type var becomes any" {
    const types = revo.lang.compiler.types;
    const alloc = std.testing.allocator;
    var subst = std.StringHashMap(types.TypeInfo).init(alloc);
    defer subst.deinit();

    const result = try types.substituteTypeParams(alloc, types.TypeInfo{ .type_var = "T" }, subst);
    try std.testing.expect(result.eql(.any));
}

test "substituteTypeParams tuple with type var" {
    const types = revo.lang.compiler.types;
    const alloc = std.testing.allocator;
    var subst = std.StringHashMap(types.TypeInfo).init(alloc);
    defer subst.deinit();
    try subst.put("T", .int);

    const input = types.TypeInfo{ .tuple = &.{ types.TypeInfo{ .type_var = "T" }, .string } };
    const result = try types.substituteTypeParams(alloc, input, subst);
    try std.testing.expect(result == .tuple);
    try std.testing.expect(result.tuple.len == 2);
    try std.testing.expect(result.tuple[0].eql(.int));
    try std.testing.expect(result.tuple[1].eql(.string));
    alloc.free(result.tuple);
}

test "substituteTypeParams multiple type vars" {
    const types = revo.lang.compiler.types;
    const alloc = std.testing.allocator;
    var subst = std.StringHashMap(types.TypeInfo).init(alloc);
    defer subst.deinit();
    try subst.put("T", .int);
    try subst.put("U", .string);

    const input = types.TypeInfo{ .tuple = &.{ types.TypeInfo{ .type_var = "T" }, types.TypeInfo{ .type_var = "U" } } };
    const result = try types.substituteTypeParams(alloc, input, subst);
    try std.testing.expect(result == .tuple);
    try std.testing.expect(result.tuple.len == 2);
    try std.testing.expect(result.tuple[0].eql(.int));
    try std.testing.expect(result.tuple[1].eql(.string));
    alloc.free(result.tuple);
}

test "substituteTypeParams function sig with type var" {
    const types = revo.lang.compiler.types;
    const alloc = std.testing.allocator;
    var subst = std.StringHashMap(types.TypeInfo).init(alloc);
    defer subst.deinit();
    try subst.put("T", .int);

    const sig = try alloc.create(types.FunctionSignature);
    sig.* = .{
        .params = &.{types.TypeInfo{ .type_var = "T" }},
        .return_type = types.TypeInfo{ .type_var = "T" },
        .param_names = &.{"x"},
    };
    const input = types.TypeInfo{ .function = sig };
    const result = try types.substituteTypeParams(alloc, input, subst);
    try std.testing.expect(result == .function);
    try std.testing.expect(result.function.params.len == 1);
    try std.testing.expect(result.function.params[0].eql(.int));
    try std.testing.expect(result.function.return_type.eql(.int));
    alloc.destroy(sig);
    alloc.free(result.function.params);
    alloc.destroy(result.function);
}

test "generics identity fn enables add_int" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn id[T](x: T) x
        \\ let y = id(42)
        \\ y + 1
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

test "generics identity fn with string compiles and runs" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn id[T](x: T) x
        \\ id("hello")
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);
}

test "generics compound return type (:ok, T) propagates inner type" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn wrap[T](x: T) -> (:ok, T) (:ok, x)
        \\ let r = wrap(42)
        \\ r[1] + 1
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);
}

test "generics multiple type params with tuple return compile" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn pair[T, U](a: T, b: U) -> (T, U)
        \\ pair(1, "hi")
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);
}

test "generics non-inferrable type param (return-only) compiles" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn make[T]() 5
        \\ make()
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);
}

test "generics repeated type param works" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn same[T](a: T, b: T) a
        \\ let x = same(42, 99)
        \\ x + 1
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

test "explicit call-site type args make[int]() resolves return type" {
    try t.top_number(
        \\ fn make[T]() -> T 5
        \\ make[int]()
    , 5);
}

test "explicit call-site type args id[int](42) resolves return type" {
    try t.top_number(
        \\ fn id[T](x: T) -> T x
        \\ id[int](42)
    , 42);
}
