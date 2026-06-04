const std = @import("std");

const revo = @import("revo");

const Data = @import("memory.zig").Data;
const mem = @import("memory.zig");
const VM = @import("VM.zig");

pub const FieldLookup = struct {
    value: Data,
    from_meta: bool,
};

pub fn resolveField(self: *VM, object: Data, key: Data) VM.EvalError!?FieldLookup {
    switch (object.tag()) {
        .table => {
            const table_id = object.asTable().?;
            const t = try self.tables.get(table_id);
            if (t.getRaw(key)) |value| {
                return .{ .value = value, .from_meta = false };
            }
            if (t.metatable) |mt_id| {
                if (try resolveViaMetatable(self, object, key, mt_id)) |resolved| {
                    return resolved;
                }
            }
            const type_mt_id = self.metatables[@intFromEnum(mem.Type.table)] orelse return null;
            return resolveViaMetatable(self, object, key, type_mt_id);
        },
        .tuple => {
            const tuple_id = object.asTuple().?;
            var instance_mt_id: ?@TypeOf(self.metatables[0].?) = null;
            var tuple_ref: ?*revo.tuple.Tuple = null;
            if (self.tuples.get(tuple_id)) |t| {
                tuple_ref = t;
                instance_mt_id = t.metatable;
            } else |_| {} // invalid tuple id, fall through to use default metatable

            // fast path::: tuple numeric indexing should not require mm lookup
            if (tuple_ref) |t| {
                const idx_opt: ?usize = if (key.asNum()) |n|
                    if (n >= 0 and @floor(n) == n and n <= @as(f64, @floatFromInt(std.math.maxInt(usize)))) @as(usize, @intFromFloat(n)) else null
                else
                    null;
                if (idx_opt) |idx| {
                    if (idx < t.items.len) {
                        return .{ .value = t.items[idx], .from_meta = false };
                    }
                    return null;
                }
            }

            if (instance_mt_id) |mt_id| {
                if (try resolveViaMetatable(self, object, key, mt_id)) |resolved| {
                    return resolved;
                }
            }

            const type_mt_id = self.metatables[@intFromEnum(mem.Type.tuple)] orelse return null;
            if (instance_mt_id != null and instance_mt_id.? == type_mt_id) return null;
            return resolveViaMetatable(self, object, key, type_mt_id);
        },
        .struct_val => {
            const instance_id = object.asStructVal().?;
            const instance = self.struct_instances.get(instance_id) catch return null;
            const desc = self.struct_types.getType(instance.type_id) orelse return null;

            if (key.asAtom()) |atom| {
                // check methods first
                if (desc.methods.get(self.atomName(atom))) |method| {
                    return .{ .value = method, .from_meta = true };
                }
                if (desc.fieldIndex(atom)) |i| {
                    return .{ .value = instance.fields[i], .from_meta = false };
                }
            }
            return null;
        },
        else => {
            const mt_id = try self.getMetatableId(object) orelse return null;
            return resolveViaMetatable(self, object, key, mt_id);
        },
    }
}

fn resolveViaMetatable(self: *VM, object: Data, key: Data, mt_id: @TypeOf(self.metatables[0].?)) VM.EvalError!?FieldLookup {
    const mt = try self.tables.get(mt_id);
    if (mt.getRaw(key)) |value| {
        return .{ .value = value, .from_meta = true };
    }
    if (mt.getRaw(Data.new.atom(revo.core_atoms.atom_id(.__index)))) |indexer| {
        return resolveIndex(self, object, key, indexer);
    }
    return null;
}

const MAX_TAG_LOOP = 200;

pub fn resolveIndex(self: *VM, object: Data, key: Data, indexer: Data) VM.EvalError!?FieldLookup {
    return resolveIndexDepth(self, object, key, indexer, MAX_TAG_LOOP);
}

fn resolveIndexDepth(self: *VM, object: Data, key: Data, indexer: Data, depth: usize) VM.EvalError!?FieldLookup {
    switch (indexer.tag()) {
        .function => {
            const fn_id = indexer.asFunction().?;
            const func = try self.functions.get(fn_id);
            const value = switch (func.*) {
                .closure => |closure| switch (closure.arity) {
                    1 => try self.callFunction(indexer, &.{object}),
                    else => try self.callFunction(indexer, &.{ object, key }),
                },
                .native => try self.callFunction(indexer, &.{ object, key }),
                .c_function => try self.callFunction(indexer, &.{ object, key }),
            };
            return .{ .value = value, .from_meta = true };
        },
        .table => {
            const table_id = indexer.asTable().?;
            const index_table = try self.tables.get(table_id);
            if (index_table.getRaw(key)) |value| {
                return .{ .value = value, .from_meta = true };
            }
            if (index_table.metatable) |mt_id| {
                if (depth == 0) return null;
                const mt = try self.tables.get(mt_id);
                if (mt.getRaw(key)) |value| {
                    return .{ .value = value, .from_meta = true };
                }
                if (mt.getRaw(Data.new.atom(revo.core_atoms.atom_id(.__index)))) |next_indexer| {
                    return resolveIndexDepth(self, Data.new.table(table_id), key, next_indexer, depth - 1);
                }
            }
            return null;
        },
        else => return .{ .value = indexer, .from_meta = true },
    }
}

pub fn callField(self: *VM, argc: usize) VM.EvalError!void {
    const fiber = self.currentFiber();
    const slots = fiber.registers[0..fiber.registers_len];
    const key_slot = slots.len - argc - 1;
    const object_slot = key_slot - 1;
    const object = slots[object_slot];
    const key = slots[key_slot];
    const lookup = (try resolveField(self, object, key)) orelse {
        fiber.registers_len = object_slot;
        const key_name = if (key.asAtom()) |atom| self.atomName(atom) else revo.std_lib.dataToString(key);
        try self.setRuntimeMessageFmt("field `{s}` does not exist on {s}", .{
            key_name,
            revo.std_lib.typeof(object),
        });
        return error.NotAFunction;
    };

    if (!lookup.from_meta) {
        const saved_len = fiber.registers_len;
        errdefer fiber.registers_len = saved_len;
        fiber.registers[key_slot] = lookup.value;
        std.mem.copyForwards(
            Data,
            fiber.registers[object_slot .. fiber.registers_len - 1],
            fiber.registers[key_slot..fiber.registers_len],
        );
        fiber.registers_len -= 1;
        try callViaStackLayout(self, object_slot, argc);
        return;
    }

    const saved_object = fiber.registers[object_slot];
    const saved_key = fiber.registers[key_slot];
    errdefer {
        fiber.registers[object_slot] = saved_object;
        fiber.registers[key_slot] = saved_key;
    }
    fiber.registers[object_slot] = lookup.value;
    fiber.registers[key_slot] = object;
    try callViaStackLayout(self, object_slot, argc + 1);
}

fn callViaStackLayout(self: *VM, callee_slot: usize, argc: usize) VM.EvalError!void {
    const fiber = self.currentFiber();
    const args_start = callee_slot + 1;
    const args_end = args_start + argc;
    const callee = fiber.registers[callee_slot];
    if (fiber.registers_len + argc + 1 > VM.MAX_REGISTERS) return error.StackOverflow;
    const result = try self.callFunction(callee, fiber.registers[args_start..args_end]);
    fiber.registers_len = callee_slot;
    if (fiber.registers_len >= VM.MAX_REGISTERS) return error.StackOverflow;
    fiber.registers[fiber.registers_len] = result;
    fiber.registers_len += 1;
}

pub fn setMetatable(self: *VM, val: Data, mt: ?mem.TableID) !void {
    switch (val.tag()) {
        .table => try self.setTableMetatable(val.asTable().?, mt),
        .tuple => {
            const id = val.asTuple().?;
            if (self.tuples.get(id)) |tuple_ref| {
                tuple_ref.metatable = mt;
            } else |_| {
                self.metatables[@intFromEnum(mem.Type.tuple)] = mt;
            }
        },
        .number => self.metatables[@intFromEnum(mem.Type.number)] = mt,
        else => self.metatables[@intFromEnum(val.tag())] = mt,
    }
}

pub fn setTableMetatable(self: *VM, id: mem.TableID, mt: ?mem.TableID) !void {
    if (self.tables.isValid(id)) {
        const tbl_ref = try self.tables.get(id);
        tbl_ref.metatable = mt;
    } else {
        self.metatables[@intFromEnum(mem.Type.table)] = mt;
    }
}

pub fn getMetatable(self: *VM, val: Data) !?*revo.table.Table {
    const id = try self.getMetatableId(val) orelse return null;
    return self.tables.get(id) catch return null;
}

pub fn getMetamethod(self: *VM, val: Data, name: []const u8) !?Data {
    return self.getMetamethodByAtom(val, try self.internAtom(name));
}
