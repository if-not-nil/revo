const Args = root.host.ArgTypes;

pub const Impl = struct {
    pub fn encode(vm: *VM, data: Args.any, pretty: Args.Optional(.bool, false)) !HostResult {
        const slice = try encodeAllocPretty(data, vm, pretty.value);
        const result = try vm.adoptValueString(slice);
        return HostResult.Ok(vm, result);
    }

    pub fn decode(vm: *VM, source: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(source));
        var parsed = json.parseFromSlice(json.Value, vm.runtime.alloc, str, .{}) catch |err| {
            return HostResult.Err(vm, @errorName(err));
        };
        defer parsed.deinit();
        const value = try fromJsonValue(parsed.value, vm);
        return HostResult.Ok(vm, value);
    }
};

pub const impls = root.host.impls(Impl).val;

/// ret owned json string
pub fn encodeAlloc(data: Value, vm: *VM) ![]const u8 {
    return encodeAllocPretty(data, vm, false);
}

/// ret owned json string; pretty selects indented output
pub fn encodeAllocPretty(data: Value, vm: *VM, pretty: bool) ![]u8 {
    var out = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer out.deinit();
    var stringify: json.Stringify = .{
        .writer = &out.writer,
        .options = .{
            .whitespace = if (pretty) .indent_2 else .minified,
        },
    };

    try (JsonValue{ .vm = vm, .data = data }).jsonStringify(&stringify);
    return out.toOwnedSlice();
}

const JsonValue = struct {
    vm: *VM,
    data: Value,

    pub fn jsonStringify(self: @This(), jws: anytype) anyerror!void {
        const vm = self.vm;
        return switch (self.data.tag()) {
            .number => {
                const n = self.data.asNumOpt().?;
                if (!std.math.isFinite(n)) return error.UnsupportedJsonValue;
                if (@trunc(n) == n and @abs(n) < 9.0e18) {
                    try jws.write(@as(i64, @intFromFloat(n)));
                } else {
                    try jws.write(n);
                }
            },
            .string => try jws.write(vm.stringValue(self.data.asString().?)),
            .atom => {
                const id = self.data.asAtom().?;
                if (id == revo.CoreAtoms.atomId(.nil)) {
                    try jws.write(null);
                } else if (id == revo.CoreAtoms.atomId(.true)) {
                    try jws.write(true);
                } else if (id == revo.CoreAtoms.atomId(.false)) {
                    try jws.write(false);
                } else {
                    try jws.write(vm.stringValue(id));
                }
            },
            .table => try writeTableJson(vm, self.data.asTable().?, jws),
            .function => return error.UnsupportedJsonValue,
            .@"opaque" => return error.UnsupportedJsonValue,
            .resource => return error.UnsupportedJsonValue,
        };
    }
};

fn writeTableJson(vm: *VM, id: revo.memory.TableID, jws: anytype) anyerror!void {
    const table = try vm.tables.get(id);
    if (table.hash.count == 0) {
        try jws.beginArray();
        for (table.array.items) |item| {
            try (JsonValue{ .vm = vm, .data = item }).jsonStringify(jws);
        }
        try jws.endArray();
        return;
    }

    // keyed entries encoded as a json object; integer slots become "0".."n-1"
    // keys so nothing is dropped
    try jws.beginObject();
    for (table.array.items, 0..) |item, idx| {
        var buf: [20]u8 = undefined;
        const key_str = try std.mem.print(&buf, "{d}", .{idx});
        try jws.objectField(key_str);
        try (JsonValue{ .vm = vm, .data = item }).jsonStringify(jws);
    }

    const entries = try table.keyedEntries(vm.runtime.alloc);
    defer vm.runtime.alloc.free(entries);
    for (entries) |entry| {
        const key_str = switch (entry.key.tag()) {
            .atom => vm.stringValue(entry.key.asAtom().?),
            .string => vm.stringValue(entry.key.asString().?),
            else => return error.UnsupportedJsonValue,
        };
        try jws.objectField(key_str);
        try (JsonValue{ .vm = vm, .data = entry.value }).jsonStringify(jws);
    }
    try jws.endObject();
}

fn fromJsonValue(value: json.Value, vm: *VM) anyerror!Value {
    return switch (value) {
        .null => revo.Value.new.core(.nil),
        .bool => |b| Value.new.boolean(b),
        .integer => |n| Value.new.num(n),
        .float => |n| Value.new.num(n),
        .number_string => |s| Value.new.num(try std.fmt.parseFloat(f64, s)),
        .string => |s| try vm.ownValueString(s),
        .array => |array| try arrayToValue(array.items, vm),
        .object => |object| try objectToValue(object, vm),
    };
}

fn arrayToValue(items: []const json.Value, vm: *VM) anyerror!Value {
    // fromJsonValue recurses and can reallocate the pool backing store
    // , so the table is created only hwen everything is decoded
    var elems = try std.ArrayList(Value).initCapacity(vm.runtime.alloc, items.len);
    defer elems.deinit(vm.runtime.alloc);

    for (items) |item| try elems.append(vm.runtime.alloc, try fromJsonValue(item, vm));
    return vm.tableOfSlice(elems.items);
}

fn objectToValue(object: json.ObjectMap, vm: *VM) anyerror!Value {
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
    return Value.new.table(table_id);
}

test "json encode and decode round trip" {
    const testing = revo.lang.test_helpers;

    try testing.topString(
        \\ json.encode({"a", "b", "c"}):unwrap()
    , "[\"a\",\"b\",\"c\"]");

    try testing.topNumber(
        \\ json.decode("{{ \"a\" : 1}}"):unwrap().a
    , 1);
}

test "json decode builds tables for arrays" {
    const testing = revo.lang.test_helpers;

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
        \\ typeof(json.decode("[1]"))
    , "table");
}

test "json decode of nested objects does not use a stale table pointer" {
    const testing = revo.lang.test_helpers;

    // decoding nested objects recurses through objectToValue, which calls
    // vm.tables.create() and can reallocate the table alloc_pool. the outer decode
    // must re-fetch its table each step rather than write through a pointer
    // taken before the recursion.
    try testing.topNumber(
        \\ json.decode("{{ \"a\" : {{ \"b\" : {{ \"c\" : 42 }} }} }}"):unwrap().a.b.c
    , 42);
}

const std = @import("std");
const json = std.json;

const revo = @import("../root.zig");
const Value = revo.Value;
const VM = revo.VM;
const root = @import("root.zig");
const HostResult = root.host.HostResult;
