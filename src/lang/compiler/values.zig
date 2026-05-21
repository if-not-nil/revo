const std = @import("std");

const revo = @import("revo");
const Data = revo.Data;
const Instruction = revo.Instruction;
const Compiler = revo.lang.compiler.Compiler;

const ast = @import("../ast.zig");
const Node = ast.Node;
const Binding = ast.Binding;
const StructItem = ast.StructItem;
const emit = @import("emit.zig");
const flow = @import("flow.zig");
const state = @import("state.zig");
const type_check = @import("type_check.zig");
const toRegister = @import("emit.zig").toRegister;

pub const BindingKind = enum { global, let, con };
pub const StructFieldTableKind = enum { fields, defaults, types };

pub fn compileLocalBinding(self: *Compiler, name: []const u8, value: *const Node, mutable: bool, type_name: ?[]const u8) !void {
    var effective_type_name = type_name;

    if (effective_type_name == null) effective_type_name = inferTypeFromLiteral(value);
    if (effective_type_name) |tn| {
        if (state.currentFunctionState(self)) |fn_state| try fn_state.var_types.put(name, tn);
    }

    if (type_name) |tn| {
        type_check.validateBindingType(self, tn, value) catch |err| switch (err) {
            error.TypeError => return self.fail(.ParseError, value, "type mismatch"),
        };
    }

    const slot = if (value.expr == .fn_expr)
        try state.reuseOrDeclareLocal(self, name, mutable)
    else
        try state.declareLocal(self, name, mutable);

    state.reserveLocalSlots(self);

    if (value.expr == .fn_expr) {
        try self.compileFn(value.expr.fn_expr.params, value.expr.fn_expr.return_type, value.expr.fn_expr.body, name, null);
    } else {
        try self.compile(value, true);
    }

    state.markLocalInitialized(self, slot);
    state.markLocalValueKind(self, slot, if (value.expr == .tuple) .tuple_literal else .unknown);
    try emit.regDupe(self);
    try emit.emit(self, .bind_local, slot);
}

fn inferTypeFromLiteral(value: *const Node) ?[]const u8 {
    return switch (value.expr) {
        .number => |n| if (n == @as(f64, @trunc(n))) "int" else "float",
        .string, .multiline_string => "string",
        .nil => "nil",
        .table => "table",
        .tuple => "tuple",
        else => null,
    };
}

pub fn bindPattern(self: *Compiler, pattern: *const Node, source_idx: usize, kind: BindingKind) !void {
    switch (pattern.expr) {
        .ident => |name| {
            if (ast.isDiscardName(name)) return;
            const mv: Instruction = .{ .op = .move, .a = try toRegister(self.active_registers), .b = try toRegister(source_idx) };
            try emit.appendRecorded(self, mv);
            self.active_registers += 1;
            try emit.emit(self, if (kind == .con) .store_global_const else .store_global, try self.vm.internAtom(name));
        },
        .tuple_pattern => |items| {
            const is_mutable = kind != .con;
            for (items, 0..) |item, idx| {
                switch (item.expr) {
                    .ident => |name| {
                        if (ast.isDiscardName(name)) continue;
                        const mv: Instruction = .{ .op = .move, .a = try toRegister(self.active_registers), .b = try toRegister(source_idx) };
                        try emit.appendRecorded(self, mv);
                        self.active_registers += 1;
                        try emit.emit(self, .tuple_get_const, idx);
                        try emit.emit(self, if (is_mutable) .store_global else .store_global_const, try self.vm.internAtom(name));
                    },
                    .tuple_pattern => {
                        const mv: Instruction = .{ .op = .move, .a = try toRegister(self.active_registers), .b = try toRegister(source_idx) };
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

pub fn compileAssign(self: *Compiler, target: *const Node, value: *const Node) !void {
    if (target.expr == .tuple_pattern) {
        try self.compile(value, true);
        const src_idx = self.active_registers - 1;
        return bindPattern(self, target, src_idx, .let);
    }
    return compileAssignSimple(self, target, value);
}

fn compileAssignSimple(self: *Compiler, target: *const Node, value: *const Node) !void {
    switch (target.expr) {
        .ident => |name| {
            try self.compile(value, true);
            try emit.regDupe(self);
            if (state.resolveLocal(self, name)) |slot| {
                try emit.emit(self, .store_local, slot);
                state.markLocalValueKind(self, slot, .unknown);
            } else if (try state.resolveUpvalue(self, name)) |slot| {
                try emit.emit(self, .store_upval, slot);
            } else {
                return self.fail(.InvalidAssignmentTarget, target, "assignment target is not declared");
            }
        },
        .field => |field| {
            if (self.resolveTypedStructFieldOffset(field.object, field.name)) |field_offset| {
                type_check.validateAssignmentType(self, target, value) catch |err| switch (err) {
                    error.TypeError => return self.fail(.ParseError, value, "type mismatch on struct field"),
                };
                try self.compile(field.object, true);
                try compileAssignIntoStructOffset(self, field_offset, value);
            } else {
                try self.compile(field.object, true);
                try compileAssignIntoTableAtom(self, try self.vm.internAtom(field.name), value);
            }
        },
        .index => |index| {
            try self.compile(index.object, true);
            if (index.key.expr == .hash)
                try compileAssignIntoTableAtom(self, try self.vm.internAtom(index.key.expr.hash), value)
            else {
                try self.compile(index.key, true);
                try compileAssignIntoTable(self, value);
            }
        },
        else => return self.fail(.InvalidAssignmentTarget, target, "invalid assignment target"),
    }
}

fn compileAssignIntoTable(self: *Compiler, value: *const Node) !void {
    try self.compile(value, true);
    try emit.emit(self, .table_set, 0);
    try emit.regRelease(self);
}

fn compileAssignIntoTableAtom(self: *Compiler, key_atom: revo.AtomID, value: *const Node) !void {
    try self.compile(value, true);
    try emit.emit(self, .table_set_atom, key_atom);
    try emit.regRelease(self);
}

fn compileAssignIntoStructOffset(self: *Compiler, field_offset: usize, value: *const Node) !void {
    try self.compile(value, true);
    try emit.emit(self, .struct_set_offset, @intCast(field_offset));
    try emit.regRelease(self);
}

pub fn compileTuple(self: *Compiler, items: []const *Node) !void {
    for (items) |item| try self.compile(item, true);
    try emit.emit(self, .tuple_new, @intCast(items.len));
}

pub fn compileStruct(self: *Compiler, expr: *const Node, name: []const u8, items: []const StructItem) !void {
    const types_mod = @import("types.zig");
    const struct_layout_mod = @import("struct_layout.zig");
    // collect typed fields for layout calculation
    var field_defs = try std.ArrayList(struct_layout_mod.FieldDef).initCapacity(self.alloc, items.len);
    defer field_defs.deinit(self.alloc);
    for (items) |item| {
        if (item == .field and item.field.type_name != null) {
            try field_defs.append(self.alloc, .{
                .name = item.field.name,
                .field_type = if (item.field.type_name) |tn| typeInfoFromName(tn) else types_mod.TypeInfo.any,
            });
        }
    }
    if (field_defs.items.len > 0) _ = try self.struct_layouter.layoutStruct(name, field_defs.items);
    // descriptor temp holds the struct table during construction
    const descriptor_slot = try state.reuseOrDeclareLocal(self, name, false);
    const descriptor_temp = self.slot_allocators.items[self.slot_allocators.items.len - 1];
    self.slot_allocators.items[self.slot_allocators.items.len - 1] += 1;
    state.reserveLocalSlots(self);

    const fields_id = try compileStructFieldTable(self, items, .fields);
    const defaults_id = try compileStructFieldTable(self, items, .defaults);
    const types_id = try compileStructFieldTable(self, items, .types);
    const fields_const = try self.vm.addConstant(Data.new.table(fields_id));
    const defaults_const = try self.vm.addConstant(Data.new.table(defaults_id));
    const types_const = try self.vm.addConstant(Data.new.table(types_id));
    const name_const = try self.vm.addConstant(try self.vm.ownDataString(name));

    try emit.emit(self, .table_new, 0);
    try flow.emitStorageStore(self, .{ .local = descriptor_temp }, false);
    inline for (&[_]struct { key: []const u8, const_id: usize }{
        .{ .key = "__name", .const_id = name_const },
        .{ .key = "__fields", .const_id = fields_const },
        .{ .key = "__defaults", .const_id = defaults_const },
        .{ .key = "__types", .const_id = types_const },
    }) |entry| {
        try flow.emitStorageLoad(self, .{ .local = descriptor_temp });
        try emit.@"const"(self, Data.new.atom(try self.vm.internAtom(entry.key)));
        try emit.loadConst(self, entry.const_id);
        try emit.emit(self, .table_set, 0);
        try emit.regRelease(self);
    }

    // comp method bindings
    for (items) |item| switch (item) {
        .binding => |b| {
            if (b.target.expr != .ident)
                return self.fail(.UnsupportedSyntax, expr, "assignment target must be named");
            const key_atom = try self.vm.internAtom(b.target.expr.ident);
            try flow.emitStorageLoad(self, .{ .local = descriptor_temp });
            try emit.@"const"(self, Data.new.atom(key_atom));
            if (b.value.expr == .fn_expr)
                try self.compileFn(b.value.expr.fn_expr.params, b.value.expr.fn_expr.return_type, b.value.expr.fn_expr.body, b.target.expr.ident, null)
            else
                try self.compile(b.value, true);
            try emit.emit(self, .table_set, 0);
            try emit.regRelease(self);
        },
        .field => {},
    };
    // bind descriptor to local name
    try flow.emitStorageLoad(self, .{ .local = descriptor_temp });
    state.markLocalInitialized(self, descriptor_slot);
    try emit.regDupe(self);
    try emit.emit(self, .bind_local, descriptor_slot);
}

fn compileStructFieldTable(self: *Compiler, items: []const StructItem, kind: StructFieldTableKind) !revo.TableID {
    const table_id = try self.vm.tables.create();
    const table = self.vm.tables.get(table_id) catch unreachable;
    for (items) |item| switch (item) {
        .field => |f| {
            const key = Data.new.atom(try self.vm.internAtom(f.name));
            switch (kind) {
                .fields => table.putRaw(key, revo.core_atoms.data(.true)) catch unreachable,
                .defaults => if (f.default_value) |v| table.putRaw(key, try constValueFromNode(self, v)) catch unreachable,
                .types => if (f.type_name) |tn| table.putRaw(key, Data.new.atom(try self.vm.internAtom(tn))) catch unreachable,
            }
        },
        .binding => {},
    };
    return table_id;
}

fn constValueFromNode(self: *Compiler, node: *const Node) !Data {
    return switch (node.expr) {
        .number => |n| blk: {
            if (std.math.isFinite(n) and @floor(n) == n and
                n >= @as(f64, @floatFromInt(std.math.minInt(i64))) and
                n <= @as(f64, @floatFromInt(std.math.maxInt(i64))))
                break :blk Data.new.num(@as(i64, @intFromFloat(n)));
            break :blk Data.new.num(n);
        },
        .string, .multiline_string => |s| try self.vm.ownDataString(s),
        .hash => |s| Data.new.atom(try self.vm.internAtom(s)),
        else => return self.fail(.UnsupportedSyntax, node, "struct defaults must be constant values"),
    };
}

pub fn compileTable(self: *Compiler, entries: []const ast.TableEntry) !void {
    try emit.emit(self, .table_new, 0);
    var array_index: i64 = 0;
    for (entries) |entry| {
        try emit.regDupe(self);
        if (entry.key) |key| {
            if (entry.computed)
                try self.compile(key, true)
            else switch (key.expr) {
                .ident => |name| try emit.@"const"(self, Data{ .atom = try self.vm.internAtom(name) }),
                else => try self.compile(key, true),
            }
        } else {
            try emit.@"const"(self, Data.new.num(array_index));
            array_index += 1;
        }
        try self.compile(entry.value, true);
        try emit.emit(self, .table_set, 0);
        try emit.regRelease(self);
    }
}

fn typeInfoFromName(type_name: []const u8) @import("types.zig").TypeInfo {
    const types_mod = @import("types.zig");
    if (std.mem.eql(u8, type_name, "int")) return types_mod.TypeInfo.int;
    if (std.mem.eql(u8, type_name, "float")) return types_mod.TypeInfo.float;
    if (std.mem.eql(u8, type_name, "string")) return types_mod.TypeInfo.string;
    if (std.mem.eql(u8, type_name, "bool")) return types_mod.TypeInfo.bool;
    return types_mod.TypeInfo.any;
}
