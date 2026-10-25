pub const Impl = struct {
    pub fn rawget(vm: *VM, self: Args.table, k: Args.any) !HostResult {
        const t = try vm.tables.get(@backingInt(self));
        return .data(t.getRaw(k, vm) orelse revo.Value.new.core(.undef));
    }

    pub fn at(vm: *VM, self: Args.table, index: Args.number) !HostResult {
        const t = try vm.tables.get(@backingInt(self));
        const idx = root.host.numToInt(isize, index) orelse return .errType(1, "integer number", typeof(Value.new.num(index), vm));
        if (idx < 0) return .data(revo.Value.new.core(.undef));
        const f: f64 = @floatFromInt(idx);
        return .data(t.getRaw(Value.new.num(f), vm) orelse revo.Value.new.core(.undef));
    }

    pub fn @"at?"(vm: *VM, self: Args.table, index: Args.number) !HostResult {
        const t = try vm.tables.get(@backingInt(self));
        const idx = root.host.numToInt(isize, index) orelse return ._bool(false);
        if (idx < 0) return ._bool(false);
        const f: f64 = @floatFromInt(idx);
        return ._bool(t.getRaw(Value.new.num(f), vm) != null);
    }

    pub fn key(vm: *VM, self: Args.table, k: Args.any) !HostResult {
        const t = try vm.tables.get(@backingInt(self));
        return .data(t.getRaw(k, vm) orelse revo.Value.new.core(.undef));
    }

    pub fn @"key?"(vm: *VM, self: Args.table, k: Args.any) !HostResult {
        const t = try vm.tables.get(@backingInt(self));
        return ._bool(t.getRaw(k, vm) != null);
    }

    pub fn last(vm: *VM, self: Args.table) !HostResult {
        const t = try vm.tables.get(@backingInt(self));

        return .data(if (t.array.items.len == 0)
            Value.new.core(.undef)
        else
            t.array.items[t.array.items.len - 1]);
    }

    pub fn rawset(vm: *VM, self: Args.table, k: Args.any, val: Args.any) !HostResult {
        const t = try vm.tables.get(@backingInt(self));
        try t.putRaw(k, val, vm);
        return .data(Value.new.table(@backingInt(self)));
    }

    pub fn unwrap(vm: *VM, self: Args.table) !HostResult {
        const val = Value.new.table(@backingInt(self));
        const parts = vm.resultParts(val) orelse
            return .errType(0, "table with at least 2 elements", "table with less than 2 elements");
        if (parts.len < 2)
            return .errType(0, "table with at least 2 elements", "table with less than 2 elements");

        const atom = parts.tag.asAtom() orelse
            return .errType(0, "table starting with atom", "table starting with non-atom");
        if (atom != revo.CoreAtoms.atomId(.ok)) return root.panic_(&[1]Value{parts.payload orelse Value.new.nil()}, vm);
        return .data(parts.payload orelse Value.new.nil());
    }

    pub fn unwrap_err(vm: *VM, self: Args.table) !HostResult {
        const val = Value.new.table(@backingInt(self));
        const parts = vm.resultParts(val) orelse
            return .errType(0, "table with at least 2 elements", "table with less than 2 elements");
        if (parts.len < 2)
            return .errType(0, "table with at least 2 elements", "table with less than 2 elements");

        const atom = parts.tag.asAtom() orelse
            return .errType(0, "table starting with atom", "table starting with non-atom");
        if (atom != revo.CoreAtoms.atomId(.err)) return root.panic_(&[1]Value{revo.Value.new.core(.err)}, vm);
        return .data(parts.payload orelse Value.new.nil());
    }

    test "table unwrap and unwrap_err" {
        try testing.topNumber("{:ok, 42}:unwrap()", 42);
        try testing.topString("{:err, \"boom\"}:unwrap_err()", "boom");
    }

    pub fn insert(vm: *VM, self: Args.table, pos_num: Args.number, val: Args.any) !HostResult {
        const table = vm.tables.get(@backingInt(self)) catch return .errType(
            0,
            "table",
            typeof(Value.new.table(@backingInt(self)), vm),
        );
        const pos: i64 = root.host.numToInt(i64, pos_num) orelse return .errType(
            1,
            "integer number",
            typeof(Value.new.num(pos_num), vm),
        );

        if (pos < 0) return .errType(1, "non-negative numberber", typeof(Value.new.num(pos_num), vm));
        const pos_usize: usize = @intCast(pos);
        if (pos_usize <= table.array.items.len) {
            try table.array.insert(vm.runtime.alloc, pos_usize, val);
        } else {
            try table.array.append(vm.runtime.alloc, val);
        }

        return .data(revo.Value.new.core(.ok));
    }

    pub fn pop(vm: *VM, self: Args.table) !HostResult {
        const table = vm.tables.get(@backingInt(self)) catch return .errType(
            0,
            "table",
            typeof(Value.new.table(@backingInt(self)), vm),
        );
        if (table.array.items.len == 0) return .coreAtom(.undef);

        const removed = table.array.orderedRemove(table.array.items.len - 1);
        return .data(removed);
    }

    pub fn remove(vm: *VM, self: Args.table, k: Args.any) !HostResult {
        const table = vm.tables.get(@backingInt(self)) catch return .errType(
            0,
            "table",
            typeof(Value.new.table(@backingInt(self)), vm),
        );
        const removed = table.removeAndReturn(k, vm) orelse return .other("not found");
        return .data(removed);
    }

    pub fn join(vm: *VM, self: Args.table, delim: Args.string) !HostResult {
        const table = try vm.tables.get(@backingInt(self));
        const delim_str = vm.stringValue(@backingInt(delim));
        var buf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
        defer buf.deinit();

        for (table.array.items, 0..) |item, idx| {
            if (idx > 0) try buf.writer.writeAll(delim_str);
            try item.write(&buf.writer, vm, .plain, vm.runtime.supports_color);
        }

        const slice = try buf.toOwnedSlice();
        return .data(try vm.adoptValueString(slice));
    }

    pub fn keys(vm: *VM, self: Args.table) !HostResult {
        const table = try vm.tables.get(@backingInt(self));
        var keys_list = try std.ArrayList(Value).initCapacity(vm.runtime.alloc, table.array.items.len + 10);
        defer keys_list.deinit(vm.runtime.alloc);

        var cur = table.cursor();
        while (cur.nextEntry()) |entry| try keys_list.append(vm.runtime.alloc, entry.key);

        return .data(try vm.tableOfSlice(keys_list.items));
    }

    pub fn values(vm: *VM, self: Args.table) !HostResult {
        const table = try vm.tables.get(@backingInt(self));
        var values_list = try std.ArrayList(Value).initCapacity(vm.runtime.alloc, table.array.items.len + 10);
        defer values_list.deinit(vm.runtime.alloc);

        var cur = table.cursor();
        while (cur.nextValue()) |val| try values_list.append(vm.runtime.alloc, val);

        return .data(try vm.tableOfSlice(values_list.items));
    }

    pub fn copy(vm: *VM, self: Args.table) !HostResult {
        return .data(try vm.tableCopy(@backingInt(self)));
    }

    pub fn deep_copy(vm: *VM, self: Args.table) !HostResult {
        return .data(try vm.tableDeepCopy(@backingInt(self)));
    }

    pub fn merge(vm: *VM, self: Args.table, other: Args.table) !HostResult {
        const t1 = try vm.tables.get(@backingInt(self));
        const t2 = try vm.tables.get(@backingInt(other));
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

        return .data(Value.new.table(result_table));
    }

    pub fn sort(vm: *VM, self: Args.table) !HostResult {
        const tbl = try vm.tables.get(@backingInt(self));
        const Context = struct {
            vm_: *VM,
            pub fn lessThanFn(ctx: @This(), lhs: Value, rhs: Value) bool {
                return ctx.vm_.compare(lhs, rhs) == .lt;
            }
        };
        std.mem.sort(Value, tbl.array.items, Context{ .vm_ = vm }, Context.lessThanFn);
        return .data(Value.new.table(@backingInt(self)));
    }

    pub fn sort_by(vm: *VM, self: Args.table, compare_fn: Args.function) !HostResult {
        const tbl = try vm.tables.get(@backingInt(self));
        const Context = struct {
            vm_: *VM,
            fn_data: Value,
            pub fn compare(ctx: @This(), a: Value, b: Value) bool {
                const result = ctx.vm_.callFunctionParts(ctx.fn_data, null, &[_]Value{ a, b }, null) catch return false;
                return !revo.isFalse(result);
            }
        };
        std.mem.sort(
            Value,
            tbl.array.items,
            Context{ .vm_ = vm, .fn_data = Value.new.function(@backingInt(compare_fn)) },
            Context.compare,
        );
        return .data(Value.new.table(@backingInt(self)));
    }

    pub fn reverse(vm: *VM, self: Args.table) !HostResult {
        const tbl = try vm.tables.get(@backingInt(self));
        std.mem.reverse(Value, tbl.array.items);
        return .data(Value.new.table(@backingInt(self)));
    }

    pub fn flatten(vm: *VM, self: Args.table) !HostResult {
        const src = try vm.tables.get(@backingInt(self));
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

        return .data(Value.new.table(result_id));
    }

    /// first array index holding `search_val` by value, or null
    fn findInArray(vm: *VM, items: []const Value, search_val: Value) ?usize {
        for (items, 0..) |item, i| {
            if (vm.compare(item, search_val) == .eq) return i;
        }
        return null;
    }

    pub fn @"contains?"(vm: *VM, self: Args.table, search_val: Args.any) !HostResult {
        const tbl = try vm.tables.get(@backingInt(self));
        return ._bool(findInArray(vm, tbl.array.items, search_val) != null);
    }

    pub fn unique(vm: *VM, self: Args.table) !HostResult {
        const src = try vm.tables.get(@backingInt(self));
        const result_id = try vm.tables.create();
        const result = try vm.tables.get(result_id);
        for (src.array.items) |item| {
            if (findInArray(vm, result.array.items, item) == null) {
                try result.array.append(vm.runtime.alloc, item);
            }
        }
        return .data(Value.new.table(result_id));
    }

    pub fn len(vm: *VM, self: Args.table) !HostResult {
        const table = try vm.tables.get(@backingInt(self));
        return .data(Value.new.num(table.count()));
    }

    pub fn alen(vm: *VM, self: Args.table) !HostResult {
        const table = try vm.tables.get(@backingInt(self));
        return .data(Value.new.num(table.array.items.len));
    }

    pub fn klen(vm: *VM, self: Args.table) !HostResult {
        const table = try vm.tables.get(@backingInt(self));
        return .data(Value.new.num(table.hash.count));
    }

    pub fn @"empty?"(vm: *VM, self: Args.table) !HostResult {
        const table = try vm.tables.get(@backingInt(self));
        return ._bool(table.count() == 0);
    }

    pub fn update(vm: *VM, self: Args.table, k: Args.any, f: Args.function) !HostResult {
        const tid = @backingInt(self);
        const table = try vm.tables.get(tid);
        const old = try table.get(k, vm) orelse Value.new.nil();
        const new = try vm.callFunctionParts(Value.new.function(@backingInt(f)), null, &[_]Value{old}, null);
        // re-fetch: the call above may have created tables
        const t = try vm.tables.get(tid);
        try t.put(tid, vm, k, new);
        return .data(Value.new.table(tid));
    }

    pub fn repeat(vm: *VM, self: Args.table, n: Args.number) !HostResult {
        const times: i64 = root.host.numToInt(i64, n) orelse return .errType(1, "integer number", typeof(Value.new.num(n), vm));
        if (times < 0) return .errType(1, "non-negative numberber", "negative number");

        const count: usize = @intCast(times);
        const left = try vm.tables.get(@backingInt(self));

        const result_id = try vm.tables.create();
        const result = try vm.tables.get(result_id);

        for (0..count) |_| {
            try result.array.appendSlice(vm.runtime.alloc, left.array.items);
        }
        return .data(Value.new.table(result_id));
    }

    pub fn count_of(vm: *VM, self: Args.table, search_val: Args.any) !HostResult {
        const table = try vm.tables.get(@backingInt(self));
        var counter: i16 = 0;

        for (table.array.items) |item| {
            if (vm.compare(item, search_val) == .eq) {
                counter += 1;
            }
        }
        return .data(Value.new.num(counter));
    }

    pub fn index_of(vm: *VM, self: Args.table, search_val: Args.any) !HostResult {
        const tbl = try vm.tables.get(@backingInt(self));
        if (findInArray(vm, tbl.array.items, search_val)) |i| {
            return .data(Value.new.num(i));
        }
        return .coreAtom(.nil);
    }
};

pub const impls: []const specs.Impl = root.host.impls(Impl).val ++ &[_]specs.Impl{
    .{ .name = "push", .f = root.host.defineVariadic(&.{.table}, push) },
    .{ .name = "slice", .f = root.host.defineVariadic(&.{ .table, .number }, sliceRange) },
    .{ .name = "get_meta", .f = root.host.define(&.{.table}, @import("metatable.zig").get_meta) },
    .{ .name = "set_meta", .f = root.host.define(&.{ .table, .any }, @import("metatable.zig").set_meta) },
};

fn push(args: []const Value, vm: *VM) !HostResult {
    const table_id = args[0].asTable().?;
    const table = vm.tables.get(table_id) catch return .errType(0, "table", typeof(args[0], vm));
    try table.array.appendSlice(vm.runtime.alloc, args[1..]);
    return .data(Value.new.table(table_id));
}

/// array slice `[start, end)`, end defaults to the array length
/// bounds clamp; empty when start >= end
fn sliceRange(args: []const Value, vm: *VM) !HostResult {
    const table = vm.tables.get(args[0].asTable().?) catch return .errType(0, "table", typeof(args[0], vm));
    const alen = table.array.items.len;
    const start_num = args[1].asNumOpt() orelse return .errType(1, "integer number", typeof(args[1], vm));
    const end_num = if (args.len > 2)
        args[2].asNumOpt() orelse return .errType(2, "integer number", typeof(args[2], vm))
    else
        @as(f64, @floatFromInt(alen));
    if (start_num < 0.0 or end_num < 0.0) return .errAssertionFailed("range cannot be negative");
    if (start_num > end_num) return .errAssertionFailed("range start cannot be greater than end");
    const start_isize = root.host.numToInt(isize, start_num) orelse return .errType(1, "integer number", typeof(args[1], vm));
    const end_isize = root.host.numToInt(isize, end_num) orelse return .errType(2, "integer number", typeof(args[2], vm));
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
    try testing.topNumber("{1, 2, x = 9}:klen()", 1);
}

test "table methods" {
    try testing.topNumber("{1, 2, 3}:at(0)", 1);
    try testing.topNumber("{1, 2, 3}:at(2)", 3);
    try testing.topAtom("{}:at(0)", "undef");
    try testing.topTrue("{1, 2, 3}:at?(1)");
    try testing.topFalse("{1, 2, 3}:at?(9)");
    try testing.topFalse("{1, 2, 3}:at?(-1)");
    try testing.topNumber("{a = 1}:key(:a)", 1);
    try testing.topTrue("{a = 1}:key?(:a)");
    try testing.topFalse("{a = 1}:key?(:b)");
    try testing.topAtom("{a = 1}:key(:b)", "undef");
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

test "table key/at bypass metatables" {
    try testing.topAtom("set_meta({x = 1}, {__index = {y = 2}}):key(:y)", "undef");
    try testing.topNumber("set_meta({x = 1}, {__index = {y = 2}}):key(:x)", 1);
    try testing.topAtom("set_meta({x = 1}, {__index = {y = 2}}):key(:zz)", "undef");
    try testing.topFalse("set_meta({x = 1}, {__index = {y = 2}}):key?(:y)");
}

test "table key with default" {
    try testing.topNumber("{a = 1}:key(:a)", 1);
    try testing.topNumber("{a = 1}:key(:b) orelse 42", 42);
    try testing.topAtom("{a = 1}:key(:b)", "undef");
    try testing.topNumber("{10, 20}:at(1) orelse 0", 20);
}

test "table empty?" {
    try testing.topTrue("{}:empty?()");
    try testing.topFalse("{1}:empty?()");
    try testing.topFalse("{a = 1}:empty?()");
}

test "table update" {
    try testing.topNumber("let t = {n = 1}; t:update(:n, fn(x) x + 1); t.n", 2);
    try testing.topNumber("let t = {}; t:update(:n, fn(x) x orelse 10); t:key(:n)", 10);
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
const testing = revo.lang.test_helpers;
const Value = revo.Value;
const VM = revo.VM;
const root = @import("root.zig");
const specs = @import("specs.zig");
const HostResult = root.host.HostResult;
const typeof = root.typeof;
const Args = root.host.ArgTypes;
