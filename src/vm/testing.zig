const std = @import("std");
const revo = @import("revo");
const vm_mod = @import("VM.zig");

pub const runtime = revo.lang.testing.runtime;

pub fn run(vm: *vm_mod.VM) !void {
    const result = try vm.runReport();
    switch (result) {
        .ok => {},
        .err => |failure| {
            if (vm.currentDebugSource()) |source| {
                revo.printEvalError(vm.runtime.alloc, source, failure);
            } else {
                std.debug.print(
                    "error: {s}\n",
                    .{revo.lang.diagnostic.firstError(failure.report).?},
                );
            }
            return error.RuntimeFailure;
        },
    }
}

pub fn expectFailure(vm: *vm_mod.VM, expected: vm_mod.EvalErrorKind) !void {
    const result = try vm.runReport();
    switch (result) {
        .ok => return error.ExpectedRuntimeFailure,
        .err => |failure| try std.testing.expectEqual(expected, failure.kind),
    }
}

test "expectFailure returns error when vm run succeeds" {
    var vm = try vm_mod.VM.init(runtime());
    defer vm.deinit();
    vm.mainFiber().program = &.{.{ .op = .halt }};

    try std.testing.expectError(error.ExpectedRuntimeFailure, expectFailure(&vm, .TypeError));
}
