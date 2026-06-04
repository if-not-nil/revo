// a table is a value that maps keys to values. keys can be numbers, atoms,
// strings, tables, tuples, or functions. values can be anything
//
// integer keys (non-negative, finite, whole numbers) have special behavior:
// sequential keys 0, 1, 2, ... fill contiguous slots. a gap -- like setting
// index 6 when only index 0 exists -- stores the value as a keyed entry
// instead of padding empty slots. negative numbers, nan, inf, and floats
// like 1.5 are always keyed entries
//
// iteration visits integer slots first in numeric order, then keyed entries
// in insertion order. this makes `fmt("%t", t)` predictable
//
// assignment to an existing key overwrites the old value, whether it's an
// integer slot or a keyed entry
//
// equality is by identity: `{a = 1} == {a = 1}` is false -- two literals
// are different tables

const std = @import("std");

const revo = @import("revo");

const memory = revo.memory;
const Data = memory.Data;
const testing = revo.lang.testing;

pub const TablePool = struct {
    alloc: std.mem.Allocator,
    tables: std.ArrayList(?Table),
    marks: std.DynamicBitSet,
    dead: std.ArrayList(memory.TableID),

    pub fn init(alloc: std.mem.Allocator) !TablePool {
        return .{
            .alloc = alloc,
            .tables = try std.ArrayList(?Table).initCapacity(alloc, 4),
            .marks = try std.DynamicBitSet.initEmpty(alloc, 64),
            .dead = try std.ArrayList(memory.TableID).initCapacity(alloc, 0),
        };
    }

    pub fn deinit(self: *TablePool) void {
        for (self.tables.items) |*maybe_t| {
            if (maybe_t.*) |*t| t.deinit();
        }
        self.tables.deinit(self.alloc);
        self.marks.deinit();
        self.dead.deinit(self.alloc);
    }

    pub fn create(self: *TablePool) !memory.TableID {
        if (self.dead.pop()) |id| {
            self.tables.items[id] = try Table.init(self.alloc);
            return id;
        }
        const id: memory.TableID = @intCast(self.tables.items.len);
        try self.tables.append(self.alloc, try Table.init(self.alloc));
        if (id >= self.marks.capacity()) {
            try self.marks.resize(self.tables.items.len, false);
        }
        return id;
    }

    pub fn get(self: *TablePool, id: memory.TableID) !*Table {
        if (id >= self.tables.items.len) return error.InvalidTable;
        if (self.tables.items[id]) |*t| return t;
        return error.InvalidTable;
    }

    pub fn isValid(self: *const TablePool, id: memory.TableID) bool {
        return id < self.tables.items.len and self.tables.items[id] != null;
    }

    pub fn mark(self: *TablePool, id: memory.TableID, vm: *revo.VM) void {
        if (id >= self.tables.items.len) return;
        if (self.marks.isSet(id)) return;
        if (self.tables.items[id] == null) return;
        self.marks.set(id);
        vm.pushMarkTable(id);
    }

    pub fn sweep(self: *TablePool) void {
        const max_dead = self.tables.items.len;
        self.dead.ensureTotalCapacity(self.alloc, max_dead) catch return;
        self.dead.items.len = 0;
        for (self.tables.items, 0..) |*maybe_t, idx| {
            if (maybe_t.* == null) continue;
            if (self.marks.isSet(idx)) continue;
            maybe_t.*.?.deinit();
            maybe_t.* = null;
            self.dead.appendAssumeCapacity(@intCast(idx));
        }
        self.marks.unmanaged.unsetAll();
    }

    pub fn bytes(self: *const TablePool) usize {
        var total: usize = 0;
        for (self.tables.items) |maybe_t| {
            if (maybe_t) |t| total += t.bytes();
        }
        return total;
    }

    pub fn clearMarks(self: *TablePool) void {
        self.marks.unmanaged.unsetAll();
    }

    pub fn capacity(self: *const TablePool) usize {
        return self.tables.items.len;
    }

    /// process up to `limit` items starting from `cursor`
    /// ret n of processed
    pub fn sweepStep(self: *TablePool, cursor: usize, limit: usize) usize {
        if (cursor >= self.tables.items.len) return 0;

        const end = @min(cursor + limit, self.tables.items.len);
        var processed: usize = 0;

        var i = cursor;
        while (i < end) : (i += 1) {
            if (self.tables.items[i]) |*t| {
                if (!self.marks.isSet(i)) {
                    t.deinit();
                    self.tables.items[i] = null;
                    self.dead.append(self.alloc, @intCast(i)) catch {};
                }
            }
            processed += 1;
        }

        return processed;
    }
};

pub const Table = struct {
    fn hashKey(key: Data) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(&[_]u8{@intCast(@intFromEnum(key.tag()))});
        switch (key.tag()) {
            .number => {
                const bits: u64 = key.rawBits();
                h.update(std.mem.asBytes(&bits));
            },
            else => {
                h.update(std.mem.asBytes(&key.unboxed()));
            },
        }
        return h.final();
    }

    /// open-addressing hash table with linear probing, power-of-2 sizing,
    /// and an embedded doubly-linked list for insertion order iteration
    ///
    /// i didn't translate lua's implementation 1-1 -- it complicates insertion-deletion
    ///     revo tables tend to be small and you would not often delete things individually
    ///
    /// i didn't use std.HashMap because insertion order has to be preserved
    /// bench/table.rv:
    ///     HashPart                   @ 0.627s
    ///     std.HashMap and atom_order @ 0.912s
    ///
    /// this is the simplest, and likely fastest in practice, out of three
    const HashPart = struct {
        buckets: []Bucket = &.{},
        count: u32 = 0,
        first: ?u32 = null,
        last: ?u32 = null,

        const INIT_CAP = 4;
        const MAX_LOAD = 75; // percent

        const Bucket = struct {
            status: enum(u8) { empty, occupied } = .empty,
            key: Data = undefined,
            val: Data = undefined,
            next: ?u32 = null,
            prev: ?u32 = null,
        };

        fn deinit(self: *HashPart, alloc: std.mem.Allocator) void {
            alloc.free(self.buckets);
            self.* = .{};
        }

        fn lookup(self: *const HashPart, key: Data) ?u32 {
            if (self.buckets.len == 0) return null;
            const mask = @as(u32, @intCast(self.buckets.len - 1));
            var idx = @as(u32, @truncate(hashKey(key))) & mask;
            while (self.buckets[idx].status == .occupied) {
                if (keyEq(self.buckets[idx].key, key)) return idx;
                idx = (idx + 1) & mask;
            }
            return null;
        }

        fn get(self: *const HashPart, key: Data) ?Data {
            const idx = self.lookup(key) orelse return null;
            return self.buckets[idx].val;
        }

        fn getPtr(self: *HashPart, key: Data) ?*Data {
            const idx = self.lookup(key) orelse return null;
            return &self.buckets[idx].val;
        }

        fn getOrPut(self: *HashPart, alloc: std.mem.Allocator, key: Data) !*Data {
            if (self.buckets.len == 0 or self.count * 100 > self.buckets.len * MAX_LOAD)
                try self.grow(alloc);

            const mask = @as(u32, @intCast(self.buckets.len - 1));
            var idx = @as(u32, @truncate(hashKey(key))) & mask;
            while (self.buckets[idx].status == .occupied) {
                if (keyEq(self.buckets[idx].key, key))
                    return &self.buckets[idx].val;
                idx = (idx + 1) & mask;
            }

            self.buckets[idx] = .{
                .status = .occupied,
                .key = key,
                .val = undefined,
                .next = null,
                .prev = self.last,
            };
            if (self.last) |l| self.buckets[l].next = idx else self.first = idx;
            self.last = idx;
            self.count += 1;

            return &self.buckets[idx].val;
        }

        fn grow(self: *HashPart, alloc: std.mem.Allocator) !void {
            const new_len = if (self.buckets.len == 0) @as(u32, INIT_CAP) else @as(u32, @truncate(self.buckets.len * 2));
            const new_buckets = try alloc.alloc(Bucket, new_len);
            @memset(new_buckets, .{});

            var new_first: ?u32 = null;
            var new_last: ?u32 = null;
            var cur = self.first;

            while (cur) |old_idx| {
                const old = &self.buckets[old_idx];
                var ni = @as(u32, @truncate(hashKey(old.key) & (new_len - 1)));
                while (new_buckets[ni].status == .occupied)
                    ni = (ni + 1) & (new_len - 1);

                new_buckets[ni] = .{
                    .status = .occupied,
                    .key = old.key,
                    .val = old.val,
                    .next = null,
                    .prev = new_last,
                };
                if (new_last) |l| new_buckets[l].next = ni else new_first = ni;
                new_last = ni;
                cur = old.next;
            }

            alloc.free(self.buckets);
            self.buckets = new_buckets;
            self.first = new_first;
            self.last = new_last;
        }

        fn clone(self: *const HashPart, alloc: std.mem.Allocator) !HashPart {
            if (self.buckets.len == 0) return .{};
            const cp = try alloc.dupe(Bucket, self.buckets);
            return .{ .buckets = cp, .count = self.count, .first = self.first, .last = self.last };
        }

        pub const OrderedIter = struct {
            part: *const HashPart,
            cur: ?u32,

            pub fn next(it: *OrderedIter) ?struct { key: Data, val: Data } {
                const idx = it.cur orelse return null;
                const b = &it.part.buckets[idx];
                it.cur = b.next;
                return .{ .key = b.key, .val = b.val };
            }
        };

        pub fn orderedIterator(self: *const HashPart) OrderedIter {
            return .{ .part = self, .cur = self.first };
        }
    };

    alloc: std.mem.Allocator,
    array: std.ArrayList(Data),
    hash: HashPart,
    metatable: ?memory.TableID = null,
    ic_version: usize = 0,
    metamethod_cache: u64 = 0,

    pub fn init(alloc: std.mem.Allocator) !Table {
        return .{
            .alloc = alloc,
            .array = try std.ArrayList(Data).initCapacity(alloc, 0),
            .hash = .{},
        };
    }

    pub fn deinit(self: *Table) void {
        self.array.deinit(self.alloc);
        self.hash.deinit(self.alloc);
    }

    fn keyEq(a: Data, b: Data) bool {
        if (a.tag() != b.tag()) return false;
        return switch (a.tag()) {
            .number => a.rawBits() == b.rawBits(),
            .string => a.asString().? == b.asString().?,
            .atom => a.asAtom().? == b.asAtom().?,
            .function => a.asFunction().? == b.asFunction().?,
            .table => a.asTable().? == b.asTable().?,
            .tuple => a.asTuple().? == b.asTuple().?,
            .struct_val => a.asStructVal().? == b.asStructVal().?,
            .struct_type => a.asStructType().? == b.asStructType().?,
        };
    }

    fn integerArrayIndex(key: Data) ?usize {
        const n = key.asNum() orelse return null;
        return if (n < 0 or !std.math.isFinite(n) or @floor(n) != n) null else @as(usize, @intFromFloat(n));
    }

    pub fn put(self: *Table, table_id: memory.TableID, vm: *revo.VM, key: Data, val: Data) !void {
        self.ic_version +%= 1;
        if (self.metatable == null) {
            return self.putRaw(key, val);
        }

        const mt_id = self.metatable.?;
        const mt = try vm.tables.get(mt_id);

        if (mt.getRaw(Data.new.atom(revo.core_atoms.atom_id(.__newindex)))) |newindex_method| {
            if (newindex_method.asFunction()) |f| {
                const table_data = Data.new.table(table_id);
                _ = try vm.callFunction(Data.new.function(f), &[_]Data{ table_data, key, val });
                return;
            }
        }

        return self.putRaw(key, val);
    }

    pub fn putRaw(self: *Table, key: Data, val: Data) !void {
        self.ic_version +%= 1;
        self.metamethod_cache = 0;
        if (integerArrayIndex(key)) |idx| {
            if (idx < self.array.items.len) {
                self.array.items[idx] = val;
                return;
            } else if (idx == self.array.items.len) {
                try self.push(val);
                return;
            } // else fallback to hash
        }

        const entry = try self.hash.getOrPut(self.alloc, key);
        entry.* = val;
    }

    pub inline fn push(self: *Table, val: Data) !void {
        try self.array.append(self.alloc, val);
    }

    pub inline fn getRaw(self: *Table, key: Data) ?Data {
        if (integerArrayIndex(key)) |idx| {
            if (idx < self.array.items.len) {
                return self.array.items[idx];
            }
        }
        return self.hash.get(key);
    }

    const MAX_TAG_LOOP = 200;

    pub fn get(self: *Table, key: Data, vm: *revo.VM) !?Data {
        return self.getWithDepth(key, vm, MAX_TAG_LOOP);
    }

    fn getWithDepth(self: *Table, key: Data, vm: *revo.VM, depth: usize) !?Data {
        if (self.getRaw(key)) |value| return value;
        if (depth == 0) return null;
        if (self.metatable) |mt_id| {
            const mt = try vm.tables.get(mt_id);
            if (mt.getRaw(Data.new.atom(revo.core_atoms.atom_id(.__index)))) |index_method| {
                if (index_method.asTable()) |table_id| {
                    const index_table = try vm.tables.get(table_id);
                    return try index_table.getWithDepth(key, vm, depth - 1);
                }
                if (index_method.asFunction() != null) return null;
            }
        }
        return null;
    }

    pub fn mark(self: *Table, vm: *revo.VM) void {
        for (self.array.items) |entry|
            vm.markData(entry);

        var cur = self.hash.first;
        while (cur) |idx| {
            vm.markData(self.hash.buckets[idx].key);
            vm.markData(self.hash.buckets[idx].val);
            cur = self.hash.buckets[idx].next;
        }
    }

    pub fn count(self: *const Table) usize {
        return self.array.items.len + self.hash.count;
    }

    pub fn bytes(self: *const Table) usize {
        const array_bytes = self.array.items.len * @sizeOf(Data);
        const hash_bytes = self.hash.buckets.len * @sizeOf(HashPart.Bucket);
        return @sizeOf(Table) + array_bytes + hash_bytes;
    }

    pub const write = revo.vm.print.writeTable;
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

//
// integer array index boundary tests
//

test "putRaw: integer key in range 0..<len overwrites existing element" {
    var table = try Table.init(std.testing.allocator);
    defer table.deinit();
    try table.push(Data.new.num(10));
    try table.push(Data.new.num(20));
    try table.push(Data.new.num(30));

    try table.putRaw(Data.new.num(1), Data.new.num(99));
    try std.testing.expectEqual(@as(usize, 3), table.array.items.len);
    try std.testing.expectEqual(Data.new.num(10), table.array.items[0]);
    try std.testing.expectEqual(Data.new.num(99), table.array.items[1]);
    try std.testing.expectEqual(Data.new.num(30), table.array.items[2]);
}

test "putRaw: integer key == len appends to array" {
    var table = try Table.init(std.testing.allocator);
    defer table.deinit();
    try table.push(Data.new.num(10));
    try table.push(Data.new.num(20));

    try table.putRaw(Data.new.num(2), Data.new.num(30));
    try std.testing.expectEqual(@as(usize, 3), table.array.items.len);
    try std.testing.expectEqual(Data.new.num(30), table.array.items[2]);
}

test "putRaw: integer key > len goes to hash" {
    var table = try Table.init(std.testing.allocator);
    defer table.deinit();
    try table.push(Data.new.num(10));

    try table.putRaw(Data.new.num(5), Data.new.num(99));
    try std.testing.expectEqual(@as(usize, 1), table.array.items.len);
    try std.testing.expectEqual(Data.new.num(99), table.hash.get(Data.new.num(5)).?);
}

test "putRaw: negative integer key always goes to hash" {
    var table = try Table.init(std.testing.allocator);
    defer table.deinit();
    try table.push(Data.new.num(10));

    try table.putRaw(Data.new.num(-1), Data.new.num(99));
    try std.testing.expectEqual(@as(usize, 1), table.array.items.len);
    try std.testing.expectEqual(Data.new.num(99), table.hash.get(Data.new.num(-1)).?);
}

test "putRaw: float key always goes to hash" {
    var table = try Table.init(std.testing.allocator);
    defer table.deinit();

    try table.putRaw(Data.new.num(1.5), Data.new.num(99));
    try std.testing.expectEqual(@as(usize, 0), table.array.items.len);
    try std.testing.expectEqual(Data.new.num(99), table.hash.get(Data.new.num(1.5)).?);
}

test "putRaw: NaN and Infinity keys go to hash" {
    var table = try Table.init(std.testing.allocator);
    defer table.deinit();

    try table.putRaw(Data.new.num(std.math.nan(f64)), Data.new.num(1));
    try table.putRaw(Data.new.num(std.math.inf(f64)), Data.new.num(2));
    try std.testing.expectEqual(@as(usize, 0), table.array.items.len);
    try std.testing.expectEqual(@as(usize, 2), table.hash.count);
}

test "putRaw: getRaw retrieves from array for integer keys" {
    var table = try Table.init(std.testing.allocator);
    defer table.deinit();
    try table.push(Data.new.num(10));
    try table.push(Data.new.num(20));

    try std.testing.expectEqual(Data.new.num(10), table.getRaw(Data.new.num(0)).?);
    try std.testing.expectEqual(Data.new.num(20), table.getRaw(Data.new.num(1)).?);
    try std.testing.expectEqual(null, table.getRaw(Data.new.num(2)));
}

test "putRaw: getRaw retrieves from hash for negative and float keys" {
    var table = try Table.init(std.testing.allocator);
    defer table.deinit();
    try table.putRaw(Data.new.num(-1), Data.new.num(42));
    try table.putRaw(Data.new.num(1.5), Data.new.num(99));

    try std.testing.expectEqual(Data.new.num(42), table.getRaw(Data.new.num(-1)).?);
    try std.testing.expectEqual(Data.new.num(99), table.getRaw(Data.new.num(1.5)).?);
}

test "putRaw: integer key > len in empty table goes to hash" {
    var table = try Table.init(std.testing.allocator);
    defer table.deinit();

    try table.putRaw(Data.new.num(0), Data.new.num(10));
    try std.testing.expectEqual(@as(usize, 1), table.array.items.len);
    try std.testing.expectEqual(Data.new.num(10), table.array.items[0]);

    try table.putRaw(Data.new.num(6), Data.new.num(42));
    try std.testing.expectEqual(@as(usize, 1), table.array.items.len);
    try std.testing.expectEqual(Data.new.num(42), table.hash.get(Data.new.num(6)).?);

    try table.putRaw(Data.new.num(1), Data.new.num(20));
    try std.testing.expectEqual(@as(usize, 2), table.array.items.len);
    try std.testing.expectEqual(Data.new.num(20), table.array.items[1]);
}

//
// full
//

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

test "array-style table literal" {
    try testing.top_number(
        \\ const tbl = {10, 20, 30}
        \\ tbl[0] + tbl[1] + tbl[2]
    , 60);
}

test "numeric and string keys are distinct" {
    try testing.top_number(
        \\ const t = {}
        \\ t[1] = 100
        \\ t["1"] = 200
        \\ t[1] + t["1"]
    , 300);
}

test "metatable __tostring works on tables" {
    try testing.top_string(
        \\ const mt = {__tostring = fn(self) "custom"}
        \\ const t = set_metatable({a = 1}, mt)
        \\ tostring(t)
    , "custom");
}

test "metatable __index for field access" {
    try testing.top_number(
        \\ const mt = {__index = fn(self, key) 42}
        \\ const t = set_metatable({}, mt)
        \\ t.missing_field
    , 42);
}

test "metatable __newindex for field assignment" {
    try testing.top_number(
        \\ const mt = {__newindex = fn(self, key, value) table.rawset(self, key, 99)}
        \\ const t = set_metatable({}, mt)
        \\ t.x = 5
        \\ t.x
    , 99);
}

test "multiple tables can share same metatable" {
    try testing.top_true(
        \\ const mt = {get_val = fn(self) 77}
        \\ const t1 = set_metatable({}, mt)
        \\ const t2 = set_metatable({x = 1}, mt)
        \\ t1:get_val() == 77 and t2:get_val() == 77
    );
}

test "get_metatable retrieves correct metatable" {
    try testing.top_true(
        \\ const mt = {get_val = fn(self) 50}
        \\ const t = set_metatable({}, mt)
        \\ const retrieved_mt = get_metatable(t)
        \\ retrieved_mt == mt
    );
}

test "metatable on metatable works" {
    try testing.top_number(
        \\ const mt = {get_val = fn(self) 9}
        \\ const t = set_metatable({}, mt)
        \\ t:get_val()
    , 9);
}

test "metamethod failures are runtime errors" {
    try testing.expectRuntimeFailureWithMessage(
        \\ const mt = {__tostring = fn(self) panic("boom")}
        \\ const t = set_metatable({}, mt)
        \\ tostring(t)
    , .Panic, "boom");
}

test "method calls on metatable tables work" {
    try testing.top_number(
        \\ const mt = {get_x = fn(self) self.x}
        \\ const t = set_metatable({x = 12}, mt)
        \\ t:get_x()
    , 12);
}

test "non-table values can use metatable fields as methods" {
    try testing.top_string(
        \\ const mt = {reverse = fn(self) "fdsa"}
        \\ set_metatable("", mt)
        \\ "asdf":reverse()
    , "fdsa");
}

test "pipe: explicit placeholder method receiver with table" {
    try testing.top_number(
        \\ const obj = { inner = 40, meth = fn(self, x) self.inner + x }
        \\ obj |> _:meth(2)
    , 42);
}

test "pipe: explicit placeholder index access with table" {
    try testing.top_number(
        \\ const t = {5, 6, 7}
        \\ 1 |> t[_]
    , 6);
}
