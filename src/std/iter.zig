const all_places: []const api.Placement = &.{
    api.g,
    api.method("string", .string),
    api.method("tuple", .tuple),
    api.method("table", .table),
};

pub const specs: []const api.FnSpec = &.{
    .{
        .name = "to_iter",
        .placements = &.{api.g},
        .params = &.{.{ "obj", "any" }},
        .ret = "function",
        .doc =
        \\ wraps any iterable in a zero-arg callable
        \\ built-in types (string, tuple, table) get a position-based iterator
        \\ functions return as-is (already callable)
        \\ tables with __iter metamethod call __iter(obj)
        ,
        .f = root.define(&.{.any}, to_iter),
    },
    .{
        .name = "map",
        .placements = &.{
            api.g,
            api.method("string", .string),
            api.method("tuple", .tuple),
            api.method("table", .table),
        },
        .params = &.{
            .{ "collection", "any" },
            .{ "fn", "function" },
        },
        .ret = "string|tuple|table",
        .doc =
        \\transforms each element by applying function
        \\    map("hello", fn(c) = c:upper())
        \\    map((1,2,3), fn(x) = x * 2)
        \\    map({a=1, b=2}, fn(v) = v + 10)
        ,
        .f = root.define(&.{ .any, .function }, map_fn),
    },
    .{
        .name = "filter",
        .placements = all_places,
        .params = &.{
            .{ "collection", "any" },
            .{ "fn", "function" },
        },
        .ret = "function",
        .doc =
        \\returns a new iterator that only yields values where pred returns truthy
        \\    filter((1,2,3,4), fn(x) = x > 2)
        ,
        .f = root.define(&.{ .any, .function }, filter_fn),
    },
    .{
        .name = "collect",
        .placements = &.{api.mod("iter")},
        .params = &.{
            .{ "iterable", "any" },
        },
        .ret = "table",
        .doc =
        \\collects all values from an iterable into a table
        \\    iter.collect(iterable)
        ,
        .f = root.define(&.{.any}, collect_fn),
    },
    .{
        .name = "reduce",
        .placements = all_places,
        .params = &.{
            .{ "collection", "any" },
            .{ "fn", "function" },
            .{ "init", "any" },
        },
        .ret = "any",
        .doc =
        \\folds/accumulates elements using function and initial value
        \\    reduce((1,2,3,4), fn(acc, x) = acc + x, 0)
        \\    reduce("hello", fn(acc, c) = acc + 1, 0)
        \\    reduce({a=1, b=2}, fn(acc, v) = acc + v, 0)
        ,
        .f = root.define(&.{ .any, .function, .any }, reduce_fn),
    },
    .{
        .name = "each",
        .placements = all_places,
        .params = &.{
            .{ "collection", "any" },
            .{ "fn", "function" },
        },
        .ret = ":ok",
        .doc =
        \\iterates over elements, calling function for side effects, returns :ok
        \\    each("hello", fn(c) = print(c))
        \\    each((1,2,3), fn(x) = print(x))
        \\    each({a=1, b=2}, fn(v) = print(v))
        ,
        .f = root.define(&.{ .any, .function }, each_fn),
    },
    .{
        .name = "find",
        .placements = all_places,
        .params = &.{
            .{ "what", "any" },
            .{ "fn", "function" },
        },
        .ret = "any",
        .doc =
        \\returns first element where function returns true, or :missing if not found
        \\    find("hello", fn(c) = c == "l")
        \\    find((1,2,3,4), fn(x) = x > 2)
        \\    find({a=1, b=2}, fn(v) = v > 1)
        ,
        .f = root.define(&.{ .any, .function }, find_fn),
    },
    .{
        .name = "all?",
        .placements = all_places,
        .params = &.{
            .{ "collection", "any" },
            .{ "pred", "function" },
        },
        .ret = "boolean",
        .doc =
        \\returns true if function returns true for all elements
        \\    all?((1,2,3), fn(x) = x > 0)
        \\    all?("hello", fn(c) = c != " ")
        \\    all?({a=1, b=2}, fn(v) = v > 0)
        ,
        .f = root.define(&.{ .any, .function }, all_fn),
    },
    .{
        .name = "any?",
        .placements = all_places,
        .params = &.{
            .{ "collection", "any" },
            .{ "pred", "function" },
        },
        .ret = "boolean",
        .doc =
        \\returns true if function returns true for any element
        \\    any?((1,2,3), fn(x) = x > 2)
        \\    any?("hello", fn(c) = c == "l")
        \\    any?({a=1, b=2}, fn(v) = v > 1)
        ,
        .f = root.define(&.{ .any, .function }, any_fn),
    },
};

/// > map(collection: string|tuple|table, fn: function) -> string|tuple|table
/// transforms each element by applying function
///     map("hello", fn(c) = c:upper())
///     map((1,2,3), fn(x) = x * 2)
///     map({a=1, b=2}, fn(v) = v + 10)
pub fn map_fn(args: []const Data, vm: *VM) !NativeResult {
    if (args.len < 2) return .errArity(args.len, 2);

    const fn_data = args[1];
    if (!fn_data.isFunction()) return .errType(1, "function", dataToString(fn_data));

    switch (args[0].tag()) {
        .string => {
            const str = vm.stringValue(args[0].asString().?);
            var buf = try std.ArrayList(u8).initCapacity(vm.runtime.alloc, str.len);
            errdefer buf.deinit(vm.runtime.alloc);

            for (str) |byte| {
                const char_str = try vm.ownDataString(&[_]u8{byte});
                const fn_result = try vm.callFunction(fn_data, &[_]Data{char_str});

                const mapped_byte = if (fn_result.asString()) |s|
                    vm.stringValue(s)[0]
                else if (fn_result.asNum()) |n|
                    @as(u8, @intFromFloat(std.math.clamp(@round(n), 0, 255)))
                else
                    return .errType(0, "string or number", dataToString(fn_result));
                try buf.append(vm.runtime.alloc, mapped_byte);
            }

            const result_str = try vm.adoptDataString(try buf.toOwnedSlice(vm.runtime.alloc));
            return .{ .ok = result_str };
        },
        .tuple => {
            const t_id = args[0].asTuple().?;
            const tuple = try vm.tuples.get(t_id);
            var result_items = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, tuple.items.len);
            errdefer result_items.deinit(vm.runtime.alloc);

            for (tuple.items) |item| {
                const fn_result = try vm.callFunction(fn_data, &[_]Data{item});
                try result_items.append(vm.runtime.alloc, fn_result);
            }

            const result_tuple = try vm.tuples.create(result_items.items);
            result_items.deinit(vm.runtime.alloc);
            return .okData(Data.new.tuple(result_tuple));
        },
        .table => {
            const table_id = args[0].asTable().?;
            const result_table_id = try vm.tables.create();
            const result_table = try vm.tables.get(result_table_id);
            const table = try vm.tables.get(table_id);

            for (table.array.items) |item| {
                const fn_result = try vm.callFunction(fn_data, &[_]Data{item});
                try result_table.array.append(vm.runtime.alloc, fn_result);
            }

            var hash_it = table.hash.orderedIterator();
            while (hash_it.next()) |entry| {
                const fn_result = try vm.callFunction(fn_data, &[_]Data{entry.val});
                try result_table.putRaw(entry.key, fn_result);
            }

            return .okData(Data.new.table(result_table_id));
        },
        else => return .errType(0, "string, tuple, or table", dataToString(args[0])),
    }
}

/// > filter(iterable: any, pred: function) -> function
/// returns a new iterator that only yields values where pred returns truthy
pub fn filter_fn(args: []const Data, vm: *VM) !NativeResult {
    if (args.len < 2) return .errArity(args.len, 2);

    const result = try to_iter(args[0..1], vm);
    const iter = result.ok;
    const pred = args[1];
    if (!pred.isFunction()) return .errType(1, "function", dataToString(pred));

    const atom_iter = revo.core_atoms.iter.atom_id();
    const atom_pred = revo.core_atoms.pred.atom_id();

    const it_id = try vm.tables.create();
    const it = try vm.tables.get(it_id);
    try it.putRaw(Data.new.atom(atom_iter), iter);
    try it.putRaw(Data.new.atom(atom_pred), pred);

    const mt_id = try vm.tables.create();
    const mt = try vm.tables.get(mt_id);
    const call_fn_id = try vm.installNative("filter_next", .{
        .arity = 1,
        .param_types = &.{.any},
        .func = filterNext,
    });
    try mt.putRawAtom(revo.core_atoms.__call.atom_id(), Data.new.function(call_fn_id));
    try vm.setTableMetatable(it_id, mt_id);

    return .okData(Data.new.table(it_id));
}

/// > collect(iterable: any) -> table
/// collects all values from an iterable into a table
pub fn collect_fn(args: []const Data, vm: *VM) !NativeResult {
    if (args.len < 1) return .errArity(args.len, 1);

    const result = try to_iter(args[0..1], vm);
    const iter = result.ok;

    const out_id = try vm.tables.create();
    const out = try vm.tables.get(out_id);

    while (true) {
        const val = try vm.callFunction(iter, &.{});
        if (val.asAtom()) |atom| if (atom == revo.core_atoms.atom_id(.done)) break;
        try out.array.append(vm.runtime.alloc, val);
    }

    return .okData(Data.new.table(out_id));
}

/// __call handler for filter iterator tables
/// reads self.iter and self.pred, skips values that fail predicate
fn filterNext(args: []const Data, vm: *VM) !NativeResult {
    const tbl_id = args[0].asTable().?;
    const tbl = try vm.tables.get(tbl_id);
    const iter = tbl.getRawAtom(revo.core_atoms.iter.atom_id()).?;
    const pred = tbl.getRawAtom(revo.core_atoms.pred.atom_id()).?;
    const done_id = revo.core_atoms.atom_id(.done);

    while (true) {
        const val = try vm.callFunction(iter, &.{});
        if (val.asAtom()) |atom| if (atom == done_id) return .okData(revo.Data.new.core(.done));
        const ok = try vm.callFunction(pred, &[_]Data{val});
        if (isTruthy(ok)) return .okData(val);
    }
}

/// > reduce(collection: string|tuple|table, fn: function, init: any) -> any
/// folds/accumulates elements using function and initial value
///     reduce((1,2,3,4), fn(acc, x) = acc + x, 0)
///     reduce("hello", fn(acc, c) = acc + 1, 0)
///     reduce({a=1, b=2}, fn(acc, v) = acc + v, 0)
pub fn reduce_fn(args: []const Data, vm: *VM) !NativeResult {
    if (args.len < 3) return .errArity(args.len, 3);

    const fn_data = args[1];
    if (!fn_data.isFunction()) return .errType(1, "function", dataToString(fn_data));

    var accumulator = args[2];

    switch (args[0].tag()) {
        .string => {
            const str = vm.stringValue(args[0].asString().?);
            for (str) |byte| {
                const char_str = try vm.ownDataString(&[_]u8{byte});
                accumulator = try vm.callFunction(fn_data, &[_]Data{ accumulator, char_str });
            }
        },
        .tuple => {
            const t_id = args[0].asTuple().?;
            const tuple = try vm.tuples.get(t_id);
            for (tuple.items) |item| {
                accumulator = try vm.callFunction(fn_data, &[_]Data{ accumulator, item });
            }
        },
        .table => {
            const table_id = args[0].asTable().?;
            const table = try vm.tables.get(table_id);

            for (table.array.items) |item| {
                accumulator = try vm.callFunction(fn_data, &[_]Data{ accumulator, item });
            }

            var hash_it = table.hash.orderedIterator();
            while (hash_it.next()) |entry| {
                accumulator = try vm.callFunction(fn_data, &[_]Data{ accumulator, entry.val });
            }
        },
        else => return .errType(0, "string, tuple, or table", dataToString(args[0])),
    }

    return .{ .ok = accumulator };
}

/// > each(collection: string|tuple|table, fn: function) -> atom
/// iterates over elements, calling function for side effects, returns :ok
///     each("hello", fn(c) = print(c))
///     each((1,2,3), fn(x) = print(x))
///     each({a=1, b=2}, fn(v) = print(v))
pub fn each_fn(args: []const Data, vm: *VM) !NativeResult {
    if (args.len < 2) return .errArity(args.len, 2);

    const fn_data = args[1];
    if (!fn_data.isFunction()) return .errType(1, "function", dataToString(fn_data));

    switch (args[0].tag()) {
        .string => {
            const str = vm.stringValue(args[0].asString().?);
            for (str) |byte| {
                const char_str = try vm.ownDataString(&[_]u8{byte});
                _ = try vm.callFunction(fn_data, &[_]Data{char_str});
            }
        },
        .tuple => {
            const t_id = args[0].asTuple().?;
            const tuple = try vm.tuples.get(t_id);
            for (tuple.items) |item| {
                _ = try vm.callFunction(fn_data, &[_]Data{item});
            }
        },
        .table => {
            const table_id = args[0].asTable().?;
            const table = try vm.tables.get(table_id);

            for (table.array.items) |item| {
                _ = try vm.callFunction(fn_data, &[_]Data{item});
            }

            var hash_it = table.hash.orderedIterator();
            while (hash_it.next()) |entry| {
                _ = try vm.callFunction(fn_data, &[_]Data{entry.val});
            }
        },
        else => return .errType(0, "string, tuple, or table", dataToString(args[0])),
    }

    return root.okAtom(vm);
}

/// > find(collection: string|tuple|table, fn: function) -> any
/// returns first element where function returns true, or :missing if not found
///     find("hello", fn(c) = c == "l")
///     find((1,2,3,4), fn(x) = x > 2)
///     find({a=1, b=2}, fn(v) = v > 1)
pub fn find_fn(args: []const Data, vm: *VM) !NativeResult {
    if (args.len < 2) return .errArity(args.len, 2);

    const fn_data = args[1];
    if (!fn_data.isFunction()) return .errType(1, "function", dataToString(fn_data));

    switch (args[0].tag()) {
        .string => {
            const str = vm.stringValue(args[0].asString().?);
            for (str) |byte| {
                const char_str = try vm.ownDataString(&[_]u8{byte});
                const fn_result = try vm.callFunction(fn_data, &[_]Data{char_str});
                if (isTruthy(fn_result)) {
                    return .{ .ok = char_str };
                }
            }
        },
        .tuple => {
            const t_id = args[0].asTuple().?;
            const tuple = try vm.tuples.get(t_id);
            for (tuple.items) |item| {
                const fn_result = try vm.callFunction(fn_data, &[_]Data{item});
                if (isTruthy(fn_result)) {
                    return .{ .ok = item };
                }
            }
        },
        .table => {
            const table_id = args[0].asTable().?;
            const table = try vm.tables.get(table_id);

            for (table.array.items) |item| {
                const fn_result = try vm.callFunction(fn_data, &[_]Data{item});
                if (isTruthy(fn_result)) {
                    return .{ .ok = item };
                }
            }

            var hash_it = table.hash.orderedIterator();
            while (hash_it.next()) |entry| {
                const fn_result = try vm.callFunction(fn_data, &[_]Data{entry.val});
                if (isTruthy(fn_result)) {
                    return .{ .ok = entry.val };
                }
            }
        },
        else => return .errType(0, "string, tuple, or table", dataToString(args[0])),
    }

    return .{ .ok = revo.Data.new.core(.missing) };
}

/// > all?(collection: string|tuple|table, fn: function) -> boolean
/// returns true if function returns true for all elements
///     all?((1,2,3), fn(x) = x > 0)
///     all?("hello", fn(c) = c != " ")
///     all?({a=1, b=2}, fn(v) = v > 0)
pub fn all_fn(args: []const Data, vm: *VM) !NativeResult {
    if (args.len < 2) return .errArity(args.len, 2);

    const fn_data = args[1];
    if (!fn_data.isFunction()) return .errType(1, "function", dataToString(fn_data));

    switch (args[0].tag()) {
        .string => {
            const str = vm.stringValue(args[0].asString().?);
            for (str) |byte| {
                const char_str = try vm.ownDataString(&[_]u8{byte});
                const fn_result = try vm.callFunction(fn_data, &[_]Data{char_str});
                if (!isTruthy(fn_result)) {
                    return .{ .ok = Data.new.boolean(false) };
                }
            }
        },
        .tuple => {
            const t_id = args[0].asTuple().?;
            const tuple = try vm.tuples.get(t_id);
            for (tuple.items) |item| {
                const fn_result = try vm.callFunction(fn_data, &[_]Data{item});
                if (!isTruthy(fn_result)) {
                    return .{ .ok = Data.new.boolean(false) };
                }
            }
        },
        .table => {
            const table_id = args[0].asTable().?;
            const table = try vm.tables.get(table_id);

            for (table.array.items) |item| {
                const fn_result = try vm.callFunction(fn_data, &[_]Data{item});
                if (!isTruthy(fn_result)) {
                    return .{ .ok = Data.new.boolean(false) };
                }
            }

            var hash_it = table.hash.orderedIterator();
            while (hash_it.next()) |entry| {
                const fn_result = try vm.callFunction(fn_data, &[_]Data{entry.val});
                if (!isTruthy(fn_result)) {
                    return .{ .ok = Data.new.boolean(false) };
                }
            }
        },
        else => return .errType(0, "string, tuple, or table", dataToString(args[0])),
    }

    return .{ .ok = Data.new.boolean(true) };
}

/// > any?(collection: string|tuple|table, fn: function) -> boolean
/// returns true if function returns true for any element
///     any?((1,2,3), fn(x) = x > 2)
///     any?("hello", fn(c) = c == "l")
///     any?({a=1, b=2}, fn(v) = v > 1)
pub fn any_fn(args: []const Data, vm: *VM) !NativeResult {
    if (args.len < 2) return .errArity(args.len, 2);

    const fn_data = args[1];
    if (!fn_data.isFunction()) return .errType(1, "function", dataToString(fn_data));

    switch (args[0].tag()) {
        .string => {
            const str = vm.stringValue(args[0].asString().?);
            for (str) |byte| {
                const char_str = try vm.ownDataString(&[_]u8{byte});
                const fn_result = try vm.callFunction(fn_data, &[_]Data{char_str});
                if (isTruthy(fn_result)) {
                    return .{ .ok = Data.new.boolean(true) };
                }
            }
        },
        .tuple => {
            const t_id = args[0].asTuple().?;
            const tuple = try vm.tuples.get(t_id);
            for (tuple.items) |item| {
                const fn_result = try vm.callFunction(fn_data, &[_]Data{item});
                if (isTruthy(fn_result)) {
                    return .{ .ok = Data.new.boolean(true) };
                }
            }
        },
        .table => {
            const table_id = args[0].asTable().?;
            const table = try vm.tables.get(table_id);

            for (table.array.items) |item| {
                const fn_result = try vm.callFunction(fn_data, &[_]Data{item});
                if (isTruthy(fn_result)) {
                    return .{ .ok = Data.new.boolean(true) };
                }
            }

            var hash_it = table.hash.orderedIterator();
            while (hash_it.next()) |entry| {
                const fn_result = try vm.callFunction(fn_data, &[_]Data{entry.val});
                if (isTruthy(fn_result)) {
                    return .{ .ok = Data.new.boolean(true) };
                }
            }
        },
        else => return .errType(0, "string, tuple, or table", dataToString(args[0])),
    }

    return .{ .ok = Data.new.boolean(false) };
}

/// > to_iter(obj: any) -> function
/// returns a zero-arg callable iterator for obj
pub fn to_iter(args: []const Data, vm: *VM) !NativeResult {
    const obj = args[0];

    if (obj.tag() == .function) return .okData(obj);

    if (try vm.getMetamethodByAtom(obj, revo.core_atoms.__iter.atom_id())) |mm|
        return .okData(try vm.callFunction(mm, &[_]Data{obj}));

    // callable tables are already iterators
    if (obj.tag() == .table and try vm.getMetamethodByAtom(obj, revo.core_atoms.__call.atom_id()) != null)
        return .okData(obj);

    if (obj.tag() == .string or obj.tag() == .tuple or obj.tag() == .table)
        return makeCallableIterator(vm, obj);

    return .errType(0, "iterable", dataToString(args[0]));
}

fn makeCallableIterator(vm: *VM, obj: Data) !NativeResult {
    const atom_obj = revo.core_atoms.obj.atom_id();
    const atom_pos = revo.core_atoms.pos.atom_id();

    const it_id = try vm.tables.create();
    const it = try vm.tables.get(it_id);
    try it.putRaw(Data.new.atom(atom_obj), obj);
    try it.putRaw(Data.new.atom(atom_pos), Data.new.num(0));

    const mt_id = try vm.tables.create();
    const mt = try vm.tables.get(mt_id);
    const call_fn_id = try vm.installNative("__iter_call", .{
        .arity = 1,
        .param_types = &.{.any},
        .func = iteratorNext,
    });
    try mt.putRawAtom(revo.core_atoms.__call.atom_id(), Data.new.function(call_fn_id));
    try vm.setTableMetatable(it_id, mt_id);

    return .okData(Data.new.table(it_id));
}

/// __call handler for iterator tables
/// reads self.obj and self.pos, returns element or :none
fn iteratorNext(args: []const Data, vm: *VM) !NativeResult {
    const it = args[0];
    const it_id = it.asTable().?;
    const tbl = try vm.tables.get(it_id);
    const atom_obj = revo.core_atoms.obj.atom_id();
    const atom_pos = revo.core_atoms.pos.atom_id();

    const obj = tbl.getRaw(Data.new.atom(atom_obj)) orelse return .okData(revo.Data.new.core(.done));
    const pos_val = tbl.getRaw(Data.new.atom(atom_pos)) orelse return .okData(revo.Data.new.core(.done));
    const pos = @as(usize, @intFromFloat(pos_val.asNum().?));

    const val: ?Data = switch (obj.tag()) {
        .string => blk: {
            const str = vm.stringValue(obj.asString().?);
            if (pos >= str.len) break :blk null;
            break :blk try vm.ownDataString(str[pos .. pos + 1]);
        },
        .tuple => blk: {
            const t_id = obj.asTuple().?;
            const t = vm.tuples.get(t_id) catch break :blk null;
            if (pos >= t.items.len) break :blk null;
            break :blk t.items[pos];
        },
        .table => blk: {
            const table_id = obj.asTable().?;
            const t = try vm.tables.get(table_id);
            if (pos >= t.array.items.len) break :blk null;
            break :blk t.array.items[pos];
        },
        else => null,
    };

    if (val) |v| {
        try tbl.putRaw(Data.new.atom(atom_pos), Data.new.num(@as(f64, @floatFromInt(pos + 1))));
        return .okData(v);
    }
    return .okData(revo.Data.new.core(.done));
}

inline fn isTruthy(data: Data) bool {
    return !revo.isFalse(data);
}

const std = @import("std");

const revo = @import("../root.zig");
const Data = revo.Data;
const VM = revo.VM;
const api = @import("api.zig");
const root = @import("root.zig");
const NativeResult = root.NativeResult;
const dataToString = root.dataToString;
const testing = revo.lang.testing;

test "iter functions" {
    try testing.top_string(
        \\ map("abc", fn(c) "x")
    , "xxx");

    try testing.top_string(
        \\ map("", fn(c) "x")
    , "");

    try testing.top_number(
        \\ map((10, 20), fn(x) x * 2)[0] + map((10, 20), fn(x) x * 2)[1]
    , 60);

    try testing.top_number(
        \\ map({a = 1, b = 2}, fn(v) v + 10).a
    , 11);

    try testing.top_number(
        \\ reduce((1, 2, 3, 4), fn(acc, x) acc + x, 0)
    , 10);

    try testing.top_number(
        \\ reduce("abc", fn(acc, c) acc + 1, 0)
    , 3);

    try testing.top_number(
        \\ reduce("", fn(acc, c) acc + 1, 42)
    , 42);

    try testing.top_atom(
        \\ each((1, 2, 3), fn(x) x)
    , "ok");

    try testing.top_atom(
        \\ each("", fn(c) c)
    , "ok");

    try testing.top_number(
        \\ const it = filter((1, 2, 3, 4, 5), fn(x) x > 3)
        \\ it() + it()
    , 9);

    try testing.top_number(
        \\ find((1, 2, 3, 4), fn(x) x > 2)
    , 3);

    try testing.top_atom(
        \\ find((1, 2), fn(x) x > 10)
    , "missing");

    try testing.top_true(
        \\ all?((1, 2, 3), fn(x) x > 0)
    );

    try testing.top_false(
        \\ all?((1, 2, 0), fn(x) x > 0)
    );

    try testing.top_false(
        \\ any?((1, 2), fn(x) x > 10)
    );

    try testing.top_true(
        \\ any?((0, 0, 3), fn(x) x > 2)
    );

    try testing.top_true(
        \\ all?("", fn(x) 0)
    );

    try testing.top_false(
        \\ any?("", fn(x) 0)
    );
}
