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

pub fn typeInfoFromName(type_name: []const u8) TypeInfo {
    if (std.mem.eql(u8, type_name, "int")) return .int;
    if (std.mem.eql(u8, type_name, "float")) return .float;
    if (std.mem.eql(u8, type_name, "string")) return .string;
    if (std.mem.eql(u8, type_name, "bool")) return .bool;
    if (std.mem.eql(u8, type_name, "void")) return .void;
    if (std.mem.eql(u8, type_name, "any")) return .any;
    return .{ .struct_type = type_name };
}

pub fn checkType(alloc: std.mem.Allocator, expected: TypeInfo, actual: TypeInfo, span: ast.Span) !void {
    if (expected == .any or actual == .any) return;
    if (expected.eql(actual)) return;
    if (types_mod.canCoerce(actual, expected)) return;
    _ = alloc;
    _ = span;
    return error.TypeError;
}

pub fn inferExprType(self: *Compiler, expr: *const Node) TypeInfo {
    return switch (expr.expr) {
        .number => |n| if (n == @as(f64, @trunc(n))) .int else .float,
        .string, .multiline_string => .string,
        .hash => |name| .{ .atom = name },
        .nil => .void,
        .ident => |name| inferVarType(self, name),
        .unary => |u| types_mod.inferUnaryOp(
            switch (u.op) {
                .negate => types_mod.UnaryOp.negate,
                .not => types_mod.UnaryOp.not,
                .spawn, .join, .yield => return .any,
            },
            inferExprType(self, u.expr),
        ),
        .binary => |b| types_mod.inferBinaryOp(
            switch (b.op) {
                inline else => |tag| @field(types_mod.BinaryOp, @tagName(tag)),
            },
            inferExprType(self, b.left),
            inferExprType(self, b.right),
        ),
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
        .con_expr, .let_expr, .global => .void,
        .tuple_pattern => .any,
        .struct_def => |def| .{ .struct_type = def.name },
    };
}

fn inferVarType(self: *Compiler, name: []const u8) TypeInfo {
    const fn_state = state_mod.currentFunctionState(self) orelse return .any;
    const type_str = fn_state.var_types.get(name) orelse return .any;
    return typeInfoFromName(type_str orelse return .any);
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
    _ = self;
    _ = call;
    return .any;
}

fn inferFieldType(self: *Compiler, field: anytype) TypeInfo {
    if (self.resolveTypedStructFieldOffset(field.object, field.name)) |_| {
        const fn_state = state_mod.currentFunctionState(self) orelse return .any;
        const type_name = fn_state.var_types.get(field.object.expr.ident) orelse return .any;
        const layout = self.struct_layouter.getLayout(type_name orelse return .any) orelse return .any;
        for (layout.fields) |f| {
            if (std.mem.eql(u8, f.name, field.name)) return f.field_type;
        }
    }
    return .any;
}

fn inferIndexType(self: *Compiler, index: anytype) TypeInfo {
    _ = self;
    _ = index;
    return .any;
}

fn inferFnType(self: *Compiler, fn_expr: anytype) TypeInfo {
    var params = std.ArrayList(TypeInfo).initCapacity(self.alloc, fn_expr.params.len) catch return .any;
    defer params.deinit(self.alloc);
    for (fn_expr.params) |p| {
        const pt = if (p.type_name) |tn| typeInfoFromName(tn) else .any;
        params.append(self.alloc, pt) catch return .any;
    }
    const ret = if (fn_expr.return_type) |rt| typeInfoFromName(rt) else .any;
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
    const expected = typeInfoFromName(type_name);
    const actual = inferExprType(self, value);
    try checkType(self.alloc, expected, actual, value.span);
}

pub fn validateAssignmentType(self: *Compiler, target: *const Node, value: *const Node) !void {
    switch (target.expr) {
        .ident => |name| {
            const fn_state = state_mod.currentFunctionState(self) orelse return;
            if (fn_state.var_types.get(name)) |type_str| {
                if (type_str) |ts| {
                    const expected = typeInfoFromName(ts);
                    const actual = inferExprType(self, value);
                    try checkType(self.alloc, expected, actual, value.span);
                }
            }
        },
        .field => |field| {
            if (self.resolveTypedStructFieldOffset(field.object, field.name)) |field_offset| {
                _ = field_offset;
                const fn_state = state_mod.currentFunctionState(self) orelse return;
                const type_name = fn_state.var_types.get(field.object.expr.ident) orelse return;
                const tn = type_name orelse return;
                const layout = self.struct_layouter.getLayout(tn) orelse return;
                for (layout.fields) |f| {
                    if (std.mem.eql(u8, f.name, field.name)) {
                        const actual = inferExprType(self, value);
                        try checkType(self.alloc, f.field_type, actual, value.span);
                        return;
                    }
                }
            }
        },
        else => {},
    }
}
