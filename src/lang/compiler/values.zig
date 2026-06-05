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
    if (ast.isDiscardName(name)) {} else if (std.mem.endsWith(u8, name, "!"))
        return self.setFailureParts(
            .ParseError,
            .{ .span = value.span, .role = .primary, .message = name },
            "name with ! is reserved for macros",
            &.{},
        )
    else if (std.mem.endsWith(u8, name, "?") and value.expr != .fn_expr)
        return self.setFailureParts(
            .ParseError,
            .{ .span = value.span, .role = .primary, .message = name },
            "name with ? is reserved for functions returning bool",
            &.{},
        );
    // type check before alloc
    if (type_name) |tn| {
        type_check.validateBindingType(self, tn, value) catch |err| switch (err) {
            error.TypeError => {
                const actual = type_check.inferExprType(self, value);
                const expected_type = try types_mod.evalTypeExpr(self, tn);
                const tn_str = try types_mod.formatType(self.alloc, expected_type);
                const msg = try std.fmt.allocPrint(
                    self.alloc,
                    "`{s}` wants {s}, got {s}",
                    .{ name, tn_str, types_mod.typeName(actual) },
                );
                const label = try std.fmt.allocPrint(
                    self.alloc,
                    "not {s}!",
                    .{tn_str},
                );
                self.alloc.free(tn_str);
                return self.setFailureParts(
                    .ParseError,
                    .{
                        .span = value.span,
                        .role = .primary,
                        .message = label,
                    },
                    msg,
                    &.{},
                );
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

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
            const mv_dst = try toRegister(self.active_registers);
            try self.spans.append(self.alloc, self.active_span);
            _ = try self.record(.move, &.{.{ .reg = try toRegister(source_idx) }}, true, mv_dst, 0);
            self.active_registers += 1;
            const slot = try state.reuseOrDeclareLocal(self, name, kind != .con);
            state.markLocalInitialized(self, slot);
            try self.emit(.bind_local, slot);
            state.reserveLocalSlots(self);
        },
        .tuple_pattern => |items| {
            for (items, 0..) |item, idx| {
                const mv_dst = try toRegister(self.active_registers);
                try self.spans.append(self.alloc, self.active_span);
                _ = try self.record(.move, &.{.{ .reg = try toRegister(source_idx) }}, true, mv_dst, 0);
                self.active_registers += 1;
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
            const mv_dst = try toRegister(self.active_registers);
            try self.spans.append(self.alloc, self.active_span);
            _ = try self.record(.move, &.{.{ .reg = try toRegister(source_idx) }}, true, mv_dst, 0);
            self.active_registers += 1;
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
                        const mv_dst2 = try toRegister(self.active_registers);
                        try self.spans.append(self.alloc, self.active_span);
                        _ = try self.record(.move, &.{.{ .reg = try toRegister(source_idx) }}, true, mv_dst2, 0);
                        self.active_registers += 1;
                        try self.emit(.tuple_get_const, idx);
                        try self.emit(
                            if (is_mutable) .store_global else .store_global_const,
                            try self.vm.internAtom(name),
                        );
                    },
                    .tuple_pattern => {
                        const mv_dst2 = try toRegister(self.active_registers);
                        try self.spans.append(self.alloc, self.active_span);
                        _ = try self.record(.move, &.{.{ .reg = try toRegister(source_idx) }}, true, mv_dst2, 0);
                        self.active_registers += 1;
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

                type_check.validateAssignmentType(self, target, value) catch |err| switch (err) {
                    error.TypeError => {
                        const loc = state.resolveLocalVar(self, name) orelse unreachable;
                        const type_name = loc.type_name orelse unreachable;
                        const actual = type_check.inferExprType(self, value);
                        const msg = try std.fmt.allocPrint(
                            self.alloc,
                            "`{s}` wants {s}, got {s}",
                            .{ name, type_name, types_mod.typeName(actual) },
                        );
                        return self.setFailureParts(
                            .ParseError,
                            .{
                                .span = value.span,
                                .role = .primary,
                                .message = try std.fmt.allocPrint(self.alloc, "not {s}!", .{type_name}),
                            },
                            msg,
                            &.{},
                        );
                    },
                };

                try state.setLocalTypeHint(self, name, inferred_type);
            } else if (try state.resolveUpvalue(self, name)) |slot| {
                type_check.validateUpvalueAssignmentType(self, name, value) catch |err| switch (err) {
                    error.TypeError => {
                        const actual = type_check.inferExprType(self, value);
                        var fn_idx = self.functions.items.len - 1;
                        var type_name: ?[]const u8 = null;
                        while (fn_idx > 0) {
                            fn_idx -= 1;
                            const loc = state.resolveLocalVarIn(self, fn_idx, name) orelse continue;
                            type_name = loc.type_name;
                            break;
                        }
                        const tn = type_name orelse "unknown";
                        const msg = try std.fmt.allocPrint(
                            self.alloc,
                            "`{s}` wants {s}, got {s}",
                            .{ name, tn, types_mod.typeName(actual) },
                        );
                        return self.setFailureParts(
                            .ParseError,
                            .{
                                .span = value.span,
                                .role = .primary,
                                .message = try std.fmt.allocPrint(self.alloc, "not {s}!", .{tn}),
                            },
                            msg,
                            &.{},
                        );
                    },
                };
                try self.emit(.store_upval, slot);
            } else {
                if (self.functions.items.len == 1) {
                    try self.emit(.store_global, try self.vm.internAtom(name));
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
                        try self.compile(field.object, true);
                        try compileAssignIntoTableAtom(
                            self,
                            try self.vm.internAtom(field.name),
                            value,
                        );
                        return;
                    };
                    const desc = self.vm.struct_types.getType(type_id) orelse {
                        try self.compile(field.object, true);
                        try compileAssignIntoTableAtom(
                            self,
                            try self.vm.internAtom(field.name),
                            value,
                        );
                        return;
                    };
                    const field_atom = try self.vm.internAtom(field.name);
                    const field_offset = desc.fieldIndex(field_atom) orelse {
                        try self.compile(field.object, true);
                        try compileAssignIntoTableAtom(self, field_atom, value);
                        return;
                    };

                    type_check.validateAssignmentType(self, target, value) catch |err| switch (err) {
                        error.TypeError => {
                            const actual = type_check.inferExprType(self, value);
                            const expected = if (field_offset < desc.fields.len) blk: {
                                if (desc.fields[field_offset].type_atom) |ta| {
                                    break :blk types_mod.resolveTypeName(
                                        self,
                                        self.vm.atomName(ta),
                                    );
                                }
                                break :blk types_mod.TypeInfo.any;
                            } else types_mod.TypeInfo.any;
                            const msg = try std.fmt.allocPrint(
                                self.alloc,
                                "`{s}[{s}]` wants {s}, got {s}",
                                .{
                                    type_name,
                                    field.name,
                                    types_mod.typeName(expected),
                                    types_mod.typeName(actual),
                                },
                            );
                            const label = try std.fmt.allocPrint(
                                self.alloc,
                                "field `{s}` on `{s}`",
                                .{ field.name, type_name },
                            );
                            return self.setFailureParts(
                                .ParseError,
                                .{
                                    .span = value.span,
                                    .role = .primary,
                                    .message = label,
                                },
                                msg,
                                &.{},
                            );
                        },
                    };
                    try self.compile(field.object, true);
                    try self.compile(value, true);
                    try self.emit(.struct_set_offset, @intCast(field_offset));
                    try self.regRelease();
                },
                else => {
                    // table field access
                    try self.compile(field.object, true);
                    try compileAssignIntoTableAtom(
                        self,
                        try self.vm.internAtom(field.name),
                        value,
                    );
                },
            }
        },
        .index => |index| {
            try self.compile(index.object, true);
            if (index.key.expr == .hash)
                try compileAssignIntoTableAtom(
                    self,
                    try self.vm.internAtom(index.key.expr.hash),
                    value,
                )
            else {
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

fn compileAssignIntoTableAtom(
    self: *Compiler,
    key_atom: revo.AtomID,
    value: *const Node,
) !void {
    try self.compile(value, true);
    try self.emit(.table_set_atom, key_atom);
    try self.regRelease();
}

pub fn compileStruct(
    self: *Compiler,
    expr: *const Node,
    name: []const u8,
    items: []const StructItem,
) !void {
    const struct_layout_mod = @import("struct_layout.zig");
    var field_defs = try std.ArrayList(struct_layout_mod.FieldDef).initCapacity(
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

    const type_id = if (field_slice.len > 0)
        try self.struct_layouter.registerType(
            self.vm,
            name,
            field_slice,
        )
    else
        try self.vm.struct_types.registerType(
            name,
            &.{},
            std.StringHashMap(revo.memory.Data).init(self.vm.runtime.alloc),
        );

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
        .nil => return revo.core_atoms.data(.nil),
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
