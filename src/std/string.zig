const std = @import("std");
const revo = @import("../root.zig");
const root = @import("root.zig");
const testing = revo.lang.testing;

const Data = revo.Data;
const VM = revo.VM;
const NativeResult = root.NativeResult;

pub fn register(vm: *VM) !void {
    const iter = @import("iter.zig");

    try root.registerMetatable(vm, &[_]root.MethodDef{
        .{ .key = .{ .named = "len" }, .func = root.define(&.{.string}, len_f) },
        .{ .key = .{ .named = "upper" }, .func = root.define(&.{.string}, upper_f) },
        .{ .key = .{ .named = "lower" }, .func = root.define(&.{.string}, lower_f) },
        .{ .key = .{ .named = "sub" }, .func = root.define(&.{ .string, .number, .number }, sub_f) },
        .{ .key = .{ .named = "find" }, .func = root.define(&.{ .string, .string }, find_f) },
        .{ .key = .{ .named = "replace" }, .func = root.define(&.{ .string, .string, .string }, replace_f) },
        .{ .key = .{ .named = "split" }, .func = root.define(&.{ .string, .string }, split_f) },
        .{ .key = .{ .named = "trim" }, .func = root.define(&.{.string}, trim_f) },
        .{ .key = .{ .named = "starts_with" }, .func = root.define(&.{ .string, .string }, starts_with_f) },
        .{ .key = .{ .named = "ends_with" }, .func = root.define(&.{ .string, .string }, ends_with_f) },
        .{ .key = .{ .named = "reverse" }, .func = root.define(&.{.string}, reverse_f) },
        .{ .key = .{ .named = "with" }, .func = root.define(&.{ .string, .number, .string }, set) },
        .{ .key = .{ .named = "table" }, .func = root.define(&.{.string}, to_table) },
        .{ .key = .{ .named = "ascii" }, .func = root.define(&.{.string}, ascii_f) },
        .{ .key = .{ .named = "contains" }, .func = root.define(&.{ .string, .string }, contains) },
        .{ .key = .{ .named = "index_of" }, .func = root.define(&.{ .string, .string }, index_of) },
        .{ .key = .{ .core = .__index }, .func = root.define(&.{ .string, .number }, index_f) },
        .{ .key = .{ .core = .__add }, .func = root.define(&.{ .string, .string }, add_f) },
        .{ .key = .{ .core = .__mul }, .func = root.define(&.{ .string, .number }, mul_f) },
        .{ .key = .{ .core = .__tostring }, .func = root.define(&.{.string}, tostring_f) },
        // those should work on string
        .{ .key = .{ .named = "map" }, .func = root.define(&.{ .any, .function }, iter.map_fn) },
        .{ .key = .{ .named = "filter" }, .func = root.define(&.{ .any, .function }, iter.filter_fn) },
        .{ .key = .{ .named = "reduce" }, .func = root.define(&.{ .any, .function, .any }, iter.reduce_fn) },
        .{ .key = .{ .named = "each" }, .func = root.define(&.{ .any, .function }, iter.each_fn) },
        .{ .key = .{ .named = "find" }, .func = root.define(&.{ .any, .function }, iter.find_fn) },
        .{ .key = .{ .named = "all" }, .func = root.define(&.{ .any, .function }, iter.all_fn) },
        .{ .key = .{ .named = "any" }, .func = root.define(&.{ .any, .function }, iter.any_fn) },
    }, try vm.ownDataString(""));

    try root.registerFunctions(vm, &[_]root.FuncDef{
        .{ .name = "string_of", .f = root.define(&.{.any}, string_of) },
        .{ .name = "string_join", .f = root.define(&.{ .table, .string }, join) },
    });
}

//
// method
//

/// > string:with(idx: number, char: string|number) -> string
/// replaces character at index with given char or byte
/// index is 0-based
fn set(args: []const Data, vm: *VM) !NativeResult {
    const str_handle = args[0].string;

    const idx: usize = switch (args[1]) {
        .number => |n| try revo.asIndex(n),
        else => return .errType(1, "number", @tagName(args[1])),
    };

    const existing_str = vm.stringValue(str_handle);
    if (idx >= existing_str.len) return .{ .ok = revo.core_atoms.data(.missing) };

    const char: u8 = blk: switch (args[2]) {
        .string => |s| {
            const s_val = vm.stringValue(s);
            if (s_val.len == 0) return .errType(2, "non-empty string", @tagName(args[2]));
            break :blk s_val[0];
        },
        .number => |val| {
            if (!std.math.isFinite(val)) return .errType(2, "string or byte", @tagName(args[2]));
            break :blk @intFromFloat(std.math.clamp(@round(val), 0, 255));
        },
        else => return .errType(2, "string or byte", @tagName(args[2])),
    };

    var new_buf = try vm.runtime.alloc.dupe(u8, existing_str);
    errdefer vm.runtime.alloc.free(new_buf);

    new_buf[idx] = char;

    const result = try vm.adoptDataString(new_buf);
    return .{ .ok = result };
}

/// > string:len() -> number
/// returns length of string
fn len_f(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].string);
    return .{ .ok = Data.new.num(str.len) };
}

/// > string[idx: number] -> string
/// returns character at index as single-char string
fn index_f(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].string);
    const idx = switch (args[1]) {
        .number => |n| revo.asIndex(n) catch return .{ .ok = revo.core_atoms.data(.missing) },
        else => return .errType(1, "number", @tagName(args[1])),
    };
    if (idx >= str.len) return .{ .ok = revo.core_atoms.data(.missing) };
    const result = try vm.ownDataString(str[idx .. idx + 1]);
    return .{ .ok = result };
}

/// > string + other: string -> string
/// concatenates two strings
fn add_f(args: []const Data, vm: *VM) !NativeResult {
    const left = vm.stringValue(args[0].string);
    const right = vm.stringValue(args[1].string);
    const concatenated = try std.mem.concat(vm.runtime.alloc, u8, &[_][]const u8{ left, right });
    const result = try vm.adoptDataString(concatenated);
    return .{ .ok = result };
}

/// > string:upper() -> string
/// converts string to uppercase
fn upper_f(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].string);

    var buf = try std.ArrayList(u8).initCapacity(vm.runtime.alloc, str.len);
    defer buf.deinit(vm.runtime.alloc);

    for (str) |c| {
        try buf.append(vm.runtime.alloc, std.ascii.toUpper(c));
    }

    const upper_slice = try buf.toOwnedSlice(vm.runtime.alloc);
    const result = try vm.adoptDataString(upper_slice);
    return .{ .ok = result };
}

/// > string:lower() -> string
/// converts string to lowercase
fn lower_f(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].string);

    var buf = try std.ArrayList(u8).initCapacity(vm.runtime.alloc, str.len);
    defer buf.deinit(vm.runtime.alloc);

    for (str) |c| {
        try buf.append(vm.runtime.alloc, std.ascii.toLower(c));
    }

    const lower_slice = try buf.toOwnedSlice(vm.runtime.alloc);
    const result = try vm.adoptDataString(lower_slice);
    return .{ .ok = result };
}

/// > string * n: number -> string
/// repeats string n times
fn mul_f(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].string);
    const times = switch (args[1]) {
        .number => |n| @as(i64, @intFromFloat(n)),
        else => return .errType(1, "number", @tagName(args[1])),
    };
    if (times < 0) return .errType(1, "positive number", @tagName(args[1]));

    var result = try std.ArrayList(u8).initCapacity(vm.runtime.alloc, str.len * @as(usize, @intCast(times)));
    defer result.deinit(vm.runtime.alloc);
    for (0..@as(usize, @intCast(times))) |_| {
        try result.appendSlice(vm.runtime.alloc, str);
    }
    const mul_slice = try result.toOwnedSlice(vm.runtime.alloc);
    const result_str = try vm.adoptDataString(mul_slice);
    return .{ .ok = result_str };
}

/// > string:tostring() -> string
/// returns string as-is (identity for tostring)
fn tostring_f(args: []const Data, _: *VM) !NativeResult {
    return .{ .ok = args[0] };
}

/// > string:sub(start: number, length: number) -> string
/// extracts substring from start with given length
fn sub_f(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].string);
    const start = switch (args[1]) {
        .number => |n| @as(i64, @intFromFloat(n)),
        else => return .errType(1, "number", @tagName(args[1])),
    };
    const length = switch (args[2]) {
        .number => |n| @as(i64, @intFromFloat(n)),
        else => return .errType(2, "number", @tagName(args[2])),
    };

    if (start < 0 or length < 0 or start >= str.len) {
        const empty = try vm.ownDataString("");
        return .{ .ok = empty };
    }

    const end = @min(@as(usize, @intCast(start + length)), str.len);
    const start_usize = @as(usize, @intCast(start));
    const result = try vm.ownDataString(str[start_usize..end]);
    return .{ .ok = result };
}

/// > string:find(needle: string) -> number|atom
/// finds first occurrence of needle in string
/// returns index or :missing if not found
fn find_f(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].string);
    const needle = vm.stringValue(args[1].string);

    if (std.mem.indexOf(u8, str, needle)) |pos| {
        return .{ .ok = Data.new.num(pos) };
    }
    return .{ .ok = revo.core_atoms.data(.missing) };
}

/// > string:replace(old: string, new: string) -> string
/// replaces all occurrences of old with new
fn replace_f(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].string);
    const old = vm.stringValue(args[1].string);
    const new = vm.stringValue(args[2].string);

    const res = try std.mem.replaceOwned(u8, vm.runtime.alloc, str, old, new);

    const result = try vm.adoptDataString(res);
    return .{ .ok = result };
}

/// > string:split(delim: string) -> table
/// splits string by delimiter into table
fn split_f(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].string);
    const delim = vm.stringValue(args[1].string);

    var parts = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, 10);
    defer parts.deinit(vm.runtime.alloc);

    var pos: usize = 0;
    while (std.mem.indexOf(u8, str[pos..], delim)) |idx| {
        const abs_idx = pos + idx;
        const part = try vm.ownDataString(str[pos..abs_idx]);
        try parts.append(vm.runtime.alloc, part);
        pos = abs_idx + delim.len;
    }
    const final_part = try vm.ownDataString(str[pos..]);
    try parts.append(vm.runtime.alloc, final_part);

    const table_id = try vm.tables.create();
    const table = try vm.tables.get(table_id);
    for (parts.items, 0..) |part, idx| {
        try table.putRaw(Data.new.num(idx), part);
    }

    return .{ .ok = .{ .table = table_id } };
}

/// > string:trim() -> string
/// trims whitespace from both ends
fn trim_f(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].string);
    const trimmed = std.mem.trim(u8, str, " \t\r\n");
    return .{ .ok = try vm.ownDataString(trimmed) };
}

/// > string:starts_with(prefix: string) -> bool
/// checks if string starts with prefix
fn starts_with_f(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].string);
    const prefix = vm.stringValue(args[1].string);
    return .{ .ok = root.boolData(std.mem.startsWith(u8, str, prefix)) };
}

/// > string:ends_with(suffix: string) -> bool
/// checks if string ends with suffix
fn ends_with_f(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].string);
    const suffix = vm.stringValue(args[1].string);
    return .{ .ok = root.boolData(std.mem.endsWith(u8, str, suffix)) };
}

/// > string:reverse() -> string
/// reverses the string
fn reverse_f(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].string);
    const duped = try vm.runtime.alloc.dupe(u8, str);
    std.mem.reverse(u8, duped);
    const result = try vm.adoptDataString(duped);
    return .{ .ok = result };
}

/// > string:table() -> table
/// converts string to table of characters
/// "asdf":table() => {"a", "s", "d", "f"}
fn to_table(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].string);
    const table_id = try vm.tables.create();
    const table = try vm.tables.get(table_id);
    for (str) |byte| {
        const char_str = try vm.adoptDataString(try vm.runtime.alloc.dupe(u8, &[_]u8{byte}));
        try table.array.append(vm.runtime.alloc, char_str);
    }
    return .{ .ok = Data.new.table(table_id) };
}

/// > string:ascii() -> number
/// returns ASCII code of first character
/// "a":ascii() => 97
fn ascii_f(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].string);
    if (str.len == 0) {
        return .errType(0, "non-empty string", "empty string");
    }
    return .{ .ok = Data.new.num(str[0]) };
}

/// > string_of(code: number | tuple) -> string
/// creates string from ASCII code(s)
/// string_of(97) => "a"
/// string_of({97, 98}) => "ab"
fn string_of(args: []const Data, vm: *VM) !NativeResult {
    switch (args[0]) {
        .number => |n| {
            const code = @as(u32, @intFromFloat(n));
            if (code > 127) {
                return .other("ASCII code out of range");
            }
            const char = try vm.runtime.alloc.dupe(u8, &[_]u8{@as(u8, @truncate(code))});
            return .{ .ok = try vm.adoptDataString(char) };
        },
        .tuple => |tuple_id| {
            const tuple = try vm.tuples.get(tuple_id);
            var buf = try std.ArrayList(u8).initCapacity(vm.runtime.alloc, tuple.len());
            defer buf.deinit(vm.runtime.alloc);
            for (tuple.items) |val| {
                switch (val) {
                    .number => |n| {
                        const code = @as(u32, @intFromFloat(n));
                        if (code > 127) {
                            return .other("ASCII code out of range");
                        }
                        try buf.append(vm.runtime.alloc, @as(u8, @truncate(code)));
                    },
                    else => {
                        return .errType(0, "number", @tagName(val));
                    },
                }
            }
            const owned = try buf.toOwnedSlice(vm.runtime.alloc);
            return .{ .ok = try vm.adoptDataString(owned) };
        },
        else => return .errType(0, "number or tuple", @tagName(args[0])),
    }
}

test "string metatable" {
    try testing.top_string("\"hello\":sub(0, 2)", "he");

    try testing.top_number("len(\"asdf\")", 4);
    try testing.top_number("\"asdf\":len()", 4);
    try testing.top_string("\"asdf\":with(1, \"y\")", "aydf");
    try testing.top_string("tostring(\"asdf\")", "asdf");
    try testing.top_string("\"asdf\"[2]", "d");
    try testing.top_string("\"asdf\" + \"qwer\"", "asdfqwer");
    try testing.top_string("\"ab\" * 3", "ababab");
}

/// > string:contains(substr: string) -> bool
/// checks if string contains substring
fn contains(args: []const Data, vm: *VM) !NativeResult {
    const str_id = args[0].string;
    const search_id = args[1].string;

    const str = vm.stringValue(str_id);
    const search = vm.stringValue(search_id);

    return .okBool(std.mem.indexOf(u8, str, search) != null);
}

/// > string:index_of(substr: string) -> number | nil
/// ret 0-based index of substring or nil
fn index_of(args: []const Data, vm: *VM) !NativeResult {
    const str_id = args[0].string;
    const search_id = args[1].string;

    const str = vm.stringValue(str_id);
    const search = vm.stringValue(search_id);

    if (std.mem.indexOf(u8, str, search)) |idx| {
        return .{ .ok = Data.new.num(idx) };
    }
    return .{ .ok = revo.core_atoms.data(.nil) };
}

/// > string.join(table: table, sep: string) -> string
/// joins table elements into string with separator
fn join(args: []const Data, vm: *VM) !NativeResult {
    const tbl_id = args[0].table;
    const sep_id = args[1].string;

    const tbl = try vm.tables.get(tbl_id);
    const sep = vm.stringValue(sep_id);

    var buf = try std.ArrayList(u8).initCapacity(vm.runtime.alloc, 64);
    defer buf.deinit(vm.runtime.alloc);

    for (tbl.array.items, 0..) |item, i| {
        const item_str = switch (item) {
            .string => |sid| vm.stringValue(sid),
            .number => |n| try std.fmt.allocPrint(vm.runtime.alloc, "{}", .{n}),
            else => "?",
        };
        try buf.appendSlice(vm.runtime.alloc, item_str);
        if (i < tbl.array.items.len - 1 and tbl.array.items.len >= i) {
            try buf.appendSlice(vm.runtime.alloc, sep);
        }
    }

    const owned = try buf.toOwnedSlice(vm.runtime.alloc);
    return .{ .ok = try vm.adoptDataString(owned) };
}

test "string methods" {
    try testing.top_true("\"hello\":contains(\"ell\")");
    try testing.top_false("\"hello\":contains(\"xyz\")");
    try testing.top_number("\"hello\":index_of(\"ll\")", 2);
    try testing.top_string("string_of(97)", "a");
    try testing.top_string("string_of((72, 105))", "Hi");
}
