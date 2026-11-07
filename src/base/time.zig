pub const Impl = struct {
    pub fn now(vm: *VM) !HostResult {
        const ts = std.Io.Clock.real.now(vm.runtime.io);
        return .data(Value.new.num(ts.toMilliseconds()));
    }

    pub fn now_ns(vm: *VM) !HostResult {
        const ts = std.Io.Clock.real.now(vm.runtime.io);
        if (vm.runtime.time_wall_base == 0) vm.runtime.time_wall_base = ts.nanoseconds;
        return .data(Value.new.num(ts.nanoseconds - vm.runtime.time_wall_base));
    }

    pub fn monotonic(vm: *VM) !HostResult {
        const ts = std.Io.Clock.awake.now(vm.runtime.io);
        return .data(Value.new.num(ts.toMilliseconds()));
    }

    pub fn monotonic_ns(vm: *VM) !HostResult {
        const ts = std.Io.Clock.awake.now(vm.runtime.io);
        if (vm.runtime.time_mono_base == 0) vm.runtime.time_mono_base = ts.nanoseconds;
        return .data(Value.new.num(ts.nanoseconds - vm.runtime.time_mono_base));
    }
};

pub const impls = root.host.impls(Impl).val;

test "time module works probably" {
    const testing = revo.lang.test_helpers;

    try testing.topTrue("time.now() > 0");
    try testing.topTrue("time.monotonic() >= 0");
}

const std = @import("std");

const revo = @import("../root.zig");
const Value = revo.Value;
const VM = revo.VM;
const root = @import("root.zig");
const HostResult = root.host.HostResult;
