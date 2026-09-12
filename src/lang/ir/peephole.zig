// zlint-disable line-length -- yeah
//! local peephole pass over ir, runs after dce.dceIr
//!
//! `fold.foldIr` folds constant expressions and `dce.dceIr` drops dead
//! instructions, but a few patterns survive
//! ~ redundant copies: `move rA, rA`, and moves whose destination register
//!   is overwritten again before anything reads it
//! ~ identity and annihilator arithmetic that fold misses because one side
//!   is not a constant (`x + 0`, `x * 1`, `x * 0`)
//! ~ control flow: jumps that chain into other jumps, conditional jumps
//!   immediately followed by an unconditional jump, and jumps that land on
//!   the very next instruction
//!
//! deletes instructions in place and compacts at the end, remapping jump
//! targets and function entry points exactly like dce.dceIr
//!
//! the identity folds drop the operand's runtime type check (a dynamic
//! `x + 0` with a non-number x would error in the vm and now silently
//! yields x), the number-safe identities are folded, annihilators only for
//! the typed int opcodes where string/float fallbacks cannot apply

const std = @import("std");

const revo = @import("revo");
const Compiler = revo.lang.compiler.Compiler;
const Opcode = revo.opcode.Opcode;
const Operand = revo.Operand;
const Register = revo.opcode.Register;
const ir = @import("root.zig");
const dce = @import("dce.zig");

pub fn peepholeIr(self: *Compiler) !void {
    const insts = self.ir_builder.instructions.items;
    const n = insts.len;
    if (n == 0) return;

    var live = try self.alloc.alloc(bool, n);
    defer self.alloc.free(live);
    @memset(live, true);

    // chase jump -> jump chains first so that rewrites below see final
    // targets (a chain that ends in a dead fallthru jump is handled by
    // the compaction remap)
    for (insts) |inst| threadJumps(insts, inst);

    // jump targets, used to keep copy propagation within straightline code
    // (a branch into the middle of a move's live range could bypass the move
    // and leave its source register holding a different value)
    var is_target = try self.alloc.alloc(bool, n);
    defer self.alloc.free(is_target);
    @memset(is_target, false);
    for (insts) |inst| if (ir.isBranch(inst.opcode)) {
        if (inst.op_arg < n) is_target[inst.op_arg] = true;
    };

    // register reads can span contiguous ranges (call args,
    // slice), so reuse dce's model with a buffer sized to the register file
    const read_buf = try self.alloc.alloc(Register, ir.maxRegister(insts) + 1);
    defer self.alloc.free(read_buf);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (!live[i]) continue;
        const inst = insts[i];
        switch (inst.opcode) {
            .move => {
                if (try eliminateMove(i, insts, live, read_buf)) continue;
                _ = try propagateMove(i, insts, live, is_target, read_buf);
            },
            .store_local, .bind_local => eliminateSelfLoad(i, insts, live, is_target),
            .table_set_atom => eliminateFieldRefetch(i, insts, live, is_target),
            .table_get_atom => reuseObjectLoad(i, insts, live, is_target),
            .add, .sub, .mul, .div, .mod, .int_div, .band, .bor, .bxor, .shl, .shr, .add_imm, .sub_imm, .mul_imm, .band_imm, .lt_int_imm => _ = try foldIdentity(self, i, insts, live),
            .jump => {
                if (inst.op_arg == i + 1) live[i] = false;
            },
            .jump_if_false, .jump_if_true, .jump_err => {
                if (inst.op_arg == i + 1) {
                    live[i] = false;
                } else if (inst.opcode == .jump_if_false or inst.opcode == .jump_if_true) {
                    _ = invertBranch(i, insts, live);
                }
            },
            else => {},
        }
    }

    try ir.compactIr(self, n, live);
}

fn threadJumps(insts: []*ir.IrInst, inst: *ir.IrInst) void {
    if (!ir.isBranch(inst.opcode)) return;
    var target = inst.op_arg;
    var steps: usize = 0;
    while (target < insts.len and insts[target].opcode == .jump and steps < insts.len) : (steps += 1) {
        target = insts[target].op_arg;
    }
    inst.op_arg = target;
}

/// opcodes that read exactly their `result_reg` and write no register at all
/// these are the only safe destinations for copy propagation: rewriting the
/// read register cannot shift a register block that later instructions rely on
fn isPureReader(op: Opcode) bool {
    return switch (op) {
        .store_local, .bind_local, .store_global, .store_global_const, .store_upval, .ret, .halt, .jump_if_false, .jump_if_true, .jump_err => true,
        else => false,
    };
}

/// `move rD, rS` where the only user of rD is an instruction that reads a
/// single register (`store_local slot, rD`), rewrite that reader to use rS and
/// drop the copy. rS must not be overwritten between the move and the read,
/// and the read must sit in straight-line code after the move so the source
/// register provably still holds the copied value when the reader runs.
///
/// dce already eliminated moves whose destination is never read, so a live
/// move here has at least one reader; this folds away the single-reader case
/// that `eliminateMove` cannot touch
fn propagateMove(i: usize, insts: []*ir.IrInst, live: []bool, is_target: []const bool, read_buf: []Register) !bool {
    const m = insts[i];
    if (m.operands.len != 1) return false;
    const src_val = m.operands[0];
    const src_reg: Register = ir.valueReg(src_val);
    const dst_reg = m.result_reg;
    if (src_reg == dst_reg) return false;

    var user_idx: usize = 0;
    var found = false;
    // once the copy's destination register is written again, the register
    // holds a different value and later readers are not users of the copy
    var dst_written = false;
    for (i + 1..insts.len) |j| {
        if (!live[j]) continue;
        var is_user = false;
        for (insts[j].operands) |op| {
            if (op == .inst and op.inst == m) {
                is_user = true;
                break;
            }
            if (op == .reg and op.reg == dst_reg and !dst_written) {
                is_user = true;
                break;
            }
        }
        // a consumer can read the copy's destination register by encoded
        // position without naming the move: its operand may point at a
        // different, already-eliminated instruction while the bytecode still
        // reads dst_reg. count those readers as users so a later reader is
        // never separated from the value the copy deposited
        if (!is_user and !dst_written and readsReg(insts[j], dst_reg, read_buf)) {
            is_user = true;
        }
        // a table setter reads its object through `result_reg`, not
        // an operand, so a move feeding it would otherwise look orphaned
        if (!is_user and !dst_written) switch (insts[j].opcode) {
            .table_set_atom, .table_set => {
                if (insts[j].result_reg == dst_reg) is_user = true;
            },
            else => {},
        };
        if (is_user) {
            if (found) return false;
            user_idx = j;
            found = true;
        }
        if (writesReg(insts[j], dst_reg)) dst_written = true;
    }
    if (!found) return false;

    const user = insts[user_idx];

    // `t.field = value` compiles to a dup of the object so the value can
    // land beside it (`table_set_atom` reads `result_reg` and `result_reg+1`);
    // when the value is straight-line and never touches the object register,
    // shift the value down one register, point the setter at the object, and
    // drop the copy
    if (user.opcode == .table_set_atom or user.opcode == .table_set) {
        return shiftSetterCopy(i, insts, live, is_target, read_buf, user_idx);
    }

    if (!isPureReader(user.opcode)) return false;
    // the reader encodes its register as `result_reg`; a single-register read
    // must be sitting at the move's register or the encoding model is off
    if (user.result_reg != dst_reg) return false;

    // the user must be reachable only through the move's fall-through: no
    // branch into the range, no branch out, and no write to the source
    // register, or the source may no longer hold the copied value
    if (is_target[user_idx]) return false;
    for (i + 1..user_idx) |k| {
        if (is_target[k]) return false;
        switch (insts[k].opcode) {
            .jump, .jump_if_false, .jump_if_true, .jump_err => return false,
            else => {},
        }
        var wbuf: [3]Register = undefined;
        const wcnt = dce.writeRegs(insts[k], &wbuf);
        for (wbuf[0..wcnt]) |w| if (w == src_reg) return false;
    }

    // repoint the reader at the source value and make it read the source
    // register, then let the compaction drop the copy
    for (user.operands) |*op| {
        if (op.* == .inst and op.inst == m) {
            op.* = src_val;
            break;
        }
        if (op.* == .reg and op.reg == dst_reg) {
            op.* = src_val;
            break;
        }
    }
    user.result_reg = src_reg;
    live[i] = false;
    return true;
}

/// `bind_local slotS, rR` (or `store_local`) followed by `load_local rR, slotS`
/// reloads a slot into the very register that just wrote it: a no-op the dce
/// keeps because the register is live. scan forward through straight-line
/// code and drop the load while the register still provably holds the slot's
/// value (nothing writes the register or the slot, no branch into the run).
fn eliminateSelfLoad(i: usize, insts: []*ir.IrInst, live: []bool, is_target: []const bool) void {
    const store = insts[i];
    const slot = store.op_arg;
    const reg = store.result_reg;
    var j: usize = i + 1;
    while (j < insts.len) : (j += 1) {
        if (is_target[j]) return;
        if (!live[j]) continue;
        const inst = insts[j];
        if (inst.opcode == .load_local and inst.result_reg == reg and inst.op_arg == slot) {
            live[j] = false;
            return;
        }
        // a jump can leave the current function or merge in control flow that
        // did not pass through the store, so the store no longer dominates
        // anything after it
        if (ir.isBranch(inst.opcode)) return;
        switch (inst.opcode) {
            .bind_local, .store_local => {
                if (inst.op_arg == slot) return;
            },
            .yield, .ret, .halt => return,
            else => {},
        }
        if (writesReg(inst, reg)) return;
    }
}

/// `t.field = value` followed by `load_local rV, slot; table_get_atom rV, rV, :field`
/// reloads the object to read back the field the setter just wrote. the value
/// register still holds the stored value, so when the reload reads the same
/// object (its slot matches the load that fed the setter) the reload and the
/// refetch are a no-op and both drop; the value register already holds the
/// field's value for the consumers of the refetch.
///
/// this is the readback that `shiftSetterCopy` collapses when it sits right
/// after the setter; here the compiler emitted a reload in between, so the
/// register value still proves the field's value only if the object is
/// provably the same one the setter wrote to
fn eliminateFieldRefetch(i: usize, insts: []*ir.IrInst, live: []bool, is_target: []const bool) void {
    const set = insts[i];
    const obj_reg = set.result_reg;
    const val_reg = obj_reg + 1;
    if (i + 2 >= insts.len) return;
    if (!live[i + 1] or !live[i + 2]) return;
    const reload = insts[i + 1];
    if (reload.opcode != .load_local) return;
    if (reload.result_reg != val_reg) return;
    const slot = reload.op_arg;
    if (!isFieldRefetchGet(insts[i + 2], set.opcode, set.op_arg, val_reg)) return;
    if (is_target[i + 1] or is_target[i + 2]) return;

    // the setter's object register must have been loaded from the same slot,
    // with no branch into the run and no rewrite of the register or the slot
    // in between, or the reload reads a different object than the setter
    var obj_load: ?usize = null;
    var k: usize = i;
    while (k > 0) {
        k -= 1;
        if (!live[k]) continue;
        if (is_target[k]) return;
        if (ir.isBranch(insts[k].opcode)) return;
        if (writesReg(insts[k], obj_reg)) {
            if (insts[k].opcode != .load_local or insts[k].op_arg != slot) return;
            obj_load = k;
            break;
        }
    }
    const ol = obj_load orelse return;
    for (ol + 1..i + 3) |j| {
        if (!live[j]) continue;
        switch (insts[j].opcode) {
            .bind_local, .store_local => if (insts[j].op_arg == slot) return,
            else => {},
        }
    }

    // the reload is immediately followed by the refetch, so the refetch is
    // the only reader of the reload's result; dropping both leaves the value
    // register holding the stored value, which is what the refetch produced
    live[i + 1] = false;
    live[i + 2] = false;
}

/// `load_local rX, slot; table_get_atom rX, rX, off` reloads an object that
/// an earlier live `load_local rO, slot` already fetched and that is still
/// sitting in rO: nothing rewrites rO or the slot and no branch enters or
/// leaves the run, so the field read can consume rO directly and the reload
/// drops. field assignment compiles the object first (for the setter) and
/// then reloads it once per field read, so this folds those reloads away.
fn reuseObjectLoad(i: usize, insts: []*ir.IrInst, live: []bool, is_target: []const bool) void {
    const inst = insts[i];
    if (inst.operands.len != 1) return;
    const obj_val = inst.operands[0];
    if (obj_val != .inst) return;
    const obj_inst = obj_val.inst;
    if (obj_inst.opcode != .load_local) return;
    const obj_reg = obj_inst.result_reg;
    const slot = obj_inst.op_arg;

    var reuse: ?usize = null;
    var redundant: ?usize = null;
    var j = i;
    while (j > 0) {
        j -= 1;
        if (!live[j]) continue;
        if (is_target[j]) return;
        if (ir.isBranch(insts[j].opcode)) return;
        switch (insts[j].opcode) {
            .bind_local, .store_local => if (insts[j].op_arg == slot) return,
            else => {},
        }
        // the read's own load writes obj_reg; it is the redundant reload, not
        // a clobber of the object, so keep scanning past it
        if (insts[j] == obj_inst) {
            redundant = j;
            continue;
        }
        if (writesReg(insts[j], obj_reg)) return;
        if (insts[j].opcode == .load_local and insts[j].op_arg == slot and insts[j].result_reg != obj_reg) {
            reuse = j;
            break;
        }
    }
    const r_idx = reuse orelse return;
    const r_reg = insts[r_idx].result_reg;

    // the candidate's register must still hold the slot's value when the read
    // runs: nothing may rewrite it (the slot writes were checked above)
    for (r_idx + 1..i) |k| {
        if (!live[k]) continue;
        if (writesReg(insts[k], r_reg)) return;
    }

    inst.operands[0] = .{ .inst = insts[r_idx] };
    if (redundant) |rd| live[rd] = false;
}

/// the `table_get_atom` that reads the field the setter
/// just wrote, from the same object, into the value register
fn isFieldRefetchGet(inst: *const ir.IrInst, set_op: Opcode, field: Operand, reg: Register) bool {
    switch (inst.opcode) {
        .table_get_atom => if (set_op != .table_set_atom) return false,
        else => return false,
    }
    if (inst.result_reg != reg) return false;
    if (inst.op_arg != field) return false;
    return true;
}

/// `t.field = value` compiles to `move rD, rS` (a dup of the object) followed
/// by the value expression and a `table_set_atom` that reads the object and
/// the value back-to-back from `result_reg` and `result_reg + 1`. the copy
/// only exists to lay the value next to the object, so when the whole value
/// expression is straight-line and never touches the object register, shift
/// every value register down one, point the setter at the object register,
/// and drop the copy.
///
/// when the assignment's result is used, the setter is followed by a
/// `table_get_atom` that reads the stored field back into the freed dup
/// register; that readback is dropped too, because the shifted value already
/// sits in the result register.
///
/// the shift is safe only if no instruction between the copy and the setter
/// writes either register, no later instruction reads the freed dup register
/// (the assignment's expression result reads it back), and no raw `.reg`
/// operand anywhere after the copy points into the shifted value range.
fn shiftSetterCopy(i: usize, insts: []*ir.IrInst, live: []bool, is_target: []const bool, read_buf: []Register, user_idx: usize) bool {
    const m = insts[i];
    if (m.operands[0] != .inst) return false;
    const src_reg = m.operands[0].inst.result_reg;
    const dst_reg = m.result_reg;
    const user = insts[user_idx];
    // the copy must sit one above the object so the value, shifted down by
    // one, lands exactly where the setter reads it next to the object
    if (dst_reg != src_reg + 1) return false;
    if (user.result_reg != dst_reg) return false;
    if (is_target[user_idx]) return false;

    // the value expression between the copy and the setter must be
    // straight-line, must not touch the object or the copy register, must
    // stay above the copy's register (its lowest register is dst after the
    // shift), and must reference registers only through instructions
    var value_max: Register = dst_reg;
    for (i + 1..user_idx) |k| {
        if (!live[k]) continue;
        if (is_target[k]) return false;
        switch (insts[k].opcode) {
            .jump, .jump_if_false, .jump_if_true, .jump_err => return false,
            else => {},
        }
        if (writesReg(insts[k], src_reg)) return false;
        if (writesReg(insts[k], dst_reg)) return false;
        if (insts[k].result_reg <= dst_reg) return false;
        for (insts[k].operands) |op| if (op == .reg) return false;
        if (insts[k].result_reg > value_max) value_max = insts[k].result_reg;
    }

    // the setter's expression result reads the stored field back with a
    // `table_get_atom` right after the set; drop that readback, the shifted
    // value already occupies the result register. later reads of that
    // register are legitimate consumers of the assignment result
    var readback: ?usize = null;
    for (user_idx + 1..insts.len) |k| {
        if (!live[k]) continue;
        if (readback == null and k == user_idx + 1 and isFieldReadback(insts[k], user, dst_reg)) {
            readback = k;
            continue;
        }
        if (readback == null) {
            if (readsReg(insts[k], dst_reg, read_buf)) return false;
        }
        for (insts[k].operands) |op| {
            if (op == .reg and op.reg > dst_reg and op.reg <= value_max) return false;
        }
        if (writesReg(insts[k], dst_reg)) break;
    }

    // shift the value expression down one register, point the setter at the
    // object register, and let the compaction drop the copy and the readback
    for (i + 1..user_idx) |k| {
        if (!live[k]) continue;
        insts[k].result_reg -= 1;
    }
    user.result_reg = src_reg;
    live[i] = false;
    if (readback) |rb| live[rb] = false;
    return true;
}

/// a `table_get_atom` that immediately follows a
/// `table_set_atom` of the same field and reads the same
/// object register: the assignment's expression result, reading the value
/// that was just stored
fn isFieldReadback(inst: *const ir.IrInst, user: *const ir.IrInst, dst_reg: Register) bool {
    if (user.opcode != .table_set_atom) return false;
    switch (inst.opcode) {
        .table_get_atom => if (user.opcode != .table_set_atom) return false,
        else => return false,
    }
    if (inst.result_reg != dst_reg) return false;
    if (inst.op_arg != user.op_arg) return false;
    return true;
}

fn readsReg(inst: *const ir.IrInst, reg: Register, buf: []Register) bool {
    const cnt = dce.readRegsAll(inst, buf);
    for (buf[0..cnt]) |r| if (r == reg) return true;
    return false;
}

fn writesReg(inst: *const ir.IrInst, reg: Register) bool {
    var buf: [3]Register = undefined;
    const cnt = dce.writeRegs(inst, &buf);
    for (buf[0..cnt]) |r| if (r == reg) return true;
    return false;
}

/// remove a move whose destination register is never read
///
/// a self-move is a no-op and always deletes. otherwise the copy is dead
/// when the destination register is overwritten again before anything reads
/// it; that is only provable locally, so the region between the move and
/// its next write must be straight-line (no jumps) with no reads of the
/// register. anything more global was already handled by dce's per-block
/// register liveness
fn eliminateMove(i: usize, insts: []*ir.IrInst, live: []bool, read_buf: []Register) !bool {
    const m = insts[i];
    if (m.operands.len != 1) return false;
    const src_val = m.operands[0];
    const src_reg: Register = ir.valueReg(src_val);
    const dst_reg = m.result_reg;

    if (src_reg == dst_reg) {
        ir.repointUsers(insts, i + 1, m, src_val);
        live[i] = false;
        return true;
    }

    var w = insts.len;
    for (i + 1..insts.len) |j| {
        if (writesReg(insts[j], dst_reg)) {
            w = j;
            break;
        }
    }
    if (w == insts.len) return false;
    for (i + 1..w) |j| {
        if (ir.isBranch(insts[j].opcode)) return false;
        if (readsReg(insts[j], dst_reg, read_buf)) return false;
    }
    // the overwriter itself must not read the register: opcodes like
    // `table_set_atom` read `result_reg` (the table) and then write it back
    if (readsReg(insts[w], dst_reg, read_buf)) return false;
    ir.repointUsers(insts, i + 1, m, src_val);
    live[i] = false;
    return true;
}

/// rewrite `x OP c` where the constant makes the result equal to one
/// operand (`x + 0`, `x * 1`) or a constant (`x * 0`)
///
/// when the surviving operand already writes the result register the
/// instruction is a register no-op and is deleted; otherwise it becomes a
/// copy. only integral small constants participate, and annihilators apply
/// to the typed int opcodes where the vm has no string/float fallback.
/// the `*_int_imm` forms carry their constant in `op_arg` (single operand),
/// so they are folded against that constant too: the compiler's immediate
/// emission must not hide an identity from this pass.
fn foldIdentity(self: *Compiler, i: usize, insts: []*ir.IrInst, live: []bool) !bool {
    const inst = insts[i];
    if (inst.operands.len == 1) return foldIdentityImm(self, i, insts, live, inst);
    if (inst.operands.len != 2) return false;
    const lhs = inst.operands[0];
    const rhs = inst.operands[1];
    if (lhs != .inst or rhs != .inst) return false;

    const lc = constInt(self, lhs.inst);
    const rc = constInt(self, rhs.inst);
    if (lc == null and rc == null) return false;
    if (lc != null and rc != null) return false;

    const op = inst.opcode;
    if (rc != null) {
        if (identityWith(op, rc.?)) return try makeCopy(self, i, insts, live, lhs.inst);
        if (annihilatorWith(op, rc.?)) return try makeConst(self, i, insts, 0);
    }
    if (lc != null and commutative(op)) {
        if (identityWith(op, lc.?)) return try makeCopy(self, i, insts, live, rhs.inst);
        if (annihilatorWith(op, lc.?)) return try makeConst(self, i, insts, 0);
    }
    return false;
}

fn foldIdentityImm(self: *Compiler, i: usize, insts: []*ir.IrInst, live: []bool, inst: *ir.IrInst) !bool {
    const acc = inst.operands[0];
    if (acc != .inst) return false;
    const k: i64 = @intCast(inst.op_arg);
    if (identityWith(inst.opcode, k)) return try makeCopy(self, i, insts, live, acc.inst);
    if (annihilatorWith(inst.opcode, k)) return try makeConst(self, i, insts, 0);
    return false;
}

fn makeCopy(self: *Compiler, i: usize, insts: []*ir.IrInst, live: []bool, src: *ir.IrInst) !bool {
    const inst = insts[i];
    if (src.result_reg == inst.result_reg) {
        // register already holds the value; repoint users so their `.inst`
        // operands stay valid, then drop the no-op
        ir.repointUsers(insts, i + 1, inst, .{ .inst = src });
        live[i] = false;
        return true;
    }
    self.alloc.free(inst.operands);
    inst.operands = try self.alloc.dupe(ir.IrValue, &.{.{ .inst = src }});
    inst.opcode = .move;
    return true;
}

fn makeConst(self: *Compiler, i: usize, insts: []*ir.IrInst, val: i64) !bool {
    const inst = insts[i];
    self.alloc.free(inst.operands);
    inst.operands = try self.alloc.alloc(ir.IrValue, 0);
    inst.opcode = .load_small_int;
    inst.op_arg = @intCast(val);
    return true;
}

fn constInt(self: *Compiler, inst: *const ir.IrInst) ?i64 {
    switch (inst.opcode) {
        .load_small_int => return @intCast(inst.op_arg),
        .load_const => {
            if (inst.op_arg < self.vm.constants.items.len) {
                if (self.vm.constants.items[inst.op_arg].asNum()) |n| {
                    if (revo.memory.numToI64(n)) |iv| {
                        if (@as(f64, @floatFromInt(iv)) == n) return iv;
                    }
                }
            }
            return null;
        },
        else => return null,
    }
}

fn commutative(op: Opcode) bool {
    return switch (op) {
        .add, .mul, .band, .bor, .bxor => true,
        else => false,
    };
}

fn identityWith(op: Opcode, c: i64) bool {
    return switch (op) {
        .add, .add_imm, .sub, .sub_imm => c == 0,
        .mul, .mul_imm, .div, .int_div => c == 1,
        else => false,
    };
}

fn annihilatorWith(op: Opcode, c: i64) bool {
    return switch (op) {
        .mul_imm, .band_imm => c == 0,
        else => false,
    };
}

/// `jump_if_false rA, L1; jump L2; L1: ...` inverts to
/// `jump_if_true rA, L2; L1: ...` when L1 is the very next slot, dropping
/// the unconditional jump
fn invertBranch(i: usize, insts: []*ir.IrInst, live: []bool) bool {
    const inst = insts[i];
    const j = i + 1;
    if (j >= insts.len) return false;
    if (!live[j]) return false;
    if (insts[j].opcode != .jump) return false;
    if (inst.op_arg != j + 1) return false;
    inst.opcode = if (inst.opcode == .jump_if_false) .jump_if_true else .jump_if_false;
    inst.op_arg = insts[j].op_arg;
    live[j] = false;
    return true;
}

const testing = revo.lang.testing;
const t = testing;
const lang = revo.lang;
const VM = revo.VM;

// -- [the tests] -------------------------------------------------------------
// i try to keep the comments formal and coherent
// but let me know if something makes no sense
// ----------------------------------------------------------------------------

fn testRuntime() revo.Runtime {
    return .{
        .alloc = std.testing.allocator,
        .io = std.testing.io,
        .diag_alloc = std.testing.allocator,
        .diag_arena = null,
    };
}

/// hand-built ir has no spans; compact mirrors dce and expects one per
/// instruction, so fill in placeholders
fn appendSpans(compiler: *Compiler, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try compiler.spans.append(compiler.alloc, .{ .start = 0, .end = 0, .line = 1, .column = 1 });
    }
}

test "peephole: add zero folds away" {
    // `x + 0` is a register no-op and must disappear entirely
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{ .text =
        \\fn f(x) do
        \\  x + 0
        \\end
        \\f(3)
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    for (built.ok.instructions) |inst| {
        if (inst.op == .add or inst.op == .move) return error.TestUnexpectedResult;
    }
}

test "peephole regressions" {
    try t.topNumber("fn f(x) do x + 0 end\nf(3)", 3);
    try t.topNumber("fn f(x) do 0 + x end\nf(3)", 3);
    try t.topNumber("fn f(x) do x + 1 end\nf(3)", 4);
    try t.topNumber("fn f(x) do 1 + x end\nf(3)", 4);
    try t.topNumber("fn f(x) do x * 1 end\nf(3)", 3);
    try t.topNumber("fn f(x) do 1 * x end\nf(3)", 3);
    try t.topNumber("fn f(x) do x * 2 end\nf(3)", 6);
    try t.topNumber("fn f(x) do x - 0 end\nf(3)", 3);
    try t.topNumber("fn f(x) do x / 1 end\nf(3)", 3);
    try t.topNumber("fn f(x) do x // 1 end\nf(3)", 3);
    try t.topNumber("fn f(x) do x - 1 end\nf(3)", 2);
    try t.topNumber("fn f(x) do 0 - x end\nf(3)", -3);
    try t.topNumber("fn f(x) do x * 0 end\nf(3)", 0);
    try t.topNumber("fn f(x) do 0 * x end\nf(3)", 0);
    try t.topString("fn f(x) do x * 1 end\nf(\"ab\")", "ab");

    // the folded result is consumed by a later expression, so the peephole
    // must keep the dataflow (via the register) intact
    try t.topNumber(
        \\fn f(x) do
        \\  let y = x + 0
        \\  y * 2
        \\end
        \\f(5)
    , 10);
}

test "peephole: dead move is eliminated" {
    // a move whose destination register is overwritten again before
    // anything reads it (straight-line, no jumps) is a dead copy and must
    // be dropped
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.init(&vm, false, arena.allocator(), std.testing.allocator);
    defer compiler.deinit();

    const a = try compiler.record(.load_small_int, &.{}, false, 0, 7);
    _ = try compiler.record(.move, &.{.{ .inst = a }}, false, 1, 0);
    _ = try compiler.record(.load_small_int, &.{}, false, 1, 8);
    _ = try compiler.record(.ret, &.{}, false, 1, 0);
    try appendSpans(&compiler, 4);

    try peepholeIr(&compiler);

    const insts = compiler.ir_builder.instructions.items;
    try std.testing.expectEqual(@as(usize, 3), insts.len);
    for (insts) |inst| {
        if (inst.opcode == .move) return error.TestUnexpectedResult;
    }
}

test "peephole: store then self-load is a no-op" {
    // `x = expr; x` reloads a slot into the same register that just stored
    // it: the load is a no-op and must be dropped, the store stays
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.init(&vm, false, arena.allocator(), std.testing.allocator);
    defer compiler.deinit();

    _ = try compiler.record(.load_local, &.{}, false, 1, 0);
    _ = try compiler.record(.store_local, &.{}, false, 1, 1);
    _ = try compiler.record(.load_local, &.{}, false, 1, 1);
    _ = try compiler.record(.ret, &.{}, false, 1, 0);
    try appendSpans(&compiler, 4);

    try peepholeIr(&compiler);

    const insts = compiler.ir_builder.instructions.items;
    try std.testing.expectEqual(@as(usize, 3), insts.len);
    for (insts) |inst| {
        if (inst.opcode == .load_local and inst.op_arg == 1) return error.TestUnexpectedResult;
    }
}

test "peephole: store then self-load with a dead register write survives" {
    // if the stored register is overwritten before the reload, the load is a
    // genuine restore and must stay
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.init(&vm, false, arena.allocator(), std.testing.allocator);
    defer compiler.deinit();

    _ = try compiler.record(.load_local, &.{}, false, 1, 0);
    _ = try compiler.record(.store_local, &.{}, false, 1, 1);
    _ = try compiler.record(.load_small_int, &.{}, false, 1, 9);
    _ = try compiler.record(.load_local, &.{}, false, 1, 1);
    _ = try compiler.record(.ret, &.{}, false, 1, 0);
    try appendSpans(&compiler, 5);

    try peepholeIr(&compiler);

    const insts = compiler.ir_builder.instructions.items;
    try std.testing.expectEqual(@as(usize, 5), insts.len);
    var loads: usize = 0;
    for (insts) |inst| {
        if (inst.opcode == .load_local and inst.op_arg == 1) loads += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), loads);
}

test "peephole: store then self-load survives a slot rewrite" {
    // rewriting the slot between store and load makes the reload load the new
    // value, so it is not a no-op
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.init(&vm, false, arena.allocator(), std.testing.allocator);
    defer compiler.deinit();

    _ = try compiler.record(.load_local, &.{}, false, 1, 0);
    _ = try compiler.record(.store_local, &.{}, false, 1, 1);
    _ = try compiler.record(.load_local, &.{}, false, 2, 0);
    _ = try compiler.record(.store_local, &.{}, false, 2, 1);
    _ = try compiler.record(.load_local, &.{}, false, 1, 1);
    _ = try compiler.record(.ret, &.{}, false, 1, 0);
    try appendSpans(&compiler, 6);

    try peepholeIr(&compiler);

    const insts = compiler.ir_builder.instructions.items;
    try std.testing.expectEqual(@as(usize, 6), insts.len);
    var loads: usize = 0;
    for (insts) |inst| {
        if (inst.opcode == .load_local) loads += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), loads);
}

test "peephole: self move is eliminated" {
    // `move r1 <- A` where A already writes r1 is a register no-op; dce
    // keeps it because the register is live, but it must be dropped here
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.init(&vm, false, arena.allocator(), std.testing.allocator);
    defer compiler.deinit();

    const a = try compiler.record(.load_local, &.{}, false, 1, 0);
    _ = try compiler.record(.move, &.{.{ .inst = a }}, false, 1, 0);
    _ = try compiler.record(.ret, &.{}, false, 1, 0);
    try appendSpans(&compiler, 3);

    try peepholeIr(&compiler);

    const insts = compiler.ir_builder.instructions.items;
    try std.testing.expectEqual(@as(usize, 2), insts.len);
    for (insts) |inst| {
        if (inst.opcode == .move) return error.TestUnexpectedResult;
    }
}

test "peephole: move into a table_set_atom register survives" {
    // `table_set_atom` reads `result_reg` (the table) and writes it back, so
    // a move feeding it is not dead even though the register is "overwritten"
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.init(&vm, false, arena.allocator(), std.testing.allocator);
    defer compiler.deinit();

    _ = try compiler.record(.table_new, &.{}, false, 1, 0);
    _ = try compiler.record(.move, &.{.{ .reg = 1 }}, false, 2, 0);
    _ = try compiler.record(.load_small_int, &.{}, false, 3, 41);
    _ = try compiler.record(.table_set_atom, &.{}, false, 2, 212);
    _ = try compiler.record(.ret, &.{}, false, 2, 0);
    try appendSpans(&compiler, 5);

    try peepholeIr(&compiler);

    var moves: usize = 0;
    for (compiler.ir_builder.instructions.items) |inst| {
        if (inst.opcode == .move) moves += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), moves);
}

test "peephole: field-assign copy folds into the setter" {
    // `t.field = value` compiles to a dup of the object so `table_set_atom`
    // can read object and value back-to-back; the dup must fold away and the
    // setter must read the value from the shifted-down register
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.init(&vm, false, arena.allocator(), std.testing.allocator);
    defer compiler.deinit();

    const obj = try compiler.record(.load_local, &.{}, false, 1, 0);
    _ = try compiler.record(.move, &.{.{ .inst = obj }}, false, 2, 0);
    const vo = try compiler.record(.load_local, &.{}, false, 3, 0);
    const vg = try compiler.record(.table_get_atom, &.{.{ .inst = vo }}, false, 3, 0);
    const one = try compiler.record(.load_small_int, &.{}, false, 4, 1);
    _ = try compiler.record(.add, &.{ .{ .inst = vg }, .{ .inst = one } }, false, 3, 0);
    _ = try compiler.record(.table_set_atom, &.{.{ .inst = vg }}, false, 2, 0);
    _ = try compiler.record(.load_local, &.{}, false, 2, 1);
    _ = try compiler.record(.ret, &.{}, false, 2, 0);
    try appendSpans(&compiler, 9);

    try peepholeIr(&compiler);

    const insts = compiler.ir_builder.instructions.items;
    try std.testing.expectEqual(@as(usize, 7), insts.len);
    for (insts) |inst| {
        if (inst.opcode == .move) return error.TestUnexpectedResult;
    }
    for (insts) |inst| {
        if (inst.opcode == .table_set_atom) {
            try std.testing.expectEqual(@as(Register, 1), inst.result_reg);
        }
    }
}

test "peephole: field-assign result read back collapses into the shift" {
    // an assignment whose value is used compiles to `table_set_atom` followed
    // by a `table_get_atom` that reads the dup register back; that readback
    // returns exactly the stored value, so the shift folds it away: the value
    // lands in the result register and the copy and readback both drop. the
    // value expression's own `t.field` reload also folds onto the object load
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.init(&vm, false, arena.allocator(), std.testing.allocator);
    defer compiler.deinit();

    const obj = try compiler.record(.load_local, &.{}, false, 1, 0);
    _ = try compiler.record(.move, &.{.{ .inst = obj }}, false, 2, 0);
    const vo = try compiler.record(.load_local, &.{}, false, 3, 0);
    const vg = try compiler.record(.table_get_atom, &.{.{ .inst = vo }}, false, 3, 0);
    const one = try compiler.record(.load_small_int, &.{}, false, 4, 1);
    _ = try compiler.record(.add, &.{ .{ .inst = vg }, .{ .inst = one } }, false, 3, 0);
    _ = try compiler.record(.table_set_atom, &.{.{ .inst = vg }}, false, 2, 0);
    _ = try compiler.record(.table_get_atom, &.{.{ .inst = obj }}, false, 2, 0);
    _ = try compiler.record(.ret, &.{}, false, 2, 0);
    try appendSpans(&compiler, 9);

    try peepholeIr(&compiler);

    const insts = compiler.ir_builder.instructions.items;
    try std.testing.expectEqual(@as(usize, 6), insts.len);
    for (insts) |inst| {
        if (inst.opcode == .move) return error.TestUnexpectedResult;
    }
    var gets: usize = 0;
    for (insts) |inst| {
        if (inst.opcode == .table_get_atom) gets += 1;
        if (inst.opcode == .table_set_atom) {
            try std.testing.expectEqual(@as(Register, 1), inst.result_reg);
        }
        if (inst.opcode == .ret) {
            try std.testing.expectEqual(@as(Register, 2), inst.result_reg);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), gets);
}

test "peephole: field-assign readback of a different field survives" {
    // the readback reads a different field than the setter wrote, so the
    // shifted value is not what the result wants and the readback must stay.
    // the object load is reused instead of a dup: the readback reads the
    // object directly, so the copy and the value reload both fold away
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.init(&vm, false, arena.allocator(), std.testing.allocator);
    defer compiler.deinit();

    const obj = try compiler.record(.load_local, &.{}, false, 1, 0);
    _ = try compiler.record(.move, &.{.{ .inst = obj }}, false, 2, 0);
    const vo = try compiler.record(.load_local, &.{}, false, 3, 0);
    const vg = try compiler.record(.table_get_atom, &.{.{ .inst = vo }}, false, 3, 0);
    _ = try compiler.record(.table_set_atom, &.{.{ .inst = vg }}, false, 2, 0);
    _ = try compiler.record(.table_get_atom, &.{.{ .inst = obj }}, false, 2, 1);
    _ = try compiler.record(.ret, &.{}, false, 2, 0);
    try appendSpans(&compiler, 7);

    try peepholeIr(&compiler);

    const insts = compiler.ir_builder.instructions.items;
    try std.testing.expectEqual(@as(usize, 5), insts.len);
    var moves: usize = 0;
    var readback_field: ?Operand = null;
    for (insts) |inst| {
        if (inst.opcode == .move) moves += 1;
        if (inst.opcode == .table_get_atom and inst.op_arg == 1) readback_field = inst.op_arg;
    }
    try std.testing.expectEqual(@as(usize, 0), moves);
    // the readback of the other field must still read that field
    try std.testing.expectEqual(@as(?Operand, 1), readback_field);
}

test "peephole: field refetch after setter folds away" {
    // `word.count = word.count + 1; word.count` reloads the object to read the
    // field the setter just wrote; the value register still holds the stored
    // value, so the reload and refetch both drop
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.init(&vm, false, arena.allocator(), std.testing.allocator);
    defer compiler.deinit();

    _ = try compiler.record(.load_local, &.{}, false, 6, 1);
    _ = try compiler.record(.load_local, &.{}, false, 7, 1);
    const vg = try compiler.record(.table_get_atom, &.{.{ .inst = compiler.ir_builder.instructions.items[1] }}, false, 7, 0);
    _ = try compiler.record(.load_small_int, &.{}, false, 8, 1);
    const add = try compiler.record(.add, &.{ .{ .inst = vg }, .{ .inst = compiler.ir_builder.instructions.items[3] } }, false, 7, 0);
    _ = try compiler.record(.table_set_atom, &.{.{ .inst = add }}, false, 6, 0);
    _ = try compiler.record(.load_local, &.{}, false, 7, 1);
    _ = try compiler.record(.table_get_atom, &.{.{ .inst = compiler.ir_builder.instructions.items[6] }}, false, 7, 0);
    _ = try compiler.record(.ret, &.{}, false, 7, 0);
    try appendSpans(&compiler, 9);

    try peepholeIr(&compiler);

    const insts = compiler.ir_builder.instructions.items;
    try std.testing.expectEqual(@as(usize, 6), insts.len);
    // only the value expression's `word.count` read remains; the reload and
    // the refetch after the setter are gone, so the setter feeds ret directly
    var gets: usize = 0;
    for (insts) |inst| {
        if (inst.opcode == .table_get_atom) gets += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), gets);
    try std.testing.expectEqual(Opcode.table_set_atom, insts[4].opcode);
    try std.testing.expectEqual(Opcode.ret, insts[5].opcode);
}

test "peephole: field refetch of a rewritten slot survives" {
    // rewriting the slot between the setter and the refetch makes the reload
    // read a different object, so the refetch is a genuine read and must stay
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.init(&vm, false, arena.allocator(), std.testing.allocator);
    defer compiler.deinit();

    _ = try compiler.record(.load_local, &.{}, false, 6, 1);
    _ = try compiler.record(.load_local, &.{}, false, 7, 1);
    _ = try compiler.record(.table_get_atom, &.{.{ .inst = compiler.ir_builder.instructions.items[1] }}, false, 7, 0);
    _ = try compiler.record(.load_small_int, &.{}, false, 8, 1);
    _ = try compiler.record(.add, &.{ .{ .inst = compiler.ir_builder.instructions.items[2] }, .{ .inst = compiler.ir_builder.instructions.items[3] } }, false, 7, 0);
    _ = try compiler.record(.table_set_atom, &.{.{ .inst = compiler.ir_builder.instructions.items[4] }}, false, 6, 0);
    _ = try compiler.record(.load_local, &.{}, false, 7, 1);
    _ = try compiler.record(.store_local, &.{}, false, 7, 1);
    _ = try compiler.record(.table_get_atom, &.{.{ .inst = compiler.ir_builder.instructions.items[7] }}, false, 7, 0);
    _ = try compiler.record(.ret, &.{}, false, 7, 0);
    try appendSpans(&compiler, 10);

    try peepholeIr(&compiler);

    const insts = compiler.ir_builder.instructions.items;
    try std.testing.expectEqual(@as(usize, 9), insts.len);
    var gets: usize = 0;
    for (insts) |inst| {
        if (inst.opcode == .table_get_atom) gets += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), gets);
}

test "peephole: field refetch of a different slot survives" {
    // the reload reads a different slot than the setter's object, so the
    // refetch reads a different object and must stay
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.init(&vm, false, arena.allocator(), std.testing.allocator);
    defer compiler.deinit();

    _ = try compiler.record(.load_local, &.{}, false, 6, 1);
    _ = try compiler.record(.load_local, &.{}, false, 7, 2);
    _ = try compiler.record(.table_set_atom, &.{.{ .inst = compiler.ir_builder.instructions.items[1] }}, false, 6, 0);
    _ = try compiler.record(.load_local, &.{}, false, 7, 3);
    _ = try compiler.record(.table_get_atom, &.{.{ .inst = compiler.ir_builder.instructions.items[3] }}, false, 7, 0);
    _ = try compiler.record(.ret, &.{}, false, 7, 0);
    try appendSpans(&compiler, 6);

    try peepholeIr(&compiler);

    const insts = compiler.ir_builder.instructions.items;
    try std.testing.expectEqual(@as(usize, 6), insts.len);
    var gets: usize = 0;
    for (insts) |inst| {
        if (inst.opcode == .table_get_atom) gets += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), gets);
}

test "peephole: jump to next instruction is eliminated" {
    // a jump whose target is the very next instruction is a no-op
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.init(&vm, false, arena.allocator(), std.testing.allocator);
    defer compiler.deinit();

    _ = try compiler.record(.load_small_int, &.{}, false, 0, 1);
    _ = try compiler.record(.jump, &.{}, false, 0, 2);
    _ = try compiler.record(.ret, &.{}, false, 0, 0);
    try appendSpans(&compiler, 3);

    try peepholeIr(&compiler);

    const insts = compiler.ir_builder.instructions.items;
    try std.testing.expectEqual(@as(usize, 2), insts.len);
    for (insts) |inst| {
        if (inst.opcode == .jump) return error.TestUnexpectedResult;
    }
}

test "peephole: branch inversion removes a jump" {
    // `jump_if_false rA, L1; jump L2; L1:` inverts to
    // `jump_if_true rA, L2; L1:` when L1 is the very next slot, dropping
    // the unconditional jump
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.init(&vm, false, arena.allocator(), std.testing.allocator);
    defer compiler.deinit();

    _ = try compiler.record(.load_small_int, &.{}, false, 0, 1);
    _ = try compiler.record(.jump_if_false, &.{}, false, 0, 3);
    _ = try compiler.record(.jump, &.{}, false, 0, 4);
    _ = try compiler.record(.ret, &.{}, false, 0, 0);
    _ = try compiler.record(.ret, &.{}, false, 0, 0);
    try appendSpans(&compiler, 5);

    try peepholeIr(&compiler);

    const insts = compiler.ir_builder.instructions.items;
    try std.testing.expectEqual(@as(usize, 4), insts.len);
    for (insts) |inst| {
        if (inst.opcode == .jump) return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(Opcode.jump_if_true, insts[1].opcode);
    try std.testing.expectEqual(@as(usize, 3), insts[1].op_arg);
}

test "peephole: jump chains are threaded" {
    // `jump 1; 1: jump 2; 2: ret` folds the chain so both jumps target the
    // final destination
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.init(&vm, false, arena.allocator(), std.testing.allocator);
    defer compiler.deinit();

    _ = try compiler.record(.jump, &.{}, false, 0, 1);
    _ = try compiler.record(.jump, &.{}, false, 0, 3);
    _ = try compiler.record(.load_small_int, &.{}, false, 0, 9);
    _ = try compiler.record(.ret, &.{}, false, 0, 0);
    try appendSpans(&compiler, 4);

    try peepholeIr(&compiler);

    const insts = compiler.ir_builder.instructions.items;
    try std.testing.expectEqual(@as(usize, 4), insts.len);
    try std.testing.expectEqual(@as(usize, 3), insts[0].op_arg);
    try std.testing.expectEqual(@as(usize, 3), insts[1].op_arg);
}
