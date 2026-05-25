const std = @import("std");

const revo = @import("revo");
const Compiler = revo.lang.compiler.Compiler;
const Data = revo.Data;

const ast = @import("../ast.zig");
const emit = @import("emit.zig");
const ir_mod = @import("ir.zig");
const types_mod = @import("types.zig");

/// returns true if folded
pub fn maybeFoldConstBinary(self: *Compiler, b: anytype) !bool {
    const left = b.left.expr;
    const right = b.right.expr;

    // numeric folding for two numeric literals
    if (left == .number and right == .number) {
        const lv = left.number.value;
        const rv = right.number.value;
        const has_float_literal = left.number.is_float or right.number.is_float;

        // div by zero check
        if ((b.op == .div or b.op == .mod) and rv == 0.0) return false;

        const res = switch (b.op) {
            .add => lv + rv,
            .sub => lv - rv,
            .mul => lv * rv,
            .div => lv / rv,
            .mod => @mod(lv, rv),
            else => return false,
        };

        if (!std.math.isFinite(res)) return false;

        // float literal? keep as float
        if (has_float_literal) {
            try emit.@"const"(self, Data.new.num(res));
            return true;
        }

        // int literal? truncate if whole
        if (@floor(res) != res) return false;
        const min = @as(f64, @floatFromInt(std.math.minInt(i64)));
        const max = @as(f64, @floatFromInt(std.math.maxInt(i64)));
        if (res < min or res > max) return false;

        try emit.@"const"(self, Data.new.num(@as(i64, @intFromFloat(res))));
        return true;
    }

    // string concatenation folding for two string literals
    if (left == .string and right == .string and b.op == .add) {
        const s = try std.mem.concat(self.alloc, u8, &.{ left.string, right.string });
        defer self.alloc.free(s);
        try emit.@"const"(self, try self.vm.ownDataString(s));
        return true;
    }

    return false;
}

pub const ConstantFolder = struct {
    alloc: std.mem.Allocator,
    comp: *Compiler,
    ir: *ir_mod.IrBuilder,
    folded: std.AutoHashMap(usize, FoldResult),

    pub fn init(alloc: std.mem.Allocator, comp: *Compiler, ir: *ir_mod.IrBuilder) !ConstantFolder {
        return .{
            .alloc = alloc,
            .comp = comp,
            .ir = ir,
            .folded = std.AutoHashMap(usize, FoldResult).init(alloc),
        };
    }

    pub fn deinit(self: *ConstantFolder) void {
        self.folded.deinit();
    }

    pub fn foldAll(self: *ConstantFolder) !usize {
        var count: usize = 0;
        for (self.ir.instructions.items, 0..) |inst, idx| {
            if (try self.tryFold(inst, idx)) count += 1;
        }
        return count;
    }

    fn tryFold(self: *ConstantFolder, inst: *ir_mod.IrInst, idx: usize) !bool {
        const bc = inst.bytecode orelse return false;
        return switch (inst.op) {
            .load_int => {
                // cache int value
                const val = if (inst.metadata == .int_value)
                    inst.metadata.int_value
                else
                    @as(i64, @intCast(bc.bx));
                try self.folded.put(idx, .{ .int_value = val });
                return false;
            },
            .load_const => {
                // cache const metadata
                switch (inst.metadata) {
                    .int_value => |v| try self.folded.put(idx, .{ .int_value = v }),
                    .float_value => |v| try self.folded.put(idx, .{ .float_value = @bitCast(v) }),
                    .bool_value => |v| try self.folded.put(idx, .{ .bool_value = v }),
                    else => {},
                }
                return false;
            },
            .add, .sub, .mul, .div, .mod, .eq, .neq, .lt, .gt, .lte, .gte => try self.foldBinary(inst, idx),
            .negate, .not => try self.foldUnary(inst, idx),
            else => false,
        };
    }

    fn foldBinary(self: *ConstantFolder, inst: *ir_mod.IrInst, idx: usize) !bool {
        if (inst.operands.len < 2) return false;
        const l = self.getVal(inst.operands[0]) orelse return false;
        const r = self.getVal(inst.operands[1]) orelse return false;
        const res = foldBinaryStatic(
            inst.op,
            inst.result_type,
            l,
            inst.result_type,
            r,
        ) orelse return false;
        try self.folded.put(idx, res);
        try self.applyFolded(inst, res);
        return true;
    }

    fn foldUnary(self: *ConstantFolder, inst: *ir_mod.IrInst, idx: usize) !bool {
        if (inst.operands.len < 1) return false;
        const v = self.getVal(inst.operands[0]) orelse return false;
        const res = foldUnaryStatic(
            inst.op,
            inst.result_type,
            v,
        ) orelse return false;
        try self.folded.put(idx, res);
        try self.applyFolded(inst, res);
        return true;
    }

    fn getVal(self: *ConstantFolder, op: ir_mod.IrValue) ?i64 {
        return switch (op) {
            .const_idx => |i| @as(i64, @intCast(i)),
            .inst => |ptr| self.getInstVal(ptr),
            .reg => null, // reg values not constant
        };
    }

    fn getInstVal(self: *ConstantFolder, ptr: anytype) ?i64 {
        for (self.ir.instructions.items, 0..) |inst, i| {
            if (inst != ptr) continue;
            // already folded?
            if (self.folded.get(i)) |f| return f.asInt();
            const bc = inst.bytecode orelse return null;

            return switch (bc.op) {
                .load_small_int => @as(i64, @intCast(bc.bx)),
                .load_const => switch (inst.metadata) {
                    .int_value => |v| v,
                    .bool_value => |v| if (v) @as(i64, 1) else 0,
                    .float_value => |v| @as(i64, @bitCast(v)),
                    else => null,
                },
                else => null,
            };
        }
        return null;
    }

    fn applyFolded(self: *ConstantFolder, inst: *ir_mod.IrInst, res: FoldResult) !void {
        const reg = if (inst.bytecode) |bc| bc.a else 0;
        switch (res) {
            .int_value => |v| {
                // smi
                if (v >= 0 and v <= 65535) {
                    inst.bytecode = .{
                        .op = .load_small_int,
                        .a = reg,
                        .bx = @intCast(v),
                    };
                } else {
                    const data = Data.new.num(v);
                    const idx = try self.comp.vm.addConstant(data);
                    inst.bytecode = .{
                        .op = .load_const,
                        .a = reg,
                        .bx = @intCast(idx),
                    };
                }
                inst.metadata = .{ .int_value = v };
            },
            .bool_value => |v| {
                const data = Data.new.boolean(v);
                const idx = try self.comp.vm.addConstant(data);
                inst.bytecode = .{
                    .op = .load_const,
                    .a = reg,
                    .bx = @intCast(idx),
                };
                inst.metadata = .{ .bool_value = v };
            },
            .float_value => |v| {
                const val_f = @as(f64, @bitCast(v));
                const data = Data.new.num(val_f);
                const idx = try self.comp.vm.addConstant(data);
                inst.bytecode = .{
                    .op = .load_const,
                    .a = reg,
                    .bx = @intCast(idx),
                };
                inst.metadata = .{ .float_value = val_f };
            },
        }
    }
};

pub fn foldBinaryStatic(
    op: ir_mod.IrOp,
    lt: types_mod.TypeInfo,
    lv: i64,
    rt: types_mod.TypeInfo,
    rv: i64,
) ?FoldResult {
    // types must match
    if (!lt.eql(rt)) return null;
    return switch (op) {
        .add => switch (lt) {
            .int => .{ .int_value = lv +% rv },
            .float => {
                const a = @as(f64, @bitCast(lv));
                const b = @as(f64, @bitCast(rv));
                return .{ .float_value = @bitCast(a + b) };
            },
            else => null,
        },
        .sub => switch (lt) {
            .int => .{ .int_value = lv -% rv },
            .float => {
                const a = @as(f64, @bitCast(lv));
                const b = @as(f64, @bitCast(rv));
                return .{ .float_value = @bitCast(a - b) };
            },
            else => null,
        },
        .mul => switch (lt) {
            .int => .{ .int_value = lv *% rv },
            .float => {
                const a = @as(f64, @bitCast(lv));
                const b = @as(f64, @bitCast(rv));
                return .{ .float_value = @bitCast(a * b) };
            },
            else => null,
        },
        .div => switch (lt) {
            .int => {
                // div by zero check
                if (rv == 0) return null;
                return .{ .int_value = @divTrunc(lv, rv) };
            },
            .float => {
                const a = @as(f64, @bitCast(lv));
                const b = @as(f64, @bitCast(rv));
                if (b == 0) return null;
                return .{ .float_value = @bitCast(a / b) };
            },
            else => null,
        },
        .mod => if (lt == .int) {
            // mod by zero check
            if (rv == 0) return null;
            return .{ .int_value = @mod(lv, rv) };
        } else null,
        .eq => .{ .bool_value = lv == rv },
        .neq => .{ .bool_value = lv != rv },
        .lt => .{ .bool_value = lv < rv },
        .gt => .{ .bool_value = lv > rv },
        .lte => .{ .bool_value = lv <= rv },
        .gte => .{ .bool_value = lv >= rv },
        else => null,
    };
}

pub fn foldUnaryStatic(
    op: ir_mod.IrOp,
    t: types_mod.TypeInfo,
    v: i64,
) ?FoldResult {
    return switch (op) {
        .negate => switch (t) {
            .int => .{ .int_value = -%v },
            .float => {
                const f = @as(f64, @bitCast(v));
                return .{ .float_value = @bitCast(-f) };
            },
            else => null,
        },
        .not => .{ .bool_value = v == 0 },
        else => null,
    };
}

pub const FoldResult = union(enum) {
    int_value: i64,
    float_value: i64, // bitcast
    bool_value: bool,

    pub fn asInt(self: FoldResult) i64 {
        return switch (self) {
            .int_value => |v| v,
            .float_value => |v| v,
            .bool_value => |v| if (v) 1 else 0,
        };
    }
};
