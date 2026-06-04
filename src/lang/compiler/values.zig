const std = @import("std");

const revo = @import("revo");
const Data = revo.Data;
const Instruction = revo.Instruction;
const Compiler = revo.lang.compiler.Compiler;

const ast = @import("../ast.zig");
const Node = ast.Node;
const TableEntry = ast.TableEntry;
const StructItem = ast.StructItem;
const emit = @import("emit.zig");
const flow = @import("flow.zig");
const state = @import("state.zig");
const toRegister = @import("emit.zig").toRegister;
const type_check = @import("type_check.zig");
const types_mod = @import("types.zig");

pub const BindingKind = enum { global, let, con };

pub fn compileLocalBinding(
    self: *Compiler,
    name: []const u8,
    value: *const Node,
    mutable: bool,
    type_name: ?[]const u8,
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
                const msg = try std.fmt.allocPrint(
                    self.alloc,
                    "`{s}` wants {s}, got {s}",
                    .{ name, tn, types_mod.typeName(actual) },
                );
                const label = try std.fmt.allocPrint(
                    self.alloc,
                    "not {s}!",
                    .{tn},
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
        types_mod.resolveTypeName(self, tn)
    else
        type_check.inferExprType(self, value);

    try state.setLocalTypeHint(self, name, inferred_type);
    if (type_check.storedTypeName(self, inferred_type)) |stored_name|
        state.setLocalType(self, slot, stored_name);

    try emit.regDupe(self);
    try emit.emit(self, .bind_local, slot);
}

fn storePatternItem(self: *Compiler, name: []const u8, kind: BindingKind) !void {
    switch (kind) {
        .global => try emit.emit(self, .store_global, try self.vm.internAtom(name)),
        .let => {
            if (state.resolveLocal(self, name)) |slot| {
                try emit.emit(self, .store_local, slot);
            } else {
                try emit.emit(self, .store_global, try self.vm.internAtom(name));
            }
        },
        .con => {
            if (state.resolveLocal(self, name)) |slot| {
                try emit.emit(self, .bind_local, slot);
            } else {
                try emit.emit(self, .store_global_const, try self.vm.internAtom(name));
            }
        },
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
            const mv: Instruction = .{
                .op = .move,
                .a = try toRegister(self.active_registers),
                .b = try toRegister(source_idx),
            };
            try emit.appendRecorded(self, mv);
            self.active_registers += 1;
            try storePatternItem(self, name, kind);
        },
        .tuple_pattern => |items| {
            for (items, 0..) |item, idx| {
                switch (item.expr) {
                    .ident => |name| {
                        if (ast.isDiscardName(name)) continue;
                        const mv: Instruction = .{
                            .op = .move,
                            .a = try toRegister(self.active_registers),
                            .b = try toRegister(source_idx),
                        };
                        try emit.appendRecorded(self, mv);
                        self.active_registers += 1;
                        try emit.emit(self, .tuple_get_const, idx);
                        try storePatternItem(self, name, kind);
                    },
                    .tuple_pattern => {
                        const mv: Instruction = .{
                            .op = .move,
                            .a = try toRegister(self.active_registers),
                            .b = try toRegister(source_idx),
                        };
                        try emit.appendRecorded(self, mv);
                        self.active_registers += 1;
                        try emit.emit(self, .tuple_get_const, idx);
                        try bindPattern(self, item, self.active_registers - 1, kind);
                    },
                    else => {},
                }
            }
        },
        else => {},
    }
}

pub fn predeclarePatternLocals(
    self: *Compiler,
    pattern: *const Node,
    kind: BindingKind,
) !void {
    switch (pattern.expr) {
        .ident => |name| {
            if (ast.isDiscardName(name)) return;
            _ = try state.declareLocal(self, name, kind == .let);
        },
        .tuple_pattern => |items| {
            for (items) |item| {
                switch (item.expr) {
                    .ident => |name| {
                        if (ast.isDiscardName(name)) continue;
                        _ = try state.declareLocal(self, name, kind == .let);
                    },
                    .tuple_pattern => {
                        try predeclarePatternLocals(self, item, kind);
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
            try emit.regDupe(self);
            if (state.resolveLocal(self, name)) |slot| {
                try emit.emit(self, .store_local, slot);
                state.markLocalValueKind(self, slot, .unknown);
                try syncLocalTableFields(self, slot, value);
                const inferred_type = type_check.inferExprType(self, value);
                try state.setLocalTypeHint(self, name, inferred_type);
                if (type_check.storedTypeName(self, inferred_type)) |stored_name|
                    state.setLocalType(self, slot, stored_name);
            } else if (try state.resolveUpvalue(self, name)) |slot| {
                try emit.emit(self, .store_upval, slot);
            } else {
                const msg = try std.fmt.allocPrint(
                    self.alloc,
                    "assignment target `{s}` is not declared",
                    .{name},
                );
                return self.fail(.InvalidAssignmentTarget, target, msg);
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
                    try compileAssignIntoStructOffset(self, field_offset, value);
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
                try compileAssignIntoTable(self, value);
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

fn compileAssignIntoTable(
    self: *Compiler,
    value: *const Node,
) !void {
    try self.compile(value, true);
    try emit.emit(self, .table_set, 0);
    try emit.regRelease(self);
}

fn compileAssignIntoTableAtom(
    self: *Compiler,
    key_atom: revo.AtomID,
    value: *const Node,
) !void {
    try self.compile(value, true);
    try emit.emit(self, .table_set_atom, key_atom);
    try emit.regRelease(self);
}

fn compileAssignIntoStructOffset(
    self: *Compiler,
    field_offset: usize,
    value: *const Node,
) !void {
    try self.compile(value, true);
    try emit.emit(self, .struct_set_offset, @intCast(field_offset));
    try emit.regRelease(self);
}

pub fn compileTuple(self: *Compiler, items: []const *Node) !void {
    for (items) |item| try self.compile(item, true);
    try emit.emit(self, .tuple_new, @intCast(items.len));
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
                try field_defs.append(self.alloc, .{
                    .name = item.field.name,
                    .field_type = if (item.field.type_name) |tn|
                        types_mod.resolveTypeName(self, tn)
                    else
                        types_mod.TypeInfo.any,
                    .type_name = item.field.type_name,
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
    try emit.@"const"(self, Data.new.structType(type_id));
    state.markLocalInitialized(self, slot);
    try emit.regDupe(self);
    try emit.emit(self, .bind_local, slot);

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
            try emit.@"const"(self, Data.new.atom(key_atom));
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
            try emit.emit(self, .struct_set_method, 0);
            try emit.regRelease(self);
        },
        .field => {},
    };

    if (state.currentFunctionState(self) != null)
        try state.setLocalTypeHint(self, name, .{ .struct_type = name });
}

pub fn compileTable(self: *Compiler, entries: []const ast.TableEntry) !void {
    try emit.emit(self, .table_new, 0);
    var array_index: i64 = 0;
    for (entries) |entry| {
        try emit.regDupe(self);
        if (entry.key) |key| {
            if (!entry.computed) switch (key.expr) {
                .ident => |name| {
                    try self.compile(entry.value, true);
                    try emit.emit(
                        self,
                        .table_set_atom,
                        try self.vm.internAtom(name),
                    );
                    try emit.regRelease(self);
                    continue;
                },
                .hash => |name| {
                    try self.compile(entry.value, true);
                    try emit.emit(
                        self,
                        .table_set_atom,
                        try self.vm.internAtom(name),
                    );
                    try emit.regRelease(self);
                    continue;
                },
                else => {},
            };
            try self.compile(key, true);
        } else {
            // array index key
            try emit.@"const"(self, Data.new.num(array_index));
            array_index += 1;
        }
        try self.compile(entry.value, true);
        try emit.emit(self, .table_set, 0);
        try emit.regRelease(self);
    }
}

fn evalConstNode(self: *Compiler, node: *const Node) ?Data {
    switch (node.expr) {
        .number => |n| return Data.new.num(n.value),
        .string => |s| return self.vm.ownDataString(s) catch return null,
        .multiline_string => |s| return self.vm.ownDataString(s) catch return null,
        .hash => |h| return self.vm.dataAtom(h) catch return null,
        .nil => return revo.core_atoms.data(.nil),
        else => return null,
    }
}
