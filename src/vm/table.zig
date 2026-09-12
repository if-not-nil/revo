// a table is a value that maps keys to values. keys can be numbers, atoms,
// strings, tables, or functions. values can be anything
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
// equality is by value: `{a = 1} == {a = 1}` is true -- array part
// in order, then keyed entries

const std = @import("std");

const revo = @import("revo");

const memory = revo.memory;
const Data = memory.Data;
const testing = revo.lang.testing;
const fastEq = @import("compare.zig").fastEq;
const pool = @import("pool.zig");

pub const NULL_ID = std.math.maxInt(u32);

pub const TablePool = struct {
    alloc: std.mem.Allocator,
    // tables are boxed: the slot array holds stable *Table pointers, so a
    // pointer from get() stays valid across later create() calls. the slot
    // ArrayList's backing store may still move, but the boxed Table it points
    // to does not. boxes are allocated from box_pool (arena-backed for
    // locality) and recycled through the dead list, same as the ids.
    box_pool: std.heap.MemoryPool(Table),
    tables: std.ArrayList(?*Table),
    marks: std.DynamicBitSet,
    dead: std.ArrayList(memory.TableID),
    first: usize = pool.end,
    last: usize = pool.end,
    next: std.ArrayList(usize),

    pub fn init(alloc: std.mem.Allocator) !TablePool {
        return TablePool{
            .alloc = alloc,
            .box_pool = .empty,
            .tables = try .initCapacity(alloc, 4),
            .marks = try .initEmpty(alloc, 64),
            .dead = .empty,
            .next = try .initCapacity(alloc, 4),
        };
    }

    pub fn deinit(self: *TablePool) void {
        for (self.tables.items) |maybe_t| {
            if (maybe_t) |t| t.deinit(self.alloc);
        }
        self.box_pool.deinit(self.alloc);
        self.tables.deinit(self.alloc);
        self.marks.deinit();
        self.dead.deinit(self.alloc);
        self.next.deinit(self.alloc);
    }

    pub fn create(self: *TablePool) !memory.TableID {
        if (self.dead.pop()) |id| {
            const t = self.tables.items[id].?;
            t.metatable = null;
            self.marks.unset(id);
            pool.relink(&self.first, &self.last, &self.next, id);
            return id;
        }
        const id: memory.TableID = @intCast(self.tables.items.len);
        if (id >= self.marks.capacity()) {
            try self.marks.resize(id + 1, false);
        }

        const box = try self.box_pool.create(self.alloc);
        errdefer self.box_pool.destroy(box);
        box.* = Table.init();

        try self.tables.append(self.alloc, box);
        errdefer _ = self.tables.pop();

        try pool.link(&self.first, &self.last, &self.next, self.alloc, id);
        return id;
    }

    pub fn get(self: *TablePool, id: memory.TableID) !*Table {
        if (id >= self.tables.items.len) @panic("invalid table :<");
        if (self.tables.items[id]) |t| return t;
        @panic("invalid table :<");
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
        const alloc = self.alloc;
        // boxes are retained and recycled through the dead list, so sweep frees
        // each dead table's contents in place and leaves survivors' slots put.
        // this mirrors pool.sweep but keeps the boxed *Table stable.
        _ = self.dead.ensureTotalCapacity(alloc, self.dead.items.len + self.tables.items.len) catch return;
        var prev: usize = pool.end;
        var id = self.first;
        while (id != pool.end) {
            const nxt = self.next.items[id];
            const t = self.tables.items[id].?;
            if (!self.marks.isSet(id)) {
                freeTable(t, alloc);
                if (prev == pool.end) self.first = nxt else self.next.items[prev] = nxt;
                self.dead.appendAssumeCapacity(@intCast(id));
            } else {
                self.marks.unset(id);
                prev = id;
            }
            id = nxt;
        }
        self.last = prev;
    }

    pub fn bytes(self: *const TablePool) usize {
        var total: usize = 0;
        var id = self.first;
        while (id != pool.end) {
            total += self.tables.items[id].?.bytes();
            id = self.next.items[id];
        }
        return total;
    }

    pub fn clearMarks(self: *TablePool) void {
        self.marks.unmanaged.unsetAll();
    }

    pub fn capacity(self: *const TablePool) usize {
        return self.tables.items.len;
    }
};

// keep the dense array buffer across GC sweeps for reused tables (bounded by
// MAX_RETAINED_ARRAY so pathological workloads can't pin unbounded memory);
// the hash buckets are always freed. integer-keyed workloads that refill the
// same small tables repeatedly skip the per-fill
// growth reallocation and its memcpy
//
// todo ab bench towers storage nogc
const MAX_RETAINED_ARRAY = 16;

fn freeTable(t: *Table, alloc: std.mem.Allocator) void {
    if (t.array.capacity > MAX_RETAINED_ARRAY) {
        t.array.deinit(alloc);
        t.array = .empty;
    } else {
        t.array.clearRetainingCapacity();
    }
    t.hash.deinit(alloc);
    t.metatable = null;
}

pub const Table = struct {
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
        first: u32 = NULL_ID,
        last: u32 = NULL_ID,

        const INIT_CAP = 4;
        const MAX_LOAD = 75; // percent

        const Bucket = struct {
            status: enum(u8) { empty, occupied } = .empty,
            key: Data = Data.new.nil(),
            value: Data = Data.new.nil(),
            // cached key hash
            // ~ computed once at insertion
            // ~ grow() and remove()'s backward-shift repair both
            //   need each stored key's hash again later
            //   reading it here avoids rehashing string
            //   content they already hashed once
            hash: u64 = 0,
            next: u32 = NULL_ID,
            prev: u32 = NULL_ID,
        };

        fn deinit(self: *HashPart, alloc: std.mem.Allocator) void {
            alloc.free(self.buckets);
            self.* = .{};
        }

        fn lookup(self: *const HashPart, key: Data, vm: *revo.VM) ?u32 {
            if (self.buckets.len == 0) return null;
            const mask: u32 = @intCast(self.buckets.len - 1);
            var idx = @as(u32, @truncate(key.hash(vm))) & mask;
            const limit: u32 = self.count;
            var probes: u32 = 0;

            while (self.buckets[idx].status == .occupied) {
                if (fastEq(vm, self.buckets[idx].key, key)) return idx;
                idx = (idx + 1) & mask;
                probes += 1;
                if (probes >= limit) return null;
            }
            return null;
        }

        fn get(self: *const HashPart, key: Data, vm: *revo.VM) ?Data {
            const idx = self.lookup(key, vm) orelse return null;
            return self.buckets[idx].value;
        }

        fn getPtr(self: *HashPart, key: Data, vm: *revo.VM) ?*Data {
            const idx = self.lookup(key, vm) orelse return null;
            return &self.buckets[idx].value;
        }

        fn getOrPut(self: *HashPart, alloc: std.mem.Allocator, key: Data, vm: *revo.VM) !*Data {
            if (self.buckets.len == 0 or self.count * 100 > self.buckets.len * MAX_LOAD)
                try self.grow(alloc, vm);

            const mask: u32 = @intCast(self.buckets.len - 1);
            const kh = key.hash(vm);
            var idx = @as(u32, @truncate(kh)) & mask;

            while (self.buckets[idx].status == .occupied) {
                if (fastEq(vm, self.buckets[idx].key, key))
                    return &self.buckets[idx].value;
                idx = (idx + 1) & mask;
            }

            self.buckets[idx] = .{
                .status = .occupied,
                .key = key,
                .hash = kh,
                .next = NULL_ID,
                .prev = self.last,
            };

            if (self.last != NULL_ID) self.buckets[self.last].next = idx;
            self.first = if (self.first == NULL_ID) idx else self.first;
            self.last = idx;
            self.count += 1;

            return &self.buckets[idx].value;
        }

        fn grow(self: *HashPart, alloc: std.mem.Allocator, vm: *revo.VM) !void {
            // bucket hashes are cached now,
            // so we dontn need to re-hash keys here
            _ = vm;

            const new_len = if (self.buckets.len == 0) @as(u32, INIT_CAP) else @as(
                u32,
                @truncate(self.buckets.len * 2),
            );

            const new_buckets = try alloc.alloc(Bucket, new_len);
            @memset(new_buckets, .{});

            var new_first: u32 = NULL_ID;
            var new_last: u32 = NULL_ID;
            var cur = self.first;

            while (cur != NULL_ID) {
                const old = &self.buckets[cur];
                var ni: u32 = @truncate(old.hash & (new_len - 1));
                while (new_buckets[ni].status == .occupied)
                    ni = (ni + 1) & (new_len - 1);

                new_buckets[ni] = .{
                    .status = .occupied,
                    .key = old.key,
                    .value = old.value,
                    .hash = old.hash,
                    .next = NULL_ID,
                    .prev = new_last,
                };
                if (new_last != NULL_ID) new_buckets[new_last].next = ni;
                new_first = if (new_first == NULL_ID) ni else new_first;
                new_last = ni;
                cur = old.next;
            }

            alloc.free(self.buckets);
            self.buckets = new_buckets;
            self.first = new_first;
            self.last = new_last;
        }

        fn remove(self: *HashPart, key: Data, vm: *revo.VM) ?u32 {
            const idx = self.lookup(key, vm) orelse return null;
            const mask: u32 = @intCast(self.buckets.len - 1);

            // unlink from insertion-order list
            if (self.buckets[idx].prev != NULL_ID) self.buckets[self.buckets[idx].prev].next = self.buckets[idx].next;
            if (self.buckets[idx].prev == NULL_ID) self.first = self.buckets[idx].next;
            if (self.buckets[idx].next != NULL_ID) self.buckets[self.buckets[idx].next].prev = self.buckets[idx].prev;
            if (self.buckets[idx].next == NULL_ID) self.last = self.buckets[idx].prev;

            self.buckets[idx].status = .empty;
            self.count -= 1;

            // repair probe sequence: re-place elements displaced by the removed one
            var hole = idx;
            var probe = (hole + 1) & mask;
            while (self.buckets[probe].status == .occupied) : (probe = (probe + 1) & mask) {
                const natural: u32 = @truncate(self.buckets[probe].hash & mask);
                const in_range = if (hole < probe)
                    natural > hole and natural <= probe
                else
                    natural > hole or natural <= probe;
                if (in_range) continue;

                self.buckets[hole] = self.buckets[probe];
                if (self.buckets[hole].prev != NULL_ID) self.buckets[self.buckets[hole].prev].next = hole;
                if (self.buckets[hole].prev == NULL_ID) self.first = hole;
                if (self.buckets[hole].next != NULL_ID) self.buckets[self.buckets[hole].next].prev = hole;
                if (self.buckets[hole].next == NULL_ID) self.last = hole;
                self.buckets[probe].status = .empty;
                hole = probe;
            }

            return idx;
        }

        pub fn removeAndReturn(self: *HashPart, key: Data, vm: *revo.VM) ?Data {
            const idx = self.remove(key, vm) orelse return null;
            return self.buckets[idx].value;
        }

        fn clone(self: *const HashPart, alloc: std.mem.Allocator) !HashPart {
            if (self.buckets.len == 0) return .{};
            const cp = try alloc.dupe(Bucket, self.buckets);
            return .{ .buckets = cp, .count = self.count, .first = self.first, .last = self.last };
        }

        pub const OrderedIter = struct {
            part: *const HashPart,
            cur: ?u32,

            pub fn next(it: *OrderedIter) ?KeyValue {
                const idx = it.cur orelse return null;
                const b = &it.part.buckets[idx];
                it.cur = if (b.next != NULL_ID) @as(?u32, b.next) else null;
                return .{ .key = b.key, .value = b.value };
            }
        };

        pub fn orderedIterator(self: *const HashPart) OrderedIter {
            return .{ .part = self, .cur = if (self.first != NULL_ID) @as(?u32, self.first) else null };
        }
    };

    array: SmallArray,
    hash: HashPart,
    metatable: ?memory.TableID = null,

    pub fn init() Table {
        return .{
            .array = .empty,
            .hash = .{},
        };
    }

    pub fn deinit(self: *Table, alloc: std.mem.Allocator) void {
        self.array.deinit(alloc);
        self.hash.deinit(alloc);
    }

    /// array part with a few inline slots
    ///
    /// : small tables never touch the heap for sequential integer keys
    /// `.items` stays a valid contiguous slice on both backings
    /// , so readers never branch; only growth transitions
    const ARRAY_INLINE = 4;

    const SmallArray = struct {
        items: []Data = &.{},
        capacity: usize = 0,
        inline_buf: [ARRAY_INLINE]Data,

        // safety:
        // inline slots are only read below items.len, which extends
        // past a slot only after that slot is written (append/insert) or
        // bulk-copied from a valid source (grow/appendSlice)
        pub const empty: SmallArray = .{ .items = &.{}, .capacity = 0, .inline_buf = undefined };

        fn isInline(self: *const SmallArray) bool {
            return self.capacity != 0 and @intFromPtr(self.items.ptr) == @intFromPtr(&self.inline_buf);
        }

        pub fn ensureTotalCapacity(self: *SmallArray, alloc: std.mem.Allocator, new_capacity: usize) !void {
            if (new_capacity <= self.capacity) return;
            if (self.capacity == 0) {
                // fresh
                // the inline slots cover the first ARRAY_INLINE for free
                self.items = self.inline_buf[0..0];
                self.capacity = ARRAY_INLINE;
                if (new_capacity <= self.capacity) return;
            }
            // standard doubling continues from 4, same curve as before
            const better = @max(new_capacity, self.capacity * 2);

            if (self.isInline()) {
                const grown = try alloc.alloc(Data, better);
                @memcpy(grown[0..self.items.len], self.items);
                self.items = grown[0..self.items.len];
                self.capacity = better;
            } else {
                const grown = try alloc.realloc(self.items.ptr[0..self.capacity], better);
                self.items = grown[0..self.items.len];
                self.capacity = better;
            }
        }

        pub fn append(self: *SmallArray, alloc: std.mem.Allocator, val: Data) !void {
            try self.ensureTotalCapacity(alloc, self.items.len + 1);
            self.items.len += 1;
            self.items[self.items.len - 1] = val;
        }

        pub fn appendSlice(self: *SmallArray, alloc: std.mem.Allocator, items: []const Data) !void {
            try self.ensureTotalCapacity(alloc, self.items.len + items.len);
            const at = self.items.len;
            self.items.len += items.len;
            @memcpy(self.items[at..], items);
        }

        pub fn insert(self: *SmallArray, alloc: std.mem.Allocator, idx: usize, val: Data) !void {
            try self.ensureTotalCapacity(alloc, self.items.len + 1);
            self.items.len += 1;
            std.mem.copyBackwards(Data, self.items[idx + 1 ..], self.items[idx .. self.items.len - 1]);
            self.items[idx] = val;
        }

        pub fn orderedRemove(self: *SmallArray, idx: usize) Data {
            const val = self.items[idx];
            std.mem.copyForwards(Data, self.items[idx .. self.items.len - 1], self.items[idx + 1 ..]);
            self.items.len -= 1;
            return val;
        }

        pub fn clearRetainingCapacity(self: *SmallArray) void {
            self.items.len = 0;
        }

        pub fn deinit(self: *SmallArray, alloc: std.mem.Allocator) void {
            if (self.capacity == 0 or self.isInline()) {
                self.* = .empty;
                return;
            }
            alloc.free(self.items.ptr[0..self.capacity]);
            self.* = .empty;
        }
    };

    fn integerArrayIndex(key: Data) ?usize {
        // numToI64 rejects +-inf, nan, and out-of-i64-range values, so only
        // the sign check is needed
        const n = memory.numToI64(key.asNum() orelse return null) orelse return null;
        return if (n < 0) null else @intCast(n);
    }

    pub fn put(self: *Table, table_id: memory.TableID, vm: *revo.VM, key: Data, val: Data) !void {
        if (self.metatable == null) {
            try self.putRaw(key, val, vm);
        } else {
            const mt_id = self.metatable.?;
            const mt = try vm.tables.get(mt_id);

            if (mt.getRawAtom(revo.core_atoms.atomId(.__newindex), vm)) |newindex_method| {
                if (newindex_method.asFunction()) |f| {
                    const table_data = Data.new.table(table_id);
                    _ = try vm.callFunctionParts(Data.new.function(f), null, &[_]Data{ table_data, key, val }, null);
                    return;
                }
            }

            try self.putRaw(key, val, vm);
        }
    }

    pub fn putRaw(self: *Table, key: Data, val: Data, vm: *revo.VM) !void {
        if (integerArrayIndex(key)) |idx| {
            if (idx < self.array.items.len) {
                self.array.items[idx] = val;
                return;
            } else if (idx == self.array.items.len) {
                try self.push(vm.runtime.alloc, val);
                return;
            } // else fallback to hash
        }

        const entry = try self.hash.getOrPut(vm.runtime.alloc, key, vm);
        entry.* = val;
    }

    pub fn putRawAtom(self: *Table, id: memory.AtomID, val: Data, vm: *revo.VM) !void {
        const entry = try self.hash.getOrPut(vm.runtime.alloc, Data.new.atom(id), vm);
        entry.* = val;
    }

    pub inline fn push(self: *Table, alloc: std.mem.Allocator, val: Data) !void {
        try self.array.append(alloc, val);
    }

    pub inline fn getRaw(self: *Table, key: Data, vm: *revo.VM) ?Data {
        if (integerArrayIndex(key)) |idx| {
            if (idx < self.array.items.len) {
                return self.array.items[idx];
            }
        }
        return self.hash.get(key, vm);
    }

    pub inline fn getRawAtom(self: *Table, id: memory.AtomID, vm: *revo.VM) ?Data {
        return self.hash.get(Data.new.atom(id), vm);
    }

    pub const KeyValue = struct {
        key: Data,
        value: Data,
    };

    /// cursor over array items first, then keyed entries in insertion order
    /// one obvious way to walk a whole table
    pub const Cursor = struct {
        array: []const Data,
        idx: usize = 0,
        hash: HashPart.OrderedIter,

        pub fn nextValue(self: *Cursor) ?Data {
            if (self.idx < self.array.len) {
                defer self.idx += 1;
                return self.array[self.idx];
            }
            return if (self.hash.next()) |entry| entry.value else null;
        }

        pub fn nextEntry(self: *Cursor) ?KeyValue {
            if (self.idx < self.array.len) {
                defer self.idx += 1;
                return .{ .key = Data.new.num(self.idx), .value = self.array[self.idx] };
            }
            const entry = self.hash.next() orelse return null;
            return .{ .key = entry.key, .value = entry.value };
        }
    };

    pub fn cursor(self: *const Table) Cursor {
        return .{ .array = self.array.items, .hash = self.hash.orderedIterator() };
    }

    /// walk keyed (non-integer) entries in insertion order
    pub fn keyedEntries(self: *const Table, alloc: std.mem.Allocator) ![]KeyValue {
        var out = try std.ArrayList(KeyValue).initCapacity(alloc, self.hash.count);
        var it = self.hash.orderedIterator();
        while (it.next()) |entry| out.appendAssumeCapacity(entry);
        return out.toOwnedSlice(alloc);
    }

    pub fn remove(self: *Table, key: Data, vm: *revo.VM) bool {
        if (integerArrayIndex(key)) |idx| {
            if (idx >= self.array.items.len) return false;
            _ = self.array.orderedRemove(idx);
            return true;
        }
        return self.hash.remove(key, vm) != null;
    }

    pub fn removeAndReturn(self: *Table, key: Data, vm: *revo.VM) ?Data {
        if (integerArrayIndex(key)) |idx| {
            if (idx >= self.array.items.len) return null;
            return self.array.orderedRemove(idx);
        }
        return self.hash.removeAndReturn(key, vm);
    }

    const MAX_TAG_LOOP = 200;

    pub inline fn get(self: *Table, key: Data, vm: *revo.VM) !?Data {
        return self.getWithDepth(key, vm, MAX_TAG_LOOP);
    }

    fn getWithDepth(self: *Table, key: Data, vm: *revo.VM, depth: usize) !?Data {
        if (self.getRaw(key, vm)) |value| return value;
        if (depth == 0) return null;
        if (self.metatable) |mt_id| {
            const mt = try vm.tables.get(mt_id);
            if (mt.getRawAtom(revo.core_atoms.atomId(.__index), vm)) |index_method| {
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
        var cur = self.cursor();
        while (cur.nextEntry()) |entry| {
            vm.markData(entry.key);
            vm.markData(entry.value);
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
    try testing.topNumber(
        \\ const t = {answer = 41, extra = 1}
        \\ t.answer + t.extra
    , 42);
}

test "table positional access" {
    try testing.topNumber(
        \\ const t = {41, 1}
        \\ t[0] + t[1]
    , 42);
}

test "table field assignment" {
    try testing.topNumber(
        \\ const t = {answer = 41}
        \\ t.answer = t.answer + 1
        \\ t.answer
    , 42);
}

test "table with positional elements" {
    try testing.topNumber(
        \\ const t = {10, 20, 30}
        \\ t[0] + t[1] + t[2]
    , 60);
}

test "mixed table with positional and named entries" {
    try testing.topNumber(
        \\ const t = {100, 30, x = 20}
        \\ t[0] + t[1] + t.x
    , 150);
}

test "table numeric key canonicalization" {
    try testing.topNumber(
        \\ const t = {1 = 41}
        \\ t[1.0] + 1
    , 42);

    try testing.topNumber(
        \\ const t = {1.0 = 41}
        \\ t[1] + 1
    , 42);
}

test "table float keys stay distinct when non integral" {
    try testing.topNumber(
        \\ const t = {1 = 1, 1.5 = 41}
        \\ t[1] + t[1.5]
    , 42);
}

test "table push appends positional values" {
    var vm = try revo.VM.init(testing.runtime());
    defer vm.deinit();
    var table = Table.init();
    defer table.deinit(std.testing.allocator);

    try table.push(std.testing.allocator, Data.new.num(10));
    try table.push(std.testing.allocator, Data.new.num(20));
    try table.push(std.testing.allocator, Data.new.num(30));

    try std.testing.expectEqual(@as(usize, 3), table.count());
    try std.testing.expectEqual(Data.new.num(10), table.getRaw(Data.new.num(0), &vm).?);
    try std.testing.expectEqual(Data.new.num(20), table.getRaw(Data.new.num(1), &vm).?);
    try std.testing.expectEqual(Data.new.num(30), table.getRaw(Data.new.num(2), &vm).?);
}

test "boxed table pointers survive pool growth from create()" {
    var vm = try revo.VM.init(testing.runtime());
    defer vm.deinit();

    const id = try vm.tables.create();
    const t = try vm.tables.get(id); // pointer we intend to keep using
    try t.push(std.testing.allocator, Data.new.num(1));

    // grow the slot array far past its initial capacity. with inline (?Table)
    // storage this reallocation moved the slots and left `t` dangling; boxing
    // keeps the Table itself put, so `t` stays valid. (raw create() notes no gc
    // pressure, so nothing is swept mid-loop and the assertions are stable.)
    var i: usize = 0;
    while (i < 512) : (i += 1) _ = try vm.tables.create();

    try std.testing.expectEqual(@as(usize, 1), t.array.items.len);
    try t.push(std.testing.allocator, Data.new.num(2));
    try std.testing.expectEqual(@as(usize, 2), t.array.items.len);
    try std.testing.expectEqual(t, try vm.tables.get(id)); // same stable address
}

//
// integer array index boundary tests
//

test "putRaw: integer key in range 0..<len overwrites existing element" {
    var vm = try revo.VM.init(testing.runtime());
    defer vm.deinit();
    var table = Table.init();
    defer table.deinit(std.testing.allocator);
    try table.push(std.testing.allocator, Data.new.num(10));
    try table.push(std.testing.allocator, Data.new.num(20));
    try table.push(std.testing.allocator, Data.new.num(30));

    try table.putRaw(Data.new.num(1), Data.new.num(99), &vm);
    try std.testing.expectEqual(@as(usize, 3), table.array.items.len);
    try std.testing.expectEqual(Data.new.num(10), table.array.items[0]);
    try std.testing.expectEqual(Data.new.num(99), table.array.items[1]);
    try std.testing.expectEqual(Data.new.num(30), table.array.items[2]);
}

test "putRaw: integer key == len appends to array" {
    var vm = try revo.VM.init(testing.runtime());
    defer vm.deinit();
    var table = Table.init();
    defer table.deinit(std.testing.allocator);
    try table.push(std.testing.allocator, Data.new.num(10));
    try table.push(std.testing.allocator, Data.new.num(20));

    try table.putRaw(Data.new.num(2), Data.new.num(30), &vm);
    try std.testing.expectEqual(@as(usize, 3), table.array.items.len);
    try std.testing.expectEqual(Data.new.num(30), table.array.items[2]);
}

test "putRaw: integer key > len goes to hash" {
    var vm = try revo.VM.init(testing.runtime());
    defer vm.deinit();
    var table = Table.init();
    defer table.deinit(std.testing.allocator);
    try table.push(std.testing.allocator, Data.new.num(10));

    try table.putRaw(Data.new.num(5), Data.new.num(99), &vm);
    try std.testing.expectEqual(@as(usize, 1), table.array.items.len);
    try std.testing.expectEqual(Data.new.num(99), table.hash.get(Data.new.num(5), &vm).?);
}

test "putRaw: negative integer key always goes to hash" {
    var vm = try revo.VM.init(testing.runtime());
    defer vm.deinit();
    var table = Table.init();
    defer table.deinit(std.testing.allocator);
    try table.push(std.testing.allocator, Data.new.num(10));

    try table.putRaw(Data.new.num(-1), Data.new.num(99), &vm);
    try std.testing.expectEqual(@as(usize, 1), table.array.items.len);
    try std.testing.expectEqual(Data.new.num(99), table.hash.get(Data.new.num(-1), &vm).?);
}

test "putRaw: float key always goes to hash" {
    var vm = try revo.VM.init(testing.runtime());
    defer vm.deinit();
    var table = Table.init();
    defer table.deinit(std.testing.allocator);

    try table.putRaw(Data.new.num(1.5), Data.new.num(99), &vm);
    try std.testing.expectEqual(@as(usize, 0), table.array.items.len);
    try std.testing.expectEqual(Data.new.num(99), table.hash.get(Data.new.num(1.5), &vm).?);
}

test "putRaw: NaN and Infinity keys go to hash" {
    var vm = try revo.VM.init(testing.runtime());
    defer vm.deinit();
    var table = Table.init();
    defer table.deinit(std.testing.allocator);

    try table.putRaw(Data.new.num(std.math.nan(f64)), Data.new.num(1), &vm);
    try table.putRaw(Data.new.num(std.math.inf(f64)), Data.new.num(2), &vm);
    try std.testing.expectEqual(@as(usize, 0), table.array.items.len);
    try std.testing.expectEqual(@as(usize, 2), table.hash.count);
}

test "putRaw: getRaw retrieves from array for integer keys" {
    var vm = try revo.VM.init(testing.runtime());
    defer vm.deinit();
    var table = Table.init();
    defer table.deinit(std.testing.allocator);
    try table.push(std.testing.allocator, Data.new.num(10));
    try table.push(std.testing.allocator, Data.new.num(20));

    try std.testing.expectEqual(Data.new.num(10), table.getRaw(Data.new.num(0), &vm).?);
    try std.testing.expectEqual(Data.new.num(20), table.getRaw(Data.new.num(1), &vm).?);
    try std.testing.expectEqual(null, table.getRaw(Data.new.num(2), &vm));
}

test "putRaw: getRaw retrieves from hash for negative and float keys" {
    var vm = try revo.VM.init(testing.runtime());
    defer vm.deinit();
    var table = Table.init();
    defer table.deinit(std.testing.allocator);
    try table.putRaw(Data.new.num(-1), Data.new.num(42), &vm);
    try table.putRaw(Data.new.num(1.5), Data.new.num(99), &vm);

    try std.testing.expectEqual(Data.new.num(42), table.getRaw(Data.new.num(-1), &vm).?);
    try std.testing.expectEqual(Data.new.num(99), table.getRaw(Data.new.num(1.5), &vm).?);
}

test "putRaw: integer key > len in empty table goes to hash" {
    var vm = try revo.VM.init(testing.runtime());
    defer vm.deinit();
    var table = Table.init();
    defer table.deinit(std.testing.allocator);

    try table.putRaw(Data.new.num(0), Data.new.num(10), &vm);
    try std.testing.expectEqual(@as(usize, 1), table.array.items.len);
    try std.testing.expectEqual(Data.new.num(10), table.array.items[0]);

    try table.putRaw(Data.new.num(6), Data.new.num(42), &vm);
    try std.testing.expectEqual(@as(usize, 1), table.array.items.len);
    try std.testing.expectEqual(Data.new.num(42), table.hash.get(Data.new.num(6), &vm).?);

    try table.putRaw(Data.new.num(1), Data.new.num(20), &vm);
    try std.testing.expectEqual(@as(usize, 2), table.array.items.len);
    try std.testing.expectEqual(Data.new.num(20), table.array.items[1]);
}

//
// inline array part
//

test "array fills inline slots before touching the heap" {
    var table = Table.init();
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), table.array.capacity);

    try table.push(std.testing.allocator, Data.new.num(10));
    try table.push(std.testing.allocator, Data.new.num(20));
    try table.push(std.testing.allocator, Data.new.num(30));
    try table.push(std.testing.allocator, Data.new.num(40));
    try std.testing.expectEqual(@as(usize, 4), table.array.items.len);
    try std.testing.expectEqual(@as(usize, 4), table.array.capacity);
    try std.testing.expectEqual(Data.new.num(10), table.array.items[0]);
    try std.testing.expectEqual(Data.new.num(40), table.array.items[3]);
}

test "fifth array element spills inline contents to the heap intact" {
    var vm = try revo.VM.init(testing.runtime());
    defer vm.deinit();
    var table = Table.init();
    defer table.deinit(std.testing.allocator);
    for ([_]f64{ 10, 20, 30, 40, 50, 60 }) |n|
        try table.push(std.testing.allocator, Data.new.num(n));

    try std.testing.expectEqual(@as(usize, 6), table.array.items.len);
    try std.testing.expect(table.array.capacity >= 6);
    for ([_]f64{ 10, 20, 30, 40, 50, 60 }, 0..) |n, i|
        try std.testing.expectEqual(Data.new.num(n), table.getRaw(Data.new.num(@as(f64, @floatFromInt(i))), &vm).?);
}

test "cursor walks inline then heap then hash in order" {
    var vm = try revo.VM.init(testing.runtime());
    defer vm.deinit();
    var table = Table.init();
    defer table.deinit(std.testing.allocator);
    for ([_]f64{ 1, 2, 3, 4, 5, 6 }) |n|
        try table.push(std.testing.allocator, Data.new.num(n));
    try table.putRaw(Data.new.atom(try vm.internAtom("k")), Data.new.num(99), &vm);

    var cur = table.cursor();
    var expect: f64 = 1;
    while (cur.nextValue()) |v| {
        if (expect <= 6) try std.testing.expectEqual(Data.new.num(expect), v);
        expect += 1;
    }
    try std.testing.expectEqual(@as(f64, 8), expect);
}

test "insert and orderedRemove work across the inline boundary" {
    var table = Table.init();
    defer table.deinit(std.testing.allocator);
    for ([_]f64{ 1, 2, 3, 4 }) |n|
        try table.push(std.testing.allocator, Data.new.num(n));

    try table.array.insert(std.testing.allocator, 4, Data.new.num(5));
    try std.testing.expectEqual(@as(usize, 5), table.array.items.len);
    try std.testing.expectEqual(Data.new.num(5), table.array.items[4]);

    try table.array.insert(std.testing.allocator, 0, Data.new.num(0));
    try std.testing.expectEqual(@as(usize, 6), table.array.items.len);
    try std.testing.expectEqual(Data.new.num(0), table.array.items[0]);
    try std.testing.expectEqual(Data.new.num(1), table.array.items[1]);

    try std.testing.expectEqual(Data.new.num(0), table.array.orderedRemove(0));
    try std.testing.expectEqual(@as(usize, 5), table.array.items.len);
    try std.testing.expectEqual(Data.new.num(1), table.array.items[0]);
}

test "appendSlice bulk-fills without a growth chain" {
    var table = Table.init();
    defer table.deinit(std.testing.allocator);
    const vals = [_]Data{
        Data.new.num(1), Data.new.num(2), Data.new.num(3),
        Data.new.num(4), Data.new.num(5), Data.new.num(6),
    };
    try table.array.appendSlice(std.testing.allocator, &vals);
    try std.testing.expectEqual(@as(usize, 6), table.array.items.len);
    try std.testing.expectEqual(Data.new.num(6), table.array.items[5]);
}

//
// full
//

test "table lookup order" {
    try testing.topString(
        \\ const mt = {metafield = "second-", __index = fn(self) "last"}
        \\ const t = set_meta({normal = "first-"}, mt)
        \\ t.normal ~ t.metafield ~ t.something
    , "first-second-last");
}

test "computed table keys use runtime values" {
    try testing.topNumber(
        \\ const key = "answer"
        \\ const t = {[key] = 41}
        \\ t["answer"]
    , 41);

    try testing.topNumber(
        \\ const k = :x
        \\ const t = {[k] = 9}
        \\ t.x
    , 9);
}

test "array-style table literal" {
    try testing.topNumber(
        \\ const tbl = {10, 20, 30}
        \\ tbl[0] + tbl[1] + tbl[2]
    , 60);
}

test "numeric and string keys are distinct" {
    try testing.topNumber(
        \\ const t = {}
        \\ t[1] = 100
        \\ t["1"] = 200
        \\ t[1] + t["1"]
    , 300);
}

test "concatenated string keys match literal keys" {
    try testing.topNumber(
        \\ const t = {}
        \\ t["user" ~ 42] = 1
        \\ t["user42"] + t["user" ~ 42]
    , 2);
}

test "metatable __tostring works on tables" {
    try testing.topString(
        \\ const mt = {__tostring = fn(self) "custom"}
        \\ const t = set_meta({a = 1}, mt)
        \\ string(t)
    , "custom");
}

test "metatable __index for field access" {
    try testing.topNumber(
        \\ const mt = {__index = fn(self, key) 42}
        \\ const t = set_meta({}, mt)
        \\ t.missing_field
    , 42);
}

test "metatable __newindex for field assignment" {
    try testing.topNumber(
        \\ const mt = {__newindex = fn(self, key, value) table.rawset(self, key, 99)}
        \\ const t = set_meta({}, mt)
        \\ t.x = 5
        \\ t.x
    , 99);
}

test "multiple tables can share same metatable" {
    try testing.topTrue(
        \\ const mt = {get_val = fn(self) 77}
        \\ const t1 = set_meta({}, mt)
        \\ const t2 = set_meta({x = 1}, mt)
        \\ t1:get_val() == 77 and t2:get_val() == 77
    );
}

test "get_meta retrieves correct metatable" {
    try testing.topTrue(
        \\ const mt = {get_val = fn(self) 50}
        \\ const t = set_meta({}, mt)
        \\ const retrieved_mt = get_meta(t)
        \\ retrieved_mt == mt
    );
}

test "metatable on metatable works" {
    try testing.topNumber(
        \\ const mt = {get_val = fn(self) 9}
        \\ const t = set_meta({}, mt)
        \\ t:get_val()
    , 9);
}

test "metamethod failures are runtime errors" {
    try testing.expectRuntimeFailureWithMessage(
        \\ const mt = {__tostring = fn(self) panic("boom")}
        \\ const t = set_meta({}, mt)
        \\ string(t)
    , .Panic, "boom");
}

test "method calls on metatable tables work" {
    try testing.topNumber(
        \\ const mt = {get_x = fn(self) self.x}
        \\ const t = set_meta({x = 12}, mt)
        \\ t:get_x()
    , 12);
}

test "non-table values can use metatable fields as methods" {
    try testing.topString(
        \\ const mt = {reverse = fn(self) "fdsa"}
        \\ set_meta("", mt)
        \\ "asdf":reverse()
    , "fdsa");
}

test "pipe: explicit placeholder method receiver with table" {
    try testing.topNumber(
        \\ const obj = { inner = 40, meth = fn(self, x) self.inner + x }
        \\ obj |> _:meth(2)
    , 42);
}

test "pipe: explicit placeholder index access with table" {
    try testing.topNumber(
        \\ const t = {5, 6, 7}
        \\ 1 |> t[_]
    , 6);
}
