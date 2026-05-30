const std = @import("std");

const revo = @import("revo");
const Instruction = revo.opcode.Instruction;
const Opcode = revo.opcode.Opcode;

const types_mod = @import("types.zig");
const TypeInfo = types_mod.TypeInfo;

pub const IrValue = union(enum) { reg: u16, const_idx: usize, inst: *IrInst };

pub const IrInst = struct {
    op: IrOp,
    result_type: TypeInfo,
    operands: []const IrValue,
    bytecode: ?Instruction = null,
    eliminated: bool = false,
    metadata: IrMetadata = .none,

    pub const IrMetadata = union(enum) {
        none,
        int_value: i64,
        float_value: f64,
        bool_value: bool,
        string_value: []const u8,
        field_name: []const u8,
        offset: usize,
    };
};

pub const IrBuilder = struct {
    alloc: std.mem.Allocator,
    instructions: std.ArrayList(*IrInst),
    constants: std.ArrayList([]const u8),

    pub fn init(alloc: std.mem.Allocator) !IrBuilder {
        return .{
            .alloc = alloc,
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

    pub fn addInstruction(self: *IrBuilder, op: IrOp, result_type: TypeInfo, operands: []const IrValue) !*IrInst {
        const inst = try self.alloc.create(IrInst);
        inst.* = .{ .op = op, .result_type = result_type, .operands = try self.alloc.dupe(IrValue, operands) };
        try self.instructions.append(self.alloc, inst);
        return inst;
    }

    pub fn addConst(self: *IrBuilder, value: []const u8) !usize {
        const idx = self.constants.items.len;
        try self.constants.append(self.alloc, try self.alloc.dupe(u8, value));
        return idx;
    }
};

pub const IrContext = struct {
    alloc: std.mem.Allocator,
    ir_builder: IrBuilder,
    value_stack: std.ArrayList(*IrInst),
    active: bool = true,

    pub fn init(alloc: std.mem.Allocator) !IrContext {
        return .{
            .alloc = alloc,
            .ir_builder = try IrBuilder.init(alloc),
            .value_stack = try std.ArrayList(*IrInst).initCapacity(alloc, 32),
        };
    }

    pub fn deinit(self: *IrContext) void {
        self.value_stack.deinit(self.alloc);
        self.ir_builder.deinit();
    }

    fn push(self: *IrContext, inst: *IrInst) !void {
        try self.value_stack.append(self.alloc, inst);
    }
    fn pop(self: *IrContext) !*IrInst {
        return self.value_stack.pop() orelse error.OutOfMemory;
    }
    fn peek(self: *IrContext) ?*IrInst {
        return if (self.value_stack.items.len == 0) null else self.value_stack.items[self.value_stack.items.len - 1];
    }

    fn record(self: *IrContext, op: IrOp, res: TypeInfo, ops: []const IrValue, bc: Instruction, meta: ?IrInst.IrMetadata, push_res: bool) !*IrInst {
        const inst = try self.ir_builder.addInstruction(op, res, ops);
        inst.metadata = if (meta) |m| m else .none;
        inst.bytecode = bc;
        if (push_res) try self.push(inst);
        return inst;
    }

    pub fn recordStackOp(self: *IrContext, op: IrOp, res: TypeInfo, bc: Instruction, pop_n: usize, push_n: usize, meta: ?IrInst.IrMetadata) !void {
        if (!self.active) return;
        var ops = try self.alloc.alloc(IrValue, pop_n);
        defer self.alloc.free(ops);
        var i = pop_n;
        while (i > 0) {
            i -= 1;
            ops[i] = .{ .inst = try self.pop() };
        }
        _ = try self.record(op, res, ops, bc, meta, false);
        var p: usize = 0;
        while (p < push_n) : (p += 1) try self.push(self.ir_builder.instructions.items[self.ir_builder.instructions.items.len - 1]);
    }

    pub fn recordLoad(self: *IrContext, op: IrOp, res: TypeInfo, bc: Instruction, meta: ?IrInst.IrMetadata) !void {
        if (!self.active) return;
        _ = try self.record(op, res, &.{}, bc, meta, true);
    }

    pub fn recordUnary(self: *IrContext, op: IrOp, res: TypeInfo, bc: Instruction) !void {
        if (!self.active) return;
        const opnd = try self.pop();
        _ = try self.record(op, res, &.{.{ .inst = opnd }}, bc, null, true);
    }

    pub fn recordBinary(self: *IrContext, op: IrOp, res: TypeInfo, bc: Instruction) !void {
        if (!self.active) return;
        const rhs = try self.pop();
        const lhs = try self.pop();
        _ = try self.record(op, res, &.{ .{ .inst = lhs }, .{ .inst = rhs } }, bc, null, true);
    }

    pub fn recordMove(self: *IrContext, bc: Instruction) !void {
        if (!self.active) return;
        const src = self.peek() orelse return;
        _ = try self.record(.move, .any, &.{.{ .inst = src }}, bc, null, true);
    }

    pub fn lowerToVerifyBytecode(self: *IrContext) ![]Instruction {
        var lowerer = try IrLowerer.init(self.alloc, &self.ir_builder);
        defer lowerer.deinit();
        return try lowerer.lower();
    }

    pub fn getIrInstructions(self: *const IrContext) []*IrInst {
        return self.ir_builder.instructions.items;
    }
};

pub fn verifyIrBytecode(ctx: *IrContext, emitted: []const Instruction, alloc: std.mem.Allocator) !bool {
    if (!ctx.active or ctx.ir_builder.instructions.items.len == 0) return true;
    const lowered = try ctx.lowerToVerifyBytecode();
    defer alloc.free(lowered);
    if (lowered.len != emitted.len) {
        return false;
    }
    var idx: usize = 0;
    while (idx < lowered.len) : (idx += 1) {
        const ir_bc = lowered[idx];
        const em_bc = emitted[idx];
        const call_parity = (ir_bc.op == .call) and (em_bc.op == .call or em_bc.op == .call_field);
        if (!call_parity and ir_bc.op != em_bc.op) {
            return false;
        }
    }
    return true;
}

pub const IrOp = enum {
    move,
    load_const,
    load_stdlib_global,
    load_nil,
    load_int,
    add,
    sub,
    mul,
    div,
    mod,
    negate,
    eq,
    neq,
    lt,
    gt,
    lte,
    gte,
    @"and",
    @"or",
    not,
    table_new,
    table_get,
    table_set,
    struct_new,
    struct_get_offset,
    struct_set_offset,
    closure,
    call,
    ret,
    jump,
    jump_if_false,
    jump_if_true,
};

pub const IrLowerer = struct {
    alloc: std.mem.Allocator,
    ir: *const IrBuilder,
    out: std.ArrayList(Instruction),
    regs: std.ArrayList(u16),
    next_reg: u16,

    pub fn init(alloc: std.mem.Allocator, ir: *const IrBuilder) !IrLowerer {
        var r = try std.ArrayList(u16).initCapacity(alloc, ir.instructions.items.len);
        for (ir.instructions.items) |_| try r.append(alloc, 0);
        return .{ .alloc = alloc, .ir = ir, .out = try std.ArrayList(Instruction).initCapacity(alloc, ir.instructions.items.len), .regs = r, .next_reg = 0 };
    }

    pub fn deinit(self: *IrLowerer) void {
        self.out.deinit(self.alloc);
        self.regs.deinit(self.alloc);
    }

    pub fn lower(self: *IrLowerer) ![]Instruction {
        for (self.ir.instructions.items, 0..) |inst, idx| try self.lowerInst(inst, idx);
        return try self.out.toOwnedSlice(self.alloc);
    }

    fn lowerInst(self: *IrLowerer, inst: *const IrInst, idx: usize) !void {
        if (inst.eliminated) return;
        if (inst.bytecode) |bc| {
            self.regs.items[idx] = bc.a;
            return try self.out.append(self.alloc, bc);
        }

        const op = selectOpcode(inst.op, inst.result_type);
        var out_inst: Instruction = .{ .op = op, .a = 0, .b = 0, .c = 0, .bx = 0 };

        const res_reg: u16 = self.next_reg;
        self.next_reg += 1;
        out_inst.a = res_reg;
        self.regs.items[idx] = res_reg;

        for (inst.operands, 0..) |opnd, i| {
            const mapped = switch (opnd) {
                .reg => |r| @as(u16, r),
                .const_idx => @as(u16, 0),
                .inst => |ptr| blk: {
                    var found: usize = 0;
                    var ok = false;
                    for (self.ir.instructions.items, 0..) |item, j| {
                        if (item == ptr) {
                            found = j;
                            ok = true;
                            break;
                        }
                    }
                    if (ok) break :blk self.regs.items[found];
                    break :blk 0;
                },
            };
            if (i == 0) out_inst.b = mapped else if (i == 1) out_inst.c = mapped;
        }

        if (inst.op == .load_const and inst.operands.len >= 1) out_inst.bx = @as(usize, inst.operands[0].const_idx);
        try self.out.append(self.alloc, out_inst);
    }
};

fn selectOpcode(op: IrOp, t: types_mod.TypeInfo) Opcode {
    return switch (op) {
        .add => switch (t) {
            .int => .add_int,
            .float => .add_int,
            else => .add,
        },
        .sub => switch (t) {
            .int => .sub_int,
            .float => .sub_int,
            else => .sub,
        },
        .mul => switch (t) {
            .int => .mul_int,
            .float => .mul_int,
            else => .mul,
        },
        .div => switch (t) {
            .int => .div_int,
            .float => .div_float,
            else => .div,
        },
        .mod => switch (t) {
            .int => .mod_int,
            else => .mod,
        },
        .eq => .eq,
        .neq => .neq,
        .lt => .lt,
        .gt => .gt,
        .lte => .lte,
        .gte => .gte,
        .@"and" => .@"and",
        .@"or" => .@"or",
        .not => .not,
        .load_int => .load_small_int,
        .load_const => .load_const,
        .load_stdlib_global => .load_stdlib_global,
        .load_nil => .load_nil,
        .table_get => .table_get,
        .table_set => .table_set,
        .table_new => .table_new,
        .call => .call,
        .ret => .ret,
        .jump => .jump,
        .jump_if_false => .jump_if_false,
        .jump_if_true => .jump_if_true,
        .negate => .negate,
        .move => .move,
        .closure => .closure,
        .struct_new => .struct_new,
        .struct_get_offset => .struct_get_offset,
        .struct_set_offset => .struct_set_offset,
    };
}

test "IrBuilder init and deinit" {
    var builder = try revo.lang.compiler.ir.IrBuilder.init(std.testing.allocator);
    defer builder.deinit();
    try std.testing.expect(builder.instructions.items.len == 0);
}

test "IrBuilder add instruction" {
    var builder = try revo.lang.compiler.ir.IrBuilder.init(std.testing.allocator);
    defer builder.deinit();

    const inst = try builder.addInstruction(
        .load_int,
        .int,
        &.{},
    );

    try std.testing.expect(inst.op == .load_int);
    try std.testing.expect(inst.result_type.eql(.int));
    try std.testing.expect(builder.instructions.items.len == 1);
}

test "IrBuilder add binary operation" {
    var builder = try revo.lang.compiler.ir.IrBuilder.init(std.testing.allocator);
    defer builder.deinit();

    const lhs = try builder.addInstruction(.load_int, .int, &.{});
    const rhs = try builder.addInstruction(.load_int, .int, &.{});

    const add_inst = try builder.addInstruction(
        .add,
        .int,
        &.{ .{ .inst = lhs }, .{ .inst = rhs } },
    );

    try std.testing.expect(add_inst.op == .add);
    try std.testing.expect(add_inst.result_type.eql(.int));
    try std.testing.expect(builder.instructions.items.len == 3);
}

test "IrBuilder constant pool" {
    var builder = try revo.lang.compiler.ir.IrBuilder.init(std.testing.allocator);
    defer builder.deinit();

    const idx1 = try builder.addConst("hello");
    const idx2 = try builder.addConst("world");

    try std.testing.expect(idx1 == 0);
    try std.testing.expect(idx2 == 1);
    try std.testing.expect(builder.constants.items.len == 2);
}
