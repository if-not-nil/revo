pub const Impl = struct {
    pub fn rawget(vm: *VM, self: Ts.table, key: Ts.any) !HostResult {
        const t = try vm.tables.get(@intFromEnum(self));
        return .data(t.getRaw(key, vm) orelse revo.Data.new.core(.undef));
    }

    pub fn rawset(vm: *VM, self: Ts.table, key: Ts.any, val: Ts.any) !HostResult {
        const t = try vm.tables.get(@intFromEnum(self));
        try t.putRaw(key, val, vm);
        return .data(Data.new.table(@intFromEnum(self)));
    }

    pub fn unwrap(vm: *VM, self: Ts.table) !HostResult {
        const val = Data.new.table(@intFromEnum(self));
        const parts = vm.resultParts(val) orelse
            return .errType(0, "table with at least 2 elements", "table with less than 2 elements");
        if (parts.len < 2)
            return .errType(0, "table with at least 2 elements", "table with less than 2 elements");

        const atom = parts.tag.asAtom() orelse
            return .errType(0, "table starting with atom", "table starting with non-atom");
        if (atom != revo.core_atoms.atomId(.ok)) return root.panic_(&[1]Data{parts.payload orelse Data.new.nil()}, vm);
        return .data(parts.payload orelse Data.new.nil());
    }

    pub fn unwrap_err(vm: *VM, self: Ts.table) !HostResult {
        const val = Data.new.table(@intFromEnum(self));
        const parts = vm.resultParts(val) orelse
            return .errType(0, "table with at least 2 elements", "table with less than 2 elements");
        if (parts.len < 2)
            return .errType(0, "table with at least 2 elements", "table with less than 2 elements");

        const atom = parts.tag.asAtom() orelse
            return .errType(0, "table starting with atom", "table starting with non-atom");
        if (atom != revo.core_atoms.atomId(.err)) return root.panic_(&[1]Data{revo.Data.new.core(.err)}, vm);
        return .data(parts.payload orelse Data.new.nil());
    }

    test "table unwrap and unwrap_err" {
        try testing.topNumber("{:ok, 42}:unwrap()", 42);
        try testing.topString("{:err, \"boom\"}:unwrap_err()", "boom");
    }

    pub fn insert(vm: *VM, self: Ts.table, pos_num: Ts.number, val: Ts.any) !HostResult {
        const table = vm.tables.get(@intFromEnum(self)) catch return .errType(
            0,
            "table",
            typeof(Data.new.table(@intFromEnum(self)), vm),
        );
        const pos: i64 = root.numToInt(i64, pos_num) orelse return .errType(
            1,
            "integer num",
            typeof(Data.new.num(pos_num), vm),
        );

        if (pos < 0) return .errType(1, "non-negative num", typeof(Data.new.num(pos_num), vm));
        const pos_usize: usize = @intCast(pos);
        if (pos_usize <= table.array.items.len) {
            try table.array.insert(vm.runtime.alloc, pos_usize, val);
        } else {
            try table.array.append(vm.runtime.alloc, val);
        }

        return .data(revo.Data.new.core(.ok));
    }

    pub fn pop(vm: *VM, self: Ts.table) !HostResult {
        const table = vm.tables.get(@intFromEnum(self)) catch return .errType(
            0,
            "table",
            typeof(Data.new.table(@intFromEnum(self)), vm),
        );
        if (table.array.items.len == 0) return .data(Data.new.nil());

        const removed = table.array.orderedRemove(table.array.items.len - 1);
        return .data(removed);
    }

    pub fn remove(vm: *VM, self: Ts.table, key: Ts.any) !HostResult {
        const table = vm.tables.get(@intFromEnum(self)) catch return .errType(
            0,
            "table",
            typeof(Data.new.table(@intFromEnum(self)), vm),
        );
        const removed = table.removeAndReturn(key, vm) orelse return .other("not found");
        return .data(removed);
    }

    pub fn join(vm: *VM, self: Ts.table, delim: Ts.string) !HostResult {
        const table = try vm.tables.get(@intFromEnum(self));
        const delim_str = vm.stringValue(@intFromEnum(delim));
        var buf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
        defer buf.deinit();

        for (table.array.items, 0..) |item, idx| {
            if (idx > 0) try buf.writer.writeAll(delim_str);
            try item.write(&buf.writer, vm, .display);
        }

        const slice = try buf.toOwnedSlice();
        return .data(try vm.adoptDataString(slice));
    }

    pub fn keys(vm: *VM, self: Ts.table) !HostResult {
        const table = try vm.tables.get(@intFromEnum(self));
        var keys_list = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, table.array.items.len + 10);
        defer keys_list.deinit(vm.runtime.alloc);

        var cur = table.cursor();
        while (cur.nextEntry()) |entry| try keys_list.append(vm.runtime.alloc, entry.key);

        return .data(try vm.tableOfSlice(keys_list.items));
    }

    pub fn values(vm: *VM, self: Ts.table) !HostResult {
        const table = try vm.tables.get(@intFromEnum(self));
        var values_list = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, table.array.items.len + 10);
        defer values_list.deinit(vm.runtime.alloc);

        var cur = table.cursor();
        while (cur.nextValue()) |val| try values_list.append(vm.runtime.alloc, val);

        return .data(try vm.tableOfSlice(values_list.items));
    }

    pub fn @"has?"(vm: *VM, self: Ts.table, key: Ts.any) !HostResult {
        const table = try vm.tables.get(@intFromEnum(self));
        const exists = try table.get(key, vm);
        return ._bool(exists != null);
    }

    pub fn copy(vm: *VM, self: Ts.table) !HostResult {
        return .data(try vm.copyTable(@intFromEnum(self)));
    }

    pub fn merge(vm: *VM, self: Ts.table, other: Ts.table) !HostResult {
        const t1 = try vm.tables.get(@intFromEnum(self));
        const t2 = try vm.tables.get(@intFromEnum(other));
        const result_table = try vm.tables.create();
        const result = try vm.tables.get(result_table);

        try result.array.appendSlice(vm.runtime.alloc, t1.array.items);
        try result.array.appendSlice(vm.runtime.alloc, t2.array.items);
        var hash_it1 = t1.hash.orderedIterator();

        while (hash_it1.next()) |entry| {
            try result.putRaw(entry.key, entry.value, vm);
        }

        var hash_it2 = t2.hash.orderedIterator();
        while (hash_it2.next()) |entry| {
            try result.putRaw(entry.key, entry.value, vm);
        }

        return .data(Data.new.table(result_table));
    }

    pub fn sort(vm: *VM, self: Ts.table) !HostResult {
        const tbl = try vm.tables.get(@intFromEnum(self));
        const Context = struct {
            vm_: *VM,
            pub fn lessThanFn(ctx: @This(), lhs: Data, rhs: Data) bool {
                return ctx.vm_.compare(lhs, rhs) == .lt;
            }
        };
        std.mem.sort(Data, tbl.array.items, Context{ .vm_ = vm }, Context.lessThanFn);
        return .data(Data.new.table(@intFromEnum(self)));
    }

    pub fn sort_by(vm: *VM, self: Ts.table, compare_fn: Ts.function) !HostResult {
        const tbl = try vm.tables.get(@intFromEnum(self));
        const Context = struct {
            vm_: *VM,
            fn_data: Data,
            pub fn compare(ctx: @This(), a: Data, b: Data) bool {
                const result = ctx.vm_.callFunctionParts(ctx.fn_data, null, &[_]Data{ a, b }, null) catch return false;
                return !revo.isFalse(result);
            }
        };
        std.mem.sort(
            Data,
            tbl.array.items,
            Context{ .vm_ = vm, .fn_data = Data.new.function(@intFromEnum(compare_fn)) },
            Context.compare,
        );
        return .data(Data.new.table(@intFromEnum(self)));
    }

    pub fn first(vm: *VM, self: Ts.table) !HostResult {
        const tbl = try vm.tables.get(@intFromEnum(self));
        if (tbl.array.items.len == 0)
            return .data(revo.Data.new.core(.nil));
        return .data(tbl.array.items[0]);
    }

    pub fn last(vm: *VM, self: Ts.table) !HostResult {
        const tbl = try vm.tables.get(@intFromEnum(self));
        if (tbl.array.items.len == 0)
            return .data(revo.Data.new.core(.nil));
        return .data(tbl.array.items[tbl.array.items.len - 1]);
    }

    pub fn reverse(vm: *VM, self: Ts.table) !HostResult {
        const tbl = try vm.tables.get(@intFromEnum(self));
        std.mem.reverse(Data, tbl.array.items);
        return .data(Data.new.table(@intFromEnum(self)));
    }

    pub fn flatten(vm: *VM, self: Ts.table) !HostResult {
        const src = try vm.tables.get(@intFromEnum(self));
        const result_id = try vm.tables.create();
        const result = try vm.tables.get(result_id);

        for (src.array.items) |item| {
            if (item.asTable()) |nested_id| {
                const nested = try vm.tables.get(nested_id);
                for (nested.array.items) |maybe_nested| {
                    try result.array.append(vm.runtime.alloc, maybe_nested);
                }
            } else {
                try result.array.append(vm.runtime.alloc, item);
            }
        }

        return .data(Data.new.table(result_id));
    }

    /// first array index holding `search_val` by value, or null
    fn findInArray(vm: *VM, items: []const Data, search_val: Data) ?usize {
        for (items, 0..) |item, i| {
            if (vm.compare(item, search_val) == .eq) return i;
        }
        return null;
    }

    pub fn @"contains?"(vm: *VM, self: Ts.table, search_val: Ts.any) !HostResult {
        const tbl = try vm.tables.get(@intFromEnum(self));
        return ._bool(findInArray(vm, tbl.array.items, search_val) != null);
    }

    pub fn unique(vm: *VM, self: Ts.table) !HostResult {
        const src = try vm.tables.get(@intFromEnum(self));
        const result_id = try vm.tables.create();
        const result = try vm.tables.get(result_id);
        for (src.array.items) |item| {
            if (findInArray(vm, result.array.items, item) == null) {
                try result.array.append(vm.runtime.alloc, item);
            }
        }
        return .data(Data.new.table(result_id));
    }

    pub fn len(vm: *VM, self: Ts.table) !HostResult {
        const table = try vm.tables.get(@intFromEnum(self));
        return .data(Data.new.num(table.count()));
    }

    pub fn alen(vm: *VM, self: Ts.table) !HostResult {
        const table = try vm.tables.get(@intFromEnum(self));
        return .data(Data.new.num(table.array.items.len));
    }

    pub fn @"empty?"(vm: *VM, self: Ts.table) !HostResult {
        const table = try vm.tables.get(@intFromEnum(self));
        return ._bool(table.count() == 0);
    }

    pub fn deep_copy(vm: *VM, self: Ts.table) !HostResult {
        var seen = std.AutoHashMap(revo.memory.TableID, revo.memory.TableID).init(vm.runtime.alloc);
        defer seen.deinit();
        return .data(try deepCopyInto(vm, @intFromEnum(self), &seen));
    }

    pub fn update(vm: *VM, self: Ts.table, key: Ts.any, f: Ts.function) !HostResult {
        const tid = @intFromEnum(self);
        const table = try vm.tables.get(tid);
        const old = try table.get(key, vm) orelse Data.new.nil();
        const new = try vm.callFunctionParts(Data.new.function(@intFromEnum(f)), null, &[_]Data{old}, null);
        // re-fetch: the call above may have created tables
        const t = try vm.tables.get(tid);
        try t.put(tid, vm, key, new);
        return .data(Data.new.table(tid));
    }

    /// recursive clone with cycle guard: already-seen tables map to
    /// their in-progress copy instead of recursing forever
    fn deepCopyInto(
        vm: *VM,
        src: revo.memory.TableID,
        seen: *std.AutoHashMap(revo.memory.TableID, revo.memory.TableID),
    ) anyerror!Data {
        if (seen.get(src)) |id| return Data.new.table(id);
        const id = try vm.tables.create();
        try seen.put(src, id);
        const s = try vm.tables.get(src);
        const d = try vm.tables.get(id);
        for (s.array.items) |item| {
            const v = if (item.asTable()) |tid| try deepCopyInto(vm, tid, seen) else item;
            try d.array.append(d.alloc, v);
        }
        var it = s.hash.orderedIterator();
        while (it.next()) |entry| {
            const k = if (entry.key.asTable()) |tid| try deepCopyInto(vm, tid, seen) else entry.key;
            const v = if (entry.value.asTable()) |tid| try deepCopyInto(vm, tid, seen) else entry.value;
            try d.putRaw(k, v, vm);
        }
        return Data.new.table(id);
    }

    pub fn repeat(vm: *VM, self: Ts.table, n: Ts.number) !HostResult {
        const times: i64 = root.numToInt(i64, n) orelse return .errType(1, "integer num", typeof(Data.new.num(n), vm));
        if (times < 0) return .errType(1, "non-negative num", "negative num");

        const count: usize = @intCast(times);
        const left = try vm.tables.get(@intFromEnum(self));

        const result_id = try vm.tables.create();
        const result = try vm.tables.get(result_id);

        for (0..count) |_| {
            try result.array.appendSlice(vm.runtime.alloc, left.array.items);
        }
        return .data(Data.new.table(result_id));
    }

    pub fn count_of(vm: *VM, self: Ts.table, search_val: Ts.any) !HostResult {
        const table = try vm.tables.get(@intFromEnum(self));
        var counter: i16 = 0;

        for (table.array.items) |item| {
            if (vm.compare(item, search_val) == .eq) {
                counter += 1;
            }
        }
        return .data(Data.new.num(counter));
    }

    pub fn index_of(vm: *VM, self: Ts.table, search_val: Ts.any) !HostResult {
        const tbl = try vm.tables.get(@intFromEnum(self));
        if (findInArray(vm, tbl.array.items, search_val)) |i| {
            return .data(Data.new.num(i));
        }
        return .coreAtom(.nil);
    }
};

pub const impls: []const api.Impl = root.impls(Impl).val ++ &[_]api.Impl{
    .{ .name = "push", .f = root.defineVariadic(&.{.table}, push) },
    .{ .name = "get", .f = root.defineVariadic(&.{ .table, .any }, getOrDefault) },
    .{ .name = "slice", .f = root.defineVariadic(&.{ .table, .number }, sliceRange) },
    .{ .name = "get_meta", .f = root.define(&.{.table}, @import("meta.zig").get_meta) },
    .{ .name = "set_meta", .f = root.define(&.{ .table, .any }, @import("meta.zig").set_meta) },
};

fn push(args: []const Data, vm: *VM) !HostResult {
    const table_id = args[0].asTable().?;
    const table = vm.tables.get(table_id) catch return .errType(0, "table", typeof(args[0], vm));
    try table.array.appendSlice(vm.runtime.alloc, args[1..]);
    return .data(Data.new.table(table_id));
}

/// metatable-aware read with optional fallback (`:undef` when absent)
fn getOrDefault(args: []const Data, vm: *VM) !HostResult {
    const table = vm.tables.get(args[0].asTable().?) catch return .errType(0, "table", typeof(args[0], vm));
    if (try table.get(args[1], vm)) |found| return .data(found);
    if (args.len > 2) return .data(args[2]);
    return .data(Data.new.core(.undef));
}

/// array slice `[start, end)`, end defaults to the array length
/// bounds clamp; empty when start >= end
fn sliceRange(args: []const Data, vm: *VM) !HostResult {
    const table = vm.tables.get(args[0].asTable().?) catch return .errType(0, "table", typeof(args[0], vm));
    const alen = table.array.items.len;
    const start_num = args[1].asNum() orelse return .errType(1, "integer num", typeof(args[1], vm));
    const end_num = if (args.len > 2)
        args[2].asNum() orelse return .errType(2, "integer num", typeof(args[2], vm))
    else
        @as(f64, @floatFromInt(alen));
    const start_isize = root.numToInt(isize, start_num) orelse return .errType(1, "integer num", typeof(args[1], vm));
    const end_isize = root.numToInt(isize, end_num) orelse return .errType(2, "integer num", typeof(args[2], vm));
    const lo: usize = @intCast(@max(start_isize, 0));
    const hi: usize = @intCast(@min(end_isize, @as(isize, @intCast(alen))));
    if (lo >= hi) return .data(try vm.tableOfSlice(&.{}));
    return .data(try vm.tableOfSlice(table.array.items[lo..hi]));
}

test "table library" {
    try testing.topNumber("len({1, 2, 3})", 3);
    try testing.topNumber("{1, 2, 3}:alen()", 3);
    try testing.topNumber("{1, 2, x = 9}:alen()", 2);
    try testing.topNumber("len({1, 2, x = 9})", 3);
}

test "table methods" {
    try testing.topNumber("{1, 2, 3}:first()", 1);
    try testing.topNumber("{1, 2, 3}:last()", 3);
    try testing.topTrue("{1, 2, 3}:contains?(2)");
    try testing.topFalse("{1, 2, 3}:contains?(5)");
    try testing.topNumber("{1, 2, 3}:index_of(2)", 1);
    try testing.topNumber("iter.sum({1, 2, 3})", 6);
    try testing.topNumber("{1, 2, 3}:pop()", 3);
    try testing.topNumber("let a = {1, 2, 3}; a:pop(); a:len()", 2);
    try testing.topNumber("{1, 2}:merge({3, 4}):len()", 4);
    try testing.topNumber("{1, 2}:repeat(3):len()", 6);
    try testing.topNumber("{1, 2}:repeat(0):len()", 0);
    try testing.topTrue("let a = {1, 2, 3}; a:remove(1); a == {1, 3}");
}

test "table get with default" {
    try testing.topNumber("{a = 1}:get(:a)", 1);
    try testing.topNumber("{a = 1}:get(:b, 42)", 42);
    try testing.topAtom("{a = 1}:get(:b)", "undef");
    try testing.topNumber("{10, 20}:get(1, 0)", 20);
}

test "table empty?" {
    try testing.topTrue("{}:empty?()");
    try testing.topFalse("{1}:empty?()");
    try testing.topFalse("{a = 1}:empty?()");
}

test "table update" {
    try testing.topNumber("let t = {n = 1}; t:update(:n, fn(x) x + 1); t.n", 2);
    try testing.topNumber("let t = {}; t:update(:n, fn(x) x orelse 10); t:get(:n)", 10);
}

test "table deep_copy" {
    try testing.topTrue("let t = {1, {2}}; let c = t:deep_copy(); c == t");
    try testing.topTrue("let t = {1, {2}}; let c = t:deep_copy(); c[1] == t[1]");
    try testing.topFalse(
        \\ let t = {{}}
        \\ let c = t:deep_copy()
        \\ c[0]:push(9)
        \\ t[0]:len() == 1
    );
    try testing.topTrue(
        \\ let t = {}
        \\ t.self = t
        \\ let c = t:deep_copy()
        \\ c.self == c
    );
}

test "table slice" {
    try testing.topNumber("iter.sum({1, 2, 3, 4}:slice(1, 3))", 5);
    try testing.topNumber("{1, 2, 3}:slice(1):len()", 2);
    try testing.topNumber("{1, 2, 3}:slice(0, 10):len()", 3);
    try testing.topNumber("{1, 2, 3}:slice(2, 2):len()", 0);
    try testing.topNumber("{1, 2, 3}:slice(5):len()", 0);
}

test "contains? and index_of compare string content, not ids" {
    try testing.topTrue(
        \\ "a b c":split(" "):contains?("b")
    );
    try testing.topNumber(
        \\ "a b c":split(" "):index_of("b")
    , 1);
}

test "get count of a value" {
    try testing.topNumber("{1, 2}:count_of(1)", 1);
    try testing.topNumber("{1, 2, 'hello'}:count_of('hello')", 1);
    try testing.topNumber("{:true, :false, 'hello', 1, 2, {1, 'hello' = 2}}:count_of(:true)", 1);
}

test "get index of a value" {
    try testing.topNumber("{1, 2}:index_of(1)", 0);
    try testing.topNumber("{1, 2, 'hello'}:index_of('hello')", 2);
    try testing.topNumber("{:true, :false, 'hello', 1, 2, {1, 'hello' = 2}}:index_of({1, 'hello' = 2})", 5);
    try testing.topAtom(
        "{:true, :false, 'hello', 1, 2, {1, 'hello' = 2}}:index_of(3)",
        "nil",
    );
}

const std = @import("std");

const revo = @import("../root.zig");
const testing = revo.lang.testing;
const Data = revo.Data;
const VM = revo.VM;
const api = @import("api.zig");
const root = @import("root.zig");
const HostResult = root.HostResult;
const typeof = root.typeof;
const Ts = root.T;
