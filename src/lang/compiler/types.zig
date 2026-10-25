const cst = @import("../cst.zig");
const std = @import("std");

pub const UnionVariant = struct {
    name: []const u8,
    types: []const TypeInfo,
};

/// one named field of a structural table type: `{ name: string }`
/// `?name:` fields may be absent from the value
pub const RecordField = struct {
    name: []const u8,
    field_type: TypeInfo,
    optional: bool = false,
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
        bool, // todo: remove, make this be atom union of :true | :false
        number,
        string,
        resource,
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
            .resource => other.tag == .resource,
            .string => other.tag == .string,
            .atom => |a| if (other.tag == .atom) std.mem.eql(u8, cst.atomName(a), cst.atomName(other.tag.atom)) else false,
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
                        if (f.optional != of.optional) break :blk false;
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
    default_values: []const ?*const cst.CstNode = &.{},
    doc: ?[]const u8 = null,
};

/// resolved pieces for one FunctionSignature; every builder (compiler
/// allocFnSig, semantic make/newSig, type_syntax eval) walks its own cst
/// because error handling differs, then funnels through here
pub const SignatureParts = struct {
    param_names: []const []const u8,
    params: []const TypeInfo,
    return_type: TypeInfo = .{ .tag = .any },
    required_count: usize = 0,
    type_params: []const []const u8 = &.{},
    default_values: []const ?*const cst.CstNode = &.{},
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

///
/// unannotated params act as implicit generics
///
/// `fn v2_new(x, y)` behaves like `fn v2_new<x, y>(x: x, y: y)`
/// so `{ x = x }` infers `{ x: x }`
/// and call sites substitute concrete arg types. `_` stays `any`
///
pub fn combinedTypeParams(
    alloc: std.mem.Allocator,
    explicit: []const []const u8,
    params: []const cst.CstParam,
) std.mem.Allocator.Error![]const []const u8 {
    var extra: usize = 0;

    for (params, 0..) |p, pi| {
        const pname = p.name_tok.text;
        if (p.type != null) continue;
        if (cst.isDiscardName(pname)) continue;
        var found = false;

        for (explicit) |e| if (std.mem.eql(u8, e, pname)) {
            found = true;
            break;
        };

        if (!found) for (params[0..pi]) |prev| {
            if (prev.type != null) continue;

            if (std.mem.eql(u8, prev.name_tok.text, pname)) {
                found = true;
                break;
            }
        };

        if (!found) extra += 1;
    }
    if (extra == 0) return explicit;

    // dedup repeated param names: first wins, mirroring bindTypeParams
    var out = try alloc.alloc([]const u8, explicit.len + extra);
    @memcpy(out[0..explicit.len], explicit);
    var idx: usize = explicit.len;

    for (params) |p| {
        const pname = p.name_tok.text;
        if (p.type != null) continue;
        if (cst.isDiscardName(pname)) continue;
        var found = false;

        for (out[0..idx]) |e| if (std.mem.eql(u8, e, pname)) {
            found = true;
            break;
        };

        if (found) continue;
        out[idx] = pname;
        idx += 1;
    }
    return out[0..idx];
}

/// param without annotation becomes `type_var(name)`, else `any` for `_`
pub fn implicitParamType(p: cst.CstParam) TypeInfo {
    if (p.type != null) unreachable;
    const pname = p.name_tok.text;
    if (cst.isDiscardName(pname)) return .{ .tag = .any };

    return .{ .tag = .{ .type_var = pname } };
}

/// params needing values at call time, one formula for all four sig loops
///   replaces `+= 1` and `len -= 1` spellings, same count either way
pub fn requiredCount(params: []const cst.CstParam) usize {
    var n: usize = 0;
    for (params) |p| {
        if (p.qmark_tok == null and p.default == null) n += 1;
    }

    return n;
}

/// shared eval for scopes needing no validation
fn evalInScope(ctx: anytype, te: *const cst.CstType) !TypeInfo {
    return evalTypeExpr(ctx.aliasScope(), te);
}

/// buildFnSig flags, both off for semantic strict mode
pub const SigOpt = struct {
    degrade_param: bool = false,
    want_defaults: bool = false,
};

/// one fn-sig builder for all four inference sites
///   degrade turns per-param failures to any, strict propagates
///   want_defaults fills default_values like locals does
///   scoping save/restore stays at call sites, only loop + sig live here
pub fn buildFnSig(
    alloc: std.mem.Allocator,
    ctx: anytype,
    params: []const cst.CstParam,
    return_type: ?*const cst.CstType,
    type_params: []const []const u8,
    doc: ?[]const u8,
    opt: SigOpt,
) !*FunctionSignature {
    var param_names = try std.ArrayList([]const u8).initCapacity(alloc, params.len);
    errdefer param_names.deinit(alloc);

    var param_types = try std.ArrayList(TypeInfo).initCapacity(alloc, params.len);
    errdefer param_types.deinit(alloc);

    for (params) |p| {
        try param_names.append(alloc, p.name_tok.text);

        const t = if (p.type) |tn| evalInScope(ctx, tn) catch |e| blk: {
            if (opt.degrade_param) break :blk TypeInfo{ .tag = .any };

            return e;
        } else implicitParamType(p);
        try param_types.append(alloc, t);
    }

    const default_values = if (opt.want_defaults) blk: {
        var defaults = try std.ArrayList(?*const cst.CstNode).initCapacity(alloc, params.len);
        errdefer defaults.deinit(alloc);
        for (params) |p| try defaults.append(alloc, p.default);

        break :blk try defaults.toOwnedSlice(alloc);
    } else &.{};

    return newSignature(alloc, .{
        .param_names = try param_names.toOwnedSlice(alloc),
        .params = try param_types.toOwnedSlice(alloc),
        .return_type = if (return_type) |rt| evalInScope(ctx, rt) catch |e| blk: {
            if (opt.degrade_param) break :blk TypeInfo{ .tag = .any };

            return e;
        } else TypeInfo{ .tag = .any },
        .required_count = requiredCount(params),
        .type_params = try combinedTypeParams(alloc, type_params, params),
        .default_values = default_values,
        .doc = doc,
    });
}

/// the single inference interface every scope implements
///
pub const CheckCtx = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    alloc: std.mem.Allocator,
    /// annotations to consult before live inference, set only by Compiler
    ///   semantic and import scopes analyze with null and infer everything
    annotations: ?Annotations = null,
    /// annotations are authoritative
    ///   an unannotated node is any
    ///   set only by Compiler when it has semantic annotations
    annotations_only: bool = false,
    /// eval data for the scope, filled by check() from producer maps
    scope: AliasScope,

    pub const VTable = struct {
        inferIdentType: *const fn (ptr: *anyopaque, name: []const u8) TypeInfo,
        inferCallReturnType: *const fn (ptr: *anyopaque, callee: *const cst.CstNode, args: []const *const cst.CstNode, type_args: []const []const u8, implicit_self: bool) TypeInfo,
        inferFieldType: *const fn (ptr: *anyopaque, object: *const cst.CstNode, name: []const u8) TypeInfo,
        inferFnType: *const fn (ptr: *anyopaque, params: []const cst.CstParam, return_type: ?*const cst.CstType, type_params: []const []const u8, doc: ?[]const u8) TypeInfo,
    };

    /// wrap any scope implementing the four vtable methods
    pub fn init(scope: anytype, alloc: std.mem.Allocator) CheckCtx {
        const S = @TypeOf(scope);
        const V = struct {
            fn vtInferIdentType(p: *anyopaque, name: []const u8) TypeInfo {
                const s: S = @ptrCast(@alignCast(p));
                return s.inferIdentType(name);
            }
            fn vtInferCallReturnType(p: *anyopaque, callee: *const cst.CstNode, args: []const *const cst.CstNode, type_args: []const []const u8, implicit_self: bool) TypeInfo {
                const s: S = @ptrCast(@alignCast(p));
                return s.inferCallReturnType(callee, args, type_args, implicit_self);
            }
            fn vtInferFieldType(p: *anyopaque, object: *const cst.CstNode, name: []const u8) TypeInfo {
                const s: S = @ptrCast(@alignCast(p));
                return s.inferFieldType(object, name);
            }
            fn vtInferFnType(p: *anyopaque, params: []const cst.CstParam, return_type: ?*const cst.CstType, type_params: []const []const u8, doc: ?[]const u8) TypeInfo {
                const s: S = @ptrCast(@alignCast(p));
                return s.inferFnType(params, return_type, type_params, doc);
            }
            const vtable: VTable = .{
                .inferIdentType = vtInferIdentType,
                .inferCallReturnType = vtInferCallReturnType,
                .inferFieldType = vtInferFieldType,
                .inferFnType = vtInferFnType,
            };
        };
        return .{
            .ptr = scope,
            .alloc = alloc,
            .vtable = &V.vtable,
            .scope = undefined,
        };
    }

    pub fn inferIdentType(self: CheckCtx, name: []const u8) TypeInfo {
        return self.vtable.inferIdentType(self.ptr, name);
    }

    pub fn inferCallReturnType(self: CheckCtx, callee: *const cst.CstNode, args: []const *const cst.CstNode, type_args: []const []const u8, implicit_self: bool) TypeInfo {
        return self.vtable.inferCallReturnType(self.ptr, callee, args, type_args, implicit_self);
    }

    pub fn inferFieldType(self: CheckCtx, object: *const cst.CstNode, name: []const u8) TypeInfo {
        return self.vtable.inferFieldType(self.ptr, object, name);
    }

    pub fn inferFnType(self: CheckCtx, params: []const cst.CstParam, return_type: ?*const cst.CstType, type_params: []const []const u8, doc: ?[]const u8) TypeInfo {
        return self.vtable.inferFnType(self.ptr, params, return_type, type_params, doc);
    }
};

/// one-shot eval with no scope: tooling convenience (hover, sig previews)
pub fn evalBare(alloc: std.mem.Allocator, te: *const cst.CstType) !TypeInfo {
    return evalTypeExpr(.{ .alloc = alloc }, te);
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
        .bool, .number, .string, .resource, .any, .never => ti,
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
                    .optional = f.optional,
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
        .bool, .number, .string, .resource, .any, .never => {},
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

/// interned type handle, index into TypeTable
///   copies are free, the table owns the canonical trees
pub const TypeId = u32;

/// annotations bundle: node -> TypeId map plus the table owning the types
///   map and table travel together; the table outlives every map reader
pub const Annotations = struct {
    map: *std.AutoHashMap(*const cst.CstNode, TypeId),
    table: *TypeTable,
};

pub const Alias = struct {
    info: TypeInfo,
    doc: ?[]const u8 = null,
};

/// everything evalTypeExpr resolves, no behavior producers fill it from their own maps
///   empty means degrade to any
pub const AliasScope = struct {
    alloc: std.mem.Allocator,
    type_params: []const []const u8 = &.{},
    aliases: ?*const std.StringHashMap(Alias) = null,
    imports: ?*const std.StringHashMap(std.StringHashMap(TypeInfo)) = null,

    pub fn isTypeParam(self: AliasScope, name: []const u8) bool {
        for (self.type_params) |tp| if (std.mem.eql(u8, tp, name)) return true;
        return false;
    }

    pub fn resolveTypeAlias(self: AliasScope, name: []const u8) ?TypeInfo {
        const aliases = self.aliases orelse return null;
        const found = aliases.get(name) orelse return null;
        return found.info;
    }

    pub fn resolveImportAlias(self: AliasScope, module: []const u8, name: []const u8) ?TypeInfo {
        const imports = self.imports orelse return null;
        const aliases = imports.get(module) orelse return null;
        return aliases.get(name);
    }
};

/// dedup store for canonical TypeInfo trees
///   intern clones into the table arena; inputs stay caller-owned as before
///   lookup returns borrowed views, never free them
///   linear scan: distinct types per build number in the dozens, and exact
///  compare short-circuits on the tag
pub const TypeTable = struct {
    alloc: std.mem.Allocator,
    types: std.ArrayList(TypeInfo),

    pub fn init(alloc: std.mem.Allocator) TypeTable {
        return .{ .alloc = alloc, .types = .empty };
    }

    pub fn deinit(self: *TypeTable) void {
        for (self.types.items) |*ti| deinitType(ti, self.alloc);
        self.types.deinit(self.alloc);
    }

    pub fn intern(self: *TypeTable, info: TypeInfo) !TypeId {
        for (self.types.items, 0..) |existing, i| {
            if (eqlExact(existing, info)) return @intCast(i);
        }

        const owned = try clone(info, self.alloc);
        errdefer {
            var tmp = owned;
            deinitType(&tmp, self.alloc);
        }
        try self.types.append(self.alloc, owned);

        return @intCast(self.types.items.len - 1);
    }

    pub fn get(self: *const TypeTable, id: TypeId) TypeInfo {
        return self.types.items[id];
    }
};

/// exact structural identity for interning, unlike eql below
///   any matches only any, all sig fields count including names and docs
///   pointer leaves (table key/value, sig, defaults) compare by identity
///   when non-empty; empty slices match regardless of backing
pub fn eqlExact(a: TypeInfo, b: TypeInfo) bool {
    if (std.meta.activeTag(a.tag) != std.meta.activeTag(b.tag)) return false;

    if (a.doc == null) {
        if (b.doc != null) return false;
    } else if (b.doc) |bd| {
        if (!std.mem.eql(u8, a.doc.?, bd)) return false;
    } else return false;

    return switch (a.tag) {
        .bool, .number, .string, .resource, .any, .never => true,
        .atom => |s| std.mem.eql(u8, s, b.tag.atom),
        .type_var => |s| std.mem.eql(u8, s, b.tag.type_var),
        .@"union" => |us| blk: {
            const vs = b.tag.@"union";
            if (us.len != vs.len) break :blk false;

            for (us, vs) |u, v| {
                if (!std.mem.eql(u8, u.name, v.name)) break :blk false;
                if (u.types.len != v.types.len) break :blk false;

                for (u.types, v.types) |ut, vt| {
                    if (!eqlExact(ut, vt)) break :blk false;
                }
            }
            break :blk true;
        },
        .table => |t| blk: {
            const o = b.tag.table;

            if ((t.key == null) != (o.key == null)) break :blk false;
            if (t.key) |k| {
                if (!eqlExact(k.*, o.key.?.*)) break :blk false;
            }

            if (!eqlExact(t.value.*, o.value.*)) break :blk false;
            if ((t.fields == null) != (o.fields == null)) break :blk false;

            if (t.fields) |fs| {
                const os = o.fields.?;
                if (fs.len != os.len) break :blk false;
                for (fs, os) |f, of| {
                    if (!std.mem.eql(u8, f.name, of.name)) break :blk false;
                    if (f.optional != of.optional) break :blk false;
                    if (!eqlExact(f.field_type, of.field_type)) break :blk false;
                }
            }
            break :blk true;
        },
        .function => |f| blk: {
            // wow this is ugly..... cant be arsed to make it smart
            const o = b.tag.function;
            if (f == o) break :blk true;
            if (f.params.len != o.params.len) break :blk false;
            for (f.params, o.params) |p, q| {
                if (!eqlExact(p, q)) break :blk false;
            }

            if (!eqlExact(f.return_type, o.return_type)) break :blk false;
            if (f.param_names.len != o.param_names.len) break :blk false;
            for (f.param_names, o.param_names) |n, m| {
                if (!std.mem.eql(u8, n, m)) break :blk false;
            }

            if (f.required_count != o.required_count) break :blk false;
            if (f.is_any_fn_sig != o.is_any_fn_sig) break :blk false;
            if (f.type_params.len != o.type_params.len) break :blk false;
            for (f.type_params, o.type_params) |tp, tq| {
                if (!std.mem.eql(u8, tp, tq)) break :blk false;
            }

            if (f.default_values.len != o.default_values.len) break :blk false;
            for (f.default_values, o.default_values) |d, e| {
                if ((d == null) != (e == null)) break :blk false;
                if (d != null and d.? != e.?) break :blk false;
            }

            if (f.doc == null) {
                if (o.doc != null) break :blk false;
            } else if (o.doc) |od| {
                if (!std.mem.eql(u8, f.doc.?, od)) break :blk false;
            } else break :blk false;
            break :blk true;
        },
    };
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
                    const have = findField(haves, w.name) orelse {
                        // `?name:` wants tolerate absent fields
                        if (w.optional) continue;
                        return false;
                    };
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
        const name = cst.atomName(from.tag.atom);
        return std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false");
    }
    if (to.tag == .@"union") {
        // fast-path for atom literals vs atom-only variants
        if (from.tag == .atom) {
            for (to.tag.@"union") |variant| {
                if (variant.types.len == 1 and variant.types[0].tag == .atom) {
                    if (std.mem.eql(u8, cst.atomName(variant.types[0].tag.atom), cst.atomName(from.tag.atom))) return true;
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

pub fn inferBinaryOp(op: cst.BinOp, l: TypeInfo, r: TypeInfo) TypeInfo {
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

pub fn inferUnaryOp(op: cst.UnaryOp, T: TypeInfo) TypeInfo {
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

pub fn inferMatchType(ctx: CheckCtx, subject: ?*const cst.CstNode, arms: []const cst.CstArm) TypeInfo {
    const subject_type: TypeInfo = if (subject) |s| inferExprType(ctx, s) else .{ .tag = .any };
    var result: TypeInfo = .{ .tag = .never };
    for (arms) |arm| {
        result = unifyBranchType(result, inferExprType(ctx, arm.then));
    }

    // miss falls through to nil at runtime
    // so a non-exhaustive match always carries :nil in its type
    if (!matchCovers(ctx.scope, subject_type, arms)) {
        result = withNilMiss(ctx.alloc, result);
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
pub fn unionVariantTagEql(variant: UnionVariant, tag: []const u8) bool {
    const pattern_tag = if (tag.len > 0 and tag[0] == ':') tag[1..] else tag;
    if (variant.types.len == 0) return false;

    if (variant.types[0].tag == .atom) {
        return std.mem.eql(u8, cst.atomName(variant.types[0].tag.atom), pattern_tag);
    }

    if (variant.types[0].tag == .table) {
        const fields = variant.types[0].tag.table.fields orelse return false;
        if (fields.len == 0 or !std.mem.eql(u8, fields[0].name, "0")) return false;
        if (fields[0].field_type.tag != .atom) return false;
        return std.mem.eql(u8, cst.atomName(fields[0].field_type.tag.atom), pattern_tag);
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
            const want = std.mem.print(&buf, "{d}", .{idx}) catch return;
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
            break :blk isResultTag(cst.atomName(fields[0].field_type.tag.atom));
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
            if (!isOkTag(cst.atomName(fields[0].field_type.tag.atom))) break :blk .{ .tag = .any };
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
    .{ "string", TypeInfo{ .tag = .string } },
    .{ "bool", TypeInfo{ .tag = .bool } },
    .{ "any", TypeInfo{ .tag = .any } },
    .{ "table", TABLE_GENERIC },
    .{ "resource", TypeInfo{ .tag = .resource } },
    .{ "function", TypeInfo{ .tag = .{ .function = &ANY_FN_SIG } } },
    .{ "atom", TypeInfo{ .tag = .{ .atom = "" } } }, // empty atom payload is the "any atom" sentinel
    .{ "never", TypeInfo{ .tag = .never } },
});

pub fn resolveTypeName(scope: AliasScope, name: []const u8) TypeInfo {
    if (type_name_map.get(name)) |res| return res;
    if (name.len > 0 and name[0] == ':') return .{ .tag = .{ .atom = name } };

    if (scope.resolveTypeAlias(name)) |aliased| return aliased;
    return .{ .tag = .any };
}

pub fn inferExprType(ctx: CheckCtx, node: *const cst.CstNode) TypeInfo {
    // annotated nodes answer from the table
    //   everything else infers live
    //   only Compiler sets annotations
    //   , so producer scopes never hit this
    if (ctx.annotations) |ann| {
        if (ann.map.get(node)) |id| return ann.table.get(id);
    }
    // compiler builds trust semantic completely
    //   a miss is any semantic/import scopes leave this false and keep live inference
    if (ctx.annotations_only) return .{ .tag = .any };
    // parens are transparent in cst; empty `()` is nil
    const uw = cst.unwrapParen(node) orelse return .{ .tag = .{ .atom = ":nil" } };
    if (uw != node) return inferExprType(ctx, uw);
    return switch (node.kind) {
        .number => .{ .tag = .number },
        // sugar lowers to a `fmt` call (string), answering directly keeps
        // , this total for unlowered trees (tests, const-eval) too
        .string, .interpolated => .{ .tag = .string },
        .atom => |a| .{ .tag = .{ .atom = a.tok.text } },
        .ident => |i| ctx.inferIdentType(i.tok.text),
        .err => .{ .tag = .any },
        .unary => |u| inferUnaryOp(u.op, inferExprType(ctx, u.expr)),
        .yield => .{ .tag = .any },
        .binary => |b| inferBinaryOp(b.op, inferExprType(ctx, b.left), inferExprType(ctx, b.right)),
        .logical => |l| switch (l.op) {
            .and_op, .or_op => .{ .tag = .bool },
            .orelse_op => inferOrelseType(inferExprType(ctx, l.left), inferExprType(ctx, l.right)),
        },
        .compound => |c| inferExprType(ctx, c.value),
        .assign => |a| inferExprType(ctx, a.value),
        .field => |f| ctx.inferFieldType(f.object, f.name_tok.text),
        .dotted_index => |d| switch (inferExprType(ctx, d.object).tag) {
            .string => .{ .tag = .string },
            else => .{ .tag = .any },
        },
        // `obj:method(args)` desugars to a call with implicit self; without a
        // synthesized field node we answer `any` like an unknown call
        .method_call => .{ .tag = .any },
        .index => |ix| inferIndexType(ctx, ix.object, ix.key),
        .generic_call => |g| blk: {
            // `f<T>(args)`: convert token type args to strings on the stack;
            // longer lists degrade to `any` rather than allocating here
            var buf: [8][]const u8 = undefined;
            if (g.type_args.len > buf.len) break :blk .{ .tag = .any };
            for (g.type_args, 0..) |tok, i| buf[i] = tok.text;
            break :blk ctx.inferCallReturnType(g.receiver, g.args, buf[0..g.type_args.len], false);
        },
        .call => |c| ctx.inferCallReturnType(c.callee, c.args, &.{}, false),
        .bare_call => |b| blk: {
            const one = [_]*const cst.CstNode{b.arg};
            break :blk ctx.inferCallReturnType(b.callee, &one, &.{}, false);
        },
        .range, .for_range, .slice => .{ .tag = .number },
        // `a |> f` desugars to a call or a temp block; answer `any`
        .pipe => .{ .tag = .any },
        .try_expr => |t| blk: {
            const it = inferExprType(ctx, t.expr);
            break :blk switch (it.tag) {
                .@"union", .table => okTypeFrom(it),
                else => it,
            };
        },
        .if_expr => |v| inferIfType(
            inferExprType(ctx, v.then),
            if (v.else_) |e| inferExprType(ctx, e) else null,
        ),
        .match => |m| inferMatchType(ctx, m.subject, m.arms),
        .ascribed => |a| inferExprType(ctx, a.expr),
        .table => |t| inferTableType(ctx, t.entries),
        .paren => |p| if (p.expr) |e| inferExprType(ctx, e) else .{ .tag = .{ .atom = ":nil" } },
        .block => |b| inferBlockResultType(ctx, b.stmts),
        .do_block => |d| inferBlockResultType(ctx, d.stmts),
        .root => |r| inferBlockResultType(ctx, r.stmts),
        .fn_def => |f| blk: {
            var tp_buf: [16][]const u8 = undefined;
            if (f.type_params.len > tp_buf.len) break :blk .{ .tag = .any };
            for (f.type_params, 0..) |tok, i| tp_buf[i] = tok.text;
            break :blk ctx.inferFnType(f.params, f.return_type, tp_buf[0..f.type_params.len], null);
        },
        // `fn obj:m() ...` lowers to an index assign; the def itself is a statement
        .fn_method => .{ .tag = .any },
        .binding => |b| inferExprType(ctx, b.value),
        .decl => |d| inferExprType(ctx, d.inner),
        .import => .{ .tag = .any },
        .test_block, .test_suite => .{ .tag = .any },
        .type_alias => .{ .tag = .any },
        .for_loop => |v| if (v.label_tok == null) .{ .tag = .{ .atom = "loop" } } else .{ .tag = .any },
        .while_loop => |v| if (v.label_tok == null) .{ .tag = .{ .atom = "loop" } } else .{ .tag = .any },
        .loop_expr => |v| if (v.label_tok == null) .{ .tag = .{ .atom = "loop" } } else .{ .tag = .any },
        .break_expr => |b| if (b.value) |v| inferExprType(ctx, v) else .{ .tag = .any },
        .continue_expr => .{ .tag = .any },
        .return_expr => .{ .tag = .any },
        .comp_block => |c| inferExprType(ctx, c.expr),
    };
}

/// static `name = v` / `:name = v` key, or null for computed/dynamic keys
/// , mirrors `ast.staticFieldName` over cst table keys; parens transparent
fn staticCstFieldName(key: *const cst.CstNode) ?[]const u8 {
    const uw = cst.unwrapParen(key) orelse return null;
    return switch (uw.kind) {
        .ident => |i| i.tok.text,
        .atom => |a| cst.atomName(a.tok.text),
        else => null,
    };
}

fn inferTableType(ctx: CheckCtx, entries: []const cst.CstEntry) TypeInfo {
    var value_type: TypeInfo = .{ .tag = .any };
    var key_type: TypeInfo = .{ .tag = .any };
    var saw_explicit_key = false;
    var saw_implicit_key = false;
    var saw_dynamic = false;
    var fields = std.ArrayList(RecordField).initCapacity(ctx.alloc, entries.len) catch return .{ .tag = .any };
    var array_index: u32 = 0;

    for (entries) |entry| {
        switch (entry) {
            .computed => |cc| {
                const field_type = inferExprType(ctx, cc.value);
                value_type = mergeInferredType(value_type, field_type);
                const inferred_key = inferExprType(ctx, cc.key);
                key_type = if (saw_explicit_key) mergeInferredType(key_type, inferred_key) else inferred_key;
                saw_explicit_key = true;
                // computed keys hide dynamic content
                saw_dynamic = true;
            },
            .keyed => |k| {
                const field_type = inferExprType(ctx, k.value);
                value_type = mergeInferredType(value_type, field_type);
                const inferred_key = inferTableKeyType(ctx, entry);
                key_type = if (saw_explicit_key) mergeInferredType(key_type, inferred_key) else inferred_key;
                saw_explicit_key = true;
                //
                // static `name = v` keys become record fields; dupes replace,
                // last wins like the runtime
                if (staticCstFieldName(k.key)) |name| {
                    if (findFieldIndex(fields.items, name)) |i| {
                        fields.items[i].field_type = field_type;
                    } else fields.append(ctx.alloc, .{ .name = name, .field_type = field_type }) catch return .{ .tag = .any };
                } else {
                    // computed or non-ident keys hide dynamic content
                    // so a missing field cant prove absence
                    saw_dynamic = true;
                }
            },
            .bare => |b| {
                // method defs are record fields with their fn type
                // they carry no value type contribution
                const bv = cst.unwrapParen(b.value) orelse {
                    const field_type: TypeInfo = .{ .tag = .{ .atom = ":nil" } };
                    value_type = mergeInferredType(value_type, field_type);
                    const idx_name = ctx.alloc.print("{d}", .{array_index}) catch return .{ .tag = .any };
                    array_index += 1;
                    fields.append(ctx.alloc, .{ .name = idx_name, .field_type = field_type }) catch return .{ .tag = .any };
                    saw_implicit_key = true;
                    continue;
                };
                if (bv.kind == .decl and bv.kind.decl.inner.kind == .binding) {
                    const binding = bv.kind.decl.inner.kind.binding;
                    const bval = cst.unwrapParen(binding.value) orelse null;
                    if (bval != null and bval.?.kind == .fn_def) {
                        const bt = cst.unwrapParen(binding.target) orelse null;
                        if (bt != null and bt.?.kind == .ident) {
                            const method_name = bt.?.kind.ident.tok.text;
                            const fn_type = inferExprType(ctx, binding.value);
                            fields.append(ctx.alloc, .{ .name = method_name, .field_type = fn_type }) catch return .{ .tag = .any };
                            continue;
                        }
                    }
                }
                const field_type = inferExprType(ctx, b.value);
                value_type = mergeInferredType(value_type, field_type);
                // keyless/implicit entries are numeric fields
                const idx_name = ctx.alloc.print("{d}", .{array_index}) catch return .{ .tag = .any };
                array_index += 1;
                fields.append(ctx.alloc, .{ .name = idx_name, .field_type = field_type }) catch return .{ .tag = .any };
                saw_implicit_key = true;
            },
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

fn inferTableKeyType(ctx: CheckCtx, entry: cst.CstEntry) TypeInfo {
    return switch (entry) {
        .computed => |cc| inferExprType(ctx, cc.key),
        .keyed => |k| if (staticCstFieldName(k.key) != null) .{ .tag = .string } else inferExprType(ctx, k.key),
        .bare => .{ .tag = .any },
    };
}

fn mergeInferredType(current: TypeInfo, next: TypeInfo) TypeInfo {
    if (current.tag == .any) return next;
    if (next.tag == .any) return current;
    if (current.eql(next)) return current;
    if ((current.tag == .number and next.tag == .number) or (current.tag == .number and next.tag == .number)) return .{ .tag = .number };
    return .{ .tag = .any };
}

pub fn inferIndexType(ctx: CheckCtx, object: *const cst.CstNode, key: *const cst.CstNode) TypeInfo {
    if (cst.unwrapParen(key)) |uk| {
        if (uk.kind == .range or uk.kind == .for_range or uk.kind == .slice) {
            return switch (inferExprType(ctx, object).tag) {
                .string => .{ .tag = .string },
                else => .{ .tag = .any },
            };
        }
    }
    return switch (inferExprType(ctx, object).tag) {
        .string => .{ .tag = .string },
        else => .{ .tag = .any },
    };
}

pub fn inferBlockResultType(ctx: CheckCtx, exprs: []const *const cst.CstNode) TypeInfo {
    if (exprs.len == 0) return .{ .tag = .any };
    return inferExprType(ctx, exprs[exprs.len - 1]);
}

/// cst type syntax back into a TypeInfo
/// every CstTypeKind must be handled here; this is the single place where CST type
/// nodes become semantic TypeInfo values. mirrors ast.printTypeExpr via lowering folds:
/// optional/qualified_optional fold to a nilable union, paren/slashed fold to inner,
/// union_of flattens
/// ctx is any CheckCtx scope: aliases resolve in the caller's scope
pub fn evalTypeExpr(scope: AliasScope, te: *const cst.CstType) !TypeInfo {
    switch (te.kind) {
        // "number" -> number (from type_name_map), unknown names -> any
        .named => |n| {
            const name = n.tok.text;
            if (scope.isTypeParam(name)) return .{ .tag = .{ .type_var = name } };
            if (type_name_map.get(name)) |res| return res;
            if (scope.resolveTypeAlias(name)) |aliased| return aliased;
            return .{ .tag = .any };
        },
        // "a.T" -> module a's alias T, or any when unresolvable (the
        // compiler has no dep IO, so it always lands here; semantic
        // validates qualified names separately and errors first)
        .qualified => |q| {
            if (scope.resolveImportAlias(q.mod_tok.text, q.name_tok.text)) |t| return t;
            return .{ .tag = .any };
        },
        // ":nil", ":ok" -> atom
        .atom => |a| return .{ .tag = .{ .atom = a.tok.text } },
        // "number | :nil" -> union(@[{name="", types=@[number]}, {name="", types=@[:nil]}])
        // "number?" folds like `union_of(named("number"), atom(":nil"))` from lowering
        .union_of => |u| {
            var collected = try std.ArrayList(UnionVariant).initCapacity(scope.alloc, 4);
            errdefer collected.deinit(scope.alloc);
            const first = try evalTypeExpr(scope, u.first);
            try collectVariants(scope.alloc, first, &collected);
            for (u.rest) |r| {
                const inner = try evalTypeExpr(scope, r);
                try collectVariants(scope.alloc, inner, &collected);
            }
            return .{ .tag = .{ .@"union" = try collected.toOwnedSlice(scope.alloc) } };
        },
        // `T?` suffix folds to `T | :nil`
        // the `?` isglued on the name token
        .optional => |o| {
            const base: TypeInfo = if (o.inner.kind == .named) blk: {
                const tok = o.inner.kind.named.tok;
                const raw = tok.text;
                const stripped = if (raw.len > 0 and raw[raw.len - 1] == '?') raw[0 .. raw.len - 1] else raw;

                if (scope.isTypeParam(stripped)) break :blk .{ .tag = .{ .type_var = stripped } };
                if (type_name_map.get(stripped)) |res| break :blk res;
                if (scope.resolveTypeAlias(stripped)) |aliased| break :blk aliased;

                break :blk .{ .tag = .any };
            } else try evalTypeExpr(scope, o.inner);

            var collected = try std.ArrayList(UnionVariant).initCapacity(scope.alloc, 2);
            errdefer collected.deinit(scope.alloc);
            try collectVariants(scope.alloc, base, &collected);
            try collectVariants(scope.alloc, .{ .tag = .{ .atom = ":nil" } }, &collected);

            return .{ .tag = .{ .@"union" = try collected.toOwnedSlice(scope.alloc) } };
        },
        // "fn(number) -> bool" -> function(param_types=@[number], return_type=bool)
        .function => |f| {
            var param_types = try std.ArrayList(TypeInfo).initCapacity(scope.alloc, f.params.len);
            errdefer param_types.deinit(scope.alloc);

            for (f.params) |p| {
                try param_types.append(scope.alloc, if (p.type) |tn| try evalTypeExpr(scope, tn) else .{ .tag = .any });
            }

            var param_names = try std.ArrayList([]const u8).initCapacity(scope.alloc, f.params.len);
            errdefer param_names.deinit(scope.alloc);
            for (f.params) |p| try param_names.append(scope.alloc, p.name_tok.text);
            const return_type = if (f.ret) |rt| try evalTypeExpr(scope, rt) else TypeInfo{ .tag = .any };

            var required: usize = 0;
            for (f.params) |p| {
                if (p.qmark_tok == null) required += 1;
            }

            const tps = if (f.tps.len == 0) &[_][]const u8{} else blk: {
                const owned = try scope.alloc.alloc([]const u8, f.tps.len);
                for (f.tps, owned) |tok, *dst| dst.* = tok.text;
                break :blk owned;
            };

            const sig = try newSignature(scope.alloc, .{
                .param_names = try param_names.toOwnedSlice(scope.alloc),
                .params = try param_types.toOwnedSlice(scope.alloc),
                .return_type = return_type,
                .required_count = required,
                .type_params = tps,
            });

            return .{ .tag = .{ .function = sig } };
        },
        // "table<number>" -> table(key=null, value=number), "table<string, number>" -> table(key=string, value=number)
        .parameterized => |p| {
            var params = try std.ArrayList(TypeInfo).initCapacity(scope.alloc, p.args.len);
            errdefer params.deinit(scope.alloc);
            for (p.args) |param| try params.append(scope.alloc, try evalTypeExpr(scope, param));
            const resolved = try params.toOwnedSlice(scope.alloc);
            if (std.mem.eql(u8, p.name_tok.text, "table")) {
                if (resolved.len == 1) {
                    const v = try scope.alloc.create(TypeInfo);
                    v.* = resolved[0];
                    return .{ .tag = .{ .table = .{ .key = null, .value = v } } };
                }
                if (resolved.len == 2) {
                    const k = try scope.alloc.create(TypeInfo);
                    k.* = resolved[0];
                    const v = try scope.alloc.create(TypeInfo);
                    v.* = resolved[1];
                    return .{ .tag = .{ .table = .{ .key = k, .value = v } } };
                }
            }
            return .{ .tag = .any };
        },
        // `a.B?` with glued `?` folds to a nilable union like `optional`
        .qualified_optional => |q| {
            const raw = q.name_tok.text;
            const stripped = if (raw.len > 0 and raw[raw.len - 1] == '?') raw[0 .. raw.len - 1] else raw;
            const base: TypeInfo = if (scope.resolveImportAlias(q.mod_tok.text, stripped)) |t| t else .{ .tag = .any };

            var collected = try std.ArrayList(UnionVariant).initCapacity(scope.alloc, 2);
            errdefer collected.deinit(scope.alloc);

            try collectVariants(scope.alloc, base, &collected);
            try collectVariants(scope.alloc, .{ .tag = .{ .atom = ":nil" } }, &collected);

            return .{ .tag = .{ .@"union" = try collected.toOwnedSlice(scope.alloc) } };
        },
        .paren => |p| return evalTypeExpr(scope, p.inner),
        // "{ name: string, age: number }" -> table with per-field types
        // names borrow source text like .named does, owners clone
        .record => |r| {
            const owned = try scope.alloc.alloc(RecordField, r.fields.len);
            var pos_idx: u32 = 0;
            for (r.fields, owned) |f, *dst| {
                if (f.name_tok) |nt| {
                    dst.* = .{
                        .name = nt.text,
                        .field_type = try evalTypeExpr(scope, f.type),
                        .optional = f.qmark_tok != null,
                    };
                } else {
                    const idx_name = try scope.alloc.print("{d}", .{pos_idx});
                    pos_idx += 1;
                    dst.* = .{
                        .name = idx_name,
                        .field_type = try evalTypeExpr(scope, f.type),
                        .optional = false,
                    };
                }
            }
            const value = try scope.alloc.create(TypeInfo);
            value.* = .{ .tag = .any };
            return makeTable(null, value, owned);
        },
        // `T/tag` carries a tag for lowering; the type is the inner one
        .slashed => |s| return evalTypeExpr(scope, s.inner),
        // "!number" -> union(@[{name="", types=@[{:ok, number}]}, {name="", types=@[{:err, any}]}])
        // the same shape the literal `{:ok, number} | {:err, any}` produces
        .error_union => |e| {
            const t = try evalTypeExpr(scope, e.inner);
            var collected = try std.ArrayList(UnionVariant).initCapacity(scope.alloc, 2);
            errdefer collected.deinit(scope.alloc);
            try collectVariants(scope.alloc, try makeResultTable(scope.alloc, ":ok", t), &collected);
            try collectVariants(scope.alloc, try makeResultTable(scope.alloc, ":err", .{ .tag = .any }), &collected);
            return .{ .tag = .{ .@"union" = try collected.toOwnedSlice(scope.alloc) } };
        },
    }
}

///
/// guardless arm coverage for match exhaustiveness
/// , one cover per matcher, guards never count since a guard can fail
///
fn patternCover(scope: AliasScope, node: *const cst.CstNode) MatchCover {
    const uw = cst.unwrapParen(node) orelse return .{ .atom = ":nil" };
    // parens are transparent; empty `()` is nil
    if (uw != node) return patternCover(scope, uw);
    return switch (node.kind) {
        .ident => .wildcard,
        .atom => |a| .{ .atom = a.tok.text },
        .number => .number,
        .string, .interpolated => .string,

        .ascribed => |a| blk: {
            const inner_uw = cst.unwrapParen(a.expr) orelse break :blk patternCover(scope, a.expr);
            if (inner_uw.kind == .ident)
                break :blk .{ .ascribed = evalTypeExpr(scope, a.type) catch TypeInfo{ .tag = .any } };
            break :blk patternCover(scope, a.expr);
        },

        .table => |t| blk: {
            // keyless `{...}` is an array pattern like the old `table_pattern`;
            // keyed/computed entries are not positional shapes
            for (t.entries) |entry| {
                switch (entry) {
                    .bare => {},
                    .keyed, .computed => break :blk .other,
                }
            }
            const elems = scope.alloc.alloc(MatchCover, t.entries.len) catch break :blk .other;

            for (t.entries, elems) |entry, *dst| {
                // checked above: all bare
                dst.* = patternCover(scope, entry.bare.value);
            }

            break :blk .{ .table = elems };
        },
        .paren => |p| if (p.expr) |e| patternCover(scope, e) else .{ .atom = ":nil" },

        else => .other,
    };
}

fn matcherCover(scope: AliasScope, m: cst.CstMatcher) MatchCover {
    return switch (m) {
        .wildcard => .wildcard,
        .expr => |e| patternCover(scope, e),
    };
}

/// one cover per guardless matcher
/// , callers decide what guards mean
pub fn buildArmCovers(scope: AliasScope, arm: cst.CstArm) ![]MatchCover {
    var covers = std.ArrayList(MatchCover).initCapacity(scope.alloc, arm.matchers.len) catch return &.{};
    errdefer covers.deinit(scope.alloc);

    for (arm.matchers) |m| try covers.append(scope.alloc, matcherCover(scope, m));
    return covers.toOwnedSlice(scope.alloc);
}

pub fn buildCovers(scope: AliasScope, arms: []const cst.CstArm) ![]MatchCover {
    var covers = std.ArrayList(MatchCover).initCapacity(scope.alloc, arms.len) catch return &.{};
    errdefer covers.deinit(scope.alloc);

    for (arms) |arm| {
        if (arm.guard != null) continue;

        const one = try buildArmCovers(scope, arm);
        defer scope.alloc.free(one);

        try covers.appendSlice(scope.alloc, one);
    }

    return covers.toOwnedSlice(scope.alloc);
}

pub fn matchCovers(scope: AliasScope, subject: TypeInfo, arms: []const cst.CstArm) bool {
    const covers = buildCovers(scope, arms) catch return false;
    defer scope.alloc.free(covers);

    return matchCoversAll(subject, covers);
}

/// one `{:tag, payload}` table, the same shape `{...}` literals infer:
/// positional fields, tag atom in "0", payload in "1"
fn makeResultTable(alloc: std.mem.Allocator, tag: []const u8, payload: TypeInfo) !TypeInfo {
    const fields = try alloc.alloc(RecordField, 2);
    fields[0] = .{ .name = "0", .field_type = .{ .tag = .{ .atom = tag } } };
    fields[1] = .{ .name = "1", .field_type = payload };
    const value = try alloc.create(TypeInfo);
    value.* = .{ .tag = .any };
    return makeTable(null, value, fields);
}

/// walk arg types against param types and bind each type_var found inside a
/// param to the concrete type at the same position
/// , e.g. `self: {:err, T}` against `{:err, string}` binds T -> string
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
                    if (!std.mem.eql(u8, cst.atomName(pv.types[0].tag.atom), cst.atomName(av.types[0].tag.atom))) continue;
                    for (pv.types[1..], av.types[1..]) |p, a| try bindTypeParam(subst, p, a);
                    break;
                }
            }
        },
        else => {},
    }
}

/// first-wins type var map over a linear scan
pub const TypeSubst = struct {
    entries: std.ArrayList(SubstEntry),
    alloc: std.mem.Allocator,
    pub const SubstEntry = struct { name: []const u8, type: TypeInfo };

    pub fn init(alloc: std.mem.Allocator, cap: usize) std.mem.Allocator.Error!TypeSubst {
        return .{ .entries = try std.ArrayList(SubstEntry).initCapacity(alloc, cap), .alloc = alloc };
    }

    pub fn deinit(self: *TypeSubst) void {
        self.entries.deinit(self.alloc);
    }

    pub fn get(self: *const TypeSubst, name: []const u8) ?TypeInfo {
        for (self.entries.items) |e| if (std.mem.eql(u8, e.name, name)) return e.type;
        return null;
    }

    pub fn put(self: *TypeSubst, name: []const u8, ti: TypeInfo) !void {
        if (self.get(name) != null) return;
        try self.entries.append(self.alloc, .{ .name = name, .type = ti });
    }
};

/// substitute explicit + inferred arg types into a generic return type
/// degrades to any on OOM
pub fn substituteGenericReturn(
    alloc: std.mem.Allocator,
    ret: TypeInfo,
    type_params: []const []const u8,
    explicit: []const TypeInfo,
    params: []const TypeInfo,
    arg_types: []const TypeInfo,
) TypeInfo {
    var subst = TypeSubst.init(alloc, type_params.len) catch return .{ .tag = .any };
    defer subst.deinit();
    for (type_params, 0..) |tp, i| {
        if (i < explicit.len) subst.put(tp, explicit[i]) catch {};
    }
    bindTypeParams(&subst, params, arg_types) catch {};
    return substituteTypeParams(alloc, ret, &subst) catch .{ .tag = .any };
}

/// instantiate a generic fn signature at a call site: resolve explicit
/// , type args, infer rest from arg types, substitute into return
/// , shared by compiler and semantic, degrades to any on oom
pub fn substCallReturn(
    ctx: CheckCtx,
    sig: *const FunctionSignature,
    callee: *const cst.CstNode,
    args: []const *const cst.CstNode,
    type_args: []const []const u8,
    implicit_self: bool,
) TypeInfo {
    var explicit = std.ArrayList(TypeInfo).initCapacity(ctx.alloc, type_args.len) catch return .{ .tag = .any };
    defer explicit.deinit(ctx.alloc);
    for (type_args) |ta| explicit.append(ctx.alloc, resolveTypeName(ctx.scope, ta)) catch return .{ .tag = .any };
    const eff = effectiveArgs(ctx.alloc, sig.params.len, callee, args, implicit_self) catch return .{ .tag = .any };
    var arg_types = std.ArrayList(TypeInfo).initCapacity(ctx.alloc, eff.len) catch return .{ .tag = .any };
    defer arg_types.deinit(ctx.alloc);
    for (eff) |a| arg_types.append(ctx.alloc, inferExprType(ctx, a)) catch return .{ .tag = .any };
    return substituteGenericReturn(ctx.alloc, sig.return_type, sig.type_params, explicit.items, sig.params, arg_types.items);
}

/// method calls (implicit_self) carry the receiver as arg 0
pub fn effectiveArgs(
    alloc: std.mem.Allocator,
    params_len: usize,
    callee: *const cst.CstNode,
    args: []const *const cst.CstNode,
    implicit_self: bool,
) ![]const *const cst.CstNode {
    const uw = cst.unwrapParen(callee) orelse return args;
    if (!implicit_self or uw.kind != .field or params_len == 0) return args;
    if (args.len != params_len - 1) return args;
    const eff = try alloc.alloc(*const cst.CstNode, args.len + 1);
    eff[0] = uw.kind.field.object;
    for (args, 1..) |a, i| eff[i] = a;
    return eff;
}

/// coerce actual into expected
pub fn ensureCoercible(expected: TypeInfo, actual: TypeInfo) !void {
    if (expected.tag == .any or actual.tag == .any) return;
    if (expected.eql(actual)) return;
    if (canCoerce(actual, expected)) return;
    return error.TypeError;
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
                    .optional = f.optional,
                };
                break :blk2 owned;
            } else null;
            break :blk makeTable(new_key, new_value, new_fields);
        },
        else => ti,
    };
}

//
// match cov prover
//

/// one guardless arm shape
/// , `x: T` stays only on binders, else use inner shape
pub const MatchCover = union(enum) {
    wildcard, // `_`, binders, everything
    atom: []const u8, // `:ok`
    ascribed: TypeInfo, // `x: T`, subject fits `T`
    number, // literal, one of infinitely many
    string, // literal, one of infinitely many
    table: []const MatchCover, // `{p0, ...}`, array part only
    other, // unknown shape, meets but never covers
};

/// array length of a table type, null when unknown
/// , counts "0", "1", ... with no gaps, skips named keys
/// , gaps, extra numbers, and open shapes yield null
/// , null covers nothing, but stays reachable for overlaps
fn tableArrayLen(fields: ?[]const RecordField) ?usize {
    const fs = fields orelse return null;

    var len: usize = 0;
    while (len <= fs.len) {
        var buf: [16]u8 = undefined;
        const want = std.mem.print(&buf, "{d}", .{len}) catch return null;
        if (findField(fs, want) == null) break;
        len += 1;
    }

    for (fs) |f| {
        const idx = std.fmt.parseInt(usize, f.name, 10) catch continue;
        if (idx >= len) return null;
    }

    return len;
}

/// element type at idx, null when absent
fn tableElemType(fields: []const RecordField, idx: usize) ?TypeInfo {
    var buf: [16]u8 = undefined;
    const want = std.mem.print(&buf, "{d}", .{idx}) catch return null;

    if (findField(fields, want)) |f| return f.field_type;
    return null;
}

/// one cover hits every value of subject
/// , true is sure, false means nothing, may still hit
/// , tables need one shape only
fn coversOne(subject: TypeInfo, cover: MatchCover) bool {
    switch (cover) {
        .wildcard => return true,
        .ascribed => |ti| return canCoerce(subject, ti),

        .atom => |name| {
            if (subject.tag == .never) return true;
            if (subject.tag != .atom) return false;

            return std.mem.eql(u8, cst.atomName(subject.tag.atom), cst.atomName(name));
        },

        .number, .string, .other => return subject.tag == .never,

        .table => |elems| {
            if (subject.tag == .never) return true;
            if (subject.tag == .table) return tableHits(elems, subject.tag.table.fields);
            if (subject.tag != .@"union") return false;

            for (subject.tag.@"union") |v| if (!variantHits(elems, v)) return false;
            return true;
        },
    }
}

/// table elems hit every element of fields
/// , same length and every element hits
fn tableHits(elems: []const MatchCover, fields: ?[]const RecordField) bool {
    const want = tableArrayLen(fields) orelse return false;
    if (want != elems.len) return false;

    const fs = fields.?;
    for (elems, 0..) |e, i| {
        const et = tableElemType(fs, i) orelse return false;
        if (!coversOne(et, e)) return false;
    }

    return true;
}

/// table elems hit one union variant
/// , plain atoms never meet tables
fn variantHits(elems: []const MatchCover, variant: UnionVariant) bool {
    if (variant.types.len == 0) return false;

    const inner = variant.types[0];
    if (inner.tag != .table) return false;

    return tableHits(elems, inner.tag.table.fields);
}

/// every value of subject meets some cover
/// , pure, no ast, no eval
/// , wildcard and fitting `x: T` return early
/// , unions need all variants hit, tables need one shape hit
pub fn matchCoversAll(subject: TypeInfo, covers: []const MatchCover) bool {
    if (subject.tag == .never) return true;

    for (covers) |c| switch (c) {
        .wildcard => return true,
        .ascribed => |ti| if (canCoerce(subject, ti)) {
            return true;
        },
        else => {},
    };

    switch (subject.tag) {
        .@"union" => |us| {
            for (us) |v| if (!variantCovered(v, covers)) return false;

            return true;
        },

        .bool => {
            var saw_true = false;
            var saw_false = false;

            for (covers) |c| switch (c) {
                .atom => |name| {
                    const bare = cst.atomName(name);
                    if (std.mem.eql(u8, bare, "true")) saw_true = true;
                    if (std.mem.eql(u8, bare, "false")) saw_false = true;
                },
                else => {},
            };

            return saw_true and saw_false;
        },

        .table, .atom => {
            for (covers) |c| if (coversOne(subject, c)) return true;

            return false;
        },

        else => return false,
    }
}

/// one union variant meets some cover
/// , plain atoms need atom, tables need shape hit, else fitting `x: T`
fn variantCovered(variant: UnionVariant, covers: []const MatchCover) bool {
    for (covers) |c| switch (c) {
        .atom => |name| if (unionVariantTagEql(variant, name)) return true,
        .ascribed => |ti| if (targetAcceptsVariant(variant, ti)) return true,
        .table => |elems| if (variantHits(elems, variant)) return true,
        else => {},
    };

    return false;
}

/// some value of subject could meet cover
/// , unknown shapes stay reachable, never proven dead
/// , elems recurse here, so one check covers all depths
pub fn matchOverlaps(subject: TypeInfo, cover: MatchCover) bool {
    switch (cover) {
        .wildcard, .other => return true,
        .table => |elems| return tableMeets(elems, subject),

        .ascribed => |ti| switch (subject.tag) {
            .@"union" => |us| {
                for (us) |v| if (targetAcceptsVariant(v, ti)) return true;
                return false;
            },
            .any, .type_var => return true,
            else => return canCoerce(subject, ti),
        },

        .atom => |name| switch (subject.tag) {
            .any, .type_var => return true,
            .@"union" => |us| {
                for (us) |v| if (unionVariantTagEql(v, name)) return true;
                return false;
            },
            .bool => {
                const bare = cst.atomName(name);
                return std.mem.eql(u8, bare, "true") or std.mem.eql(u8, bare, "false");
            },
            .atom => |s| return std.mem.eql(u8, cst.atomName(s), cst.atomName(name)),
            else => return false,
        },

        .number => switch (subject.tag) {
            .number, .any, .type_var => return true,
            .@"union" => |us| {
                for (us) |v| if (targetAcceptsVariant(v, .{ .tag = .number })) return true;
                return false;
            },
            else => return false,
        },

        .string => switch (subject.tag) {
            .string, .any, .type_var => return true,
            .@"union" => |us| {
                for (us) |v| if (targetAcceptsVariant(v, .{ .tag = .string })) return true;
                return false;
            },
            else => return false,
        },
    }
}

/// table elems could meet subject
/// , any stays reachable, never stays dead
/// , unions need one variant met, other shapes never meet tables
fn tableMeets(elems: []const MatchCover, subject: TypeInfo) bool {
    switch (subject.tag) {
        .any, .type_var => return true,
        .never => return false,
        .table => |tbl| return tableMeetsFields(elems, tbl.fields),

        .@"union" => |us| {
            for (us) |v| if (variantMeets(elems, v)) return true;
            return false;
        },

        else => return false,
    }
}

/// table elems could meet fields
/// , unknown length stays reachable
/// , known length needs same count and every element meets
fn tableMeetsFields(elems: []const MatchCover, fields: ?[]const RecordField) bool {
    const want = tableArrayLen(fields) orelse return true;
    if (want != elems.len) return false;

    const fs = fields.?;
    for (elems, 0..) |e, i| {
        const et = tableElemType(fs, i) orelse return true;
        if (!matchOverlaps(et, e)) return false;
    }

    return true;
}

/// table elems could meet one variant
/// , plain atoms never meet tables, other shapes stay reachable
fn variantMeets(elems: []const MatchCover, variant: UnionVariant) bool {
    if (variant.types.len == 0) return true;

    const inner = variant.types[0];
    if (inner.tag == .atom) return false;
    if (inner.tag == .table) return tableMeetsFields(elems, inner.tag.table.fields);

    return true;
}

/// union result with a :nil miss arm
///
/// non-exhaustive match falls to nil at runtime, so :nil joins the type
/// `any` stays `any`, `never` becomes just :nil
/// low memory keeps result
pub fn withNilMiss(alloc: std.mem.Allocator, result: TypeInfo) TypeInfo {
    if (result.tag == .any) return result;
    if (result.tag == .never) return .{ .tag = .{ .atom = ":nil" } };

    var variants = std.ArrayList(UnionVariant).initCapacity(alloc, 4) catch return result;
    errdefer variants.deinit(alloc);

    collectVariants(alloc, result, &variants) catch return result;
    const nil_types = alloc.alloc(TypeInfo, 1) catch return result;

    nil_types[0] = .{ .tag = .{ .atom = ":nil" } };
    variants.append(alloc, .{ .name = "", .types = nil_types }) catch return result;

    const owned = variants.toOwnedSlice(alloc) catch return result;
    return .{ .tag = .{ .@"union" = owned } };
}

/// bare names of uncovered union variants, for warnings
/// , borrows subject, empty when none nameable
pub fn uncoveredTags(alloc: std.mem.Allocator, subject: TypeInfo, covers: []const MatchCover, out: *std.ArrayList([]const u8)) !void {
    switch (subject.tag) {
        .@"union" => |us| {
            for (us) |v| {
                if (v.types.len == 0) continue;
                if (variantCovered(v, covers)) continue;

                if (v.types[0].tag == .atom) {
                    try out.append(alloc, cst.atomName(v.types[0].tag.atom));
                } else if (v.types[0].tag == .table) {
                    const fields = v.types[0].tag.table.fields orelse continue;
                    const alen = tableArrayLen(fields) orelse continue;
                    if (alen == 0) continue;

                    const et = tableElemType(fields, 0) orelse continue;
                    if (et.tag != .atom) continue;

                    try out.append(alloc, cst.atomName(et.tag.atom));
                }
            }
        },

        .bool => {
            var saw_true = false;
            var saw_false = false;

            for (covers) |c| switch (c) {
                .atom => |name| {
                    const bare = cst.atomName(name);
                    if (std.mem.eql(u8, bare, "true")) saw_true = true;
                    if (std.mem.eql(u8, bare, "false")) saw_false = true;
                },
                else => {},
            };

            if (!saw_true) try out.append(alloc, "true");
            if (!saw_false) try out.append(alloc, "false");
        },

        .atom => |name| {
            for (covers) |c| switch (c) {
                .atom => |cover| {
                    if (std.mem.eql(u8, cst.atomName(cover), cst.atomName(name))) return;
                },
                else => {},
            };

            try out.append(alloc, cst.atomName(name));
        },

        else => {},
    }
}

/// source pattern covering one uncovered tag
/// , `:tag` for plain atoms and bools
/// , `{:tag, _, ...}` for tuple variants
/// , null when the shape is not nameable and `_` must cover it
/// , tags are plain names as returned by uncoveredTags
/// , caller owns the returned slice
pub fn suggestArmPattern(alloc: std.mem.Allocator, subject: TypeInfo, tag: []const u8) !?[]const u8 {
    switch (subject.tag) {
        .@"union" => |us| {
            for (us) |v| {
                if (!unionVariantTagEql(v, tag)) continue;
                if (v.types.len == 0) return null;

                if (v.types[0].tag == .atom) {
                    return try alloc.print(":{s}", .{tag});
                }

                if (v.types[0].tag == .table) {
                    const fields = v.types[0].tag.table.fields orelse return null;
                    const alen = tableArrayLen(fields) orelse return null;
                    if (alen == 0) return null;

                    // positional only, named shapes fall back to `_`
                    if (fields.len != alen) return null;
                    if (alen == 1) return try alloc.print("{{:{s}}}", .{tag});

                    var buf = try std.ArrayList(u8).initCapacity(alloc, 8 + alen * 3);
                    errdefer buf.deinit(alloc);

                    try buf.appendSlice(alloc, "{:");
                    try buf.appendSlice(alloc, tag);

                    for (0..alen - 1) |_| try buf.appendSlice(alloc, ", _");

                    try buf.append(alloc, '}');
                    return try buf.toOwnedSlice(alloc);
                }

                return null;
            }

            return null;
        },

        .bool => return try alloc.print(":{s}", .{tag}),
        .atom => return try alloc.print(":{s}", .{tag}),

        else => return null,
    }
}

/// source pattern covering a concrete table subject
/// , `{_, _, ...}` with one `_` per array element, `{}` for empty
/// , null when the shape is unknown and `_` must cover it
/// , caller owns the returned slice
pub fn suggestTablePattern(alloc: std.mem.Allocator, subject: TypeInfo) !?[]const u8 {
    if (subject.tag != .table) return null;

    const alen = tableArrayLen(subject.tag.table.fields) orelse return null;
    if (alen == 0) return try alloc.dupe(u8, "{}");

    var buf = try std.ArrayList(u8).initCapacity(alloc, 2 + alen * 3);
    errdefer buf.deinit(alloc);
    try buf.append(alloc, '{');

    for (0..alen) |i| {
        if (i > 0) try buf.appendSlice(alloc, ", ");
        try buf.append(alloc, '_');
    }

    try buf.append(alloc, '}');
    return try buf.toOwnedSlice(alloc);
}

test matchCoversAll {
    // wildcard and never
    try std.testing.expect(matchCoversAll(.{ .tag = .never }, &.{}));
    try std.testing.expect(matchCoversAll(.{ .tag = .number }, &.{.wildcard}));
    try std.testing.expect(!matchCoversAll(.{ .tag = .number }, &.{}));
    try std.testing.expect(!matchCoversAll(.{ .tag = .number }, &.{.other}));
    try std.testing.expect(matchCoversAll(.{ .tag = .any }, &.{.wildcard}));
    try std.testing.expect(!matchCoversAll(.{ .tag = .any }, &.{.other}));

    // atom union needs every tag
    const ok: TypeInfo = .{ .tag = .{ .atom = ":ok" } };
    const err: TypeInfo = .{ .tag = .{ .atom = ":err" } };
    const ok_types = [_]TypeInfo{ok};
    const err_types = [_]TypeInfo{err};
    const variants = [_]UnionVariant{
        .{ .name = "", .types = &ok_types },
        .{ .name = "", .types = &err_types },
    };
    const subject: TypeInfo = .{ .tag = .{ .@"union" = &variants } };
    try std.testing.expect(matchCoversAll(subject, &.{
        .{ .atom = ":ok" },
        .{ .atom = ":err" },
    }));
    try std.testing.expect(!matchCoversAll(subject, &.{.{ .atom = ":ok" }}));
    try std.testing.expect(matchCoversAll(subject, &.{.wildcard}));
    //
    // bool and single atom
    try std.testing.expect(matchCoversAll(.{ .tag = .bool }, &.{
        .{ .atom = ":true" },
        .{ .atom = ":false" },
    }));
    try std.testing.expect(!matchCoversAll(.{ .tag = .bool }, &.{.{ .atom = ":true" }}));
    try std.testing.expect(matchCoversAll(
        .{ .tag = .{ .atom = ":ok" } },
        &.{.{ .atom = ":ok" }},
    ));
    try std.testing.expect(!matchCoversAll(
        .{ .tag = .{ .atom = ":ok" } },
        &.{.{ .atom = ":err" }},
    ));
    //
    // ascribed covers when subject fits
    try std.testing.expect(matchCoversAll(
        .{ .tag = .number },
        &.{.{ .ascribed = .{ .tag = .number } }},
    ));
    try std.testing.expect(matchCoversAll(
        .{ .tag = .number },
        &.{.{ .ascribed = .{ .tag = .any } }},
    ));
    try std.testing.expect(!matchCoversAll(
        .{ .tag = .number },
        &.{.{ .ascribed = .{ .tag = .string } }},
    ));
    //
    // tables need one shape hit, same length and every element hits
    const num_ti: TypeInfo = .{ .tag = .number };
    const ok_ti: TypeInfo = .{ .tag = .{ .atom = ":ok" } };
    const pair_fields = [_]RecordField{
        .{ .name = "0", .field_type = num_ti },
        .{ .name = "1", .field_type = ok_ti },
    };
    const pair: TypeInfo = .{ .tag = .{ .table = .{ .key = null, .value = &ANY_TI, .fields = &pair_fields } } };
    const pair_elems = [_]MatchCover{ .wildcard, .{ .atom = ":ok" } };
    try std.testing.expect(matchCoversAll(pair, &.{.{ .table = &pair_elems }}));

    // literal never covers its domain
    const lit_elems = [_]MatchCover{ .number, .{ .atom = ":ok" } };
    try std.testing.expect(!matchCoversAll(pair, &.{.{ .table = &lit_elems }}));

    // length mismatch never covers
    const short_elems = [_]MatchCover{.wildcard};
    try std.testing.expect(!matchCoversAll(pair, &.{.{ .table = &short_elems }}));

    // single binder covers a single table
    const one_fields = [_]RecordField{
        .{ .name = "0", .field_type = ok_ti },
    };
    const one: TypeInfo = .{ .tag = .{ .table = .{ .key = null, .value = &ANY_TI, .fields = &one_fields } } };
    try std.testing.expect(matchCoversAll(one, &.{.{ .table = &short_elems }}));
}

test "types: TypeInfo equality" {
    const int_type: TypeInfo = .{ .tag = .number };
    const any_type: TypeInfo = .{ .tag = .any };

    try std.testing.expect(int_type.eql(.{ .tag = .number }));
    try std.testing.expect(any_type.eql(.{ .tag = .any }));
}

test "types: table interning dedups exact shapes only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = TypeTable.init(arena.allocator());
    defer table.deinit();

    const n1 = try table.intern(.{ .tag = .number });
    const n2 = try table.intern(.{ .tag = .number });
    try std.testing.expectEqual(n1, n2);

    const s = try table.intern(.{ .tag = .string });
    try std.testing.expect(n1 != s);

    // subtyping eql is not interning identity: any stays its own id
    const a = try table.intern(.{ .tag = .any });
    try std.testing.expect(a != n1);
    try std.testing.expect(eqlExact(table.get(a), .{ .tag = .any }));

    // same spelling twice shares one entry, table owns the copy
    const name = try arena.allocator().dupe(u8, "ok");
    const at1 = try table.intern(.{ .tag = .{ .atom = name } });
    const at2 = try table.intern(.{ .tag = .{ .atom = "ok" } });
    try std.testing.expectEqual(at1, at2);
    try std.testing.expectEqualStrings("ok", table.get(at1).tag.atom);
}

test "types: numeric type check" {
    try std.testing.expect(.{ .tag = .number }.tag == .number);
    try std.testing.expect(.{ .tag = .string }.tag != .number);
    try std.testing.expect(.{ .tag = .any }.tag != .number);
}

test "types: type coercion" {
    try std.testing.expect(canCoerce(.{ .tag = .number }, .{ .tag = .number }));
    try std.testing.expect(!canCoerce(.{ .tag = .string }, .{ .tag = .number }));
    try std.testing.expect(canCoerce(.{ .tag = .number }, .{ .tag = .any })); // anything to any
    try std.testing.expect(canCoerce(.{ .tag = .any }, .{ .tag = .number })); // any to anything (optimistic)
}

test "types: binary op inference - arithmetic" {
    const add = inferBinaryOp(.add, .{ .tag = .number }, .{ .tag = .number });
    try std.testing.expect(add.eql(.{ .tag = .number }));
}

test "types: binary op inference - comparison" {
    const cmp = inferBinaryOp(.eq, .{ .tag = .number }, .{ .tag = .number });
    try std.testing.expect(cmp.eql(.{ .tag = .bool }));

    const cmp2 = inferBinaryOp(.lt, .{ .tag = .number }, .{ .tag = .number });
    try std.testing.expect(cmp2.eql(.{ .tag = .bool }));
}

test "types: empty atom sentinel coercion" {
    const empty_atom: TypeInfo = .{ .tag = .{ .atom = "" } };
    const named_atom: TypeInfo = .{ .tag = .{ .atom = ":foo" } };
    try std.testing.expect(canCoerce(empty_atom, named_atom));
    try std.testing.expect(canCoerce(named_atom, empty_atom));
    try std.testing.expect(canCoerce(empty_atom, empty_atom));
}

test "types: unary op inference" {
    const negate_int = inferUnaryOp(.negate, .{ .tag = .number });
    try std.testing.expect(negate_int.eql(.{ .tag = .number }));

    const not_bool = inferUnaryOp(.not, .{ .tag = .bool });
    try std.testing.expect(not_bool.eql(.{ .tag = .bool }));
}
