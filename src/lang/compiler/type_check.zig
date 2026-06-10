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

pub fn checkType(expected: TypeInfo, actual: TypeInfo) !void {
    if (expected == .any or actual == .any) return;
    if (expected.eql(actual)) return;
    if (types_mod.canCoerce(actual, expected)) return;
    return error.TypeError;
}

pub const evalTypeExpr = types_mod.evalTypeExpr;

pub fn inferExprType(self: *Compiler, node: *const Node) TypeInfo {
    if (self.type_annotations) |map| {
        if (map.get(node)) |t| return t;
    }
    return types_mod.inferExprType(self, node);
}
fn inferVarType(self: *Compiler, name: []const u8) TypeInfo {
    if (state_mod.resolveLocalTypeHint(self, name)) |hint| return hint;
    const local = state_mod.resolveLocalVar(self, name) orelse return inferTypeMap(self, name);
    if (local.type_name) |tn| return types_mod.resolveTypeName(self, tn);
    return inferTypeMap(self, name);
}

fn inferTypeMap(self: *Compiler, name: []const u8) TypeInfo {
    if (self.type_aliases.get(name)) |aliased| return aliased;
    return .any;
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
    var param_names = std.ArrayList([]const u8).initCapacity(self.alloc, params.len) catch return .any;
    defer param_names.deinit(self.alloc);
    for (params) |p| {
        const pt = if (p.type_name) |tn| evalTypeExpr(self, tn) catch .any else .any;
        param_types.append(self.alloc, pt) catch return .any;
        param_names.append(self.alloc, p.name) catch return .any;
    }
    const ret = if (return_type) |rt| evalTypeExpr(self, rt) catch .any else .any;
    const sig = self.alloc.create(FunctionSignature) catch return .any;
    sig.* = .{
        .param_names = param_names.toOwnedSlice(self.alloc) catch return .any,
        .params = param_types.toOwnedSlice(self.alloc) catch return .any,
        .return_type = ret,
    };
    return TypeInfo{ .function = sig };
}

pub fn resolveTypeAlias(self: *Compiler, name: []const u8) ?TypeInfo {
    return self.type_aliases.get(name);
}
