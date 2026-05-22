const std = @import("std");
const revo = @import("../root.zig");
const root = @import("root.zig");
const testing = revo.lang.testing;

const Data = revo.Data;
const VM = revo.VM;
const NativeResult = root.NativeResult;
const dataToString = root.dataToString;

pub fn register(vm: *VM) !void {
    const iter = @import("iter.zig");
    try root.registerTableFunctions(vm, "table", &[_]root.FuncDef{
        .{ .name = "rawget", .f = root.define(&.{ .table, .any }, rawget) },
        .{ .name = "rawset", .f = root.define(&.{ .table, .any, .any }, rawset) },
        .{ .name = "set_meta", .f = root.define(&.{.table}, @import("meta.zig").set_metatable_) },
        .{ .name = "unwrap", .f = root.define(&.{.table}, @"try") },
        .{ .name = "insert", .f = root.define(&.{ .table, .number, .any }, insert) },
        .{ .name = "push", .f = root.defineVariadic(&.{.table}, push) },
        .{ .name = "as_tuple", .f = root.define(&.{.table}, as_tuple) },
        .{ .name = "remove", .f = root.define(&.{ .table, .number }, remove) },
        .{ .name = "concat", .f = root.define(&.{ .table, .string }, concat) },
        .{ .name = "keys", .f = root.define(&.{.table}, keys) },
        .{ .name = "values", .f = root.define(&.{.table}, values) },
        .{ .name = "has?", .f = root.define(&.{ .table, .any }, has) },
        .{ .name = "copy", .f = root.define(&.{.table}, copy) },
        .{ .name = "merge", .f = root.define(&.{ .table, .table }, merge) },
        .{ .name = "sort", .f = root.define(&.{.table}, sort) },
        .{ .name = "sort_by", .f = root.define(&.{ .table, .function }, sort_by) },
        .{ .name = "first", .f = root.define(&.{.table}, first) },
        .{ .name = "last", .f = root.define(&.{.table}, last) },
        .{ .name = "reverse", .f = root.define(&.{.table}, reverse) },
        .{ .name = "flatten", .f = root.define(&.{.table}, flatten) },
        .{ .name = "index_of", .f = root.define(&.{ .table, .any }, index_of) },
        .{ .name = "contains?", .f = root.define(&.{ .table, .any }, contains) },
        .{ .name = "unique", .f = root.define(&.{.table}, unique) },
        .{ .name = "sum", .f = root.define(&.{.table}, sum) },
        .{ .name = "len", .f = root.define(&.{.table}, len) },
        .{ .name = "add", .f = root.define(&.{ .table, .table }, tableAdd) },
        .{ .name = "map", .f = root.define(&.{ .any, .function }, iter.map_fn) },
        .{ .name = "filter", .f = root.define(&.{ .any, .function }, iter.filter_fn) },
        .{ .name = "reduce", .f = root.define(&.{ .any, .function, .any }, iter.reduce_fn) },
        .{ .name = "each", .f = root.define(&.{ .any, .function }, iter.each_fn) },
        .{ .name = "find", .f = root.define(&.{ .any, .function }, iter.find_fn) },
        .{ .name = "all?", .f = root.define(&.{ .any, .function }, iter.all_fn) },
        .{ .name = "any?", .f = root.define(&.{ .any, .function }, iter.any_fn) },
    });

    try root.registerMetatable(vm, &[_]root.MethodDef{
        .{ .key = .{ .named = "set_meta" }, .func = root.define(&.{.table}, @import("meta.zig").set_metatable_) },
        .{ .key = .{ .named = "unwrap" }, .func = root.define(&.{.table}, @"try") },
        .{ .key = .{ .named = "insert" }, .func = root.define(&.{ .table, .number, .any }, insert) },
        .{ .key = .{ .named = "push" }, .func = root.defineVariadic(&.{.table}, push) },
        .{ .key = .{ .named = "as_tuple" }, .func = root.define(&.{.table}, as_tuple) },
        .{ .key = .{ .named = "remove" }, .func = root.define(&.{ .table, .number }, remove) },
        .{ .key = .{ .named = "concat" }, .func = root.define(&.{ .table, .string }, concat) },
        .{ .key = .{ .named = "keys" }, .func = root.define(&.{.table}, keys) },
        .{ .key = .{ .named = "values" }, .func = root.define(&.{.table}, values) },
        .{ .key = .{ .named = "has?" }, .func = root.define(&.{ .table, .any }, has) },
        .{ .key = .{ .named = "copy" }, .func = root.define(&.{.table}, copy) },
        .{ .key = .{ .named = "merge" }, .func = root.define(&.{ .table, .table }, merge) },
        .{ .key = .{ .named = "sort" }, .func = root.define(&.{.table}, sort) },
        .{ .key = .{ .named = "sort_by" }, .func = root.define(&.{ .table, .function }, sort_by) },
        .{ .key = .{ .named = "first" }, .func = root.define(&.{.table}, first) },
        .{ .key = .{ .named = "last" }, .func = root.define(&.{.table}, last) },
        .{ .key = .{ .named = "reverse" }, .func = root.define(&.{.table}, reverse) },
        .{ .key = .{ .named = "flatten" }, .func = root.define(&.{.table}, flatten) },
        .{ .key = .{ .named = "index_of" }, .func = root.define(&.{ .table, .any }, index_of) },
        .{ .key = .{ .named = "contains?" }, .func = root.define(&.{ .table, .any }, contains) },
        .{ .key = .{ .named = "unique" }, .func = root.define(&.{.table}, unique) },
        .{ .key = .{ .named = "sum" }, .func = root.define(&.{.table}, sum) },
        .{ .key = .{ .named = "len" }, .func = root.define(&.{.table}, len) },
        .{ .key = .{ .named = "add" }, .func = root.define(&.{ .table, .table }, tableAdd) },
        .{ .key = .{ .core = .__tostring }, .func = root.define(&.{.table}, tostring) },
        .{ .key = .{ .core = .__debug }, .func = root.define(&.{.table}, debug) },
        // from iter.zig
        .{ .key = .{ .named = "map" }, .func = root.define(&.{ .any, .function }, iter.map_fn) },
        .{ .key = .{ .named = "filter" }, .func = root.define(&.{ .any, .function }, iter.filter_fn) },
        .{ .key = .{ .named = "reduce" }, .func = root.define(&.{ .any, .function, .any }, iter.reduce_fn) },
        .{ .key = .{ .named = "each" }, .func = root.define(&.{ .any, .function }, iter.each_fn) },
        .{ .key = .{ .named = "find" }, .func = root.define(&.{ .any, .function }, iter.find_fn) },
        .{ .key = .{ .named = "all?" }, .func = root.define(&.{ .any, .function }, iter.all_fn) },
        .{ .key = .{ .named = "any?" }, .func = root.define(&.{ .any, .function }, iter.any_fn) },
    }, Data.new.table(std.math.maxInt(usize)));
}

/// > unwrap(result: tuple) -> any
/// unwraps result tuple, panics if not :ok
pub fn @"try"(args: []const Data, vm: *VM) !NativeResult {
    const table_id = args[0].table;
    const table = try vm.tables.get(table_id);
    if (table.array.items.len < 2) return .errType(0, "table with at least 2 elements", "table with less than 2 elements");
    const tag = table.array.items[0];

    return switch (tag) {
        .atom => |atom| blk: {
            const ok_id = revo.core_atoms.atom_id(.ok);
            if (atom != ok_id) return root.panic_(&[1]Data{table.array.items[1]}, vm);
            break :blk .{ .ok = table.array.items[1] };
        },
        else => .errType(0, "tuple starting with atom", "tuple starting with non-atom"),
    };
}

/// > table:as_tuple() -> tuple
/// converts table array part to tuple
fn as_tuple(args: []const Data, vm: *VM) !NativeResult {
    const table_id = args[0].table;

    const table = try vm.tables.get(table_id);

    var values_list = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, table.array.items.len + 10);

    defer values_list.deinit(vm.runtime.alloc);

    for (table.array.items) |val|
        try values_list.append(vm.runtime.alloc, val);

    const values_slice = try values_list.toOwnedSlice(vm.runtime.alloc);
    defer vm.runtime.alloc.free(values_slice);

    const result_tuple = try vm.tuples.create(values_slice);

    return .okData(Data.new.tuple(result_tuple));
}

/// > table:insert(pos: number, value: any) -> atom
/// inserts value at position, shifting elements right
fn insert(args: []const Data, vm: *VM) !NativeResult {
    if (args.len != 3) return .errArity(args.len, 3);
    const table_id = switch (args[0]) {
        .table => |id| id,
        else => return .errType(0, "table", dataToString(args[0])),
    };
    const pos = switch (args[1]) {
        .number => |n| @as(i64, @intFromFloat(n)),
        else => return .errType(1, "number", dataToString(args[1])),
    };
    const val = args[2];

    const table = vm.tables.get(table_id) catch return .errType(0, "table", dataToString(args[0]));
    if (pos < 0) return .errType(1, "non-negative number", dataToString(args[1]));

    const pos_usize: usize = @intCast(pos);
    if (pos_usize <= table.array.items.len) {
        try table.array.insert(vm.runtime.alloc, pos_usize, val);
    } else {
        try table.array.append(vm.runtime.alloc, val);
    }

    return .{ .ok = revo.core_atoms.data(.ok) };
}

/// > table:remove(pos: number) -> any
/// removes element at position, returns removed value
fn remove(args: []const Data, vm: *VM) !NativeResult {
    if (args.len != 2) return .errArity(args.len, 2);
    const table_id = switch (args[0]) {
        .table => |id| id,
        else => return .errType(0, "table", dataToString(args[0])),
    };
    const pos = switch (args[1]) {
        .number => |n| @as(i64, @intFromFloat(n)),
        else => return .errType(1, "number", dataToString(args[1])),
    };

    const table = vm.tables.get(table_id) catch return .errType(0, "table", dataToString(args[0]));
    if (pos < 0 or pos >= table.array.items.len) return .errType(1, "valid index", dataToString(args[1]));

    const pos_usize: usize = @intCast(pos);
    const removed = table.array.orderedRemove(pos_usize);
    return .okData(removed);
}

/// > table:push(value: any) -> table
/// inserts element as last
fn push(args: []const Data, vm: *VM) !NativeResult {
    const table_id = args[0].table;

    const table = vm.tables.get(table_id) catch return .errType(0, "table", dataToString(args[0]));

    try table.array.appendSlice(vm.runtime.alloc, args[1..]);

    return .{ .ok = .{ .table = table_id } };
}

/// > table:concat(delim: string) -> string
/// concatenates array elements with delimiter
fn concat(args: []const Data, vm: *VM) !NativeResult {
    if (args.len != 2) return .errArity(args.len, 2);
    const table_id = switch (args[0]) {
        .table => |id| id,
        else => return .errType(0, "table", dataToString(args[0])),
    };
    const delim = switch (args[1]) {
        .string => |id| vm.stringValue(id),
        else => return .errType(1, "string", dataToString(args[1])),
    };

    const table = vm.tables.get(table_id) catch return .errType(0, "table", dataToString(args[0]));
    var buf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer buf.deinit();

    for (table.array.items, 0..) |item, idx| {
        if (idx > 0) try buf.writer.writeAll(delim);
        var temp = std.Io.Writer.Allocating.init(vm.runtime.alloc);
        defer temp.deinit();
        try item.write(&temp.writer, vm, .display);
        try buf.writer.writeAll(temp.written());
    }

    const slice = try buf.toOwnedSlice();
    const result = try vm.adoptDataString(slice);
    return .{ .ok = result };
}

/// > table:keys() -> table
/// returns all keys as table (array indices + hash keys)
fn keys(args: []const Data, vm: *VM) !NativeResult {
    if (args.len != 1) return .errArity(args.len, 1);
    const table_id = switch (args[0]) {
        .table => |id| id,
        else => return .errType(0, "table", dataToString(args[0])),
    };

    const table = vm.tables.get(table_id) catch return .errType(0, "table", dataToString(args[0]));
    var keys_list = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, table.array.items.len + 10);
    defer keys_list.deinit(vm.runtime.alloc);

    for (0..table.array.items.len) |idx| {
        try keys_list.append(vm.runtime.alloc, Data.new.num(idx));
    }

    for (table.hash_order.items) |key| {
        try keys_list.append(vm.runtime.alloc, key);
    }

    const result_table = try vm.tables.create();
    const result = try vm.tables.get(result_table);
    for (keys_list.items, 0..) |key, idx| {
        try result.putRaw(Data.new.num(idx), key);
    }

    return .{ .ok = .{ .table = result_table } };
}

/// > table:values() -> table
/// returns all values as table
fn values(args: []const Data, vm: *VM) !NativeResult {
    if (args.len != 1) return .errArity(args.len, 1);
    const table_id = switch (args[0]) {
        .table => |id| id,
        else => return .errType(0, "table", dataToString(args[0])),
    };

    const table = try vm.tables.get(table_id);
    var values_list = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, table.array.items.len + 10);
    defer values_list.deinit(vm.runtime.alloc);

    for (table.array.items) |val|
        try values_list.append(vm.runtime.alloc, val);

    for (table.hash_order.items) |key| {
        if (table.hash_entries.get(key)) |val| {
            try values_list.append(vm.runtime.alloc, val);
        }
    }

    const result_table = try vm.tables.create();
    const result = try vm.tables.get(result_table);
    for (values_list.items, 0..) |val, idx| {
        try result.putRaw(Data.new.num(idx), val);
    }

    return .{ .ok = .{ .table = result_table } };
}

/// > table:len() -> number
/// returns length of table array part
fn len(args: []const Data, vm: *VM) !NativeResult {
    const table = try vm.tables.get(args[0].table);
    return .okData(Data.new.num(table.array.items.len));
}

/// > table:has?(key: any) -> bool
/// checks if key exists in table
fn has(args: []const Data, vm: *VM) !NativeResult {
    if (args.len != 2) return .errArity(args.len, 2);
    const table_id = switch (args[0]) {
        .table => |id| id,
        else => return .errType(0, "table", dataToString(args[0])),
    };

    const table = try vm.tables.get(table_id);
    const exists = try table.get(args[1], vm);
    return .{ .ok = root.boolData(exists != null) };
}

/// > table:copy() -> table
/// creates shallow copy of table
fn copy(args: []const Data, vm: *VM) !NativeResult {
    if (args.len != 1) return .errArity(args.len, 1);
    const table_id = switch (args[0]) {
        .table => |id| id,
        else => return .errType(0, "table", dataToString(args[0])),
    };

    const table = vm.tables.get(table_id) catch return .errType(0, "table", dataToString(args[0]));
    const new_table = try vm.tables.create();
    const new_t = try vm.tables.get(new_table);

    try new_t.array.appendSlice(vm.runtime.alloc, table.array.items);

    var hash_iter = table.hash_entries.iterator();
    while (hash_iter.next()) |entry| {
        try new_t.putRaw(entry.key_ptr.*, entry.value_ptr.*);
    }
    try new_t.hash_order.appendSlice(vm.runtime.alloc, table.hash_order.items);

    return .{ .ok = .{ .table = new_table } };
}

/// > table:merge(other: table) -> table
/// merges second table into first
/// later values overwrite earlier ones
fn merge(args: []const Data, vm: *VM) !NativeResult {
    if (args.len != 2) return .errArity(args.len, 2);
    const table1_id = switch (args[0]) {
        .table => |id| id,
        else => return .errType(0, "table", dataToString(args[0])),
    };
    const table2_id = switch (args[1]) {
        .table => |id| id,
        else => return .errType(1, "table", dataToString(args[1])),
    };

    const table1 = vm.tables.get(table1_id) catch return .errType(0, "table", dataToString(args[0]));
    const table2 = vm.tables.get(table2_id) catch return .errType(1, "table", dataToString(args[1]));

    const result_table = try vm.tables.create();
    const result = try vm.tables.get(result_table);

    try result.array.appendSlice(vm.runtime.alloc, table1.array.items);
    try result.array.appendSlice(vm.runtime.alloc, table2.array.items);

    var hash_iter1 = table1.hash_entries.iterator();
    while (hash_iter1.next()) |entry| {
        try result.putRaw(entry.key_ptr.*, entry.value_ptr.*);
    }
    var hash_iter2 = table2.hash_entries.iterator();
    while (hash_iter2.next()) |entry| {
        try result.putRaw(entry.key_ptr.*, entry.value_ptr.*);
    }
    try result.hash_order.appendSlice(vm.runtime.alloc, table1.hash_order.items);
    try result.hash_order.appendSlice(vm.runtime.alloc, table2.hash_order.items);

    return .okData(.{ .table = result_table });
}

/// > rawget(table: table, key: any) -> any
/// gets value without metamethods
/// returns :undef if key missing
fn rawget(args: []const Data, vm: *VM) !NativeResult {
    if (args.len != 2) return .errArity(args.len, 2);
    const table_id = switch (args[0]) {
        .table => |id| id,
        else => return .errType(0, "table", dataToString(args[0])),
    };
    const t = try vm.tables.get(table_id);
    return .okData(t.getRaw(args[1]) orelse revo.core_atoms.data(.undef));
}

/// > rawset(table: table, key: any, value: any) -> table
/// sets value without metamethods
fn rawset(args: []const Data, vm: *VM) !NativeResult {
    if (args.len != 3) return .errArity(args.len, 3);
    const table_id = switch (args[0]) {
        .table => |id| id,
        else => return .errType(0, "table", dataToString(args[0])),
    };
    const t = try vm.tables.get(table_id);
    try t.putRaw(args[1], args[2]);
    return .okData(args[0]);
}

test "table library" {
    try testing.top_number("len({1, 2, 3})", 3);
}

/// > table + other: table -> table
/// merges two tables (union)
fn tableAdd(args: []const Data, vm: *VM) !NativeResult {
    const left_id = switch (args[0]) {
        .table => |id| id,
        else => return .errType(0, "table", dataToString(args[0])),
    };
    const right_id = switch (args[1]) {
        .table => |id| id,
        else => return .errType(1, "table", dataToString(args[1])),
    };
    const left = try vm.tables.get(left_id);
    const right = try vm.tables.get(right_id);

    const new_id = try vm.tables.create();
    const new_t = try vm.tables.get(new_id);

    var hash_iter = left.hash_entries.iterator();
    while (hash_iter.next()) |entry| {
        try new_t.putRaw(entry.key_ptr.*, entry.value_ptr.*);
    }
    hash_iter = right.hash_entries.iterator();
    while (hash_iter.next()) |entry| {
        try new_t.putRaw(entry.key_ptr.*, entry.value_ptr.*);
    }
    return .okData(.{ .table = new_id });
}

/// > table:tostring() -> string
/// converts table to display string
fn tostring(args: []const Data, vm: *VM) !NativeResult {
    const table_id = switch (args[0]) {
        .table => |id| id,
        else => return .errType(0, "table", dataToString(args[0])),
    };
    const tbl = try vm.tables.get(table_id);
    var buf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer buf.deinit();
    try tbl.write(&buf.writer, vm, .display);
    const slice = try buf.toOwnedSlice();
    const result = try vm.adoptDataString(slice);
    return .okData(result);
}

/// > table:__debug() -> string
/// converts table to debug string
fn debug(args: []const Data, vm: *VM) !NativeResult {
    const table_id = switch (args[0]) {
        .table => |id| id,
        else => return .errType(0, "table", dataToString(args[0])),
    };
    const tbl = try vm.tables.get(table_id);
    var buf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer buf.deinit();
    try tbl.write(&buf.writer, vm, .debug);
    const slice = try buf.toOwnedSlice();
    const result = try vm.adoptDataString(slice);
    return .okData(result);
}

/// > table:sort() -> table
/// sorts table array part in ascending order (numbers < strings)
fn sort(args: []const Data, vm: *VM) !NativeResult {
    const table_id = args[0].table;
    const tbl = try vm.tables.get(table_id);

    const Context = struct {
        vm: *VM,
        pub fn compare(ctx: @This(), a: Data, b: Data) bool {
            switch (a) {
                .number => |an| switch (b) {
                    .number => |bn| return an < bn,
                    else => return true,
                },
                .string => |as| switch (b) {
                    .string => |bs| {
                        const astr = ctx.vm.stringValue(as);
                        const bstr = ctx.vm.stringValue(bs);
                        return std.mem.order(u8, astr, bstr) == .lt;
                    },
                    .number => return false,
                    else => return true,
                },
                else => return false,
            }
        }
    };

    const ctx = Context{ .vm = vm };
    std.mem.sort(Data, tbl.array.items, ctx, Context.compare);
    return .okData(args[0]);
}

/// > table:sort_by(fn) -> table
/// sorts table array part using comparison function fn(a, b) -> bool (true if a < b)
fn sort_by(args: []const Data, vm: *VM) !NativeResult {
    const table_id = args[0].table;
    const compare_fn = args[1];
    const tbl = try vm.tables.get(table_id);

    const Context = struct {
        vm: *VM,
        fn_data: Data,
        pub fn compare(ctx: @This(), a: Data, b: Data) bool {
            const result = ctx.vm.callFunction(ctx.fn_data, &[_]Data{ a, b }) catch return false;
            return !revo.isFalse(result);
        }
    };

    const ctx = Context{ .vm = vm, .fn_data = compare_fn };
    std.mem.sort(Data, tbl.array.items, ctx, Context.compare);
    return .okData(args[0]);
}

/// > table:first() -> any
/// returns first element or nil
fn first(args: []const Data, vm: *VM) !NativeResult {
    const table_id = args[0].table;
    const tbl = try vm.tables.get(table_id);
    if (tbl.array.items.len == 0) {
        return .{ .ok = revo.core_atoms.data(.nil) };
    }
    return .{ .ok = tbl.array.items[0] };
}

/// > table:last() -> any
/// returns last element or nil
fn last(args: []const Data, vm: *VM) !NativeResult {
    const table_id = args[0].table;
    const tbl = try vm.tables.get(table_id);
    if (tbl.array.items.len == 0) {
        return .{ .ok = revo.core_atoms.data(.nil) };
    }
    return .{ .ok = tbl.array.items[tbl.array.items.len - 1] };
}

/// > table:reverse() -> table
/// reverses table array part in place
fn reverse(args: []const Data, vm: *VM) !NativeResult {
    const table_id = args[0].table;
    const tbl = try vm.tables.get(table_id);
    std.mem.reverse(Data, tbl.array.items);
    return .{ .ok = args[0] };
}

/// > table:flatten() -> table
/// flattens nested tables into single array
fn flatten(args: []const Data, vm: *VM) !NativeResult {
    const table_id = args[0].table;
    const src = try vm.tables.get(table_id);

    const result_id = try vm.tables.create();
    const result = try vm.tables.get(result_id);

    for (src.array.items) |item| {
        if (item == .table) {
            const nested_id = item.table;
            const nested = try vm.tables.get(nested_id);
            for (nested.array.items) |maybe_nested| {
                try result.array.append(vm.runtime.alloc, maybe_nested);
            }
        } else {
            try result.array.append(vm.runtime.alloc, item);
        }
    }

    return .{ .ok = Data.new.table(result_id) };
}

/// > table:index_of(value) -> number | nil
/// ret 0-based index of value or nil if not found
fn index_of(args: []const Data, vm: *VM) !NativeResult {
    const table_id = args[0].table;
    const search_val = args[1];
    const tbl = try vm.tables.get(table_id);

    for (tbl.array.items, 0..) |item, i| {
        if (dataEq(item, search_val)) {
            return .{ .ok = Data.new.num(i) };
        }
    }
    return .{ .ok = revo.core_atoms.data(.nil) };
}

/// > table:contains?(value) -> bool
/// checks if table contains value
fn contains(args: []const Data, vm: *VM) !NativeResult {
    const table_id = args[0].table;
    const search_val = args[1];
    const tbl = try vm.tables.get(table_id);

    for (tbl.array.items) |item| {
        if (dataEq(item, search_val)) {
            return .okBool(true);
        }
    }
    return .okBool(false);
}

/// > table:unique() -> table
/// removes duplicate elements
fn unique(args: []const Data, vm: *VM) !NativeResult {
    const table_id = args[0].table;
    const src = try vm.tables.get(table_id);

    const result_id = try vm.tables.create();
    const result = try vm.tables.get(result_id);

    for (src.array.items) |item| {
        var found = false;
        for (result.array.items) |res| {
            if (dataEq(item, res)) {
                found = true;
                break;
            }
        }

        if (!found) {
            try result.array.append(vm.runtime.alloc, item);
        }
    }

    return .{ .ok = Data.new.table(result_id) };
}

/// > table:sum() -> number
/// sums numeric elements
fn sum(args: []const Data, vm: *VM) !NativeResult {
    const table_id = args[0].table;
    const tbl = try vm.tables.get(table_id);

    var total: f64 = 0;
    for (tbl.array.items) |item| {
        if (item == .number)
            total += item.number;
    }

    return .{ .ok = Data.new.num(total) };
}

fn dataEq(a: Data, b: Data) bool {
    switch (a) {
        .number => |an| return b == .number and an == b.number,
        .string => |as| return b == .string and as == b.string,
        .atom => |aa| return b == .atom and aa == b.atom,
        else => return false,
    }
}

test "table methods" {
    try testing.top_number("{1, 2, 3}:first()", 1);
    try testing.top_number("{1, 2, 3}:last()", 3);
    try testing.top_true("{1, 2, 3}:contains?(2)");
    try testing.top_false("{1, 2, 3}:contains?(5)");
    try testing.top_number("{1, 2, 3}:index_of(2)", 1);
    try testing.top_number("{1, 2, 3}:sum()", 6);
}
