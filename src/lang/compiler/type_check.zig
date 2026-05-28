const std = @import("std");

const revo = @import("revo");
const Compiler = revo.lang.compiler.Compiler;
const ast = @import("../ast.zig");
const Node = ast.Node;
const types_mod = @import("types.zig");
pub const TypeInfo = types_mod.TypeInfo;
const FunctionSignature = types_mod.FunctionSignature;
const state_mod = @import("state.zig");

pub const TypeError = struct {
    message: []const u8,
    span: ast.Span,
};

pub fn storedTypeName(self: *Compiler, t: TypeInfo) ?[]const u8 {
    if (t == .any or t == .function or t == .tuple or t == .@"union") return null;
    const name = types_mod.typeName(t);
    const roundtrip = resolveTypeName(self, name);
    return if (roundtrip.eql(t)) name else null;
}

pub fn checkType(alloc: std.mem.Allocator, expected: TypeInfo, actual: TypeInfo, span: ast.Span) !void {
    // std.debug.print("this {any} other {any}", .{ expected, actual });
    if (expected == .any or actual == .any) return;
    if (expected.eql(actual)) return;
    if (types_mod.canCoerce(actual, expected)) return;
    _ = alloc;
    _ = span;
    return error.TypeError;
}

pub fn inferExprType(self: *Compiler, expr: *const Node) TypeInfo {
    return switch (expr.expr) {
        .number => |n| if (n.is_float) .float else .int,
        .string, .multiline_string => .string,
        .hash => |name| .{ .atom = name },
        .nil => .void,
        .ident => |name| inferVarType(self, name),
        .unary => |u| types_mod.inferUnaryOp(u.op, inferExprType(self, u.expr)),
        .binary => |b| types_mod.inferBinaryOp(b.op, inferExprType(self, b.left), inferExprType(self, b.right)),
        .and_expr, .or_expr => .bool,
        .if_expr => |v| inferIfType(self, v),
        .tuple => |items| inferTupleType(self, items),
        .table => .{ .struct_type = "table" },
        .call => |call| inferCallReturnType(self, call),
        .field => |field| inferFieldType(self, field),
        .index => |index| inferIndexType(self, index),
        .fn_expr => |fn_expr| inferFnType(self, fn_expr),
        .block => |exprs| inferBlockType(self, exprs),
        .return_expr => |val| if (val) |_| .void else .void,
        .loop_expr, .while_loop, .for_loop => .void,
        .break_expr => .void,
        .try_expr => |inner| inferExprType(self, inner),
        .orelse_expr => |v| inferOrelseType(self, v),
        .comp_block, .import_expr, .test_block, .test_suite, .macro_expr, .proc_macro => .any,
        .range_literal, .match_expr, .assign_expr => .any,
        .decl, .binding, .module_decl => .void,
        .tuple_pattern => .any,
        .struct_def => |def| .{ .struct_type = def.name },
        .type_alias => .void,
    };
}

fn inferVarType(self: *Compiler, name: []const u8) TypeInfo {
    if (state_mod.resolveLocalTypeHint(self, name)) |hint| return hint;
    const local = state_mod.resolveLocalVar(self, name) orelse return inferTypeMap(self, name);
    if (local.type_name) |tn| return resolveTypeName(self, tn);
    return inferTypeMap(self, name);
}

fn inferTypeMap(self: *Compiler, name: []const u8) TypeInfo {
    if (self.type_aliases.get(name)) |aliased| return aliased;
    const fn_state = state_mod.currentFunctionState(self) orelse return .any;
    const type_str = fn_state.var_types.get(name) orelse return .any;
    return resolveTypeName(self, type_str orelse return .any);
}

fn inferIfType(self: *Compiler, v: anytype) TypeInfo {
    const then_type = inferExprType(self, v.then_expr);
    if (v.else_expr) |else_expr| {
        const else_type = inferExprType(self, else_expr);
        if (then_type.eql(else_type)) return then_type;
        if (then_type == .any) return else_type;
        if (else_type == .any) return then_type;
        return .any;
    }
    if (then_type == .void) return .void;
    return .any;
}

fn inferTupleType(self: *Compiler, items: []const *Node) TypeInfo {
    if (items.len == 0) return TypeInfo{ .tuple = &.{} };
    var types = std.ArrayList(TypeInfo).initCapacity(self.alloc, items.len) catch return .any;
    defer types.deinit(self.alloc);
    for (items) |item| {
        types.append(self.alloc, inferExprType(self, item)) catch return .any;
    }
    return TypeInfo{ .tuple = types.toOwnedSlice(self.alloc) catch return .any };
}

fn inferCallReturnType(self: *Compiler, call: anytype) TypeInfo {
    const callee_type = inferExprType(self, call.callee);
    if (callee_type == .function) return callee_type.function.return_type;

    if (call.callee.expr == .ident) {
        const sig = state_mod.findFnSignature(self, call.callee.expr.ident) orelse return .any;
        return if (sig.return_type) |ret| resolveTypeName(self, ret) else .any;
    }

    return .any;
}

fn inferFieldType(self: *Compiler, field: anytype) TypeInfo {
    return switch (inferExprType(self, field.object)) {
        .struct_type => |name| blk: {
            const layout = self.struct_layouter.getLayout(self.vm, name) orelse break :blk .any;
            for (layout.fields) |f| {
                if (std.mem.eql(u8, f.name, field.name)) break :blk f.field_type;
            }
            break :blk .any;
        },
        else => .any,
    };
}

fn inferIndexType(self: *Compiler, index: anytype) TypeInfo {
    return switch (inferExprType(self, index.object)) {
        .tuple => |items| if (index.key.expr == .number) blk: {
            const key_num = index.key.expr.number.value;
            if (std.math.isFinite(key_num) and @floor(key_num) == key_num and key_num >= 0) {
                const idx: usize = @intFromFloat(key_num);
                if (index.object.expr == .tuple) {
                    const tuple_items = index.object.expr.tuple;
                    if (idx < tuple_items.len) break :blk inferExprType(self, tuple_items[idx]);
                } else if (idx < items.len) {
                    break :blk items[idx];
                }
            }
            break :blk .any;
        } else .any,
        else => .any,
    };
}

fn inferFnType(self: *Compiler, fn_expr: anytype) TypeInfo {
    var params = std.ArrayList(TypeInfo).initCapacity(self.alloc, fn_expr.params.len) catch return .any;
    defer params.deinit(self.alloc);
    for (fn_expr.params) |p| {
        const pt = if (p.type_name) |tn| resolveTypeName(self, tn) else .any;
        params.append(self.alloc, pt) catch return .any;
    }
    const ret = if (fn_expr.return_type) |rt| resolveTypeName(self, rt) else .any;
    const sig = self.alloc.create(FunctionSignature) catch return .any;
    sig.* = .{
        .params = params.toOwnedSlice(self.alloc) catch return .any,
        .return_type = ret,
    };
    return TypeInfo{ .function = sig };
}

fn inferBlockType(self: *Compiler, exprs: []const *Node) TypeInfo {
    if (exprs.len == 0) return .void;
    return inferExprType(self, exprs[exprs.len - 1]);
}

fn inferOrelseType(self: *Compiler, v: anytype) TypeInfo {
    const left_type = inferExprType(self, v.left);
    const right_type = inferExprType(self, v.right);
    if (left_type == .any) return right_type;
    if (right_type == .any) return left_type;
    if (left_type.eql(right_type)) return left_type;
    return .any;
}

pub fn validateBindingType(self: *Compiler, type_name: []const u8, value: *const Node) !void {
    const expected = resolveTypeName(self, type_name);
    const actual = inferExprType(self, value);
    // atom literal assigned to atom-union alias
    if (actual == .atom and expected == .@"union") {
        return;
    }
    try checkType(self.alloc, expected, actual, value.span);
}

pub const TypeExprError = error{
    UnexpectedToken,
    OutOfMemory,
    TypeError,
    UnsupportedSyntax,
};

pub fn resolveTypeName(self: *Compiler, name: []const u8) TypeInfo {
    if (std.mem.eql(u8, name, "int")) return .int;
    if (std.mem.eql(u8, name, "float")) return .float;
    if (std.mem.eql(u8, name, "number")) return numberType();
    if (std.mem.eql(u8, name, "string")) return .string;
    if (std.mem.eql(u8, name, "bool")) return .bool;
    if (std.mem.eql(u8, name, "void")) return .void;
    if (std.mem.eql(u8, name, "any")) return .any;
    if (name.len > 0 and name[0] == ':') return .{ .atom = name };
    if (self.type_aliases.get(name)) |aliased| return aliased;
    return .{ .struct_type = name };
}

fn numberType() TypeInfo {
    return TypeInfo{
        .@"union" = &.{
            .{ .name = "", .types = &.{TypeInfo.int} },
            .{ .name = "", .types = &.{TypeInfo.float} },
        },
    };
}

pub fn evalTypeExpr(self: *Compiler, node: *const Node) TypeExprError!TypeInfo {
    return switch (node.expr) {
        .ident => |name| resolveTypeName(self, name),
        .hash => |name| TypeInfo{ .atom = name },
        .tuple => |items| blk: {
            var types = std.ArrayList(TypeInfo).initCapacity(self.alloc, items.len) catch return error.OutOfMemory;
            errdefer types.deinit(self.alloc);
            for (items) |item| {
                try types.append(self.alloc, try evalTypeExpr(self, item));
            }
            break :blk TypeInfo{ .tuple = try types.toOwnedSlice(self.alloc) };
        },
        .binary => |b| switch (b.op) {
            .@"union" => blk: {
                const left = try evalTypeExpr(self, b.left);
                const right = try evalTypeExpr(self, b.right);
                var variants = std.ArrayList(types_mod.UnionVariant).initCapacity(self.alloc, 4) catch return error.OutOfMemory;
                errdefer variants.deinit(self.alloc);
                try collectVariants(self, left, &variants);
                try collectVariants(self, right, &variants);
                break :blk TypeInfo{ .@"union" = try variants.toOwnedSlice(self.alloc) };
            },
            else => return error.UnsupportedSyntax,
        },
        else => return error.UnsupportedSyntax,
    };
}

fn collectVariants(self: *Compiler, ti: TypeInfo, variants: *std.ArrayList(types_mod.UnionVariant)) TypeExprError!void {
    switch (ti) {
        .@"union" => |us| {
            for (us) |u| try variants.append(self.alloc, u);
        },
        .tuple => |types| {
            try variants.append(self.alloc, .{
                .name = "",
                .types = types,
            });
        },
        else => {
            // make one so its storage outlives this function
            var one = std.ArrayList(TypeInfo).initCapacity(self.alloc, 1) catch return error.OutOfMemory;
            defer one.deinit(self.alloc);
            try one.append(self.alloc, ti);
            try variants.append(self.alloc, .{
                .name = "",
                .types = try one.toOwnedSlice(self.alloc),
            });
        },
    }
}

pub fn evalUnionVariant(self: *Compiler, node: *const Node) TypeExprError!types_mod.UnionVariant {
    switch (node.expr) {
        .tuple => |items| {
            if (items.len == 0) return error.UnsupportedSyntax;
            const name_type = try evalTypeExpr(self, items[0]);
            const name_str = switch (name_type) {
                .atom => |a| a,
                else => return error.UnsupportedSyntax,
            };
            var types = std.ArrayList(TypeInfo).initCapacity(self.alloc, items.len - 1) catch return error.OutOfMemory;
            errdefer types.deinit(self.alloc);
            for (items[1..]) |item| {
                try types.append(self.alloc, try evalTypeExpr(self, item));
            }
            return types_mod.UnionVariant{
                .name = name_str,
                .types = try types.toOwnedSlice(self.alloc),
            };
        },
        else => return error.UnsupportedSyntax,
    }
}

pub fn validateAssignmentType(self: *Compiler, target: *const Node, value: *const Node) !void {
    switch (target.expr) {
        .ident => |name| {
            const expected = inferVarType(self, name);
            if (expected != .any) {
                const actual = inferExprType(self, value);
                try checkType(self.alloc, expected, actual, value.span);
            }
        },
        .field => |field| {
            const object_type = inferExprType(self, field.object);
            if (object_type != .struct_type) return;
            const layout = self.struct_layouter.getLayout(self.vm, object_type.struct_type) orelse return;
            for (layout.fields) |f| {
                if (std.mem.eql(u8, f.name, field.name)) {
                    const actual = inferExprType(self, value);
                    try checkType(self.alloc, f.field_type, actual, value.span);
                    return;
                }
            }
        },
        else => {},
    }
}
