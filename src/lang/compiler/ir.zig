const std = @import("std");

const revo = @import("revo");
const Instruction = revo.opcode.Instruction;
const Opcode = revo.opcode.Opcode;
const Operand = revo.Operand;
const Register = revo.opcode.Register;

pub const IrValue = union(enum) { reg: Register, const_idx: usize, inst: *IrInst };

pub const IrInst = struct {
    opcode: Opcode,
    operands: []const IrValue,
    result_reg: Register = 0,
    op_arg: Operand = 0,
};

pub const IrBuilder = struct {
    alloc: std.mem.Allocator,
    instructions: std.ArrayList(*IrInst),
    constants: std.ArrayList([]const u8),

    pub fn init(alloc: std.mem.Allocator) !IrBuilder {
        return .{
            .alloc = alloc,
            // 'alloc' will be an arena
            .instructions = try std.ArrayList(*IrInst).initCapacity(alloc, 32),
            .constants = try std.ArrayList([]const u8).initCapacity(alloc, 16),
        };
    }

    pub fn deinit(self: *IrBuilder) void {
        for (self.instructions.items) |inst| {
            self.alloc.free(inst.operands);
            self.alloc.destroy(inst);
        }
        self.instructions.deinit(self.alloc);
        for (self.constants.items) |c| self.alloc.free(c);
        self.constants.deinit(self.alloc);
    }
};

pub fn lowerInst(alloc: std.mem.Allocator, out: *std.ArrayList(Instruction), inst: *const IrInst) !void {
    const op = inst.opcode;
    const r = inst.result_reg;
    const bx = inst.op_arg;
    const bxi: u32 = @intCast(bx);
    var bc: Instruction = undefined;

    switch (op) {
        .add, .sub, .mul, .div, .mod, .add_int, .sub_int, .mul_int, .mod_int, .div_float, .eq, .neq, .lt, .gt, .lte, .gte, .eq_int, .neq_int, .lt_int, .gt_int, .lte_int, .gte_int, .@"and", .@"or" => bc = .{ .op = op, .a = r, .b = r, .c = r + 1 },
        .negate, .not, .negate_int, .negate_float => bc = .{ .op = op, .a = r, .b = r },
        .load_global, .load_stdlib_global, .load_upval, .closure => bc = .{ .op = op, .a = r, .bx = bxi },
        .load_local => bc = .{ .op = op, .a = r, .b = @intCast(bx) },
        .table_new => bc = .{ .op = op, .a = r },
        .struct_new => bc = .{ .op = op, .a = r, .bx = bxi },
        .load_nil => bc = .{ .op = op, .a = r },
        .load_small_int => bc = .{ .op = op, .a = r, .bx = bxi },
        .load_const => bc = .{ .op = op, .a = r, .bx = bxi },
        .halt => bc = .{ .op = op, .a = if (r == 0) 0 else r },
        .ret => bc = .{ .op = op, .a = if (r == 0) 0 else r },
        .jump => bc = .{ .op = op, .bx = bxi },
        .jump_if_false, .jump_if_true, .jump_if_not_nil_and_not_err, .jump_if_err => bc = .{ .op = op, .a = r, .bx = bxi },
        .store_global, .store_global_const, .store_upval => bc = .{ .op = op, .a = r, .bx = bxi },
        .store_local, .bind_local => bc = .{ .op = op, .a = @intCast(bx), .b = r },
        .tuple_new => bc = .{ .op = op, .a = r, .b = r, .bx = bxi },
        .tuple_get => bc = .{ .op = op, .a = r, .b = r, .c = r + 1 },
        .table_set => bc = .{ .op = op, .a = r, .b = r + 1, .c = r + 2 },
        .table_get => bc = .{ .op = op, .a = r, .b = r, .c = r + 1 },
        .table_set_atom, .struct_set_offset => bc = .{ .op = op, .a = r, .c = r + 1, .bx = bxi },
        .struct_set_method => bc = .{ .op = op, .a = r, .b = r + 1, .c = r + 2 },
        .table_get_atom, .tuple_get_const, .struct_get_offset => bc = .{ .op = op, .a = r, .b = r, .bx = bxi },
        .call, .spawn => bc = .{ .op = op, .a = r, .b = @intCast(bx), .c = r },
        .call_field => bc = .{ .op = op, .a = r, .b = @intCast(bx), .c = r },
        .join => bc = .{ .op = op, .a = r },
        .yield => bc = .{ .op = op },
        .move => {
            const source_reg = switch (inst.operands[0]) {
                .inst => |ptr| ptr.result_reg,
                .reg => |reg| reg,
                .const_idx => unreachable,
            };
            bc = .{ .op = op, .a = r, .b = source_reg };
        },
        .range_init => bc = .{ .op = op, .a = r, .b = r, .c = r + 2, .bx = @intCast(r + 1) },
        .range_next => {
            const has_index = bx != 0;
            bc = .{ .op = op, .a = r, .b = r - 3, .c = if (has_index) r + 1 else 0, .bx = @as(u32, if (has_index) r + 2 else r + 1) };
        },
        .range_for => bc = .{ .op = op, .a = r, .b = r + 1, .c = r + 2, .bx = bxi },
        .unwrap_result => bc = .{ .op = op, .a = r, .bx = bxi },
    }

    try out.append(alloc, bc);
}
