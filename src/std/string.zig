//
// the table
//
// one spec per registration entry. registration happens in root.zig
// via api.registerAll
// // // // //

pub const specs: []const api.FnSpec = &.{
    .{
        .name = "len",
        .placements = &.{ api.mod("string"), api.method("string", .string) },
        .params = &.{
            .{ "self", "string" },
        },
        .ret = "number",
        .doc = "returns length of string",
        .f = root.define(&.{.string}, len_f),
    },
    .{
        .name = "upper",
        .placements = &.{ api.mod("string"), api.method("string", .string) },
        .params = &.{
            .{ "self", "string" },
        },
        .ret = "string",
        .doc = "converts string to uppercase",
        .f = root.define(&.{.string}, upper_f),
    },
    .{
        .name = "lower",
        .placements = &.{ api.mod("string"), api.method("string", .string) },
        .params = &.{
            .{ "self", "string" },
        },
        .ret = "string",
        .doc = "converts string to lowercase",
        .f = root.define(&.{.string}, lower_f),
    },
    .{
        .name = "sub",
        .placements = &.{ api.mod("string"), api.method("string", .string) },
        .params = &.{
            .{ "self", "string" },
            .{ "start", "number" },
            .{ "length", "number" },
        },
        .ret = "string",
        .doc = "extracts substring from start with given length",
        .f = root.define(&.{ .string, .number, .number }, sub_f),
    },
    .{
        .name = "find",
        .placements = &.{ api.mod("string"), api.method("string", .string) },
        .params = &.{
            .{ "self", "string" },
            .{ "needle", "string" },
        },
        .ret = "number|atom",
        .doc =
        \\finds first occurrence of needle in string
        \\returns index or :missing if not found
        ,
        .f = root.define(&.{ .string, .string }, find_f),
    },
    .{
        .name = "replace",
        .placements = &.{ api.mod("string"), api.method("string", .string) },
        .params = &.{
            .{ "self", "string" },
            .{ "old", "string" },
            .{ "new", "string" },
        },
        .ret = "string",
        .doc = "replaces all occurrences of old with new",
        .f = root.define(&.{ .string, .string, .string }, replace_f),
    },
    .{
        .name = "split",
        .placements = &.{ api.mod("string"), api.method("string", .string) },
        .params = &.{
            .{ "self", "string" },
            .{ "delim", "string" },
        },
        .ret = "table",
        .doc = "splits string by delimiter into table",
        .f = root.define(&.{ .string, .string }, split_f),
    },
    .{
        .name = "trim",
        .placements = &.{ api.mod("string"), api.method("string", .string) },
        .params = &.{
            .{ "self", "string" },
        },
        .ret = "string",
        .doc = "trims whitespace from both ends",
        .f = root.define(&.{.string}, trim_f),
    },
    .{
        .name = "starts_with?",
        .placements = &.{ api.mod("string"), api.method("string", .string) },
        .params = &.{
            .{ "self", "string" },
            .{ "prefix", "string" },
        },
        .ret = "bool",
        .doc = "checks if string starts with prefix",
        .f = root.define(&.{ .string, .string }, starts_with_f),
    },
    .{
        .name = "ends_with?",
        .placements = &.{ api.mod("string"), api.method("string", .string) },
        .params = &.{
            .{ "self", "string" },
            .{ "suffix", "string" },
        },
        .ret = "bool",
        .doc = "checks if string ends with suffix",
        .f = root.define(&.{ .string, .string }, ends_with_f),
    },
    .{
        .name = "reverse",
        .placements = &.{ api.mod("string"), api.method("string", .string) },
        .params = &.{
            .{ "self", "string" },
        },
        .ret = "string",
        .doc = "reverses the string",
        .f = root.define(&.{.string}, reverse_f),
    },
    .{
        .name = "with",
        .placements = &.{ api.mod("string"), api.method("string", .string) },
        .params = &.{
            .{ "self", "string" },
            .{ "idx", "number" },
            .{ "char", "string|number" },
        },
        .ret = "string",
        .doc =
        \\replaces character at index with given char or byte
        \\index is 0-based
        ,
        .f = root.define(&.{ .string, .number, .string }, set),
    },
    .{
        .name = "table",
        .placements = &.{ api.mod("string"), api.method("string", .string) },
        .params = &.{
            .{ "self", "string" },
        },
        .ret = "table",
        .doc =
        \\converts string to table of characters
        \\"asdf":table() => {"a", "s", "d", "f"}
        ,
        .f = root.define(&.{.string}, to_table),
    },
    .{
        .name = "ascii",
        .placements = &.{ api.mod("string"), api.method("string", .string) },
        .params = &.{
            .{ "self", "string" },
        },
        .ret = "number",
        .doc =
        \\returns ASCII code of first character
        \\"a":ascii() => 97
        ,
        .f = root.define(&.{.string}, ascii_f),
    },
    .{
        .name = "contains?",
        .placements = &.{ api.mod("string"), api.method("string", .string) },
        .params = &.{
            .{ "self", "string" },
            .{ "substr", "string" },
        },
        .ret = "bool",
        .doc = "checks if string contains substring",
        .f = root.define(&.{ .string, .string }, contains),
    },
    .{
        .name = "index_of",
        .placements = &.{ api.mod("string"), api.method("string", .string) },
        .params = &.{
            .{ "self", "string" },
            .{ "substr", "string" },
        },
        .ret = "number|:nil",
        .doc = "ret 0-based index of substring or nil",
        .f = root.define(&.{ .string, .string }, index_of),
    },
    .{
        .name = "__index",
        .placements = &.{api.method("string", .string)},
        .params = &.{
            .{ "self", "string" },
            .{ "idx", "number" },
        },
        .ret = "string",
        .doc = "returns character at index as single-char string",
        .f = root.define(&.{ .string, .number }, index_f),
        .core_key = revo.core_atoms.__index,
    },
    .{
        .name = "add",
        .placements = &.{api.method("string", .string)},
        .params = &.{
            .{ "self", "string" },
            .{ "other", "string" },
        },
        .ret = "string",
        .doc = "concatenates two strings",
        .f = root.define(&.{ .string, .string }, add_f),
    },
    .{
        .name = "mul",
        .placements = &.{api.method("string", .string)},
        .params = &.{
            .{ "self", "string" },
            .{ "n", "number" },
        },
        .ret = "string",
        .doc = "repeats string n times",
        .f = root.define(&.{ .string, .number }, mul_f),
    },
    // globals
    .{
        .name = "string_of",
        .placements = &.{api.g},
        .params = &.{
            .{ "code", "any" },
        },
        .ret = "string",
        .doc =
        \\creates string from ASCII code(s)
        \\string_of(97) => "a"
        \\string_of({97, 98}) => "ab"
        ,
        .f = root.define(&.{.any}, string_of),
    },
    .{
        .name = "string_join",
        .placements = &.{api.g},
        .params = &.{
            .{ "table", "table" },
            .{ "sep", "string" },
        },
        .ret = "string",
        .doc = "joins table elements into string with separator",
        .f = root.define(&.{ .table, .string }, join),
    },
    // module-only (not in the metatable)
    .{
        .name = "join",
        .placements = &.{api.mod("string")},
        .params = &.{
            .{ "table", "table" },
            .{ "sep", "string" },
        },
        .ret = "string",
        .doc = "joins table elements into string with separator",
        .f = root.define(&.{ .table, .string }, join),
    },
};

//
// registration
//
// method
//

/// > string:with(idx: number, char: string|number) -> string
/// replaces character at index with given char or byte
/// index is 0-based
fn set(args: []const Data, vm: *VM) !NativeResult {
    const str_handle = args[0].asString().?;

    const idx: usize = if (args[1].asNum()) |n| try revo.asIndex(n) else return .errType(1, "number", root.dataToString(args[1]));

    const existing_str = vm.stringValue(str_handle);
    if (idx >= existing_str.len) return .{ .ok = revo.Data.new.core(.missing) };

    const char: u8 = blk: {
        if (args[2].asString()) |s| {
            const s_val = vm.stringValue(s);
            if (s_val.len == 0) return .errType(2, "non-empty string", root.dataToString(args[2]));
            break :blk s_val[0];
        } else if (args[2].asNum()) |val| {
            if (!std.math.isFinite(val)) return .errType(2, "string or byte", root.dataToString(args[2]));
            break :blk @intFromFloat(std.math.clamp(@round(val), 0, 255));
        } else {
            return .errType(2, "string or byte", root.dataToString(args[2]));
        }
    };

    var new_buf = try vm.runtime.alloc.dupe(u8, existing_str);
    errdefer vm.runtime.alloc.free(new_buf);

    new_buf[idx] = char;

    const result = try vm.adoptDataStringNoDedup(new_buf);
    return .{ .ok = result };
}

/// > string:len() -> number
/// returns length of string
fn len_f(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].asString().?);
    return .{ .ok = Data.new.num(str.len) };
}

/// > string[idx: number] -> string
/// returns character at index as single-char string
fn index_f(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].asString().?);
    const idx = if (args[1].asNum()) |n| revo.asIndex(n) catch return .{ .ok = revo.Data.new.core(.missing) } else return .errType(1, "number", root.dataToString(args[1]));
    if (idx >= str.len) return .{ .ok = revo.Data.new.core(.missing) };
    const result = try vm.ownDataStringNoDedup(str[idx .. idx + 1]);
    return .{ .ok = result };
}

/// > string + other: string -> string
/// concatenates two strings
fn add_f(args: []const Data, vm: *VM) !NativeResult {
    const left = vm.stringValue(args[0].asString().?);
    const right = vm.stringValue(args[1].asString().?);
    const concatenated = try std.mem.concat(vm.runtime.alloc, u8, &.{ left, right });
    const result = try vm.adoptDataStringNoDedup(concatenated);
    return .{ .ok = result };
}

/// > string:upper() -> string
/// converts string to uppercase
fn upper_f(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].asString().?);
    const buf = try vm.runtime.alloc.dupe(u8, str);
    for (buf) |*c| c.* = std.ascii.toUpper(c.*);
    const result = try vm.adoptDataStringNoDedup(buf);
    return .{ .ok = result };
}

/// > string:lower() -> string
/// converts string to lowercase
fn lower_f(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].asString().?);
    const buf = try vm.runtime.alloc.dupe(u8, str);
    for (buf) |*c| c.* = std.ascii.toLower(c.*);
    const result = try vm.adoptDataStringNoDedup(buf);
    return .{ .ok = result };
}

/// > string * n: number -> string
/// repeats string n times
fn mul_f(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].asString().?);
    const times = if (args[1].asNum()) |n| @as(i64, @intFromFloat(n)) else return .errType(1, "number", root.dataToString(args[1]));
    if (times < 0) return .errType(1, "positive number", root.dataToString(args[1]));

    const count = @as(usize, @intCast(times));
    const buf = try vm.runtime.alloc.alloc(u8, str.len * count);
    for (0..count) |i| {
        @memcpy(buf[i * str.len ..][0..str.len], str);
    }
    const result_str = try vm.adoptDataStringNoDedup(buf);
    return .{ .ok = result_str };
}

/// > string:sub(start: number, length: number) -> string
/// extracts substring from start with given length
fn sub_f(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].asString().?);
    const start = if (args[1].asNum()) |n| @as(i64, @intFromFloat(n)) else return .errType(1, "number", root.dataToString(args[1]));
    const length = if (args[2].asNum()) |n| @as(i64, @intFromFloat(n)) else return .errType(2, "number", root.dataToString(args[2]));

    if (start < 0 or length < 0 or start >= str.len) {
        const empty = try vm.ownDataString("");
        return .{ .ok = empty };
    }

    const end = @min(@as(usize, @intCast(start + length)), str.len);
    const start_usize: usize = @intCast(start);
    const result = try vm.ownDataStringNoDedup(str[start_usize..end]);
    return .{ .ok = result };
}

/// > string:find(needle: string) -> number|atom
/// finds first occurrence of needle in string
/// returns index or :missing if not found
fn find_f(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].asString().?);
    const needle = vm.stringValue(args[1].asString().?);

    if (std.mem.find(u8, str, needle)) |pos| {
        return .{ .ok = Data.new.num(pos) };
    }
    return .{ .ok = revo.Data.new.core(.missing) };
}

/// > string:replace(old: string, new: string) -> string
/// replaces all occurrences of old with new
fn replace_f(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].asString().?);
    const old = vm.stringValue(args[1].asString().?);
    const new = vm.stringValue(args[2].asString().?);

    const res = try std.mem.replaceOwned(u8, vm.runtime.alloc, str, old, new);
    const result = try vm.adoptDataStringNoDedup(res);
    return .{ .ok = result };
}

/// > string:split(delim: string) -> table
/// splits string by delimiter into table
fn split_f(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].asString().?);
    const delim = vm.stringValue(args[1].asString().?);

    var parts = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, 10);
    defer parts.deinit(vm.runtime.alloc);

    var pos: usize = 0;
    while (std.mem.find(u8, str[pos..], delim)) |idx| {
        const abs_idx = pos + idx;
        const part = try vm.ownDataStringNoDedup(str[pos..abs_idx]);
        try parts.append(vm.runtime.alloc, part);
        pos = abs_idx + delim.len;
    }
    const final_part = try vm.ownDataStringNoDedup(str[pos..]);
    try parts.append(vm.runtime.alloc, final_part);

    const table_id = try vm.tables.create();
    const table = try vm.tables.get(table_id);
    for (parts.items, 0..) |part, idx| {
        try table.putRaw(Data.new.num(idx), part);
    }

    return .{ .ok = Data.new.table(table_id) };
}

/// > string:trim() -> string
/// trims whitespace from both ends
fn trim_f(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].asString().?);
    const trimmed = std.mem.trim(u8, str, " \t\r\n");
    return .{ .ok = try vm.ownDataStringNoDedup(trimmed) };
}

/// > string:starts_with?(prefix: string) -> bool
/// checks if string starts with prefix
fn starts_with_f(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].asString().?);
    const prefix = vm.stringValue(args[1].asString().?);
    return .{ .ok = root.boolData(std.mem.startsWith(u8, str, prefix)) };
}

/// > string:ends_with?(suffix: string) -> bool
/// checks if string ends with suffix
fn ends_with_f(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].asString().?);
    const suffix = vm.stringValue(args[1].asString().?);
    return .{ .ok = root.boolData(std.mem.endsWith(u8, str, suffix)) };
}

/// > string:reverse() -> string
/// reverses the string
fn reverse_f(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].asString().?);
    const duped = try vm.runtime.alloc.dupe(u8, str);
    std.mem.reverse(u8, duped);
    const result = try vm.adoptDataStringNoDedup(duped);
    return .{ .ok = result };
}

/// > string:table() -> table
/// converts string to table of characters
/// "asdf":table() => {"a", "s", "d", "f"}
fn to_table(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].asString().?);
    const table_id = try vm.tables.create();
    const table = try vm.tables.get(table_id);
    for (str) |byte| {
        const char_str = try vm.adoptDataStringNoDedup(try vm.runtime.alloc.dupe(u8, &[_]u8{byte}));
        try table.array.append(vm.runtime.alloc, char_str);
    }
    return .{ .ok = Data.new.table(table_id) };
}

/// > string:ascii() -> number
/// returns ASCII code of first character
/// "a":ascii() => 97
fn ascii_f(args: []const Data, vm: *VM) !NativeResult {
    const str = vm.stringValue(args[0].asString().?);
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
    if (args[0].asNum()) |n| {
        const code: u32 = @intFromFloat(n);
        if (code > 127) {
            return .other("ASCII code out of range");
        }
        const char = try vm.runtime.alloc.dupe(u8, &[_]u8{@as(u8, @truncate(code))});
        return .{ .ok = try vm.adoptDataStringNoDedup(char) };
    }
    if (args[0].asTuple()) |tuple_id| {
        const tuple = try vm.tuples.get(tuple_id);
        var buf = try std.ArrayList(u8).initCapacity(vm.runtime.alloc, tuple.len());
        defer buf.deinit(vm.runtime.alloc);
        for (tuple.items) |val| {
            if (val.asNum()) |n| {
                const code: u32 = @intFromFloat(n);
                if (code > 127) {
                    return .other("ASCII code out of range");
                }
                try buf.append(vm.runtime.alloc, @as(u8, @truncate(code)));
            } else {
                return .errType(0, "number", root.dataToString(val));
            }
        }
        const owned = try buf.toOwnedSlice(vm.runtime.alloc);
        return .{ .ok = try vm.adoptDataStringNoDedup(owned) };
    }
    return .errType(0, "number or tuple", root.dataToString(args[0]));
}

test "string metatable" {
    try testing.top_string("\"hello\":sub(0, 2)", "he");

    try testing.top_number("len(\"asdf\")", 4);
    try testing.top_number("\"asdf\":len()", 4);
    try testing.top_string("\"asdf\":with(1, \"y\")", "aydf");
    try testing.top_string("tostring(\"asdf\")", "asdf");
    try testing.top_string("\"asdf\"[2]", "d");
    try testing.top_string("\"asdf\" ~ \"qwer\"", "asdfqwer");
    try testing.top_string("\"ab\" * 3", "ababab");
}

/// > string:contains?(substr: string) -> bool
/// checks if string contains substring
fn contains(args: []const Data, vm: *VM) !NativeResult {
    const str_id = args[0].asString().?;
    const search_id = args[1].asString().?;

    const str = vm.stringValue(str_id);
    const search = vm.stringValue(search_id);

    return .okBool(std.mem.find(u8, str, search) != null);
}

/// > string:index_of(substr: string) -> number | nil
/// ret 0-based index of substring or nil
fn index_of(args: []const Data, vm: *VM) !NativeResult {
    const str_id = args[0].asString().?;
    const search_id = args[1].asString().?;

    const str = vm.stringValue(str_id);
    const search = vm.stringValue(search_id);

    if (std.mem.find(u8, str, search)) |idx| {
        return .{ .ok = Data.new.num(idx) };
    }
    return .{ .ok = revo.Data.new.core(.nil) };
}

/// > string.join(table: table, sep: string) -> string
/// joins table elements into string with separator
fn join(args: []const Data, vm: *VM) !NativeResult {
    const tbl_id = args[0].asTable().?;
    const sep_id = args[1].asString().?;

    const tbl = try vm.tables.get(tbl_id);
    const sep = vm.stringValue(sep_id);

    var buf = try std.ArrayList(u8).initCapacity(vm.runtime.alloc, 64);
    defer buf.deinit(vm.runtime.alloc);

    for (tbl.array.items, 0..) |item, i| {
        const item_str = if (item.asString()) |sid|
            vm.stringValue(sid)
        else if (item.asNum()) |n| blk: {
            var fmt_buf: [64]u8 = undefined;
            break :blk std.fmt.bufPrint(&fmt_buf, "{}", .{n}) catch "?";
        } else "?";
        try buf.appendSlice(vm.runtime.alloc, item_str);
        if (i < tbl.array.items.len - 1 and tbl.array.items.len >= i) {
            try buf.appendSlice(vm.runtime.alloc, sep);
        }
    }

    const owned = try buf.toOwnedSlice(vm.runtime.alloc);
    return .{ .ok = try vm.adoptDataStringNoDedup(owned) };
}

test "string methods" {
    try testing.top_true("\"hello\":contains?(\"ell\")");
    try testing.top_false("\"hello\":contains?(\"xyz\")");
    try testing.top_number("\"hello\":index_of(\"ll\")", 2);
    try testing.top_string("string_of(97)", "a");
    try testing.top_string("string_of((72, 105))", "Hi");
    try testing.top_string("'hello':upper()", "HELLO");
    try testing.expectCompileError("'hello':sub('x', 2)", .ParseError);
    try testing.expectCompileError("'hello':sub(2, 2, 3)", .ParseError);
    try testing.top_number("'hello':find('el')", 1);
    try testing.expectCompileError("'hello':find(42)", .ParseError);
    try testing.top_string("'hello':replace('l', 'x')", "hexxo");
    try testing.expectCompileError("'hello':replace(1, 'x')", .ParseError);
    try testing.top_string("'hello':add(' world')", "hello world");
    try testing.expectRuntimeFailureWithMessage(
        \\ "abc":with(1, "")
    , .TypeError, "arg 2: wants non-empty string, got string");
}

const std = @import("std");

const revo = @import("../root.zig");
const testing = revo.lang.testing;
const Data = revo.Data;
const VM = revo.VM;
const api = @import("api.zig");
const root = @import("root.zig");
const NativeResult = root.NativeResult;
