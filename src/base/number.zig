const Args = root.host.ArgTypes;

pub const Impl = struct {
    pub fn @"nan?"(vm: *VM, n: Args.number) !HostResult {
        _ = vm;
        return ._bool(std.math.isNan(n));
    }
    pub fn @"finite?"(vm: *VM, n: Args.number) !HostResult {
        _ = vm;
        return ._bool(std.math.isFinite(n));
    }
    pub fn @"inf?"(vm: *VM, n: Args.number) !HostResult {
        _ = vm;
        return ._bool(std.math.isInf(n));
    }
    pub fn floor(vm: *VM, n: Args.number) !HostResult {
        _ = vm;
        return .data(Value.new.num(@floor(n)));
    }
    pub fn ceil(vm: *VM, n: Args.number) !HostResult {
        _ = vm;
        return .data(Value.new.num(@ceil(n)));
    }
    pub fn round(vm: *VM, n: Args.number) !HostResult {
        _ = vm;
        return .data(Value.new.num(@round(n)));
    }
    pub fn abs(vm: *VM, n: Args.number) !HostResult {
        _ = vm;
        return .data(Value.new.num(@abs(n)));
    }
    pub fn __call(vm: *VM, self: Args.any, val: Args.any) !HostResult {
        _ = self;
        return root.number_(&.{val}, vm);
    }
};

pub const impls = root.host.impls(Impl).val;

test "number module and metatable" {
    try testing.topNumber("number(\"12\"):unwrap()", 12);
    try testing.topNumber("number(3.5):unwrap()", 3.5);
    try testing.topTrue("number.nan?(number(\"nan\"):unwrap())");
    try testing.topTrue("number(\"nan\"):unwrap():nan?()");
    try testing.topFalse("42:nan?()");
    try testing.topTrue("42:finite?()");
    try testing.topFalse("42:inf?()");
    try testing.topTrue("number(\"inf\"):unwrap():inf?()");
    try testing.topNumber("3.7:floor()", 3);
    try testing.topNumber("3.2:ceil()", 4);
    try testing.topNumber("3.5:round()", 4);
    try testing.topNumber("(-3):abs()", 3);
    try testing.topNumber("number.abs(-7)", 7);
}

const std = @import("std");

const revo = @import("../root.zig");
const testing = revo.lang.test_helpers;
const Value = revo.Value;
const VM = revo.VM;
const root = @import("root.zig");
const HostResult = root.host.HostResult;
