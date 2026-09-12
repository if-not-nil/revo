// zlint-disable line-length -- yeah
//! walk ir and fold constant expressions
//! safe bc operands use .inst pointers (not register names),
//! so data flow is correct whatever the control flow is
//!
//! folding frees the operands of the folded instruction, but the operand
//! instructions themselves are only reclaimed by `dce.dceIr`; fold must
//! therefore always be followed by dce before the ir is lowered
const std = @import("std");

const revo = @import("revo");
const Compiler = revo.lang.compiler.Compiler;
const Data = revo.Data;

const ir = @import("root.zig");

pub fn foldIr(self: *Compiler) !void {
    for (self.ir_builder.instructions.items) |inst| {
        _ = tryFoldInst(self, inst) catch continue;
    }
}

fn tryFoldInst(self: *Compiler, inst: *ir.IrInst) !bool {
    switch (inst.opcode) {
        .add, .sub, .mul, .div, .mod, .concat, .pow, .band, .bor, .bxor, .shl, .shr, .int_div, .eq, .neq, .lt, .gt, .lte, .gte, .eq_int, .neq_int, .lt_int, .gt_int, .lte_int, .gte_int => {
            return tryFoldBinary(self, inst);
        },
        .negate, .not => {
            return tryFoldUnary(self, inst);
        },
        else => return false,
    }
}

fn extractConst(self: *Compiler, v: *const ir.IrInst) ?Data {
    switch (v.opcode) {
        .load_small_int => return Data.new.num(@as(i64, @intCast(v.op_arg))),
        .load_const => {
            if (v.op_arg < self.vm.constants.items.len) {
                return self.vm.constants.items[v.op_arg];
            }
            return null;
        },
        .load_nil => return Data.new.nil(),
        .move => {
            // chase the copied value so moves don't block folding; operands
            // point at earlier instructions so the recursion always ends
            if (v.operands.len == 1) {
                if (v.operands[0] == .inst) return extractConst(self, v.operands[0].inst);
            }
            return null;
        },
        else => return null,
    }
}

fn rewriteToConst(self: *Compiler, inst: *ir.IrInst, val: Data) !void {
    // allocate the replacement first so a failure can't leave inst.operands
    // pointing at already-freed memory for a later dce/deinit double free
    const new_ops = try self.alloc.alloc(ir.IrValue, 0);
    self.alloc.free(inst.operands);
    inst.operands = new_ops;

    if (val.asNum()) |n| {
        if (n >= 0 and n <= 65535 and @trunc(n) == n) {
            inst.opcode = .load_small_int;
            inst.op_arg = @intFromFloat(n);
            return;
        }
    }
    const idx = try self.vm.addConstant(val);
    inst.opcode = .load_const;
    inst.op_arg = idx;
}

fn tryFoldBinary(self: *Compiler, inst: *ir.IrInst) !bool {
    if (inst.operands.len != 2) return false;
    const lhs = inst.operands[0];
    const rhs = inst.operands[1];
    if (lhs != .inst or rhs != .inst) return false;

    const lv = extractConst(self, lhs.inst) orelse return false;
    const rv = extractConst(self, rhs.inst) orelse return false;

    // numeric fold
    if (lv.isNumber() and rv.isNumber()) {
        const ln = lv.asNum().?;
        const rn = rv.asNum().?;
        const is_comp = switch (inst.opcode) {
            .eq, .neq, .lt, .gt, .lte, .gte, .eq_int, .neq_int, .lt_int, .gt_int, .lte_int, .gte_int => true,
            else => false,
        };
        const is_int = switch (inst.opcode) {
            .band, .bor, .bxor, .shl, .shr, .int_div, .eq_int, .neq_int, .lt_int, .gt_int, .lte_int, .gte_int => true,
            else => false,
        };

        // bitwise folds only on integral values; `//` folds for floats too
        // (floor), no fold on div-by-zero or non-finite results
        const is_int_only = switch (inst.opcode) {
            .band, .bor, .bxor, .shl, .shr => true,
            else => false,
        };
        const is_floor_div = switch (inst.opcode) {
            .int_div => true,
            else => false,
        };
        const is_pow = switch (inst.opcode) {
            .pow => true,
            else => false,
        };
        if (is_int_only or is_floor_div or is_pow) {
            if (is_int_only) {
                const li = revo.memory.numToI64(ln) orelse return false;
                const ri = revo.memory.numToI64(rn) orelse return false;
                const raw: f64 = switch (inst.opcode) {
                    .band => @floatFromInt(li & ri),
                    .bor => @floatFromInt(li | ri),
                    .bxor => @floatFromInt(li ^ ri),
                    .shl => blk: {
                        if (ri < 0 or ri > 63) break :blk std.math.nan(f64);
                        const shifted: i64 = @bitCast(@as(u64, @bitCast(li)) << @as(u6, @intCast(ri)));
                        break :blk @floatFromInt(shifted);
                    },
                    .shr => blk: {
                        if (ri < 0 or ri > 63) break :blk std.math.nan(f64);
                        break :blk @floatFromInt(li >> @as(u6, @intCast(ri)));
                    },
                    else => unreachable,
                };
                if (!std.math.isFinite(raw)) return false;
                try rewriteToConst(self, inst, Data.new.num(raw));
                return true;
            }
            if (is_floor_div) {
                if (rn == 0) return false;
                const li = revo.memory.numToI64(ln);
                const ri = revo.memory.numToI64(rn);
                const raw: f64 = if (li != null and ri != null)
                    @floatFromInt(@divFloor(li.?, ri.?))
                else
                    @floor(ln / rn);
                if (!std.math.isFinite(raw)) return false;
                try rewriteToConst(self, inst, Data.new.num(raw));
                return true;
            }
            if (is_pow) {
                const li = revo.memory.numToI64(ln);
                const ri = revo.memory.numToI64(rn);
                const raw: f64 = if (li != null and ri != null and ri.? >= 0) blk: {
                    break :blk @floatFromInt(revo.memory.ipow(li.?, ri.?));
                } else std.math.pow(f64, ln, rn);
                if (!std.math.isFinite(raw)) return false;
                try rewriteToConst(self, inst, Data.new.num(raw));
                return true;
            }
            unreachable;
        }

        const raw: f64 = switch (inst.opcode) {
            .add => ln + rn,
            .sub => ln - rn,
            .mul => ln * rn,
            .div => if (rn == 0.0) return false else ln / rn,
            // mirror the vm's .mod: i32-range integers mod via i64 @mod
            // (sign of divisor), everything else fmod (sign of dividend)
            .mod => blk: {
                if (rn == 0.0) return false;
                const li = revo.memory.numToI64(ln);
                const ri = revo.memory.numToI64(rn);
                if (li != null and ri != null and
                    li.? >= std.math.minInt(i32) and li.? <= std.math.maxInt(i32) and
                    ri.? >= std.math.minInt(i32) and ri.? <= std.math.maxInt(i32))
                    break :blk @floatFromInt(@mod(li.?, ri.?));
                break :blk @mod(ln, rn);
            },
            .eq, .eq_int => if (ln == rn) 1.0 else 0.0,
            .neq, .neq_int => if (ln != rn) 1.0 else 0.0,
            .lt, .lt_int => if (ln < rn) 1.0 else 0.0,
            .gt, .gt_int => if (ln > rn) 1.0 else 0.0,
            .lte, .lte_int => if (ln <= rn) 1.0 else 0.0,
            .gte, .gte_int => if (ln >= rn) 1.0 else 0.0,
            else => return false,
        };

        if (is_comp) {
            // comparisons produce :true/:false atoms
            try rewriteToConst(self, inst, Data.new.boolean(raw != 0.0));
        } else {
            if (!std.math.isFinite(raw)) return false;
            if (is_int) {
                if (@floor(raw) != raw) return false;
                const min: f64 = @floatFromInt(std.math.minInt(i64));
                const max: f64 = @floatFromInt(std.math.maxInt(i64));
                if (raw < min or raw > max) return false;
                try rewriteToConst(self, inst, Data.new.num(@as(i64, @intFromFloat(raw))));
            } else {
                try rewriteToConst(self, inst, Data.new.num(raw));
            }
        }
        return true;
    }

    // string concat for .concat with two string constants
    if (lv.isString() and rv.isString() and inst.opcode == .concat) {
        const ls = try self.vm.strings.get(lv.asString().?);
        const rs = try self.vm.strings.get(rv.asString().?);
        const s = try std.mem.concat(self.alloc, u8, &.{ ls, rs });
        defer self.alloc.free(s);
        try rewriteToConst(self, inst, try self.vm.ownDataString(s));
        return true;
    }

    return false;
}

fn tryFoldUnary(self: *Compiler, inst: *ir.IrInst) !bool {
    if (inst.operands.len != 1) return false;
    const operand = inst.operands[0];
    if (operand != .inst) return false;

    const val = extractConst(self, operand.inst) orelse return false;
    if (!val.isNumber()) return false;

    const n = val.asNum().?;
    const is_not = inst.opcode == .not;
    const raw: f64 = switch (inst.opcode) {
        .negate => -n,
        .not => if (n == 0.0) 1.0 else 0.0,
        else => return false,
    };

    if (is_not) {
        try rewriteToConst(self, inst, Data.new.boolean(n == 0.0));
    } else {
        if (!std.math.isFinite(raw)) return false;
        try rewriteToConst(self, inst, Data.new.num(raw));
    }
    return true;
}
