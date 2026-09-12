const revo = @import("revo");

const Data = @import("memory.zig").Data;
const mem = @import("memory.zig");
const VM = @import("VM.zig");

pub const FieldLookup = struct {
    value: Data,
    from_meta: bool,
};

/// `result_reg`, when set, is where a parking `__index` metamethod's result
/// should land on resume: the metamethod runs on the fiber and its eventual
/// ret is rerouted there (see VM.callFunctionParts), so a dispatch
/// instruction that parks mid-lookup resumes with its result register filled
pub fn resolveField(self: *VM, object: Data, key: Data, result_reg: ?@import("opcode.zig").Register) VM.EvalError!?FieldLookup {
    switch (object.tag()) {
        .table => {
            const table_id = object.asTable().?;
            const t = try self.tables.get(table_id);
            if (t.getRaw(key, self)) |value| {
                return .{ .value = value, .from_meta = false };
            }
            return resolveTableMiss(self, object, t, key, result_reg);
        },
        .string => {
            const type_mt_id = self.metatables[@intFromEnum(mem.Type.string)] orelse return null;
            const mt = try self.tables.get(type_mt_id);
            if (mt.getRaw(key, self)) |value| {
                return .{ .value = value, .from_meta = true };
            }
            // numeric character access: "str"[n]
            if (key.asNum()) |n| {
                const str = self.stringValue(object.asString().?);
                const idx = revo.asIndex(n) catch return null;
                if (idx < str.len) {
                    return .{ .value = try self.ownDataStringNoDedup(str[idx .. idx + 1]), .from_meta = false };
                }
                return null;
            }
            return null;
        },
        .number => {
            const type_mt_id = self.metatables[@intFromEnum(mem.Type.number)] orelse return null;
            const mt = try self.tables.get(type_mt_id);
            if (mt.getRaw(key, self)) |value| {
                return .{ .value = value, .from_meta = true };
            }
            return null;
        },
        .atom => {
            const type_mt_id = self.metatables[@intFromEnum(mem.Type.atom)] orelse return null;
            const mt = try self.tables.get(type_mt_id);
            if (mt.getRaw(key, self)) |value| {
                return .{ .value = value, .from_meta = true };
            }
            return null;
        },
        else => {
            const mt_id = try self.getMetatableId(object) orelse return null;
            return resolveViaMetatable(self, object, key, mt_id, result_reg);
        },
    }
}

/// for when the caller already did the direct `getRaw` and missed
///   and you need to skip straight to the metatables instead of hashing the same key twice
pub fn resolveTableMiss(self: *VM, object: Data, t: *revo.table.Table, key: Data, result_reg: ?@import("opcode.zig").Register) VM.EvalError!?FieldLookup {
    if (t.metatable) |mt_id| {
        if (try resolveViaMetatable(self, object, key, mt_id, result_reg)) |resolved| {
            return resolved;
        }
    }
    const type_mt_id = self.metatables[@intFromEnum(mem.Type.table)] orelse return null;
    return resolveViaMetatable(self, object, key, type_mt_id, result_reg);
}

fn resolveViaMetatable(self: *VM, object: Data, key: Data, mt_id: mem.TableID, result_reg: ?@import("opcode.zig").Register) VM.EvalError!?FieldLookup {
    const mt = try self.tables.get(mt_id);
    if (mt.getRaw(key, self)) |value| {
        return .{ .value = value, .from_meta = true };
    }
    if (mt.getRawAtom(revo.core_atoms.atomId(.__index), self)) |indexer| {
        const result = try resolveIndexDepth(self, object, key, indexer, MAX_TAG_LOOP, result_reg);
        if (result) |r| {
            if (r.value.bits == revo.Data.new.core(.undef).bits and key.asNum() == null)
                return null;
        }
        return result;
    }
    return null;
}

const MAX_TAG_LOOP = 200;

fn resolveIndexDepth(self: *VM, object: Data, key: Data, indexer: Data, depth: usize, result_reg: ?@import("opcode.zig").Register) VM.EvalError!?FieldLookup {
    switch (indexer.tag()) {
        .function => {
            const fn_id = indexer.asFunction().?;
            const func = try self.functions.get(fn_id);
            const value = switch (func.*) {
                .closure => |closure| switch (closure.arity) {
                    1 => try self.callFunctionParts(indexer, null, &.{object}, result_reg),
                    else => try self.callFunctionParts(indexer, null, &.{ object, key }, result_reg),
                },
                .host => try self.callFunctionParts(indexer, null, &.{ object, key }, result_reg),
                .c_function => try self.callFunctionParts(indexer, null, &.{ object, key }, result_reg),
            };
            return .{ .value = value, .from_meta = true };
        },
        .table => {
            const table_id = indexer.asTable().?;
            const index_table = try self.tables.get(table_id);
            if (index_table.getRaw(key, self)) |value| {
                return .{ .value = value, .from_meta = true };
            }
            if (index_table.metatable) |mt_id| {
                if (depth == 0) return null;
                const mt = try self.tables.get(mt_id);
                if (mt.getRaw(key, self)) |value| {
                    return .{ .value = value, .from_meta = true };
                }
                if (mt.getRawAtom(revo.core_atoms.atomId(.__index), self)) |next_indexer| {
                    return resolveIndexDepth(self, Data.new.table(table_id), key, next_indexer, depth - 1, result_reg);
                }
            }
            return null;
        },
        else => return .{ .value = indexer, .from_meta = true },
    }
}

pub fn setMetatable(self: *VM, val: Data, mt: ?mem.TableID) !void {
    switch (val.tag()) {
        .table => try self.setTableMetatable(val.asTable().?, mt),
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
