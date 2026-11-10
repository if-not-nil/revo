const std = @import("std");

const revo = @import("revo");
const Instruction = revo.opcode.Instruction;
const Opcode = revo.opcode.Opcode;
const Operand = revo.Operand;
const Register = revo.opcode.Register;

pub const IrValue = union(enum) { reg: Register, inst: *IrInst };

pub const IrInst = struct {
    opcode: Opcode,
    operands: []IrValue,
    result_reg: Register = 0,
    op_arg: Operand = 0,
    // function nesting depth at emission: the root artifact function is 1 (__main),
    // nested closures are deeper. promotion only touches loops at the root
    // depth, because nested frames keep their own (smaller) register_count
    fn_depth: u16 = 0,
    /// dense position in the builder list, refreshed by passes that need it
    tmp_index: usize = 0,
};

pub const IrBuilder = struct {
    alloc: std.mem.Allocator,
    instructions: std.ArrayList(*IrInst),
    deinited: bool = false,

    pub fn init(alloc: std.mem.Allocator) !IrBuilder {
        return .{
            .alloc = alloc,
            .instructions = try std.ArrayList(*IrInst).initCapacity(alloc, 32),
        };
    }

    pub fn deinit(self: *IrBuilder) void {
        // dce may have destroyed dead instructions and compacted the list,
        // leaving only the survivors; deinit frees those. the guard makes a
        // second deinit a no-op instead of a double-free
        if (self.deinited) return;
        self.deinited = true;
        for (self.instructions.items) |inst| {
            self.alloc.free(inst.operands);
            self.alloc.destroy(inst);
        }
        self.instructions.deinit(self.alloc);
    }
};

/// the control-flow opcodes that carry a target in `op_arg` (jumps and the
/// fused range back-branch). dce and peephole walk these
pub fn isBranch(op: Opcode) bool {
    return switch (op) {
        .jump, .jump_if_false, .jump_if_true, .jump_err, .range_loop => true,
        else => false,
    };
}

/// the register an `IrValue` operand reads
pub fn valueReg(v: IrValue) Register {
    return switch (v) {
        .inst => |ptr| ptr.result_reg,
        .reg => |reg| reg,
    };
}

/// for readRegs/writeRegs/maxRegister
pub fn regEffects(inst: *const IrInst, reads: ?[]Register, writes: ?*[3]Register) struct { nreads: usize, nwrites: usize, span: usize } {
    const r = inst.result_reg;
    switch (inst.opcode) {
        // zig fmt: off
        .jump, .yield => return .{ .nreads = 0, .nwrites = 0, .span = 1 },

        .load_user_global, .load_builtin_global, .load_local, .load_upval,
        .make_closure, .table_new, .load_nil, .load_small_int,
        .load_const => {
            if (writes) |out| out[0] = r;
            return .{ .nreads = 0, .nwrites = 1, .span = 1 };
        },

        .move => {
            const src = valueReg(inst.operands[0]);
            if (reads) |out| out[0] = src;
            if (writes) |out| out[0] = r;
            return .{ .nreads = 1, .nwrites = 1, .span = 1 };
        },

        .range_loop => {
            std.debug.assert(r >= 3);
            if (reads) |out| {
                out[0] = r - 3;
                out[1] = r - 2;
                out[2] = r - 1;
            }
            if (writes) |out| {
                out[0] = r;
                out[1] = r + 1;
            }
            const nw: usize = if (inst.operands.len > 0) 2 else 1;
            return .{ .nreads = 3, .nwrites = nw, .span = 2 };
        },

        .call, .spawn => {
            const cnt = inst.op_arg + 1;
            if (reads) |out| {
                for (0..cnt) |k| out[k] = r + @as(Register, @intCast(k));
            }
            if (writes) |out| out[0] = r;
            return .{ .nreads = cnt, .nwrites = 1, .span = cnt };
        },

        .call_field => {
            const cnt = (inst.op_arg & ~@as(usize, 1 << 7)) + 2;
            if (reads) |out| {
                for (0..cnt) |k| out[k] = r + @as(Register, @intCast(k));
            }
            if (writes) |out| out[0] = r;
            return .{ .nreads = cnt, .nwrites = 1, .span = cnt };
        },

        .halt, .ret, .jump_if_false, .jump_if_true, .jump_err,
        .store_user_global, .store_user_global_const, .store_upval,
        .store_local, .bind_local => {
            if (reads) |out| out[0] = r;
            return .{ .nreads = 1, .nwrites = 0, .span = 1 };
        },

        .negate, .not,
        .add_imm, .sub_imm, .mul_imm,
        .band_imm, .lt_int_imm, .unwrap_result => {
            if (reads) |out| out[0] = r;
            if (writes) |out| out[0] = r;
            return .{ .nreads = 1, .nwrites = 1, .span = 1 };
        },

        // the object register comes from the operand, not the result register:
        // a peephole may point the read at an earlier live load of the object
        .table_get_atom => {
            const obj = if (inst.operands.len >= 1) valueReg(inst.operands[0]) else r;
            if (reads) |out| out[0] = obj;
            if (writes) |out| out[0] = r;
            return .{ .nreads = 1, .nwrites = 1, .span = 2 };
        },

        .table_get, .table_set_atom, .@"and", .@"or" => {
            if (reads) |out| {
                out[0] = r;
                out[1] = r + 1;
            }
            if (writes) |out| out[0] = r;
            return .{ .nreads = 2, .nwrites = 1, .span = 2 };
        },

        .add, .sub, .mul, .div, .mod, .concat,
        .band, .bor, .bxor, .shl, .shr, .int_div,
        .pow, .eq, .neq, .lt, .gt, .lte, .gte,
        .eq_int, .neq_int, .lt_int, .gt_int, .lte_int, .gte_int => {
            if (reads) |out| {
                out[0] = r;
                out[1] = r + 1;
            }
            if (writes) |out| out[0] = r;
            return .{ .nreads = 2, .nwrites = 1, .span = 1 };
        },

        .table_set => {
            if (reads) |out| {
                out[0] = r;
                out[1] = r + 1;
                out[2] = r + 2;
            }
            if (writes) |out| out[0] = r;
            return .{ .nreads = 3, .nwrites = 1, .span = 3 };
        },

        .range_init => {
            if (reads) |out| {
                out[0] = r;
                out[1] = r + 1;
                out[2] = r + 2;
            }
            if (writes) |out| {
                out[0] = r;
                out[1] = r + 1;
                out[2] = r + 2;
            }
            return .{ .nreads = 3, .nwrites = 3, .span = 3 };
        },

        .slice => {
            if (reads) |out| {
                out[0] = r;
                out[1] = r + 1;
                out[2] = r + 2;
                out[3] = r + 3;
            }
            if (writes) |out| out[0] = r;
            return .{ .nreads = 4, .nwrites = 1, .span = 4 };
        },
        // zig fmt: on
    }
}

/// highest register any instruction touches, plus a 3-wide read/write span
/// headroom so callers can size buffers to the full register file
pub fn maxRegister(insts: []*IrInst) usize {
    var max_reg: usize = 0;
    for (insts) |inst| {
        const r: usize = inst.result_reg;
        if (r + 2 > max_reg) max_reg = r + 2;
        const span = regEffects(inst, null, null).span;
        if (span > 2 and r + span > max_reg) max_reg = r + span;
    }
    return max_reg;
}

/// repoint every instruction at or after `from` whose `.inst` operand points
/// at `dead` to `repl`, so operands never dangle. operands always point
/// backward, so only later instructions can reference `dead`
pub fn repointUsers(insts: []*IrInst, from: usize, dead: *IrInst, repl: IrValue) void {
    for (insts[from..]) |u| {
        for (u.operands) |*op| {
            if (op.* == .inst and op.inst == dead) op.* = repl;
        }
    }
}

/// registers read by an instruction in its lowering encoding
///
/// reads may be over-estimated (that keeps more code),
/// so call/call_field read the whole argument range
pub fn readRegs(inst: *const IrInst, out: []Register) usize {
    return regEffects(inst, out, null).nreads;
}

/// registers written by an instruction. must be exact: over-estimating
/// would kill registers that are still live at runtime
pub fn writeRegs(inst: *const IrInst, out: *[3]Register) usize {
    return regEffects(inst, null, out).nwrites;
}

/// readRegs plus the instruction's `.reg` operands: the complete set of
/// registers an instruction reads in its lowering encoding
pub fn readRegsAll(inst: *const IrInst, out: []Register) usize {
    var cnt = readRegs(inst, out);
    for (inst.operands) |op| {
        if (op == .reg and cnt < out.len) {
            out[cnt] = op.reg;
            cnt += 1;
        }
    }
    return cnt;
}

pub fn lowerInst(alloc: std.mem.Allocator, out: *std.ArrayList(Instruction), inst: *const IrInst) !void {
    const op = inst.opcode;
    const r = inst.result_reg;
    const bx = inst.op_arg;
    const bxi: u32 = @intCast(bx);
    var bc: Instruction = .{ .op = .halt };

    switch (op) {
        .add, .sub, .mul, .div, .mod, .concat, .pow, .band, .bor, .bxor, .shl, .shr, .int_div, .eq, .neq, .lt, .gt, .lte, .gte, .eq_int, .neq_int, .lt_int, .gt_int, .lte_int, .gte_int, .@"and", .@"or" => bc = .{ .op = op, .a = r, .b = r, .c = r + 1 },
        .add_imm, .sub_imm, .mul_imm, .band_imm, .lt_int_imm => bc = .{ .op = op, .a = r, .b = r, .bx = bxi },
        .negate, .not => bc = .{ .op = op, .a = r, .b = r },
        .load_user_global, .load_builtin_global, .load_upval, .make_closure => bc = .{ .op = op, .a = r, .bx = bxi },
        .load_local => bc = .{ .op = op, .a = r, .b = @intCast(bx) },
        .table_new => bc = .{ .op = op, .a = r },
        .load_nil => bc = .{ .op = op, .a = r },
        .load_small_int => bc = .{ .op = op, .a = r, .bx = bxi },
        .load_const => bc = .{ .op = op, .a = r, .bx = bxi },
        .halt, .ret => bc = .{ .op = op, .a = if (r == 0) 0 else r },
        .jump => bc = .{ .op = op, .bx = bxi },
        .jump_if_false, .jump_if_true, .jump_err => bc = .{ .op = op, .a = r, .bx = bxi },
        .store_user_global, .store_user_global_const, .store_upval => bc = .{ .op = op, .a = r, .bx = bxi },
        .store_local, .bind_local => bc = .{ .op = op, .a = @intCast(bx), .b = r },
        .table_set => bc = .{ .op = op, .a = r, .b = r + 1, .c = r + 2 },
        .table_get => bc = .{ .op = op, .a = r, .b = r, .c = r + 1 },
        .slice => bc = .{ .op = op, .a = r, .b = r, .c = r + 1 }, // vm reads R[b..b+4) as object/start/step/end
        .table_set_atom => bc = .{ .op = op, .a = r, .c = r + 1, .bx = bxi },
        .table_get_atom => {
            const b = if (inst.operands.len >= 1) valueReg(inst.operands[0]) else r;
            bc = .{ .op = op, .a = r, .b = b, .bx = bxi };
        },
        .call, .spawn => bc = .{ .op = op, .a = r, .b = @intCast(bx), .c = r },
        .call_field => bc = .{ .op = op, .a = r, .b = @intCast(bx), .c = r },
        .yield => bc = .{ .op = op },
        .move => {
            const source_reg = valueReg(inst.operands[0]);
            bc = .{ .op = op, .a = r, .b = source_reg };
        },
        .range_init => bc = .{ .op = op, .a = r, .b = r, .c = r + 2, .bx = @intCast(r + 1) },
        .range_loop => {
            const has_index = inst.operands.len > 0;
            bc = .{ .op = op, .a = r, .b = r - 3, .c = if (has_index) inst.operands[0].reg else 0, .bx = bxi };
        },
        .unwrap_result => bc = .{ .op = op, .a = r, .bx = bxi },
    }

    try out.append(alloc, bc);
}
