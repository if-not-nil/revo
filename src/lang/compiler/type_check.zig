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
    const roundtrip = types_mod.resolveTypeName(self, name);
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

pub const evalTypeExpr = types_mod.evalTypeExpr;
pub const inferExprType = types_mod.inferExprType;
fn inferVarType(self: *Compiler, name: []const u8) TypeInfo {
    if (state_mod.resolveLocalTypeHint(self, name)) |hint| return hint;
    const local = state_mod.resolveLocalVar(self, name) orelse return inferTypeMap(self, name);
    if (local.type_name) |tn| return types_mod.resolveTypeName(self, tn);
    return inferTypeMap(self, name);
}

fn inferTypeMap(self: *Compiler, name: []const u8) TypeInfo {
    if (self.type_aliases.get(name)) |aliased| return aliased;
    return state_mod.resolveLocalTypeHint(self, name) orelse .any;
}

pub fn inferIdentType(self: *Compiler, name: []const u8) TypeInfo {
    return inferVarType(self, name);
}

pub fn inferCallReturnType(self: *Compiler, callee: *const Node, args: []const *Node) TypeInfo {
    _ = args;
    const callee_type = inferExprType(self, callee);
    if (callee_type == .function) return callee_type.function.return_type;

    if (callee.expr == .ident) {
        const sig = state_mod.findFnSignature(self, callee.expr.ident) orelse return .any;
        return if (sig.return_type) |ret| types_mod.resolveTypeName(self, ret) else .any;
    }

    return .any;
}

pub fn inferFieldType(self: *Compiler, object: *const Node, name: []const u8) TypeInfo {
    return switch (inferExprType(self, object)) {
        .struct_type => |struct_name| blk: {
            const layout = self.struct_layouts.get(struct_name) orelse break :blk .any;
            for (layout) |f| {
                if (std.mem.eql(u8, f.name, name)) break :blk f.field_type;
            }
            break :blk .any;
        },
        else => .any,
    };
}

pub fn inferFnType(self: *Compiler, params: []const ast.FnParam, return_type: ?*ast.TypeExpr) TypeInfo {
    var param_types = std.ArrayList(TypeInfo).initCapacity(self.alloc, params.len) catch return .any;
    defer param_types.deinit(self.alloc);
    for (params) |p| {
        const pt = if (p.type_name) |tn| evalTypeExpr(self, tn) catch .any else .any;
        param_types.append(self.alloc, pt) catch return .any;
    }
    const ret = if (return_type) |rt| evalTypeExpr(self, rt) catch .any else .any;
    const sig = self.alloc.create(FunctionSignature) catch return .any;
    sig.* = .{
        .params = param_types.toOwnedSlice(self.alloc) catch return .any,
        .return_type = ret,
    };
    return TypeInfo{ .function = sig };
}

pub fn validateBindingType(self: *Compiler, type_name: []const u8, value: *const Node) !void {
    const expected = types_mod.resolveTypeName(self, type_name);
    const actual = inferExprType(self, value);
    try checkType(self.alloc, expected, actual, value.span);
}

pub fn resolveTypeAlias(self: *Compiler, name: []const u8) ?TypeInfo {
    return self.type_aliases.get(name);
}

pub fn validateAssignmentType(self: *Compiler, target: *const Node, value: *const Node) !void {
    switch (target.expr) {
        .ident => |name| {
            const local = state_mod.resolveLocalVar(self, name) orelse return;
            const type_name = local.type_name orelse return;
            const expected = types_mod.resolveTypeName(self, type_name);
            const actual = inferExprType(self, value);
            try checkType(self.alloc, expected, actual, value.span);
        },
        .field => |field| {
            const object_type = inferExprType(self, field.object);
            if (object_type != .struct_type) return;
            const layout = self.struct_layouts.get(object_type.struct_type) orelse return;
            for (layout) |f| {
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

pub fn validateUpvalueAssignmentType(self: *Compiler, name: []const u8, value: *const Node) !void {
    var fn_idx = self.functions.items.len - 1;
    while (fn_idx > 0) {
        fn_idx -= 1;
        const local = state_mod.resolveLocalVarIn(self, fn_idx, name) orelse continue;
        if (!local.type_explicit) return;
        const type_hints = &self.functions.items[fn_idx].type_hints;
        var i = type_hints.items.len;
        while (i > 0) {
            i -= 1;
            const hint = type_hints.items[i];
            if (std.mem.eql(u8, hint.name, name)) {
                const actual = inferExprType(self, value);
                try checkType(self.alloc, hint.type_info, actual, value.span);
                return;
            }
        }
        return;
    }
}
