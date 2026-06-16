const std = @import("std");

const revo = @import("revo");
const Compiler = revo.lang.compiler.Compiler;
const Data = revo.Data;
const ir = @import("ir.zig");

/// walk ir and fold constant expressions
/// safe bc operands use .inst pointers (not register names),
/// so data flow is correct whatever the control flow is
pub fn foldIr(self: *Compiler) !void {
    for (self.ir_builder.instructions.items) |inst| {
        _ = tryFoldInst(self, inst) catch continue;
    }
}

fn tryFoldInst(self: *Compiler, inst: *ir.IrInst) !bool {
    switch (inst.opcode) {
        .add, .sub, .mul, .div, .mod, .concat, .add_int, .sub_int, .mul_int, .mod_int, .div_float, .eq, .neq, .lt, .gt, .lte, .gte, .eq_int, .neq_int, .lt_int, .gt_int, .lte_int, .gte_int => {
            return tryFoldBinary(self, inst);
        },
        .negate, .not, .negate_int, .negate_float => {
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
        else => return null,
    }
}

fn rewriteToConst(self: *Compiler, inst: *ir.IrInst, val: Data) !void {
    self.alloc.free(inst.operands);
    inst.operands = &.{};

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
            .add_int, .sub_int, .mul_int, .mod_int, .eq_int, .neq_int, .lt_int, .gt_int, .lte_int, .gte_int => true,
            else => false,
        };

        const raw: f64 = switch (inst.opcode) {
            .add, .add_int => ln + rn,
            .sub, .sub_int => ln - rn,
            .mul, .mul_int => ln * rn,
            .div, .div_float => if (rn == 0.0) return false else ln / rn,
            .mod, .mod_int => if (rn == 0.0) return false else @mod(ln, rn),
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
                const min = @as(f64, @floatFromInt(std.math.minInt(i64)));
                const max = @as(f64, @floatFromInt(std.math.maxInt(i64)));
                if (raw < min or raw > max) return false;
                try rewriteToConst(self, inst, Data.new.num(@as(i64, @intFromFloat(raw))));
            } else {
                try rewriteToConst(self, inst, Data.new.num(raw));
            }
        }
        return true;
    }

    // string concat for .add and .concat with two string constants
    if (lv.isString() and rv.isString() and
        (inst.opcode == .add or inst.opcode == .add_int or inst.opcode == .concat))
    {
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
        .negate, .negate_int, .negate_float => -n,
        .not => if (n == 0.0) 1.0 else 0.0,
        else => return false,
    };

    if (is_not) {
        try rewriteToConst(self, inst, Data.new.boolean(n == 0.0));
    } else {
        if (!std.math.isFinite(raw)) return false;
        const is_int = inst.opcode == .negate_int;
        if (is_int) {
            if (@floor(raw) != raw) return false;
            const min = @as(f64, @floatFromInt(std.math.minInt(i64)));
            const max = @as(f64, @floatFromInt(std.math.maxInt(i64)));
            if (raw < min or raw > max) return false;
            try rewriteToConst(self, inst, Data.new.num(@as(i64, @intFromFloat(raw))));
        } else {
            try rewriteToConst(self, inst, Data.new.num(raw));
        }
    }
    return true;
}
