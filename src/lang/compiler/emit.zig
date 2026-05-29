const std = @import("std");

const revo = @import("revo");
const diagnostic = revo.lang.diagnostic;
const Data = revo.Data;
const Compiler = revo.lang.compiler.Compiler;
const Instruction = revo.Instruction;
const Opcode = revo.opcode.Opcode;
const Operand = revo.Operand;
const Register = revo.opcode.Register;

const Node = @import("../ast.zig").Node;
const state = @import("state.zig");

pub fn toRegister(n: usize) !Register {
    std.debug.assert(n <= std.math.maxInt(Register));
    return @intCast(n);
}

pub fn @"const"(self: *Compiler, v: Data) !void {
    if (v.asNum()) |n| {
        if (n >= 0 and n <= 65535 and @trunc(n) == n) return smi(self, @intFromFloat(n));
    }
    const idx = try self.vm.addConstant(v);
    const dst = try state.pushRegister(self);
    const i: Instruction = .{ .op = .load_const, .a = dst, .bx = idx };

    try self.instructions.append(self.alloc, i);
    try self.spans.append(self.alloc, self.active_span);

    if (self.ir_ctx) |*ctx| {
        const m: ?revo.lang.compiler.ir.IrInst.IrMetadata = switch (v.tag()) {
            .number => .{ .float_value = v.asNum().? },
            .string => .{ .string_value = self.vm.stringValue(v.asString().?) },
            .atom => .{ .int_value = @intCast(v.asAtom().?) },
            else => .none,
        };
        try ctx.recordLoad(.load_const, .any, i, m);
    }
}

pub fn loadConst(self: *Compiler, idx: revo.ConstantID) !void {
    const dst = try state.pushRegister(self);
    const i: Instruction = .{ .op = .load_const, .a = dst, .bx = idx };

    try self.instructions.append(self.alloc, i);
    try self.spans.append(self.alloc, self.active_span);

    if (self.ir_ctx) |*ctx| try ctx.recordLoad(.load_const, .any, i, .none);
}

pub fn nil(self: *Compiler) !void {
    const dst = try state.pushRegister(self);
    const i: Instruction = .{ .op = .load_nil, .a = dst };

    try self.instructions.append(self.alloc, i);
    try self.spans.append(self.alloc, self.active_span);

    if (self.ir_ctx) |*ctx| try ctx.recordLoad(.load_nil, .void, i, .none);
}

pub fn smi(self: *Compiler, val: usize) !void {
    const dst = try state.pushRegister(self);
    const i: Instruction = .{ .op = .load_small_int, .a = dst, .bx = val };

    try self.instructions.append(self.alloc, i);
    try self.spans.append(self.alloc, self.active_span);

    if (self.ir_ctx) |*ctx| try ctx.recordLoad(.load_int, .int, i, .{ .int_value = @intCast(val) });
}

pub fn regDupe(self: *Compiler) !void {
    std.debug.assert(self.active_registers != 0);
    const dst = try toRegister(self.active_registers);
    const src = try toRegister(self.active_registers - 1);

    const i: Instruction = .{ .op = .move, .a = dst, .b = src };
    try self.instructions.append(self.alloc, i);
    try self.spans.append(self.alloc, self.active_span);
    self.active_registers += 1;

    if (self.active_registers > self.max_registers) self.max_registers = self.active_registers;
    if (self.ir_ctx) |*ctx| try ctx.recordMove(i);
}

pub fn regRelease(self: *Compiler) !void {
    std.debug.assert(self.active_registers != 0);
    state.popRegister(self);
}

//
// horrors
//

fn stackEffect(op: Opcode) struct { pop: usize, push: usize } {
    return switch (op) {
        .add, .sub, .mul, .div, .mod, .add_int, .sub_int, .mul_int, .div_int, .mod_int, .div_float, .eq, .neq, .lt, .gt, .lte, .gte, .eq_int, .neq_int, .lt_int, .gt_int, .lte_int, .gte_int, .@"and", .@"or" => .{ .pop = 2, .push = 1 },
        .negate, .not, .negate_int, .negate_float => .{ .pop = 1, .push = 1 },
        .jump_if_false, .jump_if_true, .jump_if_not_nil_and_not_err, .jump_if_err => .{ .pop = 1, .push = 0 },
        .store_global, .store_global_const, .store_local, .store_upval, .bind_local => .{ .pop = 1, .push = 0 },
        .load_global, .load_stdlib_global, .load_local, .load_upval, .closure, .table_new, .load_nil, .load_small_int, .load_const => .{ .pop = 0, .push = 1 },
        .table_set => .{ .pop = 3, .push = 0 },
        .table_get, .tuple_get => .{ .pop = 2, .push = 1 },
        .table_set_atom, .struct_set_offset, .struct_set_method => .{ .pop = 3, .push = 0 },
        .table_get_atom, .tuple_get_const, .struct_get_offset => .{ .pop = 1, .push = 1 },
        .struct_new => .{ .pop = 0, .push = 1 },
        .join, .ret, .halt => .{ .pop = 1, .push = 0 },
        .yield, .jump, .unwrap_result, .call, .call_field, .spawn, .tuple_new, .range_init, .range_next, .range_for, .move => .{ .pop = 0, .push = 0 },
    };
}

fn resultType(op: Opcode) revo.lang.compiler.types.TypeInfo {
    return switch (op) {
        .add_int, .sub_int, .mul_int, .div_int, .mod_int, .negate_int => .int,
        .div_float, .negate_float => .float,
        .eq, .neq, .lt, .gt, .lte, .gte, .eq_int, .neq_int, .lt_int, .gt_int, .lte_int, .gte_int, .@"and", .@"or", .not => .bool,
        .load_nil => .void,
        .load_small_int => .int,
        .load_const, .load_global, .load_stdlib_global, .load_local, .load_upval, .closure, .table_new, .table_get, .table_get_atom, .tuple_get, .tuple_get_const, .struct_get_offset, .struct_new, .call, .call_field, .spawn, .join, .range_next, .unwrap_result, .move => .any,
        else => .any,
    };
}

fn toIrOp(op: Opcode) revo.lang.compiler.ir.IrOp {
    return switch (op) {
        .add, .add_int => .add,
        .sub, .sub_int => .sub,
        .mul, .mul_int => .mul,
        .div, .div_int, .div_float => .div,
        .mod, .mod_int => .mod,
        .negate, .negate_int, .negate_float => .negate,
        .@"and" => .@"and",
        .@"or" => .@"or",
        .not => .not,
        .eq, .eq_int => .eq,
        .neq, .neq_int => .neq,
        .lt, .lt_int => .lt,
        .gt, .gt_int => .gt,
        .lte, .lte_int => .lte,
        .gte, .gte_int => .gte,
        .load_const => .load_const,
        .load_stdlib_global => .load_stdlib_global,
        .load_nil => .load_nil,
        .load_small_int => .load_int,
        .table_get => .table_get,
        .table_set => .table_set,
        .table_new => .table_new,
        .call => .call,
        .struct_new => .struct_new,
        .struct_get_offset => .struct_get_offset,
        .struct_set_offset => .struct_set_offset,
        else => .load_nil,
    };
}

fn recordIr(self: *Compiler, op: Opcode, i: Instruction, op_arg: Operand) !void {
    if (self.ir_ctx) |*ctx| switch (op) {
        .add, .sub, .mul, .div, .mod, .add_int, .sub_int, .mul_int, .div_int, .mod_int, .div_float, .eq, .neq, .lt, .gt, .lte, .gte, .eq_int, .neq_int, .lt_int, .gt_int, .lte_int, .gte_int, .@"and", .@"or" => try ctx.recordBinary(toIrOp(op), resultType(op), i),
        .negate, .not, .negate_int, .negate_float => try ctx.recordUnary(toIrOp(op), resultType(op), i),
        .load_const, .load_nil, .load_small_int => {}, // already recorded at call site
        .jump, .yield, .halt => try ctx.recordStackOp(toIrOp(op), resultType(op), i, 0, 0, null),
        .jump_if_false, .jump_if_true, .jump_if_not_nil_and_not_err, .jump_if_err => try ctx.recordStackOp(toIrOp(op), resultType(op), i, 1, 0, null),
        .store_global, .store_global_const, .store_local, .store_upval, .bind_local => try ctx.recordStackOp(toIrOp(op), resultType(op), i, 1, 0, null),
        .ret => try ctx.recordStackOp(toIrOp(op), resultType(op), i, 1, 0, null),
        .load_global, .load_stdlib_global, .load_local, .load_upval, .closure, .table_new, .struct_new => try ctx.recordStackOp(toIrOp(op), resultType(op), i, 0, 1, null),
        .table_get, .tuple_get => try ctx.recordStackOp(toIrOp(op), resultType(op), i, 2, 1, null),
        .table_get_atom, .tuple_get_const, .struct_get_offset, .join => try ctx.recordStackOp(toIrOp(op), resultType(op), i, 1, 1, null),
        .table_set => try ctx.recordStackOp(toIrOp(op), resultType(op), i, 3, 0, null),
        .table_set_atom, .struct_set_offset => try ctx.recordStackOp(toIrOp(op), resultType(op), i, 2, 0, null),
        .struct_set_method => try ctx.recordStackOp(.table_set, .any, i, 3, 0, null),
        .tuple_new => try ctx.recordStackOp(toIrOp(op), resultType(op), i, op_arg, 1, null),
        .call => try ctx.recordStackOp(toIrOp(.call), resultType(op), i, op_arg + 1, 1, null),
        .call_field => {
            const argc = op_arg & ~@as(Operand, 1 << 15);
            try ctx.recordStackOp(toIrOp(.call), resultType(op), i, argc + 2, 1, null);
        },
        .spawn => try ctx.recordStackOp(toIrOp(.call), resultType(op), i, op_arg + 1, 1, null),
        .range_init => try ctx.recordStackOp(toIrOp(op), resultType(op), i, 3, 0, null),
        .range_next => try ctx.recordStackOp(toIrOp(op), resultType(op), i, 1, 3, null),
        .range_for => try ctx.recordStackOp(toIrOp(op), resultType(op), i, 3, 0, null),
        .unwrap_result => try ctx.recordStackOp(toIrOp(op), resultType(op), i, 1, 1, null),
        .move => try ctx.recordMove(i),
    };
}

pub fn emit(self: *Compiler, op: Opcode, op_arg: Operand) !void {
    var i: Instruction = .{ .op = .halt };
    var d = self.active_registers;
    var ir_rec = false;

    switch (op) {
        // binary: pop 2, push 1, result in c
        .add, .sub, .mul, .div, .mod, .add_int, .sub_int, .mul_int, .div_int, .mod_int, .div_float, .eq, .neq, .lt, .gt, .lte, .gte, .eq_int, .neq_int, .lt_int, .gt_int, .lte_int, .gte_int, .@"and", .@"or" => {
            std.debug.assert(d >= 2);
            i = .{ .op = op, .a = try toRegister(d - 2), .b = try toRegister(d - 2), .c = try toRegister(d - 1) };
            d -= 1;
            if (self.ir_ctx) |*ctx| try ctx.recordBinary(toIrOp(op), resultType(op), i);
            ir_rec = true;
        },
        // unary: pop 1, push 1, result in a
        .negate, .not, .negate_int, .negate_float => {
            std.debug.assert(d > 0);
            i = .{ .op = op, .a = try toRegister(d - 1), .b = try toRegister(d - 1) };
            if (self.ir_ctx) |*ctx| try ctx.recordUnary(toIrOp(op), resultType(op), i);
            ir_rec = true;
        },
        // loads
        .load_global, .load_stdlib_global, .load_local, .load_upval, .closure, .table_new, .struct_new, .load_nil, .load_small_int, .load_const => {
            i = switch (op) {
                .load_global => .{ .op = .load_global, .a = try toRegister(d), .bx = op_arg },
                .load_stdlib_global => .{ .op = .load_stdlib_global, .a = try toRegister(d), .bx = op_arg },
                .load_local => .{ .op = .load_local, .a = try toRegister(d), .b = try toRegister(op_arg) },
                .load_upval => .{ .op = .load_upval, .a = try toRegister(d), .bx = op_arg },
                .closure => .{ .op = .closure, .a = try toRegister(d), .bx = op_arg },
                .table_new => .{ .op = .table_new, .a = try toRegister(d) },
                .struct_new => .{ .op = .struct_new, .a = try toRegister(d), .bx = op_arg },
                .load_nil => .{ .op = .load_nil, .a = try toRegister(d) },
                .load_small_int => .{ .op = .load_small_int, .a = try toRegister(d), .bx = op_arg },
                .load_const => .{ .op = .load_const, .a = try toRegister(d), .bx = op_arg },
                else => unreachable,
            };
            d += 1;
            if (self.ir_ctx) |*ctx| switch (op) {
                .load_global, .load_stdlib_global, .load_local, .load_upval, .closure, .table_new, .struct_new => try ctx.recordStackOp(toIrOp(op), resultType(op), i, 0, 1, null),
                .load_const => try ctx.recordLoad(.load_const, .any, i, .none),
                .load_nil => try ctx.recordLoad(.load_nil, .void, i, .none),
                .load_small_int => try ctx.recordLoad(.load_int, .int, i, .{ .int_value = @intCast(op_arg) }),
                else => {},
            };
            ir_rec = op != .load_const and op != .load_nil and op != .load_small_int;
        },
        // terminators
        .halt => i = .{ .op = .halt, .a = if (d == 0) 0 else try toRegister(d - 1) },
        .ret => i = .{ .op = .ret, .a = if (d == 0) 0 else try toRegister(d - 1) },
        // jumps
        .jump => i = .{ .op = .jump, .bx = op_arg },
        .jump_if_false, .jump_if_true, .jump_if_not_nil_and_not_err, .jump_if_err => {
            std.debug.assert(d > 0);
            i = .{ .op = op, .a = try toRegister(d - 1), .bx = op_arg };
            d -= 1;
        },
        // stores: pop 1
        .store_global, .store_global_const, .store_upval => {
            std.debug.assert(d > 0);
            i = .{ .op = op, .a = try toRegister(d - 1), .bx = op_arg };
            d -= 1;
        },
        .store_local, .bind_local => {
            std.debug.assert(d > 0);
            i = .{ .op = op, .a = try toRegister(op_arg), .b = try toRegister(d - 1) };
            d -= 1;
        },
        // tuple ops
        .tuple_new => {
            std.debug.assert(d >= op_arg);
            const first = d - op_arg;
            i = .{ .op = .tuple_new, .a = try toRegister(first), .b = try toRegister(first), .bx = op_arg };
            d = first + 1;
        },
        .tuple_get => {
            std.debug.assert(d >= 2);
            i = .{ .op = .tuple_get, .a = try toRegister(d - 2), .b = try toRegister(d - 2), .c = try toRegister(d - 1) };
            d -= 1;
        },
        // table ops
        .table_set => {
            std.debug.assert(d >= 3);
            i = .{ .op = .table_set, .a = try toRegister(d - 3), .b = try toRegister(d - 2), .c = try toRegister(d - 1) };
            d -= 2;
        },
        .table_get => {
            std.debug.assert(d >= 2);
            i = .{ .op = .table_get, .a = try toRegister(d - 2), .b = try toRegister(d - 2), .c = try toRegister(d - 1) };
            d -= 1;
        },
        .table_set_atom, .struct_set_offset => {
            std.debug.assert(d >= 2);
            i = .{ .op = op, .a = try toRegister(d - 2), .c = try toRegister(d - 1), .bx = op_arg };
            d -= 1;
        },
        .struct_set_method => {
            std.debug.assert(d >= 3);
            i = .{ .op = .struct_set_method, .a = try toRegister(d - 3), .b = try toRegister(d - 2), .c = try toRegister(d - 1) };
            d -= 2;
        },
        .table_get_atom, .tuple_get_const, .struct_get_offset => {
            std.debug.assert(d > 0);
            i = .{ .op = op, .a = try toRegister(d - 1), .b = try toRegister(d - 1), .bx = op_arg };
        },
        // calls
        .call, .spawn => {
            std.debug.assert(d >= op_arg + 1);
            const base = d - op_arg - 1;
            i = .{ .op = op, .a = try toRegister(base), .b = try toRegister(op_arg), .c = try toRegister(base) };
            d = base + 1;
        },
        .call_field => {
            const argc = op_arg & ~@as(Operand, 1 << 15);
            const needed = argc + 2;
            std.debug.assert(d >= needed);
            const base = d - needed;
            i = .{ .op = .call_field, .a = try toRegister(base), .b = try toRegister(op_arg), .c = try toRegister(base) };
            d = base + 1;
        },
        // flow
        .join => {
            std.debug.assert(d > 0);
            i = .{ .op = .join, .a = try toRegister(d - 1) };
        },
        .yield => i = .{ .op = .yield },
        .move => unreachable,
        // ranges
        .range_init => {
            std.debug.assert(d >= 3);
            i = .{ .op = .range_init, .a = try toRegister(d - 3), .b = try toRegister(d - 3), .c = try toRegister(d - 1), .bx = @intCast(d - 2) };
            d -= 3;
        },
        .range_next => {
            std.debug.assert(d >= 3);
            i = .{ .op = .range_next, .a = try toRegister(d), .b = try toRegister(d - 3), .c = try toRegister(d + 1), .bx = @intCast(d + 2) };
            d += 3;
        },
        .range_for => {
            std.debug.assert(d >= 3);
            i = .{ .op = .range_for, .a = try toRegister(d - 3), .b = try toRegister(d - 2), .c = try toRegister(d - 1), .bx = op_arg };
        },
        .unwrap_result => {
            std.debug.assert(d > 0);
            i = .{ .op = .unwrap_result, .a = try toRegister(d - 1), .bx = op_arg };
        },
    }

    if (!ir_rec) try recordIr(self, op, i, op_arg);
    try self.instructions.append(self.alloc, i);
    try self.spans.append(self.alloc, self.active_span);
    self.active_registers = d;
    if (d > self.max_registers) self.max_registers = d;
}

pub fn jump(self: *Compiler, op: Opcode) !usize {
    const idx = self.instructions.items.len;
    try emit(self, op, 0);
    return idx;
}

pub fn patchJump(self: *Compiler, idx: usize) void {
    patchJumpToLabel(self, idx, self.instructions.items.len);
}

pub fn patchJumpToLabel(self: *Compiler, jump_idx: usize, target: usize) void {
    self.instructions.items[jump_idx].bx = @intCast(target);
    if (self.ir_ctx) |*ctx| {
        if (jump_idx < ctx.ir_builder.instructions.items.len) {
            if (ctx.ir_builder.instructions.items[jump_idx].bytecode) |*bc| {
                bc.bx = @intCast(target);
            }
        }
    }
}

pub fn fail(self: *Compiler, kind: anytype, expr: *const Node, msg: []const u8) error{LoweringFailed} {
    const owned_msg = self.runtime_alloc.dupe(u8, msg) catch "out of memory while formatting error message";
    if (self.failure_message_owned) self.runtime_alloc.free(self.failure_message);
    self.failure_message = owned_msg;
    self.failure_message_owned = owned_msg.ptr != msg.ptr;
    self.failure_parts[0] = diagnostic.Part{ .@"error" = owned_msg };
    self.failure_parts[1] = .{ .span = .{ .span = expr.span, .role = .primary } };
    self.failure = .{
        .kind = kind,
        .report = .{ .parts = self.failure_parts[0..2], .message = owned_msg },
    };
    return error.LoweringFailed;
}

pub fn appendRecorded(self: *Compiler, instr: Instruction) !void {
    const op_arg: Operand = switch (instr.op) {
        .call, .call_field, .spawn => @intCast(instr.b),
        else => instr.bx,
    };
    if (self.ir_ctx != null) try recordIr(self, instr.op, instr, op_arg);
    try self.instructions.append(self.alloc, instr);
    try self.spans.append(self.alloc, self.active_span);
}

test "emit: data ret types regression" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 2), stackEffect(.add).pop);
    try t.expectEqual(revo.lang.compiler.types.TypeInfo.int, resultType(.add_int));
    try t.expectEqual(revo.lang.compiler.ir.IrOp.add, toIrOp(.add));
}
