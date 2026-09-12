const std = @import("std");
const revo = @import("revo");
const ast = @import("../ast.zig");

pub const UnionVariant = struct {
    name: []const u8,
    types: []const TypeInfo,
};

/// one named field of a structural table type: `{ name: string }`
pub const RecordField = struct {
    name: []const u8,
    field_type: TypeInfo,
};

/// build a table TypeInfo; the key/value ptrs borrow the caller's
/// storage, arena-owned in practice like every other TypeInfo
pub fn makeTable(key: ?*const TypeInfo, value: *const TypeInfo, fields: ?[]RecordField) TypeInfo {
    return .{ .tag = .{ .table = .{ .key = key, .value = value, .fields = fields } } };
}

/// linear field lookup by name; field lists stay small, no map needed
pub fn findField(fields: []const RecordField, name: []const u8) ?RecordField {
    for (fields) |f| if (std.mem.eql(u8, f.name, name)) return f;
    return null;
}

/// index variant, for replacing a field in place (dupes: last wins)
pub fn findFieldIndex(fields: []const RecordField, name: []const u8) ?usize {
    for (fields, 0..) |f, i| if (std.mem.eql(u8, f.name, name)) return i;
    return null;
}

pub const TypeInfo = struct {
    tag: Tag,
    doc: ?[]const u8 = null,

    pub const Tag = union(enum) {
        bool, // TODO: remove, make this be atom union of :true | :false
        number,
        string,
        atom: []const u8,
        @"union": []const UnionVariant,
        table: struct {
            key: ?*const TypeInfo,
            value: *const TypeInfo,
            // per-field types for `{ name: string }`; null = untyped map
            fields: ?[]const RecordField = null,
        },
        function: *const FunctionSignature,
        any,
        never,
        type_var: []const u8,
    };

    pub fn eql(self: TypeInfo, other: TypeInfo) bool {
        return switch (self.tag) {
            .bool => other.tag == .bool,
            .number => other.tag == .number,
            .string => other.tag == .string,
            .atom => |a| if (other.tag == .atom) std.mem.eql(u8, ast.atomName(a), ast.atomName(other.tag.atom)) else false,
            .@"union" => |us| if (other.tag == .@"union") blk: {
                if (us.len != other.tag.@"union".len) break :blk false;
                for (us, other.tag.@"union") |a, b| {
                    if (!std.mem.eql(u8, a.name, b.name)) break :blk false;
                    if (a.types.len != b.types.len) break :blk false;
                    for (a.types, b.types) |at, bt| if (!eql(at, bt)) break :blk false;
                }
                break :blk true;
            } else false,
            .table => |ti| if (other.tag == .table) blk: {
                const o = other.tag.table;
                if (!eql(ti.value.*, o.value.*)) break :blk false;

                if (ti.key) |tk| {
                    if (o.key) |ok| {
                        if (!eql(tk.*, ok.*)) break :blk false;
                    } else break :blk false;
                } else if (o.key != null) break :blk false;

                // fields compare syntactically, order-sensitive
                if (ti.fields) |fs| {
                    const os = o.fields orelse break :blk false;
                    if (fs.len != os.len) break :blk false;
                    for (fs, os) |f, of| {
                        if (!std.mem.eql(u8, f.name, of.name)) break :blk false;
                        if (!eql(f.field_type, of.field_type)) break :blk false;
                    }
                } else if (o.fields != null) break :blk false;

                break :blk true;
            } else false,
            .function => |f| if (other.tag == .function) blk: {
                const o = other.tag.function;
                if (f == o) break :blk true;
                if (!f.return_type.eql(o.return_type)) break :blk false;
                if (f.params.len != o.params.len) break :blk false;
                for (f.params, o.params) |a, b| if (!a.eql(b)) break :blk false;
                break :blk true;
            } else false,
            .type_var => |name| if (other.tag == .type_var) std.mem.eql(u8, name, other.tag.type_var) else false,
            .any => true,
            .never => other.tag == .never,
        };
    }
};

pub const FunctionSignature = struct {
    params: []const TypeInfo,
    return_type: TypeInfo,
    param_names: []const []const u8 = &.{},
    is_any_fn_sig: bool = false,
    required_count: usize = 0,
    type_params: []const []const u8 = &.{},
    default_values: []const ?*ast.Node = &.{},
    doc: ?[]const u8 = null,
};

/// resolved pieces for one FunctionSignature; every builder (compiler
/// allocFnSig, semantic make/newSig, type_serde eval) walks its own AST
/// because error handling differs, then funnels through here
pub const SignatureParts = struct {
    param_names: []const []const u8,
    params: []const TypeInfo,
    return_type: TypeInfo = .{ .tag = .any },
    required_count: usize = 0,
    type_params: []const []const u8 = &.{},
    default_values: []const ?*ast.Node = &.{},
    doc: ?[]const u8 = null,
};

pub fn newSignature(alloc: std.mem.Allocator, parts: SignatureParts) std.mem.Allocator.Error!*FunctionSignature {
    const sig = try alloc.create(FunctionSignature);
    sig.* = .{
        .param_names = parts.param_names,
        .params = parts.params,
        .return_type = parts.return_type,
        .required_count = parts.required_count,
        .type_params = parts.type_params,
        .default_values = parts.default_values,
        .doc = parts.doc,
    };
    return sig;
}

/// sentinel "any function" type,,, matches any callable value
/// ptr identity;; only matches when &ANY_FN_SIG is used
pub const ANY_FN_SIG: FunctionSignature = .{
    .params = &.{},
    .return_type = .{ .tag = .any },
    .param_names = &.{},
    .is_any_fn_sig = true,
};

/// sentinel type info for `any` used by the generic table sentinel
const ANY_TI: TypeInfo = .{ .tag = .any };
/// sentinel for a generic table (no key/value constraints)
pub const TABLE_GENERIC: TypeInfo = makeTable(null, &ANY_TI, null);

/// deep-clone a TypeInfo into a new allocator
pub fn clone(ti: TypeInfo, alloc: std.mem.Allocator) !TypeInfo {
    return switch (ti.tag) {
        .bool, .number, .string, .any, .never => ti,
        .atom => |s| .{ .tag = .{ .atom = try alloc.dupe(u8, s) } },
        .type_var => |s| .{ .tag = .{ .type_var = try alloc.dupe(u8, s) } },
        .@"union" => |variants| {
            const owned = try alloc.alloc(UnionVariant, variants.len);
            for (variants, 0..) |v, i| {
                const types_owned = try alloc.alloc(TypeInfo, v.types.len);
                for (v.types, 0..) |vt, j| types_owned[j] = try clone(vt, alloc);
                owned[i] = .{
                    .name = try alloc.dupe(u8, v.name),
                    .types = types_owned,
                };
            }
            return .{ .tag = .{ .@"union" = owned } };
        },
        .table => |tbl| {
            const key: ?*TypeInfo = if (tbl.key) |_| try alloc.create(TypeInfo) else null;
            errdefer if (key) |k| alloc.destroy(k);

            if (key) |k| k.* = try clone(tbl.key.?.*, alloc);
            const value = try alloc.create(TypeInfo);
            value.* = try clone(tbl.value.*, alloc);
            errdefer alloc.destroy(value);

            const fields: ?[]RecordField = if (tbl.fields) |fs| blk: {
                const owned = try alloc.alloc(RecordField, fs.len);
                errdefer alloc.free(owned);

                for (fs, owned) |f, *dst| dst.* = .{
                    .name = try alloc.dupe(u8, f.name),
                    .field_type = try clone(f.field_type, alloc),
                };
                break :blk owned;
            } else null;
            return .{ .tag = .{ .table = .{ .key = key, .value = value, .fields = fields } } };
        },
        .function => |sig| {
            const owned = try alloc.create(FunctionSignature);
            errdefer alloc.destroy(owned);

            const params = try alloc.alloc(TypeInfo, sig.params.len);
            errdefer alloc.free(params);

            for (sig.params, 0..) |p, i| params[i] = try clone(p, alloc);
            const param_names = try alloc.alloc([]const u8, sig.param_names.len);
            errdefer alloc.free(param_names);

            for (sig.param_names, 0..) |n, i| param_names[i] = try alloc.dupe(u8, n);
            const type_params = try alloc.alloc([]const u8, sig.type_params.len);
            errdefer alloc.free(type_params);

            for (sig.type_params, 0..) |tp, i| type_params[i] = try alloc.dupe(u8, tp);
            owned.* = .{
                .params = params,
                .return_type = try clone(sig.return_type, alloc),
                .param_names = param_names,
                .is_any_fn_sig = sig.is_any_fn_sig,
                .required_count = sig.required_count,
                .type_params = type_params,
            };
            return .{ .tag = .{ .function = owned } };
        },
    };
}

/// free all heap-allocated memory owned by a TypeInfo
pub fn deinitType(ti: *TypeInfo, alloc: std.mem.Allocator) void {
    if (ti.doc) |d| alloc.free(d);
    switch (ti.tag) {
        .bool, .number, .string, .any, .never => {},
        .atom, .type_var => |s| if (s.len > 0) alloc.free(s),
        .@"union" => |variants| {
            for (variants) |*v| {
                alloc.free(v.name);
                for (v.types) |*vt| deinitType(@constCast(vt), alloc);
                alloc.free(v.types);
            }
            alloc.free(variants);
        },
        .table => |tbl| {
            if (tbl.key) |k| {
                deinitType(@constCast(k), alloc);
                alloc.destroy(@constCast(k));
            }
            deinitType(@constCast(tbl.value), alloc);
            alloc.destroy(@constCast(tbl.value));
            if (tbl.fields) |fields| {
                for (fields) |*f| {
                    alloc.free(f.name);
                    deinitType(@constCast(&f.field_type), alloc);
                }
                alloc.free(fields);
            }
        },
        .function => |sig| {
            for (sig.params) |*p| deinitType(@constCast(p), alloc);
            alloc.free(sig.params);
            deinitType(@constCast(&sig.return_type), alloc);
            for (sig.param_names) |n| alloc.free(n);
            alloc.free(sig.param_names);
            for (sig.type_params) |tp| alloc.free(tp);
            alloc.free(sig.type_params);
            alloc.destroy(@constCast(sig));
        },
    }
    ti.* = .{ .tag = .never };
}

pub fn canCoerce(from: TypeInfo, to: TypeInfo) bool {
    if (from.tag == .never) return true;
    if (to.tag == .never) return false;
    if (from.eql(to) or to.tag == .any or from.tag == .any or from.tag == .type_var or to.tag == .type_var) return true;
    if (from.tag == .table and to.tag == .table) {
        const from_table = from.tag.table;
        const to_table = to.tag.table;
        // target names fields: every one must exist in source with a
        // fitting type; extra source fields are fine, tables are open
        if (to_table.fields) |wants| {
            if (from_table.fields) |haves| {
                for (wants) |w| {
                    const have = findField(haves, w.name) orelse return false;
                    if (!canCoerce(have.field_type, w.field_type)) return false;
                }
                return true;
            }
            // source field types unknown: fall back to the value check
        }
        if (!canCoerce(from_table.value.*, to_table.value.*)) return false;
        if (to_table.key == null) return true;
        if (from_table.key == null) return true;
        return canCoerce(from_table.key.?.*, to_table.key.?.*);
    }
    // function subtyping: contravariant params, covariant return
    if (to.tag == .function and from.tag == .function) {
        const to_sig = to.tag.function;
        const from_sig = from.tag.function;
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
    // empty atom (.atom == "") is a sentinel for "any atom"
    if (to.tag == .atom and from.tag == .atom) {
        if (to.tag.atom.len == 0 or from.tag.atom.len == 0) return true;
        return std.mem.eql(u8, to.tag.atom, from.tag.atom);
    }
    // :true and :false are bool
    if (to.tag == .bool and from.tag == .atom) {
        const name = ast.atomName(from.tag.atom);
        return std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false");
    }
    if (to.tag == .@"union") {
        // fast-path for atom literals vs atom-only variants
        if (from.tag == .atom) {
            for (to.tag.@"union") |variant| {
                if (variant.types.len == 1 and variant.types[0].tag == .atom) {
                    if (std.mem.eql(u8, ast.atomName(variant.types[0].tag.atom), ast.atomName(from.tag.atom))) return true;
                }
            }
        }
        for (to.tag.@"union") |variant| {
            if (unionVariantAccepts(variant, from)) return true;
        }
    }
    if (from.tag == .@"union") {
        if (from.tag.@"union".len == 0) return false;
        for (from.tag.@"union") |variant| {
            if (!targetAcceptsVariant(variant, to)) return false;
        }
        return true;
    }
    return from.tag == .number and to.tag == .number;
}

fn unionVariantAccepts(variant: UnionVariant, value: TypeInfo) bool {
    if (variant.types.len == 1) return canCoerce(value, variant.types[0]);
    return false;
}

fn targetAcceptsVariant(variant: UnionVariant, target: TypeInfo) bool {
    if (variant.types.len == 1) return canCoerce(variant.types[0], target);
    return false;
}

pub fn inferBinaryOp(op: ast.BinOp, l: TypeInfo, r: TypeInfo) TypeInfo {
    return switch (op) {
        .@"union" => .{ .tag = .any },
        .concat => .{ .tag = .string },
        .add, .sub, .div, .mod, .pow => if (l.tag == .number and r.tag == .number) .{ .tag = .number } else .{ .tag = .any },
        .mul => if (l.tag == .number and r.tag == .number) .{ .tag = .number } else .{ .tag = .any },
        .int_div => if (l.tag == .number and r.tag == .number) .{ .tag = .number } else .{ .tag = .any },
        .band, .bor, .bxor, .shl, .shr => if (l.tag == .number and r.tag == .number) .{ .tag = .number } else .{ .tag = .any },
        .eq, .neq, .lt, .gt, .lte, .gte => .{ .tag = .bool },
    };
}

pub fn inferUnaryOp(op: ast.UnOp, T: TypeInfo) TypeInfo {
    return switch (op) {
        .negate => if (T.tag == .number) T else .{ .tag = .any },
        .not => .{ .tag = .bool },
        else => .{ .tag = .any },
    };
}

pub fn inferIfType(then_type: TypeInfo, else_type: ?TypeInfo) TypeInfo {
    if (else_type) |et| return unifyBranchType(then_type, et);
    return .{ .tag = .any };
}

/// unify a branch type into the running if/orelse/match result:
/// `never` branches diverge and contribute nothing; a leading `any` is
/// overwritten by a later concrete type (pattern vars narrow only while
/// their scope is live, so re-inference after scope pop sees `any`)
pub fn unifyBranchType(acc: TypeInfo, branch: TypeInfo) TypeInfo {
    if (branch.tag == .never) return acc;
    if (acc.tag == .never) return branch;
    if (acc.tag == .any) return branch;
    if (branch.tag == .any) return acc;
    if (acc.eql(branch)) return acc;
    return .{ .tag = .any };
}

pub fn inferMatchType(ctx: anytype, subject: *const ast.Node, arms: []const ast.MatchArm) TypeInfo {
    _ = subject;
    var result: TypeInfo = .{ .tag = .never };
    for (arms) |arm| {
        result = unifyBranchType(result, inferExprType(ctx, arm.then));
    }
    return result;
}

pub fn inferOrelseType(left: TypeInfo, right: TypeInfo) TypeInfo {
    const unwrapped = if (isResultType(left)) okTypeFrom(left) else left;
    return unifyBranchType(unwrapped, right);
}

fn isResultTag(name: []const u8) bool {
    return std.mem.eql(u8, name, ":ok") or std.mem.eql(u8, name, "ok") or
        std.mem.eql(u8, name, ":err") or std.mem.eql(u8, name, "err");
}

fn isOkTag(name: []const u8) bool {
    return std.mem.eql(u8, name, ":ok") or std.mem.eql(u8, name, "ok");
}

/// tag of one union variant, table-style `{:ok, T}`
///     : tags live in positional field "0", payload in "1", "2", ...
pub fn unionVariantTagEql(variant: UnionVariant, tag: []const u8) bool {
    const pattern_tag = if (tag.len > 0 and tag[0] == ':') tag[1..] else tag;
    if (variant.types.len == 0) return false;

    if (variant.types[0].tag == .atom) {
        return std.mem.eql(u8, ast.atomName(variant.types[0].tag.atom), pattern_tag);
    }

    if (variant.types[0].tag == .table) {
        const fields = variant.types[0].tag.table.fields orelse return false;
        if (fields.len == 0 or !std.mem.eql(u8, fields[0].name, "0")) return false;
        if (fields[0].field_type.tag != .atom) return false;
        return std.mem.eql(u8, ast.atomName(fields[0].field_type.tag.atom), pattern_tag);
    }

    return false;
}

/// payload types after the tag: leading numeric table fields past "0"
///     - stops at the first non-positional field
pub fn appendUnionVariantPayload(alloc: std.mem.Allocator, variant: UnionVariant, out: *std.ArrayList(TypeInfo)) !void {
    if (variant.types.len == 0) return;
    if (variant.types[0].tag == .atom) {
        try out.appendSlice(alloc, variant.types[1..]);
        return;
    }

    if (variant.types[0].tag == .table) {
        const fields = variant.types[0].tag.table.fields orelse return;
        if (fields.len == 0) return;
        var idx: usize = 1;

        for (fields[1..]) |f| {
            var buf: [16]u8 = undefined;
            const want = std.fmt.bufPrint(&buf, "{d}", .{idx}) catch return;
            if (!std.mem.eql(u8, f.name, want)) return;
            try out.append(alloc, f.field_type);
            idx += 1;
        }
    }
}

/// `{:ok, T} | {:err, any}` unions (both the `!T` sugar and the literal form)
///     : the shapes `?` and `orelse` unwrap at runtime
pub fn isResultType(ti: TypeInfo) bool {
    return switch (ti.tag) {
        .@"union" => |us| blk: {
            for (us) |v| {
                if (unionVariantTagEql(v, ":ok") or unionVariantTagEql(v, ":err")) break :blk true;
            }
            break :blk false;
        },
        .table => |tbl| blk: {
            const fields = tbl.fields orelse break :blk false;
            if (fields.len == 0 or fields[0].field_type.tag != .atom) break :blk false;
            break :blk isResultTag(ast.atomName(fields[0].field_type.tag.atom));
        },
        else => false,
    };
}

///
/// unwrap the `:ok` payload from a `{:ok, T} | {:err, any}` union
///     or a `{:ok, T}` table
/// ; mirrors the runtime, which yields only the first payload element
pub fn okTypeFrom(ti: TypeInfo) TypeInfo {
    return switch (ti.tag) {
        .@"union" => |variants| blk: {
            for (variants) |v| {
                if (!unionVariantTagEql(v, ":ok")) continue;
                if (v.types.len > 0 and v.types[0].tag == .table) {
                    const fields = v.types[0].tag.table.fields orelse continue;
                    if (fields.len >= 2 and std.mem.eql(u8, fields[1].name, "1")) break :blk fields[1].field_type;
                    continue;
                }
            }
            break :blk .{ .tag = .any };
        },
        .table => |tbl| blk: {
            const fields = tbl.fields orelse break :blk .{ .tag = .any };
            if (fields.len < 2 or fields[0].field_type.tag != .atom) break :blk .{ .tag = .any };
            if (!isOkTag(ast.atomName(fields[0].field_type.tag.atom))) break :blk .{ .tag = .any };
            if (!std.mem.eql(u8, fields[1].name, "1")) break :blk .{ .tag = .any };
            break :blk fields[1].field_type;
        },
        else => .{ .tag = .any },
    };
}

pub fn collectVariants(alloc: std.mem.Allocator, ti: TypeInfo, variants: *std.ArrayList(UnionVariant)) !void {
    switch (ti.tag) {
        .@"union" => |us| for (us) |u| try variants.append(alloc, u),
        else => {
            var one = try std.ArrayList(TypeInfo).initCapacity(alloc, 1);
            errdefer one.deinit(alloc);
            try one.append(alloc, ti);
            try variants.append(alloc, .{ .name = "", .types = try one.toOwnedSlice(alloc) });
        },
    }
}

pub const type_name_map: std.StaticStringMap(TypeInfo) = std.StaticStringMap(TypeInfo).initComptime(.{
    .{ "number", TypeInfo{ .tag = .number } },
    .{ "num", TypeInfo{ .tag = .number } },
    .{ "int", TypeInfo{ .tag = .number } },
    .{ "string", TypeInfo{ .tag = .string } },
    .{ "bool", TypeInfo{ .tag = .bool } },
    .{ "any", TypeInfo{ .tag = .any } },
    .{ "nil", TypeInfo{ .tag = .{ .atom = ":nil" } } },
    .{ "table", TABLE_GENERIC },
    .{ "function", TypeInfo{ .tag = .{ .function = &ANY_FN_SIG } } },
    .{ "atom", TypeInfo{ .tag = .{ .atom = "" } } }, // empty atom payload is the "any atom" sentinel
    .{ "never", TypeInfo{ .tag = .never } },
    .{ "parked", TypeInfo{ .tag = .any } },
});

pub fn resolveTypeName(ctx: anytype, name: []const u8) TypeInfo {
    if (type_name_map.get(name)) |res| return res;
    if (name.len > 0 and name[0] == ':') return .{ .tag = .{ .atom = name } };
    if (ctx.resolveTypeAlias(name)) |aliased| return aliased;
    return .{ .tag = .any };
}

pub fn inferExprType(ctx: anytype, node: *const ast.Node) TypeInfo {
    return switch (node.expr) {
        .number => .{ .tag = .number },
        .string, .multiline_string => .{ .tag = .string },
        .hash => |name| .{ .tag = .{ .atom = name } },
        .nil => .{ .tag = .{ .atom = ":nil" } },
        .ident => |name| ctx.inferIdentType(name),
        .unary => |u| inferUnaryOp(u.op, inferExprType(ctx, u.expr)),
        .binary => |b| inferBinaryOp(b.op, inferExprType(ctx, b.left), inferExprType(ctx, b.right)),
        .and_expr, .or_expr => .{ .tag = .bool },
        .if_expr => |v| inferIfType(
            inferExprType(ctx, v.then_expr),
            if (v.else_expr) |e| inferExprType(ctx, e) else null,
        ),
        .unless_expr => |v| inferIfType(
            inferExprType(ctx, v.then_expr),
            if (v.else_expr) |e| inferExprType(ctx, e) else null,
        ),

        .table => |entries| inferTableType(ctx, entries),
        .call => |call| ctx.inferCallReturnType(call.callee, @as([]const *ast.Node, call.args), call.type_args, call.implicit_self),
        .field => |field| ctx.inferFieldType(field.object, field.name),
        .index => |index| inferIndexType(ctx, index.object, index.key),
        .fn_expr => |fn_expr| ctx.inferFnType(fn_expr.params, fn_expr.return_type, fn_expr.type_params, fn_expr.doc),
        .block => |exprs| inferBlockResultType(ctx, exprs),
        .return_expr => .{ .tag = .any },
        .loop_expr => |v| if (v.label == null) .{ .tag = .{ .atom = "loop" } } else .{ .tag = .any },
        .for_loop => |v| if (v.label == null) .{ .tag = .{ .atom = "loop" } } else .{ .tag = .any },
        .while_loop => |v| if (v.label == null) .{ .tag = .{ .atom = "loop" } } else .{ .tag = .any },
        .break_expr => |b| if (b.value) |v| inferExprType(ctx, v) else .{ .tag = .any },
        .continue_expr => |c| if (c.value) |v| inferExprType(ctx, v) else .{ .tag = .any },
        .labeled_block => |lb| inferExprType(ctx, lb.body),
        .try_expr => |inner| blk: {
            const it = inferExprType(ctx, inner);
            break :blk switch (it.tag) {
                .@"union", .table => okTypeFrom(it),
                else => it,
            };
        },
        .orelse_expr => |v| inferOrelseType(inferExprType(ctx, v.left), inferExprType(ctx, v.right)),
        .comp_block => |cb| inferExprType(ctx, cb.expr),
        .import_stmt, .test_block, .test_suite, .macro_expr, .proc_macro, .quasiquote => .{ .tag = .any },
        .match_expr => |v| inferMatchType(ctx, v.subject, v.arms),
        .range_literal, .slice_literal => .{ .tag = .number },
        .assign_expr, .compound_assign, .decl, .binding, .table_pattern, .ascribed, .type_alias => .{ .tag = .any },
    };
}

fn inferTableType(ctx: anytype, entries: []const ast.TableEntry) TypeInfo {
    var value_type: TypeInfo = .{ .tag = .any };
    var key_type: TypeInfo = .{ .tag = .any };
    var saw_explicit_key = false;
    var saw_implicit_key = false;
    var saw_dynamic = false;
    var fields = std.ArrayList(RecordField).initCapacity(ctx.alloc, entries.len) catch return .{ .tag = .any };
    var array_index: u32 = 0;

    for (entries) |entry| {
        // method defs are record fields with their fn type
        // they carry no value type contribution
        if (entry.key == null and entry.value.expr == .decl and
            entry.value.expr.decl.inner.expr == .binding and
            entry.value.expr.decl.inner.expr.binding.value.expr == .fn_expr)
        {
            const binding = entry.value.expr.decl.inner.expr.binding;
            const method_name = if (binding.target.expr == .ident) binding.target.expr.ident else continue;
            const fn_type = inferExprType(ctx, binding.value);

            fields.append(ctx.alloc, .{ .name = method_name, .field_type = fn_type }) catch return .{ .tag = .any };
            continue;
        }
        const field_type = inferExprType(ctx, entry.value);
        value_type = mergeInferredType(value_type, field_type);
        if (entry.key != null) {
            const inferred_key = inferTableKeyType(ctx, entry);
            key_type = if (saw_explicit_key) mergeInferredType(key_type, inferred_key) else inferred_key;
            saw_explicit_key = true;
            //
            // static `name = v` keys become record fields; dupes replace,
            // last wins like the runtime
            if (ast.staticFieldName(entry)) |name| {
                if (findFieldIndex(fields.items, name)) |i| {
                    fields.items[i].field_type = field_type;
                } else fields.append(ctx.alloc, .{ .name = name, .field_type = field_type }) catch return .{ .tag = .any };
            } else {
                // computed or non-ident keys hide dynamic content
                // so a missing field cant prove absence
                saw_dynamic = true;
            }
        } else {
            // keyless/implicit entries are numeric fields
            const idx_name = std.fmt.allocPrint(ctx.alloc, "{d}", .{array_index}) catch return .{ .tag = .any };
            array_index += 1;
            fields.append(ctx.alloc, .{ .name = idx_name, .field_type = field_type }) catch return .{ .tag = .any };
            saw_implicit_key = true;
        }
    }

    const value_ptr = ctx.alloc.create(TypeInfo) catch return .{ .tag = .any };
    value_ptr.* = value_type;

    // a literal's shape is fully known, even when empty: `{}` carries
    // zero fields so record targets reject it; genuinely unknown shapes
    // (plain `table`, `any`, dynamic keys) keep fields null and stay
    // optimistic
    const known_fields: ?[]RecordField = if (saw_dynamic) null else fields.toOwnedSlice(ctx.alloc) catch return .{ .tag = .any };

    if (!saw_explicit_key and !saw_implicit_key) {
        return makeTable(null, value_ptr, known_fields);
    }

    if (saw_implicit_key) key_type = mergeInferredType(key_type, .{ .tag = .number });
    const key_ptr = ctx.alloc.create(TypeInfo) catch return .{ .tag = .any };
    key_ptr.* = key_type;
    return makeTable(key_ptr, value_ptr, known_fields);
}

fn inferTableKeyType(ctx: anytype, entry: ast.TableEntry) TypeInfo {
    if (ast.staticFieldName(entry)) |_| return .{ .tag = .string };
    if (entry.key) |key| return inferExprType(ctx, key);
    return .{ .tag = .any };
}

fn mergeInferredType(current: TypeInfo, next: TypeInfo) TypeInfo {
    if (current.tag == .any) return next;
    if (next.tag == .any) return current;
    if (current.eql(next)) return current;
    if ((current.tag == .number and next.tag == .number) or (current.tag == .number and next.tag == .number)) return .{ .tag = .number };
    return .{ .tag = .any };
}

pub fn inferIndexType(ctx: anytype, object: *const ast.Node, key: *const ast.Node) TypeInfo {
    if (key.expr == .range_literal or key.expr == .slice_literal) {
        return switch (inferExprType(ctx, object).tag) {
            .string => .{ .tag = .string },
            else => .{ .tag = .any },
        };
    }
    return switch (inferExprType(ctx, object).tag) {
        .string => .{ .tag = .string },
        else => .{ .tag = .any },
    };
}

pub fn inferBlockResultType(ctx: anytype, exprs: []const *ast.Node) TypeInfo {
    if (exprs.len == 0) return .{ .tag = .any };
    return inferExprType(ctx, exprs[exprs.len - 1]);
}

/// walk arg types against param types and bind each type_var found inside a
/// param to the concrete type at the same position, e.g. `self: {:err, T}`
/// against `{:err, string}` binds T -> string. best-effort: first binding per
/// name wins, mismatched shapes are skipped
/// subst is any type with `put(name: []const u8, t: TypeInfo)`
pub fn bindTypeParams(subst: anytype, params: []const TypeInfo, arg_types: []const TypeInfo) anyerror!void {
    const count = @min(params.len, arg_types.len);
    for (0..count) |i| try bindTypeParam(subst, params[i], arg_types[i]);
}

fn bindTypeParam(subst: anytype, param: TypeInfo, arg: TypeInfo) anyerror!void {
    switch (param.tag) {
        .type_var => |name| if (arg.tag != .any) try subst.put(name, arg),
        .table => |tbl| {
            if (arg.tag != .table) return;
            try bindTypeParam(subst, tbl.value.*, arg.tag.table.value.*);
            if (tbl.key) |k| if (arg.tag.table.key) |ak| try bindTypeParam(subst, k.*, ak.*);
            // `{ name: T }` against `{ name: string }` binds T -> string
            if (tbl.fields) |pfs| {
                if (arg.tag.table.fields) |afs| {
                    for (pfs) |pf| {
                        if (findField(afs, pf.name)) |af| try bindTypeParam(subst, pf.field_type, af.field_type);
                    }
                }
            }
        },
        .function => |fsig| {
            if (arg.tag != .function) return;
            try bindTypeParams(subst, fsig.params, arg.tag.function.params);
            try bindTypeParam(subst, fsig.return_type, arg.tag.function.return_type);
        },
        // tagged unions only: match each param variant to the arg variant with
        // the same discriminator atom
        .@"union" => |variants| {
            if (arg.tag != .@"union") return;
            for (variants) |pv| {
                if (pv.types.len == 0 or pv.types[0].tag != .atom) continue;
                for (arg.tag.@"union") |av| {
                    if (av.types.len != pv.types.len) continue;
                    if (av.types[0].tag != .atom or av.types[0].tag.atom.len == 0) continue;
                    if (!std.mem.eql(u8, ast.atomName(pv.types[0].tag.atom), ast.atomName(av.types[0].tag.atom))) continue;
                    for (pv.types[1..], av.types[1..]) |p, a| try bindTypeParam(subst, p, a);
                    break;
                }
            }
        },
        else => {},
    }
}

/// substitute type params in a TypeInfo tree
/// subst is any type with `get(key: []const u8) ?TypeInfo`
pub fn substituteTypeParams(alloc: std.mem.Allocator, ti: TypeInfo, subst: anytype) !TypeInfo {
    return switch (ti.tag) {
        .type_var => |name| subst.get(name) orelse .{ .tag = .any },
        .function => |fsig| blk: {
            const new_params = try alloc.alloc(TypeInfo, fsig.params.len);
            for (fsig.params, new_params) |p, *np| np.* = try substituteTypeParams(alloc, p, subst);
            const new_ret = try substituteTypeParams(alloc, fsig.return_type, subst);
            const new_sig = try newSignature(alloc, .{
                .param_names = fsig.param_names,
                .params = new_params,
                .return_type = new_ret,
                .type_params = fsig.type_params,
            });
            break :blk .{ .tag = .{ .function = new_sig } };
        },
        .table => |tbl| blk: {
            const new_value = try alloc.create(TypeInfo);
            new_value.* = try substituteTypeParams(alloc, tbl.value.*, subst);
            const new_key: ?*TypeInfo = if (tbl.key) |k| blk2: {
                const nk = try alloc.create(TypeInfo);
                nk.* = try substituteTypeParams(alloc, k.*, subst);
                break :blk2 nk;
            } else null;
            const new_fields: ?[]RecordField = if (tbl.fields) |fs| blk2: {
                const owned = try alloc.alloc(RecordField, fs.len);
                for (fs, owned) |f, *dst| dst.* = .{
                    .name = f.name,
                    .field_type = try substituteTypeParams(alloc, f.field_type, subst),
                };
                break :blk2 owned;
            } else null;
            break :blk makeTable(new_key, new_value, new_fields);
        },
        else => ti,
    };
}

test "types: TypeInfo equality" {
    const int_type: revo.lang.compiler.types.TypeInfo = .{ .tag = .number };
    const any_type: revo.lang.compiler.types.TypeInfo = .{ .tag = .any };

    try std.testing.expect(int_type.eql(.{ .tag = .number }));
    try std.testing.expect(int_type.eql(.{ .tag = .number }));
    try std.testing.expect(any_type.eql(.{ .tag = .any }));
}

test "types: numeric type check" {
    try std.testing.expect(.{ .tag = .number }.tag == .number);
    try std.testing.expect(.{ .tag = .string }.tag != .number);
    try std.testing.expect(.{ .tag = .any }.tag != .number);
}

test "types: type coercion" {
    const types = revo.lang.compiler.types;
    try std.testing.expect(types.canCoerce(.{ .tag = .number }, .{ .tag = .number }));
    try std.testing.expect(!types.canCoerce(.{ .tag = .string }, .{ .tag = .number }));
    try std.testing.expect(types.canCoerce(.{ .tag = .number }, .{ .tag = .any })); // anything to any
    try std.testing.expect(types.canCoerce(.{ .tag = .any }, .{ .tag = .number })); // any to anything (optimistic)
}

test "types: binary op inference - arithmetic" {
    const types = revo.lang.compiler.types;
    const add_int_int = types.inferBinaryOp(.add, .{ .tag = .number }, .{ .tag = .number });
    try std.testing.expect(add_int_int.eql(.{ .tag = .number }));

    const add_float_float = types.inferBinaryOp(.add, .{ .tag = .number }, .{ .tag = .number });
    try std.testing.expect(add_float_float.eql(.{ .tag = .number }));

    const add_int_float = types.inferBinaryOp(.add, .{ .tag = .number }, .{ .tag = .number });
    try std.testing.expect(add_int_float.eql(.{ .tag = .number }));
}

test "types: binary op inference - comparison" {
    const types = revo.lang.compiler.types;
    const cmp = types.inferBinaryOp(.eq, .{ .tag = .number }, .{ .tag = .number });
    try std.testing.expect(cmp.eql(.{ .tag = .bool }));

    const cmp2 = types.inferBinaryOp(.lt, .{ .tag = .number }, .{ .tag = .number });
    try std.testing.expect(cmp2.eql(.{ .tag = .bool }));
}

test "types: empty atom sentinel coercion" {
    const types = revo.lang.compiler.types;
    const empty_atom: types.TypeInfo = .{ .tag = .{ .atom = "" } };
    const named_atom: types.TypeInfo = .{ .tag = .{ .atom = ":foo" } };
    try std.testing.expect(types.canCoerce(empty_atom, named_atom));
    try std.testing.expect(types.canCoerce(named_atom, empty_atom));
    try std.testing.expect(types.canCoerce(empty_atom, empty_atom));
}

test "types: unary op inference" {
    const types = revo.lang.compiler.types;
    const negate_int = types.inferUnaryOp(.negate, .{ .tag = .number });
    try std.testing.expect(negate_int.eql(.{ .tag = .number }));

    const not_bool = types.inferUnaryOp(.not, .{ .tag = .bool });
    try std.testing.expect(not_bool.eql(.{ .tag = .bool }));
}

//
// type system
//
const lang = revo.lang;
const t = lang.testing;
const VM = revo.VM;

test "typed binding num accepts int literal" {
    try t.topNumber(
        \\ let x: num = 42
        \\ x
    , 42);
}

test "typed binding num accepts float literal" {
    try t.topNumber(
        \\ let x: num = 3.14
        \\ x
    , 3.14);
}

test "typed binding num accepts num literal coerced to num" {
    try t.topNumber(
        \\ let x: num = 10
        \\ x
    , 10.0);
}

test "typed binding rejects string for num" {
    try t.expectCompileError(
        \\ let x: num = "hello"
    , .ParseError);
}

test "typed binding num accepts float literal as num" {
    try t.topNumber(
        \\ let x: num = 3.14
        \\ x
    , 3.14);
}

test "typed binding rejects num for string" {
    try t.expectCompileError(
        \\ let x: string = 42
    , .ParseError);
}

test "typed binding table<num> accepts positional table literal" {
    try t.topNumber(
        \\ let nums: table<num> = { 1, 2, 3 }
        \\ 1
    , 1);
}

test "typed binding table<string, num> accepts keyed table literal" {
    try t.topNumber(
        \\ let pairs: table<string, num> = { a = 1, b = 2 }
        \\ 1
    , 1);
}

test "record annotation accepts matching literal" {
    try t.topNumber(
        \\ let u: { name: string, age: num } = { name = "alice", age = 30 }
        \\ u.age
    , 30);
}

test "record rejects missing field" {
    try t.expectCompileError(
        \\ let u: { name: string, age: num } = { name = "alice" }
    , .ParseError);
}

test "record rejects wrong field type" {
    try t.expectCompileError(
        \\ let u: { name: string } = { name = 42 }
    , .ParseError);
}

test "record allows extra fields" {
    try t.topString(
        \\ let u: { name: string } = { name = "alice", age = 30 }
        \\ u.name
    , "alice");
}

test "record field access infers precise type" {
    try t.topNumber(
        \\ let u: { name: string, age: num } = { name = "alice", age = 30 }
        \\ u.age + 12
    , 42);
}

test "record field flows into typed binding" {
    try t.expectCompileError(
        \\ let u: { name: string } = { name = "alice" }
        \\ let x: num = u.name
    , .ParseError);
}

test "record fn param accepts table with extra fields" {
    try t.topString(
        \\ fn greet(u: { name: string }) u.name
        \\ greet({ name = "bob", age = 40 })
    , "bob");
}

test "record fn param rejects missing field" {
    try t.expectCompileError(
        \\ fn greet(u: { name: string, age: num }) u.name
        \\ greet({ name = "bob" })
    , .ParseError);
}

test "record alias works in bindings" {
    try t.topNumber(
        \\ type User = { name: string, age: num }
        \\ let u: User = { name = "alice", age = 30 }
        \\ u.age
    , 30);
}

test "nested records check inner fields" {
    try t.topString(
        \\ let t: { user: { name: string } } = { user = { name = "alice" } }
        \\ t.user.name
    , "alice");
}

test "nested record rejects bad inner field" {
    try t.expectCompileError(
        \\ let t: { user: { name: string } } = { user = { name = 42 } }
    , .ParseError);
}

test "empty record accepts any table" {
    try t.topNumber(
        \\ let u: {} = { a = 1 }
        \\ 1
    , 1);
}

test "record rejects empty literal" {
    try t.expectCompileError(
        \\ let a: { name: num } = {}
    , .ParseError);
}

test "record rejects array literal" {
    try t.expectCompileError(
        \\ let a: { name: num } = { 1, 2, 3 }
    , .ParseError);
}

test "positional record accepts matching literal" {
    try t.topNumber(
        \\ let t0: {number, number} = {1, 2}
        \\ 1
    , 1);
}

test "positional record rejects wrong field type" {
    try t.expectCompileError(
        \\ let a: {number, string} = {1, 2}
    , .ParseError);
}

test "mixed record accepts matching literal" {
    try t.topString(
        \\ let t1: {number, number, name: string} = {1, 2, name = "me"}
        \\ t1.name
    , "me");
}

test "mixed record rejects missing named field" {
    try t.expectCompileError(
        \\ let t1: {number, number, name: string} = {1, 2}
    , .ParseError);
}

test "positional atom record accepts literal and any atom" {
    try t.topAtom(
        \\ let tb: {number, number, :err, atom} = {1, 2, :err, :NotFound}
        \\ :NotFound
    , "NotFound");
}

test "fn alias enforces arity at call sites" {
    try t.expectCompileError(
        \\ type F = fn(num, num) -> num
        \\ fn apply(f: F) f(1)
    , .ParseError);
}

test "unknown table field read is an error" {
    try t.expectCompileError(
        \\ let t = { name = "me" }
        \\ t.a
    , .ParseError);
}

test "unknown table field index read is an error" {
    try t.expectCompileError(
        \\ let t = { name = "me" }
        \\ t[:a]
    , .ParseError);
    try t.expectCompileError(
        \\ let t = { name = "me" }
        \\ t["a"]
    , .ParseError);
}

test "assigned and dynamic fields are not flagged" {
    // static assign extends the known shape
    try t.topNumber(
        \\ let t = {}
        \\ t.a = 41
        \\ t.a
    , 41);
    // dynamic keys make the shape unknown: optimistic, no error
    try t.topNumber(
        \\ const k = "a"
        \\ const t = {}
        \\ t[k] = 41
        \\ t[k]
    , 41);
    // mutations through closures escape analysis: optimistic, no error
    try t.topNumber(
        \\ const out = {}
        \\ const f = fn(k) out[k] = 1
        \\ f("a")
        \\ out["a"]
    , 1);
    // foreign tables have unknown shapes: optimistic, no error
    try t.topNumber(
        \\ fn f(t: table) t.a
        \\ f({a = 41})
    , 41);
}

test "typed function params accept correct types" {
    try t.topNumber(
        \\ const add = fn(a: num, b: num) a + b
        \\ add(3, 4)
    , 7);
}

test "typed function rejects wrong arg type" {
    try t.expectCompileError(
        \\ const add = fn(a: num, b: num) a + b
        \\ add(3, "wrong")
    , .ParseError);
}

test "typed function rejects first arg wrong type" {
    try t.expectCompileError(
        \\ const add = fn(a: num, b: num) a + b
        \\ add("wrong", 4)
    , .ParseError);
}

test "atom union alias accepts literal and alias value in calls" {
    try t.topAtom(
        \\ type A = :one | :two
        \\ fn pick(how: A) -> any do
        \\   how
        \\ end
        \\ let pred: A = :one
        \\ pick(pred)
    , "one");

    try t.topAtom(
        \\ type A = :one | :two
        \\ fn pick(how: A) -> any do
        \\   how
        \\ end
        \\ let pred: A = :one
        \\ pick(:two)
    , "two");
}

test "binary num + num emits add" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let a: num = 5
        \\ let b: num = 3
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

test "binary float literal + float emits add" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let a: num = 1.5
        \\ let b: num = 2.5
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

test "negate num emits negate" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let x: num = 5
        \\ let y = -x
        \\ y
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_neg = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .negate) saw_neg = true;
    }
    try std.testing.expect(saw_neg);
}

test "comparison num == num emits eq_int" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let a: num = 5
        \\ let b: num = 5
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
    try t.topNumber("1 + 2 * 3", 7);
    try t.topNumber(
        \\ let x = 10
        \\ x + 5
    , 15);
    try t.topString(
        \\ let s = "hello"
        \\ s
    , "hello");
}

test "mixed num and num falls back to generic add" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let a: num = 5
        \\ let b: num = 2.5
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
    try t.topNumber(
        \\ const outer = fn(x: num) do
        \\     const inner = fn(y: num) y * 2
        \\     inner(x) + 1
        \\ end
        \\ outer(5)
    , 11);
}

test "function call with multiple typed params" {
    try t.topNumber(
        \\ const calc = fn(a: num, b: num, c: num) do
        \\     a + b + c
        \\ end
        \\ calc(1, 2.5, 3)
    , 6.5);
}

test "return type validation accepts correct type" {
    try t.topNumber(
        \\ const get_num = fn() -> num do
        \\     return 42
        \\ end
        \\ get_num()
    , 42);
}

test "atoms<->any relationship" {
    try t.topNumber(
        \\ const get_num = fn() -> num do
        \\     return 42
        \\ end
        \\ get_num()
    , 42);
}

//
// typed const bindings
//
test "typed const binding num int" {
    try t.topNumber(
        \\ const x: num = 42
        \\ x
    , 42);
}

test "typed const binding string" {
    try t.topString(
        \\ const s: string = "hello"
        \\ s
    , "hello");
}

test "typed const binding num float" {
    try t.topNumber(
        \\ const x: num = 3.14
        \\ x
    , 3.14);
}

test "typed const binding rejects wrong type" {
    try t.expectCompileError(
        \\ const x: num = "hello"
    , .ParseError);
}

//
// typed global bindings
//
test "typed global binding num int" {
    try t.topNumber(
        \\ global x: num = 42
        \\ x
    , 42);
}

test "typed global binding num float" {
    try t.topNumber(
        \\ global x: num = 1.5
        \\ x
    , 1.5);
}

//
// type alias at call sites
//
test "type alias used in function param" {
    try t.topNumber(
        \\ type MyInt = num
        \\ const double = fn(x: MyInt) -> MyInt x * 2
        \\ double(21)
    , 42);
}

test "type alias used in binding" {
    try t.topString(
        \\ type Name = string
        \\ let s: Name = "alice"
        \\ s
    , "alice");
}

test "type alias num accepts num" {
    try t.topNumber(
        \\ type Num = num
        \\ const add = fn(a: Num, b: Num) -> num a + b
        \\ add(3, 4)
    , 7);
}

test "type alias num accepts float literal" {
    try t.topNumber(
        \\ type Num = num
        \\ const add = fn(a: Num, b: Num) -> num a + b
        \\ add(3.5, 4.2)
    , 7.7);
}

test "type alias rejects type not in union" {
    try t.expectCompileError(
        \\ type MyInt = num
        \\ const x: MyInt = "string"
    , .ParseError);
}

//
// named union variants with payloads
//
test "named union variant ok result" {
    try t.topAtom(
        \\ type Result = :ok | :err
        \\ match 0
        \\ | 0 => :ok
        \\ | _ => :err
    , "ok");
}

test "named union variant err result" {
    try t.topAtom(
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
        \\ fn get() -> num do
        \\     return "hello"
        \\ end
    , .ParseError);
}

test "coercion in return type num to num" {
    try t.topNumber(
        \\ fn get() -> num do
        \\     return 42
        \\ end
        \\ get()
    , 42);
}

test "explicit return matches return type" {
    try t.topNumber(
        \\ fn get() -> num do
        \\     return 99
        \\ end
        \\ get()
    , 99);
}

//
// if/else branch type unification
//
test "if/else typed branches unify to num" {
    try t.topNumber(
        \\ let x: num = 5
        \\ let y = if x > 0 10 else 20
        \\ y
    , 10);
}

test "if/else typed branches unify to string" {
    try t.topString(
        \\ let x: num = 0
        \\ let y = if x > 0 "pos" else "non-pos"
        \\ y
    , "non-pos");
}

//
// string indexing
//
test "string indexing returns string" {
    try t.topString(
        \\ let s: string = "hello"
        \\ s[0]
    , "h");
}

test "string slicing uses half-open range bounds" {
    try t.topString(
        \\ let s: string = "hello"
        \\ s[1..4]
    , "ell");
}

test "stepped string slicing" {
    try t.topString(
        \\ let s: string = "abcdef"
        \\ s[5..-1..1]
    , "fedc");
}
//
// open-bound slicing
//
test "string slice open start [..n]" {
    try t.topString(
        \\ let s: string = "hello"
        \\ s[..4]
    , "hell");
}

test "string slice open end [n..]" {
    try t.topString(
        \\ let s: string = "hello"
        \\ s[2..]
    , "llo");
}

test "string slice open both [..]" {
    try t.topString(
        \\ let s: string = "hello"
        \\ s[..]
    , "hello");
}
test "string slice open step [n..step..m]" {
    try t.topString(
        \\ let s: string = "abcdef"
        \\ s[0..2..5]
    , "ace");
}
test "string slice empty result" {
    try t.topString(
        \\ let s: string = "abc"
        \\ s[2..2]
    , "");
}
//
// any type accepts everything
//
test "any typed param accepts num" {
    try t.topNumber(
        \\ const id = fn(x: any) x
        \\ id(42)
    , 42);
}

test "any typed param accepts string" {
    try t.topString(
        \\ const id = fn(x: any) x
        \\ id("hello")
    , "hello");
}

test "any typed param accepts table" {
    try t.topNumber(
        \\ const get = fn(t: any, k: any) t[k]
        \\ get({x = 99}, :x)
    , 99);
}

test "any typed binding accepts anything" {
    try t.topNumber(
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
    try t.topNumber(
        \\ let x: num = do
        \\     let a = 1
        \\     let b = 2
        \\     a + b
        \\ end
        \\ x
    , 3);
}

test "block type error on type mismatch" {
    try t.expectCompileError(
        \\ let x: num = do
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
        \\ let a: num = 1
        \\ let b: num = 2
        \\ let c: num = 3
        \\ a + b * c
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add = false;
    var saw_mul = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add) saw_add = true;
        if (inst.op == .mul) saw_mul = true;
    }
    try std.testing.expect(saw_add);
    try std.testing.expect(saw_mul);
}

//
// type alias union with multiple atom variants
//
test "multi-atom union alias in match" {
    try t.topAtom(
        \\ type Color = :red | :green | :blue
        \\ match :red
        \\ | :red => :green
        \\ | :green => :red
        \\ | _ => :blue
    , "green");
}

test "multi-atom union fn param accepts valid atom" {
    try t.topAtom(
        \\ type Color = :red | :green
        \\ fn pick(c: Color) c
        \\ pick(:green)
    , "green");
}

//
// void / nil type
//
test "nil typed fn body" {
    try t.topNil(
        \\ fn nothing() do :nil end
        \\ nothing()
    );
}

test "typed binding with void returns nil" {
    try t.topNil(
        \\ let x: any = :nil
        \\ x
    );
}

test "global typed binding rejects type mismatch" {
    try t.expectCompileError(
        \\ const x: num = "hello"
    , .ParseError);
}

test "global typed binding accepts matching type" {
    try t.topNumber(
        \\ const x: num = 42
        \\ x
    , 42);
}

test "typed assignment rejects type mismatch" {
    try t.expectCompileError(
        \\ let x: num = 5
        \\ x = "hello"
    , .ParseError);
}

test "untyped assignment allows type change" {
    try t.topString(
        \\ let x = 5
        \\ x = "hello"
        \\ x
    , "hello");
}

//
// bool type
//
test "bool typed binding" {
    try t.topTrue(
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
    try t.topFalse(
        \\ let b: bool = not (1 == 1)
        \\ b
    );
}

test "implicit return validates block-local variable type" {
    try t.expectCompileError(
        \\ fn f() -> num do
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
        \\     let x: num = 5
        \\     const inner = fn() do x = "hello" end
        \\ end
    , .ParseError);
}

test "dynamic callee validates argument types" {
    try t.expectCompileError(
        \\ const f: function = fn(x: num) x
        \\ f("hello")
    , .ParseError);
}
test "for loop expression produces loop atom" {
    try t.topAtom(
        \\ fn f() do
        \\   for i in 0..5 do i end
        \\ end
        \\ f()
    , "loop");
    try t.topNumber(
        \\ fn f() -> num do
        \\   for/l i in 0..5 do
        \\     if i == 4 break/l(i)
        \\   end
        \\ end
        \\ f()
    , 4);
}

test "type alias gets unaliased" {
    try t.topTrue(
        \\ type Als =
        \\       {:aa, num}
        \\     | {:bb, num}
        \\
        \\ let x: Als = {:aa, 55}
        \\ let y: Als = {:bb, 100.1}
        \\
        \\ x[1] + y[1] == 155.1
    );
}
test "comp block infers num from literal" {
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

    var saw_add_imm = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_imm) saw_add_imm = true;
    }
    try std.testing.expect(saw_add_imm);
}

test "never collapses in if and orelse inference" {
    // `panic` is `never`: a branch that diverges contributes no type
    try std.testing.expectEqual(TypeInfo{ .tag = .number }, inferIfType(.{ .tag = .never }, .{ .tag = .number }));
    try std.testing.expectEqual(TypeInfo{ .tag = .number }, inferIfType(.{ .tag = .number }, .{ .tag = .never }));
    try std.testing.expectEqual(TypeInfo{ .tag = .never }, inferIfType(.{ .tag = .never }, .{ .tag = .never }));
    try std.testing.expectEqual(TypeInfo{ .tag = .number }, inferOrelseType(.{ .tag = .never }, .{ .tag = .number }));
    try std.testing.expectEqual(TypeInfo{ .tag = .number }, inferOrelseType(.{ .tag = .number }, .{ .tag = .never }));
    // unknown left stays unknown: the value may be anything or diverge
    try std.testing.expectEqual(TypeInfo{ .tag = .any }, inferOrelseType(.{ .tag = .any }, .{ .tag = .never }));
}

test "never arms don't poison match result type" {
    // the panic arm is `never`: the match result is the `:ok` payload (num),
    // so `?` on it is rejected as a non-result (it would pass as `.any`)
    try t.expectCompileError(
        \\ type Res = {:ok, num} | {:err, string}
        \\ let x: Res = {:ok, 42}
        \\ let r = match x
        \\ | {:ok, v} => v
        \\ | {:err, e} => panic(e)
        \\ r?
    , .ParseError);
}

test "match narrowing works for call subjects" {
    // the subject is a call, not an ident: `v` still narrows to the payload
    // type (from the fn's declared return) and `v + 1` emits add_imm
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ type Res = {:ok, num} | {:err, string}
        \\ fn g() -> Res do {:ok, 42} end
        \\ match g()
        \\ | {:ok, v} => v + 1
        \\ | {:err, _} => 0
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_imm = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_imm) saw_add_imm = true;
    }
    try std.testing.expect(saw_add_imm);
}

test "match narrowing enables specialized add_imm from table union payload" {
    // `v` narrows to num so `v + 1` emits add_imm
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ type Res = {:ok, num} | {:err, string}
        \\ let x: Res = {:ok, 42}
        \\ match x
        \\ | {:ok, v} => v + 1
        \\ | {:err, _} => 0
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_imm = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_imm) saw_add_imm = true;
    }
    try std.testing.expect(saw_add_imm);
}

test "match ascriptions narrow to the annotated type" {
    // `v: num` narrows even with an `any` subject
    //   ; so `v + 1` emits add_imm
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let x: any = {41}
        \\ match x
        \\ | {v: num} => v + 1
        \\ | _ => 0
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_imm = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_imm) saw_add_imm = true;
    }
    try std.testing.expect(saw_add_imm);
}

test "return type propagation: const binding with annotated fn" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ const add = fn(a: num, b: num) a + b
        \\ let x = add(3, 4)
        \\ x + 1
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_imm = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_imm) saw_add_imm = true;
    }
    try std.testing.expect(saw_add_imm);
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

    var saw_add_imm = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_imm) saw_add_imm = true;
    }
    try std.testing.expect(saw_add_imm);
}

test "annotated function return type propagates to caller via pointer" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn add(a: num, b: num) a + b
        \\ let x = add(3, 4)
        \\ x + 1
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_imm = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_imm) saw_add_imm = true;
    }
    try std.testing.expect(saw_add_imm);
}

//
// generics / type_var tests
//

fn testRuntime() revo.Runtime {
    return .{
        .alloc = std.testing.allocator,
        .io = std.testing.io,
        .diag_alloc = std.testing.allocator,
        .diag_arena = null,
    };
}

test "types: type_var equality" {
    const TI = revo.lang.compiler.types.TypeInfo;
    const a = TI{ .tag = .{ .type_var = "T" } };
    const b = TI{ .tag = .{ .type_var = "T" } };
    const c = TI{ .tag = .{ .type_var = "U" } };
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
    try std.testing.expect(!a.eql(.{ .tag = .number }));
}

test "types: type_var coercion" {
    const types = revo.lang.compiler.types;
    const tv = types.TypeInfo{ .tag = .{ .type_var = "T" } };
    try std.testing.expect(types.canCoerce(tv, .{ .tag = .number }));
    try std.testing.expect(types.canCoerce(.{ .tag = .number }, tv));
    try std.testing.expect(types.canCoerce(tv, .{ .tag = .any }));
    try std.testing.expect(types.canCoerce(.{ .tag = .any }, tv));
    try std.testing.expect(types.canCoerce(tv, tv));
}

test "substituteTypeParams direct type var" {
    const types = revo.lang.compiler.types;
    const alloc = std.testing.allocator;
    var subst = std.StringHashMap(types.TypeInfo).init(alloc);
    defer subst.deinit();
    try subst.put("T", .{ .tag = .number });

    const result = try types.substituteTypeParams(alloc, types.TypeInfo{ .tag = .{ .type_var = "T" } }, subst);
    try std.testing.expect(result.eql(.{ .tag = .number }));
}

test "substituteTypeParams unknown type var becomes any" {
    const types = revo.lang.compiler.types;
    const alloc = std.testing.allocator;
    var subst = std.StringHashMap(types.TypeInfo).init(alloc);
    defer subst.deinit();

    const result = try types.substituteTypeParams(alloc, types.TypeInfo{ .tag = .{ .type_var = "T" } }, subst);
    try std.testing.expect(result.eql(.{ .tag = .any }));
}

test "substituteTypeParams function sig with type var" {
    const types = revo.lang.compiler.types;
    const alloc = std.testing.allocator;
    var subst = std.StringHashMap(types.TypeInfo).init(alloc);
    defer subst.deinit();
    try subst.put("T", .{ .tag = .number });

    const sig = try alloc.create(types.FunctionSignature);
    sig.* = .{
        .params = &.{types.TypeInfo{ .tag = .{ .type_var = "T" } }},
        .return_type = types.TypeInfo{ .tag = .{ .type_var = "T" } },
        .param_names = &.{"x"},
    };
    const input = types.TypeInfo{ .tag = .{ .function = sig } };
    const result = try types.substituteTypeParams(alloc, input, subst);
    try std.testing.expect(result.tag == .function);
    try std.testing.expect(result.tag.function.params.len == 1);
    try std.testing.expect(result.tag.function.params[0].eql(.{ .tag = .number }));
    try std.testing.expect(result.tag.function.return_type.eql(.{ .tag = .number }));
    alloc.destroy(sig);
    alloc.free(result.tag.function.params);
    alloc.destroy(result.tag.function);
}

test "generics identity fn enables add_imm" {
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

    var saw_add_imm = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_imm) saw_add_imm = true;
    }
    try std.testing.expect(saw_add_imm);
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

test "generics compound return type {:ok, T} propagates inner type" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn wrap[T](x: T) -> {:ok, T} {:ok, x}
        \\ let r = wrap(42)
        \\ r[1] + 1
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);
}

test "generics multiple type params with table return compile" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn pair[T, U](a: T, b: U) -> {T, U}
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

    var saw_add_imm = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_imm) saw_add_imm = true;
    }
    try std.testing.expect(saw_add_imm);
}

test "explicit call-site type args make[num]() resolves return type" {
    try t.topNumber(
        \\ fn make[T]() -> T 5
        \\ make[num]()
    , 5);
}

test "explicit call-site type args id[num](42) resolves return type" {
    try t.topNumber(
        \\ fn id[T](x: T) -> T x
        \\ id[num](42)
    , 42);
}

//
// stdlib signatures flow from the semantic checker through the
// annotation bridge into the compiler
//

test "stdlib sigs: method return types reach the compiler" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ "abc":len() + 1
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_imm = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_imm) saw_add_imm = true;
    }
    try std.testing.expect(saw_add_imm);
}

test "stdlib sigs: global return types reach the compiler" {
    // semantic knows cwd/read from the os iface; misuse that compiled
    // against .any now errors before codegen
    try t.expectCompileError(
        \\ let x = cwd()
        \\ let n: num = x
    , .ParseError);
    try t.expectCompileError(
        \\ let x = read({delimiter = :eof})
        \\ let n: num = x?
    , .ParseError);
}

test "stdlib sigs source fn shadows stdlib global" {
    try t.topNumber(
        \\ const cwd = fn(x: num) x + 1
        \\ cwd(41)
    , 42);
    try t.expectCompileError(
        \\ const cwd = fn(x: num) x + 1
        \\ cwd("nope")
    , .ParseError);
}

test "stdlib sigs variadic global keeps accepting extra args" {
    try t.topString("fmt(\"%v\", 1, 2, 3)", "1");
    try t.expectCompileError(
        \\ fmt()
    , .ParseError);
}

test "stdlib sigs untyped call still validates arg count" {
    try t.expectCompileError(
        \\ cwd("nope", "more")
    , .ParseError);
}

test "stdlib sigs: module field calls resolve to spec sigs" {
    try t.topAtom("fs.exists?(\"/definitely/not/a/real/path_xyz\")", "false");
    try t.topNumber(
        \\ table.len({1, 2}) + 1
    , 3);
    try t.topTrue("let b: bool = fs.exists?(\"/tmp\")");
}

test "stdlib sigs: module result flows through match" {
    try t.topAtom(
        \\ let r = fs.open("/definitely/not/a/real/path_xyz")
        \\ match r | {:ok, f} => :found | {:err, e} => e
    , "FileNotFound");
}

test "stdlib sigs: local binding shadows stdlib module" {
    // `fs` here is a local table, not the module
    // no stdlib sig is applied, and the missing field fails at compile time
    // (it can never work, so no point waiting for runtime)
    // so this is EXACTLY what we want. it gets erased
    try t.expectCompileError(
        \\ let fs = {}
        \\ fs.exists?("/tmp")
    , .ParseError);
}
test "stdlib sigs: orelse unwraps results" {
    try t.topTrue("fs.exists?(\"/tmp\")");
    try t.topNumber("{:err, \"boom\"} orelse 5", 5);
}

test "stdlib sigs: try rejects non-result unions" {
    // `?` on it is a lie
    try t.expectCompileError(
        \\ "abc":find("b")?
    , .ParseError);
}

test "stdlib sigs: match narrows call-subject payloads" {
    // the subject is a call, not an ident: the payload still narrows to
    // bool, so the match result is bool (not a result) and `?` is rejected
    try t.expectCompileError(
        \\ (match fs.open("/tmp")
        \\ | {:ok, v} => v
        \\ | {:err, e} => panic(e))?
    , .ParseError);
}

test "eu.rv: result types flow end to end" {
    // the predicate binds as bool, while result calls still bind as !T
    // and flow through match on both arms
    try t.topTrue(
        \\ let x: bool = fs.exists?("/tmp")
        \\ x
    );
    try t.topAtom(
        \\ let r = fs.open("/definitely/not/a/real/path_xyz")
        \\ match r | {:err, e} => e | _ => :found
    , "FileNotFound");
    try t.topAtom(
        \\ let x: {:ok, table} | {:err, any} = fs.open("/tmp")
        \\ match x | {:ok, t} => :found | {:err, e} => e
    , "found");
}

test "error-union sugar and the literal form are the same union" {
    // `!table` and `{:ok, table} | {:err, any}` are structurally identical, so
    // a value typed with one can be bound to a slot typed with the other
    try t.topAtom(
        \\ let x: {:ok, table} | {:err, any} = {:ok, {}}
        \\ let y: !table = x
        \\ match y | {:ok, t} => :found | {:err, e} => e
    , "found");
}

//
// ambient declares
//

test "declare typed const is usable in type positions" {
    try t.topNumber(
        \\ declare MAX_ITEMS = num
        \\ const x: MAX_ITEMS = 5
        \\ x
    , 5);
}

test "declare fn calls typecheck and run into undefined variable" {
    try t.expectRuntimeError(
        \\ declare lamp = fn(volume: num, label: string) -> bool
        \\ lamp(1, "x")
    , .UndefinedVariable);
}

test "declare fn return type reaches the compiler" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ declare add = fn(a: num, b: num) -> num
        \\ add(1, 2) + 1
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_imm = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_imm) saw_add_imm = true;
    }
    try std.testing.expect(saw_add_imm);
}

test "declare rejects duplicate names" {
    try t.expectCompileError(
        \\ declare MAX_ITEMS = num
        \\ declare MAX_ITEMS = num
    , .ParseError);
}

test "declare rejects non-top-level placement" {
    try t.expectCompileError(
        \\ fn f() do
        \\     declare y = num
        \\ end
    , .ParseError);
}

test "dotted pub type resolves bare in the same file" {
    try t.topNumber(
        \\ pub type geo.Port = num
        \\ const p: Port = 8080
        \\ p
    , 8080);
}

test "dotted pub type in .d.rv resolves qualified by import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "shapes.d.rv",
        .data = "pub type geo.Point = num\n",
    });
    const module_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(module_dir);
    try t.topNumberInDir(
        module_dir,
        "import \"shapes.d.rv\"\nconst p: shapes.Point = 7\np\n",
        7,
    );
    try t.expectCompileErrorInDir(
        module_dir,
        "import \"shapes.d.rv\"\nconst p: shapes.Point = \"x\"\n",
    );
}

test "manifest dotted macros rescope under the import name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "m.d.rv",
        .data =
        \\pub macro q.shout! `(%w:expr)` `%w`
        \\pub proc q.add3!(iter) do
        \\  let a = iter:next()
        \\  let b = iter:next()
        \\  let c = iter:next()
        \\  {{:binary, :add, {:binary, :add, a, b}, c}}
        \\end
        ,
    });
    const module_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(module_dir);
    try t.topNumberInDir(
        module_dir,
        "import \"m.d.rv\"\nm.shout!(40) + m.add3!(10, 20, 10)\n",
        80,
    );
}

test "stdlib dotted type resolves qualified, unknown qualified errors" {
    try t.topNumber(
        \\ const u: uri.Hi = {n = "x"}
        \\ 1
    , 1);
    try t.expectCompileError(
        \\ const u: uri.Hi = 2
    , .ParseError);
    try t.expectCompileError(
        \\ const u: uri.Bogus = 1
    , .ParseError);
}

test ".d.rv import typechecks calls and never executes the file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "audio.d.rv",
        .data = "pub declare ring = fn(volume: num, label: string) -> bool\nundefined_poison()\n",
    });
    const module_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(module_dir);
    // build succeeds (semantic extracted the sig); runtime only fails on the
    // empty module table - the poison call inside the file never ran
    try t.expectRuntimeErrorInDir(
        module_dir,
        "import \"audio.d.rv\"\naudio.ring(1, \"x\")\n",
        .NotAFunction,
    );
}

test "manifest .d.rv types .so imports, sig fallback without one" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fake.so", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fake.d.rv", .data = "pub declare open = fn(path: string) -> string\n" });
    const module_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(module_dir);
    const source_name = try std.fs.path.join(std.testing.allocator, &.{ module_dir, "<source>" });
    defer std.testing.allocator.free(source_name);

    const source = "import \"fake.so\"\nfake.open(5)\n";

    // manifest present: the wrong-arg call is a compile error
    {
        var vm = try VM.init(t.runtime());
        defer vm.deinit();
        vm.module_dir = module_dir;
        const result = try lang.build(&vm, .{ .name = source_name, .text = source }, .{ .install_debug_info = false });
        switch (result) {
            .ok => return error.ExpectedCompileFailure,
            .err => |f| switch (f) {
                .semantic, .lower => vm.runtime.resetDiagArena(),
                .expand, .parse => return error.ExpectedCompileFailure,
            },
        }
    }

    // manifest gone: no sigs to synthesize from, the call compiles untyped
    try tmp.dir.deleteFile(std.testing.io, "fake.d.rv");
    {
        var vm = try VM.init(t.runtime());
        defer vm.deinit();
        vm.module_dir = module_dir;
        const result = try lang.build(&vm, .{ .name = source_name, .text = source }, .{ .install_debug_info = false });
        switch (result) {
            .ok => |artifact| {
                std.testing.allocator.free(artifact.instructions);
                std.testing.allocator.free(artifact.spans);
            },
            .err => return error.ExpectedCompileSuccess,
        }
    }
}

//
// unless/else branch type unification
//
test "unless/else typed branches unify to num" {
    try t.topNumber(
        \\ let x: num = 5
        \\ let y = unless x > 0 10 else 20
        \\ y
    , 20);
}

test "unless/else typed branches unify to string" {
    try t.topString(
        \\ let x: num = 0
        \\ let y = unless x > 0 "pos" else "non-pos"
        \\ y
    , "pos");
}
