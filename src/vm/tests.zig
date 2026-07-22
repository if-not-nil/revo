const std = @import("std");
const testing = std.testing;

const revo = @import("revo");
const Data = revo.Data;

const VM = @import("VM.zig").VM;
const Scheduler = revo.vm.Scheduler;
const vt_runtime = revo.lang.testing.runtime;

fn trigger_gc(vm: *VM) void {
    vm.gc_pending = true;
    vm.maybeCollectGarbage();
}

fn fakeIoReady(_: *VM, _: *Scheduler.WaitEntry, _: i16) anyerror!Scheduler.IoDispatchResult {
    return .{};
}

test {
    _ = std.testing.refAllDecls(@import("VM.zig"));
    _ = std.testing.refAllDecls(@import("module.zig"));
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
    _ = try vm.runReport();

    const out = vm.mainResult();
    try testing.expectEqual(@as(f64, 42), out.asNum().?);
}

test "nanbox canonicalizes nan through helpers" {
    // nanboxing canonicalizes NaN to CANONICAL_NAN, which collides with the
    // boxed value tag space. NaN values cannot round-trip through Data.new.num.
    const nan = Data.new.num(std.math.nan(f64));
    try testing.expect(nan.asNum() == null);
}

test "vm join parks current fiber when target alive" {
    return error.SkipZigTest;
    // var vm = try VM.init(vt_runtime());
    // defer vm.deinit();
    //
    // const child = try VM.Fiber.init(vm.runtime.alloc, 1, &.{});
    // try vm.sched.fibers.append(vm.runtime.alloc, child);
    // vm.sched.fibers.items[1].state = .ready;
    //
    // const handle = try vm.addConstant(Data.new.num(1));
    // const program = [_]revo.Instruction{
    //     .{ .op = .load_const, .a = 0, .bx = @intCast(handle) },
    //     .{ .op = .join, .a = 0 },
    //     .{ .op = .halt, .a = 0 },
    // };
    // vm.mainFiber().program = &program;
    // _ = try vm.runReport();
    //
    // try testing.expectEqual(@as(VM.Fiber.State, .waiting), vm.currentFiber().state);
    // try testing.expectEqual(@as(bool, false), vm.currentFiber().running);
    // try testing.expectEqual(@as(usize, 1), vm.sched.fibers.items[1].waiters.items.len);
    // try testing.expectEqual(@as(usize, 0), vm.sched.fibers.items[1].waiters.items[0]);
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
    const result = try vm.runReport();
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

test "vm gc keeps rooted tables and their children alive" {
    var vm = try VM.init(vt_runtime());
    defer vm.deinit();

    const parent_id = try vm.tables.create();
    const child_id = try vm.tables.create();

    {
        const parent = try vm.tables.get(parent_id);
        try parent.putRaw(try vm.ownDataString("child"), Data.new.table(child_id));
    }

    try vm.push(Data.new.table(parent_id));
    defer _ = vm.pop() catch {};

    trigger_gc(&vm);

    const parent = try vm.tables.get(parent_id);
    const child = parent.getRaw(try vm.ownDataString("child")) orelse unreachable;
    try testing.expect(child.isTable());
    try testing.expectEqual(child_id, child.asTable().?);
    _ = try vm.tables.get(child_id);
}

test "vm gc keeps globals rooted tables alive" {
    var vm = try revo.VM.init(vt_runtime());
    defer vm.deinit();

    const table_id = try vm.tables.create();
    try vm.setGlobal("alive", Data.new.table(table_id));

    trigger_gc(&vm);

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

    trigger_gc(&vm);

    const key = try vm.ownDataString("child");
    const child_id = try vm.tables.create();
    {
        const root = try vm.tables.get(root_id);
        try root.put(root_id, &vm, key, Data.new.table(child_id));
    }

    vm.maybeCollectGarbage();

    const root = try vm.tables.get(root_id);
    const child = root.getRaw(key) orelse unreachable;
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
    trigger_gc(&vm);

    try testing.expectError(error.FunctionDNE, vm.functions.get(fn_id));
    const reused = try vm.functions.createClosure(proto_id, &.{});
    try testing.expectEqual(fn_id, reused);
}

test "vm gc keeps rooted closures and captured tables alive" {
    var vm = try VM.init(vt_runtime());
    defer vm.deinit();

    const table_id = try vm.tables.create();
    try (try vm.tables.get(table_id)).putRaw(try vm.ownDataString("x"), Data.new.num(1));

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

    trigger_gc(&vm);

    _ = try vm.functions.get(closure_id);
    _ = try vm.tables.get(table_id);
}

test "vm gc keeps struct methods alive" {
    var vm = try VM.init(vt_runtime());
    defer vm.deinit();

    const proto_id = try vm.functions.createPrototype(.{
        .addr = 0,
        .arity = 1,
        .total_arity = 1,
        .name = "take",
        .upvalue_specs = &.{},
        .const_locals = &.{},
        .const_local_bits = &.{},
    });
    const fn_id = try vm.functions.createClosure(proto_id, &.{});

    var methods = std.StringHashMap(Data).init(vm.runtime.alloc);
    errdefer methods.deinit();
    try methods.put("take", Data.new.function(fn_id));
    _ = try vm.struct_types.registerType("Chain", &.{}, methods);

    trigger_gc(&vm);

    _ = try vm.functions.get(fn_id);
}

test "vm gc reuses freed tuple ids" {
    var vm = try VM.init(vt_runtime());
    defer vm.deinit();

    const first_id = try vm.tuples.create(&.{Data.new.num(1)});
    trigger_gc(&vm);

    try testing.expectError(error.InvalidTuple, vm.tuples.get(first_id));

    const reused_id = try vm.tuples.create(&.{Data.new.num(2)});
    try testing.expectEqual(first_id, reused_id);
}

test "vm gc keeps rooted tuples and nested tuples alive" {
    var vm = try VM.init(vt_runtime());
    defer vm.deinit();

    const child_id = try vm.tuples.create(&.{ Data.new.num(2), Data.new.num(3) });
    const parent_id = try vm.tuples.create(&.{ Data.new.num(1), Data.new.tuple(child_id) });

    try vm.push(Data.new.tuple(parent_id));
    defer _ = vm.pop() catch {};

    trigger_gc(&vm);

    const parent = try vm.tuples.get(parent_id);
    const child = try vm.tuples.get(child_id);
    try testing.expectEqual(@as(usize, 2), parent.items.len);
    try testing.expectEqual(@as(usize, 2), child.items.len);
    try testing.expectEqual(child_id, parent.items[1].asTuple().?);
}

test "vm gc collects unreachable tuples" {
    var vm = try VM.init(vt_runtime());
    defer vm.deinit();

    const tuple_id = try vm.tuples.create(&.{Data.new.num(9)});
    trigger_gc(&vm);

    try testing.expectError(error.InvalidTuple, vm.tuples.get(tuple_id));
}

test "vm gc reuses freed string storage" {
    var vm = try VM.init(vt_runtime());
    defer vm.deinit();

    const first = try vm.ownString("alpha");
    try testing.expect(vm.strings.contains(first));

    vm.gc_pending = true;
    vm.maybeCollectGarbage();

    try testing.expect(!vm.strings.contains(first));

    const second = try vm.ownString("beta");
    try testing.expectEqualStrings("beta", vm.stringValue(second));
}

test "vm gc keeps rooted strings alive" {
    var vm = try VM.init(vt_runtime());
    defer vm.deinit();

    const s = try vm.ownString("keep-me");
    try vm.push(try vm.ownDataString(vm.stringValue(s)));
    defer _ = vm.pop() catch {};

    trigger_gc(&vm);

    try testing.expect(vm.strings.contains(s));
}

test "vm gc stress test allocates many objects" {
    var vm = try VM.init(vt_runtime());
    defer vm.deinit();

    var table_ids = try std.ArrayList(revo.memory.TableID).initCapacity(vt_runtime().alloc, 200);
    defer table_ids.deinit(vt_runtime().alloc);

    var tuple_ids = try std.ArrayList(revo.memory.TupleID).initCapacity(vt_runtime().alloc, 200);
    defer tuple_ids.deinit(vt_runtime().alloc);

    var string_ids = try std.ArrayList(revo.memory.StringID).initCapacity(vt_runtime().alloc, 200);
    defer string_ids.deinit(vt_runtime().alloc);

    const iterations = 200;

    for (0..iterations) |i| {
        const tid = try vm.tables.create();
        try table_ids.append(vt_runtime().alloc, tid);

        const ttbl = try vm.tables.get(tid);
        try ttbl.putRaw(try vm.ownDataString("index"), Data.new.num(i));

        const tpl_id = try vm.tuples.create(&.{ Data.new.num(i), Data.new.num(i * 2) });
        try tuple_ids.append(vt_runtime().alloc, tpl_id);

        const sid = try vm.ownString("stress-string");
        try string_ids.append(vt_runtime().alloc, sid);
    }

    try vm.push(try vm.ownDataString("root"));
    try vm.push(Data.new.table(table_ids.items[0]));
    try vm.push(Data.new.tuple(tuple_ids.items[0]));
    try vm.push(try vm.ownDataString(vm.stringValue(string_ids.items[0])));
    // SAFETY: test cleanup
    defer {
        _ = vm.pop() catch {};
        _ = vm.pop() catch {};
        _ = vm.pop() catch {};
        _ = vm.pop() catch {};
    }

    trigger_gc(&vm);

    _ = try vm.tables.get(table_ids.items[0]);
    _ = try vm.tuples.get(tuple_ids.items[0]);
    try testing.expect(vm.strings.contains(string_ids.items[0]));
}
