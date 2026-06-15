pub const specs: []const api.FnSpec = &.{
    .{
        .name = "len",
        .placements = &.{ api.mod("tuple"), api.method("tuple", .tuple) },
        .params = &.{
            .{ "self", "tuple" },
        },
        .ret = "number",
        .doc = "returns length of tuple",
        .f = root.define(&[_]root.TypeSpec{.tuple}, len),
    },
    .{
        .name = "unwrap",
        .placements = &.{ api.mod("tuple"), api.method("tuple", .tuple) },
        .params = &.{
            .{ "self", "tuple" },
        },
        .ret = "any",
        .doc = "unwraps result tuple, panics if not :ok",
        .f = root.define(&[_]root.TypeSpec{.tuple}, root.try_),
    },
    .{
        .name = "unwrap_err",
        .placements = &.{ api.mod("tuple"), api.method("tuple", .tuple) },
        .params = &.{
            .{ "self", "tuple" },
        },
        .ret = "any",
        .doc = "extracts error from result tuple, panics if not :err",
        .f = root.define(&[_]root.TypeSpec{.tuple}, root.unwrap_err_),
    },
    .{
        .name = "add",
        .placements = &.{ api.mod("tuple"), api.method("tuple", .tuple) },
        .params = &.{
            .{ "self", "tuple" },
            .{ "other", "tuple" },
        },
        .ret = "tuple",
        .doc = "concatenates two tuples",
        .f = root.define(&[_]root.TypeSpec{ .tuple, .tuple }, add),
    },
    .{
        .name = "mul",
        .placements = &.{ api.mod("tuple"), api.method("tuple", .tuple) },
        .params = &.{
            .{ "self", "tuple" },
            .{ "n", "number" },
        },
        .ret = "tuple",
        .doc = "repeats tuple n times",
        .f = root.define(&[_]root.TypeSpec{ .tuple, .number }, mul),
    },
    .{
        .name = "__index",
        .placements = &.{api.method("tuple", .tuple)},
        .params = &.{
            .{ "self", "tuple" },
            .{ "idx", "number" },
        },
        .ret = "any",
        .doc = "returns element at index",
        .f = root.define(&[_]root.TypeSpec{ .tuple, .number }, index),
        .core_key = revo.core_atoms.__index,
    },
};

fn len(args: []const Data, vm: *VM) !NativeResult {
    const id = args[0].asTuple() orelse return .errType(0, "tuple", root.dataToString(args[0]));
    const t = try vm.tuples.get(id);
    return .{ .ok = Data.new.num(t.len()) };
}

fn index(args: []const Data, vm: *VM) !NativeResult {
    const id = args[0].asTuple() orelse return .errType(0, "tuple", root.dataToString(args[0]));
    const n = args[1].asNum() orelse return .errType(1, "number", root.dataToString(args[1]));
    const idx = try revo.asIndex(n);
    const t = try vm.tuples.get(id);
    if (idx >= t.items.len) return .{ .ok = revo.core_atoms.data(.missing) };
    return .{ .ok = t.items[idx] };
}

fn add(args: []const Data, vm: *VM) !NativeResult {
    const left_id = args[0].asTuple() orelse return .errType(0, "tuple", root.dataToString(args[0]));
    const right_id = args[1].asTuple() orelse return .errType(1, "tuple", root.dataToString(args[1]));
    const left = try vm.tuples.get(left_id);
    const right = try vm.tuples.get(right_id);
    var items = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, left.items.len + right.items.len);
    defer items.deinit(vm.runtime.alloc);
    try items.appendSlice(vm.runtime.alloc, left.items);
    try items.appendSlice(vm.runtime.alloc, right.items);
    return .okData(Data.new.tuple(try vm.tuples.create(items.items)));
}

fn mul(args: []const Data, vm: *VM) !NativeResult {
    const tuple_id = args[0].asTuple() orelse return .errType(0, "tuple", root.dataToString(args[0]));
    const n = args[1].asNum() orelse return .errType(1, "number", root.dataToString(args[1]));
    const times = @as(i64, @intFromFloat(n));
    if (times < 0) return .errType(1, "non-negative number", "negative number");
    const tuple = try vm.tuples.get(tuple_id);
    var items = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, tuple.items.len * @as(usize, @intCast(times)));
    defer items.deinit(vm.runtime.alloc);
    for (0..@as(usize, @intCast(times))) |_| {
        try items.appendSlice(vm.runtime.alloc, tuple.items);
    }
    return .okData(Data.new.tuple(try vm.tuples.create(items.items)));
}

const std = @import("std");

const revo = @import("../root.zig");
const Data = revo.Data;
const VM = revo.VM;
const api = @import("api.zig");
const iter = @import("iter.zig");
const root = @import("root.zig");
const NativeResult = root.NativeResult;
