const std = @import("std");

const revo = @import("revo");
const Data = revo.Data;
const Instruction = revo.Instruction;
const Opcode = revo.opcode.Opcode;
const Operand = revo.Operand;
const Register = revo.opcode.Register;
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

pub const types = @import("types.zig");
pub const type_check = @import("type_check.zig");
const values = @import("values.zig");
const diagnostic = @import("../diagnostic.zig");

const toRegister = state_mod.toRegister;

pub const LowerErrorKind = enum {
    ParseError,
    CompileError,
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
    type_annotations: ?*const std.AutoHashMap(*const Node, types.TypeInfo),
) !ArtifactResult {
    var arena = std.heap.ArenaAllocator.init(vm.runtime.alloc);
    defer arena.deinit();

    var compiler = try Compiler.init(
        vm,
        test_mode,
        arena.allocator(),
        vm.runtime.alloc,
    );
    compiler.type_annotations = type_annotations;
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
    failure_parts: std.ArrayList(diagnostic.Part),
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
    struct_layouts: std.StringHashMap([]const types.FieldDef),
    ir_builder: ir.IrBuilder,
    value_stack: std.ArrayList(*ir.IrInst),
    // register cache for upvalue loads, cleared per-block in compileBlock
    upvalue_cache: std.AutoHashMap(usize, usize) = undefined,
    type_aliases: std.StringHashMap(types.TypeInfo),
    type_annotations: ?*const std.AutoHashMap(*const Node, types.TypeInfo) = null,
    fn_return_type: ?[]const u8 = null,
    pending_prototypes: std.ArrayList(revo.PrototypeID),
    declared_globals: std.StringHashMap(void),

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
            .struct_layouts = std.StringHashMap([]const types.FieldDef).init(arena),
            .ir_builder = try ir.IrBuilder.init(arena),
            .value_stack = try std.ArrayList(*ir.IrInst).initCapacity(arena, 32),
            .upvalue_cache = std.AutoHashMap(usize, usize).init(arena),
            .type_aliases = std.StringHashMap(types.TypeInfo).init(arena),
            .declared_globals = std.StringHashMap(void).init(arena),
            .pending_prototypes = try std.ArrayList(revo.PrototypeID).initCapacity(arena, 4),
            .failure_parts = .{ .items = &.{}, .capacity = 0 },
        };
    }

    pub fn deinit(self: *Compiler) void {
        if (self.failure_message_owned) self.runtime_alloc.free(self.failure_message);
        for (self.functions.items) |*s| s.deinit(self.alloc);
        self.functions.deinit(self.alloc);
        self.slot_allocators.deinit(self.alloc);
        self.failure_parts.deinit(self.alloc);
        self.failure_reports.deinit(self.alloc);
        self.spans.deinit(self.alloc);
        self.break_jumps.deinit(self.alloc);
        self.loop_result_regs.deinit(self.alloc);
        self.test_suite_names.deinit(self.alloc);
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

    pub fn isTypeParam(self: *Compiler, name: []const u8) bool {
        const fn_state = state_mod.currentFunctionState(self) orelse return false;
        for (fn_state.type_params) |tp|
            if (std.mem.eql(u8, tp, name)) return true;
        return false;
    }

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

    pub fn record(self: *Compiler, opcode: Opcode, ops: []const ir.IrValue, push_res: bool, result_reg: Register, op_arg: Operand) !*ir.IrInst {
        const inst = try self.alloc.create(ir.IrInst);
        inst.* = .{ .opcode = opcode, .operands = try self.alloc.dupe(ir.IrValue, ops) };
        try self.ir_builder.instructions.append(self.alloc, inst);
        inst.result_reg = result_reg;
        inst.op_arg = op_arg;
        if (push_res) try self.value_stack.append(self.alloc, inst);
        return inst;
    }

    pub fn recordStackOp(self: *Compiler, opcode: Opcode, pop_n: usize, push_n: usize, result_reg: Register, op_arg: Operand) !void {
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

    pub fn recordLoad(self: *Compiler, opcode: Opcode, result_reg: Register, op_arg: Operand) !void {
        _ = try self.record(opcode, &.{}, true, result_reg, op_arg);
    }

    pub fn recordMove(self: *Compiler, result_reg: Register) !void {
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
        var result_reg: Register = 0;

        switch (op) {
            .add, .sub, .mul, .div, .mod, .concat, .add_int, .sub_int, .mul_int, .mod_int, .div_float, .eq, .neq, .lt, .gt, .lte, .gte, .eq_int, .neq_int, .lt_int, .gt_int, .lte_int, .gte_int, .@"and", .@"or" => {
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
                const argc = op_arg & ~@as(Operand, 1 << 7);
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
        try self.compileFn(&.{}, null, expr, "__main", null, &.{});
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
            .binding => unreachable, // all bindings arrive wrapped in .decl
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
            .nil => try self.@"const"(Data.new.atom(revo.core_atoms.nil.atom_id())),
            .ident => |name| {
                if (state_mod.resolveLocal(self, name)) |slot| {
                    try self.emit(.load_local, slot);
                } else if (try state_mod.resolveUpvalue(self, name)) |upval_id| {
                    // reuse cached reg only if still live
                    if (self.upvalue_cache.get(upval_id)) |cached_reg| {
                        if (self.active_registers > 0 and cached_reg < self.active_registers - 1) {
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
                        .div => .div_float,
                        .mod => .mod_int,
                        .concat => .concat,
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
                        if (b.value.expr == .import_stmt and b.target.expr == .ident) {
                            // imports must be const, no type annotations
                            const user_name = b.target.expr.ident;
                            if (d.kind != .con) {
                                return self.fail(.ParseError, expr, "import binding must be const");
                            }
                            // compile import_stmt directly so it handles its own slot
                            // then also bind the user-specified name if it differs
                            try self.compile(b.value, true);
                            if (!std.mem.eql(u8, user_name, b.value.expr.import_stmt.name)) {
                                const slot = try state_mod.declareLocal(self, user_name, false);
                                state_mod.reserveLocalSlots(self);
                                try self.regDupe();
                                try self.emit(.bind_local, slot);
                            }
                            return;
                        }
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
                } else try self.pushNil();
                try self.emit(.ret, 1);
            },
            .import_stmt => |is| {
                const fn_state = state_mod.currentFunctionState(self) orelse return self.fail(
                    .ParseError,
                    expr,
                    "import statement outside function context",
                );
                if (state_mod.findLocalInCurrentScope(self, is.name)) |_| {
                    const msg = try std.fmt.allocPrint(self.alloc, "name `{s}` is already defined", .{is.name});
                    return self.fail(.ParseError, expr, msg);
                }
                // also check import_locals to prevent double import of same name
                for (fn_state.import_locals.items) |il| {
                    if (std.mem.eql(u8, il.name, is.name)) {
                        const msg = try std.fmt.allocPrint(self.alloc, "name `{s}` is already defined by another import", .{is.name});
                        return self.fail(.ParseError, expr, msg);
                    }
                }
                const slot = self.slot_allocators.items[self.slot_allocators.items.len - 1];
                self.slot_allocators.items[self.slot_allocators.items.len - 1] += 1;

                const import_local = LocalVar{ .name = is.name, .slot = slot, .mutable = false, .initialized = true };
                try fn_state.import_locals.append(self.alloc, import_local);
                try fn_state.all_locals.append(self.alloc, import_local);

                state_mod.reserveLocalSlots(self);

                try self.emit(.load_global, revo.core_atoms.import.atom_id());
                try self.@"const"(try self.vm.ownDataString(is.path));

                try self.emit(.call, 1);
                try self.regDupe();

                try self.emit(.bind_local, slot);
            },
            .comp_block => |cb| try self.compileComp(cb.expr),
            .loop_expr => |v| try flow.compileLoop(self, v.body),
            .for_loop => |v| try flow.compileFor(self, v.params, v.body, v.iter),
            .while_loop => |v| try flow.compileWhile(self, v.predicate, v.body),
            .break_expr => |value| try flow.compileBreak(self, expr, value),
            .fn_expr => |fn_expr| try self.compileFn(fn_expr.params, fn_expr.return_type, fn_expr.body, "<fn>", null, fn_expr.type_params),
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
            .quasiquote => return self.fail(
                .UnsupportedSyntax,
                expr,
                "quasiquote must be expanded before compilation",
            ),
        }
    }

    pub fn compileCall(
        self: *Compiler,
        call: anytype,
    ) InternalLowerError!void {
        switch (call.callee.expr) {
            .field => |field| {
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
                        (@as(usize, @intFromBool(call.implicit_self)) << 7);
                    try self.emit(.call_field, @intCast(argc));
                }
            },
            .index => |index| {
                try self.compile(index.object, true);
                try self.compile(index.key, true);
                for (call.args) |arg| try self.compile(arg, true);
                const argc = call.args.len |
                    (@as(usize, @intFromBool(call.implicit_self)) << 7);
                try self.emit(.call_field, @intCast(argc));
            },
            .ident => |fn_name| {
                const reordered_args = try validateCallArgs(
                    self,
                    fn_name,
                    call.args,
                );
                try self.compile(call.callee, true);

                // use reordered args if named params were used
                const args_to_compile = if (reordered_args.ptr != call.args.ptr)
                    reordered_args
                else
                    call.args;

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

        if (reordered_args.len < sig.required_count or reordered_args.len > sig.param_types.len) {
            var extra_parts = try std.ArrayList(diagnostic.Part).initCapacity(self.alloc, 1);
            defer extra_parts.deinit(self.alloc);
            if (reordered_args.len > sig.param_types.len) {
                try self.appendUnexpectedArgPart(
                    reordered_args,
                    sig.param_types.len,
                    &extra_parts,
                );
            }
            const msg = if (sig.required_count == sig.param_types.len)
                try std.fmt.allocPrint(
                    self.alloc,
                    "call to `{s}` wants {d} arg(s), got {d}",
                    .{ fn_name, sig.required_count, reordered_args.len },
                )
            else
                try std.fmt.allocPrint(
                    self.alloc,
                    "call to `{s}` wants at least {d} arg(s), got {d}",
                    .{ fn_name, sig.required_count, reordered_args.len },
                );
            try self.appendFailureReport(.ParseError, &.{
                .{ .@"error" = msg },
                if (extra_parts.items.len > 0) extra_parts.items[0] else .{ .@"error" = "" },
            });
            had_error = true;
        }

        const min_args = @min(sig.param_types.len, reordered_args.len);
        for (0..min_args) |i| {
            const expected_type = sig.param_types[i];
            if (expected_type == .any) continue;
            const actual_type = type_check.inferExprType(
                self,
                reordered_args[i],
            );
            // type params (generics) are .type_var, skip type check
            if (expected_type == .type_var) continue;
            type_check.checkType(
                expected_type,
                actual_type,
            ) catch |err| switch (err) {
                error.TypeError => {
                    const expected_str = try types.formatType(self.alloc, expected_type);
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
                            .{ i + 1, fn_name, expected_str, actual_str },
                        )
                    else
                        try std.fmt.allocPrint(
                            self.alloc,
                            "arg {d} (`{s}`) to `{s}` wants {s}, got {s}",
                            .{ i + 1, sig.param_names[i], fn_name, expected_str, actual_str },
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
                else => |e| return e,
            };
        }
        if (had_error) return error.LoweringFailed;
        return reordered_args;
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
            const msg = try self.alloc.dupe(u8, eval_failure.report.message);
            const parts = try self.alloc.dupe(
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
            if (!ast.isDiscardName(name) and std.mem.findAny(u8, name[0..name.len -| 1], "!?") != null)
                return self.setFailureParts(
                    .ParseError,
                    .{ .span = binding.target.span, .role = .primary, .message = name },
                    "! and ? are only allowed at the end of names",
                    &.{},
                );
            if (std.mem.endsWith(u8, name, "!") and !ast.isDiscardName(name))
                return self.setFailureParts(
                    .ParseError,
                    .{ .span = binding.target.span, .role = .primary, .message = name },
                    "name with ! is reserved for macros",
                    &.{},
                );
            if (binding.value.expr == .fn_expr) {
                try self.compileFn(
                    binding.value.expr.fn_expr.params,
                    binding.value.expr.fn_expr.return_type,
                    binding.value.expr.fn_expr.body,
                    name,
                    null,
                    binding.value.expr.fn_expr.type_params,
                );
            } else try self.compile(binding.value, true);

            const inferred_type = if (binding.type_name) |tn|
                try type_check.evalTypeExpr(self, tn)
            else
                type_check.inferExprType(self, binding.value);
            try state_mod.setLocalTypeHint(self, name, inferred_type);

            if (ast.isDiscardName(name)) return;
            try self.regDupe();
            try self.declared_globals.put(name, {});
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
            if (kind == .global) {
                try values.declareGlobalPattern(self, binding.target);
            } else {
                try values.declarePatternLocals(
                    self,
                    binding.target,
                    kind != .con,
                );
            }
        }

        try self.compile(binding.value, true);
        const src_idx = self.active_registers - 1;
        if (kind == .global) {
            try values.bindPattern(self, binding.target, src_idx, kind);
        } else {
            try values.bindDeclaredPattern(self, binding.target, src_idx, kind);
        }
    }

    pub fn compileFn(
        self: *Compiler,
        params: []const ast.FnParam,
        return_type: ?*ast.TypeExpr,
        body: *const Node,
        name: []const u8,
        loop_sym: ?revo.AtomID,
        type_params: []const []const u8,
    ) InternalLowerError!void {
        if (!ast.isDiscardName(name) and !std.mem.eql(u8, name, "<fn>")) {
            if (std.mem.findAny(u8, name[0..name.len -| 1], "!?")) |_| {
                return self.setFailureParts(
                    .ParseError,
                    .{ .span = body.span, .role = .primary, .message = name },
                    "! and ? are only allowed at the end of names",
                    &.{},
                );
            }
            if (std.mem.endsWith(u8, name, "!")) {
                return self.setFailureParts(
                    .ParseError,
                    .{ .span = body.span, .role = .primary, .message = name },
                    "function name with ! is reserved for macros",
                    &.{},
                );
            }
        }

        const jump_over = try self.jump(.jump);
        const body_addr: ProgramCounter = @intCast(self.irLen());
        const caller_registers = self.active_registers;
        const caller_max_registers = self.max_registers;
        const caller_value_stack_len = self.value_stack.items.len;
        errdefer {
            self.active_registers = caller_registers;
            self.max_registers = caller_max_registers;
            self.value_stack.shrinkRetainingCapacity(caller_value_stack_len);
        }

        const own_sig = !(ast.isDiscardName(name) or std.mem.eql(u8, name, "<fn>"));

        var s = try FunctionState.init(self.alloc);
        s.type_params = type_params;
        s.return_type = if (return_type) |rt| switch (rt.kind) {
            .named => |n| n,
            else => @tagName(rt.kind),
        } else if (std.mem.endsWith(u8, name, "?")) "bool" else null;

        // push function state early so evalTypeExpr can resolve type params
        const params_len: LocalSlot = @intCast(params.len);
        try self.functions.append(self.alloc, s);
        try self.slot_allocators.append(self.alloc, params_len);
        var state_pushed = true;
        errdefer if (state_pushed) {
            var leaked = self.functions.pop() orelse unreachable;
            leaked.deinit(self.alloc);
            _ = self.slot_allocators.pop() orelse unreachable;
        };

        const sig = try state_mod.allocFnSig(self, params, return_type, type_params);

        // set up params on the function state in the array
        const fn_state = &self.functions.items[self.functions.items.len - 1];
        for (params, 0..) |param, idx| {
            const local: LocalVar = .{
                .name = param.name,
                .slot = @intCast(idx),
                .mutable = true,
                .initialized = true,
                .type_name = if (param.type_name) |tn| switch (tn.kind) {
                    .named => |n| n,
                    else => types.typeName(try type_check.evalTypeExpr(self, tn)),
                } else null,
                .type_explicit = param.type_name != null,
            };
            try fn_state.locals.append(self.alloc, local);
            try fn_state.all_locals.append(self.alloc, local);
            if (param.type_name) |type_name| {
                try fn_state.type_hints.append(self.alloc, .{
                    .name = param.name,
                    .type_info = try type_check.evalTypeExpr(self, type_name),
                });
            }
        }

        const prev_in_loop = self.in_loop_depth;
        self.in_loop_depth = 0;
        if (loop_sym != null) self.in_loop_depth += 1;
        defer self.in_loop_depth = prev_in_loop;

        var required_count: u8 = @intCast(params.len);
        for (params) |p| {
            if (p.optional) required_count -= 1;
        }
        self.active_registers = params.len;
        self.max_registers = params.len;
        self.upvalue_cache.clearRetainingCapacity();
        if (own_sig) try s.fn_signatures.put(name, sig);

        self.fn_return_type = if (return_type) |rt| switch (rt.kind) {
            .named => |n| n,
            else => @tagName(rt.kind),
        } else null;

        defer self.fn_return_type = null;
        try self.compile(body, true);
        if (return_type) |rt| {
            _ = rt;
        } else {
            const inferred_type = type_check.inferExprType(self, body);
            sig.return_type = inferred_type;

            // propagate to parent state so callers find it via
            // findFnSignature (this state will be popped)
            if (own_sig and self.functions.items.len >= 2) {
                const parent = &self.functions.items[self.functions.items.len - 2];
                if (parent.fn_signatures.get(name)) |parent_sig| {
                    parent_sig.return_type = sig.return_type;
                }
            }
        }
        if (self.failure_reports.items.len != 0 or self.failure != null) return error.LoweringFailed;
        if (self.active_registers == 0) try self.pushNil();
        if (loop_sym) |sym| try flow.emitLoopRecurse(self, params.len, sym) else try self.emit(.ret, 1);

        const fn_register_count = self.max_registers;
        self.active_registers = caller_registers;
        self.max_registers = caller_max_registers;
        //
        // remove any surplus items the body left on value_stack
        // the body's .ret consumes 1, so leftovers are anything beyond pre-call len
        // don't attempt to grow back items consumed by early returns
        if (self.value_stack.items.len > caller_value_stack_len)
            self.value_stack.shrinkRetainingCapacity(caller_value_stack_len);

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
            .arity = required_count,
            .total_arity = @intCast(params.len),
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
        const msg = for (parts) |p| {
            if (p == .@"error") break p.@"error";
        } else "";
        try self.failure_reports.append(self.alloc, .{
            .kind = kind,
            .report = .{
                .parts = copied_parts,
                .message = msg,
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

        self.failure_parts.clearRetainingCapacity();
        self.failure_parts.append(self.alloc, .{ .@"error" = owned_msg }) catch {};
        if (primary_span) |span|
            self.failure_parts.append(self.alloc, .{ .span = span }) catch {};
        for (extra_parts) |part|
            self.failure_parts.append(self.alloc, part) catch {};

        self.failure = .{
            .kind = kind,
            .report = .{
                .parts = self.failure_parts.items,
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
                .message = first.report.message,
                .source_name = first.report.source_name,
                .source = first.report.source,
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
