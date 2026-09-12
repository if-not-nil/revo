pub fn runReport(self: *VM) !@TypeOf(self.*).EvalResult {
    self.clearPanicMessage();
    self.clearRuntimeMessage();

    const fid = self.sched.current_fiber;
    const fiber = self.currentFiber();
    if (fiber.frames.items.len == 0) {
        try self.pushRootFrame(fiber, 16);
        fiber.registers_len = 16;
        @memset(fiber.registers[0..16], revo.Data.new.core(.missing));
    }

    self.sched.setFiberState(fid, .ready);
    try self.sched.enqueueRunnable(fid);

    while (true) {
        if (try runReadyFibers(self)) |failure| {
            return .{ .err = failure };
        }

        // wait errors become eval failures here so the main loop keeps a
        // narrow error set for its compile-time callers
        const live = waitForActivity(self) catch |e| return .{ .err = self.evalFailure(e) };
        if (!live) break;
    }
    return .ok;
}

/// one idle step of the main loop, shared by runReport and nested blocking
/// waits: wake due sleepers, then block briefly on io/sleep/channel
/// activity. false when nothing is left to wait for.
fn waitForActivity(self: *VM) VM.EvalError!bool {
    try self.sched.wakeDueSleepers(self.schedNowMonotonicNs());

    const has_sleepers = self.sched.sleepers.items.len > 0;
    const has_io_waiters = self.sched.io_waiters.items.len > 0;
    const has_waiting = self.sched.waiting_cnt > 0;
    const has_runnable = self.sched.ring_head != self.sched.ring_tail;

    if (!has_sleepers and !has_waiting and !has_runnable) {
        @branchHint(.unlikely);
        return false;
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
        else if (!has_io_waiters)
            1 // no sleepers and no io then don't block forever on the control pipe
        else
            -1;

        if (revo.has_async_backend) {
            _ = revo.async_backend_impl.pollAll(
                &self.runtime.async_backend,
                self,
                timeout_ms,
            ) catch return error.Panic;
        } else if (comptime !revo.is_freestanding) {
            _ = revo.std_net.pollIoWaiters(self, timeout_ms) catch
                return error.Panic;
        }

        try self.sched.wakeDueSleepers(self.schedNowMonotonicNs());
        return true;
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
        try self.sched.wakeDueSleepers(self.schedNowMonotonicNs());
    } else if (has_waiting) {
        // channel waiters without io backend, so yield to avoid busy-wait
        std.Io.sleep(
            self.runtime.io,
            std.Io.Duration.fromNanoseconds(std.time.ns_per_ms),
            .awake,
        ) catch {};
    }
    return true;
}

/// drive other fibers inline until target_id finishes
/// . a join nested inside a host call cannot suspend the host call stack
///   , so instead of parking it pumps the scheduler and blocks
/// . reports the first fiber failure seen.
fn pumpUntilDone(self: *VM, target_id: VM.FiberID) !?VM.EvalFailure {
    // runReadyFibers parks current_fiber on whatever ran last
    // , so restore ours on every exit
    // : the suspended dispatch below resumes on it
    const outer = self.sched.current_fiber;
    defer self.sched.current_fiber = outer;

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

inline fn runReadyFibers(self: *VM) !?@TypeOf(self.*).EvalFailure {
    while (self.sched.dequeueRunnable()) |fid| {
        @branchHint(.unlikely);
        self.sched.current_fiber = fid;
        if (self.currentFiber().state == .dead) continue;

        self.sched.setFiberState(fid, .running);
        self.currentFiber().running = true;

        // a fiber that parks mid-native (also when the native is reached
        // through a metamethod host call) suspends instead of failing: it is
        // .waiting and the io waiter re-queues it on completion
        if (execFiber(self) catch |e| {
            if (e == error.Parked) continue;
            return self.evalFailure(e);
        }) |failure| return failure;

        if (self.currentFiber().state == .ready) {
            @branchHint(.unlikely);
            try self.sched.enqueueRunnable(fid);
        }
    }
    return null;
}

/// computed-goto dispatch,,, runs current fiber until it yields, halts, or errors
inline fn execFiber(self: *VM) !?VM.EvalFailure {
    return execFiberGenericWithAlloc(self, self.runtime.alloc, false, 0);
}

/// runs dispatch until fiber.frames.items.len <= target_depth
pub inline fn execFiberUntilDepth(self: *VM, target_depth: usize) !?VM.EvalFailure {
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
) !?VM.EvalFailure {
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
) !?VM.EvalFailure {
    @setEvalBranchQuota(2000);
    var fiber = self.currentFiber();
    std.debug.assert(fiber.pc < fiber.program.len);
    var instr = fiber.program[fiber.pc];
    fiber.pc += 1;
    var base = fiber.top_base;
    var regs = fiber.registers[0..fiber.registers_len];

    dispatch: switch (instr.op) {
        .move => {
            const val = regRead(regs, base, instr.b);
            regWrite(regs, base, instr.a, val);

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .load_const => {
            std.debug.assert(instr.bx < self.constants.items.len);
            regWrite(regs, base, instr.a, self.constants.items[instr.bx]);

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .load_nil => {
            regWrite(regs, base, instr.a, revo.Data.new.core(.nil));

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .load_small_int => {
            regWrite(
                regs,
                base,
                instr.a,
                Data.new.num(@as(i64, @intCast(instr.bx))),
            );

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .add => {
            const lhs = regRead(regs, base, instr.b);
            const rhs = regRead(regs, base, instr.c);

            if (lhs.asNum()) |ln| if (rhs.asNum()) |rn| {
                regWrite(regs, base, instr.a, Data.new.num(ln + rn));

                if (!fetchNext(fiber, &instr)) break :dispatch;
                continue :dispatch instr.op;
            };

            return self.fail(
                error.IncompatibleTypes,
                "cannot add {s} and {s}",
                .{ revo.std_lib.typeof(lhs, self), revo.std_lib.typeof(rhs, self) },
            );
        },
        .concat => {
            if (try execConcat(self, regs, base, instr, alloc)) |failure| return failure;
            fiber = self.currentFiber();
            base = fiber.top_base;
            regs = fiber.registers[0..fiber.registers_len];

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .sub => {
            const lhs = regRead(regs, base, instr.b);
            const rhs = regRead(regs, base, instr.c);
            if (lhs.asNum()) |ln| if (rhs.asNum()) |rn| {
                regWrite(regs, base, instr.a, Data.new.num(ln - rn));

                if (!fetchNext(fiber, &instr)) break :dispatch;
                continue :dispatch instr.op;
            };
            return self.fail(
                error.IncompatibleTypes,
                "cannot subtract {s} from {s}",
                .{ revo.std_lib.typeof(rhs, self), revo.std_lib.typeof(lhs, self) },
            );
        },
        .mul => {
            const lhs = regRead(regs, base, instr.b);
            const rhs = regRead(regs, base, instr.c);
            if (lhs.asNum()) |ln| if (rhs.asNum()) |rn| {
                regWrite(regs, base, instr.a, Data.new.num(ln * rn));

                if (!fetchNext(fiber, &instr)) break :dispatch;
                continue :dispatch instr.op;
            };

            if (try execStringRepeat(self, regs, base, instr, lhs, rhs, alloc)) |failure| return failure;

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .div => {
            const lhs = regRead(regs, base, instr.b);
            const rhs = regRead(regs, base, instr.c);
            if (lhs.asNum()) |ln| if (rhs.asNum()) |rn| {
                if (rn == 0) return self.evalFailure(error.DivisionByZero);
                regWrite(regs, base, instr.a, Data.new.num(ln / rn));

                if (!fetchNext(fiber, &instr)) break :dispatch;
                continue :dispatch instr.op;
            };
            return self.fail(
                error.IncompatibleTypes,
                "cannot divide {s} by {s}",
                .{ revo.std_lib.typeof(lhs, self), revo.std_lib.typeof(rhs, self) },
            );
        },
        .mod => {
            const lhs = regRead(regs, base, instr.b);
            const rhs = regRead(regs, base, instr.c);
            if (lhs.asNum()) |ln| if (rhs.asNum()) |rn| {
                if (rn == 0) return self.evalFailure(error.DivisionByZero);
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
                        regWrite(regs, base, instr.a, Data.new.num(@as(f64, @floatFromInt(@mod(li, ri)))));
                        if (!fetchNext(fiber, &instr)) break :dispatch;
                        continue :dispatch instr.op;
                    }
                };
                regWrite(regs, base, instr.a, Data.new.num(@mod(ln, rn)));

                if (!fetchNext(fiber, &instr)) break :dispatch;
                continue :dispatch instr.op;
            };
            return self.fail(
                error.IncompatibleTypes,
                "cannot mod {s} by {s}",
                .{ revo.std_lib.typeof(lhs, self), revo.std_lib.typeof(rhs, self) },
            );
        },
        inline .band, .bor, .bxor => |op| {
            const lhs = regRead(regs, base, instr.b);
            const rhs = regRead(regs, base, instr.c);
            if (lhs.asNum()) |ln| if (rhs.asNum()) |rn| {
                if (revo.memory.numToI64(ln)) |li| if (revo.memory.numToI64(rn)) |ri| {
                    const result: i64 = switch (op) {
                        .band => li & ri,
                        .bor => li | ri,
                        else => li ^ ri,
                    };
                    regWrite(regs, base, instr.a, Data.new.num(@as(f64, @floatFromInt(result))));

                    if (!fetchNext(fiber, &instr)) break :dispatch;
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
                .{ revo.std_lib.typeof(lhs, self), revo.std_lib.typeof(rhs, self) },
            );
        },
        inline .shl, .shr => |op| {
            const lhs = regRead(regs, base, instr.b);
            const rhs = regRead(regs, base, instr.c);
            if (lhs.asNum()) |ln| if (rhs.asNum()) |rn| {
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
                    regWrite(regs, base, instr.a, Data.new.num(@as(f64, @floatFromInt(shifted))));

                    if (!fetchNext(fiber, &instr)) break :dispatch;
                    continue :dispatch instr.op;
                };
            };
            return self.fail(
                error.IncompatibleTypes,
                "cannot shift {s} by {s}",
                .{ revo.std_lib.typeof(lhs, self), revo.std_lib.typeof(rhs, self) },
            );
        },
        .int_div => {
            const lhs = regRead(regs, base, instr.b);
            const rhs = regRead(regs, base, instr.c);
            if (lhs.asNum()) |ln| if (rhs.asNum()) |rn| {
                if (rn == 0) return self.evalFailure(error.DivisionByZero);
                const li = revo.memory.numToI64(ln);
                const ri = revo.memory.numToI64(rn);
                if (li != null and ri != null) {
                    regWrite(regs, base, instr.a, Data.new.num(@as(f64, @floatFromInt(@divFloor(li.?, ri.?)))));
                } else {
                    regWrite(regs, base, instr.a, Data.new.num(@floor(ln / rn)));
                }

                if (!fetchNext(fiber, &instr)) break :dispatch;
                continue :dispatch instr.op;
            };
            return self.fail(
                error.IncompatibleTypes,
                "cannot divide {s} by {s}",
                .{ revo.std_lib.typeof(lhs, self), revo.std_lib.typeof(rhs, self) },
            );
        },
        .negate => {
            const v = regRead(regs, base, instr.b);
            if (v.asNum()) |n| {
                regWrite(regs, base, instr.a, Data.new.num(-n));

                if (!fetchNext(fiber, &instr)) break :dispatch;
                continue :dispatch instr.op;
            }
            return self.fail(error.IncompatibleTypes, "cannot negate {s}", .{revo.std_lib.typeof(v, self)});
        },
        .pow => {
            if (try execPow(self, regs, base, instr)) |failure| return failure;

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        inline .eq, .neq, .lt, .gt, .lte, .gte => |op| {
            try compare_impl.evalCachedFast(regs, base, self, instr, op);

            if (!fetchNext(fiber, &instr)) break :dispatch;
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
            regWrite(regs, base, instr.a, Data.new.boolean(result));

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .@"and" => {
            regWrite(regs, base, instr.a, Data.new.boolean(
                !revo.isFalse(regRead(regs, base, instr.b)) and
                    !revo.isFalse(regRead(regs, base, instr.c)),
            ));

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .@"or" => {
            regWrite(regs, base, instr.a, Data.new.boolean(
                !revo.isFalse(regRead(regs, base, instr.b)) or
                    !revo.isFalse(regRead(regs, base, instr.c)),
            ));

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .not => {
            regWrite(regs, base, instr.a, Data.new.boolean(revo.isFalse(regRead(regs, base, instr.b))));

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .table_new => {
            self.noteGCPressure(@sizeOf(revo.table.Table) + 64);
            regWrite(regs, base, instr.a, Data.new.table(try self.tables.create()));

            if (!fetchNext(fiber, &instr)) break :dispatch;
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

            if (!fetchNext(fiber, &instr)) break :dispatch;
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
                } else regWrite(regs, base, instr.a, revo.Data.new.core(.undef));
            } else if (try self.resolveField(object, key, instr.a)) |resolved| {
                fiber = self.currentFiber();
                base = fiber.top_base;
                regs = fiber.registers[0..fiber.registers_len];
                regWrite(regs, base, instr.a, resolved.value);
            } else regWrite(regs, base, instr.a, revo.Data.new.core(.undef));

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .slice => {
            if (try execSlice(self, regs, base, instr)) |failure| return failure;

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .table_set_atom => {
            const table_value = regRead(regs, base, instr.a);
            const t_id = table_value.asTable() orelse
                return self.typeError("table", table_value);

            const t = try self.tableFast(t_id);
            const key = Data.new.atom(instr.bx);
            try t.put(t_id, self, key, regRead(regs, base, instr.c));

            // put may run __newindex user code, which may have spawned
            fiber = self.currentFiber();

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .table_get_atom => {
            const object = regRead(regs, base, instr.b);
            const key = Data.new.atom(instr.bx);

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
                    regWrite(regs, base, instr.a, revo.Data.new.core(.undef));
                }
            } else if (try self.resolveField(object, key, instr.a)) |resolved| {
                fiber = self.currentFiber();
                base = fiber.top_base;
                regs = fiber.registers[0..fiber.registers_len];
                regWrite(regs, base, instr.a, resolved.value);
            } else {
                regWrite(regs, base, instr.a, revo.Data.new.core(.undef));
            }

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .jump => {
            fiber.pc = instr.bx;

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .jump_if_false => {
            @branchHint(.unlikely);

            if (revo.isFalse(regRead(regs, base, instr.a))) fiber.pc = instr.bx;

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .jump_if_true => {
            @branchHint(.unlikely);

            if (!revo.isFalse(regRead(regs, base, instr.a))) fiber.pc = instr.bx;

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .load_global => {
            const value = self.globals.get(instr.bx) orelse
                return self.fail(error.UndefinedVariable, "undefined variable `{s}`", .{self.stringValue(instr.bx)});
            regWrite(regs, base, instr.a, value);

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .load_stdlib_global => {
            const value = self.stdlib_globals.get(instr.bx) orelse
                return self.fail(
                    error.UndefinedVariable,
                    "undefined stdlib variable `{s}`",
                    .{self.stringValue(instr.bx)},
                );

            regWrite(regs, base, instr.a, value);

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        inline .store_global, .store_global_const => |op| {
            if (self.const_globals.contains(instr.bx))
                return self.fail(error.ConstantReassignment, "reassignment to constant!", .{});
            const val = regRead(regs, base, instr.a);
            try self.globals.put(instr.bx, val);
            if (op == .store_global_const) try self.const_globals.put(instr.bx, {});

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .load_local, .bind_local, .store_local => {
            const dst = base + instr.a;
            const src = base + instr.b;
            if (builtin.mode != .ReleaseFast and src >= regs.len) {
                regWrite(regs, base, instr.a, revo.Data.new.core(.missing));
            } else {
                regs[dst] = regs[src];
            }

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .closure => {
            if (try execClosure(self, regs, base, instr, alloc)) |failure| return failure;

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .load_upval => {
            const closure2 = (try self.currentClosure()) orelse return self.evalFailure(error.InvalidLocal);
            regWrite(regs, base, instr.a, try self.loadUpvalueData(closure2.upvalues[instr.bx]));

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .store_upval => {
            const closure2 = (try self.currentClosure()) orelse return self.evalFailure(error.InvalidLocal);
            try self.storeUpvalueData(closure2.upvalues[instr.bx], regRead(regs, base, instr.a));

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .call => {
            self.callRegister(instr) catch |e| {
                if (e == error.Parked) return e;
                return self.evalFailure(e);
            };
            // callRegister runs user code, which may have spawned and
            // reallocated the fibers array or grown registers
            fiber = self.currentFiber();
            base = fiber.top_base;
            regs = fiber.registers[0..fiber.registers_len];

            if (if (comptime use_depth) fiber.frames.items.len <= target_depth else !fiber.running) {
                if (switchOrStop(self, use_depth, &fiber, &regs, &base, &instr)) {
                    continue :dispatch instr.op;
                }
                break :dispatch;
            }
            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .call_field => {
            execCallField(self, regs, base, instr) catch |e| {
                if (e == error.Parked) return e;
                return self.evalFailure(e);
            };
            // execCallField runs user code, same hazard as .call above
            fiber = self.currentFiber();
            base = fiber.top_base;
            regs = fiber.registers[0..fiber.registers_len];

            if (if (comptime use_depth) fiber.frames.items.len <= target_depth else !fiber.running) {
                if (switchOrStop(self, use_depth, &fiber, &regs, &base, &instr)) {
                    continue :dispatch instr.op;
                }
                break :dispatch;
            }
            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .ret => {
            self.returnRegister(instr) catch |e| return self.evalFailure(e);
            if (fiber.frames.items.len == 0) {
                if (switchOrStop(self, use_depth, &fiber, &regs, &base, &instr)) {
                    continue :dispatch instr.op;
                }
                break :dispatch;
            }
            base = fiber.top_base;
            regs = fiber.registers[0..fiber.registers_len];

            if (if (comptime use_depth) fiber.frames.items.len <= target_depth else !fiber.running) break :dispatch;
            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .spawn => {
            self.spawnRegister(instr, base) catch |e| return self.evalFailure(e);
            // spawnRegister may have reallocated fibers
            fiber = self.currentFiber();
            regs = fiber.registers[0..fiber.registers_len];
            base = fiber.top_base;

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .join => {
            const handle = regRead(regs, base, instr.a);
            const target_num = handle.asNum() orelse
                return self.typeError("number in join", handle);
            const target_id: usize = if (revo.memory.numToI64(target_num)) |tid|
                if (tid < 0) return self.fail(error.TypeError, "invalid fiber id in join", .{}) else @intCast(tid)
            else
                return self.fail(error.TypeError, "invalid fiber id in join", .{});
            if (target_id >= self.sched.fibers.items.len)
                return self.fail(error.TypeError, "fiber id out of range", .{});
            const target = &self.sched.fibers.items[target_id];
            if (target.state == .dead) {
                regWrite(regs, base, instr.a, target.result);
            } else if (comptime use_depth) {
                // nested join (inside a host call): the host call stack
                // cannot suspend, so drive other fibers inline until the
                // target finishes instead of parking
                if (try pumpUntilDone(self, target_id)) |failure| return failure;
                // pumped fibers may have spawned: re-fetch everything
                fiber = self.currentFiber();
                base = fiber.top_base;
                regs = fiber.registers[0..fiber.registers_len];
                const done = &self.sched.fibers.items[target_id];
                regWrite(regs, base, instr.a, done.result);
            } else {
                try target.waiters.append(alloc, self.sched.current_fiber);
                self.sched.parkCurrentWithResult(.{ .join = target_id }, base + instr.a);
            }

            if (if (comptime use_depth) fiber.frames.items.len <= target_depth else !fiber.running) {
                if (switchOrStop(self, use_depth, &fiber, &regs, &base, &instr)) {
                    continue :dispatch instr.op;
                }
                break :dispatch;
            }
            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .yield => {
            self.sched.setFiberState(self.sched.current_fiber, .ready);
            fiber.running = false;
            if (comptime use_depth) break :dispatch;
            if (self.sched.ring_head == self.sched.ring_tail) {
                // nothing else runnable
                // keep running in place instead of a round trip through runq
                fiber.running = true;
                if (!fetchNext(fiber, &instr)) break :dispatch;
                continue :dispatch instr.op;
            }
            try self.sched.enqueueRunnable(self.sched.current_fiber);
            if (switchOrStop(self, false, &fiber, &regs, &base, &instr)) {
                continue :dispatch instr.op;
            }
            break :dispatch;
        },
        .halt => {
            const result = regRead(regs, base, instr.a);
            fiber.registers_len = 0;
            try self.push(result);
            fiber.running = false;
            self.sched.setFiberState(self.sched.current_fiber, .dead);
            if (switchOrStop(self, use_depth, &fiber, &regs, &base, &instr)) {
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

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .range_loop => {
            const current: f64 = @bitCast((regRead(regs, base, instr.b)).bits);
            const step: f64 = @bitCast((regRead(regs, base, instr.b + 1)).bits);
            const limit: f64 = @bitCast((regRead(regs, base, instr.b + 2)).bits);

            const has_next = (step > 0 and current < limit) or (step < 0 and current > limit);

            if (has_next) {
                regWrite(regs, base, instr.a, Data.new.num(current));
                if (instr.c != 0) {
                    const index_reg = regRead(regs, base, instr.c);
                    const index: f64 = blk: {
                        const n = index_reg.asNum() orelse break :blk 0.0;
                        break :blk if (std.math.isFinite(n)) n else 0.0;
                    };
                    regWrite(regs, base, instr.c, Data.new.num(index + 1));
                }
                regWrite(regs, base, instr.b, Data.new.num(current + step));
                fiber.pc = instr.bx;
            }

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .unwrap_result => {
            const val = regRead(regs, base, instr.a);
            const propagate_errors = instr.bx == 0;

            const parts = self.resultParts(val);
            if (parts == null) {
                if (!fetchNext(fiber, &instr)) break :dispatch;
                continue :dispatch instr.op;
            }
            const tag = parts.?.tag;
            const payload = parts.?.payload;

            if (tag.asAtom() == revo.core_atoms.atomId(.err)) {
                if (propagate_errors) {
                    if (fiber.frames.items.len == 2) {
                        self.panicFromErrPayload(payload, fiber.pc) catch |e| return self.evalFailure(e);
                        return self.evalFailure(error.Panic);
                    }
                    self.returnRegister(.{ .op = .ret, .a = instr.a }) catch |e| return self.evalFailure(e);

                    if (fiber.frames.items.len == 0) break :dispatch;
                    base = fiber.top_base;
                    regs = fiber.registers[0..fiber.registers_len];

                    if (!fetchNext(fiber, &instr)) break :dispatch;
                    continue :dispatch instr.op;
                }

                if (!fetchNext(fiber, &instr)) break :dispatch;
                continue :dispatch instr.op;
            }

            if (tag.asAtom() == revo.core_atoms.atomId(.ok)) {
                if (payload) |p| {
                    regWrite(regs, base, instr.a, p);
                }
            }

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .jump_err => {
            const val = regRead(regs, base, instr.a);
            const is_err = self.isErrTable(val);
            const absent = if (val.asAtom()) |a|
                a == revo.core_atoms.atomId(.nil) or
                    a == revo.core_atoms.atomId(.undef)
            else
                false;
            if (!absent and !is_err) fiber.pc = instr.bx;

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        inline .add_imm, .sub_imm, .mul_imm, .band_imm => |op| {
            const lhs_val = regRead(regs, base, instr.b);
            if (debug_assert_types) std.debug.assert(lhs_val.isNumber());
            const li: i64 = revo.memory.numToI64(@as(f64, @bitCast(lhs_val.bits))) orelse
                return self.fail(error.TypeError, "expected integer, got {s}", .{revo.std_lib.typeof(lhs_val, self)});
            const ri: i64 = @intCast(instr.bx);
            const result: i64 = switch (op) {
                .add_imm => li + ri,
                .sub_imm => li - ri,
                .mul_imm => li * ri,
                .band_imm => li & ri,
                else => unreachable,
            };
            regWrite(regs, base, instr.a, Data.new.num(@as(f64, @floatFromInt(result))));

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .lt_int_imm => {
            const lhs_val = regRead(regs, base, instr.b);
            const lhs: f64 = @bitCast(lhs_val.bits);
            const rhs: i64 = @intCast(instr.bx);
            regWrite(regs, base, instr.a, Data.new.boolean(lhs < @as(f64, @floatFromInt(rhs))));

            if (!fetchNext(fiber, &instr)) break :dispatch;
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
) align(4096) !?VM.EvalFailure {
    return execFiberDispatch(self, alloc, use_depth, target_depth);
}

/// fetch next instruction into `instr`, advance fiber pc. returns false if program ended
///
/// for some reason, making this void or textually inlining makes it slower. idk why
inline fn fetchNext(fiber: *VM.Fiber, instr: *Instruction) bool {
    if (fiber.pc >= fiber.program.len) return false;
    instr.* = fiber.program[fiber.pc];
    fiber.pc += 1;
    return true;
}

inline fn switchOrStop(
    self: *VM,
    comptime use_depth: bool,
    fiber: **VM.Fiber,
    regs: *[]Data,
    base: *usize,
    instr: *Instruction,
) bool {
    if (comptime use_depth) return false;
    if (self.sched.switchNext()) {
        fiber.* = self.currentFiber();
        base.* = fiber.*.top_base;
        regs.* = fiber.*.registers[0..fiber.*.registers_len];
        return fetchNext(fiber.*, instr);
    }
    return false;
}

//
// -- [cold handlers] ---------------------------------------------------------
// pulled outta the dispatch loop so the hot opcodes stay small in the icache
//
// each returns an error-union `?EvalFailure`: null
// on success, an EvalFailure to report, or an error to unwrap via evalFailure

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
    regs_in: []Data,
    base_in: usize,
    instr: Instruction,
    alloc: std.mem.Allocator,
) VM.EvalError!?VM.EvalFailure {
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

            self.noteGCPressure(total_len + @sizeOf(Data));
            const buf = try alloc.alloc(u8, total_len);
            var off: usize = 0;
            for (0..n) |j| {
                const s = self.stringValue(op_ids[j]);
                @memcpy(buf[off..][0..op_lens[j]], s);
                off += op_lens[j];
            }
            const result = try self.adoptDataStringNoDedup(buf);
            regWrite(regs, base, prev_a, result);
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

        self.noteGCPressure(l_str.len + r_str.len + @sizeOf(Data));
        const result_str = try self.adoptDataStringNoDedup(
            try std.mem.concat(alloc, u8, &.{ l_str, r_str }),
        );
        regWrite(regs, base, instr.a, result_str);
        return null;
    };

    // number + number fast path
    if (lhs.asNum()) |ln| if (rhs.asNum()) |rn| {
        const combined = try std.fmt.allocPrint(alloc, "{d}{d}", .{ ln, rn });
        self.noteGCPressure(combined.len + @sizeOf(Data));
        regWrite(regs, base, instr.a, try self.adoptDataStringNoDedup(combined));
        return null;
    };

    // string + number fast path
    if (lhs.asStr()) |ls2| if (rhs.asNum()) |rn| {
        const l_str = self.stringValue(ls2);
        var r_buf: [128]u8 = undefined;
        const r_str = std.fmt.bufPrint(&r_buf, "{d}", .{rn}) catch blk: {
            break :blk try std.fmt.allocPrint(alloc, "{d}", .{rn});
        };
        self.noteGCPressure(l_str.len + r_str.len + @sizeOf(Data));
        const combined = try std.mem.concat(alloc, u8, &.{ l_str, r_str });
        regWrite(regs, base, instr.a, try self.adoptDataStringNoDedup(combined));
        return null;
    };

    // number + string fast path
    if (lhs.asNum()) |ln| if (rhs.asStr()) |rs2| {
        const r_str = self.stringValue(rs2);
        const combined = try std.fmt.allocPrint(alloc, "{d}{s}", .{ ln, r_str });
        self.noteGCPressure(combined.len + @sizeOf(Data));
        regWrite(regs, base, instr.a, try self.adoptDataStringNoDedup(combined));
        return null;
    };
    // general: convert both to strings and concat
    //          same pattern as stdlib's string()
    const l_src = (try toStringOperand(self, &fiber, &base, &regs, alloc, lhs)) orelse
        return self.fail(
            error.IncompatibleTypes,
            "cannot concatenate {s} and {s}",
            .{ revo.std_lib.typeof(lhs, self), revo.std_lib.typeof(rhs, self) },
        );
    defer alloc.free(l_src);

    const r_src = (try toStringOperand(self, &fiber, &base, &regs, alloc, rhs)) orelse
        return self.fail(
            error.IncompatibleTypes,
            "cannot concatenate {s} and {s}",
            .{ revo.std_lib.typeof(lhs, self), revo.std_lib.typeof(rhs, self) },
        );
    defer alloc.free(r_src);

    const result = try std.mem.concat(alloc, u8, &.{ l_src, r_src });
    regWrite(regs, base, instr.a, try self.adoptDataStringNoDedup(result));
    return null;
}

/// stringify an operand for concat: `__tostring` metamethod if it yields a
/// string, else a display render. null when the metamethod did not produce a
/// string, so the caller can report the concat failure.
noinline fn toStringOperand(
    self: *VM,
    fiber: **VM.Fiber,
    base: *usize,
    regs: *[]Data,
    alloc: std.mem.Allocator,
    operand: Data,
) VM.EvalError!?[]u8 {
    if (try self.getMetamethodByAtom(operand, revo.core_atoms.__tostring.atomId())) |mm| {
        const call_result = revo.std_lib.callUnaryMetamethod(mm, operand, self);
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
    operand.write(&wbuf.writer, self, .display) catch return null;
    return try wbuf.toOwnedSlice();
}

noinline fn execSlice(self: *VM, regs: []Data, base: usize, instr: Instruction) VM.EvalError!?VM.EvalFailure {
    const object = regRead(regs, base, instr.b);
    const start_value = regRead(regs, base, instr.b + 1);
    const step_value = regRead(regs, base, instr.b + 2);
    const end_value = regRead(regs, base, instr.b + 3);

    const nil_atom = revo.core_atoms.atomId(.nil);

    const step_num = if (step_value.asAtom() == nil_atom)
        @as(f64, 1)
    else
        step_value.asNum() orelse return self.typeError("number for slice step", step_value);

    const source_len: isize = switch (object.tag()) {
        .string => @intCast(self.stringValue(object.asString().?).len),
        else => return self.typeError("string for slice", object),
    };

    const start_num = if (start_value.asAtom() == nil_atom)
        if (step_num > 0) @as(f64, 0) else @as(f64, @floatFromInt(source_len - 1))
    else
        start_value.asNum() orelse return self.typeError("number for slice start", start_value);

    const end_num = if (end_value.asAtom() == nil_atom)
        if (step_num > 0) @as(f64, @floatFromInt(source_len)) else @as(f64, -1)
    else
        end_value.asNum() orelse return self.typeError("number for slice end", end_value);

    if (!std.math.isFinite(start_num) or !std.math.isFinite(step_num) or !std.math.isFinite(end_num) or
        @floor(start_num) != start_num or @floor(step_num) != step_num or @floor(end_num) != end_num or
        step_num == 0)
        return self.fail(error.TypeError, "slice bounds must be finite integers with a non-zero step", .{});

    switch (object.tag()) {
        .string => {
            const source = self.stringValue(object.asString().?);
            const start: isize = @intFromFloat(start_num);
            const step: isize = @intFromFloat(step_num);
            const end: isize = @intFromFloat(end_num);
            var out = std.ArrayList(u8).initCapacity(self.runtime.alloc, 8) catch |err| return self.evalFailure(err);
            defer out.deinit(self.runtime.alloc);
            var i = start;
            while ((step > 0 and i < end) or (step < 0 and i > end)) : (i += step) {
                if (i < 0 or @as(usize, @intCast(i)) >= source.len)
                    return self.fail(error.TypeError, "string slice index out of range", .{});
                try out.append(self.runtime.alloc, source[@intCast(i)]);
            }
            const data = try self.adoptDataString(try out.toOwnedSlice(self.runtime.alloc));
            regWrite(regs, base, instr.a, data);
        },
        else => return self.typeError("string for slice", object),
    }
    return null;
}

noinline fn execCallField(self: *VM, regs: []Data, base: usize, instr: Instruction) VM.EvalError!void {
    const colon = (instr.b & 0x80) != 0;
    const explicit_argc: usize = instr.b & 0x7F;
    const object = regRead(regs, base, instr.a);
    const key = regRead(regs, base, instr.a + 1);

    const lookup_result = try self.resolveField(object, key, instr.a) orelse {
        const key_name = if (key.asAtom()) |atom| self.stringValue(atom) else revo.std_lib.typeof(key, self);
        try self.setRuntimeMessageFmt("field `{s}` does not exist on {s}", .{ key_name, revo.std_lib.typeof(object, self) });
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
    regs: []Data,
    base: usize,
    instr: Instruction,
    alloc: std.mem.Allocator,
) VM.EvalError!?VM.EvalFailure {
    const fiber = self.currentFiber();
    const proto = try self.functions.getPrototype(instr.bx);
    self.noteGCPressure(@sizeOf(revo.functions.Closure) + @sizeOf(revo.functions.UpvalueID) * proto.upvalue_specs.len);

    if (proto.upvalue_specs.len <= 8) {
        var upv_buf: [8]revo.functions.UpvalueID = undefined;
        for (proto.upvalue_specs, 0..) |spec, i| {
            if (spec.is_local) {
                const frame_base = fiber.top_base;
                upv_buf[i] = try self.captureUpvalue(frame_base + spec.index);
            } else {
                const closure2 = (try self.currentClosure()) orelse
                    return self.fail(error.TypeError, "expected closure", .{});
                upv_buf[i] = closure2.upvalues[spec.index];
            }
        }
        regWrite(
            regs,
            base,
            instr.a,
            Data.new.function(try self.functions.createClosure(instr.bx, upv_buf[0..proto.upvalue_specs.len])),
        );
    } else {
        var list = try std.ArrayList(revo.functions.UpvalueID).initCapacity(alloc, proto.upvalue_specs.len);
        errdefer list.deinit(alloc);
        for (proto.upvalue_specs) |spec| {
            if (spec.is_local) {
                const frame_base = fiber.top_base;
                try list.append(alloc, try self.captureUpvalue(frame_base + spec.index));
            } else {
                const closure2 = (try self.currentClosure()) orelse
                    return self.fail(error.TypeError, "expected closure", .{});
                try list.append(alloc, closure2.upvalues[spec.index]);
            }
        }
        regWrite(regs, base, instr.a, Data.new.function(try self.functions.createClosure(instr.bx, list.items)));
        list.deinit(alloc);
    }
    return null;
}

noinline fn execPow(self: *VM, regs: []Data, base: usize, instr: Instruction) VM.EvalError!?VM.EvalFailure {
    const lhs = regRead(regs, base, instr.b);
    const rhs = regRead(regs, base, instr.c);
    if (lhs.asNum()) |ln| if (rhs.asNum()) |rn| {
        const li = revo.memory.numToI64(ln);
        const ri = revo.memory.numToI64(rn);
        if (li != null and ri != null and ri.? >= 0) {
            regWrite(regs, base, instr.a, Data.new.num(@as(f64, @floatFromInt(revo.memory.ipow(li.?, ri.?)))));
        } else {
            const result = std.math.pow(f64, ln, rn);
            if (std.math.isNan(result)) return self.fail(
                error.IncompatibleTypes,
                "cannot exponentiate {s} by {s}",
                .{ revo.std_lib.typeof(lhs, self), revo.std_lib.typeof(rhs, self) },
            );

            regWrite(regs, base, instr.a, Data.new.num(result));
        }
        return null;
    };
    return self.fail(
        error.IncompatibleTypes,
        "cannot exponentiate {s} by {s}",
        .{ revo.std_lib.typeof(lhs, self), revo.std_lib.typeof(rhs, self) },
    );
}

noinline fn execPowFloat(self: *VM, regs: []Data, base: usize, instr: Instruction) VM.EvalError!?VM.EvalFailure {
    const lhs = regRead(regs, base, instr.b);
    const rhs = regRead(regs, base, instr.c);
    if (debug_assert_types) {
        std.debug.assert(lhs.isNumber());
        std.debug.assert(rhs.isNumber());
    }
    const ln: f64 = @bitCast(lhs.bits);
    const rn: f64 = @bitCast(rhs.bits);
    const result = std.math.pow(f64, ln, rn);
    if (std.math.isNan(result)) return self.fail(
        error.IncompatibleTypes,
        "cannot exponentiate {s} by {s}",
        .{ revo.std_lib.typeof(lhs, self), revo.std_lib.typeof(rhs, self) },
    );

    regWrite(regs, base, instr.a, Data.new.num(result));
    return null;
}

/// string * n fallback for .mul (numeric fast path stays inline)
noinline fn execStringRepeat(
    self: *VM,
    regs: []Data,
    base: usize,
    instr: Instruction,
    lhs: Data,
    rhs: Data,
    alloc: std.mem.Allocator,
) VM.EvalError!?VM.EvalFailure {
    const StrNum = struct { s: revo.memory.StringID, n: f64 };
    const str_and_num: ?StrNum = blk: {
        if (lhs.asStr()) |ls| if (rhs.asNum()) |n|
            break :blk .{ .s = ls, .n = n };
        if (rhs.asStr()) |rs| if (lhs.asNum()) |n|
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
            return self.evalFailure(error.OutOfMemory);
        self.noteGCPressure(total_len + @sizeOf(Data));
        const result = try alloc.alloc(u8, total_len);
        for (0..count_u) |i|
            @memcpy(result[i * str.len ..][0..str.len], str);
        regWrite(regs, base, instr.a, try self.adoptDataStringNoDedup(result));
        return null;
    }
    return self.fail(
        error.IncompatibleTypes,
        "cannot multiply {s} and {s}",
        .{ revo.std_lib.typeof(lhs, self), revo.std_lib.typeof(rhs, self) },
    );
}

const std = @import("std");
const builtin = @import("builtin");

const revo = @import("revo");

const compare_impl = @import("compare.zig");
const opcode = @import("opcode.zig");
const Instruction = opcode.Instruction;
const VM = @import("VM.zig");
const Data = VM.memory.Data;
const debug_assert_types = VM.debug_assert_types;
const regRead = VM.regRead;
const regWrite = VM.regWrite;
const lookup = VM.lookup;
