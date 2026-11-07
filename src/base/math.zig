const Args = root.host.ArgTypes;

pub const Impl = struct {
    pub fn abs(vm: *VM, x: Args.number) !HostResult {
        _ = vm;
        return .data(Value.new.num(@abs(x)));
    }
    pub fn floor(vm: *VM, x: Args.number) !HostResult {
        _ = vm;
        return .data(Value.new.num(@floor(x)));
    }
    pub fn ceil(vm: *VM, x: Args.number) !HostResult {
        _ = vm;
        return .data(Value.new.num(@ceil(x)));
    }
    pub fn sqrt(vm: *VM, x: Args.number) !HostResult {
        _ = vm;
        return .data(Value.new.num(@sqrt(x)));
    }
    pub fn pow(vm: *VM, base: Args.number, exponent: Args.number) !HostResult {
        _ = vm;
        return .data(Value.new.num(std.math.pow(f64, base, exponent)));
    }
    pub fn sin(vm: *VM, x: Args.number) !HostResult {
        _ = vm;
        return .data(Value.new.num(@sin(x)));
    }
    pub fn asin(vm: *VM, x: Args.number) !HostResult {
        _ = vm;
        return .data(Value.new.num(std.math.asin(x)));
    }
    pub fn sinh(vm: *VM, x: Args.number) !HostResult {
        _ = vm;
        return .data(Value.new.num(std.math.sinh(x)));
    }
    pub fn asinh(vm: *VM, x: Args.number) !HostResult {
        _ = vm;
        return .data(Value.new.num(std.math.asinh(x)));
    }
    pub fn cos(vm: *VM, x: Args.number) !HostResult {
        _ = vm;
        return .data(Value.new.num(@cos(x)));
    }
    pub fn acos(vm: *VM, x: Args.number) !HostResult {
        _ = vm;
        return .data(Value.new.num(std.math.acos(x)));
    }
    pub fn cosh(vm: *VM, x: Args.number) !HostResult {
        _ = vm;
        return .data(Value.new.num(std.math.cosh(x)));
    }
    pub fn acosh(vm: *VM, x: Args.number) !HostResult {
        _ = vm;
        return .data(Value.new.num(std.math.acosh(x)));
    }
    pub fn tan(vm: *VM, x: Args.number) !HostResult {
        _ = vm;
        return .data(Value.new.num(@tan(x)));
    }
    pub fn atan(vm: *VM, x: Args.number) !HostResult {
        _ = vm;
        return .data(Value.new.num(std.math.atan(x)));
    }
    pub fn tanh(vm: *VM, x: Args.number) !HostResult {
        _ = vm;
        return .data(Value.new.num(std.math.tanh(x)));
    }
    pub fn atanh(vm: *VM, x: Args.number) !HostResult {
        _ = vm;
        return .data(Value.new.num(std.math.atanh(x)));
    }
    pub fn atan2(vm: *VM, y: Args.number, x: Args.number) !HostResult {
        _ = vm;
        return .data(Value.new.num(std.math.atan2(y, x)));
    }
    pub fn hypot(vm: *VM, x: Args.number, y: Args.number) !HostResult {
        _ = vm;
        return .data(Value.new.num(std.math.hypot(x, y)));
    }
    pub fn log(vm: *VM, x: Args.number) !HostResult {
        _ = vm;
        return .data(Value.new.num(@log(x)));
    }
    pub fn exp(vm: *VM, x: Args.number) !HostResult {
        _ = vm;
        return .data(Value.new.num(@exp(x)));
    }
    pub fn sign(vm: *VM, x: Args.number) !HostResult {
        _ = vm;
        return .data(Value.new.num(std.math.sign(x)));
    }
    pub fn @"close?"(vm: *VM, x: Args.number, y: Args.number, places: Args.number) !HostResult {
        _ = vm;
        const tolerance = 1.0 / std.math.pow(f64, 10, places);
        const result = std.math.approxEqAbs(f64, x, y, tolerance);
        return .data(Value.new.boolean(result));
    }
};

pub const impls: []const specs.Impl = root.host.impls(Impl).val ++ &[_]specs.Impl{
    .{ .name = "min", .f = root.host.defineVariadic(&.{.number}, minFn) },
    .{ .name = "max", .f = root.host.defineVariadic(&.{.number}, maxFn) },
};

fn minFn(args: []const Value, _: *VM) !HostResult {
    var res = args[0].asNumOpt().?;
    for (args[1..]) |arg| {
        const val = arg.asNumOpt().?;
        if (val < res) res = val;
    }
    return .data(Value.new.num(res));
}

fn maxFn(args: []const Value, _: *VM) !HostResult {
    var res = args[0].asNumOpt().?;
    for (args[1..]) |arg| {
        const val = arg.asNumOpt().?;
        if (val > res) res = val;
    }
    return .data(Value.new.num(res));
}

test "math library" {
    try testing.topNumber("math.abs(-5)", 5);
    try testing.topNumber("math.abs(5)", 5);
    try testing.topNumber("math.floor(3.7)", 3);
    try testing.topNumber("math.ceil(3.2)", 4);
    try testing.topNumber("math.sqrt(4)", 2);
    try testing.topNumber("math.pow(2, 3)", 8);
    try testing.topNumber("math.min(1, 2, 3)", 1);
    try testing.topNumber("math.max(1, 2, 3)", 3);
    try testing.topNumber("math.hypot(3, 4)", 5.0);
    try testing.topNumber("math.sign(-0.15)", -1);
    try testing.topTrue("math.close?(1.5, 1.5004, 3)");
    try testing.topFalse("math.close?(1.5, 1.5004, 4)");
}

const std = @import("std");

const revo = @import("../root.zig");
const testing = revo.lang.test_helpers;
const Value = revo.Value;
const VM = revo.VM;
const root = @import("root.zig");
const specs = @import("specs.zig");
const HostResult = root.host.HostResult;
