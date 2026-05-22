const std = @import("std");

const revo = @import("revo");

const memory = revo.memory;
const Data = memory.Data;
const testing = revo.lang.testing;

pub const TableSlot = struct {
    value: ?Table = null,
    marked: bool = false,
    next_free: ?memory.TableID = null,
};

pub const TablePool = struct {
    alloc: std.mem.Allocator,
    tables: std.ArrayList(TableSlot),
    free_head: ?memory.TableID = null,

    pub fn init(alloc: std.mem.Allocator) !TablePool {
        return .{
            .alloc = alloc,
            .tables = try std.ArrayList(TableSlot).initCapacity(alloc, 4),
        };
    }

    pub fn deinit(self: *TablePool) void {
        for (self.tables.items) |*slot|
            if (slot.value) |*tbl| tbl.deinit();
        self.tables.deinit(self.alloc);
    }

    pub fn create(self: *TablePool) !memory.TableID {
        return try revo.allocSlot(TableSlot, memory.TableID, self.alloc, &self.tables, &self.free_head, .{ .value = try Table.init(self.alloc) });
    }

    pub fn get(self: *TablePool, id: memory.TableID) !*Table {
        if (id >= self.tables.items.len) return error.InvalidTable;
        if (self.tables.items[id].value) |*t| return t;
        return error.InvalidTable;
    }

    pub fn isValid(self: *const TablePool, id: memory.TableID) bool {
        return id < self.tables.items.len and self.tables.items[id].value != null;
    }

    pub fn mark(self: *TablePool, id: memory.TableID, vm: *revo.VM) void {
        if (id >= self.tables.items.len) return;
        const slot = &self.tables.items[id];
        if (slot.value) |*t| {
            if (slot.marked) return;
            slot.marked = true;
            t.mark(vm);
            if (t.metatable) |mt| self.mark(mt, vm);
        }
    }

    pub fn sweep(self: *TablePool) void {
        revo.sweepSlots(TableSlot, memory.TableID, &self.tables, &self.free_head, self, TablePool.finalizeSlot);
    }

    fn finalizeSlot(slot: *TableSlot, _: *TablePool) void {
        if (slot.value) |*t| t.deinit();
    }

    pub fn bytes(self: *const TablePool) usize {
        var total: usize = 0;
        for (self.tables.items) |slot| {
            if (slot.value) |*t| total += t.bytes();
        }
        return total;
    }
};

pub const Table = struct {
    const KeyContext = struct {
        pub fn hash(_: @This(), key: Data) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(&[_]u8{@intCast(@intFromEnum(std.meta.activeTag(key)))});
            switch (key) {
                .number => |n| {
                    const bits: u64 = @bitCast(n);
                    h.update(std.mem.asBytes(&bits));
                },
                .string => |id| h.update(std.mem.asBytes(&id)),
                .atom => |id| h.update(std.mem.asBytes(&id)),
                .function => |id| h.update(std.mem.asBytes(&id)),
                .table => |id| h.update(std.mem.asBytes(&id)),
                .tuple => |id| h.update(std.mem.asBytes(&id)),
            }
            return h.final();
        }

        pub fn eql(_: @This(), a: Data, b: Data) bool {
            return keyEq(a, b);
        }
    };

    const HashEntries = std.HashMap(Data, Data, KeyContext, std.hash_map.default_max_load_percentage);

    alloc: std.mem.Allocator,
    array: std.ArrayList(Data),
    hash_entries: HashEntries,
    hash_order: std.ArrayList(Data),
    metatable: ?memory.TableID = null,

    pub fn init(alloc: std.mem.Allocator) !Table {
        return .{
            .alloc = alloc,
            .array = try std.ArrayList(Data).initCapacity(alloc, 0),
            .hash_entries = HashEntries.init(alloc),
            .hash_order = try std.ArrayList(Data).initCapacity(alloc, 0),
        };
    }

    pub fn deinit(self: *Table) void {
        self.array.deinit(self.alloc);
        self.hash_entries.deinit();
        self.hash_order.deinit(self.alloc);
    }

    fn keyEq(a: Data, b: Data) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .number => |n| @as(u64, @bitCast(n)) == @as(u64, @bitCast(b.number)),
            .string => |id| b.string == id,
            .atom => |id| b.atom == id,
            .function => |id| b.function == id,
            .table => |id| b.table == id,
            .tuple => |id| b.tuple == id,
        };
    }

    fn integerArrayIndex(key: Data) ?usize {
        return switch (key) {
            .number => |n| if (n < 0 or !std.math.isFinite(n) or @floor(n) != n) null else @as(usize, @intFromFloat(n)),
            else => null,
        };
    }

    inline fn canonicalKey(key: Data) Data {
        return key;
    }

    fn isBoolAtom(atom: memory.AtomID) bool {
        return atom == revo.core_atoms.atom_id(.true) or atom == revo.core_atoms.atom_id(.false);
    }

    fn valueTypeName(value: Data) []const u8 {
        return switch (value) {
            .atom => |a| if (a == revo.core_atoms.atom_id(.nil)) "nil" else "atom",
            .number => "number",
            .string => "string",
            .function => "function",
            .table => "table",
            .tuple => "tuple",
        };
    }

    fn structFieldTypeMatches(expected: Data, value: Data, vm: *revo.VM) bool {
        const expected_atom = switch (expected) {
            .atom => |atom| atom,
            else => return true,
        };
        const expected_name = vm.atomName(expected_atom);
        if (std.mem.eql(u8, expected_name, "bool")) {
            return value == .atom and isBoolAtom(value.atom);
        }
        if (std.mem.eql(u8, expected_name, "integer")) return value == .number;
        if (std.mem.eql(u8, expected_name, "float")) return value == .number;
        return std.mem.eql(u8, expected_name, valueTypeName(value));
    }

    fn structName(mt: *Table, vm: *revo.VM) ![]const u8 {
        const name_atom = try vm.internAtom("__name");
        return switch (mt.getRaw(.{ .atom = name_atom }) orelse revo.core_atoms.data(.nil)) {
            .string => |id| vm.stringValue(id),
            else => "<struct>",
        };
    }

    pub fn structFieldIndex(self: *const Table, vm: *revo.VM, field_atom: memory.AtomID) !?usize {
        const mt_id = self.metatable orelse return null;
        const mt = try vm.tables.get(mt_id);
        const fields_data = mt.getRaw(.{ .atom = try vm.internAtom("__fields") }) orelse return null;
        const fields_id = switch (fields_data) {
            .table => |id| id,
            else => return null,
        };
        const fields = try vm.tables.get(fields_id);
        const field_key = Data.new.atom(field_atom);
        if (fields.getRaw(field_key) == null) return null;
        for (fields.hash_order.items, 0..) |key, idx| {
            if (key == .atom and field_key == .atom and key.atom == field_key.atom) return idx;
        }
        return null;
    }

    pub fn put(self: *Table, table_id: memory.TableID, vm: *revo.VM, key: Data, val: Data) !void {
        if (self.metatable == null) {
            return self.putRaw(key, val);
        }

        const mt_id = self.metatable.?;
        const mt = try vm.tables.get(mt_id);

        const fields_atom = try vm.internAtom("__fields");
        const types_atom = try vm.internAtom("__types");
        // struct instances are table backed with descriptor as mt
        if (mt.getRaw(.{ .atom = fields_atom })) |fields_data| {
            const fields_id = switch (fields_data) {
                .table => |id| id,
                else => return error.TypeError,
            };
            const fields = try vm.tables.get(fields_id);
            const key_atom = switch (key) {
                .atom => |a| a,
                else => {
                    const struct_name = try structName(mt, vm);
                    try vm.setRuntimeMessageFmt("unknown field `{s}` for struct `{s}`", .{ valueTypeName(key), struct_name });
                    return error.Panic;
                },
            };
            const field_key = Data.new.atom(key_atom);
            _ = fields.getRaw(field_key) orelse {
                const struct_name = try structName(mt, vm);
                try vm.setRuntimeMessageFmt("unknown field `{s}` for struct `{s}`", .{ vm.atomName(key_atom), struct_name });
                return error.Panic;
            };

            if (mt.getRaw(.{ .atom = types_atom })) |types_data| {
                if (types_data == .table) {
                    const types = try vm.tables.get(types_data.table);
                    if (types.getRaw(field_key)) |expected| {
                        if (!structFieldTypeMatches(expected, val, vm)) {
                            const struct_name = try structName(mt, vm);
                            try vm.setRuntimeMessageFmt("field `{s}` on `{s}` expected {s}, got {s}", .{
                                vm.atomName(key_atom),
                                struct_name,
                                switch (expected) {
                                    .atom => |atom| vm.atomName(atom),
                                    else => valueTypeName(expected),
                                },
                                valueTypeName(val),
                            });
                            return error.Panic;
                        }
                    }
                }
            }

            if (try self.structFieldIndex(vm, key_atom)) |field_idx| {
                if (field_idx >= self.array.items.len) {
                    const old_len = self.array.items.len;
                    try self.array.resize(vm.runtime.alloc, field_idx + 1);
                    @memset(self.array.items[old_len..], revo.core_atoms.data(.missing));
                }
                self.array.items[field_idx] = val;
            }

            try self.putRaw(key, val);
            return;
        }

        if (mt.getRaw(.{ .atom = revo.core_atoms.atom_id(.__newindex) })) |newindex_method| {
            switch (newindex_method) {
                .function => |f| {
                    const table_data = Data{ .table = table_id };
                    _ = try vm.callFunction(Data{ .function = f }, &[_]Data{ table_data, key, val });
                    return;
                },
                else => {},
            }
        }

        return self.putRaw(key, val);
    }

    pub fn putRaw(self: *Table, key: Data, val: Data) !void {
        const canon = canonicalKey(key);
        if (integerArrayIndex(canon)) |idx| {
            if (idx < self.array.items.len) {
                self.array.items[idx] = val;
                return;
            } else if (idx == self.array.items.len) {
                try self.push(val);
                return;
            } // else fallback to hash
        }

        if (self.hash_entries.getPtr(canon)) |entry_val| {
            entry_val.* = val;
            return;
        }
        try self.hash_entries.put(canon, val);
        try self.hash_order.append(self.alloc, canon);
    }

    pub fn push(self: *Table, val: Data) !void {
        try self.array.append(self.alloc, val);
    }

    pub fn getRaw(self: *Table, key: Data) ?Data {
        const canon = canonicalKey(key);
        if (integerArrayIndex(canon)) |idx| {
            if (idx < self.array.items.len) {
                return self.array.items[idx];
            }
        }
        return self.hash_entries.get(canon);
    }

    pub fn get(self: *Table, key: Data, vm: *revo.VM) !?Data {
        if (self.getRaw(key)) |value| return value;
        if (self.metatable) |mt_id| {
            const mt = try vm.tables.get(mt_id);
            if (mt.getRaw(.{ .atom = revo.core_atoms.atom_id(.__index) })) |index_method| {
                switch (index_method) {
                    .table => |table_id| {
                        const index_table = try vm.tables.get(table_id);
                        return try index_table.get(key, vm);
                    },
                    .function => return null,
                    else => {},
                }
            }
        }
        return null;
    }

    pub fn mark(self: *Table, vm: *revo.VM) void {
        for (self.array.items) |entry|
            vm.markData(entry);

        var it = self.hash_entries.iterator();
        while (it.next()) |entry| {
            vm.markData(entry.key_ptr.*);
            vm.markData(entry.value_ptr.*);
        }
    }

    pub fn count(self: *const Table) usize {
        var n: usize = self.hash_entries.count();
        for (self.array.items) |_| {
            n += 1;
        }
        return n;
    }

    pub fn bytes(self: *const Table) usize {
        return 64 + 16 * self.count();
    }

    pub fn write(self: *Table, writer: *std.Io.Writer, vm: *revo.VM, mode: Data.RenderMode) anyerror!void {
        try writer.writeAll("{ ");
        const has_struct_fields = if (self.metatable) |mt_id| blk: {
            const mt = try vm.tables.get(mt_id);
            break :blk mt.getRaw(.{ .atom = try vm.internAtom("__fields") }) != null;
        } else false;
        const should_write_idx = self.hash_entries.count() != 0 and !has_struct_fields;
        for (self.array.items, 0..) |val, idx| {
            if (should_write_idx) {
                try Data.new.num(idx).write(writer, vm, mode);
                try writer.writeAll(": ");
            }
            try val.write(writer, vm, mode);
            try writer.writeAll(", ");
        }
        for (self.hash_order.items) |key| {
            const val = self.hash_entries.get(key) orelse continue;
            if (should_write_idx) {
                try key.write(writer, vm, mode);
                try writer.writeAll(": ");
            }
            try val.write(writer, vm, mode);
            try writer.writeAll(", ");
        }
        try writer.writeAll("}");
    }
};

test "table literals and field lookup work" {
    try testing.top_number(
        \\ const t = {answer = 41, extra = 1}
        \\ t.answer + t.extra
    , 42);
}

test "table positional access" {
    try testing.top_number(
        \\ const t = {41, 1}
        \\ t[0] + t[1]
    , 42);
}

test "table field assignment" {
    try testing.top_number(
        \\ const t = {answer = 41}
        \\ t.answer = t.answer + 1
        \\ t.answer
    , 42);
}

test "table with positional elements" {
    try testing.top_number(
        \\ const t = {10, 20, 30}
        \\ t[0] + t[1] + t[2]
    , 60);
}

test "mixed table with positional and named entries" {
    try testing.top_number(
        \\ const t = {100, 30, x = 20}
        \\ t[0] + t[1] + t.x
    , 150);
}

test "table numeric key canonicalization" {
    try testing.top_number(
        \\ const t = {1 = 41}
        \\ t[1.0] + 1
    , 42);

    try testing.top_number(
        \\ const t = {1.0 = 41}
        \\ t[1] + 1
    , 42);
}

test "table float keys stay distinct when non integral" {
    try testing.top_number(
        \\ const t = {1 = 1, 1.5 = 41}
        \\ t[1] + t[1.5]
    , 42);
}

test "table push appends positional values" {
    var table = try Table.init(std.testing.allocator);
    defer table.deinit();

    try table.push(Data.new.num(10));
    try table.push(Data.new.num(20));
    try table.push(Data.new.num(30));

    try std.testing.expectEqual(@as(usize, 3), table.count());
    try std.testing.expectEqual(Data.new.num(10), table.getRaw(Data.new.num(0)).?);
    try std.testing.expectEqual(Data.new.num(20), table.getRaw(Data.new.num(1)).?);
    try std.testing.expectEqual(Data.new.num(30), table.getRaw(Data.new.num(2)).?);
}

const tt = revo.lang.testing;

test "table lookup order" {
    try tt.top_string(
        \\ const mt = {metafield = "second-", __index = fn(self) "last"}
        \\ const t = set_metatable({normal = "first-"}, mt)
        \\ t.normal + t.metafield + t.something
    , "first-second-last");
}

test "computed table keys use runtime values" {
    try tt.top_number(
        \\ const key = "answer"
        \\ const t = {[key] = 41}
        \\ t["answer"]
    , 41);

    try tt.top_number(
        \\ const k = :x
        \\ const t = {[k] = 9}
        \\ t.x
    , 9);
}

