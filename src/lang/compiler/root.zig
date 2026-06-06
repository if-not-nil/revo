const std = @import("std");

const revo = @import("revo");
const Data = revo.Data;
const Instruction = revo.Instruction;
const Opcode = revo.opcode.Opcode;
const Operand = revo.Operand;
const VM = revo.VM;
const LocalSlot = revo.LocalSlot;
const ProgramCounter = revo.ProgramCounter;

const ast = @import("../ast.zig");
const Node = ast.Node;
const Binding = ast.Binding;
const expander = @import("../expander.zig");
const flow = @import("flow.zig");
const fold = @import("fold.zig");
pub const ir = @import("ir.zig");
const state_mod = @import("state.zig");
pub const struct_layout = @import("struct_layout.zig");
pub const types = @import("types.zig");
pub const type_check = @import("type_check.zig");
const values = @import("values.zig");
const diagnostic = @import("../diagnostic.zig");

const toRegister = state_mod.toRegister;

pub const LowerErrorKind = enum {
    ParseError,
    UnsupportedSyntax,
    InvalidAssignmentTarget,
    IntegerOutOfRange,
};

pub const LowerResult = union(enum) {
    ok: []Instruction,
    err: LowerFailure,
};

pub const Artifact = struct {
    instructions: []Instruction,
    spans: []ast.Span,
};

pub const ArtifactResult = union(enum) {
    ok: Artifact,
    err: LowerFailure,
};

pub const LowerError = error{
    ParseError,
    UnsupportedSyntax,
    InvalidAssignmentTarget,
    IntegerOutOfRange,
} || std.mem.Allocator.Error || expander.ExpandError;

const InternalLowerError = LowerError || error{LoweringFailed};

pub const LowerFailure = diagnostic.Diagnostic(LowerErrorKind);

pub fn lowerExprArtifactReport(
    vm: *VM,
    expr: *const Node,
    test_mode: bool,
) !ArtifactResult {
    var arena = std.heap.ArenaAllocator.init(vm.runtime.alloc);
    defer arena.deinit();

    var compiler = try Compiler.init(
        vm,
        test_mode,
        arena.allocator(),
        vm.runtime.alloc,
    );
    defer compiler.deinit();

    compiler.compileRoot(expr) catch |err| switch (err) {
        error.LoweringFailed => {
            const failure = try compiler.finishFailure() orelse return error.LoweringFailed;
            const report = try failure.report.copy(vm.runtime.diag_alloc);
            return .{ .err = .{
                .kind = failure.kind,
                .report = report,
            } };
        },
        else => return err,
    };

    return .{ .ok = try compiler.finishArtifact() };
}

pub const Compiler = struct {
    const LocalValueKind = state_mod.LocalValueKind;
    const LocalVar = state_mod.LocalVar;
    const FunctionState = state_mod.FunctionState;
    const Temps = state_mod.Temps;

    vm: *VM,
    comp_vm: *VM,
    alloc: std.mem.Allocator,
    runtime_alloc: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    test_mode: bool,
    functions: std.ArrayList(FunctionState),
    slot_allocators: std.ArrayList(LocalSlot),
    temps: Temps = .{},
    break_jumps: std.ArrayList(usize),
    loop_result_regs: std.ArrayList(usize),
    test_suite_names: std.ArrayList([]const u8),
    in_loop_depth: usize = 0,
    failure: ?LowerFailure = null,
    failure_message: []const u8 = "",
    failure_message_owned: bool = false,
    failure_parts: [16]diagnostic.Part = undefined,
    failure_part_len: usize = 0,
    failure_reports: std.ArrayList(LowerFailure),
    spans: std.ArrayList(ast.Span),
    active_span: ast.Span = .{
        .start = 0,
        .end = 0,
        .line = 1,
        .column = 1,
    },
    active_registers: usize = 0,
    max_registers: usize = 0,
    struct_layouter: struct_layout.StructLayouter,
    struct_layouts: std.StringHashMap([]const struct_layout.FieldDef),
    ir_builder: ir.IrBuilder,
    value_stack: std.ArrayList(*ir.IrInst),
    // register cache for upvalue loads, cleared per-block in compileBlock
    upvalue_cache: std.AutoHashMap(usize, usize) = undefined,
    type_aliases: std.StringHashMap(types.TypeInfo),
    fn_return_type: ?[]const u8 = null,
    pending_prototypes: std.ArrayList(revo.PrototypeID),

    pub fn init(
        vm: *VM,
        test_mode: bool,
        arena: std.mem.Allocator,
        runtime_alloc: std.mem.Allocator,
    ) !Compiler {
        return .{
            .vm = vm,
            .comp_vm = vm,
            .alloc = arena,
            .runtime_alloc = runtime_alloc,
            .arena = std.heap.ArenaAllocator.init(arena),
            .test_mode = test_mode,
            .functions = try std.ArrayList(FunctionState).initCapacity(arena, 4),
            .slot_allocators = try std.ArrayList(LocalSlot).initCapacity(arena, 4),
            .failure_reports = try std.ArrayList(LowerFailure).initCapacity(arena, 4),
            .spans = try std.ArrayList(ast.Span).initCapacity(arena, 32),
            .break_jumps = try std.ArrayList(usize).initCapacity(arena, 16),
            .loop_result_regs = try std.ArrayList(usize).initCapacity(arena, 8),
            .test_suite_names = try std.ArrayList([]const u8).initCapacity(arena, 4),
            .struct_layouter = struct_layout.StructLayouter.init(arena),
            .struct_layouts = std.StringHashMap([]const struct_layout.FieldDef).init(arena),
            .ir_builder = try ir.IrBuilder.init(arena),
            .value_stack = try std.ArrayList(*ir.IrInst).initCapacity(arena, 32),
            .upvalue_cache = std.AutoHashMap(usize, usize).init(arena),
            .type_aliases = std.StringHashMap(types.TypeInfo).init(arena),
            .pending_prototypes = try std.ArrayList(revo.PrototypeID).initCapacity(arena, 4),
        };
    }

    pub fn deinit(self: *Compiler) void {
        if (self.failure_message_owned) self.runtime_alloc.free(self.failure_message);
        for (self.functions.items) |*s| s.deinit(self.alloc);
        self.functions.deinit(self.alloc);
        self.slot_allocators.deinit(self.alloc);
        self.failure_reports.deinit(self.alloc);
        self.spans.deinit(self.alloc);
        self.break_jumps.deinit(self.alloc);
        self.loop_result_regs.deinit(self.alloc);
        self.test_suite_names.deinit(self.alloc);
        self.struct_layouter.deinit();
        var layout_it = self.struct_layouts.iterator();
        while (layout_it.next()) |entry| self.alloc.free(entry.value_ptr.*);
        self.struct_layouts.deinit();
        self.ir_builder.deinit();
        self.value_stack.deinit(self.alloc);
        self.arena.deinit();
    }

    // ctx interface for types.zig
    pub const inferIdentType = type_check.inferIdentType;
    pub const resolveTypeName = types.resolveTypeName;
    pub const resolveTypeAlias = type_check.resolveTypeAlias;
    pub const inferCallReturnType = type_check.inferCallReturnType;
    pub const inferFieldType = type_check.inferFieldType;
    pub const inferFnType = type_check.inferFnType;

    pub fn finishArtifact(self: *Compiler) !Artifact {
        try fold.foldIr(self);
        const lowered = try self.lowerToVerifyBytecode();
        const instr_copy = try self.runtime_alloc.dupe(Instruction, lowered);
        defer self.alloc.free(lowered);

        if (self.pending_prototypes.items.len > 0) {
            const segment_copy = try self.runtime_alloc.dupe(Instruction, lowered);
            const segment_id = try self.vm.functions.addBytecodeSegment(segment_copy);
            for (self.pending_prototypes.items) |proto_id| {
                self.vm.functions.prototypes.items[proto_id].segment_id = segment_id;
            }
            self.pending_prototypes.items.len = 0;
        }

        const spans_copy = try self.runtime_alloc.dupe(ast.Span, self.spans.items);
        return .{ .instructions = instr_copy, .spans = spans_copy };
    }

    // ir methods

    pub fn pop(self: *Compiler) !*ir.IrInst {
        return self.value_stack.pop() orelse error.OutOfMemory;
    }

    pub fn record(self: *Compiler, opcode: Opcode, ops: []const ir.IrValue, push_res: bool, result_reg: u16, op_arg: Operand) !*ir.IrInst {
        const inst = try self.alloc.create(ir.IrInst);
        inst.* = .{ .opcode = opcode, .operands = try self.alloc.dupe(ir.IrValue, ops) };
        try self.ir_builder.instructions.append(self.alloc, inst);
        inst.result_reg = result_reg;
        inst.op_arg = op_arg;
        if (push_res) try self.value_stack.append(self.alloc, inst);
        return inst;
    }

    pub fn recordStackOp(self: *Compiler, opcode: Opcode, pop_n: usize, push_n: usize, result_reg: u16, op_arg: Operand) !void {
        var ops = try self.alloc.alloc(ir.IrValue, pop_n);
        defer self.alloc.free(ops);
        var i = pop_n;
        while (i > 0) {
            i -= 1;
            ops[i] = .{ .inst = try self.pop() };
        }
        _ = try self.record(opcode, ops, false, result_reg, op_arg);
        var p: usize = 0;
        while (p < push_n) : (p += 1) try self.value_stack.append(self.alloc, self.ir_builder.instructions.items[self.ir_builder.instructions.items.len - 1]);
    }

    pub fn recordLoad(self: *Compiler, opcode: Opcode, result_reg: u16, op_arg: Operand) !void {
        _ = try self.record(opcode, &.{}, true, result_reg, op_arg);
    }

    pub fn recordMove(self: *Compiler, result_reg: u16) !void {
        if (self.value_stack.items.len == 0) {
            _ = try self.record(.load_nil, &.{}, true, result_reg, 0);
            return;
        }
        const src = self.value_stack.items[self.value_stack.items.len - 1];
        _ = try self.record(.move, &.{.{ .inst = src }}, true, result_reg, 0);
    }

    pub fn lowerToVerifyBytecode(self: *Compiler) ![]Instruction {
        var out = try std.ArrayList(Instruction).initCapacity(self.alloc, self.ir_builder.instructions.items.len);
        defer out.deinit(self.alloc);
        for (self.ir_builder.instructions.items) |inst| try ir.lowerInst(self.alloc, &out, inst);
        return try out.toOwnedSlice(self.alloc);
    }

    pub fn irLen(self: *Compiler) usize {
        return self.ir_builder.instructions.items.len;
    }

    pub fn jump(self: *Compiler, op: Opcode) !usize {
        const idx = self.irLen();
        try self.emit(op, 0);
        return idx;
    }

    pub fn patchJump(self: *Compiler, idx: usize) void {
        self.patchJumpToLabel(idx, self.irLen());
    }

    pub fn patchJumpToLabel(self: *Compiler, jump_idx: usize, target: usize) void {
        if (jump_idx < self.ir_builder.instructions.items.len) {
            self.ir_builder.instructions.items[jump_idx].op_arg = @intCast(target);
        }
    }

    pub fn regDupe(self: *Compiler) !void {
        std.debug.assert(self.active_registers != 0);
        const dst = try toRegister(self.active_registers);
        try self.spans.append(self.alloc, self.active_span);
        self.active_registers += 1;
        if (self.active_registers > self.max_registers) self.max_registers = self.active_registers;
        try self.recordMove(dst);
    }

    pub fn regRelease(self: *Compiler) !void {
        std.debug.assert(self.active_registers != 0);
        state_mod.popRegister(self);
    }

    pub fn pushNil(self: *Compiler) !void {
        const dst = try state_mod.pushRegister(self);
        try self.spans.append(self.alloc, self.active_span);
        try self.recordLoad(.load_nil, dst, 0);
    }

    pub fn @"const"(self: *Compiler, v: Data) !void {
        if (v.asNum()) |n| {
            if (n >= 0 and n <= 65535 and @trunc(n) == n) {
                const dst = try state_mod.pushRegister(self);
                try self.spans.append(self.alloc, self.active_span);
                try self.recordLoad(.load_small_int, dst, @intFromFloat(n));
                return;
            }
        }
        const idx = try self.vm.addConstant(v);
        const dst = try state_mod.pushRegister(self);
        try self.spans.append(self.alloc, self.active_span);
        try self.recordLoad(.load_const, dst, idx);
    }

    pub fn emit(self: *Compiler, op: Opcode, op_arg: Operand) !void {
        var d = self.active_registers;
        var result_reg: u16 = 0;

        switch (op) {
            .add, .sub, .mul, .div, .mod, .add_int, .sub_int, .mul_int, .div_int, .mod_int, .div_float, .eq, .neq, .lt, .gt, .lte, .gte, .eq_int, .neq_int, .lt_int, .gt_int, .lte_int, .gte_int, .@"and", .@"or" => {
                std.debug.assert(d >= 2);
                result_reg = try toRegister(d - 2);
                d -= 1;
                const rhs = try self.pop();
                const lhs = try self.pop();
                _ = try self.record(op, &.{ .{ .inst = lhs }, .{ .inst = rhs } }, true, result_reg, 0);
            },
            .negate, .not, .negate_int, .negate_float => {
                std.debug.assert(d > 0);
                result_reg = try toRegister(d - 1);
                const opnd = try self.pop();
                _ = try self.record(op, &.{.{ .inst = opnd }}, true, result_reg, 0);
            },
            .load_global, .load_stdlib_global, .load_local, .load_upval, .closure, .table_new, .struct_new, .load_nil, .load_small_int, .load_const => {
                result_reg = try toRegister(d);
                d += 1;
                if (op == .load_const) {
                    try self.recordLoad(.load_const, result_reg, op_arg);
                } else if (op == .load_nil) {
                    try self.recordLoad(.load_nil, result_reg, 0);
                } else if (op == .load_small_int) {
                    try self.recordLoad(.load_small_int, result_reg, op_arg);
                } else {
                    try self.recordStackOp(op, 0, 1, result_reg, op_arg);
                }
            },
            .halt, .ret => {
                result_reg = if (d == 0) 0 else try toRegister(d - 1);
                try self.recordStackOp(op, 1, 0, result_reg, 0);
            },
            .jump => {
                result_reg = 0;
                try self.recordStackOp(op, 0, 0, result_reg, op_arg);
            },
            .jump_if_false, .jump_if_true, .jump_if_not_nil_and_not_err, .jump_if_err => {
                std.debug.assert(d > 0);
                result_reg = try toRegister(d - 1);
                d -= 1;
                try self.recordStackOp(op, 1, 0, result_reg, op_arg);
            },
            .store_global, .store_global_const, .store_upval => {
                std.debug.assert(d > 0);
                result_reg = try toRegister(d - 1);
                d -= 1;
                try self.recordStackOp(op, 1, 0, result_reg, op_arg);
            },
            .store_local, .bind_local => {
                std.debug.assert(d > 0);
                result_reg = try toRegister(d - 1);
                d -= 1;
                try self.recordStackOp(op, 1, 0, result_reg, op_arg);
            },
            .tuple_new => {
                std.debug.assert(d >= op_arg);
                result_reg = try toRegister(d - op_arg);
                const first = d - op_arg;
                d = first + 1;
                try self.recordStackOp(op, op_arg, 1, result_reg, op_arg);
            },
            .tuple_get => {
                std.debug.assert(d >= 2);
                result_reg = try toRegister(d - 2);
                d -= 1;
                try self.recordStackOp(op, 2, 1, result_reg, 0);
            },
            .table_set => {
                std.debug.assert(d >= 3);
                result_reg = try toRegister(d - 3);
                d -= 2;
                try self.recordStackOp(op, 3, 0, result_reg, 0);
            },
            .table_get => {
                std.debug.assert(d >= 2);
                result_reg = try toRegister(d - 2);
                d -= 1;
                try self.recordStackOp(op, 2, 1, result_reg, 0);
            },
            .table_set_atom, .struct_set_offset => {
                std.debug.assert(d >= 2);
                result_reg = try toRegister(d - 2);
                d -= 1;
                try self.recordStackOp(op, 2, 0, result_reg, op_arg);
            },
            .struct_set_method => {
                std.debug.assert(d >= 3);
                result_reg = try toRegister(d - 3);
                d -= 2;
                try self.recordStackOp(op, 3, 0, result_reg, 0);
            },
            .table_get_atom, .tuple_get_const, .struct_get_offset => {
                std.debug.assert(d > 0);
                result_reg = try toRegister(d - 1);
                try self.recordStackOp(op, 1, 1, result_reg, op_arg);
            },
            .call, .spawn => {
                std.debug.assert(d >= op_arg + 1);
                const base = d - op_arg - 1;
                result_reg = try toRegister(base);
                d = base + 1;
                try self.recordStackOp(op, op_arg + 1, 1, result_reg, op_arg);
            },
            .call_field => {
                const argc = op_arg & ~@as(Operand, 1 << 15);
                const needed = argc + 2;
                std.debug.assert(d >= needed);
                const base = d - needed;
                result_reg = try toRegister(base);
                d = base + 1;
                try self.recordStackOp(op, argc + 2, 1, result_reg, op_arg);
            },
            .join => {
                std.debug.assert(d > 0);
                result_reg = try toRegister(d - 1);
                try self.recordStackOp(op, 1, 1, result_reg, 0);
            },
            .yield => {
                result_reg = 0;
                try self.recordStackOp(op, 0, 0, result_reg, 0);
            },
            .move => unreachable,
            .range_init => {
                std.debug.assert(d >= 3);
                result_reg = try toRegister(d - 3);
                d -= 3;
                try self.recordStackOp(op, 3, 0, result_reg, op_arg);
            },
            .range_next => {
                std.debug.assert(d >= 3);
                result_reg = try toRegister(d);
                d += 3;
                try self.recordStackOp(op, 1, 3, result_reg, op_arg);
            },
            .range_for => {
                std.debug.assert(d >= 3);
                result_reg = try toRegister(d - 3);
                try self.recordStackOp(op, 3, 0, result_reg, op_arg);
            },
            .unwrap_result => {
                std.debug.assert(d > 0);
                result_reg = try toRegister(d - 1);
                try self.recordStackOp(op, 1, 1, result_reg, op_arg);
            },
        }

        try self.spans.append(self.alloc, self.active_span);
        self.active_registers = d;
        if (d > self.max_registers) self.max_registers = d;
    }

    pub fn compile(self: *Compiler, expr: *const Node, keep: bool) InternalLowerError!void {
        const prev_span = self.active_span;
        self.active_span = expr.span;
        defer self.active_span = prev_span;

        try self.compileValue(expr);
        if (!keep) try self.regRelease();
    }

    pub fn compileRoot(self: *Compiler, expr: *const Node) InternalLowerError!void {
        try self.compileFn(&.{}, null, expr, "__main", null);
        if (self.failure_reports.items.len != 0 or self.failure != null) return error.LoweringFailed;
        try self.emit(.call, 0);
        try self.emit(.halt, 0);
    }

    pub fn formatSuiteTestName(self: *Compiler, test_name: []const u8) ![]u8 {
        var out = try std.ArrayList(u8).initCapacity(self.alloc, test_name.len + 16);
        errdefer out.deinit(self.alloc);

        if (self.test_suite_names.items.len == 0) {
            try out.appendSlice(self.alloc, test_name);
            return out.toOwnedSlice(self.alloc);
        }

        try out.appendSlice(self.alloc, self.test_suite_names.items[0]);
        for (self.test_suite_names.items[1..]) |s| {
            try out.appendSlice(self.alloc, "::");
            try out.appendSlice(self.alloc, s);
        }
        try out.appendSlice(self.alloc, "::");
        try out.appendSlice(self.alloc, test_name);
        return out.toOwnedSlice(self.alloc);
    }

    pub fn compileValue(self: *Compiler, expr: *const Node) InternalLowerError!void {
        switch (expr.expr) {
            .binding => |binding| try self.compileBinding(binding, .con),
            .number => |n| {
                const value = n.value;
                // fit in i64 and whole? -> tagged int, else float
                if (std.math.isFinite(value) and
                    @floor(value) == value and
                    value >= @as(f64, @floatFromInt(std.math.minInt(i64))) and
                    value <= @as(f64, @floatFromInt(std.math.maxInt(i64))) and
                    !n.is_float)
                {
                    try self.@"const"(
                        Data.new.num(@as(i64, @intFromFloat(value))),
                    );
                } else try self.@"const"(Data.new.num(value));
            },
            .string => |s| try self.@"const"(try self.vm.ownDataString(s)),
            .multiline_string => |s| try self.@"const"(try self.vm.ownDataString(s)),
            .hash => |name| try self.@"const"(Data.new.atom(try self.vm.internAtom(name))),
            .nil => try self.@"const"(Data.new.atom(try self.vm.internAtom("nil"))),
            .ident => |name| {
                if (state_mod.resolveLocal(self, name)) |slot| {
                    try self.emit(.load_local, slot);
                } else if (try state_mod.resolveUpvalue(self, name)) |upval_id| {
                    // reuse cached reg only if still live
                    if (self.upvalue_cache.get(upval_id)) |cached_reg| {
                        if (cached_reg < self.active_registers - 1) {
                            const dst = try state_mod.pushRegister(self);
                            try self.spans.append(self.alloc, self.active_span);
                            try self.recordMove(dst);
                        } else {
                            try self.emit(.load_upval, upval_id);
                            try self.upvalue_cache.put(upval_id, self.active_registers - 1);
                        }
                    } else {
                        try self.emit(.load_upval, upval_id);
                        try self.upvalue_cache.put(upval_id, self.active_registers - 1);
                    }
                } else if (self.type_aliases.get(name)) |_| {
                    // type used as value
                    const msg = try std.fmt.allocPrint(
                        self.alloc,
                        "type name `{s}` used as a value",
                        .{name},
                    );
                    return self.fail(.ParseError, expr, msg);
                } else try self.emit(.load_global, try self.vm.internAtom(name));
            },
            .unary => |u| switch (u.op) {
                .negate => {
                    try self.compile(u.expr, true);
                    const op_type = type_check.inferExprType(self, u.expr);
                    const specialized: Opcode = if (op_type == .int)
                        .negate_int
                    else if (op_type == .float)
                        .negate_float
                    else
                        .negate;
                    try self.emit(specialized, 0);
                },
                .not => {
                    try self.compile(u.expr, true);
                    try self.emit(.not, 0);
                },
                .join => {
                    try self.compile(u.expr, true);
                    try self.emit(.join, 0);
                },
                .yield => {
                    try self.emit(.yield, 0);
                    try self.pushNil();
                },
                .spawn => switch (u.expr.expr) {
                    .call => |call| {
                        try self.compile(call.callee, true);
                        if (call.implicit_self) switch (call.callee.expr) {
                            .field => |field| try self.compile(field.object, true),
                            .index => |index| try self.compile(index.object, true),
                            else => {},
                        };
                        for (call.args) |arg| try self.compile(arg, true);
                        try self.emit(
                            .spawn,
                            @intCast(
                                call.args.len + @intFromBool(call.implicit_self),
                            ),
                        );
                    },
                    else => {
                        try self.compile(u.expr, true);
                        try self.emit(.spawn, 0);
                    },
                },
            },
            .binary => |b| {
                if (b.op == .@"union") return self.fail(
                    .UnsupportedSyntax,
                    expr,
                    "union type expression used as a value",
                );

                try self.compile(b.left, true);
                try self.compile(b.right, true);

                const left_type = type_check.inferExprType(self, b.left);
                const right_type = type_check.inferExprType(self, b.right);

                const both_numeric = (left_type == .int or left_type == .float) and
                    (right_type == .int or right_type == .float);
                const any_float = left_type == .float or right_type == .float;

                const specialized_op: Opcode = if (both_numeric)
                    switch (b.op) {
                        .add => if (any_float) .add else .add_int,
                        .sub => if (any_float) .sub else .sub_int,
                        .mul => if (any_float) .mul else .mul_int,
                        .div => if (any_float) .div_float else .div_int,
                        .mod => .mod_int,
                        .eq => .eq_int,
                        .neq => .neq_int,
                        .lt => .lt_int,
                        .gt => .gt_int,
                        .lte => .lte_int,
                        .gte => .gte_int,
                        .@"union" => unreachable,
                    }
                else switch (b.op) {
                    .@"union" => unreachable,
                    inline else => |tag| @field(Opcode, @tagName(tag)),
                };

                try self.emit(specialized_op, 0);
            },
            .and_expr => |v| try flow.compileAnd(self, v.left, v.right),
            .or_expr => |v| try flow.compileOr(self, v.left, v.right),
            .call => |call| try self.compileCall(call),
            .field => |field| {
                // typed struct field?
                if (self.resolveTypedStructFieldOffset(field.object, field.name)) |off| {
                    try self.compile(field.object, true);
                    try self.emit(.struct_get_offset, @intCast(off));
                } else {
                    try self.compile(field.object, true);
                    try self.emit(.table_get_atom, try self.vm.internAtom(field.name));
                }
            },
            .index => |index| {
                try self.compile(index.object, true);
                if (index.key.expr == .hash) try self.emit(
                    .table_get_atom,
                    try self.vm.internAtom(index.key.expr.hash),
                ) else if (state_mod.constTupleIndex(self, index)) |idx| try self.emit(
                    .tuple_get_const,
                    idx,
                ) else {
                    try self.compile(index.key, true);
                    try self.emit(.table_get, 0);
                }
            },
            .if_expr => |v| try flow.compileIf(self, v.condition, v.then_expr, v.else_expr),
            .decl => |d| {
                switch (d.inner.expr) {
                    .binding => |*b| {
                        const kind: values.BindingKind = switch (d.kind) {
                            .con => .con,
                            .let => .let,
                            .global => .global,
                            else => .con,
                        };
                        return try self.compileBinding(b.*, kind);
                    },
                    else => {},
                }
                return self.compile(d.inner, true);
            },
            .assign_expr => |assign| try values.compileAssign(self, assign.target, assign.value),
            .block => |exprs| try self.compileBlock(exprs),
            .tuple => |items| {
                for (items) |item| try self.compile(item, true);
                try self.emit(.tuple_new, @intCast(items.len));
            },
            .table => |entries| try values.compileTable(self, entries),
            .struct_def => |def| try values.compileStruct(self, expr, def.name, def.items),
            .return_expr => |val| {
                if (val) |v| {
                    try self.compile(v, true);
                    try validateReturnType(self, v);
                } else try self.pushNil();
                try self.emit(.ret, 1);
            },
            .import_expr => |path| {
                try self.emit(.load_global, try self.vm.internAtom("import"));
                try self.compile(path, true);
                try self.emit(.call, 1);
            },
            .comp_block => |cb| try self.compileComp(cb.expr),
            .loop_expr => |v| try flow.compileLoop(self, v.body),
            .for_loop => |v| try flow.compileFor(self, v.params, v.body, v.iter),
            .while_loop => |v| try flow.compileWhile(self, v.predicate, v.body),
            .break_expr => |value| try flow.compileBreak(self, expr, value),
            .fn_expr => |fn_expr| try self.compileFn(fn_expr.params, fn_expr.return_type, fn_expr.body, "<fn>", null),
            .match_expr => |v| try flow.compileMatch(self, v.subject, v.arms),
            .tuple_pattern => return self.fail(
                .UnsupportedSyntax,
                expr,
                "tuple patterns do not compile as values",
            ),
            .range_literal => return self.fail(
                .UnsupportedSyntax,
                expr,
                "range literals only go in forloops for now",
            ),
            .try_expr => |expr_ptr| {
                try self.compile(expr_ptr, true);
                try self.emit(.unwrap_result, 0);
            },
            .orelse_expr => |v| {
                try self.compile(v.left, true);
                const fail_jump = try self.jump(.jump_if_not_nil_and_not_err);
                try self.compile(v.right, true);
                self.patchJump(fail_jump);
                try self.emit(.unwrap_result, 1);
            },
            .test_block => |block| {
                if (self.test_mode and !block.skip) {
                    const test_label = try self.formatSuiteTestName(block.name);
                    defer self.alloc.free(test_label);
                    try self.emit(
                        .load_global,
                        try self.vm.internAtom("@dotest"),
                    );
                    try self.@"const"(
                        try self.vm.ownDataString(test_label),
                    );
                    try self.compile(block.body, true);
                    try self.emit(.call, 2);
                    try self.regRelease();
                }
                try self.pushNil();
            },
            .test_suite => |suite| {
                if (self.test_mode) {
                    const suite_label = try self.formatSuiteTestName(suite.name);
                    defer self.alloc.free(suite_label);
                    try self.emit(
                        .load_global,
                        try self.vm.internAtom("@dosuite"),
                    );
                    try self.@"const"(
                        try self.vm.ownDataString(suite_label),
                    );
                    try self.test_suite_names.append(self.alloc, suite.name);
                    defer _ = self.test_suite_names.pop();
                    try self.compile(suite.body, true);
                    try self.emit(.call, 2);
                    try self.regRelease();
                }
                try self.pushNil();
            },
            .type_alias => |t| {
                const type_info = type_check.evalTypeExpr(self, t.type_expr) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                };
                try self.type_aliases.put(t.name, type_info);
                try self.pushNil();
            },
            .macro_expr => return self.fail(
                .UnsupportedSyntax,
                expr,
                "syntax must be expanded before compilation",
            ),
            .proc_macro => return self.fail(
                .UnsupportedSyntax,
                expr,
                "proc must be expanded before compilation",
            ),
        }
    }

    pub fn compileCall(
        self: *Compiler,
        call: anytype,
    ) InternalLowerError!void {
        switch (call.callee.expr) {
            .field => |field| {
                try self.validateTypedCall(call.callee, call.args);
                // method call desugar: obj:method(args)
                const desugared = call.args.len > 0 and
                    call.args[0] == field.object;
                if (desugared) {
                    try self.compile(call.callee, true);
                    for (call.args) |arg| try self.compile(arg, true);
                    try self.emit(
                        .call,
                        @intCast(
                            call.args.len + @intFromBool(call.implicit_self),
                        ),
                    );
                } else {
                    if (try self.tryCompileBoundMethodCall(
                        field,
                        call.args,
                        call.implicit_self,
                    )) return;
                    try self.compile(field.object, true);
                    try self.@"const"(
                        Data.new.atom(try self.vm.internAtom(field.name)),
                    );
                    for (call.args) |arg| try self.compile(arg, true);
                    const argc = call.args.len |
                        (@as(usize, @intFromBool(call.implicit_self)) << 15);
                    try self.emit(.call_field, @intCast(argc));
                }
            },
            .index => |index| {
                try self.validateTypedCall(call.callee, call.args);
                try self.compile(index.object, true);
                try self.compile(index.key, true);
                for (call.args) |arg| try self.compile(arg, true);
                const argc = call.args.len |
                    (@as(usize, @intFromBool(call.implicit_self)) << 15);
                try self.emit(.call_field, @intCast(argc));
            },
            .ident => |fn_name| {
                const reordered_args = try validateCallArgs(
                    self,
                    fn_name,
                    call.args,
                );
                try self.validateStructInit(fn_name, call.callee, call.args);
                try self.compile(call.callee, true);

                // use reordered args if named params were used
                const args_to_compile = if (reordered_args.ptr != call.args.ptr)
                    reordered_args
                else
                    call.args;

                if (reordered_args.ptr == call.args.ptr) {
                    try self.validateTypedCall(call.callee, args_to_compile);
                }

                for (args_to_compile) |arg| {
                    if (arg.expr == .assign_expr) {
                        // in call context, assignment expressions should only compile their values
                        try self.compile(arg.expr.assign_expr.value, true);
                    } else {
                        try self.compile(arg, true);
                    }
                }
                if (reordered_args.ptr != call.args.ptr) self.alloc.free(
                    reordered_args,
                );
                try self.emit(
                    .call,
                    @intCast(
                        call.args.len + @intFromBool(call.implicit_self),
                    ),
                );
            },
            .fn_expr => {
                try self.validateTypedCall(call.callee, call.args);
                try self.compile(call.callee, true);
                for (call.args) |arg| try self.compile(arg, true);
                try self.emit(
                    .call,
                    @intCast(
                        call.args.len + @intFromBool(call.implicit_self),
                    ),
                );
            },
            else => {
                try self.validateTypedCall(call.callee, call.args);
                try self.compile(call.callee, true);
                for (call.args) |arg| try self.compile(arg, true);
                try self.emit(
                    .call,
                    @intCast(
                        call.args.len + @intFromBool(call.implicit_self),
                    ),
                );
            },
        }
    }

    fn validateTypedCall(
        self: *Compiler,
        callee: *const Node,
        args: []const *Node,
    ) InternalLowerError!void {
        const callee_type = type_check.inferExprType(self, callee);
        if (callee_type != .function) return;

        const sig = callee_type.function;
        // "any function" sentinel,,, can't validate params or return
        if (sig == &types.ANY_FN_SIG) return;
        const fn_sig = if (callee.expr == .ident)
            state_mod.findFnSignature(self, callee.expr.ident)
        else
            null;
        const fn_name = if (fn_sig != null and callee.expr == .ident) callee.expr.ident else "call";
        if (args.len != sig.params.len) {
            const expected_types = try self.buildTypesListFromInfo(sig.params);
            defer self.alloc.free(expected_types);
            const actual_types = try self.buildArgTypesList(args);
            defer self.alloc.free(actual_types);

            const actual_sig = if (fn_sig) |named| try formatCallSignatureWithNames(
                self.alloc,
                fn_name,
                named.param_names,
                actual_types,
            ) else try formatCallSignatureTypesOnly(self.alloc, fn_name, actual_types);
            const expected_sig = if (fn_sig) |named| try formatCallSignatureWithNames(
                self.alloc,
                fn_name,
                named.param_names,
                expected_types,
            ) else try formatCallSignatureTypesOnly(self.alloc, fn_name, expected_types);

            var extra_parts = try std.ArrayList(diagnostic.Part).initCapacity(
                self.alloc,
                if (args.len > sig.params.len) 1 else 0,
            );
            defer extra_parts.deinit(self.alloc);
            if (args.len > sig.params.len) {
                try self.appendUnexpectedArgPart(args, sig.params.len, &extra_parts);
            }

            const msg = try std.fmt.allocPrint(
                self.alloc,
                "{s} wants {d} arg(s), got {d}",
                .{
                    fn_name,
                    sig.params.len,
                    args.len,
                },
            );
            try extra_parts.append(self.alloc, .{ .note = actual_sig });
            try extra_parts.append(self.alloc, .{ .note = expected_sig });
            return self.setFailureParts(.ParseError, null, msg, extra_parts.items);
        }

        for (args, sig.params, 0..) |arg, expected_type, idx| {
            type_check.checkType(
                expected_type,
                type_check.inferExprType(self, arg),
            ) catch |err| switch (err) {
                error.TypeError => {
                    const actual_types = try self.buildArgTypesList(args);
                    defer self.alloc.free(actual_types);
                    const expected_types = try self.buildTypesListFromInfo(sig.params);
                    defer self.alloc.free(expected_types);

                    const actual_sig = if (fn_sig) |named| try formatCallSignatureWithNames(
                        self.alloc,
                        fn_name,
                        named.param_names,
                        actual_types,
                    ) else try formatCallSignatureTypesOnly(self.alloc, fn_name, actual_types);
                    const expected_sig = if (fn_sig) |named| try formatCallSignatureWithNames(
                        self.alloc,
                        fn_name,
                        named.param_names,
                        expected_types,
                    ) else try formatCallSignatureTypesOnly(self.alloc, fn_name, expected_types);

                    const display_name = if (fn_sig) |named| blk: {
                        if (idx < named.param_names.len) break :blk named.param_names[idx];
                        break :blk null;
                    } else null;

                    const actual_type = type_check.inferExprType(self, arg);
                    const headline = if (display_name) |name| blk: {
                        break :blk try std.fmt.allocPrint(
                            self.alloc,
                            "arg {d} (`{s}`) to `{s}` wants {s}, got {s}",
                            .{
                                idx + 1,
                                name,
                                fn_name,
                                types.typeName(expected_type),
                                types.typeName(actual_type),
                            },
                        );
                    } else blk: {
                        break :blk try std.fmt.allocPrint(
                            self.alloc,
                            "arg {d} on `{s}` wants {s}, got {s}",
                            .{
                                idx + 1,
                                fn_name,
                                types.typeName(expected_type),
                                types.typeName(actual_type),
                            },
                        );
                    };

                    var extra_parts = try std.ArrayList(diagnostic.Part).initCapacity(
                        self.alloc,
                        2,
                    );
                    defer extra_parts.deinit(self.alloc);
                    try extra_parts.append(self.alloc, .{ .note = actual_sig });
                    try extra_parts.append(self.alloc, .{ .note = expected_sig });
                    return self.setFailureParts(
                        .ParseError,
                        .{ .span = arg.span, .role = .primary, .message = "wrong type!" },
                        headline,
                        extra_parts.items,
                    );
                },
            };
        }
    }

    fn validateStructInit(
        self: *Compiler,
        struct_name: []const u8,
        callee: *const Node,
        args: []const *Node,
    ) InternalLowerError!void {
        const callee_type = type_check.inferExprType(self, callee);
        if (callee_type != .struct_type) return;
        const field_defs = self.struct_layouts.get(struct_name) orelse return;
        if (args.len == 0) return;

        const init_arg = args[0];
        if (init_arg.expr != .table) return;

        for (init_arg.expr.table) |entry| {
            const key = entry.key orelse continue;
            if (key.expr != .ident) continue;
            const field_name = key.expr.ident;

            for (field_defs) |fd| {
                if (!std.mem.eql(u8, fd.name, field_name)) continue;
                if (fd.field_type == .any) break;

                type_check.checkType(
                    fd.field_type,
                    type_check.inferExprType(self, entry.value),
                ) catch |err| switch (err) {
                    error.TypeError => {
                        const actual = type_check.inferExprType(self, entry.value);
                        const headline = try std.fmt.allocPrint(
                            self.alloc,
                            "field `{s}` on `{s}` wants {s}, got {s}",
                            .{
                                field_name,
                                struct_name,
                                try types.formatType(self.alloc, fd.field_type),
                                types.typeName(actual),
                            },
                        );

                        return self.setFailureParts(
                            .ParseError,
                            .{ .span = entry.value.span, .role = .primary, .message = "wrong type!" },
                            headline,
                            &.{},
                        );
                    },
                    else => |e| return e,
                };
                break;
            }
        }
    }

    fn tryCompileBoundMethodCall(
        self: *Compiler,
        field: anytype,
        args: []const *Node,
        implicit_self: bool,
    ) InternalLowerError!bool {
        const module_name = switch (type_check.inferExprType(
            self,
            field.object,
        )) {
            .string => "string",
            .tuple => "tuple",
            .struct_type => |name| if (std.mem.eql(u8, name, "table")) "table" else return false,
            else => return false,
        };

        if (std.mem.eql(u8, module_name, "table") and
            std.mem.eql(u8, field.name, "add")) return false;

        if (std.mem.eql(u8, module_name, "table") and
            field.object.expr == .ident)
        {
            const local_ = state_mod.resolveLocalVar(self, field.object.expr.ident);
            const fields = if (local_) |l| l.table_fields else null;
            if (fields) |fs| {
                for (fs) |f| {
                    if (std.mem.eql(u8, f, field.name)) return false;
                }
            }
        }

        const module_atom = try self.vm.internAtom(module_name);
        const module = self.vm.stdlib_globals.get(module_atom) orelse return false;
        const module_table_id = module.asTable() orelse return false;
        const module_table = self.vm.tables.get(module_table_id) catch return false;

        const method_atom = try self.vm.internAtom(field.name);
        const method = module_table.getRawAtom(method_atom) orelse return false;
        if (!method.isFunction()) return false;

        try self.emit(.load_stdlib_global, module_atom);
        try self.emit(.table_get_atom, method_atom);
        if (implicit_self)
            try self.compile(field.object, true);
        for (args) |arg| try self.compile(arg, true);
        try self.emit(.call, @intCast(args.len + @intFromBool(implicit_self)));
        return true;
    }

    fn isNamedParam(arg: *const Node) ?[]const u8 {
        if (arg.expr != .assign_expr) return null;
        const assign = arg.expr.assign_expr;
        if (assign.target.expr != .ident) return null;
        return assign.target.expr.ident;
    }

    fn tryReorderNamedParams(
        self: *Compiler,
        args: []const *Node,
        sig: *const FunctionState.FnSig,
    ) ![]const *Node {
        var has_named = false;
        var had_error = false;
        for (args) |arg| {
            if (isNamedParam(arg) != null) {
                has_named = true;
            } else if (has_named) {
                const msg = try std.fmt.allocPrint(
                    self.alloc,
                    "positional arg cannot follow named arg",
                    .{},
                );
                try self.appendFailureReport(.ParseError, &.{
                    .{ .@"error" = msg },
                    .{ .span = .{
                        .span = arg.span,
                        .role = .primary,
                    } },
                });
                had_error = true;
            }
        }

        if (!has_named) return args;

        var reordered = try self.alloc.alloc(*Node, args.len);
        errdefer self.alloc.free(reordered);

        var param_seen = try self.alloc.alloc(bool, sig.param_names.len);
        defer self.alloc.free(param_seen);
        for (param_seen) |*p| p.* = false;

        var positional_idx: usize = 0;

        for (args) |arg| {
            if (isNamedParam(arg)) |param_name| {
                var found = false;
                for (sig.param_names, 0..) |sig_name, param_idx| {
                    if (std.mem.eql(u8, sig_name, param_name)) {
                        if (param_seen[param_idx]) {
                            const msg = try std.fmt.allocPrint(
                                self.alloc,
                                "parameter `{s}` specified multiple times",
                                .{param_name},
                            );
                            try self.appendFailureReport(.ParseError, &.{
                                .{ .@"error" = msg },
                                .{ .span = .{
                                    .span = arg.span,
                                    .role = .primary,
                                } },
                            });
                            had_error = true;
                            found = true;
                            break;
                        }
                        param_seen[param_idx] = true;
                        reordered[param_idx] = arg;
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    const msg = try std.fmt.allocPrint(
                        self.alloc,
                        "unknown parameter `{s}` (expected one of: {s})",
                        .{
                            param_name,
                            try std.mem.join(
                                self.alloc,
                                ", ",
                                sig.param_names,
                            ),
                        },
                    );
                    try self.appendFailureReport(.ParseError, &.{
                        .{ .@"error" = msg },
                        .{ .span = .{
                            .span = arg.span,
                            .role = .primary,
                        } },
                    });
                    had_error = true;
                }
            } else {
                if (positional_idx >= sig.param_names.len) {
                    const msg = try std.fmt.allocPrint(
                        self.alloc,
                        "too many positional args",
                        .{},
                    );
                    try self.appendFailureReport(.ParseError, &.{
                        .{ .@"error" = msg },
                        .{ .span = .{
                            .span = arg.span,
                            .role = .primary,
                        } },
                    });
                    had_error = true;
                    continue;
                }
                reordered[positional_idx] = arg;
                param_seen[positional_idx] = true;
                positional_idx += 1;
            }
        }

        if (had_error) return error.LoweringFailed;
        return reordered;
    }

    fn validateCallArgs(
        self: *Compiler,
        fn_name: []const u8,
        args: []const *Node,
    ) InternalLowerError![]const *Node {
        const fn_state = state_mod.currentFunctionState(self) orelse return args;
        const sig = fn_state.fn_signatures.get(fn_name) orelse return args;
        const reordered_args = try tryReorderNamedParams(self, args, sig);
        var had_error = false;

        if (reordered_args.len != sig.param_types.len) {
            var extra_parts = try std.ArrayList(diagnostic.Part).initCapacity(self.alloc, 1);
            defer extra_parts.deinit(self.alloc);
            if (reordered_args.len > sig.param_types.len) {
                try self.appendUnexpectedArgPart(
                    reordered_args,
                    sig.param_types.len,
                    &extra_parts,
                );
            }
            const msg = try std.fmt.allocPrint(
                self.alloc,
                "call to `{s}` wants {d} arg(s), got {d}",
                .{
                    fn_name,
                    sig.param_types.len,
                    reordered_args.len,
                },
            );
            if (extra_parts.items.len > 0) {
                try self.appendFailureReport(.ParseError, &.{
                    .{ .@"error" = msg },
                    extra_parts.items[0],
                });
            } else {
                try self.appendFailureReport(.ParseError, &.{
                    .{ .@"error" = msg },
                });
            }
            had_error = true;
        }

        const min_args = @min(sig.param_types.len, reordered_args.len);
        for (0..min_args) |i| {
            if (sig.param_types[i]) |expected_type| {
                const actual_type = type_check.inferExprType(
                    self,
                    reordered_args[i],
                );
                type_check.checkType(
                    types.resolveTypeName(self, expected_type),
                    actual_type,
                ) catch |err| switch (err) {
                    error.TypeError => {
                        const actual_str = try types.formatType(self.alloc, actual_type);
                        const label = if (sig.param_names[i].len == 0)
                            try std.fmt.allocPrint(
                                self.alloc,
                                "arg {d}",
                                .{i + 1},
                            )
                        else
                            try std.fmt.allocPrint(
                                self.alloc,
                                "arg {d} (`{s}`)",
                                .{ i + 1, sig.param_names[i] },
                            );

                        const headline = if (sig.param_names[i].len == 0)
                            try std.fmt.allocPrint(
                                self.alloc,
                                "arg {d} to `{s}` wants {s}, got {s}",
                                .{
                                    i + 1,
                                    fn_name,
                                    expected_type,
                                    actual_str,
                                },
                            )
                        else
                            try std.fmt.allocPrint(
                                self.alloc,
                                "arg {d} (`{s}`) to `{s}` wants {s}, got {s}",
                                .{
                                    i + 1,
                                    sig.param_names[i],
                                    fn_name,
                                    expected_type,
                                    actual_str,
                                },
                            );
                        try self.appendFailureReport(.ParseError, &.{
                            .{ .@"error" = headline },
                            .{ .span = .{
                                .span = reordered_args[i].span,
                                .role = .primary,
                                .message = label,
                            } },
                        });
                        had_error = true;
                    },
                };
            }
        }
        if (had_error) return error.LoweringFailed;
        return reordered_args;
    }

    fn buildTypesListFromInfo(
        self: *Compiler,
        type_infos: []const types.TypeInfo,
    ) ![]const []const u8 {
        var list = try std.ArrayList([]const u8).initCapacity(
            self.alloc,
            type_infos.len,
        );
        for (type_infos) |type_info| {
            try list.append(self.alloc, types.typeName(type_info));
        }
        return try list.toOwnedSlice(self.alloc);
    }

    fn buildArgTypesList(
        self: *Compiler,
        args: []const *const Node,
    ) ![]const []const u8 {
        var list = try std.ArrayList([]const u8).initCapacity(
            self.alloc,
            args.len,
        );
        for (args) |arg| {
            const arg_type = type_check.inferExprType(self, arg);
            try list.append(self.alloc, types.typeName(arg_type));
        }
        return try list.toOwnedSlice(self.alloc);
    }

    fn formatCallSignatureTypesOnly(
        alloc: std.mem.Allocator,
        fn_name: []const u8,
        types_list: []const []const u8,
    ) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(
            alloc,
            fn_name.len + types_list.len * 8 + 4,
        );
        defer buf.deinit(alloc);
        try buf.appendSlice(alloc, fn_name);
        try buf.append(alloc, '(');
        for (types_list, 0..) |type_name, idx| {
            if (idx > 0) try buf.appendSlice(alloc, ", ");
            try buf.appendSlice(alloc, type_name);
        }
        try buf.append(alloc, ')');
        return try buf.toOwnedSlice(alloc);
    }

    fn formatCallSignatureWithNames(
        alloc: std.mem.Allocator,
        fn_name: []const u8,
        param_names: []const []const u8,
        types_list: []const []const u8,
    ) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(
            alloc,
            fn_name.len + types_list.len * 16 + 4,
        );
        defer buf.deinit(alloc);
        try buf.appendSlice(alloc, fn_name);
        try buf.append(alloc, '(');
        for (types_list, 0..) |type_name, idx| {
            if (idx > 0) try buf.appendSlice(alloc, ", ");
            if (idx < param_names.len and param_names[idx].len > 0) {
                try buf.appendSlice(alloc, param_names[idx]);
                try buf.appendSlice(alloc, ": ");
            }
            try buf.appendSlice(alloc, type_name);
        }
        try buf.append(alloc, ')');
        return try buf.toOwnedSlice(alloc);
    }

    pub fn resolveTypedStructFieldOffset(
        self: *Compiler,
        object: *const Node,
        field_name: []const u8,
    ) ?usize {
        if (object.expr != .ident) return null;
        return switch (type_check.inferExprType(self, object)) {
            .struct_type => |type_name| blk: {
                const type_id = self.vm.struct_types.findTypeByName(type_name) orelse break :blk null;
                const desc = self.vm.struct_types.getType(type_id) orelse break :blk null;
                const field_atom = self.vm.internAtom(field_name) catch break :blk null;
                break :blk desc.fieldIndex(field_atom);
            },
            else => null,
        };
    }

    pub fn compileComp(self: *Compiler, expr: *Node) InternalLowerError!void {
        var temp_compiler = try Compiler.init(
            self.vm,
            self.test_mode,
            self.alloc,
            self.runtime_alloc,
        );
        defer temp_compiler.deinit();
        temp_compiler.compileRoot(expr) catch |err| switch (err) {
            error.LoweringFailed => {
                const nested_failure = try temp_compiler.finishFailure() orelse unreachable;
                const report = try nested_failure.report.copy(self.runtime_alloc);
                self.failure = .{
                    .kind = nested_failure.kind,
                    .report = report,
                };
                return error.LoweringFailed;
            },
            else => return err,
        };
        const artifact = try temp_compiler.finishArtifact();
        defer self.vm.runtime.alloc.free(artifact.instructions);
        defer self.vm.runtime.alloc.free(artifact.spans);
        const result = try VM.module.runCompiledModuleReport(
            self.comp_vm,
            "<comp>",
            artifact.instructions,
        );
        if (result == .err) {
            const eval_failure = result.err;
            const msg = try self.runtime_alloc.dupe(u8, eval_failure.report.message);
            const parts = try self.runtime_alloc.dupe(
                diagnostic.Part,
                eval_failure.report.parts,
            );
            parts[0] = diagnostic.Part{ .@"error" = msg };
            if (parts.len > 1) {
                if (parts[1] == .span) {
                    parts[1].span = .{
                        .span = expr.span,
                        .role = .primary,
                    };
                }
            }
            self.failure = .{
                .kind = .ParseError,
                .report = .{
                    .parts = parts,
                    .message = msg,
                    .source_name = eval_failure.report.source_name,
                    .source = eval_failure.report.source,
                },
            };
            return error.LoweringFailed;
        }
        try self.@"const"(self.comp_vm.mainResult());
    }

    pub fn compileBlock(self: *Compiler, exprs: []const *Node) InternalLowerError!void {
        if (exprs.len == 0) return self.pushNil();
        var pushed_scope = false;
        if (state_mod.currentFunctionState(self) != null) {
            try state_mod.pushScope(self);
            pushed_scope = true;
            errdefer if (pushed_scope) state_mod.popScope(self);
            try state_mod.predeclareFunctionBindings(self, exprs);
        }
        for (exprs, 0..) |expr, idx| {
            self.upvalue_cache.clearRetainingCapacity();
            const before = self.active_registers;
            self.compile(expr, true) catch |err| switch (err) {
                error.LoweringFailed => {
                    try self.recordFailure();
                    self.active_registers = before;
                    continue;
                },
                else => return err,
            };
            if (idx + 1 < exprs.len and self.active_registers > before) try self.regRelease();
        }
        if (pushed_scope and self.fn_return_type != null and exprs.len > 0) {
            const last = exprs[exprs.len - 1];
            if (last.expr != .return_expr) {
                const actual = type_check.inferExprType(self, last);
                const expected = types.resolveTypeName(self, self.fn_return_type.?);
                type_check.checkType(expected, actual) catch |err| switch (err) {
                    error.TypeError => {
                        const actual_str = try types.formatType(self.alloc, actual);
                        const expected_str = try types.formatType(self.alloc, expected);
                        const msg = try std.fmt.allocPrint(
                            self.alloc,
                            "return type mismatch: wanted {s}, got {s}",
                            .{ self.fn_return_type.?, actual_str },
                        );
                        return self.setFailureParts(
                            .ParseError,
                            .{
                                .span = last.span,
                                .role = .primary,
                                .message = try std.fmt.allocPrint(self.alloc, "return type not {s} (got {s})", .{
                                    expected_str,
                                    actual_str,
                                }),
                            },
                            msg,
                            &.{},
                        );
                    },
                };
            }
        }
        if (pushed_scope) state_mod.popScope(self);
    }

    const BindingKind = values.BindingKind;

    pub fn compileBinding(
        self: *Compiler,
        binding: Binding,
        kind: BindingKind,
    ) InternalLowerError!void {
        if (binding.target.expr == .ident and kind != .global) {
            return values.compileLocalBinding(
                self,
                binding.target.expr.ident,
                binding.value,
                kind != .con,
                binding.type_name,
            );
        }

        if (binding.target.expr == .ident) {
            const name = binding.target.expr.ident;
            if (std.mem.endsWith(u8, name, "!"))
                return self.setFailureParts(
                    .ParseError,
                    .{ .span = binding.target.span, .role = .primary, .message = name },
                    "name with ! is reserved for macros",
                    &.{},
                );
            if (std.mem.endsWith(u8, name, "?") and !ast.isDiscardName(name) and binding.value.expr != .fn_expr)
                return self.setFailureParts(
                    .ParseError,
                    .{ .span = binding.target.span, .role = .primary, .message = name },
                    "name with ? is reserved for functions returning bool",
                    &.{},
                );
            if (binding.type_name) |tn| {
                type_check.validateBindingType(self, tn, binding.value) catch |err| switch (err) {
                    error.TypeError => {
                        const actual = type_check.inferExprType(self, binding.value);
                        const expected_type = try types.evalTypeExpr(self, tn);
                        const tn_str = try types.formatType(self.alloc, expected_type);
                        const msg = try std.fmt.allocPrint(
                            self.alloc,
                            "`{s}` wants {s}, got {s}",
                            .{ name, tn_str, types.typeName(actual) },
                        );
                        const label = try std.fmt.allocPrint(self.alloc, "not {s}!", .{tn_str});
                        self.alloc.free(tn_str);
                        return self.setFailureParts(
                            .ParseError,
                            .{
                                .span = binding.value.span,
                                .role = .primary,
                                .message = label,
                            },
                            msg,
                            &.{},
                        );
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                };
            }

            if (binding.value.expr == .fn_expr) {
                try self.compileFn(
                    binding.value.expr.fn_expr.params,
                    binding.value.expr.fn_expr.return_type,
                    binding.value.expr.fn_expr.body,
                    name,
                    null,
                );
            } else try self.compile(binding.value, true);

            const inferred_type = if (binding.type_name) |tn|
                try types.evalTypeExpr(self, tn)
            else
                type_check.inferExprType(self, binding.value);
            try state_mod.setLocalTypeHint(self, name, inferred_type);

            if (ast.isDiscardName(name)) return;
            try self.regDupe();
            try self.emit(
                if (kind != .con) .store_global else .store_global_const,
                try self.vm.internAtom(name),
            );
            return;
        }

        if (binding.target.expr == .tuple_pattern) {
            try values.validateTuplePatternShape(
                self,
                binding.target.expr.tuple_pattern,
                binding.value,
                "binding",
            );
            if (binding.type_name) |tn| {
                type_check.validateBindingType(self, tn, binding.value) catch |err| switch (err) {
                    error.TypeError => {
                        const actual = type_check.inferExprType(self, binding.value);
                        const expected_type = try types.evalTypeExpr(self, tn);
                        const tn_str = try types.formatType(self.alloc, expected_type);
                        const msg = try std.fmt.allocPrint(
                            self.alloc,
                            "binding wants {s}, got {s}",
                            .{ tn_str, types.typeName(actual) },
                        );
                        self.alloc.free(tn_str);
                        return self.setFailureParts(
                            .ParseError,
                            .{ .span = binding.value.span, .role = .primary, .message = msg },
                            msg,
                            &.{},
                        );
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                };
            }
            try values.declarePatternLocals(
                self,
                binding.target,
                kind != .con,
            );
        }

        try self.compile(binding.value, true);
        const src_idx = self.active_registers - 1;
        try values.bindDeclaredPattern(self, binding.target, src_idx, kind);
    }

    pub fn compileFn(
        self: *Compiler,
        params: []const ast.FnParam,
        return_type: ?*ast.TypeExpr,
        body: *const Node,
        name: []const u8,
        loop_sym: ?revo.AtomID,
    ) InternalLowerError!void {
        if (!ast.isDiscardName(name) and !std.mem.eql(u8, name, "<fn>")) {
            if (std.mem.endsWith(u8, name, "!"))
                return self.setFailureParts(
                    .ParseError,
                    .{ .span = body.span, .role = .primary, .message = name },
                    "function name with ! is reserved for macros",
                    &.{},
                );
            if (std.mem.endsWith(u8, name, "?")) {
                if (return_type) |rt| {
                    const rt_name = switch (rt.kind) {
                        .named => |n| n,
                        else => @tagName(rt.kind),
                    };
                    if (!std.mem.eql(u8, rt_name, "bool"))
                        return self.setFailureParts(
                            .ParseError,
                            .{ .span = body.span, .role = .primary, .message = name },
                            "function ending with ? must return bool",
                            &.{},
                        );
                }
            }
        }

        // names ending with ? must return bool (forced if not explicit)
        const effective_return_type: ?*ast.TypeExpr = if (std.mem.endsWith(u8, name, "?") and !ast.isDiscardName(name) and !std.mem.eql(u8, name, "<fn>"))
            if (return_type) |rt| rt else try ast.allocTypeExpr(self.alloc, body.span, .{ .named = "bool" })
        else
            return_type;

        const jump_over = try self.jump(.jump);
        const body_addr: ProgramCounter = @intCast(self.irLen());
        const caller_registers = self.active_registers;
        const caller_max_registers = self.max_registers;
        errdefer {
            self.active_registers = caller_registers;
            self.max_registers = caller_max_registers;
        }

        const own_sig = !(ast.isDiscardName(name) or std.mem.eql(u8, name, "<fn>"));
        const sig = try state_mod.allocFnSig(self, params, effective_return_type);

        var s = try FunctionState.init(self.alloc);
        s.return_type = if (effective_return_type) |rt| switch (rt.kind) {
            .named => |n| n,
            else => @tagName(rt.kind),
        } else null;
        for (params, 0..) |param, idx| {
            const local: LocalVar = .{
                .name = param.name,
                .slot = @intCast(idx),
                .mutable = true,
                .initialized = true,
                .type_name = if (param.type_name) |tn| switch (tn.kind) {
                    .named => |n| n,
                    else => types.typeName(try types.evalTypeExpr(self, tn)),
                } else null,
                .type_explicit = param.type_name != null,
            };
            s.locals.append(self.alloc, local) catch |err| {
                s.deinit(self.alloc);
                return err;
            };
            s.all_locals.append(self.alloc, local) catch |err| {
                s.deinit(self.alloc);
                return err;
            };
            if (param.type_name) |type_name| {
                s.type_hints.append(self.alloc, .{
                    .name = param.name,
                    .type_info = try types.evalTypeExpr(self, type_name),
                }) catch |err| {
                    s.deinit(self.alloc);
                    return err;
                };
            }
        }
        const params_len: LocalSlot = @intCast(params.len);
        self.functions.append(self.alloc, s) catch |err| {
            s.deinit(self.alloc);
            return err;
        };
        self.slot_allocators.append(self.alloc, params_len) catch |err| {
            var leaked = self.functions.pop() orelse unreachable;
            leaked.deinit(self.alloc);
            return err;
        };
        var state_pushed = true;
        errdefer if (state_pushed) {
            var leaked = self.functions.pop() orelse unreachable;
            leaked.deinit(self.alloc);
            _ = self.slot_allocators.pop() orelse unreachable;
        };

        const prev_in_loop = self.in_loop_depth;
        self.in_loop_depth = 0;
        if (loop_sym != null) self.in_loop_depth += 1;
        defer self.in_loop_depth = prev_in_loop;

        self.active_registers = params.len;
        self.max_registers = params.len;
        self.upvalue_cache.clearRetainingCapacity();
        if (own_sig) try s.fn_signatures.put(name, sig);
        self.fn_return_type = if (effective_return_type) |rt| switch (rt.kind) {
            .named => |n| n,
            else => @tagName(rt.kind),
        } else null;
        defer self.fn_return_type = null;
        try self.compile(body, true);
        if (effective_return_type) |rt| {
            if (body.expr != .block) {
                const rt_name = switch (rt.kind) {
                    .named => |n| n,
                    else => @tagName(rt.kind),
                };
                try validateImplicitReturnType(self, body, rt_name);
            }
        } else {
            const inferred_type = type_check.inferExprType(self, body);
            const inferred_type_str = try self.alloc.dupe(u8, types.typeName(inferred_type));
            sig.return_type = inferred_type_str;
        }
        if (self.failure_reports.items.len != 0 or self.failure != null) return error.LoweringFailed;
        if (self.active_registers == 0) try self.pushNil();
        if (loop_sym) |sym| try flow.emitLoopRecurse(self, params.len, sym) else try self.emit(.ret, 1);

        const fn_register_count = self.max_registers;
        self.active_registers = caller_registers;
        self.max_registers = caller_max_registers;

        var finished = self.functions.pop() orelse unreachable;
        defer finished.deinit(self.alloc);

        _ = self.slot_allocators.pop() orelse unreachable;

        var cl_out = try std.ArrayList(LocalSlot).initCapacity(self.alloc, finished.all_locals.items.len);
        defer cl_out.deinit(self.alloc);
        for (finished.all_locals.items) |local| if (!local.mutable) try cl_out.append(self.alloc, local.slot);
        const const_locals = try cl_out.toOwnedSlice(self.alloc);
        defer self.alloc.free(const_locals);

        self.patchJump(jump_over);
        const proto_id = try self.vm.functions.createPrototype(.{
            .addr = body_addr,
            .arity = @intCast(params.len),
            .register_count = @intCast(fn_register_count),
            .name = name,
            .upvalue_specs = finished.upvalues.items,
            .const_locals = const_locals,
            .const_local_bits = &.{},
        });
        try self.pending_prototypes.append(self.alloc, proto_id);
        try self.emit(.closure, proto_id);

        if (!own_sig) {
            self.alloc.free(sig.param_types);
            self.alloc.destroy(sig);
        }

        state_pushed = false;
    }

    fn appendUnexpectedArgPart(
        self: *Compiler,
        args: []const *const Node,
        start_idx: usize,
        parts: *std.ArrayList(diagnostic.Part),
    ) !void {
        if (start_idx >= args.len) return;
        const merged = blk: {
            var span = args[start_idx].span;
            for (args[start_idx + 1 ..]) |arg| span = ast.Span.merge(span, arg.span);
            break :blk span;
        };
        try parts.append(self.alloc, .{
            .span = .{
                .span = merged,
                .role = .secondary,
                .message = "unexpected args",
            },
        });
    }

    fn appendFailureReport(
        self: *Compiler,
        kind: LowerErrorKind,
        parts: []const diagnostic.Part,
    ) !void {
        const copied_parts = try self.alloc.dupe(diagnostic.Part, parts);
        try self.failure_reports.append(self.alloc, .{
            .kind = kind,
            .report = .{
                .parts = copied_parts,
                .message = "",
            },
        });
    }

    pub fn setFailureParts(
        self: *Compiler,
        kind: LowerErrorKind,
        primary_span: ?diagnostic.SpanPart,
        message: []const u8,
        extra_parts: []const diagnostic.Part,
    ) error{LoweringFailed} {
        const owned_msg = self.runtime_alloc.dupe(u8, message) catch "out of memory while formatting error message";
        if (self.failure_message_owned) self.runtime_alloc.free(self.failure_message);
        self.failure_message = owned_msg;
        self.failure_message_owned = owned_msg.ptr != message.ptr;

        self.failure_parts[0] = diagnostic.Part{ .@"error" = owned_msg };
        var part_len: usize = 1;
        if (primary_span) |span| {
            self.failure_parts[1] = .{ .span = span };
            part_len += 1;
        }
        const available = self.failure_parts.len - part_len;
        const extra_len = @min(extra_parts.len, available);
        for (extra_parts[0..extra_len], 0..) |part, idx| self.failure_parts[part_len + idx] = part;
        self.failure_part_len = part_len + extra_len;
        self.failure = .{
            .kind = kind,
            .report = .{
                .parts = self.failure_parts[0..self.failure_part_len],
                .message = owned_msg,
            },
        };
        return error.LoweringFailed;
    }

    fn recordFailure(self: *Compiler) !void {
        const current = self.failure orelse return;
        const copied = try current.report.copy(self.alloc);
        try self.failure_reports.append(self.alloc, .{
            .kind = current.kind,
            .report = copied,
        });
        self.failure = null;
    }

    fn finishFailure(self: *Compiler) !?LowerFailure {
        if (self.failure != null) try self.recordFailure();
        if (self.failure_reports.items.len == 0) return null;
        if (self.failure_reports.items.len == 1) return self.failure_reports.items[0];

        var total_parts: usize = 0;
        for (self.failure_reports.items) |failure| total_parts += failure.report.parts.len;
        var parts = try std.ArrayList(diagnostic.Part).initCapacity(self.alloc, total_parts);
        for (self.failure_reports.items) |failure| {
            try parts.appendSlice(self.alloc, failure.report.parts);
        }

        const first = self.failure_reports.items[0];
        return .{
            .kind = first.kind,
            .report = .{
                .parts = try parts.toOwnedSlice(self.alloc),
                .message = "",
                .source_name = first.report.source_name,
                .source = first.report.source,
            },
        };
    }

    fn validateReturnType(self: *Compiler, val: *const Node) !void {
        const fn_state = state_mod.currentFunctionState(self) orelse return;
        const declared = fn_state.return_type orelse return;
        const actual = type_check.inferExprType(self, val);
        const expected = types.resolveTypeName(self, declared);
        type_check.checkType(expected, actual) catch |err| switch (err) {
            error.TypeError => {
                const actual_str = try types.formatType(self.alloc, actual);
                const msg = try std.fmt.allocPrint(
                    self.alloc,
                    "return type mismatch: wanted {s}, got {s}",
                    .{ declared, actual_str },
                );
                return self.setFailureParts(
                    .ParseError,
                    .{
                        .span = val.span,
                        .role = .primary,
                        .message = try std.fmt.allocPrint(
                            self.alloc,
                            "must return {s} (got {s})",
                            .{ declared, actual_str },
                        ),
                    },
                    msg,
                    &.{},
                );
            },
        };
    }

    fn validateImplicitReturnType(
        self: *Compiler,
        body: *const Node,
        declared: []const u8,
    ) !void {
        const last_expr = switch (body.expr) {
            .block => |exprs| if (exprs.len > 0) exprs[exprs.len - 1] else return,
            else => body,
        };
        if (last_expr.expr == .return_expr) return;
        const actual = type_check.inferExprType(self, last_expr);
        const expected = types.resolveTypeName(self, declared);
        type_check.checkType(expected, actual) catch |err| switch (err) {
            error.TypeError => {
                const actual_str = try types.formatType(self.alloc, actual);
                const expected_str = try types.formatType(self.alloc, expected);
                const msg = try std.fmt.allocPrint(
                    self.alloc,
                    "return type mismatch: wanted {s}, got {s}",
                    .{ declared, actual_str },
                );
                return self.setFailureParts(
                    .ParseError,
                    .{
                        .span = last_expr.span,
                        .role = .primary,
                        .message = try std.fmt.allocPrint(self.alloc, "return type not {s} (got {s})", .{
                            expected_str,
                            actual_str,
                        }),
                    },
                    msg,
                    &.{},
                );
            },
        };
    }

    // compat wrapper,,, failures should through this
    pub fn fail(
        self: *Compiler,
        kind: LowerErrorKind,
        expr: *const Node,
        message: []const u8,
    ) error{LoweringFailed} {
        return self.setFailureParts(kind, .{ .span = expr.span, .role = .primary }, message, &.{});
    }
};
