const std = @import("std");
const builtin = @import("builtin");
const revo = @import("revo");
const opcode = @import("opcode.zig");
const Instruction = opcode.Instruction;
const VM = @import("VM.zig");
const compare_impl = @import("compare.zig");
const Data = VM.memory.Data;
const debug_assert_types = VM.debug_assert_types;
const regRead = VM.regRead;
const regWrite = VM.regWrite;

pub fn runReport(self: *VM) !@TypeOf(self.*).EvalResult {
    self.clearPanicMessage();
    self.clearRuntimeMessage();

    if (self.mainFiber().frames_hot.items.len == 0) {
        if (self.mainFiber().debug_info_id == null)
            self.mainFiber().debug_info_id = self.pending_debug_info_id;

        try self.mainFiber().frames_hot.append(self.runtime.alloc, .{
            .return_addr = @intCast(self.mainFiber().program.len),
            .base = 0,
            .program = self.mainFiber().program,
        });
        try self.mainFiber().frames_cold.append(self.runtime.alloc, .{
            .call_site_pc = null,
            .result_register = 0,
            .register_count = 16,
            .closure_id = null,
        });
        const fiber = self.mainFiber();
        fiber.registers_len = 16;
        @memset(fiber.registers[0..16], revo.core_atoms.data(.missing));
    }

    self.sched.setFiberState(0, .ready);
    try self.sched.enqueueRunnable(0);

    while (true) {
        if (try runReadyFibers(self)) |failure| {
            return .{ .err = failure };
        }

        try self.sched.wakeDueSleepers(self.schedNowMonotonicNs());

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

            try self.sched.wakeDueSleepers(self.schedNowMonotonicNs());
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
            try self.sched.wakeDueSleepers(self.schedNowMonotonicNs());
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

        if (execFiber(self) catch |e| return self.evalFailure(e)) |failure| return failure;

        if (self.currentFiber().state == .ready) {
            @branchHint(.unlikely);
            try self.sched.enqueueRunnable(fid);
        }
    }
    return null;
}

/// computed-goto dispatch,,, runs current fiber until it yields, halts, or errors
pub inline fn execFiber(self: *VM) !?VM.EvalFailure {
    return execFiberGeneric(self, false, 0);
}

/// runs dispatch until fiber.frames_hot.items.len <= target_depth
pub inline fn execFiberUntilDepth(self: *VM, target_depth: usize) !?VM.EvalFailure {
    return execFiberGeneric(self, true, target_depth);
}

fn execFiberGeneric(self: *VM, comptime use_depth: bool, target_depth: usize) !?VM.EvalFailure {
    var fiber = self.currentFiber();
    const alloc = self.runtime.alloc;

    if (fiber.pc >= fiber.program.len) return null;
    var instr = fiber.program[fiber.pc];
    fiber.pc += 1;

    var base = fiber.frames_hot.items[fiber.frames_hot.items.len - 1].base;
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
            regWrite(regs, base, instr.a, revo.core_atoms.data(.nil));

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

            if (lhs.asStr()) |ls| if (rhs.asStr()) |rs| {
                const l_str = self.stringValue(ls);
                const r_str = self.stringValue(rs);
                self.noteGCPressure(l_str.len + r_str.len + @sizeOf(Data));
                const result_str = try self.adoptDataStringNoDedup(
                    try std.mem.concat(alloc, u8, &.{ l_str, r_str }),
                );
                regWrite(regs, base, instr.a, result_str);

                if (!fetchNext(fiber, &instr)) break :dispatch;
                continue :dispatch instr.op;
            };

            try self.setRuntimeMessageFmt("cannot add {s} and {s}", .{ revo.std_lib.dataToString(lhs), revo.std_lib.dataToString(rhs) });
            return self.evalFailure(error.IncompatibleTypes);
        },
        .sub => {
            const lhs = regRead(regs, base, instr.b);
            const rhs = regRead(regs, base, instr.c);
            if (lhs.asNum()) |ln| if (rhs.asNum()) |rn| {
                regWrite(regs, base, instr.a, Data.new.num(ln - rn));

                if (!fetchNext(fiber, &instr)) break :dispatch;
                continue :dispatch instr.op;
            };
            try self.setRuntimeMessageFmt("cannot subtract {s} from {s}", .{ revo.std_lib.dataToString(rhs), revo.std_lib.dataToString(lhs) });
            return self.evalFailure(error.IncompatibleTypes);
        },
        .mul => {
            const slots = regs;
            const lhs = regRead(slots, base, instr.b);
            const rhs = regRead(slots, base, instr.c);
            if (lhs.asNum()) |ln| if (rhs.asNum()) |rn| {
                regWrite(slots, base, instr.a, Data.new.num(ln * rn));

                if (!fetchNext(fiber, &instr)) break :dispatch;
                continue :dispatch instr.op;
            };
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
                const count: usize = @intCast(
                    std.math.clamp(@as(i64, @intFromFloat(pair.n)), 0, std.math.maxInt(i32)),
                );
                _ = std.math.mul(usize, str.len, count) catch
                    return self.evalFailure(error.OutOfMemory);
                self.noteGCPressure(str.len * count + @sizeOf(Data));
                const result = try alloc.alloc(u8, str.len * count);
                for (0..count) |i|
                    @memcpy(result[i * str.len ..][0..str.len], str);
                regWrite(slots, base, instr.a, try self.adoptDataStringNoDedup(result));

                if (!fetchNext(fiber, &instr)) break :dispatch;
                continue :dispatch instr.op;
            }
            try self.setRuntimeMessageFmt("cannot multiply {s} and {s}", .{ revo.std_lib.dataToString(lhs), revo.std_lib.dataToString(rhs) });
            return self.evalFailure(error.IncompatibleTypes);
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
            try self.setRuntimeMessageFmt("cannot divide {s} by {s}", .{ revo.std_lib.dataToString(lhs), revo.std_lib.dataToString(rhs) });
            return self.evalFailure(error.IncompatibleTypes);
        },
        .mod => {
            const lhs = regRead(regs, base, instr.b);
            const rhs = regRead(regs, base, instr.c);
            if (lhs.asNum()) |ln| if (rhs.asNum()) |rn| {
                if (rn == 0) return self.evalFailure(error.DivisionByZero);
                regWrite(regs, base, instr.a, Data.new.num(@mod(ln, rn)));

                if (!fetchNext(fiber, &instr)) break :dispatch;
                continue :dispatch instr.op;
            };
            try self.setRuntimeMessageFmt("cannot mod {s} by {s}", .{ revo.std_lib.dataToString(lhs), revo.std_lib.dataToString(rhs) });
            return self.evalFailure(error.IncompatibleTypes);
        },
        .mod_int => {
            const lhs = regRead(regs, base, instr.b);
            const rhs = regRead(regs, base, instr.c);
            if (debug_assert_types) {
                std.debug.assert(lhs.isNumber());
                std.debug.assert(rhs.isNumber());
            }
            const li = @as(i64, @intFromFloat(@as(f64, @bitCast(lhs.bits))));
            const ri = @as(i64, @intFromFloat(@as(f64, @bitCast(rhs.bits))));
            if (ri == 0) return self.evalFailure(error.DivisionByZero);
            regWrite(regs, base, instr.a, Data.new.num(@as(f64, @floatFromInt(@mod(li, ri)))));

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .negate => {
            const v = regRead(regs, base, instr.b);
            if (v.asNum()) |n| {
                regWrite(regs, base, instr.a, Data.new.num(-n));

                if (!fetchNext(fiber, &instr)) break :dispatch;
                continue :dispatch instr.op;
            }
            try self.setRuntimeMessageFmt("cannot negate {s}", .{revo.std_lib.dataToString(v)});
            return self.evalFailure(error.IncompatibleTypes);
        },
        .negate_int => {
            const v = regRead(regs, base, instr.b);
            if (debug_assert_types) std.debug.assert(v.isNumber());
            const v_int = @as(i64, @intFromFloat(@as(f64, @bitCast(v.bits))));
            regWrite(regs, base, instr.a, Data.new.num(@as(f64, @floatFromInt(-v_int))));

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .negate_float => {
            const v = regRead(regs, base, instr.b);
            if (debug_assert_types) std.debug.assert(v.isNumber());
            regWrite(regs, base, instr.a, Data.new.num(-@as(f64, @bitCast(v.bits))));

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .add_int => {
            const lhs = regRead(regs, base, instr.b);
            const rhs = regRead(regs, base, instr.c);
            if (debug_assert_types) {
                std.debug.assert(lhs.isNumber());
                std.debug.assert(rhs.isNumber());
            }
            const li = @as(i64, @intFromFloat(@as(f64, @bitCast(lhs.bits))));
            const ri = @as(i64, @intFromFloat(@as(f64, @bitCast(rhs.bits))));
            regWrite(regs, base, instr.a, Data.new.num(@as(f64, @floatFromInt(li + ri))));

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .sub_int => {
            const lhs = regRead(regs, base, instr.b);
            const rhs = regRead(regs, base, instr.c);
            if (debug_assert_types) {
                std.debug.assert(lhs.isNumber());
                std.debug.assert(rhs.isNumber());
            }
            const li = @as(i64, @intFromFloat(@as(f64, @bitCast(lhs.bits))));
            const ri = @as(i64, @intFromFloat(@as(f64, @bitCast(rhs.bits))));
            regWrite(regs, base, instr.a, Data.new.num(@as(f64, @floatFromInt(li - ri))));

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .mul_int => {
            const lhs = regRead(regs, base, instr.b);
            const rhs = regRead(regs, base, instr.c);
            if (debug_assert_types) {
                std.debug.assert(lhs.isNumber());
                std.debug.assert(rhs.isNumber());
            }
            const li = @as(i64, @intFromFloat(@as(f64, @bitCast(lhs.bits))));
            const ri = @as(i64, @intFromFloat(@as(f64, @bitCast(rhs.bits))));
            regWrite(regs, base, instr.a, Data.new.num(@as(f64, @floatFromInt(li * ri))));

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .div_float => {
            const lhs = regRead(regs, base, instr.b);
            const rhs = regRead(regs, base, instr.c);
            if (debug_assert_types) {
                std.debug.assert(lhs.isNumber());
                std.debug.assert(rhs.isNumber());
            }
            if (@as(f64, @bitCast(rhs.bits)) == 0) return self.evalFailure(error.DivisionByZero);
            regWrite(regs, base, instr.a, Data.new.num(@as(f64, @bitCast(lhs.bits)) / @as(f64, @bitCast(rhs.bits))));

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
            const lhs = @as(i64, @intFromFloat(@as(f64, @bitCast(lhs_val.bits))));
            const rhs = @as(i64, @intFromFloat(@as(f64, @bitCast(rhs_val.bits))));

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
            if (key.asAtom()) |atom| {
                if (try self.setStructField(table_value, atom, regRead(regs, base, instr.c))) {
                    if (!fetchNext(fiber, &instr)) break :dispatch;
                    continue :dispatch instr.op;
                }
            }
            const t_id = table_value.asTable() orelse return self.evalFailure(error.TypeError);
            const t = try self.tableFast(t_id);
            try t.put(t_id, self, key, regRead(regs, base, instr.c));

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .table_get => {
            const object = regRead(regs, base, instr.b);
            const key = regRead(regs, base, instr.c);
            if (object.asTable()) |t_id| {
                const t = try self.tableFast(t_id);
                if (t.getRaw(key)) |value| {
                    regWrite(regs, base, instr.a, value);

                    if (!fetchNext(fiber, &instr)) break :dispatch;
                    continue :dispatch instr.op;
                }
            }
            if (try self.resolveField(object, key)) |resolved| {
                regWrite(regs, base, instr.a, resolved.value);
            } else regWrite(regs, base, instr.a, revo.core_atoms.data(.undef));

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .table_set_atom => {
            const table_value = regRead(regs, base, instr.a);
            if (try self.setStructField(table_value, instr.bx, regRead(regs, base, instr.c))) {
                if (!fetchNext(fiber, &instr)) break :dispatch;
                continue :dispatch instr.op;
            }
            const t_id = table_value.asTable() orelse return self.evalFailure(error.TypeError);
            const t = try self.tableFast(t_id);
            const key = Data.new.atom(instr.bx);
            try t.put(t_id, self, key, regRead(regs, base, instr.c));

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .table_get_atom => {
            const object = regRead(regs, base, instr.b);
            const key = Data.new.atom(instr.bx);

            if (object.asTable()) |t_id| {
                const pc = fiber.pc - 1;
                const ic = &self.icache[pc & (self.icache.len - 1)];
                const t = try self.tableFast(t_id);

                if (ic.pc == pc and ic.table_id == t_id and ic.version == t.ic_version) {
                    @branchHint(.likely);
                    regWrite(regs, base, instr.a, ic.value);
                } else if (t.getRaw(key)) |value| {
                    ic.* = .{ .pc = pc, .table_id = t_id, .version = t.ic_version, .value = value };
                    regWrite(regs, base, instr.a, value);
                } else if (try self.resolveField(object, key)) |resolved| {
                    ic.* = .{ .pc = pc, .table_id = t_id, .version = t.ic_version, .value = resolved.value };
                    regWrite(regs, base, instr.a, resolved.value);
                } else {
                    regWrite(regs, base, instr.a, revo.core_atoms.data(.undef));
                }
            } else if (try self.resolveField(object, key)) |resolved| {
                regWrite(regs, base, instr.a, resolved.value);
            } else {
                regWrite(regs, base, instr.a, revo.core_atoms.data(.undef));
            }

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .tuple_new => {
            const start = base + instr.b;
            const count: usize = instr.bx;
            self.noteGCPressure(@sizeOf(revo.tuple.Tuple) + @sizeOf(Data) * count);
            regWrite(regs, base, instr.a, Data.new.tuple(try self.tuples.create(regs[start .. start + count])));

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .tuple_get => {
            const tuple_id = (regRead(regs, base, instr.b)).asTuple() orelse return self.evalFailure(error.TypeError);
            const idx_val = regRead(regs, base, instr.c);
            const idx_num = idx_val.asNum() orelse return self.evalFailure(error.TypeError);
            if (idx_num < 0 or @floor(idx_num) != idx_num) return self.evalFailure(error.TypeError);
            if (idx_num > @as(f64, @floatFromInt(std.math.maxInt(usize)))) return self.evalFailure(error.TypeError);
            const idx: usize = @intFromFloat(idx_num);
            const t = try self.tuples.get(tuple_id);
            if (idx >= t.items.len) {
                try self.setRuntimeMessageFmt("tuple index {d} out of range for tuple of length {d}", .{ idx, t.items.len });
                return self.evalFailure(error.InvalidTuple);
            }
            regWrite(regs, base, instr.a, t.items[idx]);

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .tuple_get_const => {
            const tuple_id = (regRead(regs, base, instr.b)).asTuple() orelse return self.evalFailure(error.TypeError);
            const t = try self.tuples.get(tuple_id);
            if (instr.bx >= t.items.len) {
                try self.setRuntimeMessageFmt("tuple index {d} out of range for tuple of length {d}", .{ instr.bx, t.items.len });
                return self.evalFailure(error.InvalidTuple);
            }
            regWrite(regs, base, instr.a, t.items[instr.bx]);

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .struct_new => {
            const type_id: revo.StructTypeID = instr.bx;
            const desc = self.struct_types.getType(type_id) orelse {
                try self.setRuntimeMessage("invalid struct type");
                return self.evalFailure(error.Panic);
            };
            const instance_id = try self.struct_instances.create(type_id, desc.fields.len);
            const instance = self.structGetInstance(instance_id) catch return self.evalFailure(error.Panic);
            for (desc.fields, 0..) |f, i| {
                if (f.default_val) |dv| instance.fields[i] = dv;
            }
            regWrite(regs, base, instr.a, Data.new.structVal(instance_id));

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .struct_set_method => {
            const type_val = regRead(regs, base, instr.a);
            const type_id = type_val.asStructType() orelse return self.evalFailure(error.TypeError);
            const name_atom_data = regRead(regs, base, instr.b);
            const name_atom = name_atom_data.asAtom() orelse return self.evalFailure(error.TypeError);
            const method = regRead(regs, base, instr.c);
            const desc = self.struct_types.getType(type_id) orelse return self.evalFailure(error.TypeError);
            try desc.methods.put(self.atomName(name_atom), method);

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .struct_get_offset => {
            const object = regRead(regs, base, instr.b);
            const instance_id = object.asStructVal() orelse return self.evalFailure(error.TypeError);
            const instance = self.structGetInstance(instance_id) catch return self.evalFailure(error.Panic);
            regWrite(regs, base, instr.a, instance.get(instr.bx));

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .struct_set_offset => {
            const object = regRead(regs, base, instr.a);
            const instance_id = object.asStructVal() orelse return self.evalFailure(error.TypeError);
            const instance = self.structGetInstance(instance_id) catch return self.evalFailure(error.Panic);
            const value = regRead(regs, base, instr.c);
            instance.set(instr.bx, value);
            regWrite(regs, base, instr.a, Data.new.structVal(instance_id));

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
            const value = self.globals.get(instr.bx) orelse {
                try self.setRuntimeMessageFmt("undefined variable `{s}`", .{self.atomName(instr.bx)});
                return self.evalFailure(error.UndefinedVariable);
            };
            regWrite(regs, base, instr.a, value);

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .load_stdlib_global => {
            const value = self.stdlib_globals.get(instr.bx) orelse {
                try self.setRuntimeMessageFmt("undefined stdlib variable `{s}`", .{self.atomName(instr.bx)});
                return self.evalFailure(error.UndefinedVariable);
            };
            regWrite(regs, base, instr.a, value);

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .store_global => {
            if (self.const_globals.contains(instr.bx)) {
                try self.setRuntimeMessage("reassignment to constant!");
                return self.evalFailure(error.ConstantReassignment);
            }
            const val = regRead(regs, base, instr.a);
            try self.globals.put(instr.bx, val);

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .store_global_const => {
            if (self.const_globals.contains(instr.bx)) {
                try self.setRuntimeMessage("reassignment to constant!");
                return self.evalFailure(error.ConstantReassignment);
            }
            const val = regRead(regs, base, instr.a);
            try self.globals.put(instr.bx, val);
            try self.const_globals.put(instr.bx, {});

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .load_local, .bind_local => {
            const dst = base + instr.a;
            const src = base + instr.b;
            if (builtin.mode != .ReleaseFast and src >= regs.len) {
                regWrite(regs, base, instr.a, revo.core_atoms.data(.missing));
            } else {
                regs[dst] = regs[src];
            }

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .store_local => {
            if (try self.currentClosure()) |closure| blk: {
                const proto = try self.functions.getPrototype(closure.prototype);
                const idx = instr.a / 8;
                if (idx >= proto.const_local_bits.len) break :blk;
                const bit: u3 = @intCast(instr.a % 8);
                if ((proto.const_local_bits[idx] & (@as(u8, 1) << bit)) != 0) return self.evalFailure(error.ConstantReassignment);
            }
            const dst = base + instr.a;
            const src = base + instr.b;
            if (builtin.mode != .ReleaseFast and src >= regs.len) {
                regWrite(regs, base, instr.a, revo.core_atoms.data(.missing));
            } else {
                regs[dst] = regs[src];
            }

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .closure => {
            const proto = try self.functions.getPrototype(instr.bx);
            self.noteGCPressure(@sizeOf(revo.functions.Closure) + @sizeOf(revo.functions.UpvalueID) * proto.upvalue_specs.len);

            var upv_buf: [8]revo.functions.UpvalueID = undefined;
            const upvalues = if (proto.upvalue_specs.len <= 8) blk: {
                for (proto.upvalue_specs, 0..) |spec, i| {
                    if (spec.is_local) {
                        const frame_base = fiber.frames_hot.items[fiber.frames_hot.items.len - 1].base;
                        upv_buf[i] = try self.captureUpvalue(frame_base + spec.index);
                    } else {
                        const closure2 = (try self.currentClosure()) orelse return self.evalFailure(error.TypeError);
                        upv_buf[i] = closure2.upvalues[spec.index];
                    }
                }
                break :blk upv_buf[0..proto.upvalue_specs.len];
            } else blk: {
                var list = try std.ArrayList(revo.functions.UpvalueID).initCapacity(alloc, proto.upvalue_specs.len);
                defer list.deinit(alloc);
                for (proto.upvalue_specs) |spec| {
                    if (spec.is_local) {
                        const frame_base = fiber.frames_hot.items[fiber.frames_hot.items.len - 1].base;
                        try list.append(alloc, try self.captureUpvalue(frame_base + spec.index));
                    } else {
                        const closure2 = (try self.currentClosure()) orelse return self.evalFailure(error.TypeError);
                        try list.append(alloc, closure2.upvalues[spec.index]);
                    }
                }
                break :blk list.items;
            };
            regWrite(regs, base, instr.a, Data.new.function(try self.functions.createClosure(instr.bx, upvalues)));

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
            self.callRegister(instr) catch |e| switch (e) {
                error.Parked => break :dispatch,
                else => return self.evalFailure(e),
            };
            base = fiber.frames_hot.items[fiber.frames_hot.items.len - 1].base;
            regs = fiber.registers[0..fiber.registers_len];

            if (if (comptime use_depth) fiber.frames_hot.items.len <= target_depth else !fiber.running) break :dispatch;
            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .call_field => {
            const colon = (instr.b & 0x80) != 0;
            const explicit_argc: usize = instr.b & 0x7F;
            const object = regRead(regs, base, instr.a);
            const key = regRead(regs, base, instr.a + 1);

            const lookup_result = (try self.resolveField(object, key)) orelse {
                const key_name = if (key.asAtom()) |atom| self.atomName(atom) else revo.std_lib.dataToString(key);
                try self.setRuntimeMessageFmt("field `{s}` does not exist on {s}", .{ key_name, revo.std_lib.typeof(object) });
                return self.evalFailure(error.NotAFunction);
            };

            if (colon) {
                regWrite(regs, base, instr.a, lookup_result.value);
                regWrite(regs, base, instr.a + 1, object);
                self.callRegister(.{ .op = .call, .a = instr.a, .b = @intCast(explicit_argc + 1), .c = instr.c }) catch |e| switch (e) {
                    error.Parked => break :dispatch,
                    else => return self.evalFailure(e),
                };
            } else {
                regWrite(regs, base, instr.a + 1, lookup_result.value);
                self.callRegister(.{ .op = .call, .a = instr.a + 1, .b = @intCast(explicit_argc), .c = instr.c }) catch |e| switch (e) {
                    error.Parked => break :dispatch,
                    else => return self.evalFailure(e),
                };
            }

            base = fiber.frames_hot.items[fiber.frames_hot.items.len - 1].base;
            regs = fiber.registers[0..fiber.registers_len];

            if (if (comptime use_depth) fiber.frames_hot.items.len <= target_depth else !fiber.running) break :dispatch;
            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .ret => {
            self.returnRegister(instr) catch |e| return self.evalFailure(e);
            if (fiber.frames_hot.items.len == 0) break :dispatch;
            base = fiber.frames_hot.items[fiber.frames_hot.items.len - 1].base;
            regs = fiber.registers[0..fiber.registers_len];

            if (if (comptime use_depth) fiber.frames_hot.items.len <= target_depth else !fiber.running) break :dispatch;
            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .spawn => {
            self.spawnRegister(instr, base) catch |e| return self.evalFailure(e);
            // spawnRegister may have reallocated fibers
            fiber = self.currentFiber();
            regs = fiber.registers[0..fiber.registers_len];
            base = fiber.frames_hot.items[fiber.frames_hot.items.len - 1].base;

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .join => {
            const handle = regRead(regs, base, instr.a);
            const target_num = handle.asNum() orelse return self.evalFailure(error.TypeError);
            const target_id = if (target_num >= 0 and @floor(target_num) == target_num)
                @as(usize, @intFromFloat(target_num))
            else
                return self.evalFailure(error.TypeError);
            if (target_id >= self.sched.fibers.items.len)
                return self.evalFailure(error.TypeError);
            const target = &self.sched.fibers.items[target_id];
            if (target.state == .dead) {
                regWrite(regs, base, instr.a, target.result);
            } else {
                try target.waiters.append(alloc, self.sched.current_fiber);
                self.sched.parkCurrentWithResult(.{ .join = target_id }, base + instr.a);
            }

            if (if (comptime use_depth) fiber.frames_hot.items.len <= target_depth else !fiber.running) break :dispatch;
            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .yield => {
            self.sched.setFiberState(self.sched.current_fiber, .ready);
            fiber.running = false;
            break :dispatch;
        },
        .halt => {
            const result = regRead(regs, base, instr.a);
            fiber.registers_len = 0;
            try self.push(result);
            fiber.running = false;
            self.sched.setFiberState(self.sched.current_fiber, .dead);
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
        .range_next => {
            const current = @as(f64, @bitCast((regRead(regs, base, instr.b)).bits));
            const step = @as(f64, @bitCast((regRead(regs, base, instr.b + 1)).bits));
            const limit = @as(f64, @bitCast((regRead(regs, base, instr.b + 2)).bits));

            const has_next = (step > 0 and current < limit) or (step < 0 and current > limit);

            regWrite(regs, base, instr.a, Data.new.num(current));
            if (instr.c != 0) {
                const index_reg = regRead(regs, base, instr.c);
                const index = index_reg.asNum() orelse 0.0;
                if (has_next) regWrite(regs, base, instr.c, Data.new.num(index + 1));
            }
            regWrite(regs, base, @intCast(instr.bx), Data.new.boolean(has_next));

            if (has_next) regWrite(regs, base, instr.b, Data.new.num(current + step));

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .range_for => {
            var current = (regRead(regs, base, instr.a)).as_number() catch return self.evalFailure(error.TypeError);
            const step = (regRead(regs, base, instr.b)).as_number() catch return self.evalFailure(error.TypeError);
            const limit = (regRead(regs, base, instr.c)).as_number() catch return self.evalFailure(error.TypeError);
            const max_iter: f64 = @floatFromInt(instr.bx);

            var i: f64 = 0;
            while (i < max_iter) {
                const done = (step > 0 and current > limit) or (step < 0 and current < limit);
                if (done) break;
                current += step;
                i += 1;
            }
            regWrite(regs, base, instr.a, Data.new.num(current));

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .unwrap_result => {
            const val = regRead(regs, base, instr.a);
            const propagate_errors = instr.bx == 0;

            const tuple_id = if (val.asTuple()) |tid| tid else {
                if (!fetchNext(fiber, &instr)) break :dispatch;
                continue :dispatch instr.op;
            };
            const tuple = try self.tuples.get(tuple_id);
            if (tuple.items.len == 0) {
                if (!fetchNext(fiber, &instr)) break :dispatch;
                continue :dispatch instr.op;
            }

            const tag = tuple.items[0];

            if (tag.asAtom() == revo.core_atoms.atom_id(.err)) {
                if (propagate_errors) {
                    if (fiber.frames_hot.items.len == 2) {
                        if (tuple.items.len > 1) {
                            var buf = std.Io.Writer.Allocating.init(alloc);
                            defer buf.deinit();
                            tuple.items[1].write(&buf.writer, self, .display) catch |err| switch (err) {
                                error.OutOfMemory => return self.evalFailure(error.OutOfMemory),
                                else => return self.evalFailure(error.Panic),
                            };
                            self.setPanicMessageOwned(try buf.toOwnedSlice());
                        }
                        self.panic_span = if (self.currentDebugInfo()) |debug|
                            self.spanAtPc(debug, if (fiber.pc > 0) fiber.pc - 1 else 0)
                        else
                            null;
                        return self.evalFailure(error.Panic);
                    }
                    self.returnRegister(.{ .op = .ret, .a = instr.a }) catch |e| return self.evalFailure(e);

                    if (fiber.frames_hot.items.len == 0) break :dispatch;
                    base = fiber.frames_hot.items[fiber.frames_hot.items.len - 1].base;
                    regs = fiber.registers[0..fiber.registers_len];

                    if (!fetchNext(fiber, &instr)) break :dispatch;
                    continue :dispatch instr.op;
                }

                if (!fetchNext(fiber, &instr)) break :dispatch;
                continue :dispatch instr.op;
            }

            if (tag.asAtom() == revo.core_atoms.atom_id(.ok)) {
                if (tuple.items.len > 1) {
                    regWrite(regs, base, instr.a, tuple.items[1]);
                }
            }

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .jump_if_not_nil_and_not_err => {
            const val = regRead(regs, base, instr.a);
            const is_nil = if (val.asAtom()) |a| a == revo.core_atoms.atom_id(.nil) else false;
            const is_err = if (val.asTuple()) |tid| blk: {
                const tuple2 = try self.tuples.get(tid);
                if (tuple2.items.len > 0) {
                    const tag2 = tuple2.items[0];
                    break :blk tag2.asAtom() == revo.core_atoms.atom_id(.err);
                }
                break :blk false;
            } else false;

            if (!is_nil and !is_err) fiber.pc = instr.bx;

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
        .jump_if_err => {
            const val = regRead(regs, base, instr.a);
            const is_err = if (val.asTuple()) |tid| blk: {
                const tuple2 = try self.tuples.get(tid);
                if (tuple2.items.len > 0) {
                    const tag2 = tuple2.items[0];
                    break :blk tag2.asAtom() == revo.core_atoms.atom_id(.err);
                }
                break :blk false;
            } else false;

            if (is_err) fiber.pc = instr.bx;

            if (!fetchNext(fiber, &instr)) break :dispatch;
            continue :dispatch instr.op;
        },
    }
    return null;
}

/// fetch next instruction into `instr`, advance fiber pc. returns false if program ended
inline fn fetchNext(fiber: *VM.Fiber, instr: *Instruction) bool {
    if (fiber.pc >= fiber.program.len) return false;
    instr.* = fiber.program[fiber.pc];
    fiber.pc += 1;
    return true;
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
    for (fiber.registers[0..fiber.registers_len]) |item| {
        item.print(self);
        std.debug.print(" ", .{});
    }
    std.debug.print("]\n", .{});
}
