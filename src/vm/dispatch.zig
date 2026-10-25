//!
//! dispatcher: runq, blocking waits, and the bytecode loop
//!
//! ~ `runReport` is the one entry point, `waitForActivity` is the idle step
//! ~ workers steal whole fibers, the gil guards the heap
//!

pub fn runReport(self: *VM) !@TypeOf(self.*).RunResult {
    self.clearPanicMessage();
    self.clearRuntimeMessage();

    const fid = self.sched.currentID();
    const fiber = self.currentFiber();
    if (fiber.frames.items.len == 0) {
        try self.pushRootFrame(fiber, 16);
        fiber.registers_len = 16;
        @memset(fiber.registers[0..16], revo.Value.new.core(.missing));
    }

    self.sched.setFiberState(fid, .ready);
    try self.sched.enqueueRunnable(fid);

    self.run_depth += 1;
    defer self.run_depth -= 1;

    const was_exempt = shutdown_exempt;
    if (self.run_depth > 1) shutdown_exempt = true;
    defer shutdown_exempt = was_exempt;

    // nested report with a live pool
    // ; ask workers to drain so the import runs near-solo
    // ; the outer loop rebuilds the pool after
    if (self.run_depth > 1 and self.sched.workers.items.len > 0) {
        std.debug.assert(gil_depth > 0);
        self.sched.requestShutdown();
    }

    if (self.run_depth == 1 and revo.can_async and self.sched.thread_count > 1) {
        while (true) {
            self.mt_failed.store(false, .release);
            self.mt_failure = null;
            self.sched.shutdown.store(false, .release);
            spawnWorkers(self) catch {
                if (try runLoop(self)) |failure| return .{ .err = failure };
                return .ok;
            };
            const r = runLoop(self);
            self.sched.requestShutdown();
            joinWorkers(self);
            const failure = r catch |e| return e;
            if (failure) |f| return .{ .err = f };
            if (self.mt_failure) |f| return .{ .err = f };
            if (self.mt_failed.load(.acquire)) return error.OutOfMemory;
            if (schedHasLive(self)) continue;
            return .ok;
        }
    }

    if (try runLoop(self)) |failure| return .{ .err = failure };
    if (self.mt_failure) |f| return .{ .err = f };
    if (self.mt_failed.load(.acquire)) return error.OutOfMemory;
    return .ok;
}

/// run every ready fiber a quantum, then idle till something is runnable
/// , ends when the scheduler is idle or a fiber fails
fn runLoop(self: *VM) !?VM.RunFailure {
    while (true) {
        if (!shutdown_exempt and (self.mt_failed.load(.acquire) or self.sched.shutdown.load(.acquire))) return null;
        if (try runReadyFibers(self)) |failure| return failure;
        // wait errors become eval failures here so the main loop keeps a
        // narrow error set for its compile-time callers
        const live = waitForActivity(self) catch |e| return self.runFailure(e);
        if (!live) return null;
    }
}

fn schedHasLive(self: *VM) bool {
    return !self.sched.isIdle(self.run_depth - 1);
}

fn spawnWorkers(self: *VM) !void {
    const n = self.sched.thread_count - 1;
    try self.sched.workers.ensureTotalCapacity(self.runtime.alloc, self.sched.workers.items.len + n);
    errdefer {
        self.sched.requestShutdown();
        joinWorkers(self);
    }
    for (0..n) |_| {
        const t = try std.Thread.spawn(.{}, workerMain, .{self});
        self.sched.workers.appendAssumeCapacity(t);
    }
}

fn joinWorkers(self: *VM) void {
    for (self.sched.workers.items) |t| t.join();
    self.sched.workers.items.len = 0;
}

/// steal whole fibers till shutdown; first failure stops the pool
/// , parks on the wakeup pipe when idle so the main thread can wake it
fn workerMain(vm: *VM) void {
    var spins: usize = 0;
    while (true) {
        if (vm.sched.takeRunnable()) |fid| {
            spins = 0;
            while (!gilTryLock(vm)) {
                if (vm.sched.shutdown.load(.acquire)) {
                    requeueAndExit(vm, fid);
                    return;
                }
                std.Thread.yield() catch std.atomic.spinLoopHint();
            }
            if (vm.sched.shutdown.load(.acquire)) {
                gilUnlock(vm);
                requeueAndExit(vm, fid);
                return;
            }
            defer gilUnlock(vm);
            defer vm.sched.quantumDone();
            vm.sched.setCurrent(fid);
            if (vm.currentFiber().state == .dead) continue;
            vm.sched.setFiberState(fid, .running);
            vm.currentFiber().running = true;
            if (execFiber(vm) catch |e| {
                if (e == error.Parked) continue;
                vm.mt_failure = vm.runFailure(e);
                vm.mt_failed.store(true, .release);
                vm.sched.requestShutdown();
                return;
            }) |failure| {
                vm.mt_failure = failure;
                vm.mt_failed.store(true, .release);
                vm.sched.requestShutdown();
                return;
            }
            if (vm.currentFiber().state == .ready) {
                vm.sched.enqueueRunnable(fid) catch {
                    vm.mt_failed.store(true, .release);
                    vm.sched.requestShutdown();
                    return;
                };
            }
        } else if (vm.sched.shutdown.load(.acquire)) {
            return;
        } else if (spins < 100) {
            spins += 1;
            std.atomic.spinLoopHint();
        } else if (revo.can_async and vm.sched.wakeup_r >= 0) {
            // park on the wakeup pipe; timed so a byte stolen by the main
            // , loop's own drain still ends in exit, just 20ms later
            var pfd = [_]std.posix.pollfd{.{
                .fd = vm.sched.wakeup_r,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            _ = std.posix.poll(&pfd, 20) catch {};
            revo.baselib_net.drainWakeup(vm);
        } else {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
    }
}

/// give a checked-out fiber back to the runq and mark its quantum done
/// , for when a worker sees shutdown mid-handoff
fn requeueAndExit(vm: *VM, fid: VM.FiberID) void {
    vm.sched.enqueueRunnable(fid) catch {
        vm.mt_failed.store(true, .release);
    };
    vm.sched.quantumDone();
}

///
/// one idle step of the main loop, shared by runReport and nested blocking waits:
/// wake due sleepers
/// , then block briefly on io/sleep/channel activity.
/// false when nothing is left to wait for.
///
/// holds the GIL except across the blocking syscalls, so workers keep
/// dispatching while we wait; completions still run GIL-held.
///
fn waitForActivity(self: *VM) VM.RunError!bool {
    gilLock(self);
    defer gilUnlock(self);
    try self.sched.wakeDueSleepers(self.schedNowMonotonicNs());

    // idle means nothing outstanding beyond our own ancestral quanta
    if (self.sched.isIdle(self.run_depth - 1)) {
        @branchHint(.unlikely);
        return false;
    }
    const has_sleepers = self.sched.sleepers.items.len > 0;
    const has_io_waiters = self.sched.io_waiters.items.len > 0;
    const has_waiting = self.sched.waiting_cnt > 0;

    if (has_io_waiters or (revo.can_async and has_waiting)) {
        @branchHint(.likely);
        const timeout_ms = pollTimeoutMs(self, has_io_waiters);

        if (comptime !revo.is_freestanding) {
            _ = revo.baselib_net.pollIoWaiters(self, timeout_ms) catch
                return error.Panic;
        }

        try self.sched.wakeDueSleepers(self.schedNowMonotonicNs());
        return true;
    }

    if (has_sleepers) {
        @branchHint(.unlikely);
        const now_ns = self.schedNowMonotonicNs();
        if (self.sched.nextSleepDelayNs(now_ns)) |diff_ns| {
            if (diff_ns > 0) {
                const depth = gilDropForBlocking(self);
                if (revo.can_async and self.sched.wakeup_r >= 0) {
                    // poll the wakeup pipe instead of sleeping blind
                    // ; a newly parked shorter sleeper wakes us early
                    var pfd = [_]std.posix.pollfd{.{
                        .fd = self.sched.wakeup_r,
                        .events = std.posix.POLL.IN,
                        .revents = 0,
                    }};
                    const timeout_ms: i32 = @intCast(@min(
                        diff_ns / std.time.ns_per_ms,
                        std.math.maxInt(i32),
                    ));
                    _ = std.posix.poll(&pfd, timeout_ms) catch {};
                    revo.baselib_net.drainWakeup(self);
                } else {
                    std.Io.sleep(
                        self.runtime.io,
                        std.Io.Duration.fromNanoseconds(@intCast(diff_ns)),
                        .awake,
                    ) catch {};
                }
                gilTakeAfterBlocking(self, depth);
            }
        }
        try self.sched.wakeDueSleepers(self.schedNowMonotonicNs());
    } else if (has_waiting) {
        // channel waiters without io backend, so yield to avoid busy-wait
        const depth = gilDropForBlocking(self);
        std.Io.sleep(
            self.runtime.io,
            std.Io.Duration.fromNanoseconds(std.time.ns_per_ms),
            .awake,
        ) catch {};
        gilTakeAfterBlocking(self, depth);
    }
    return true;
}

/// poll timeout for the io-wait branch: next timer delay when armed
/// , else infinite only when an io waiter can wake us
/// , with no io waiters or no wakeup pipe on multithread, poll briefly
/// , so newly queued work gets seen fast
fn pollTimeoutMs(self: *VM, has_io_waiters: bool) i32 {
    if (self.sched.nextSleepDelayNs(self.schedNowMonotonicNs())) |delay_ns|
        return @intCast(@min(delay_ns / std.time.ns_per_ms, std.math.maxInt(i32)));
    if (!has_io_waiters) return 1;
    if (self.sched.thread_count > 1 and self.sched.wakeup_w < 0) return 1;
    return -1;
}

/// drive other fibers inline until target_id finishes
/// . a join nested inside a host call cannot suspend the host call stack
///   , so instead of parking it pumps the scheduler and blocks
/// . reports the first fiber failure seen.
pub fn pumpUntilDone(self: *VM, target_id: VM.FiberID) !?VM.RunFailure {
    // runReadyFibers parks current_fiber on whatever ran last
    // , so restore ours on every exit
    // : the suspended dispatch below resumes on it
    const outer = self.sched.currentID();
    defer self.sched.setCurrent(outer);

    while (self.sched.fibers.items[target_id].state != .dead) {
        if (try runReadyFibers(self)) |failure| return failure;
        if (self.sched.fibers.items[target_id].state == .dead) break;
        if (!try waitForActivity(self)) break;
    }
    if (self.sched.fibers.items[target_id].state != .dead) {
        return self.fail(error.Panic, "join: target fiber did not finish", .{});
    }
    return null;
}

/// who holds the gil and how deep; same thread relocks for free
threadlocal var gil_owner: ?*VM = null;
threadlocal var gil_depth: usize = 0;
/// nested runs never observe worker shutdown, the inner run goes near-solo
threadlocal var shutdown_exempt: bool = false;

fn gilLock(self: *VM) void {
    if (gil_owner == self) {
        gil_depth += 1;
        return;
    }

    self.gil.lock();
    gil_owner = self;
    gil_depth = 1;
}

fn gilUnlock(self: *VM) void {
    std.debug.assert(gil_owner == self);
    gil_depth -= 1;

    if (gil_depth == 0) {
        gil_owner = null;
        self.gil.unlock();
    }
}

fn gilTryLock(self: *VM) bool {
    if (gil_owner == self) {
        gil_depth += 1;
        return true;
    }
    if (!self.gil.tryLock()) return false;
    gil_owner = self;
    gil_depth = 1;
    return true;
}

// release the GIL around a blocking syscall
// ; no vm touches or nested calls until gilTakeAfterBlocking, returns opaque depth
pub fn gilDropForBlocking(vm: *VM) usize {
    std.debug.assert(gil_owner == vm);
    const d = gil_depth;
    gil_owner = null;
    gil_depth = 0;
    if (d > 0) vm.gil.unlock();
    return d;
}

pub fn gilTakeAfterBlocking(vm: *VM, d: usize) void {
    if (d == 0) return;
    vm.gil.lock();
    std.debug.assert(gil_owner == null);
    gil_owner = vm;
    gil_depth = d;
}

/// one quantum per ready fiber; Parked stays parked, failures stop the loop
inline fn runReadyFibers(self: *VM) !?@TypeOf(self.*).RunFailure {
    while (self.sched.takeRunnable()) |fid| {
        @branchHint(.unlikely);
        {
            gilLock(self);
            defer gilUnlock(self);
            defer self.sched.quantumDone();
            // only the gil holder touches current_fiber
            self.sched.setCurrent(fid);
            if (self.currentFiber().state == .dead) continue;
            self.sched.setFiberState(fid, .running);
            self.currentFiber().running = true;

            // a fiber that parks mid-native (also when the native is reached
            // through a metamethod host call) suspends instead of failing
            //
            // its .waiting and the io waiter re-queues it on completion
            if (execFiber(self) catch |e| {
                if (e == error.Parked) continue;
                return self.runFailure(e);
            }) |failure| return failure;

            if (self.currentFiber().state == .ready) {
                @branchHint(.unlikely);
                try self.sched.enqueueRunnable(fid);
            }
        }
    }
    return null;
}

/// computed-goto dispatch,,, runs current fiber until it yields, halts, or errors
inline fn execFiber(self: *VM) !?VM.RunFailure {
    return execFiberGenericWithAlloc(self, self.runtime.alloc, false, 0);
}

/// runs dispatch until fiber.frames.items.len <= target_depth
pub inline fn execFiberUntilDepth(self: *VM, target_depth: usize) !?VM.RunFailure {
    return execFiberGenericWithAlloc(self, self.runtime.alloc, true, target_depth);
}

// the computed-goto dispatcher's branch targets alias in the BTB by absolute
// address; aligning the whole dispatch loop keeps that aliasing deterministic
// regardless of unrelated changes elsewhere in the binary. wasm doesn't support
// function alignment, so the aligned entry exists only on native targets.
fn execFiberGenericWithAlloc(
    self: *VM,
    alloc: std.mem.Allocator,
    comptime use_depth: bool,
    target_depth: usize,
) !?VM.RunFailure {
    if (builtin.target.cpu.arch.isWasm()) {
        return execFiberDispatch(self, alloc, use_depth, target_depth);
    } else {
        return execFiberDispatchAligned(self, alloc, use_depth, target_depth);
    }
}

inline fn execFiberDispatch(
    self: *VM,
    alloc: std.mem.Allocator,
    comptime use_depth: bool,
    target_depth: usize,
) !?VM.RunFailure {
    @setEvalBranchQuota(2000);
    var fiber = self.currentFiber();
    // fresh host-spawned fiber: run the host call directly, then finish
    // like a returned root frame. a woken fiber lands here marked done
    // with its completion already in regs[0]; it must not re-run.
    if (fiber.pending_host) |ph| {
        switch (ph) {
            .done => {},
            .run => |info| {
                fiber.pending_host = .done;
                self.callRegister(.{ .op = .call, .a = 0, .b = info.argc, .c = 0 }) catch |e| {
                    if (e == error.Parked) return e;
                    return self.runFailure(e);
                };
            },
        }
        fiber.pending_host = null;
        const result = fiber.registers[0];
        try self.sched.finishFiber(fiber.id, result);
        return null;
    }
    std.debug.assert(fiber.pc < fiber.program.len);
    var instr = fiber.program[fiber.pc];
    fiber.pc += 1;
    self.bumpPerf(instr.op);
    var base = fiber.top_base;
    var regs = fiber.registers[0..fiber.registers_len];

    dispatch: switch (instr.op) {
        .move => {
            const val = regRead(regs, base, instr.b);
            regWrite(regs, base, instr.a, val);

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .load_const => {
            std.debug.assert(instr.bx < self.constants.items.len);
            regWrite(regs, base, instr.a, self.constants.items[instr.bx]);

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .load_nil => {
            regWrite(regs, base, instr.a, revo.Value.new.core(.nil));

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .load_small_int => {
            regWrite(
                regs,
                base,
                instr.a,
                Value.new.num(@as(i64, @intCast(instr.bx))),
            );

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .add => {
            const lhs = regRead(regs, base, instr.b);
            const rhs = regRead(regs, base, instr.c);

            if (lhs.asNumOpt()) |ln| if (rhs.asNumOpt()) |rn| {
                regWrite(regs, base, instr.a, Value.new.num(ln + rn));

                fetchNext(self, fiber, &instr);
                continue :dispatch instr.op;
            };

            return self.fail(
                error.IncompatibleTypes,
                "cannot add {s} and {s}",
                .{ revo.baselib.typeof(lhs, self), revo.baselib.typeof(rhs, self) },
            );
        },
        .concat => {
            if (try execConcat(self, regs, base, instr, alloc)) |failure| return failure;
            fiber = self.currentFiber();
            base = fiber.top_base;
            regs = fiber.registers[0..fiber.registers_len];

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .sub => {
            const lhs = regRead(regs, base, instr.b);
            const rhs = regRead(regs, base, instr.c);
            if (lhs.asNumOpt()) |ln| if (rhs.asNumOpt()) |rn| {
                regWrite(regs, base, instr.a, Value.new.num(ln - rn));

                fetchNext(self, fiber, &instr);
                continue :dispatch instr.op;
            };
            return self.fail(
                error.IncompatibleTypes,
                "cannot subtract {s} from {s}",
                .{ revo.baselib.typeof(rhs, self), revo.baselib.typeof(lhs, self) },
            );
        },
        .mul => {
            const lhs = regRead(regs, base, instr.b);
            const rhs = regRead(regs, base, instr.c);
            if (lhs.asNumOpt()) |ln| if (rhs.asNumOpt()) |rn| {
                regWrite(regs, base, instr.a, Value.new.num(ln * rn));

                fetchNext(self, fiber, &instr);
                continue :dispatch instr.op;
            };

            if (try execStringRepeat(self, regs, base, instr, lhs, rhs, alloc)) |failure| return failure;

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .div => {
            const lhs = regRead(regs, base, instr.b);
            const rhs = regRead(regs, base, instr.c);
            if (lhs.asNumOpt()) |ln| if (rhs.asNumOpt()) |rn| {
                if (rn == 0) return self.runFailure(error.DivisionByZero);
                regWrite(regs, base, instr.a, Value.new.num(ln / rn));

                fetchNext(self, fiber, &instr);
                continue :dispatch instr.op;
            };
            return self.fail(
                error.IncompatibleTypes,
                "cannot divide {s} by {s}",
                .{ revo.baselib.typeof(lhs, self), revo.baselib.typeof(rhs, self) },
            );
        },
        .mod => {
            const lhs = regRead(regs, base, instr.b);
            const rhs = regRead(regs, base, instr.c);
            if (lhs.asNumOpt()) |ln| if (rhs.asNumOpt()) |rn| {
                if (rn == 0) return self.runFailure(error.DivisionByZero);
                // integer fast path: @mod(ln, rn) on f64 lowers to fmod, a
                // ~40-cycle libm call. for operands in i32 range fmod and
                // integer @mod agree exactly (beyond that, f64 rounding can
                // push a quotient across an integer boundary), so do i64 mod
                if (revo.memory.numToI64(ln)) |li| if (revo.memory.numToI64(rn)) |ri| {
                    if (li >= std.math.minInt(i32) and
                        li <= std.math.maxInt(i32) and
                        ri >= std.math.minInt(i32) and
                        ri <= std.math.maxInt(i32))
                    {
                        regWrite(regs, base, instr.a, Value.new.num(@as(f64, @floatFromInt(@mod(li, ri)))));
                        fetchNext(self, fiber, &instr);
                        continue :dispatch instr.op;
                    }
                };
                regWrite(regs, base, instr.a, Value.new.num(@mod(ln, rn)));

                fetchNext(self, fiber, &instr);
                continue :dispatch instr.op;
            };
            return self.fail(
                error.IncompatibleTypes,
                "cannot mod {s} by {s}",
                .{ revo.baselib.typeof(lhs, self), revo.baselib.typeof(rhs, self) },
            );
        },
        inline .band, .bor, .bxor => |op| {
            const lhs = regRead(regs, base, instr.b);
            const rhs = regRead(regs, base, instr.c);
            if (lhs.asNumOpt()) |ln| if (rhs.asNumOpt()) |rn| {
                if (revo.memory.numToI64(ln)) |li| if (revo.memory.numToI64(rn)) |ri| {
                    const result: i64 = switch (op) {
                        .band => li & ri,
                        .bor => li | ri,
                        else => li ^ ri,
                    };
                    regWrite(regs, base, instr.a, Value.new.num(@as(f64, @floatFromInt(result))));

                    fetchNext(self, fiber, &instr);
                    continue :dispatch instr.op;
                };
            };
            const msg: []const u8 = switch (op) {
                .band => "cannot band {s} and {s}",
                .bor => "cannot bor {s} and {s}",
                else => "cannot bxor {s} and {s}",
            };
            return self.fail(
                error.IncompatibleTypes,
                msg,
                .{ revo.baselib.typeof(lhs, self), revo.baselib.typeof(rhs, self) },
            );
        },
        inline .shl, .shr => |op| {
            const lhs = regRead(regs, base, instr.b);
            const rhs = regRead(regs, base, instr.c);
            if (lhs.asNumOpt()) |ln| if (rhs.asNumOpt()) |rn| {
                if (revo.memory.numToI64(ln)) |li| if (revo.memory.numToI64(rn)) |ri| {
                    if (ri < 0 or ri > 63) return self.fail(
                        error.ShiftAmountOutOfRange,
                        "shift amount {d} out of range",
                        .{ri},
                    );

                    const shifted: i64 = switch (op) {
                        .shl => @bitCast(@as(u64, @bitCast(li)) << @as(u6, @intCast(ri))),
                        else => li >> @as(u6, @intCast(ri)),
                    };
                    regWrite(regs, base, instr.a, Value.new.num(@as(f64, @floatFromInt(shifted))));

                    fetchNext(self, fiber, &instr);
                    continue :dispatch instr.op;
                };
            };
            return self.fail(
                error.IncompatibleTypes,
                "cannot shift {s} by {s}",
                .{ revo.baselib.typeof(lhs, self), revo.baselib.typeof(rhs, self) },
            );
        },
        .int_div => {
            const lhs = regRead(regs, base, instr.b);
            const rhs = regRead(regs, base, instr.c);
            if (lhs.asNumOpt()) |ln| if (rhs.asNumOpt()) |rn| {
                if (rn == 0) return self.runFailure(error.DivisionByZero);
                const li = revo.memory.numToI64(ln);
                const ri = revo.memory.numToI64(rn);
                if (li != null and ri != null) {
                    regWrite(regs, base, instr.a, Value.new.num(@as(f64, @floatFromInt(@divFloor(li.?, ri.?)))));
                } else {
                    regWrite(regs, base, instr.a, Value.new.num(@floor(ln / rn)));
                }

                fetchNext(self, fiber, &instr);
                continue :dispatch instr.op;
            };
            return self.fail(
                error.IncompatibleTypes,
                "cannot divide {s} by {s}",
                .{ revo.baselib.typeof(lhs, self), revo.baselib.typeof(rhs, self) },
            );
        },
        .negate => {
            const v = regRead(regs, base, instr.b);
            if (v.asNumOpt()) |n| {
                regWrite(regs, base, instr.a, Value.new.num(-n));

                fetchNext(self, fiber, &instr);
                continue :dispatch instr.op;
            }
            return self.fail(error.IncompatibleTypes, "cannot negate {s}", .{revo.baselib.typeof(v, self)});
        },
        .pow => {
            if (try execPow(self, regs, base, instr)) |failure| return failure;

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        inline .eq, .neq, .lt, .gt, .lte, .gte => |op| {
            try compare_impl.evalCachedFast(regs, base, self, instr, op);

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        inline .eq_int, .neq_int, .lt_int, .gt_int, .lte_int, .gte_int => |op| {
            const lhs_val = regRead(regs, base, instr.b);
            const rhs_val = regRead(regs, base, instr.c);
            // f64 compare is the language's number equality for all values,
            // including +-inf and NaN (unordered -> false), so no conversion
            const lhs: f64 = @bitCast(lhs_val.bits);
            const rhs: f64 = @bitCast(rhs_val.bits);

            const result = switch (op) {
                .eq_int => lhs == rhs,
                .neq_int => lhs != rhs,
                .lt_int => lhs < rhs,
                .gt_int => lhs > rhs,
                .lte_int => lhs <= rhs,
                .gte_int => lhs >= rhs,
                else => unreachable,
            };
            regWrite(regs, base, instr.a, Value.new.boolean(result));

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .@"and" => {
            regWrite(regs, base, instr.a, Value.new.boolean(
                !revo.isFalse(regRead(regs, base, instr.b)) and
                    !revo.isFalse(regRead(regs, base, instr.c)),
            ));

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .@"or" => {
            regWrite(regs, base, instr.a, Value.new.boolean(
                !revo.isFalse(regRead(regs, base, instr.b)) or
                    !revo.isFalse(regRead(regs, base, instr.c)),
            ));

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .not => {
            regWrite(regs, base, instr.a, Value.new.boolean(revo.isFalse(regRead(regs, base, instr.b))));

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .table_new => {
            self.noteGCPressure(@sizeOf(revo.table.Table) + 64);
            regWrite(regs, base, instr.a, Value.new.table(try self.tables.create()));

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .table_set => {
            const table_value = regRead(regs, base, instr.a);
            const key = regRead(regs, base, instr.b);
            const t_id = table_value.asTable() orelse
                return self.typeError("table", table_value);
            const t = try self.tableFast(t_id);
            try t.put(t_id, self, key, regRead(regs, base, instr.c));

            // put runs __newindex user code, which may have spawned
            fiber = self.currentFiber();

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .table_get => {
            const object = regRead(regs, base, instr.b);
            const key = regRead(regs, base, instr.c);

            if (object.asTable()) |t_id| {
                const t = try self.tableFast(t_id);
                if (t.getRaw(key, self)) |value| {
                    regWrite(regs, base, instr.a, value);
                } else if (try lookup.resolveTableMiss(self, object, t, key, instr.a)) |resolved| {

                    // resolve may run __index user code, refetch the window
                    fiber = self.currentFiber();
                    base = fiber.top_base;
                    regs = fiber.registers[0..fiber.registers_len];

                    regWrite(regs, base, instr.a, resolved.value);
                } else regWrite(regs, base, instr.a, revo.Value.new.core(.undef));
            } else if (try self.resolveField(object, key, instr.a)) |resolved| {
                fiber = self.currentFiber();
                base = fiber.top_base;
                regs = fiber.registers[0..fiber.registers_len];
                regWrite(regs, base, instr.a, resolved.value);
            } else regWrite(regs, base, instr.a, revo.Value.new.core(.undef));

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .slice => {
            if (try execSlice(self, regs, base, instr)) |failure| return failure;

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .table_set_atom => {
            const table_value = regRead(regs, base, instr.a);
            const t_id = table_value.asTable() orelse
                return self.typeError("table", table_value);

            const t = try self.tableFast(t_id);
            const key = Value.new.atom(instr.bx);
            try t.put(t_id, self, key, regRead(regs, base, instr.c));

            // put may run __newindex user code, which may have spawned
            fiber = self.currentFiber();

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .table_get_atom => {
            const object = regRead(regs, base, instr.b);
            const key = Value.new.atom(instr.bx);

            if (object.asTable()) |t_id| {
                const t = try self.tableFast(t_id);
                if (t.getRaw(key, self)) |value| {
                    regWrite(regs, base, instr.a, value);
                } else if (try lookup.resolveTableMiss(self, object, t, key, instr.a)) |resolved| {
                    // resolve may run __index user code, refetch the window
                    fiber = self.currentFiber();
                    base = fiber.top_base;
                    regs = fiber.registers[0..fiber.registers_len];

                    regWrite(regs, base, instr.a, resolved.value);
                } else {
                    regWrite(regs, base, instr.a, revo.Value.new.core(.undef));
                }
            } else if (try self.resolveField(object, key, instr.a)) |resolved| {
                fiber = self.currentFiber();
                base = fiber.top_base;
                regs = fiber.registers[0..fiber.registers_len];
                regWrite(regs, base, instr.a, resolved.value);
            } else {
                regWrite(regs, base, instr.a, revo.Value.new.core(.undef));
            }

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .jump => {
            fiber.pc = instr.bx;

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .jump_if_false => {
            @branchHint(.unlikely);

            if (revo.isFalse(regRead(regs, base, instr.a))) fiber.pc = instr.bx;

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .jump_if_true => {
            @branchHint(.unlikely);

            if (!revo.isFalse(regRead(regs, base, instr.a))) fiber.pc = instr.bx;

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .load_user_global => {
            const value = self.user_globals.get(instr.bx) orelse
                return self.fail(error.UndefinedVariable, "undefined variable `{s}`", .{self.stringValue(instr.bx)});
            regWrite(regs, base, instr.a, value);

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .load_builtin_global => {
            const value = self.builtin_globals.get(instr.bx) orelse
                return self.fail(
                    error.UndefinedVariable,
                    "undefined baselib variable `{s}`",
                    .{self.stringValue(instr.bx)},
                );

            regWrite(regs, base, instr.a, value);

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        inline .store_user_global, .store_user_global_const => |op| {
            if (self.frozen_globals.contains(instr.bx))
                return self.fail(error.ConstantReassignment, "reassignment to constant!", .{});
            const val = regRead(regs, base, instr.a);
            try self.user_globals.put(instr.bx, val);
            if (op == .store_user_global_const) try self.frozen_globals.put(instr.bx, {});

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .load_local, .bind_local, .store_local => {
            const dst = base + instr.a;
            const src = base + instr.b;
            if (builtin.mode != .fast and src >= regs.len) {
                regWrite(regs, base, instr.a, revo.Value.new.core(.missing));
            } else {
                regs[dst] = regs[src];
            }

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .make_closure => {
            if (try execClosure(self, regs, base, instr, alloc)) |failure| return failure;

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .load_upval => {
            const closure2 = (try self.currentClosureIn(fiber)) orelse return self.runFailure(error.InvalidLocal);
            regWrite(regs, base, instr.a, try self.loadUpvalueValue(closure2.upvalues[instr.bx]));

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .store_upval => {
            const closure2 = (try self.currentClosureIn(fiber)) orelse return self.runFailure(error.InvalidLocal);
            try self.storeUpvalueValue(fiber, closure2.upvalues[instr.bx], regRead(regs, base, instr.a));

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .call => {
            self.callRegister(instr) catch |e| {
                if (e == error.Parked) return e;
                return self.runFailure(e);
            };
            // callRegister runs user code, which may have spawned and
            // reallocated the fibers array or grown registers
            fiber = self.currentFiber();
            base = fiber.top_base;
            regs = fiber.registers[0..fiber.registers_len];

            if (if (comptime use_depth) fiber.frames.items.len <= target_depth else !fiber.running) {
                if (try switchOrStop(self, use_depth, &fiber, &regs, &base, &instr)) {
                    continue :dispatch instr.op;
                }
                break :dispatch;
            }
            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .call_field => {
            execCallField(self, regs, base, instr) catch |e| {
                if (e == error.Parked) return e;
                return self.runFailure(e);
            };
            // execCallField runs user code, same hazard as .call above
            fiber = self.currentFiber();
            base = fiber.top_base;
            regs = fiber.registers[0..fiber.registers_len];

            if (if (comptime use_depth) fiber.frames.items.len <= target_depth else !fiber.running) {
                if (try switchOrStop(self, use_depth, &fiber, &regs, &base, &instr)) {
                    continue :dispatch instr.op;
                }
                break :dispatch;
            }
            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .ret => {
            self.returnRegister(instr) catch |e| return self.runFailure(e);
            if (fiber.frames.items.len == 0) {
                if (try switchOrStop(self, use_depth, &fiber, &regs, &base, &instr)) {
                    continue :dispatch instr.op;
                }
                break :dispatch;
            }
            base = fiber.top_base;
            regs = fiber.registers[0..fiber.registers_len];

            if (if (comptime use_depth) fiber.frames.items.len <= target_depth else !fiber.running) break :dispatch;
            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .spawn => {
            self.spawnRegister(instr, base) catch |e| {
                if (e == error.Parked) return e;
                return self.runFailure(e);
            };
            // spawnRegister may have reallocated fibers
            fiber = self.currentFiber();
            regs = fiber.registers[0..fiber.registers_len];
            base = fiber.top_base;

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .yield => {
            self.sched.setFiberState(self.sched.currentID(), .ready);
            fiber.running = false;
            if (comptime use_depth) break :dispatch;
            if (self.sched.ring_head == self.sched.ring_tail) {
                // nothing else runnable
                // keep running in place instead of a round trip through runq
                fiber.running = true;
                fetchNext(self, fiber, &instr);
                continue :dispatch instr.op;
            }
            try self.sched.enqueueRunnable(self.sched.currentID());
            if (try switchOrStop(self, false, &fiber, &regs, &base, &instr)) {
                continue :dispatch instr.op;
            }
            break :dispatch;
        },
        .halt => {
            const result = regRead(regs, base, instr.a);
            fiber.registers_len = 0;
            try self.push(result);
            fiber.running = false;
            self.sched.setFiberState(self.sched.currentID(), .dead);
            if (try switchOrStop(self, use_depth, &fiber, &regs, &base, &instr)) {
                continue :dispatch instr.op;
            }
            break :dispatch;
        },
        .range_init => {
            const start = regRead(regs, base, instr.b);
            const limit = regRead(regs, base, instr.c);
            const step = regRead(regs, base, @intCast(instr.bx));
            regWrite(regs, base, instr.a, start);
            regWrite(regs, base, instr.a + 1, step);
            regWrite(regs, base, instr.a + 2, limit);

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .range_loop => {
            const current: f64 = @bitCast((regRead(regs, base, instr.b)).bits);
            const step: f64 = @bitCast((regRead(regs, base, instr.b + 1)).bits);
            const limit: f64 = @bitCast((regRead(regs, base, instr.b + 2)).bits);

            const has_next = (step > 0 and current < limit) or (step < 0 and current > limit);

            if (has_next) {
                regWrite(regs, base, instr.a, Value.new.num(current));
                if (instr.c != 0) {
                    const index_reg = regRead(regs, base, instr.c);
                    const index: f64 = blk: {
                        const n = index_reg.asNumOpt() orelse break :blk 0.0;
                        break :blk if (std.math.isFinite(n)) n else 0.0;
                    };
                    regWrite(regs, base, instr.c, Value.new.num(index + 1));
                }
                regWrite(regs, base, instr.b, Value.new.num(current + step));
                fiber.pc = instr.bx;
            }

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .unwrap_result => {
            const val = regRead(regs, base, instr.a);
            const propagate_errors = instr.bx == 0;

            const parts = self.resultParts(val);
            if (parts == null) {
                fetchNext(self, fiber, &instr);
                continue :dispatch instr.op;
            }
            const tag = parts.?.tag;
            const payload = parts.?.payload;

            if (tag.asAtom() == revo.CoreAtoms.atomId(.err)) {
                if (propagate_errors) {
                    if (fiber.frames.items.len == 2) {
                        self.panicFromErrPayload(payload, fiber.pc) catch |e| return self.runFailure(e);
                        return self.runFailure(error.Panic);
                    }
                    self.returnRegister(.{ .op = .ret, .a = instr.a }) catch |e| return self.runFailure(e);

                    if (fiber.frames.items.len == 0) break :dispatch;
                    base = fiber.top_base;
                    regs = fiber.registers[0..fiber.registers_len];

                    fetchNext(self, fiber, &instr);
                    continue :dispatch instr.op;
                }

                fetchNext(self, fiber, &instr);
                continue :dispatch instr.op;
            }

            if (tag.asAtom() == revo.CoreAtoms.atomId(.ok)) {
                if (payload) |p| {
                    regWrite(regs, base, instr.a, p);
                }
            }

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .jump_err => {
            const val = regRead(regs, base, instr.a);
            const is_err = self.isErrTable(val);
            const absent = if (val.asAtom()) |a|
                a == revo.CoreAtoms.atomId(.nil) or
                    a == revo.CoreAtoms.atomId(.undef)
            else
                false;
            if (!absent and !is_err) fiber.pc = instr.bx;

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        inline .add_imm, .sub_imm, .mul_imm => |op| {
            const lhs_val = regRead(regs, base, instr.b);
            if (debug_assert_types) std.debug.assert(lhs_val.isNumber());
            const lhs: f64 = @bitCast(lhs_val.bits);
            const rhs: f64 = @floatFromInt(@as(i64, @intCast(instr.bx)));
            const result: f64 = switch (op) {
                .add_imm => lhs + rhs,
                .sub_imm => lhs - rhs,
                .mul_imm => lhs * rhs,
                else => unreachable,
            };
            regWrite(regs, base, instr.a, Value.new.num(result));

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .band_imm => {
            const lhs_val = regRead(regs, base, instr.b);
            if (debug_assert_types) std.debug.assert(lhs_val.isNumber());
            const li: i64 = revo.memory.numToI64(@as(f64, @bitCast(lhs_val.bits))) orelse
                return self.fail(error.TypeError, "expected integer, got {s}", .{revo.baselib.typeof(lhs_val, self)});
            const ri: i64 = @intCast(instr.bx);
            regWrite(regs, base, instr.a, Value.new.num(@as(f64, @floatFromInt(li & ri))));

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
        .lt_int_imm => {
            const lhs_val = regRead(regs, base, instr.b);
            const lhs: f64 = @bitCast(lhs_val.bits);
            const rhs: i64 = @intCast(instr.bx);
            regWrite(regs, base, instr.a, Value.new.boolean(lhs < @as(f64, @floatFromInt(rhs))));

            fetchNext(self, fiber, &instr);
            continue :dispatch instr.op;
        },
    }
    return null;
}

noinline fn execFiberDispatchAligned(
    self: *VM,
    alloc: std.mem.Allocator,
    comptime use_depth: bool,
    target_depth: usize,
) align(4096) !?VM.RunFailure {
    return execFiberDispatch(self, alloc, use_depth, target_depth);
}

/// fetch next instruction into `instr`, advance fiber pc.
/// TODO: profiling shows passing self here has no perf hit. is that true?
///       never looked at disasm. if its not true, put bumpperf calls at callsite instead (its flag-gated inside anyways)
inline fn fetchNext(self: *VM, fiber: *VM.Fiber, instr: *Instruction) void {
    std.debug.assert(fiber.pc < fiber.program.len);
    instr.* = fiber.program[fiber.pc];
    fiber.pc += 1;
    self.bumpPerf(instr.op);
}

/// keep dispatching inplace on another ready fiber instead of unwinding
/// , depth runs never switch, they unwind to the host caller
inline fn switchOrStop(
    self: *VM,
    comptime use_depth: bool,
    fiber: **VM.Fiber,
    regs: *[]Value,
    base: *usize,
    instr: *Instruction,
) !bool {
    // depth runs unwind to host caller instead of switching fibers
    if (comptime use_depth) return false;
    if (self.sched.switchNext()) {
        fiber.* = self.currentFiber();
        if (fiber.*.pending_host != null) {
            // fresh host fiber: hand back to the runq so the run loop
            // takes it through the entry prologue instead of dispatching
            // an empty program here. restore exact pre-switch state first,
            // switchNext already flipped it to running.
            fiber.*.running = false;
            self.sched.setFiberState(self.sched.currentID(), .ready);
            try self.sched.enqueueRunnable(self.sched.currentID());
            return false;
        }
        base.* = fiber.*.top_base;
        regs.* = fiber.*.registers[0..fiber.*.registers_len];
        fetchNext(self, fiber.*, instr);
        return true;
    }
    return false;
}

//
// -- [cold handlers] ---------------------------------------------------------
// pulled outta the dispatch loop so the hot opcodes stay small in the icache
//
// each returns an error-union `?RunFailure`: null
// on success, an RunFailure to report, or an error to unwrap via runFailure

/// concat with multi-op batching: the compiler lowers a chain `a ~ b ~ c ~ d`
/// to consecutive concats
///
/// R[a]  = R[b] ~ R[c];  R[a'] = R[a'] ~ R[a];  R[a''] = R[a''] ~ R[a']
///
/// so one allocation can build the whole result. only fires when every
/// operand is a string and the chain is straight-line, so the intermediate
/// result registers are dead temporaries
noinline fn execConcat(
    self: *VM,
    regs_in: []Value,
    base_in: usize,
    instr: Instruction,
    alloc: std.mem.Allocator,
) VM.RunError!?VM.RunFailure {
    var regs = regs_in;
    var base = base_in;
    var fiber = self.currentFiber();
    const lhs = regRead(regs, base, instr.b);
    const rhs = regRead(regs, base, instr.c);

    // string + string fast path
    if (lhs.asStr()) |ls| if (rhs.asStr()) |rs| {
        // try to batch consecutive accumulator concats
        const batched = blk: {
            var prev_a = instr.a;
            var new_ops: [8]opcode.Register = undefined;
            var new_count: usize = 0;
            var scan_pc = fiber.pc;
            while (new_count < new_ops.len and scan_pc < fiber.program.len) {
                const next = fiber.program[scan_pc];
                if (next.op != .concat) break;
                const fwd = next.c == prev_a and next.b == next.a;
                const rev = next.b == prev_a and next.c == next.a;
                if (!fwd and !rev) break;
                new_ops[new_count] = if (fwd) next.b else next.c;
                new_count += 1;
                prev_a = next.a;
                scan_pc += 1;
            }
            if (new_count == 0) break :blk false;

            // operands in result order: [n_{k-1}, ..., n_1, b, c]
            var op_ids: [10]revo.memory.StringID = undefined;
            var op_lens: [10]usize = undefined;
            var n: usize = 0;
            var total_len: usize = 0;
            var i = new_count;
            while (i > 0) {
                i -= 1;
                const v = regRead(regs, base, new_ops[i]);
                const sid = v.asStr() orelse break :blk false;
                const s = self.stringValue(sid);
                op_ids[n] = sid;
                op_lens[n] = s.len;
                total_len += s.len;
                n += 1;
            }
            const bs = self.stringValue(ls);
            const cs = self.stringValue(rs);
            op_ids[n] = ls;
            op_lens[n] = bs.len;
            total_len += bs.len;
            n += 1;
            op_ids[n] = rs;
            op_lens[n] = cs.len;
            total_len += cs.len;
            n += 1;

            self.noteGCPressure(total_len + @sizeOf(Value));
            const buf = try alloc.alloc(u8, total_len);
            var off: usize = 0;
            for (0..n) |j| {
                const s = self.stringValue(op_ids[j]);
                @memcpy(buf[off..][0..op_lens[j]], s);
                off += op_lens[j];
            }
            const result = try self.adoptValueStringNoDedup(buf);
            regWrite(regs, base, prev_a, result);
            // skipped concats never dispatch, count them here
            // (the current one was already counted at fetch)
            self.bumpPerfN(.concat, new_count);
            fiber.pc += new_count;
            break :blk true;
        };
        if (batched) return null;

        const l_str = self.stringValue(ls);
        const r_str = self.stringValue(rs);

        // empty string shortcuts: "" ~ x = x,  x ~ "" = x
        if (l_str.len == 0) {
            regWrite(regs, base, instr.a, rhs);
            return null;
        }
        if (r_str.len == 0) {
            regWrite(regs, base, instr.a, lhs);
            return null;
        }

        self.noteGCPressure(l_str.len + r_str.len + @sizeOf(Value));
        const result_str = try self.adoptValueStringNoDedup(
            try std.mem.concat(alloc, u8, &.{ l_str, r_str }),
        );
        regWrite(regs, base, instr.a, result_str);
        return null;
    };

    // number + number fast path
    if (lhs.asNumOpt()) |ln| if (rhs.asNumOpt()) |rn| {
        const combined = try alloc.print("{d}{d}", .{ ln, rn });
        self.noteGCPressure(combined.len + @sizeOf(Value));
        regWrite(regs, base, instr.a, try self.adoptValueStringNoDedup(combined));
        return null;
    };

    // string + number fast path
    if (lhs.asStr()) |ls2| if (rhs.asNumOpt()) |rn| {
        const l_str = self.stringValue(ls2);
        var r_buf: [128]u8 = undefined;
        const r_str = std.mem.print(&r_buf, "{d}", .{rn}) catch blk: {
            break :blk try alloc.print("{d}", .{rn});
        };
        self.noteGCPressure(l_str.len + r_str.len + @sizeOf(Value));
        const combined = try std.mem.concat(alloc, u8, &.{ l_str, r_str });
        regWrite(regs, base, instr.a, try self.adoptValueStringNoDedup(combined));
        return null;
    };

    // number + string fast path
    if (lhs.asNumOpt()) |ln| if (rhs.asStr()) |rs2| {
        const r_str = self.stringValue(rs2);
        const combined = try alloc.print("{d}{s}", .{ ln, r_str });
        self.noteGCPressure(combined.len + @sizeOf(Value));
        regWrite(regs, base, instr.a, try self.adoptValueStringNoDedup(combined));
        return null;
    };
    // general: convert both to strings and concat
    //          same pattern as baselib's string()
    const l_src = (try toStringOperand(self, &fiber, &base, &regs, alloc, lhs)) orelse
        return self.fail(
            error.IncompatibleTypes,
            "cannot concatenate {s} and {s}",
            .{ revo.baselib.typeof(lhs, self), revo.baselib.typeof(rhs, self) },
        );
    defer alloc.free(l_src);

    const r_src = (try toStringOperand(self, &fiber, &base, &regs, alloc, rhs)) orelse
        return self.fail(
            error.IncompatibleTypes,
            "cannot concatenate {s} and {s}",
            .{ revo.baselib.typeof(lhs, self), revo.baselib.typeof(rhs, self) },
        );
    defer alloc.free(r_src);

    const result = try std.mem.concat(alloc, u8, &.{ l_src, r_src });
    regWrite(regs, base, instr.a, try self.adoptValueStringNoDedup(result));
    return null;
}

/// stringify an operand for concat: `__tostring` metamethod if it yields a
/// string, else a display render. null when the metamethod did not produce a
/// string, so the caller can report the concat failure.
noinline fn toStringOperand(
    self: *VM,
    fiber: **VM.Fiber,
    base: *usize,
    regs: *[]Value,
    alloc: std.mem.Allocator,
    operand: Value,
) VM.RunError!?[]u8 {
    if (try self.getMetamethodByAtom(operand, revo.CoreAtoms.__tostring.atomId())) |mm| {
        const call_result = revo.baselib.callUnaryMetamethod(mm, operand, self);
        fiber.* = self.currentFiber();
        base.* = fiber.*.top_base;
        regs.* = fiber.*.registers[0..fiber.*.registers_len];
        switch (call_result) {
            .ok => |data| {
                if (data.asStr()) |sid| return try alloc.dupe(u8, self.stringValue(sid));
            },
            .err => {},
        }
        return null;
    }
    var wbuf = std.Io.Writer.Allocating.init(alloc);
    defer wbuf.deinit();
    operand.write(&wbuf.writer, self, .plain, self.runtime.supports_color) catch return null;
    return try wbuf.toOwnedSlice();
}

noinline fn execSlice(self: *VM, regs: []Value, base: usize, instr: Instruction) VM.RunError!?VM.RunFailure {
    const object = regRead(regs, base, instr.b);
    const start_value = regRead(regs, base, instr.b + 1);
    const step_value = regRead(regs, base, instr.b + 2);
    const end_value = regRead(regs, base, instr.b + 3);

    const nil_atom = revo.CoreAtoms.atomId(.nil);

    const step_num = if (step_value.asAtom() == nil_atom)
        @as(f64, 1)
    else
        step_value.asNumOpt() orelse return self.typeError("number for slice step", step_value);

    const source_len: isize = switch (object.tag()) {
        .string => @intCast(self.stringValue(object.asString().?).len),
        .table => blk: {
            const t_id = object.asTable().?;
            const t = try self.tableFast(t_id);
            break :blk @intCast(t.array.items.len);
        },
        else => return self.typeError("string or table for slice", object),
    };

    const start_num = if (start_value.asAtom() == nil_atom)
        if (step_num > 0) @as(f64, 0) else @as(f64, @floatFromInt(source_len - 1))
    else
        start_value.asNumOpt() orelse return self.typeError("number for slice start", start_value);

    const end_num = if (end_value.asAtom() == nil_atom)
        if (step_num > 0) @as(f64, @floatFromInt(source_len)) else @as(f64, -1)
    else
        end_value.asNumOpt() orelse return self.typeError("number for slice end", end_value);

    if (!std.math.isFinite(start_num) or !std.math.isFinite(step_num) or !std.math.isFinite(end_num) or
        @floor(start_num) != start_num or @floor(step_num) != step_num or @floor(end_num) != end_num or
        step_num == 0)
    {
        return self.fail(error.TypeError, "slice bounds must be finite integers with a non-zero step", .{});
    }

    const start: isize = @intFromFloat(start_num);
    const step: isize = @intFromFloat(step_num);
    const end: isize = @intFromFloat(end_num);

    switch (object.tag()) {
        .string => {
            const source = self.stringValue(object.asString().?);

            var out = std.ArrayList(u8).initCapacity(self.runtime.alloc, 8) catch |err| return self.runFailure(err);
            defer out.deinit(self.runtime.alloc);
            var i = start;
            while ((step > 0 and i < end) or (step < 0 and i > end)) : (i += step) {
                if (i < 0 or @as(usize, @intCast(i)) >= source.len)
                    return self.fail(error.TypeError, "string slice index out of range", .{});
                try out.append(self.runtime.alloc, source[@intCast(i)]);
            }
            const data = try self.adoptValueString(try out.toOwnedSlice(self.runtime.alloc));
            regWrite(regs, base, instr.a, data);
        },
        .table => {
            const t_id = object.asTable().?;
            const src_t = try self.tableFast(t_id);
            const src = src_t.array.items;

            self.noteGCPressure(@sizeOf(revo.table.Table) + 64);
            const out_id = try self.tables.create();
            const out_t = try self.tableFast(out_id);
            var i = start;
            while ((step > 0 and i < end) or (step < 0 and i > end)) : (i += step) {
                if (i < 0 or @as(usize, @intCast(i)) >= src.len)
                    return self.fail(error.TypeError, "table slice index out of range", .{});
                try out_t.push(self.runtime.alloc, src[@intCast(i)]);
            }
            regWrite(regs, base, instr.a, Value.new.table(out_id));
        },
        else => return self.typeError("string or table for slice", object),
    }
    return null;
}

noinline fn execCallField(self: *VM, regs: []Value, base: usize, instr: Instruction) VM.RunError!void {
    const colon = (instr.b & 0x80) != 0;
    const explicit_argc: usize = instr.b & 0x7F;
    const object = regRead(regs, base, instr.a);
    const key = regRead(regs, base, instr.a + 1);

    const lookup_result = try self.resolveField(object, key, instr.a) orelse {
        const key_name = if (key.asAtom()) |atom| self.stringValue(atom) else revo.baselib.typeof(key, self);
        try self.setRuntimeMessageFmt("field `{s}` does not exist on {s}", .{ key_name, revo.baselib.typeof(object, self) });
        return error.NotAFunction;
    };

    // resolveField may run __index user code, which may have spawned and
    // reallocated the fibers array or grown registers
    const live = self.currentFiber();
    const live_regs = live.registers[0..live.registers_len];
    const live_base = live.top_base;

    if (colon) {
        regWrite(live_regs, live_base, instr.a, lookup_result.value);
        regWrite(live_regs, live_base, instr.a + 1, object);
        try self.callRegister(.{ .op = .call, .a = instr.a, .b = @intCast(explicit_argc + 1), .c = instr.c });
    } else {
        regWrite(live_regs, live_base, instr.a + 1, lookup_result.value);
        try self.callRegister(.{ .op = .call, .a = instr.a + 1, .b = @intCast(explicit_argc), .c = instr.c });
    }
}

noinline fn execClosure(
    self: *VM,
    regs: []Value,
    base: usize,
    instr: Instruction,
    alloc: std.mem.Allocator,
) VM.RunError!?VM.RunFailure {
    const fiber = self.currentFiber();
    const template = try self.callable.getTemplate(instr.bx);
    if (self.perfActive()) self.perf.closures_created += 1;
    self.noteGCPressure(@sizeOf(revo.callable.Closure) + @sizeOf(revo.callable.UpvalueID) * template.upvalue_specs.len);

    if (template.upvalue_specs.len <= 8) {
        var upv_buf: [8]revo.callable.UpvalueID = undefined;
        for (template.upvalue_specs, 0..) |spec, i| {
            if (spec.is_local) {
                const frame_base = fiber.top_base;
                upv_buf[i] = try self.captureUpvalue(frame_base + spec.index);
            } else {
                const closure2 = (try self.currentClosureIn(fiber)) orelse
                    return self.fail(error.TypeError, "expected closure", .{});
                upv_buf[i] = closure2.upvalues[spec.index];
            }
        }
        regWrite(
            regs,
            base,
            instr.a,
            Value.new.function(try self.callable.createClosure(instr.bx, upv_buf[0..template.upvalue_specs.len])),
        );
    } else {
        var list = try std.ArrayList(revo.callable.UpvalueID).initCapacity(alloc, template.upvalue_specs.len);
        errdefer list.deinit(alloc);
        for (template.upvalue_specs) |spec| {
            if (spec.is_local) {
                const frame_base = fiber.top_base;
                try list.append(alloc, try self.captureUpvalue(frame_base + spec.index));
            } else {
                const closure2 = (try self.currentClosureIn(fiber)) orelse
                    return self.fail(error.TypeError, "expected closure", .{});
                try list.append(alloc, closure2.upvalues[spec.index]);
            }
        }
        regWrite(regs, base, instr.a, Value.new.function(try self.callable.createClosure(instr.bx, list.items)));
        list.deinit(alloc);
    }
    return null;
}

noinline fn execPow(self: *VM, regs: []Value, base: usize, instr: Instruction) VM.RunError!?VM.RunFailure {
    const lhs = regRead(regs, base, instr.b);
    const rhs = regRead(regs, base, instr.c);
    if (lhs.asNumOpt()) |ln| if (rhs.asNumOpt()) |rn| {
        const li = revo.memory.numToI64(ln);
        const ri = revo.memory.numToI64(rn);
        if (li != null and ri != null and ri.? >= 0) {
            regWrite(regs, base, instr.a, Value.new.num(@as(f64, @floatFromInt(revo.memory.ipow(li.?, ri.?)))));
        } else {
            const result = std.math.pow(f64, ln, rn);
            if (std.math.isNan(result)) return self.fail(
                error.IncompatibleTypes,
                "cannot exponentiate {s} by {s}",
                .{ revo.baselib.typeof(lhs, self), revo.baselib.typeof(rhs, self) },
            );

            regWrite(regs, base, instr.a, Value.new.num(result));
        }
        return null;
    };
    return self.fail(
        error.IncompatibleTypes,
        "cannot exponentiate {s} by {s}",
        .{ revo.baselib.typeof(lhs, self), revo.baselib.typeof(rhs, self) },
    );
}

/// string * n fallback for .mul (numeric fast path stays inline)
noinline fn execStringRepeat(
    self: *VM,
    regs: []Value,
    base: usize,
    instr: Instruction,
    lhs: Value,
    rhs: Value,
    alloc: std.mem.Allocator,
) VM.RunError!?VM.RunFailure {
    const StrNum = struct { s: revo.memory.StringID, n: f64 };
    const str_and_num: ?StrNum = blk: {
        if (lhs.asStr()) |ls| if (rhs.asNumOpt()) |n|
            break :blk .{ .s = ls, .n = n };
        if (rhs.asStr()) |rs| if (lhs.asNumOpt()) |n|
            break :blk .{ .s = rs, .n = n };
        break :blk null;
    };
    if (str_and_num) |pair| {
        const str = self.stringValue(pair.s);
        const count: i64 = revo.memory.numToInt(i64, pair.n) orelse
            return self.fail(error.IncompatibleTypes, "cannot multiply string by non-integer number", .{});
        if (count < 0)
            return self.fail(error.IncompatibleTypes, "cannot multiply string by negative number", .{});
        const count_u: usize = @intCast(count);
        const total_len = std.math.mul(usize, str.len, count_u) catch
            return self.runFailure(error.OutOfMemory);
        self.noteGCPressure(total_len + @sizeOf(Value));
        const result = try alloc.alloc(u8, total_len);
        for (0..count_u) |i|
            @memcpy(result[i * str.len ..][0..str.len], str);
        regWrite(regs, base, instr.a, try self.adoptValueStringNoDedup(result));
        return null;
    }
    return self.fail(
        error.IncompatibleTypes,
        "cannot multiply {s} and {s}",
        .{ revo.baselib.typeof(lhs, self), revo.baselib.typeof(rhs, self) },
    );
}

const builtin = @import("builtin");
const std = @import("std");

const revo = @import("revo");

const compare_impl = @import("compare.zig");
const opcode = @import("opcode.zig");
const Instruction = opcode.Instruction;
const VM = @import("VM.zig");
const Value = VM.memory.Value;
const debug_assert_types = VM.debug_assert_types;
const regRead = VM.regRead;
const regWrite = VM.regWrite;
const lookup = VM.lookup;
