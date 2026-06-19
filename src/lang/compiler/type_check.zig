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

pub fn inferCallReturnType(
    self: *Compiler,
    callee: *const Node,
    args: []const *Node,
    type_args: []const []const u8,
) TypeInfo {
    const callee_type = inferExprType(self, callee);
    if (callee_type == .function) {
        const fn_sig = callee_type.function;
        const ret = fn_sig.return_type;
        // generic fn with type params? substitute from arg types
        if (fn_sig.type_params.len > 0 and ret != .any) {
            var param_map = std.StringHashMap(TypeInfo).init(self.alloc);
            defer param_map.deinit();
            for (fn_sig.type_params, 0..) |tp, i| {
                param_map.put(tp, if (i < type_args.len) types_mod.resolveTypeName(self, type_args[i]) else if (i < args.len and type_args.len == 0) inferExprType(self, args[i]) else .any) catch {};
            }
            return types_mod.substituteTypeParams(self.alloc, ret, &param_map) catch .any;
        }
        if (ret != .any) return ret;
        // .function type hint with .any return? maybe findFnSignature
        // for the compiled sig with inferred return type
    }

    if (callee.expr == .ident) {
        const fn_name = callee.expr.ident;
        const sig = state_mod.findFnSignature(self, fn_name) orelse return .any;
        // generic fn with type params? subst from arg types
        if (sig.type_params.len > 0) {
            // synthetic return type from the what weve got
            const ret_info: TypeInfo = if (sig.return_type_info != .any)
                sig.return_type_info
            else if (sig.return_type) |ret_str|
                types_mod.resolveTypeName(self, ret_str)
            else
                .any;

            if (ret_info != .any) {
                var param_map = std.StringHashMap(TypeInfo).init(self.alloc);
                defer param_map.deinit();
                for (sig.type_params, 0..) |tp, i| {
                    param_map.put(tp, if (i < type_args.len) types_mod.resolveTypeName(self, type_args[i]) else if (i < args.len and type_args.len == 0) inferExprType(self, args[i]) else .any) catch {};
                }
                return types_mod.substituteTypeParams(self.alloc, ret_info, &param_map) catch .any;
            }
        }
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

pub fn inferFnType(self: *Compiler, params: []const ast.FnParam, return_type: ?*ast.TypeExpr, type_params: []const []const u8) TypeInfo {
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
        .type_params = type_params,
    };
    return TypeInfo{ .function = sig };
}

pub fn resolveTypeAlias(self: *Compiler, name: []const u8) ?TypeInfo {
    return self.type_aliases.get(name);
}
