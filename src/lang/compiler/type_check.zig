const std = @import("std");

const revo = @import("revo");
const Compiler = revo.lang.compiler.Compiler;
const ast = @import("../ast.zig");
const Node = ast.Node;
const types_mod = @import("types.zig");
pub const TypeInfo = types_mod.TypeInfo;
const FunctionSignature = types_mod.FunctionSignature;
const state_mod = @import("state.zig");
const type_serde = @import("../type_serde.zig");

pub fn checkType(expected: TypeInfo, actual: TypeInfo) !void {
    if (expected.tag == .any or actual.tag == .any) return;
    if (expected.eql(actual)) return;
    if (types_mod.canCoerce(actual, expected)) return;
    return error.TypeError;
}

pub fn inferExprType(self: *Compiler, node: *const Node) TypeInfo {
    if (self.type_annotations) |map| {
        if (map.get(node)) |t| return t;
    }
    return types_mod.inferExprType(self, node);
}
pub fn inferIdentType(self: *Compiler, name: []const u8) TypeInfo {
    if (state_mod.resolveLocalTypeHint(self, name)) |hint| return hint;
    const local = state_mod.resolveLocalVar(self, name) orelse return inferTypeMap(self, name);
    if (local.type_info) |ti| return ti;
    return inferTypeMap(self, name);
}

fn inferTypeMap(self: *Compiler, name: []const u8) TypeInfo {
    if (self.type_aliases.get(name)) |aliased| return aliased;
    return .{ .tag = .any };
}

const TypeParamSubst = struct {
    entries: [4]struct { name: []const u8, type: TypeInfo } = @splat(.{ .name = &[_]u8{}, .type = .{ .tag = .any } }),
    count: usize = 0,

    pub fn get(self: *const TypeParamSubst, name: []const u8) ?TypeInfo {
        var i: usize = self.count;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.entries[i].name, name)) return self.entries[i].type;
        }
        return null;
    }

    /// first binding per name wins
    pub fn put(self: *TypeParamSubst, name: []const u8, t: TypeInfo) !void {
        if (self.count >= self.entries.len) return;
        if (self.get(name) != null) return;
        self.entries[self.count] = .{ .name = name, .type = t };
        self.count += 1;
    }
};

fn genericSubstReturnType(
    self: *Compiler,
    type_params: []const []const u8,
    type_args: []const []const u8,
    args: []const *Node,
    params: []const TypeInfo,
    return_type: TypeInfo,
) TypeInfo {
    if (type_params.len <= 4) {
        var subst: TypeParamSubst = .{ .count = type_params.len };
        // explicit type args win; the shape walk binds vars found inside
        // compound params (e.g. `unwrap(x: {:err, T}) -> T`)
        for (type_params, 0..) |tp, i| {
            if (i < type_args.len)
                subst.entries[i] = .{
                    .name = tp,
                    .type = types_mod.resolveTypeName(self, type_args[i]),
                };
        }
        var arg_types: [4]TypeInfo = @splat(.{ .tag = .any });
        for (args, 0..) |a, i| {
            if (i < 4) arg_types[i] = inferExprType(self, a);
        }
        types_mod.bindTypeParams(&subst, params, arg_types[0..@min(args.len, 4)]) catch {};
        return types_mod.substituteTypeParams(self.alloc, return_type, &subst) catch TypeInfo{ .tag = .any };
    }
    // fallback: heap-allocated map for many type params
    var param_map = std.StringHashMap(TypeInfo).init(self.alloc);
    defer param_map.deinit();
    for (type_params, 0..) |tp, i| {
        if (i < type_args.len)
            param_map.put(tp, types_mod.resolveTypeName(self, type_args[i])) catch {};
    }
    var arg_types = std.ArrayList(TypeInfo).initCapacity(self.alloc, @min(args.len, 8)) catch return .{ .tag = .any };
    defer arg_types.deinit(self.alloc);
    for (args) |a| {
        if (arg_types.items.len >= 8) break;
        arg_types.append(self.alloc, inferExprType(self, a)) catch return .{ .tag = .any };
    }
    types_mod.bindTypeParams(&param_map, params, arg_types.items) catch {};
    return types_mod.substituteTypeParams(self.alloc, return_type, &param_map) catch TypeInfo{ .tag = .any };
}

pub fn inferCallReturnType(
    self: *Compiler,
    callee: *const Node,
    args: []const *Node,
    type_args: []const []const u8,
    implicit_self: bool,
) TypeInfo {
    _ = implicit_self;
    const callee_type = inferExprType(self, callee);
    if (callee_type.tag == .function) {
        const fn_sig = callee_type.tag.function;
        const ret = fn_sig.return_type;

        if (fn_sig.type_params.len > 0 and ret.tag != .any)
            return genericSubstReturnType(self, fn_sig.type_params, type_args, args, fn_sig.params, ret);
        if (ret.tag != .any) return ret;
        if (callee.expr == .fn_expr and callee.expr.fn_expr.return_type == null)
            return inferExprType(self, callee.expr.fn_expr.body);
    }

    if (callee.expr == .ident) {
        const fn_name = callee.expr.ident;
        const sig = state_mod.findFnSignature(self, fn_name) orelse return .{ .tag = .any };
        if (sig.type_params.len > 0 and sig.return_type.tag != .any)
            return genericSubstReturnType(self, sig.type_params, type_args, args, sig.params, sig.return_type);
        return sig.return_type;
    }

    return .{ .tag = .any };
}

pub fn inferFieldType(self: *Compiler, object: *const Node, name: []const u8) TypeInfo {
    return switch (inferExprType(self, object).tag) {
        // `t.name` where t: { name: string } infers string
        .table => |tbl| blk: {
            if (tbl.fields) |fields| {
                if (types_mod.findField(fields, name)) |f| break :blk f.field_type;
            }
            break :blk .{ .tag = .any };
        },
        else => .{ .tag = .any },
    };
}

pub fn inferFnType(
    self: *Compiler,
    params: []const ast.FnParam,
    return_type: ?*ast.TypeExpr,
    type_params: []const []const u8,
    doc: ?[]const u8,
) TypeInfo {
    var param_types = std.ArrayList(TypeInfo).initCapacity(self.alloc, params.len) catch return .{ .tag = .any };
    defer param_types.deinit(self.alloc);
    var param_names = std.ArrayList([]const u8).initCapacity(self.alloc, params.len) catch return .{ .tag = .any };
    defer param_names.deinit(self.alloc);
    for (params) |p| {
        const pt = if (p.type_name) |tn| type_serde.evalTypeExpr(self, tn) catch TypeInfo{ .tag = .any } else types_mod.implicitParamType(p);
        param_types.append(self.alloc, pt) catch return .{ .tag = .any };
        param_names.append(self.alloc, p.name) catch return .{ .tag = .any };
    }
    const ret = if (return_type) |rt| type_serde.evalTypeExpr(self, rt) catch TypeInfo{ .tag = .any } else TypeInfo{ .tag = .any };
    const combined = types_mod.combinedTypeParams(self.alloc, type_params, params) catch type_params;
    const sig = self.alloc.create(FunctionSignature) catch return .{ .tag = .any };
    sig.* = .{
        .param_names = param_names.toOwnedSlice(self.alloc) catch return TypeInfo{ .tag = .any },
        .params = param_types.toOwnedSlice(self.alloc) catch return TypeInfo{ .tag = .any },
        .return_type = ret,
        .type_params = combined,
        .doc = doc,
    };
    return .{ .tag = .{ .function = sig } };
}

pub fn resolveTypeAlias(self: *Compiler, name: []const u8) ?TypeInfo {
    return self.type_aliases.get(name);
}

/// cant do it
/// no io dep in the compiler
/// sema validates first anwyays so degraditn to any cant false-error
pub fn resolveImportAlias(_: *Compiler, _: []const u8, _: []const u8) ?TypeInfo {
    return null;
}
