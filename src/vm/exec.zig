const std = @import("std");
const revo = @import("revo");
const Scheduler = @import("scheduler.zig");
const opcode = @import("opcode.zig");
const Instruction = opcode.Instruction;
const VM = @import("VM.zig");

pub fn runReport(self: *VM) !@TypeOf(self.*).EvalResult {
    self.clearPanicMessage();
    self.clearRuntimeMessage();

    if (self.mainFiber().frames.items.len == 0) {
        if (self.mainFiber().debug_info_id == null)
            self.mainFiber().debug_info_id = self.pending_debug_info_id;

        try self.mainFiber().frames.append(self.runtime.alloc, .{
            .return_addr = @intCast(self.mainFiber().program.len),
            .base = 0,
            .register_count = 16,
        });
        const fiber = self.mainFiber();
        try fiber.slots.resize(self.runtime.alloc, 16);
        @memset(fiber.slots.items, revo.core_atoms.data(.missing));
    }

    self.sched.setFiberState(0, .ready);
    try @call(.always_inline, Scheduler.enqueueRunnable, .{
        &self.sched,
        @as(@TypeOf(self.*).FiberID, 0),
    });

    while (true) {
        if (try runReadyFibers(self)) |failure| {
            return .{ .err = failure };
        }

        try @call(.always_inline, Scheduler.wakeDueSleepers, .{
            &self.sched,
            self.schedNowMonotonicNs(),
        });

        const has_sleepers = self.sched.sleepers.items.len > 0;
        const has_io_waiters = self.sched.io_waiters.items.len > 0;
        const has_waiting = self.sched.waiting_cnt > 0;

        if (!has_sleepers and !has_waiting) {
            @branchHint(.unlikely);
            break;
        }

        if (has_io_waiters or (revo.has_async_backend and has_waiting)) {
            @branchHint(.likely);
            const timeout_ms: i32 = if (self.sched.nextSleepDelayNs(
                self.schedNowMonotonicNs(),
            )) |delay_ns|
                @as(i32, @intCast(@min(
                    delay_ns / std.time.ns_per_ms,
                    @as(u64, std.math.maxInt(i32)),
                )))
            else
                -1;

            if (revo.has_async_backend) {
                _ = revo.async_backend_impl.poll_all(
                    &self.runtime.async_backend,
                    self,
                    timeout_ms,
                ) catch return .{ .err = self.evalFailure(error.Panic) };
            } else {
                _ = revo.std_net.pollIoWaiters(self, timeout_ms) catch
                    return .{ .err = self.evalFailure(error.Panic) };
            }

            try @call(.always_inline, Scheduler.wakeDueSleepers, .{
                &self.sched,
                self.schedNowMonotonicNs(),
            });
            continue;
        }

        if (has_sleepers) {
            @branchHint(.unlikely);
            const now_ns = self.schedNowMonotonicNs();
            if (self.sched.nextSleepDelayNs(now_ns)) |diff_ns| {
                if (diff_ns > 0) std.Io.sleep(
                    self.runtime.io,
                    std.Io.Duration.fromNanoseconds(@intCast(diff_ns)),
                    .awake,
                ) catch {};
            }
            try @call(.always_inline, Scheduler.wakeDueSleepers, .{
                &self.sched,
                self.schedNowMonotonicNs(),
            });
        } else if (has_waiting) {
            // channel waiters without io backend, so yield to avoid busy-wait
            std.Io.sleep(
                self.runtime.io,
                std.Io.Duration.fromNanoseconds(std.time.ns_per_ms),
                .awake,
            ) catch {};
        }
    }
    return .ok;
}

pub fn runReadyFibers(self: *VM) !?@TypeOf(self.*).EvalFailure {
    while (self.sched.dequeueRunnable()) |fid| {
        @branchHint(.unlikely);
        self.sched.current_fiber = fid;
        if (self.currentFiber().state == .dead) continue;

        self.sched.setFiberState(fid, .running);
        self.currentFiber().running = true;

        while (self.currentFiber().running) {
            const instr = fetch(self) catch |e| switch (e) {
                error.ProgramEnd => return null,
            };
            self.evalRegister(instr) catch |e| {
                if (e == error.Parked) {
                    @branchHint(.unlikely);
                    break;
                }
                return self.evalFailure(e);
            };
        }

        if (self.currentFiber().state == .ready) {
            @branchHint(.unlikely);
            try @call(.always_inline, Scheduler.enqueueRunnable, .{
                &self.sched,
                fid,
            });
        }
    }
    return null;
}

pub inline fn fetch(self: *VM) !Instruction {
    const fiber = self.currentFiber();
    if (fiber.pc >= fiber.program.len)
        return error.ProgramEnd;

    const instr = fiber.program[fiber.pc];
    fiber.pc += 1;
    return instr;
}

pub fn trace(self: *VM, instr: Instruction) void {
    const fiber = self.currentFiber();
    std.debug.print("[{d:>4}] {s:<16}\n", .{
        fiber.pc - 1,
        @tagName(instr.op),
    });
}

pub fn dumpStack(self: *VM) void {
    const fiber = self.currentFiber();
    std.debug.print("       stack: [ ", .{});
    for (fiber.slots.items) |item| {
        item.print(self);
        std.debug.print(" ", .{});
    }
    std.debug.print("]\n", .{});
}
