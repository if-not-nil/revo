const Ts = root.T;

pub const Impl = struct {
    pub fn encode(vm: *VM, data: Ts.any) !HostResult {
        var out = std.Io.Writer.Allocating.init(vm.runtime.alloc);
        defer out.deinit();
        try writeJsonValue(data, vm, &out.writer);
        const slice = try out.toOwnedSlice();
        const result = try vm.adoptDataString(slice);
        return HostResult.Ok(vm, result);
    }

    pub fn decode(vm: *VM, source: Ts.string) !HostResult {
        const str = vm.stringValue(@intFromEnum(source));
        var parsed = json.parseFromSlice(json.Value, vm.runtime.alloc, str, .{}) catch |err| {
            return HostResult.Err(vm, @errorName(err));
        };
        defer parsed.deinit();
        const value = try fromJsonValue(parsed.value, vm);
        return HostResult.Ok(vm, value);
    }
};

pub const impls = root.impls(Impl).val;

/// ret owned json string
pub fn encodeAlloc(data: Data, vm: *VM) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer out.deinit();
    try writeJsonValue(data, vm, &out.writer);
    return out.toOwnedSlice();
}

fn writeJsonValue(data: Data, vm: *VM, writer: *std.Io.Writer) anyerror!void {
    return switch (data.tag()) {
        .number => blk: {
            const n = data.asNum().?;
            if (!std.math.isFinite(n)) return error.UnsupportedJsonValue;
            if (@trunc(n) == n and @abs(n) < 9.0e18) {
                break :blk try writer.print("{d}", .{@as(i64, @intFromFloat(n))});
            }
            break :blk try writer.print("{d}", .{n});
        },
        .string => try writeJsonString(writer, vm.stringValue(data.asString().?)),
        .atom => blk: {
            const id = data.asAtom().?;
            const atom = vm.stringValue(id);
            if (std.mem.eql(u8, atom, "nil")) break :blk try writer.writeAll("null");
            if (std.mem.eql(u8, atom, "true")) break :blk try writer.writeAll("true");
            if (std.mem.eql(u8, atom, "false")) break :blk try writer.writeAll("false");
            break :blk try writeJsonString(writer, atom);
        },
        .table => try writeTableJson(data.asTable().?, vm, writer),
        .function => return error.UnsupportedJsonValue,
        .foreign => return error.UnsupportedJsonValue,
    };
}

fn writeArrayJson(items: []const Data, vm: *VM, writer: *std.Io.Writer) anyerror!void {
    try writer.writeByte('[');
    for (items, 0..) |item, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writeJsonValue(item, vm, writer);
    }
    try writer.writeByte(']');
}

fn writeTableJson(id: revo.memory.TableID, vm: *VM, writer: *std.Io.Writer) anyerror!void {
    const table = try vm.tables.get(id);
    if (table.hash.count == 0) return writeArrayJson(table.array.items, vm, writer);

    // keyed entries encoded as a json object; integer slots become "0".."n-1"
    // keys so nothing is dropped
    try writer.writeByte('{');
    var first = true;
    for (table.array.items, 0..) |item, idx| {
        if (!first) try writer.writeByte(',');
        first = false;
        var buf: [20]u8 = undefined;
        const key_str = try std.fmt.bufPrint(&buf, "{d}", .{idx});
        try writeJsonString(writer, key_str);
        try writer.writeByte(':');
        try writeJsonValue(item, vm, writer);
    }

    const entries = try table.keyedEntries(vm.runtime.alloc);
    defer vm.runtime.alloc.free(entries);
    for (entries) |entry| {
        if (!first) try writer.writeByte(',');
        first = false;
        const key_str = switch (entry.key.tag()) {
            .atom => vm.stringValue(entry.key.asAtom().?),
            .string => vm.stringValue(entry.key.asString().?),
            else => return error.UnsupportedJsonValue,
        };
        try writeJsonString(writer, key_str);
        try writer.writeByte(':');
        try writeJsonValue(entry.value, vm, writer);
    }
    try writer.writeByte('}');
}

fn writeJsonString(writer: *std.Io.Writer, str: []const u8) anyerror!void {
    try writer.writeByte('"');
    for (str) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            else => if (c < 0x20)
                try writer.print("\\u{x:0>4}", .{c})
            else
                try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

fn fromJsonValue(value: json.Value, vm: *VM) anyerror!Data {
    return switch (value) {
        .null => revo.Data.new.core(.nil),
        .bool => |b| Data.new.boolean(b),
        .integer => |n| Data.new.num(n),
        .float => |n| Data.new.num(n),
        .number_string => |s| Data.new.num(try std.fmt.parseFloat(f64, s)),
        .string => |s| try vm.ownDataString(s),
        .array => |array| try arrayToData(array.items, vm),
        .object => |object| try objectToData(object, vm),
    };
}

fn arrayToData(items: []const json.Value, vm: *VM) anyerror!Data {
    // fromJsonValue recurses and can reallocate the pool backing store
    // , so the table is created only hwen everything is decoded
    var elems = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, items.len);
    defer elems.deinit(vm.runtime.alloc);

    for (items) |item| try elems.append(vm.runtime.alloc, try fromJsonValue(item, vm));
    return vm.tableOfSlice(elems.items);
}

fn objectToData(object: json.ObjectMap, vm: *VM) anyerror!Data {
    const table_id = try vm.tables.create();
    var it = object.iterator();
    while (it.next()) |entry| {
        const atom = try vm.internAtom(entry.key_ptr.*);
        // fromJsonValue recurses on nested objects/arrays and can call
        // vm.tables.create(), which could  reallocate the pool backing store
        //
        // re-fetch the table afterwards instead of holding a pointer across the recursion
        //   or the putRawAtom below writes through a dangling pointer
        const value = try fromJsonValue(entry.value_ptr.*, vm);
        const table = try vm.tables.get(table_id);

        try table.putRawAtom(atom, value, vm);
    }
    return Data.new.table(table_id);
}

test "json encode and decode round trip" {
    const testing = revo.lang.testing;

    try testing.topString(
        \\ json.encode({"a", "b", "c"}):unwrap()
    , "[\"a\",\"b\",\"c\"]");

    try testing.topNumber(
        \\ json.decode("{{ \"a\" : 1}}"):unwrap().a
    , 1);
}

test "json decode builds tables for arrays" {
    const testing = revo.lang.testing;

    try testing.topNumber(
        \\ json.decode("[1, 2, 3]"):unwrap()[0]
    , 1);
    try testing.topNumber(
        \\ json.decode("[1, 2, 3]"):unwrap():len()
    , 3);
    try testing.topNumber(
        \\ json.decode("{{ \"a\": [1, 2] }}"):unwrap().a[1]
    , 2);
    try testing.topString(
        \\ json.encode(json.decode("[1, 2]"):unwrap()):unwrap()
    , "[1,2]");
    try testing.topAtom(
        \\ type(json.decode("[1]"))
    , "table");
}

test "json decode of nested objects does not use a stale table pointer" {
    const testing = revo.lang.testing;

    // decoding nested objects recurses through objectToData, which calls
    // vm.tables.create() and can reallocate the table pool. the outer decode
    // must re-fetch its table each step rather than write through a pointer
    // taken before the recursion.
    try testing.topNumber(
        \\ json.decode("{{ \"a\" : {{ \"b\" : {{ \"c\" : 42 }} }} }}"):unwrap().a.b.c
    , 42);
}

const std = @import("std");
const json = std.json;

const revo = @import("../root.zig");
const mem = revo.memory;
const Data = revo.Data;
const VM = revo.VM;
const api = @import("api.zig");
const root = @import("root.zig");
const HostResult = root.HostResult;
