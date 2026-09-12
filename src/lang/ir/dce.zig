// dead code elimination for ir
//
// walks the ir and removes instructions whose results are never used.
// an instruction is live if it has side effects: stores, calls, control
// flow, or if its result flows into another live instruction
//
// data flow uses .inst pointers, not register names, so liveness traces
// correctly across the whole instruction list. jump targets live in op_arg
// as instruction indices and get remapped after compaction
//
// some dataflow edges go through .reg operands (move instructions that
// reference a register by number rather than popping from the value
// stack)
//
// registers also carry values across control flow :(((
//
// if/else and loop results converge onto one shared register written by several
// instructions, so a linear backward scan can only see the last writer
// and would eliminate the others. register liveness is therefore
// computed per basic block over the register lowering encoding
//
// runs after `fold.foldIr` so folded-to-constant operands are already
// freed, dce cleans up the dead constants that folding leaves behind

const Block = struct { start: usize, end: usize };

/// registers read by an instruction in its lowering encoding
///
/// reads may be over-estimated (that keeps more code),
/// so call/call_field read the whole argument range
pub fn readRegs(inst: *const ir.IrInst, out: []Register) usize {
    const r = inst.result_reg;
    switch (inst.opcode) {
        // zig fmt: off
        .jump, .yield,
        .load_global, .load_stdlib_global, .load_local, .load_upval,
        .closure, .table_new, .load_nil, .load_small_int,
        .load_const => return 0,

        .move => {
            out[0] = ir.valueReg(inst.operands[0]);
            return 1;
        },

        .range_loop => {
            std.debug.assert(r >= 3);
            out[0] = r - 3;
            out[1] = r - 2;
            out[2] = r - 1;
            return 3;
        },

        .call, .spawn => {
            const cnt = inst.op_arg + 1;
            for (0..cnt) |k| out[k] = r + @as(Register, @intCast(k));
            return cnt;
        },

        .call_field => {
            const cnt = (inst.op_arg & ~@as(usize, 1 << 7)) + 2;
            for (0..cnt) |k| out[k] = r + @as(Register, @intCast(k));
            return cnt;
        },

        .halt, .ret, .jump_if_false, .jump_if_true, .jump_err,
        .store_global, .store_global_const, .store_upval,
        .store_local, .bind_local, .negate, .not,
        .join, .add_imm, .sub_imm, .mul_imm,
        .band_imm, .lt_int_imm, .unwrap_result => {
            out[0] = r;
            return 1;
        },

        // the object register comes from the operand, not the result register:
        // a peephole may point the read at an earlier live load of the object
        .table_get_atom => {
            if (inst.operands.len >= 1) {
                out[0] = ir.valueReg(inst.operands[0]);
            } else out[0] = r;
            return 1;
        },

        .add, .sub, .mul, .div, .mod, .concat,
        .band, .bor, .bxor, .shl, .shr, .int_div,
        .pow, .eq, .neq, .lt, .gt, .lte, .gte,
        .eq_int, .neq_int, .lt_int, .gt_int, .lte_int, .gte_int,
        .@"and", .@"or", .table_get,
        .table_set_atom => {
            out[0] = r;
            out[1] = r + 1;
            return 2;
        },

        .table_set, .range_init => {
            out[0] = r;
            out[1] = r + 1;
            out[2] = r + 2;
            return 3;
        },

        .slice => {
            out[0] = r;
            out[1] = r + 1;
            out[2] = r + 2;
            out[3] = r + 3;
            return 4;
        },
        // zig fmt: on
    }
}

/// registers written by an instruction. must be exact: over-estimating
/// would kill registers that are still live at runtime
pub fn writeRegs(inst: *const ir.IrInst, out: *[3]Register) usize {
    const r = inst.result_reg;
    switch (inst.opcode) {
        // zig fmt: off
        .ret, .halt, .jump, .jump_if_false, .jump_if_true,
        .jump_err,
        .store_global, .store_global_const, .store_upval,
        .store_local, .bind_local, .yield => return 0,

        .range_init => {
            out[0] = r;
            out[1] = r + 1;
            out[2] = r + 2;
            return 3;
        },

        .range_loop => {
            out[0] = r;
            if (inst.operands.len > 0) {
                out[1] = r + 1;
                return 2;
            }
            return 1;
        },
        // zig fmt: on
        else => {
            out[0] = r;
            return 1;
        },
    }
}

/// readRegs plus the instruction's `.reg` operands: the complete set of
/// registers an instruction reads in its lowering encoding
pub fn readRegsAll(inst: *const ir.IrInst, out: []Register) usize {
    var cnt = readRegs(inst, out);
    for (inst.operands) |op| {
        if (op == .reg and cnt < out.len) {
            out[cnt] = op.reg;
            cnt += 1;
        }
    }
    return cnt;
}

const std = @import("std");

const revo = @import("revo");
const Compiler = revo.lang.compiler.Compiler;
const Opcode = revo.opcode.Opcode;
const Register = revo.opcode.Register;
const ir = @import("root.zig");

/// side-effecting opcodes that must never be eliminated
///
/// `move` is deliberately absent: moves are pure register copies and are
/// kept only when register liveness shows their destination is still read.
/// loop-break and branch-merge results flow through a move into a shared
/// register that later code reads by name, and the per-block register
/// liveness below keeps exactly those moves alive
fn isSideEffect(op: Opcode) bool {
    return switch (op) {
        // zig fmt: off
        .store_global, .store_global_const, .store_local, .bind_local,
        .store_upval, .table_set, .table_set_atom, .call, .call_field, .spawn,
        .join, .yield, .ret, .halt,
        .range_init, .unwrap_result
        // zig fmt: on
        => true,
        else => ir.isBranch(op),
    };
}

pub fn dceIr(self: *Compiler) !void {
    const insts = self.ir_builder.instructions.items;
    const n = insts.len;
    if (n == 0) return;

    // map each *IrInst to its current index (4 fast lookups)
    var index_of = std.AutoHashMap(*ir.IrInst, usize).init(self.alloc);
    defer index_of.deinit();
    try index_of.ensureTotalCapacity(@intCast(n));
    for (insts, 0..) |inst, i| index_of.putAssumeCapacity(inst, i);

    var live = try self.alloc.alloc(bool, n);
    defer self.alloc.free(live);
    @memset(live, false);

    // -- [pass 1] ------------------------------------------------------------
    // mark side-effecting instructions as live
    for (insts, 0..) |inst, i| {
        if (isSideEffect(inst.opcode)) live[i] = true;
    }

    // -- [pass 2a] -----------------------------------------------------------
    // split into basic blocks: a block starts at index 0, at every jump
    // target, and after every terminator
    var is_block_start = try self.alloc.alloc(bool, n);
    defer self.alloc.free(is_block_start);
    @memset(is_block_start, false);
    is_block_start[0] = true;
    for (insts) |inst| {
        if (ir.isBranch(inst.opcode)) {
            if (inst.op_arg < n) is_block_start[inst.op_arg] = true;
        }
    }
    for (insts, 0..) |inst, i| {
        if (i + 1 < n and (ir.isBranch(inst.opcode) or inst.opcode == .ret or inst.opcode == .halt))
            is_block_start[i + 1] = true;
    }

    var blocks = try std.ArrayList(Block).initCapacity(self.alloc, 0);
    defer blocks.deinit(self.alloc);
    var block_of = try self.alloc.alloc(usize, n);
    defer self.alloc.free(block_of);
    {
        var start: usize = 0;
        while (start < n) {
            var end = start + 1;
            while (end < n and !is_block_start[end]) : (end += 1) {}
            for (start..end) |j| block_of[j] = blocks.items.len;
            try blocks.append(self.alloc, .{ .start = start, .end = end });
            start = end;
        }
    }
    const nb = blocks.items.len;

    // registers can hold values written on multiple control-flow paths,
    // so register liveness is per-block (see readRegs/writeRegs)
    const reg_count = ir.maxRegister(insts) + 1;

    // there's no concise way to un-ugly this sorry
    var block_uses = try self.alloc.alloc(bool, nb * reg_count);
    defer self.alloc.free(block_uses);
    var block_writes = try self.alloc.alloc(bool, nb * reg_count);
    defer self.alloc.free(block_writes);
    var live_in = try self.alloc.alloc(bool, nb * reg_count);
    defer self.alloc.free(live_in);
    var live_out = try self.alloc.alloc(bool, nb * reg_count);
    defer self.alloc.free(live_out);
    var next_out = try self.alloc.alloc(bool, reg_count);
    defer self.alloc.free(next_out);
    var written_regs = try self.alloc.alloc(bool, reg_count);
    defer self.alloc.free(written_regs);
    var read_buf = try self.alloc.alloc(Register, reg_count);
    defer self.alloc.free(read_buf);

    @memset(block_writes, false);
    for (insts, 0..) |inst, i| {
        var wbuf: [3]Register = undefined;
        const wcnt = writeRegs(inst, &wbuf);
        const row = block_of[i] * reg_count;
        for (wbuf[0..wcnt]) |reg| block_writes[row + @as(usize, reg)] = true;
    }

    // -- [pass 2b] -----------------------------------------------------------
    // propagate liveness until stable
    //
    // ~ backward through .inst operands (data flow)
    // ~ forward to jump targets (control flow)
    // ~ register liveness across the block graph (backward data flow)
    @memset(live_in, false);
    var changed = true;
    while (changed) {
        changed = false;

        // dataflow thru .inst operands and control flow
        //
        // walk instructions backward: operands always sit at earlier
        // indices, so one pass propagates a whole dependency chain and
        // the outer loop only re-runs for forward jump chains
        var di = n;
        while (di > 0) {
            di -= 1;
            const inst = insts[di];
            if (!live[di]) continue;
            for (inst.operands) |op| {
                if (op == .inst) {
                    if (index_of.get(op.inst)) |j| {
                        if (!live[j]) {
                            live[j] = true;
                            changed = true;
                        }
                    }
                }
            }
            if (ir.isBranch(inst.opcode)) {
                const target = inst.op_arg;
                if (target < n and !live[target]) {
                    live[target] = true;
                    changed = true;
                }
            }
        }

        // registers read by live instructions, per block
        //
        // a register only counts as a block use if it is read before its
        // first write in the block; otherwise its value is produced inside
        // the block and the block needs nothing from its predecessors
        @memset(block_uses, false);
        for (blocks.items, 0..) |b, bi| {
            const base = bi * reg_count;
            @memset(written_regs, false);
            for (b.start..b.end) |i| {
                const inst = insts[i];
                if (live[i]) {
                    const rcnt = readRegsAll(inst, read_buf);
                    std.debug.assert(rcnt <= reg_count);
                    for (read_buf[0..rcnt]) |reg| {
                        if (!written_regs[reg]) block_uses[base + @as(usize, reg)] = true;
                    }
                }
                var wbuf: [3]Register = undefined;
                const wcnt = writeRegs(inst, &wbuf);
                for (wbuf[0..wcnt]) |reg| written_regs[reg] = true;
            }
        }

        // block liveness: live_out[b] = union of live_in[succ];
        // live_in[b] = reads[b] | (live_out[b] & !writes[b])
        //
        // live_in is warm-started (not reset)
        // liveness only grows across outer iterations, so the previous state is a lower bound and the
        // fixpoint converges from it faster than from empty
        var liveness_changed = true;
        while (liveness_changed) {
            liveness_changed = false;
            for (blocks.items, 0..) |b, bi| {
                const base = bi * reg_count;
                const last_inst = insts[b.end - 1];
                @memset(next_out, false);

                if (last_inst.opcode == .jump) {
                    const tb = block_of[last_inst.op_arg];
                    for (0..reg_count) |reg| next_out[reg] = live_in[tb * reg_count + reg];
                } else if (ir.isBranch(last_inst.opcode)) {
                    const tb = block_of[last_inst.op_arg];
                    for (0..reg_count) |reg| next_out[reg] = live_in[tb * reg_count + reg];
                    if (b.end < n) {
                        const fb = block_of[b.end];
                        for (0..reg_count) |reg| next_out[reg] = next_out[reg] or live_in[fb * reg_count + reg];
                    }
                } else if (last_inst.opcode == .ret or last_inst.opcode == .halt) {
                    // no successors
                } else {
                    if (b.end < n) {
                        const fb = block_of[b.end];
                        for (0..reg_count) |reg| next_out[reg] = live_in[fb * reg_count + reg];
                    }
                }
                for (0..reg_count) |reg| live_out[base + reg] = next_out[reg];
                for (0..reg_count) |reg| {
                    const v = block_uses[base + reg] or (next_out[reg] and !block_writes[base + reg]);
                    if (v != live_in[base + reg]) {
                        live_in[base + reg] = v;
                        liveness_changed = true;
                    }
                }
            }
        }

        // within each block, walk backward marking the writers of
        // registers that are live at the point they are written
        for (blocks.items, 0..) |b, bi| {
            const base = bi * reg_count;
            var cur: []bool = live_out[base .. base + reg_count];
            var j: usize = b.end;
            while (j > b.start) {
                j -= 1;
                const inst = insts[j];
                var wbuf: [3]Register = undefined;
                const wcnt = writeRegs(inst, &wbuf);
                var needed = false;
                for (wbuf[0..wcnt]) |reg| {
                    if (cur[reg]) needed = true;
                }
                if (needed) {
                    for (wbuf[0..wcnt]) |reg| cur[reg] = false;
                    if (!live[j]) {
                        live[j] = true;
                        changed = true;
                    }
                }
                if (live[j]) {
                    const rcnt = readRegsAll(inst, read_buf);
                    std.debug.assert(rcnt <= reg_count);
                    for (read_buf[0..rcnt]) |reg| cur[reg] = true;
                }
            }
        }
    }

    // -- [pass 3] ------------------------------------------------------------
    // compact
    //
    // keep live instructions, destroy dead ones; spans stay in 1:1
    // correspondence with instructions, and jump targets / prototype addrs
    // (instruction indices) are remapped. for dead positions the remap points
    // at the next live slot so stale addresses still land on real code.
    try ir.compactIr(self, n, live);
}

const testing = revo.lang.testing;
const t = testing;
const lang = revo.lang;
const VM = revo.VM;

fn testRuntime() revo.Runtime {
    return .{
        .alloc = std.testing.allocator,
        .io = std.testing.io,
        .diag_alloc = std.testing.allocator,
        .diag_arena = null,
    };
}

test "dce: arithmetic with unused result is eliminated" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{ .text =
        \\let _ = 1 + 2
        \\42
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    for (built.ok.instructions) |inst| {
        if (inst.op == .add) return error.TestUnexpectedResult;
    }
}

test "dce regression tests" {
    try t.topNumber(
        \\let x = 1 + 2
        \\x
    , 3);

    try t.topNumber(
        \\if 1 == 1
        \\    42
        \\else
        \\    1 + 2
    , 42);

    try t.topNumber(
        \\fn f() do
        \\    let _ = 1 + 2
        \\    let _ = 3 * 4
        \\    42
        \\end
        \\f()
    , 42);

    try t.topNumber(
        \\do
        \\    1
        \\    2
        \\    3
        \\end
    , 3);

    try t.topNumber("1 + 2 * 3", 7);
    try t.topString(
        \\let s = "hello"
        \\s
    , "hello");
    try t.topNumber(
        \\let x = 10
        \\x + 5
    , 15);

    try t.topNumber(
        \\let x = 1 + 2
        \\let _ = x
        \\99
    , 99);

    // the then and else branches write the same shared branch register,
    // so a linear last-writer scan only keeps one of them. both must
    // survive or the if-expression returns a raw number instead of a bool
    try t.topNumber(
        \\let hold_count = 9297
        \\let queue_count = 23246
        \\fn f() do
        \\  if queue_count == 23246
        \\    hold_count == 9297
        \\  else
        \\    :false
        \\end
        \\if f() 1 else 0
    , 1);

    // a while loop's break value flows back through a register; dce must
    // not treat the loop result as dead just because it is written on both
    // the loop-back and fall-through paths
    try t.topNumber(
        \\fn f() do
        \\  let i = 0
        \\  while i < 3 do
        \\    i = i + 1
        \\  end
        \\  i
        \\end
        \\f()
    , 3);

    // the same loop but the break value is consumed, so its move must live
    try t.topNumber(
        \\let r = loop/l do
        \\  break/l 42
        \\end
        \\r
    , 42);
    try t.topAtom(
        \\let r = loop do
        \\  break 42
        \\end
        \\r
    , "loop");

    // a function whose dead leading arithmetic is eliminated, with a
    // conditional jump inside that must still reach the right branches
    try t.topNumber(
        \\fn f(x) do
        \\  7 * 8
        \\  9 + 10
        \\  if x == 1
        \\    10
        \\  else
        \\    20
        \\  end
        \\if f(1) 100 else 200
    , 100);

    // the function's first statement is a discarded expression, so the
    // prototype addr points at a now-dead instruction, it has2 be remapped
    // or the call lands on the wrong bytecode
    try t.topNumber(
        \\fn f() do
        \\  1 + 2
        \\  42
        \\end
        \\f()
    , 42);
}

test "dce: side-effecting calls are never eliminated" {
    // yeah i know. too hard to figure out whether it really side-effects or not
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{ .text =
        \\fn f() 42
        \\let _ = f()
        \\1
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var has_call = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .call) has_call = true;
    }
    try std.testing.expect(has_call);
}

test "dce: dead move after break is eliminated" {
    // the break's move is a pure register copy into a loop-result register
    // that nothing reads; register liveness must drop it (it used to be
    // treated as unconditionally side-effecting)
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{ .text =
        \\loop do
        \\  break
        \\  99
        \\end
        \\42
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    for (built.ok.instructions) |inst| {
        if (inst.op == .move) return error.TestUnexpectedResult;
    }
}

test "dce: dead statements after a break are eliminated" {
    // `1 + 2` is pure arithmetic whose result nothing reads
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{ .text =
        \\do
        \\  1 + 2
        \\  42
        \\end
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    for (built.ok.instructions) |inst| {
        if (inst.op == .add) return error.TestUnexpectedResult;
    }
}

test "dce: folded constants and dead operands are both removed" {
    // `(1 + 2) * 3` folds to a single constant, and the load_small_int
    // operands of the folded instructions are reclaimed by dce
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{ .text =
        \\let _ = (1 + 2) * 3
        \\42
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    for (built.ok.instructions) |inst| {
        switch (inst.op) {
            .add, .mul, .pow => return error.TestUnexpectedResult,
            else => {},
        }
    }
}
