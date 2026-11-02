const revo = @import("revo");

const std = @import("std");
const Value = @import("memory.zig").Value;
const mem = @import("memory.zig");
const VM = @import("VM.zig");

pub const FieldLookup = struct {
    value: Value,
    from_meta: bool,
};

/// `result_reg`, when set, is where a parking `__index` metamethod's result
/// should land on resume: the metamethod runs on the fiber and its eventual
/// ret is rerouted there (see VM.callFunctionParts), so a dispatch
/// instruction that parks mid-lookup resumes with its result register filled
pub fn resolveField(self: *VM, object: Value, key: Value, result_reg: ?@import("opcode.zig").Register) VM.RunError!?FieldLookup {
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
            const type_mt_id = self.metatables[@backingInt(mem.ValueTag.string)] orelse return null;
            const mt = try self.tables.get(type_mt_id);
            if (mt.getRaw(key, self)) |value| {
                return .{ .value = value, .from_meta = true };
            }
            // numeric character access: "str"[n]
            if (key.asNumOpt()) |n| {
                const str = self.stringValue(object.asString().?);
                // get the nth-last value of the string

                // revo.asIndex does not and should not allow negative integers, duplicated here
                if (!std.math.isFinite(n) or @floor(n) != n) return null;
                const idx = @as(usize, @intFromFloat(@abs(n)));

                // negative index, counting from the end. slice needs to be handled separately in execSlice
                if (n < 0) {
                    if (str.len < idx) return null;
                    return .{ .value = try self.ownValueStringNoDedup(&.{str[str.len - idx]}), .from_meta = false };
                }

                // an oob lookup should return null, rather than panicking
                // if it needs to panic, it'll be handled from above
                if (idx < str.len) {
                    return .{ .value = try self.ownValueStringNoDedup(str[idx .. idx + 1]), .from_meta = false };
                }
                const msg = self.runtime.alloc.print(
                    "string index {d} out of range (len {d})",
                    .{ idx, str.len },
                ) catch return error.OutOfMemory;
                self.setRuntimeMessageOwned(msg);
                return error.TypeError;
            }
            return null;
        },
        .number => {
            const type_mt_id = self.metatables[@backingInt(mem.ValueTag.number)] orelse return null;
            const mt = try self.tables.get(type_mt_id);
            if (mt.getRaw(key, self)) |value| {
                return .{ .value = value, .from_meta = true };
            }
            return null;
        },
        .atom => {
            const type_mt_id = self.metatables[@backingInt(mem.ValueTag.atom)] orelse return null;
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
pub fn resolveTableMiss(self: *VM, object: Value, t: *revo.table.Table, key: Value, result_reg: ?@import("opcode.zig").Register) VM.RunError!?FieldLookup {
    if (t.metatable) |mt_id| {
        if (try resolveViaMetatable(self, object, key, mt_id, result_reg)) |resolved| {
            return resolved;
        }
    }
    const type_mt_id = self.metatables[@backingInt(mem.ValueTag.table)] orelse return null;
    return resolveViaMetatable(self, object, key, type_mt_id, result_reg);
}

fn resolveViaMetatable(self: *VM, object: Value, key: Value, mt_id: mem.TableID, result_reg: ?@import("opcode.zig").Register) VM.RunError!?FieldLookup {
    const mt = try self.tables.get(mt_id);
    if (mt.getRaw(key, self)) |value| {
        return .{ .value = value, .from_meta = true };
    }
    if (mt.getRawAtom(revo.CoreAtoms.atomId(.__index), self)) |indexer| {
        const result = try resolveIndexDepth(self, object, key, indexer, MAX_TAG_LOOP, result_reg);
        if (result) |r| {
            if (r.value.bits == revo.Value.new.core(.undef).bits and key.asNumOpt() == null)
                return null;
        }
        return result;
    }
    return null;
}

const MAX_TAG_LOOP = 200;
// fn-valued lookup runs thru nested native dispatch calls
//   so keep this lower than the table-chain limit before the host stakc is exhausetd
const MAX_FUNCTION_INDEX_DEPTH = 8;

fn resolveIndexDepth(self: *VM, object: Value, key: Value, indexer: Value, depth: usize, result_reg: ?@import("opcode.zig").Register) VM.RunError!?FieldLookup {
    switch (indexer.tag()) {
        .function => {
            if (self.index_call_depth >= MAX_FUNCTION_INDEX_DEPTH) return error.StackOverflow;
            self.index_call_depth += 1;
            defer self.index_call_depth -= 1;

            const fn_id = indexer.asFunction().?;
            const func = try self.callable.get(fn_id);
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
                if (mt.getRawAtom(revo.CoreAtoms.atomId(.__index), self)) |next_indexer| {
                    return resolveIndexDepth(self, Value.new.table(table_id), key, next_indexer, depth - 1, result_reg);
                }
            }
            return null;
        },
        else => return .{ .value = indexer, .from_meta = true },
    }
}

pub fn setMetatable(self: *VM, val: Value, mt: ?mem.TableID) !void {
    switch (val.tag()) {
        .table => try self.setTableMetatable(val.asTable().?, mt),
        .resource => try self.setResourceMetatable(val.asResource().?, mt),
        .number => self.metatables[@backingInt(mem.ValueTag.number)] = mt,
        else => self.metatables[@backingInt(val.tag())] = mt,
    }
}

pub fn setTableMetatable(self: *VM, id: mem.TableID, mt: ?mem.TableID) !void {
    if (self.tables.isValid(id)) {
        const tbl_ref = try self.tables.get(id);
        tbl_ref.metatable = mt;
    } else {
        self.metatables[@backingInt(mem.ValueTag.table)] = mt;
    }
}

pub fn setResourceMetatable(self: *VM, id: mem.ResourceID, mt: ?mem.TableID) !void {
    if (self.resources.isValid(id)) {
        const cell = try self.resources.get(id);
        cell.metatable = mt;
    } else {
        self.metatables[@backingInt(mem.ValueTag.resource)] = mt;
    }
}
