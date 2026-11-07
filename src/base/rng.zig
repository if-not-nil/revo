const revo = @import("../root.zig");
const root = @import("root.zig");
const specs = @import("specs.zig");
const std = @import("std");
const testing = revo.lang.test_helpers;

const Args = root.host.ArgTypes;
const Value = revo.Value;
const VM = revo.VM;
const HostResult = root.host.HostResult;

pub const Impl = struct {
    pub fn set_seed(vm: *VM, raw_arg: Args.number) !HostResult {
        const new_seed: u64 = root.host.numToInt(u64, raw_arg) orelse return .errType(0, "non-negative integer", root.typeof(Value.new.num(raw_arg), vm));
        vm.runtime.prng = std.Random.DefaultPrng.init(new_seed);
        return .data(Value.new.nil());
    }

    pub fn revert_seed(vm: *VM) !HostResult {
        vm.runtime.prng = null;
        return .data(Value.new.nil());
    }

    pub fn rand(vm: *VM, raw_arg: Args.number) !HostResult {
        const upper_bound: isize = root.host.numToInt(isize, raw_arg) orelse return .errType(0, "integer num", root.typeof(Value.new.num(raw_arg), vm));
        return .data(Value.new.num(randomNumber(isize, vm, 0, upper_bound)));
    }

    pub fn range(vm: *VM, raw_lower: Args.number, raw_upper: Args.number) !HostResult {
        const lower_bound: isize = root.host.numToInt(isize, raw_lower) orelse return .errType(0, "integer num", root.typeof(Value.new.num(raw_lower), vm));
        const upper_bound: isize = root.host.numToInt(isize, raw_upper) orelse return .errType(1, "integer num", root.typeof(Value.new.num(raw_upper), vm));
        const result = if (lower_bound < upper_bound)
            randomNumber(isize, vm, lower_bound, upper_bound)
        else
            randomNumber(isize, vm, upper_bound, lower_bound);
        return .data(Value.new.num(result));
    }

    pub fn rand_float(vm: *VM) !HostResult {
        return .data(Value.new.num(randomNumber(f64, vm, 0.0, 1.0)));
    }

    pub fn choice(vm: *VM, self: Args.table) !HostResult {
        const table = try vm.tables.get(@backingInt(self));
        if (table.array.items.len > 0) {
            const idx = randomNumber(usize, vm, 0, table.array.items.len - 1);
            return .data(table.array.items[idx]);
        } else {
            return .data(Value.new.nil());
        }
    }
};

pub const impls: []const specs.Impl = root.host.impls(Impl).val;

fn randomNumber(comptime T: type, vm: *VM, lowerBound: T, upperBound: T) T {
    if (vm.runtime.prng == null) {
        const time_seed: u64 = @intCast(std.Io.Clock.awake.now(vm.runtime.io).toNanoseconds());
        vm.runtime.prng = std.Random.DefaultPrng.init(time_seed);
    }
    var random = vm.runtime.prng.?.random();
    return switch (@typeInfo(T)) {
        .int => random.intRangeAtMost(T, lowerBound, upperBound),
        .float => random.float(T),
        else => unreachable,
    };
}

test "getting random element from table" {
    try testing.topNumber(
        \\ rng.set_seed(2226)
        \\ const elem = rng.choice({1, 2, 3})
        \\ elem
    , 3);
}

test "nil from a table with only named members" {
    try testing.topTrue(
        \\ let t = {"hi" = 1, "bye" = 2}
        \\ let result = :true
        \\
        \\ for _ in 0..100 
        \\   result = result and rng.choice(t) == :nil
        \\
        \\ result
    );
}

test "seed setting and resetting" {
    try testing.topTrue(
        \\ rng.set_seed(2226)
        \\ let x_total = 0 
        \\
        \\ for x in 0..10 
        \\   x_total += rng.rand(x)
        \\
        \\ rng.set_seed(7)
        \\ let y_total = 0
        \\
        \\ for y in 0..10
        \\   y_total += rng.rand(y)
        \\
        \\ x_total == 16 and y_total == 24
    );
}
