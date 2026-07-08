const std = @import("std");

const revo = @import("revo");
const Data = revo.Data;
const Compiler = revo.lang.compiler.Compiler;

const ast = @import("../ast.zig");
const Node = ast.Node;
const TableEntry = ast.TableEntry;
const StructItem = ast.StructItem;
const flow = @import("flow.zig");
const state = @import("state.zig");
const toRegister = state.toRegister;
const type_check = @import("type_check.zig");
const types_mod = @import("types.zig");

pub const BindingKind = enum { global, let, con };

pub fn compileLocalBinding(
    self: *Compiler,
    name: []const u8,
    value: *const Node,
    mutable: bool,
    type_name: ?*ast.TypeExpr,
) !void {
    if (ast.isDiscardName(name)) {} else if (std.mem.findAny(u8, name[0..name.len -| 1], "!?")) |_|
        return self.setFailureParts(
            .ParseError,
            .{ .span = value.span, .role = .primary, .message = name },
            "! and ? are only allowed at the end of names",
            &.{},
        )
    else if (std.mem.endsWith(u8, name, "!"))
        return self.setFailureParts(
            .ParseError,
            .{ .span = value.span, .role = .primary, .message = name },
            "name with ! is reserved for macros",
            &.{},
        )
    else if (!ast.isDiscardName(name))
        if (state.currentFunctionState(self)) |fn_state|
            for (fn_state.import_locals.items) |il|
                if (std.mem.eql(u8, il.name, name))
                    return self.setFailureParts(
                        .ParseError,
                        .{ .span = value.span, .role = .primary, .message = name },
                        "name conflicts with an import",
                        &.{},
                    );
    // fn slots can be reused if not initialized
    const slot = if (value.expr == .fn_expr)
        try state.reuseOrDeclareLocal(self, name, mutable)
    else
        try state.declareLocal(self, name, mutable);

    state.reserveLocalSlots(self);

    if (value.expr == .fn_expr) {
        try self.compileFn(
            value.expr.fn_expr.params,
            value.expr.fn_expr.return_type,
            value.expr.fn_expr.body,
            name,
            null,
            value.expr.fn_expr.type_params,
        );
    } else {
        try self.compile(value, true);
    }

    state.markLocalInitialized(self, slot);
    state.markLocalValueKind(
        self,
        slot,
        if (value.expr == .tuple) .tuple_literal else .unknown,
    );
    try syncLocalTableFields(self, slot, value);

    const inferred_type = if (type_name) |tn|
        try types_mod.evalTypeExpr(self, tn)
    else
        type_check.inferExprType(self, value);

    try state.setLocalTypeHint(self, name, inferred_type);
    if (type_name != null) {
        if (type_check.storedTypeName(self, inferred_type)) |stored_name|
            state.setLocalType(self, slot, stored_name);
        state.setLocalTypeExplicit(self, slot);
    }

    try self.regDupe();
    try self.emit(.bind_local, slot);
}

pub fn bindDeclaredPattern(
    self: *Compiler,
    pattern: *const Node,
    source_idx: usize,
    kind: BindingKind,
) !void {
    switch (pattern.expr) {
        .ident => |name| {
            if (ast.isDiscardName(name)) return;
            const mv_dst = try state.pushRegister(self);
            try self.spans.append(self.alloc, self.active_span);
            _ = try self.record(.move, &.{.{ .reg = try toRegister(source_idx) }}, true, mv_dst, 0);
            const slot = try state.reuseOrDeclareLocal(self, name, kind != .con);
            state.markLocalInitialized(self, slot);
            try self.emit(.bind_local, slot);
            state.reserveLocalSlots(self);
        },
        .tuple_pattern => |items| {
            for (items, 0..) |item, idx| {
                const mv_dst = try state.pushRegister(self);
                try self.spans.append(self.alloc, self.active_span);
                _ = try self.record(.move, &.{.{ .reg = try toRegister(source_idx) }}, true, mv_dst, 0);
                try self.emit(.tuple_get_const, idx);
                try bindDeclaredPattern(self, item, self.active_registers - 1, kind);
            }
        },
        else => {},
    }
}

pub fn declarePatternLocals(
    self: *Compiler,
    pattern: *const Node,
    mutable: bool,
) !void {
    switch (pattern.expr) {
        .ident => |name| {
            if (ast.isDiscardName(name)) return;
            _ = try state.reuseOrDeclareLocal(self, name, mutable);
            state.reserveLocalSlots(self);
        },
        .tuple_pattern => |items| {
            for (items) |item| {
                try declarePatternLocals(self, item, mutable);
            }
        },
        else => {},
    }
}

pub fn bindPattern(
    self: *Compiler,
    pattern: *const Node,
    source_idx: usize,
    kind: BindingKind,
) !void {
    switch (pattern.expr) {
        .ident => |name| {
            if (ast.isDiscardName(name)) return;
            const mv_dst = try state.pushRegister(self);
            try self.spans.append(self.alloc, self.active_span);
            _ = try self.record(.move, &.{.{ .reg = try toRegister(source_idx) }}, true, mv_dst, 0);
            try self.emit(
                if (kind == .con) .store_global_const else .store_global,
                try self.vm.internAtom(name),
            );
        },
        .tuple_pattern => |items| {
            const is_mutable = kind != .con;
            for (items, 0..) |item, idx| {
                switch (item.expr) {
                    .ident => |name| {
                        if (ast.isDiscardName(name)) continue;
                        const mv_dst2 = try state.pushRegister(self);
                        try self.spans.append(self.alloc, self.active_span);
                        _ = try self.record(.move, &.{.{ .reg = try toRegister(source_idx) }}, true, mv_dst2, 0);
                        try self.emit(.tuple_get_const, idx);
                        try self.emit(
                            if (is_mutable) .store_global else .store_global_const,
                            try self.vm.internAtom(name),
                        );
                    },
                    .tuple_pattern => {
                        const mv_dst2 = try state.pushRegister(self);
                        try self.spans.append(self.alloc, self.active_span);
                        _ = try self.record(.move, &.{.{ .reg = try toRegister(source_idx) }}, true, mv_dst2, 0);
                        try self.emit(.tuple_get_const, idx);
                        try bindPattern(self, item, self.active_registers - 1, kind);
                    },
                    else => {},
                }
            }
        },
        else => {},
    }
}

pub fn compileAssign(
    self: *Compiler,
    target: *const Node,
    value: *const Node,
) !void {
    if (target.expr == .tuple_pattern) {
        try validateTuplePatternShape(
            self,
            target.expr.tuple_pattern,
            value,
            "assignment",
        );
        try self.compile(value, true);
        const src_idx = self.active_registers - 1;
        return bindPattern(self, target, src_idx, .let);
    }
    return compileAssignSimple(self, target, value);
}

pub fn validateTuplePatternShape(
    self: *Compiler,
    pattern: []*Node,
    value: *const Node,
    context: []const u8,
) !void {
    if (value.expr != .tuple) return;
    // allow extra but not fewer
    if (value.expr.tuple.len >= pattern.len) return;
    const msg = try std.fmt.allocPrint(
        self.alloc,
        "tuple {s} expects at least {d} items, got {d}",
        .{ context, pattern.len, value.expr.tuple.len },
    );
    return self.fail(.ParseError, value, msg);
}

fn compileAssignSimple(
    self: *Compiler,
    target: *const Node,
    value: *const Node,
) !void {
    switch (target.expr) {
        .ident => |name| {
            try self.compile(value, true);
            try self.regDupe();
            if (state.resolveLocal(self, name)) |slot| {
                try self.emit(.store_local, slot);
                state.markLocalValueKind(self, slot, .unknown);
                try syncLocalTableFields(self, slot, value);
                const inferred_type = type_check.inferExprType(self, value);
                try state.setLocalTypeHint(self, name, inferred_type);
            } else if (try state.resolveUpvalue(self, name)) |slot| {
                try self.emit(.store_upval, slot);
            } else {
                if (self.functions.items.len == 1) {
                    const atom = try self.vm.internAtom(name);
                    const known = self.declared_globals.contains(name) or
                        self.vm.stdlib_globals.contains(atom) or
                        self.vm.globals.contains(atom) or
                        self.vm.const_globals.contains(atom);
                    if (!known) {
                        const msg = try std.fmt.allocPrint(
                            self.alloc,
                            "assignment target `{s}` is not declared",
                            .{name},
                        );
                        return self.fail(.InvalidAssignmentTarget, target, msg);
                    }
                    try self.emit(.store_global, atom);
                } else {
                    const msg = try std.fmt.allocPrint(
                        self.alloc,
                        "assignment target `{s}` is not declared",
                        .{name},
                    );
                    return self.fail(.InvalidAssignmentTarget, target, msg);
                }
            }
        },
        .field => |field| {
            const object_type = type_check.inferExprType(self, field.object);
            switch (object_type) {
                .struct_type => |type_name| {
                    const type_id = self.vm.struct_types.findTypeByName(type_name) orelse {
                        // fallback to table set if struct not found
                        try compileFieldAssign(self, field.object, field.name, value);
                        return;
                    };
                    const desc = self.vm.struct_types.getType(type_id) orelse {
                        try compileFieldAssign(self, field.object, field.name, value);
                        return;
                    };
                    const field_atom = try self.vm.internAtom(field.name);
                    const field_offset = desc.fieldIndex(field_atom) orelse {
                        try compileFieldAssign(self, field.object, field.name, value);
                        return;
                    };

                    try self.compile(field.object, true);
                    try self.compile(value, true);
                    try self.emit(.struct_set_offset, @intCast(field_offset));
                    try self.regRelease();
                },
                else => {
                    // table field access: set field, return value as expression result
                    const key_atom = try self.vm.internAtom(field.name);
                    try self.compile(field.object, true);
                    try self.regDupe();
                    try self.compile(value, true);
                    try self.emit(.table_set_atom, key_atom);
                    try self.emit(.table_get_atom, key_atom);
                    try addFieldToLocalTableFields(self, field.object, field.name);
                },
            }
        },
        .index => |index| {
            try self.compile(index.object, true);
            if (index.key.expr == .hash) {
                const key_atom = try self.vm.internAtom(index.key.expr.hash);
                try self.regDupe();
                try self.compile(value, true);
                try self.emit(.table_set_atom, key_atom);
                try self.emit(.table_get_atom, key_atom);
                try addFieldToLocalTableFields(self, index.object, index.key.expr.hash);
            } else {
                try self.compile(index.key, true);
                try self.compile(value, true);
                try self.emit(.table_set, 0);
                try self.regRelease();
            }
        },
        else => {
            const msg = try std.fmt.allocPrint(
                self.alloc,
                "bad assignment target: {}",
                .{target.*},
            );
            return self.fail(.InvalidAssignmentTarget, target, msg);
        },
    }
}

fn addFieldToLocalTableFields(self: *Compiler, object: *const Node, field_name: []const u8) !void {
    if (object.expr != .ident) return;
    const name = object.expr.ident;
    const local = state.resolveLocalVar(self, name) orelse return;
    if (local.table_fields) |fields| {
        for (fields) |f| if (std.mem.eql(u8, f, field_name)) return;
    }
    const field_dup = try self.alloc.dupe(u8, field_name);
    const old = local.table_fields orelse &[_][]const u8{};
    const new_fields = try self.alloc.alloc([]const u8, old.len + 1);
    @memcpy(new_fields[0..old.len], old);
    new_fields[old.len] = field_dup;
    state.setLocalTableFields(self, local.slot, new_fields);
}

fn applyLocalTableFields(
    self: *Compiler,
    slot: revo.LocalSlot,
    entries: []const TableEntry,
) !void {
    var fields = try std.ArrayList([]const u8).initCapacity(
        self.alloc,
        entries.len,
    );
    defer fields.deinit(self.alloc);

    for (entries) |entry| {
        if (entry.computed or entry.key == null) continue;
        if (entry.key) |key| switch (key.expr) {
            .ident => |name| try fields.append(self.alloc, name),
            .hash => |name| try fields.append(self.alloc, name),
            else => {},
        };
    }

    if (fields.items.len == 0) {
        state.setLocalTableFields(self, slot, null);
        return;
    }
    state.setLocalTableFields(
        self,
        slot,
        try fields.toOwnedSlice(self.alloc),
    );
}

fn syncLocalTableFields(
    self: *Compiler,
    slot: revo.LocalSlot,
    value: *const Node,
) !void {
    switch (value.expr) {
        .table => try applyLocalTableFields(self, slot, value.expr.table),
        .ident => |name| {
            const source = state.resolveLocalVar(self, name) orelse {
                state.setLocalTableFields(self, slot, null);
                return;
            };
            state.setLocalTableFields(self, slot, source.table_fields);
        },
        else => state.setLocalTableFields(self, slot, null),
    }
}

fn compileFieldAssign(
    self: *Compiler,
    field_obj: *const Node,
    field_name: []const u8,
    value: *const Node,
) !void {
    const key_atom = try self.vm.internAtom(field_name);
    try self.compile(field_obj, true);
    try self.regDupe();
    try self.compile(value, true);
    try self.emit(.table_set_atom, key_atom);
    try self.emit(.table_get_atom, key_atom);
    try addFieldToLocalTableFields(self, field_obj, field_name);
}

pub fn compileStruct(
    self: *Compiler,
    expr: *const Node,
    name: []const u8,
    items: []const StructItem,
) !void {
    var field_defs = try std.ArrayList(types_mod.FieldDef).initCapacity(
        self.alloc,
        items.len,
    );
    defer field_defs.deinit(self.alloc);

    var seen = std.StringHashMap(bool).init(self.alloc);
    defer seen.deinit();

    for (items) |item| {
        if (item == .field) {
            const fname = item.field.name;
            if (seen.get(fname) != null) {
                const msg = try std.fmt.allocPrint(
                    self.alloc,
                    "duplicate field `{s}` in struct `{s}`",
                    .{ fname, name },
                );
                var tmp_node: Node = .{
                    .span = item.field.name_span,
                    .expr = .nil,
                };
                return self.fail(.ParseError, &tmp_node, msg);
            } else {
                try seen.put(fname, true);
                const field_type: types_mod.TypeInfo = if (item.field.type_name) |tn|
                    try types_mod.evalTypeExpr(self, tn)
                else
                    types_mod.TypeInfo.any;
                try field_defs.append(self.alloc, .{
                    .name = item.field.name,
                    .field_type = field_type,
                    .type_name = if (item.field.type_name) |tn| switch (tn.kind) {
                        .named => |n| n,
                        else => types_mod.typeName(field_type),
                    } else null,
                    .default_val = if (item.field.default_value) |dv|
                        evalConstNode(self, dv)
                    else
                        null,
                });
            }
        }
    }

    const field_slice = try field_defs.toOwnedSlice(self.alloc);
    errdefer self.alloc.free(field_slice);

    if (self.struct_layouts.fetchRemove(name)) |kv| self.alloc.free(kv.value);
    try self.struct_layouts.put(name, field_slice);

    const type_id = if (field_slice.len > 0) blk: {
        var fields = try std.ArrayList(revo.vm.struct_mod.StructField).initCapacity(self.alloc, field_slice.len);
        defer fields.deinit(self.alloc);
        for (field_slice) |d| {
            const type_atom: ?revo.AtomID = if (d.type_name) |tn|
                try self.vm.internAtom(tn)
            else if (d.field_type != .any)
                try self.vm.internAtom(types_mod.typeName(d.field_type))
            else
                null;
            try fields.append(self.alloc, .{
                .name_atom = try self.vm.internAtom(d.name),
                .type_atom = type_atom,
                .default_val = d.default_val,
            });
        }
        break :blk try self.vm.struct_types.registerType(name, fields.items, std.StringHashMap(revo.memory.Data).init(self.vm.runtime.alloc));
    } else try self.vm.struct_types.registerType(name, &.{}, std.StringHashMap(revo.memory.Data).init(self.vm.runtime.alloc));

    // bind the .struct_type constant to the struct name
    const slot = try state.reuseOrDeclareLocal(self, name, false);
    state.reserveLocalSlots(self);
    try self.@"const"(Data.new.structType(type_id));
    state.markLocalInitialized(self, slot);
    try self.regDupe();
    try self.emit(.bind_local, slot);

    // compile meth binds & store in pool via rt calls
    for (items) |item| switch (item) {
        .binding => |b| {
            if (b.target.expr != .ident) {
                const msg = try std.fmt.allocPrint(
                    self.alloc,
                    "assignment target must be named: {}",
                    .{b.target.*},
                );
                return self.fail(.UnsupportedSyntax, expr, msg);
            }
            const key_atom = try self.vm.internAtom(b.target.expr.ident);
            try flow.emitStorageLoad(self, .{ .local = slot });
            try self.@"const"(Data.new.atom(key_atom));
            if (b.value.expr == .fn_expr)
                try self.compileFn(
                    b.value.expr.fn_expr.params,
                    b.value.expr.fn_expr.return_type,
                    b.value.expr.fn_expr.body,
                    b.target.expr.ident,
                    null,
                    b.value.expr.fn_expr.type_params,
                )
            else
                try self.compile(b.value, true);
            try self.emit(.struct_set_method, 0);
            try self.regRelease();
        },
        .field => {},
    };

    if (state.currentFunctionState(self) != null)
        try state.setLocalTypeHint(self, name, .{ .struct_type = name });
}

pub fn compileTable(self: *Compiler, entries: []const ast.TableEntry) !void {
    try self.emit(.table_new, 0);
    var array_index: i64 = 0;
    for (entries) |entry| {
        try self.regDupe();
        if (entry.key) |key| {
            if (!entry.computed) switch (key.expr) {
                .ident => |name| {
                    try self.compile(entry.value, true);
                    try self.emit(
                        .table_set_atom,
                        try self.vm.internAtom(name),
                    );
                    try self.regRelease();
                    continue;
                },
                .hash => |name| {
                    try self.compile(entry.value, true);
                    try self.emit(
                        .table_set_atom,
                        try self.vm.internAtom(name),
                    );
                    try self.regRelease();
                    continue;
                },
                else => {},
            };
            try self.compile(key, true);
        } else {
            // array index key
            try self.@"const"(Data.new.num(array_index));
            array_index += 1;
        }
        try self.compile(entry.value, true);
        try self.emit(.table_set, 0);
        try self.regRelease();
    }
}

fn evalConstNode(self: *Compiler, node: *const Node) ?Data {
    switch (node.expr) {
        .number => |n| return Data.new.num(n.value),
        .string => |s| return self.vm.ownDataString(s) catch return null,
        .multiline_string => |s| return self.vm.ownDataString(s) catch return null,
        .hash => |h| return self.vm.dataAtom(h) catch return null,
        .nil => return revo.Data.new.core(.nil),
        .table => |entries| {
            const t_id = self.vm.tables.create() catch return null;
            const table = self.vm.tables.get(t_id) catch return null;
            var array_index: i64 = 0;
            for (entries) |entry| {
                if (entry.key) |key| {
                    const key_val = evalConstNode(self, key) orelse return null;
                    const val = evalConstNode(self, entry.value) orelse return null;
                    table.putRaw(key_val, val) catch return null;
                } else {
                    const val = evalConstNode(self, entry.value) orelse return null;
                    table.putRaw(Data.new.num(@as(f64, @floatFromInt(array_index))), val) catch return null;
                    array_index += 1;
                }
            }
            return Data.new.table(t_id);
        },
        else => return null,
    }
}
