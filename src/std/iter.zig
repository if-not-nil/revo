const std = @import("std");
const revo = @import("../root.zig");
const root = @import("root.zig");
const testing = revo.lang.testing;

const Data = revo.Data;
const VM = revo.VM;
const NativeResult = root.NativeResult;
const dataToString = root.dataToString;

pub fn register(vm: *VM) !void {
    // as globals
    try root.registerFunctions(vm, &[_]root.FuncDef{
        .{ .name = "map", .f = root.define(&.{ .any, .function }, map_fn) },
        .{ .name = "filter", .f = root.define(&.{ .any, .function }, filter_fn) },
        .{ .name = "reduce", .f = root.define(&.{ .any, .function, .any }, reduce_fn) },
        .{ .name = "each", .f = root.define(&.{ .any, .function }, each_fn) },
        .{ .name = "find", .f = root.define(&.{ .any, .function }, find_fn) },
        .{ .name = "all", .f = root.define(&.{ .any, .function }, all_fn) },
        .{ .name = "any", .f = root.define(&.{ .any, .function }, any_fn) },
    });
    // tuple mt is registered by tuple.zig and it includes iteer methods
}

/// > map(collection: string|tuple|table, fn: function) -> string|tuple|table
/// transforms each element by applying function
///     map("hello", fn(c) = c:upper())
///     map((1,2,3), fn(x) = x * 2)
///     map({a=1, b=2}, fn(v) = v + 10)
pub fn map_fn(args: []const Data, vm: *VM) !NativeResult {
    if (args.len < 2) return .errArity(args.len, 2);

    const fn_data = args[1];
    if (fn_data != .function) return .errType(1, "function", dataToString(fn_data));

    switch (args[0]) {
        .string => {
            const str = vm.stringValue(args[0].string);
            var buf = try std.ArrayList(u8).initCapacity(vm.runtime.alloc, str.len);
            errdefer buf.deinit(vm.runtime.alloc);

            for (str) |byte| {
                const char_str = try vm.ownDataString(&[_]u8{byte});
                const fn_result = vm.callFunction(fn_data, &[_]Data{char_str}) catch |err| {
                    return err;
                };

                const mapped_byte = switch (fn_result) {
                    .string => |s| vm.stringValue(s)[0],
                    .number => |n| @as(u8, @intFromFloat(std.math.clamp(@round(n), 0, 255))),
                    else => return .errType(0, "string or number", dataToString(fn_result)),
                };
                try buf.append(vm.runtime.alloc, mapped_byte);
            }

            const result_str = try vm.adoptDataString(try buf.toOwnedSlice(vm.runtime.alloc));
            return .{ .ok = result_str };
        },
        .tuple => {
            const t_id = args[0].tuple;
            const tuple = try vm.tuples.get(t_id);
            var result_items = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, tuple.items.len);
            errdefer result_items.deinit(vm.runtime.alloc);

            for (tuple.items) |item| {
                const fn_result = vm.callFunction(fn_data, &[_]Data{item}) catch |err| {
                    return err;
                };
                try result_items.append(vm.runtime.alloc, fn_result);
            }

            const result_tuple = try vm.tuples.create(result_items.items);
            result_items.deinit(vm.runtime.alloc);
            return .okData(Data.new.tuple(result_tuple));
        },
        .table => {
            const table_id = args[0].table;
            const table = try vm.tables.get(table_id);
            const result_table_id = try vm.tables.create();
            const result_table = try vm.tables.get(result_table_id);

            for (table.array.items) |item| {
                const fn_result = vm.callFunction(fn_data, &[_]Data{item}) catch |err| {
                    return err;
                };
                try result_table.array.append(vm.runtime.alloc, fn_result);
            }

            for (table.hash_order.items) |key| {
                if (table.getRaw(key)) |val| {
                    const fn_result = vm.callFunction(fn_data, &[_]Data{val}) catch |err| {
                        return err;
                    };
                    try result_table.putRaw(key, fn_result);
                }
            }

            return .okData(Data.new.table(result_table_id));
        },
        else => return .errType(0, "string, tuple, or table", dataToString(args[0])),
    }
}

/// > filter(collection: string|tuple|table, fn: function) -> string|tuple|table
/// keeps only elements where function returns true
///     filter("hello", fn(c) = c != "l")
///     filter((1,2,3,4), fn(x) = x > 2)
///     filter({a=1, b=2}, fn(v) = v > 1)
pub fn filter_fn(args: []const Data, vm: *VM) !NativeResult {
    if (args.len < 2) return .errArity(args.len, 2);

    const fn_data = args[1];
    if (fn_data != .function) return .errType(1, "function", dataToString(fn_data));

    switch (args[0]) {
        .string => {
            const str = vm.stringValue(args[0].string);
            var buf = try std.ArrayList(u8).initCapacity(vm.runtime.alloc, str.len);
            errdefer buf.deinit(vm.runtime.alloc);

            for (str) |byte| {
                const char_str = try vm.ownDataString(&[_]u8{byte});
                const fn_result = vm.callFunction(fn_data, &[_]Data{char_str}) catch |err| {
                    return err;
                };
                if (isTruthy(fn_result)) {
                    try buf.append(vm.runtime.alloc, byte);
                }
            }

            const result_str = try vm.adoptDataString(try buf.toOwnedSlice(vm.runtime.alloc));
            return .{ .ok = result_str };
        },
        .tuple => {
            const t_id = args[0].tuple;
            const tuple = try vm.tuples.get(t_id);
            var result_items = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, tuple.items.len);
            errdefer result_items.deinit(vm.runtime.alloc);

            for (tuple.items) |item| {
                const fn_result = vm.callFunction(fn_data, &[_]Data{item}) catch |err| {
                    return err;
                };
                if (isTruthy(fn_result)) {
                    try result_items.append(vm.runtime.alloc, item);
                }
            }

            const result_tuple = try vm.tuples.create(result_items.items);
            result_items.deinit(vm.runtime.alloc);
            return .okData(Data.new.tuple(result_tuple));
        },
        .table => {
            const table_id = args[0].table;
            const table = try vm.tables.get(table_id);
            const result_table_id = try vm.tables.create();
            const result_table = try vm.tables.get(result_table_id);

            for (table.array.items) |item| {
                const fn_result = vm.callFunction(fn_data, &[_]Data{item}) catch |err| {
                    return err;
                };
                if (isTruthy(fn_result)) {
                    try result_table.array.append(vm.runtime.alloc, item);
                }
            }

            for (table.hash_order.items) |key| {
                if (table.getRaw(key)) |val| {
                    const fn_result = vm.callFunction(fn_data, &[_]Data{val}) catch |err| {
                        return err;
                    };
                    if (isTruthy(fn_result)) {
                        try result_table.putRaw(key, val);
                    }
                }
            }

            return .okData(Data.new.table(result_table_id));
        },
        else => return .errType(0, "string, tuple, or table", dataToString(args[0])),
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
    if (fn_data != .function) return .errType(1, "function", dataToString(fn_data));

    var accumulator = args[2];

    switch (args[0]) {
        .string => {
            const str = vm.stringValue(args[0].string);
            for (str) |byte| {
                const char_str = try vm.ownDataString(&[_]u8{byte});
                accumulator = vm.callFunction(fn_data, &[_]Data{ accumulator, char_str }) catch |err| {
                    return err;
                };
            }
        },
        .tuple => {
            const t_id = args[0].tuple;
            const tuple = try vm.tuples.get(t_id);
            for (tuple.items) |item| {
                accumulator = vm.callFunction(fn_data, &[_]Data{ accumulator, item }) catch |err| {
                    return err;
                };
            }
        },
        .table => {
            const table_id = args[0].table;
            const table = try vm.tables.get(table_id);

            for (table.array.items) |item| {
                accumulator = vm.callFunction(fn_data, &[_]Data{ accumulator, item }) catch |err| {
                    return err;
                };
            }

            for (table.hash_order.items) |key| {
                if (table.getRaw(key)) |val| {
                    accumulator = vm.callFunction(fn_data, &[_]Data{ accumulator, val }) catch |err| {
                        return err;
                    };
                }
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
    if (fn_data != .function) return .errType(1, "function", dataToString(fn_data));

    switch (args[0]) {
        .string => {
            const str = vm.stringValue(args[0].string);
            for (str) |byte| {
                const char_str = try vm.ownDataString(&[_]u8{byte});
                _ = vm.callFunction(fn_data, &[_]Data{char_str}) catch |err| {
                    return err;
                };
            }
        },
        .tuple => {
            const t_id = args[0].tuple;
            const tuple = try vm.tuples.get(t_id);
            for (tuple.items) |item| {
                _ = vm.callFunction(fn_data, &[_]Data{item}) catch |err| {
                    return err;
                };
            }
        },
        .table => {
            const table_id = args[0].table;
            const table = try vm.tables.get(table_id);

            for (table.array.items) |item| {
                _ = vm.callFunction(fn_data, &[_]Data{item}) catch |err| {
                    return err;
                };
            }

            for (table.hash_order.items) |key| {
                if (table.getRaw(key)) |val| {
                    _ = vm.callFunction(fn_data, &[_]Data{val}) catch |err| {
                        return err;
                    };
                }
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
    if (fn_data != .function) return .errType(1, "function", dataToString(fn_data));

    switch (args[0]) {
        .string => {
            const str = vm.stringValue(args[0].string);
            for (str) |byte| {
                const char_str = try vm.ownDataString(&[_]u8{byte});
                const fn_result = vm.callFunction(fn_data, &[_]Data{char_str}) catch |err| {
                    return err;
                };
                if (isTruthy(fn_result)) {
                    return .{ .ok = char_str };
                }
            }
        },
        .tuple => {
            const t_id = args[0].tuple;
            const tuple = try vm.tuples.get(t_id);
            for (tuple.items) |item| {
                const fn_result = vm.callFunction(fn_data, &[_]Data{item}) catch |err| {
                    return err;
                };
                if (isTruthy(fn_result)) {
                    return .{ .ok = item };
                }
            }
        },
        .table => {
            const table_id = args[0].table;
            const table = try vm.tables.get(table_id);

            for (table.array.items) |item| {
                const fn_result = vm.callFunction(fn_data, &[_]Data{item}) catch |err| {
                    return err;
                };
                if (isTruthy(fn_result)) {
                    return .{ .ok = item };
                }
            }

            for (table.hash_order.items) |key| {
                if (table.getRaw(key)) |val| {
                    const fn_result = vm.callFunction(fn_data, &[_]Data{val}) catch |err| {
                        return err;
                    };
                    if (isTruthy(fn_result)) {
                        return .{ .ok = val };
                    }
                }
            }
        },
        else => return .errType(0, "string, tuple, or table", dataToString(args[0])),
    }

    return .{ .ok = revo.core_atoms.data(.missing) };
}

/// > all(collection: string|tuple|table, fn: function) -> boolean
/// returns true if function returns true for all elements
///     all((1,2,3), fn(x) = x > 0)
///     all("hello", fn(c) = c != " ")
///     all({a=1, b=2}, fn(v) = v > 0)
pub fn all_fn(args: []const Data, vm: *VM) !NativeResult {
    if (args.len < 2) return .errArity(args.len, 2);

    const fn_data = args[1];
    if (fn_data != .function) return .errType(1, "function", dataToString(fn_data));

    switch (args[0]) {
        .string => {
            const str = vm.stringValue(args[0].string);
            for (str) |byte| {
                const char_str = try vm.ownDataString(&[_]u8{byte});
                const fn_result = vm.callFunction(fn_data, &[_]Data{char_str}) catch |err| {
                    return err;
                };
                if (!isTruthy(fn_result)) {
                    return .{ .ok = Data.new.boolean(false) };
                }
            }
        },
        .tuple => {
            const t_id = args[0].tuple;
            const tuple = try vm.tuples.get(t_id);
            for (tuple.items) |item| {
                const fn_result = vm.callFunction(fn_data, &[_]Data{item}) catch |err| {
                    return err;
                };
                if (!isTruthy(fn_result)) {
                    return .{ .ok = Data.new.boolean(false) };
                }
            }
        },
        .table => {
            const table_id = args[0].table;
            const table = try vm.tables.get(table_id);

            for (table.array.items) |item| {
                const fn_result = vm.callFunction(fn_data, &[_]Data{item}) catch |err| {
                    return err;
                };
                if (!isTruthy(fn_result)) {
                    return .{ .ok = Data.new.boolean(false) };
                }
            }

            for (table.hash_order.items) |key| {
                if (table.getRaw(key)) |val| {
                    const fn_result = vm.callFunction(fn_data, &[_]Data{val}) catch |err| {
                        return err;
                    };
                    if (!isTruthy(fn_result)) {
                        return .{ .ok = Data.new.boolean(false) };
                    }
                }
            }
        },
        else => return .errType(0, "string, tuple, or table", dataToString(args[0])),
    }

    return .{ .ok = Data.new.boolean(true) };
}

/// > any(collection: string|tuple|table, fn: function) -> boolean
/// returns true if function returns true for any element
///     any((1,2,3), fn(x) = x > 2)
///     any("hello", fn(c) = c == "l")
///     any({a=1, b=2}, fn(v) = v > 1)
pub fn any_fn(args: []const Data, vm: *VM) !NativeResult {
    if (args.len < 2) return .errArity(args.len, 2);

    const fn_data = args[1];
    if (fn_data != .function) return .errType(1, "function", dataToString(fn_data));

    switch (args[0]) {
        .string => {
            const str = vm.stringValue(args[0].string);
            for (str) |byte| {
                const char_str = try vm.ownDataString(&[_]u8{byte});
                const fn_result = vm.callFunction(fn_data, &[_]Data{char_str}) catch |err| {
                    return err;
                };
                if (isTruthy(fn_result)) {
                    return .{ .ok = Data.new.boolean(true) };
                }
            }
        },
        .tuple => {
            const t_id = args[0].tuple;
            const tuple = try vm.tuples.get(t_id);
            for (tuple.items) |item| {
                const fn_result = vm.callFunction(fn_data, &[_]Data{item}) catch |err| {
                    return err;
                };
                if (isTruthy(fn_result)) {
                    return .{ .ok = Data.new.boolean(true) };
                }
            }
        },
        .table => {
            const table_id = args[0].table;
            const table = try vm.tables.get(table_id);

            for (table.array.items) |item| {
                const fn_result = vm.callFunction(fn_data, &[_]Data{item}) catch |err| {
                    return err;
                };
                if (isTruthy(fn_result)) {
                    return .{ .ok = Data.new.boolean(true) };
                }
            }

            for (table.hash_order.items) |key| {
                if (table.getRaw(key)) |val| {
                    const fn_result = vm.callFunction(fn_data, &[_]Data{val}) catch |err| {
                        return err;
                    };
                    if (isTruthy(fn_result)) {
                        return .{ .ok = Data.new.boolean(true) };
                    }
                }
            }
        },
        else => return .errType(0, "string, tuple, or table", dataToString(args[0])),
    }

    return .{ .ok = Data.new.boolean(false) };
}

/// TODO: maybe dont do that
inline fn isTruthy(data: Data) bool {
    return !revo.isFalse(data);
}
