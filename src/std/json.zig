const std = @import("std");
const revo = @import("../root.zig");
const root = @import("root.zig");
const api = @import("api.zig");

const Data = revo.Data;
const VM = revo.VM;
const NativeResult = root.NativeResult;

const json = std.json;

pub const specs: []const api.FnSpec = &.{
    .{
        .name = "encode",
        .placements = &.{api.mod("json")},
        .params = &.{
            .{ "value", "any" },
        },
        .ret = "(:ok, string) | (:err, string)",
        .doc = "encodes value as json string",
        .f = root.define(&.{.any}, encode),
    },
    .{
        .name = "decode",
        .placements = &.{api.mod("json")},
        .params = &.{
            .{ "source", "string" },
        },
        .ret = "(:ok, any) | (:err, string)",
        .doc = "decodes json string into revo value",
        .f = root.define(&.{.string}, decode),
    },
};

fn encode(args: []const Data, vm: *VM) !NativeResult {
    var out = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer out.deinit();
    try writeJsonValue(args[0], vm, &out.writer);
    const slice = try out.toOwnedSlice();
    const data = try vm.adoptDataString(slice);
    return root.resultTuple(vm, .ok, data);
}

fn decode(args: []const Data, vm: *VM) !NativeResult {
    const source = vm.stringValue(args[0].asString().?);
    var parsed = json.parseFromSlice(json.Value, vm.runtime.alloc, source, .{}) catch |err| {
        return resultErr(vm, @errorName(err));
    };
    defer parsed.deinit();

    const value = try fromJsonValue(parsed.value, vm);
    return root.resultTuple(vm, .ok, value);
}

fn resultErr(vm: *VM, message: []const u8) !NativeResult {
    return root.resultTuple(vm, .err, try vm.ownDataString(message));
}

fn writeJsonValue(data: Data, vm: *VM, writer: *std.Io.Writer) anyerror!void {
    return switch (data.tag()) {
        .number => return error.UnsupportedJsonValue,
        .string => try writeJsonString(writer, vm.stringValue(data.asString().?)),
        .atom => blk: {
            const id = data.asAtom().?;
            const atom = vm.atomName(id);
            if (std.mem.eql(u8, atom, "nil")) break :blk try writer.writeAll("null");
            if (std.mem.eql(u8, atom, "true")) break :blk try writer.writeAll("true");
            if (std.mem.eql(u8, atom, "false")) break :blk try writer.writeAll("false");
            break :blk try writeJsonString(writer, atom);
        },
        .table => try writeTableJson(data.asTable().?, vm, writer),
        .tuple => try writeTupleJson(data.asTuple().?, vm, writer),
        .function => return error.UnsupportedJsonValue,
        .struct_val => return error.UnsupportedJsonValue,
        .struct_type => return error.UnsupportedJsonValue,
        .foreign => return error.UnsupportedJsonValue,
    };
}

fn writeTupleJson(id: revo.memory.TupleID, vm: *VM, writer: *std.Io.Writer) anyerror!void {
    const tuple = try vm.tuples.get(id);
    try writeArrayJson(tuple.items, vm, writer);
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
    if (table.hash.count != 0) return error.UnsupportedJsonValue;
    return writeArrayJson(table.array.items, vm, writer);
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
            else => try writer.writeByte(c),
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
    var tuples = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, items.len);
    defer tuples.deinit(vm.runtime.alloc);
    for (items) |item| try tuples.append(vm.runtime.alloc, try fromJsonValue(item, vm));
    return Data.new.tuple(try vm.tuples.create(tuples.items));
}

fn objectToData(object: json.ObjectMap, vm: *VM) anyerror!Data {
    const table_id = try vm.tables.create();
    const table = try vm.tables.get(table_id);
    var it = object.iterator();
    while (it.next()) |entry| {
        try table.putRawAtom(try vm.internAtom(entry.key_ptr.*), try fromJsonValue(entry.value_ptr.*, vm));
    }
    return Data.new.table(table_id);
}

test "json encode and decode round trip" {
    const testing = revo.lang.testing;

    try testing.top_string(
        \\ json.encode(("a", "b", "c")):unwrap()
    , "[\"a\",\"b\",\"c\"]");

    try testing.top_number(
        \\ json.decode("{\"a\":1}"):unwrap().a
    , 1);
}
