const std = @import("std");
const testing = std.testing;

const revo = @import("revo");
const Data = revo.Data;

const VM = @import("VM.zig").VM;
const Scheduler = revo.vm.Scheduler;
const vt_runtime = revo.lang.testing.runtime;

fn triggerGc(vm: *VM) void {
    vm.gc_pending = true;
    vm.maybeCollectGarbage();
}

fn fakeIoReady(_: *VM, _: *Scheduler.WaitEntry, _: i16) anyerror!Scheduler.IoDispatchResult {
    return .{};
}

test "vm join returns dead fiber result" {
    var vm = try VM.init(vt_runtime());
    defer vm.deinit();

    const child = try VM.Fiber.init(vm.runtime.alloc, 1, &.{}, 16);
    try vm.sched.fibers.append(vm.runtime.alloc, child);
    vm.sched.fibers.items[1].state = .dead;
    vm.sched.fibers.items[1].result = Data.new.num(42);

    const handle = try vm.addConstant(Data.new.num(1));
    const program = [_]revo.Instruction{
        .{ .op = .load_const, .a = 0, .bx = @intCast(handle) },
        .{ .op = .join, .a = 0 },
        .{ .op = .halt, .a = 0 },
    };
    vm.mainFiber().program = &program;
    _ = try revo.vm.exec.runReport(&vm);

    const out = vm.mainResult();
    try testing.expectEqual(@as(f64, 42), out.asNum().?);
}

test "nanbox canonicalizes nan through helpers" {
    const nan = Data.new.num(std.math.nan(f64));
    try testing.expect(nan.asNum() != null);
    try testing.expect(std.math.isNan(nan.asNum().?));
}

test "vm spawn passes n args to child and join returns result" {
    var vm = try VM.init(vt_runtime());
    defer vm.deinit();

    const proto_id = try vm.functions.createPrototype(.{
        .addr = 6,
        .arity = 2,
        .total_arity = 2,
        .register_count = 4,
        .name = "sum2",
        .upvalue_specs = &.{},
        .const_locals = &.{},
        .const_local_bits = &.{},
    });
    const fn_id = try vm.functions.createClosure(proto_id, &.{});
    const c_fn = try vm.addConstant(Data.new.function(fn_id));
    const c_two = try vm.addConstant(Data.new.num(2));
    const c_three = try vm.addConstant(Data.new.num(3));

    const program = [_]revo.Instruction{
        .{ .op = .load_const, .a = 0, .bx = @intCast(c_fn) },
        .{ .op = .load_const, .a = 1, .bx = @intCast(c_two) },
        .{ .op = .load_const, .a = 2, .bx = @intCast(c_three) },
        .{ .op = .spawn, .a = 0, .b = 2, .c = 0 },
        .{ .op = .join, .a = 0 },
        .{ .op = .halt, .a = 0 },
        .{ .op = .load_local, .a = 2, .b = 0 },
        .{ .op = .load_local, .a = 3, .b = 1 },
        .{ .op = .add, .a = 2, .b = 2, .c = 3 },
        .{ .op = .ret, .a = 2 },
    };

    vm.mainFiber().program = &program;
    const result = try revo.vm.exec.runReport(&vm);
    try testing.expect(result == .ok);

    const out = vm.mainResult();
    try testing.expectEqual(@as(f64, 5), out.asNum().?);
}

test "vm channel handoff wakes blocked receiver" {
    var vm = try VM.init(vt_runtime());
    defer vm.deinit();

    const ch = try vm.sched.channelCreate(&vm.tables, 0);

    const recv = try VM.Fiber.init(vm.runtime.alloc, 1, &.{}, 16);
    try vm.sched.fibers.append(vm.runtime.alloc, recv);
    vm.sched.current_fiber = 1;
    _ = try vm.sched.channelRecv(ch);
    try testing.expectEqual(@as(VM.Fiber.State, .waiting), vm.currentFiber().state);

    vm.sched.current_fiber = 0;
    try vm.sched.channelSend(ch, Data.new.num(99));

    try testing.expectEqual(@as(VM.Fiber.State, .ready), vm.sched.fibers.items[1].state);
    try testing.expectEqual(@as(f64, 99), vm.sched.fibers.items[1].registers[0].asNum().?);
}

test "scheduler generic park wake resumes parked fiber" {
    var vm = try VM.init(vt_runtime());
    defer vm.deinit();

    const child = try VM.Fiber.init(vm.runtime.alloc, 1, &.{}, 16);
    try vm.sched.fibers.append(vm.runtime.alloc, child);
    vm.sched.fibers.items[1].registers_len = 1;
    vm.sched.fibers.items[1].registers[0] = revo.Data.new.core(.missing);

    vm.sched.current_fiber = 1;
    try vm.sched.parkCurrentForIo(
        7,
        .read,
        0,
        fakeIoReady,
        null,
    );

    try testing.expectEqual(@as(VM.Fiber.State, .waiting), vm.sched.fibers.items[1].state);
    try testing.expect(vm.sched.fibers.items[1].wait == .io);
    const io_wait = switch (vm.sched.fibers.items[1].wait) {
        .io => |wait| wait,
        else => unreachable,
    };
    try testing.expectEqual(@as(u64, 7), io_wait.wait_id);
    try testing.expectEqual(@as(usize, 1), vm.sched.io_waiters.items.len);
    try testing.expectEqual(@as(u64, 7), vm.sched.io_waiters.items[0].wait_id);

    try vm.sched.wakeFiber(1, Data.new.num(13));

    try testing.expectEqual(@as(VM.Fiber.State, .ready), vm.sched.fibers.items[1].state);
    try testing.expectEqual(@as(f64, 13), vm.sched.fibers.items[1].registers[1].asNum().?);
}

test "vm channel buffered send then recv" {
    var vm = try VM.init(vt_runtime());
    defer vm.deinit();

    const ch = try vm.sched.channelCreate(&vm.tables, 1);
    try vm.sched.channelSend(ch, Data.new.num(7));

    const before = vm.currentFiber().registers_len;
    if (try vm.sched.channelRecv(ch)) |value| {
        try vm.push(value);
    }
    try testing.expectEqual(before + 1, vm.currentFiber().registers_len);
    try testing.expectEqual(@as(f64, 7), vm.currentFiber().registers[vm.currentFiber().registers_len - 1].asNum().?);
}

// a fiber whose registers are freed (repl reload swaps in a fresh fiber and
// deinits the one that just finished) must have its open upvalues closed
// first: closures stored in globals survive the reload and read `closed`,
// never the freed register buffer
test "vm closes open upvalues before the owning fiber is deinit'd" {
    var vm = try VM.init(vt_runtime());
    defer vm.deinit();

    // what module.runCompiledModuleReport does between runs: swap in a fresh
    // fiber, run it (it captures an open upvalue), then close and deinit it
    const next = try VM.Fiber.init(vm.runtime.alloc, 0, &.{}, 16);
    const prev = vm.swapFiber(next);

    vm.mainFiber().registers_len = 4;
    vm.mainFiber().registers[3] = Data.new.num(42);
    const uv_id = try vm.captureUpvalue(3);
    {
        const uv = try vm.functions.getUpvalue(uv_id);
        try testing.expectEqual(@as(?usize, 3), uv.open_index);
        try testing.expectEqual(@as(?usize, 0), uv.owner_fiber_id);
    }

    var finished = vm.swapFiber(prev);
    try vm.closeUpvalueList(&finished, 0);
    VM.Fiber.deinit(&finished, vm.runtime.alloc);

    const uv = try vm.functions.getUpvalue(uv_id);
    try testing.expectEqual(@as(?usize, null), uv.open_index);
    try testing.expectEqual(@as(f64, 42), uv.closed.asNum().?);
}

test "vm gc keeps rooted tables and their children alive" {
    var vm = try VM.init(vt_runtime());
    defer vm.deinit();

    const parent_id = try vm.tables.create();
    const child_id = try vm.tables.create();

    {
        const parent = try vm.tables.get(parent_id);
        try parent.putRaw(try vm.ownDataString("child"), Data.new.table(child_id), &vm);
    }

    try vm.push(Data.new.table(parent_id));
    defer _ = vm.pop() catch {};

    triggerGc(&vm);

    const parent = try vm.tables.get(parent_id);
    const child = parent.getRaw(try vm.ownDataString("child"), &vm) orelse unreachable;
    try testing.expect(child.isTable());
    try testing.expectEqual(child_id, child.asTable().?);
    _ = try vm.tables.get(child_id);
}

test "vm gc keeps globals rooted tables alive" {
    var vm = try revo.VM.init(vt_runtime());
    defer vm.deinit();

    const table_id = try vm.tables.create();
    try vm.setGlobal("alive", Data.new.table(table_id));

    triggerGc(&vm);

    _ = try vm.tables.get(table_id);
}

test "vm gc keeps tables written during sweep alive" {
    var vm = try revo.VM.init(vt_runtime());
    defer vm.deinit();

    const root_id = try vm.tables.create();
    try vm.setGlobal("root", Data.new.table(root_id));

    for (0..1100) |_| {
        _ = try vm.tables.create();
    }

    triggerGc(&vm);

    const key = try vm.ownDataString("child");
    const child_id = try vm.tables.create();
    {
        const root = try vm.tables.get(root_id);
        try root.put(root_id, &vm, key, Data.new.table(child_id));
    }

    vm.maybeCollectGarbage();

    const root = try vm.tables.get(root_id);
    const child = root.getRaw(key, &vm) orelse unreachable;
    try testing.expect(child.isTable());
    try testing.expectEqual(child_id, child.asTable().?);
    _ = try vm.tables.get(child_id);
}

test "vm gc reuses freed function ids" {
    var vm = try VM.init(vt_runtime());
    defer vm.deinit();

    const proto_id = try vm.functions.createPrototype(.{
        .addr = 0,
        .arity = 0,
        .total_arity = 0,
        .name = "f",
        .upvalue_specs = &.{},
        .const_locals = &.{},
        .const_local_bits = &.{},
    });
    const fn_id = try vm.functions.createClosure(proto_id, &.{});
    triggerGc(&vm);

    try testing.expectError(error.FunctionDNE, vm.functions.get(fn_id));
    const reused = try vm.functions.createClosure(proto_id, &.{});
    try testing.expectEqual(fn_id, reused);
}

test "vm gc keeps rooted closures and captured tables alive" {
    var vm = try VM.init(vt_runtime());
    defer vm.deinit();

    const table_id = try vm.tables.create();
    try (try vm.tables.get(table_id)).putRaw(try vm.ownDataString("x"), Data.new.num(1), &vm);

    const proto_id = try vm.functions.createPrototype(.{
        .addr = 0,
        .arity = 0,
        .total_arity = 0,
        .name = "capture",
        .upvalue_specs = &.{},
        .const_locals = &.{},
        .const_local_bits = &.{},
    });
    const upvalue_id = try vm.functions.createUpvalue(.{
        .open_index = null,
        .closed = Data.new.table(table_id),
        .owner_fiber_id = null,
    });
    const closure_id = try vm.functions.createClosure(proto_id, &.{upvalue_id});
    try vm.push(Data.new.function(closure_id));
    defer _ = vm.pop() catch {};

    triggerGc(&vm);

    _ = try vm.functions.get(closure_id);
    _ = try vm.tables.get(table_id);
}

test "vm gc reuses freed string storage" {
    var vm = try VM.init(vt_runtime());
    defer vm.deinit();

    const first = try vm.strings.own("alpha");
    try testing.expect(vm.strings.contains(first));

    vm.gc_pending = true;
    vm.maybeCollectGarbage();

    try testing.expect(!vm.strings.contains(first));

    const second = try vm.strings.own("beta");
    try testing.expectEqualStrings("beta", vm.stringValue(second));
}

test "vm gc keeps rooted strings alive" {
    var vm = try VM.init(vt_runtime());
    defer vm.deinit();

    const s = try vm.strings.own("keep-me");
    try vm.push(try vm.ownDataString(vm.stringValue(s)));
    defer _ = vm.pop() catch {};

    triggerGc(&vm);

    try testing.expect(vm.strings.contains(s));
}

test "vm gc stress test allocates many objects" {
    var vm = try VM.init(vt_runtime());
    defer vm.deinit();

    var table_ids = try std.ArrayList(revo.memory.TableID).initCapacity(vt_runtime().alloc, 200);
    defer table_ids.deinit(vt_runtime().alloc);

    var string_ids = try std.ArrayList(revo.memory.StringID).initCapacity(vt_runtime().alloc, 200);
    defer string_ids.deinit(vt_runtime().alloc);

    const iterations = 200;

    for (0..iterations) |i| {
        const tid = try vm.tables.create();
        try table_ids.append(vt_runtime().alloc, tid);

        const ttbl = try vm.tables.get(tid);
        try ttbl.putRaw(try vm.ownDataString("index"), Data.new.num(i), &vm);

        const sid = try vm.strings.own("stress-string");
        try string_ids.append(vt_runtime().alloc, sid);
    }

    try vm.push(try vm.ownDataString("root"));
    try vm.push(Data.new.table(table_ids.items[0]));
    try vm.push(try vm.ownDataString(vm.stringValue(string_ids.items[0])));
    // SAFETY: shut up zlint
    defer {
        _ = vm.pop() catch {};
        _ = vm.pop() catch {};
        _ = vm.pop() catch {};
        _ = vm.pop() catch {};
    }

    triggerGc(&vm);

    _ = try vm.tables.get(table_ids.items[0]);
    try testing.expect(vm.strings.contains(string_ids.items[0]));
}
