// zlint-disable line-length -- yeah
const std = @import("std");

const revo = @import("revo");
const Instruction = revo.opcode.Instruction;
const Opcode = revo.opcode.Opcode;
const Operand = revo.Operand;
const Register = revo.opcode.Register;
const Compiler = revo.lang.compiler.Compiler;

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
/// fused range back-branch). dce, peephole, and promote all walk these
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

/// the number of contiguous regs starting at `result_reg` that the
/// instruction touches in its lowering (call arg blocks)
/// this is what `maxRegister` adds per instruction: the flat +2 below covers the
/// fixed-width ops, and the var-length ops (call args,
/// slice) contribute their real span
fn spanFor(i: *IrInst) usize {
    return switch (i.opcode) {
        .slice => 4,
        .call, .spawn => i.op_arg + 1,
        .call_field => (i.op_arg & ~@as(Operand, 1 << 7)) + 2,
        .table_set, .range_init => 3,
        .table_get, .table_set_atom, .range_loop, .@"and", .@"or" => 2,
        else => 1,
    };
}

/// highest register any instruction touches, plus a 3-wide read/write span
/// headroom so callers can size buffers to the full register file
pub fn maxRegister(insts: []*IrInst) usize {
    var max_reg: usize = 0;
    for (insts) |inst| {
        const r: usize = inst.result_reg;
        if (r + 2 > max_reg) max_reg = r + 2;
        const span = spanFor(inst);
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

/// compact a `live` bitmap into the instruction list: keep live instructions
/// (and their spans), destroy dead ones, then remap jump targets and function
/// entry addresses, which are stored as instruction indices. dead positions
/// map to the next live slot so stale addresses still land on real code
pub fn compactIr(self: *Compiler, n: usize, live: []const bool) !void {
    const insts = self.ir_builder.instructions.items;
    var new_index = try self.alloc.alloc(usize, n);
    defer self.alloc.free(new_index);

    var write: usize = 0;
    for (insts, 0..) |inst, i| {
        new_index[i] = write;
        if (live[i]) {
            self.ir_builder.instructions.items[write] = inst;
            self.spans.items[write] = self.spans.items[i];
            write += 1;
        } else {
            self.alloc.free(inst.operands);
            self.alloc.destroy(inst);
        }
    }
    self.ir_builder.instructions.shrinkAndFree(self.alloc, write);
    self.spans.shrinkAndFree(self.alloc, write);

    for (self.ir_builder.instructions.items) |inst| {
        if (isBranch(inst.opcode)) inst.op_arg = new_index[inst.op_arg];
    }
    for (self.pending_prototypes.items) |proto_id| {
        const proto = &self.vm.functions.prototypes.items[proto_id];
        proto.addr = @intCast(new_index[proto.addr]);
    }
}

pub fn lowerInst(alloc: std.mem.Allocator, out: *std.ArrayList(Instruction), inst: *const IrInst) !void {
    const op = inst.opcode;
    const r = inst.result_reg;
    const bx = inst.op_arg;
    const bxi: u32 = @intCast(bx);
    var bc: Instruction = .{ .op = .halt };

    switch (op) {
        .add, .sub, .mul, .div, .mod, .concat, .pow, .band, .bor, .bxor, .shl, .shr, .int_div, .eq, .neq, .lt, .gt, .lte, .gte, .eq_int, .neq_int, .lt_int, .gt_int, .lte_int, .gte_int, .@"and", .@"or" => bc = .{ .op = op, .a = r, .b = r, .c = r + 1 },
        .add_int_imm, .sub_int_imm, .mul_int_imm, .band_int_imm, .lt_int_imm => bc = .{ .op = op, .a = r, .b = r, .bx = bxi },
        .negate, .not => bc = .{ .op = op, .a = r, .b = r },
        .load_global, .load_stdlib_global, .load_upval, .closure => bc = .{ .op = op, .a = r, .bx = bxi },
        .load_local => bc = .{ .op = op, .a = r, .b = @intCast(bx) },
        .table_new => bc = .{ .op = op, .a = r },
        .load_nil => bc = .{ .op = op, .a = r },
        .load_small_int => bc = .{ .op = op, .a = r, .bx = bxi },
        .load_const => bc = .{ .op = op, .a = r, .bx = bxi },
        .halt, .ret => bc = .{ .op = op, .a = if (r == 0) 0 else r },
        .jump => bc = .{ .op = op, .bx = bxi },
        .jump_if_false, .jump_if_true, .jump_err => bc = .{ .op = op, .a = r, .bx = bxi },
        .store_global, .store_global_const, .store_upval => bc = .{ .op = op, .a = r, .bx = bxi },
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
        .join => bc = .{ .op = op, .a = r },
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
