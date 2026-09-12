// zlint-disable line-length -- yeah
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
const fold = @import("../ir/fold.zig");
const dce = @import("../ir/dce.zig");
const peephole = @import("../ir/peephole.zig");
const promote = @import("../ir/promote.zig");
pub const ir = @import("../ir/root.zig");
const state_mod = @import("state.zig");

pub const types = @import("types.zig");
pub const type_check = @import("type_check.zig");
const type_serde = @import("../type_serde.zig");
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
    const LocalVar = state_mod.LocalVar;
    const FunctionState = state_mod.FunctionState;

    vm: *VM,
    alloc: std.mem.Allocator,
    runtime_alloc: std.mem.Allocator,
    test_mode: bool,
    functions: std.ArrayList(FunctionState),
    slot_allocators: std.ArrayList(LocalSlot),

    loop_stack: std.ArrayList(state_mod.LoopFrame),
    test_suite_names: std.ArrayList([]const u8),
    in_loop_depth: usize = 0,
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
    ir_builder: ir.IrBuilder,
    value_stack: std.ArrayList(*ir.IrInst),
    // register cache for upvalue loads, cleared per-block in compileBlock
    upvalue_cache: std.AutoHashMap(usize, usize),
    type_aliases: std.StringHashMap(types.TypeInfo),
    type_annotations: ?*const std.AutoHashMap(*const Node, types.TypeInfo) = null,
    pending_prototypes: std.ArrayList(revo.PrototypeID),
    declared_globals: std.StringHashMap(void),
    current_proto: revo.PrototypeID = 0,
    fn_depth: usize = 0,
    // name whose local is currently being initialized; the branch-local slot is
    // hidden from name resolution so initializers see the outer binding
    masking_local: ?[]const u8 = null,

    pub fn init(
        vm: *VM,
        test_mode: bool,
        arena: std.mem.Allocator,
        runtime_alloc: std.mem.Allocator,
    ) !Compiler {
        return .{
            .vm = vm,
            .alloc = arena,
            .runtime_alloc = runtime_alloc,
            .test_mode = test_mode,
            .functions = try std.ArrayList(FunctionState).initCapacity(arena, 4),
            .slot_allocators = try std.ArrayList(LocalSlot).initCapacity(arena, 4),
            .failure_reports = try std.ArrayList(LowerFailure).initCapacity(arena, 4),
            .spans = try std.ArrayList(ast.Span).initCapacity(arena, 32),
            .loop_stack = try std.ArrayList(state_mod.LoopFrame).initCapacity(arena, 8),
            .test_suite_names = try std.ArrayList([]const u8).initCapacity(arena, 4),
            .ir_builder = try ir.IrBuilder.init(arena),
            .value_stack = try std.ArrayList(*ir.IrInst).initCapacity(arena, 32),
            .upvalue_cache = std.AutoHashMap(usize, usize).init(arena),
            .type_aliases = std.StringHashMap(types.TypeInfo).init(arena),
            .declared_globals = std.StringHashMap(void).init(arena),
            .pending_prototypes = try std.ArrayList(revo.PrototypeID).initCapacity(arena, 4),
        };
    }

    pub fn deinit(self: *Compiler) void {
        for (self.functions.items) |*s| s.deinit(self.alloc);
        self.functions.deinit(self.alloc);
        self.slot_allocators.deinit(self.alloc);
        self.failure_reports.deinit(self.alloc);
        self.spans.deinit(self.alloc);
        for (self.loop_stack.items) |*frame| {
            frame.break_jumps.deinit(self.alloc);
            frame.continue_jumps.deinit(self.alloc);
        }
        self.loop_stack.deinit(self.alloc);
        self.test_suite_names.deinit(self.alloc);
        self.pending_prototypes.deinit(self.alloc);
        self.ir_builder.deinit();
        self.value_stack.deinit(self.alloc);
    }

    // ctx interface for types.zig
    pub const inferIdentType = type_check.inferIdentType;
    pub const resolveTypeName = types.resolveTypeName;
    pub const resolveTypeAlias = type_check.resolveTypeAlias;
    pub const resolveImportAlias = type_check.resolveImportAlias;
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
        // if (self.ir_builder.instructions.items.len < 40) {
        //     std.debug.print("[RAWFN]\n", .{});
        //     for (self.ir_builder.instructions.items) |inst| {
        //         std.debug.print("  op={any} res_r={d} arg={d}\n", .{ inst.opcode, inst.result_reg, inst.op_arg });
        //     }
        // }
        try fold.foldIr(self);
        try dce.dceIr(self);
        try peephole.peepholeIr(self);
        try promote.promoteLoopCarried(self);
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

    pub fn record(
        self: *Compiler,
        opcode: Opcode,
        ops: []const ir.IrValue,
        push_res: bool,
        result_reg: Register,
        op_arg: Operand,
    ) !*ir.IrInst {
        const inst = try self.alloc.create(ir.IrInst);
        inst.* = .{ .opcode = opcode, .operands = try self.alloc.dupe(ir.IrValue, ops) };
        try self.ir_builder.instructions.append(self.alloc, inst);
        inst.result_reg = result_reg;
        inst.op_arg = op_arg;
        inst.fn_depth = @intCast(self.fn_depth);
        if (push_res) try self.value_stack.append(self.alloc, inst);
        return inst;
    }

    pub fn recordStackOp(
        self: *Compiler,
        opcode: Opcode,
        pop_n: usize,
        push_n: usize,
        result_reg: Register,
        op_arg: Operand,
    ) !void {
        var ops = try self.alloc.alloc(ir.IrValue, pop_n);
        defer self.alloc.free(ops);
        var i = pop_n;
        while (i > 0) {
            i -= 1;
            ops[i] = .{ .inst = try self.pop() };
        }
        _ = try self.record(opcode, ops, false, result_reg, op_arg);
        var p: usize = 0;
        while (p < push_n) : (p += 1) {
            try self.value_stack.append(
                self.alloc,
                self.ir_builder.instructions.items[self.ir_builder.instructions.items.len - 1],
            );
        }
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
        var out = try std.ArrayList(Instruction)
            .initCapacity(self.alloc, self.ir_builder.instructions.items.len);
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

    pub fn validateName(self: *Compiler, name: []const u8, span: ast.Span) InternalLowerError!void {
        if (ast.isDiscardName(name) or std.mem.eql(u8, name, "<fn>")) return;
        if (std.mem.findAny(u8, name[0..name.len -| 1], "!?") != null) {
            try self.appendFailureReport(.ParseError, &.{
                .{ .@"error" = "! and ? are only allowed at the end of names" },
                .{ .span = .{ .span = span, .role = .primary, .message = name } },
            });
            return error.LoweringFailed;
        }
        if (std.mem.endsWith(u8, name, "!")) {
            try self.appendFailureReport(.ParseError, &.{
                .{ .@"error" = "name with ! is reserved for macros" },
                .{ .span = .{ .span = span, .role = .primary, .message = name } },
            });
            return error.LoweringFailed;
        }
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

    /// emit bind_local/store_local that reads from source_reg directly,
    /// bypassing the value_stack. avoids a redundant move in patterns like
    /// `move Rsrc,Rdst + bind_local slot,Rdst` -> `bind_local slot,Rsrc`.
    pub fn emitBind(self: *Compiler, op: Opcode, slot: Operand, source_reg: Register) !void {
        try self.spans.append(self.alloc, self.active_span);
        _ = try self.record(op, &.{}, false, source_reg, slot);
    }

    pub fn emit(self: *Compiler, op: Opcode, op_arg: Operand) !void {
        var d = self.active_registers;
        var result_reg: Register = 0;

        switch (op) {
            .add, .sub, .mul, .div, .mod, .concat, .band, .bor, .bxor, .shl, .shr, .int_div, .pow, .eq, .neq, .lt, .gt, .lte, .gte, .eq_int, .neq_int, .lt_int, .gt_int, .lte_int, .gte_int, .@"and", .@"or" => {
                std.debug.assert(d >= 2);
                result_reg = try toRegister(d - 2);
                d -= 1;
                const rhs = try self.pop();
                const lhs = try self.pop();
                _ = try self.record(op, &.{ .{ .inst = lhs }, .{ .inst = rhs } }, true, result_reg, 0);
            },
            .negate, .not => {
                std.debug.assert(d > 0);
                result_reg = try toRegister(d - 1);
                const opnd = try self.pop();
                _ = try self.record(op, &.{.{ .inst = opnd }}, true, result_reg, 0);
            },
            .add_int_imm, .sub_int_imm, .mul_int_imm, .band_int_imm, .lt_int_imm => {
                std.debug.assert(d > 0);
                result_reg = try toRegister(d - 1);
                try self.recordStackOp(op, 1, 1, result_reg, op_arg);
            },
            .load_global, .load_stdlib_global, .load_local, .load_upval, .closure, .table_new, .load_nil, .load_small_int, .load_const => {
                result_reg = try toRegister(d);
                d += 1;
                try self.recordStackOp(op, 0, 1, result_reg, op_arg);
            },
            .halt, .ret => {
                result_reg = if (d == 0) 0 else try toRegister(d - 1);
                try self.recordStackOp(op, 1, 0, result_reg, 0);
            },
            .jump => {
                result_reg = 0;
                try self.recordStackOp(op, 0, 0, result_reg, op_arg);
            },
            .jump_if_false, .jump_if_true, .jump_err => {
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
            .slice => {
                std.debug.assert(d >= 4);
                result_reg = try toRegister(d - 4);
                d -= 3;
                try self.recordStackOp(op, 4, 1, result_reg, 0);
            },
            .table_set_atom => {
                std.debug.assert(d >= 2);
                result_reg = try toRegister(d - 2);
                d -= 1;
                try self.recordStackOp(op, 2, 0, result_reg, op_arg);
            },
            .table_get_atom => {
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
            .range_loop => {
                std.debug.assert(d >= 3);
                result_reg = try toRegister(d - 3);
                try self.recordStackOp(op, 0, 0, result_reg, op_arg);
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
        if (self.failure_reports.items.len != 0) return error.LoweringFailed;
        try self.emit(.call, 0);
        try self.emit(.halt, 0);
    }

    pub fn formatSuiteTestName(self: *Compiler, test_name: []const u8) ![]u8 {
        const prefix = try std.mem.join(self.alloc, "::", self.test_suite_names.items);
        if (prefix.len == 0) return self.alloc.dupe(u8, test_name);
        defer self.alloc.free(prefix);
        return std.fmt.allocPrint(self.alloc, "{s}::{s}", .{ prefix, test_name });
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
            .nil => try self.@"const"(Data.new.atom(revo.core_atoms.nil.atomId())),
            .ident => |name| {
                if (state_mod.resolveLocal(self, name)) |slot| {
                    try self.emit(.load_local, slot);
                } else if (try state_mod.resolveUpvalue(self, name)) |upval_id| {
                    // reuse a cached upvalue load ONLY while its result is still
                    // the topmost live value, once other values are pushed on
                    // top the cached register coukd be stale or about to be
                    // reused, so recordMove would copy the wrong register
                    const top_inst = if (self.value_stack.items.len > 0)
                        self.value_stack.items[self.value_stack.items.len - 1]
                    else
                        null;
                    if (top_inst != null and
                        top_inst.?.opcode == .load_upval and
                        top_inst.?.op_arg == upval_id and
                        self.upvalue_cache.get(upval_id) == top_inst.?.result_reg)
                    {
                        const dst = try state_mod.pushRegister(self);
                        try self.spans.append(self.alloc, self.active_span);
                        try self.recordMove(dst);
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
                    try self.emit(.negate, 0);
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
                        var spawn_args: []const *Node = call.args;
                        var spawn_expanded: ?[]const *Node = null;
                        defer if (spawn_expanded) |ea| if (ea.ptr != call.args.ptr) self.alloc.free(ea);
                        switch (call.callee.expr) {
                            .ident => |nm| {
                                const ra = try validateCallArgs(self, nm, call.args);
                                if (ra.ptr != call.args.ptr) {
                                    spawn_expanded = ra;
                                    spawn_args = ra;
                                }
                            },
                            .fn_expr => |fe| {
                                const ea = try expandDirectFnArgs(self, fe.params, call.args);
                                if (ea.ptr != call.args.ptr) {
                                    spawn_expanded = ea;
                                    spawn_args = ea;
                                }
                            },
                            else => {},
                        }
                        try self.compile(call.callee, true);
                        if (call.implicit_self) switch (call.callee.expr) {
                            .field => |field| try self.compile(field.object, true),
                            .index => |index| try self.compile(index.object, true),
                            else => {},
                        };
                        for (spawn_args) |arg| {
                            if (arg.expr == .assign_expr) try self.compile(arg.expr.assign_expr.value, true) else try self.compile(arg, true);
                        }
                        try self.emit(
                            .spawn,
                            @intCast(
                                spawn_args.len + @intFromBool(call.implicit_self),
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

                const left_type = type_check.inferExprType(self, b.left);
                const right_type = type_check.inferExprType(self, b.right);

                const both_numeric = b.op != .concat and left_type.tag == .number and right_type.tag == .number;

                const specialized_op: Opcode = if (both_numeric)
                    switch (b.op) {
                        .add => .add,
                        .sub => .sub,
                        .mul => .mul,
                        .div => .div,
                        .int_div => .int_div,
                        .mod => .mod,
                        .pow => .pow,
                        .band => .band,
                        .bor => .bor,
                        .bxor => .bxor,
                        .shl => .shl,
                        .shr => .shr,
                        .eq => .eq_int,
                        .neq => .neq_int,
                        .lt => .lt_int,
                        .gt => .gt_int,
                        .lte => .lte_int,
                        .gte => .gte_int,
                        .concat, .@"union" => unreachable,
                    }
                else switch (b.op) {
                    .@"union" => unreachable,
                    inline else => |tag| @field(Opcode, @tagName(tag)),
                };

                // a constant int RHS folds into the opcode as an immediate,
                // skipping its materialization (and a dispatch at runtime).
                // when both operands are literals, keep the two-register form
                // so the constant fold pass still collapses them at compile time
                if (both_numeric and immInt(b.left) == null) {
                    if (immOpFor(b.op)) |op_imm| {
                        if (immInt(b.right)) |k| {
                            try self.compile(b.left, true);
                            try self.emit(op_imm, k);
                            return;
                        }
                    }
                }

                try self.compile(b.left, true);
                try self.compile(b.right, true);
                try self.emit(specialized_op, 0);
            },
            .and_expr => |v| try flow.compileAnd(self, v.left, v.right),
            .or_expr => |v| try flow.compileOr(self, v.left, v.right),
            .call => |call| try self.compileCall(call),
            .field => |field| {
                try self.compile(field.object, true);
                try self.emit(.table_get_atom, try self.vm.internAtom(field.name));
            },
            .index => |index| {
                try self.compile(index.object, true);
                if (index.key.expr == .range_literal) {
                    const range = index.key.expr.range_literal;
                    try self.compile(range.start, true);
                    try self.compile(range.step, true);
                    try self.compile(range.end, true);
                    try self.emit(.slice, 0);
                } else if (index.key.expr == .slice_literal) {
                    const slice = index.key.expr.slice_literal;
                    if (slice.start) |n| try self.compile(n, true) else try self.emit(.load_nil, 0);
                    if (slice.step) |n| try self.compile(n, true) else try self.emit(.load_nil, 0);
                    if (slice.end) |n| try self.compile(n, true) else try self.emit(.load_nil, 0);
                    try self.emit(.slice, 0);
                } else if (index.key.expr == .hash) try self.emit(
                    .table_get_atom,
                    try self.vm.internAtom(index.key.expr.hash),
                ) else {
                    try self.compile(index.key, true);
                    try self.emit(.table_get, 0);
                }
            },
            .if_expr => |v| try flow.compileIf(self, v.condition, v.then_expr, v.else_expr),
            .unless_expr => |v| try flow.compileUnless(self, v.condition, v.then_expr, v.else_expr),
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
                    .type_alias => |t| {
                        _ = t;
                        if (d.kind == .declare_decl) {
                            try self.pushNil();
                            return;
                        }
                    },
                    else => {},
                }
                return self.compile(d.inner, true);
            },
            .assign_expr => |assign| try values.compileAssign(self, assign.target, assign.value),
            .compound_assign => |assign| try values.compileCompound(self, assign.target, assign.op, assign.value),
            .block => |exprs| try self.compileBlock(exprs),
            .table => |entries| try values.compileTable(self, entries),
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

                try self.emit(.load_global, revo.core_atoms.import.atomId());
                try self.@"const"(try self.vm.ownDataString(is.path));

                try self.emit(.call, 1);
                try self.regDupe();

                try self.emit(.bind_local, slot);
            },
            .comp_block => |cb| try self.compileComp(cb.expr),
            .loop_expr => |v| try flow.compileLoop(self, v.body, v.label),
            .for_loop => |v| try flow.compileFor(self, v.params, v.body, v.iter, v.label),
            .while_loop => |v| try flow.compileWhile(self, v.predicate, v.body, v.label),
            .break_expr => |b| try flow.compileBreak(self, expr, b.value, b.label),
            .continue_expr => |c| try flow.compileContinue(self, expr, c.value, c.label),
            .labeled_block => |lb| try flow.compileLabeledBlock(self, lb.label, lb.body),
            .fn_expr => |fn_expr| try self.compileFn(fn_expr.params, fn_expr.return_type, fn_expr.body, "<fn>", null, fn_expr.type_params),
            .match_expr => |v| try flow.compileMatch(self, v.subject, v.arms),
            .table_pattern => return self.fail(
                .UnsupportedSyntax,
                expr,
                "table patterns do not compile as values",
            ),
            .ascribed => return self.fail(
                .UnsupportedSyntax,
                expr,
                "type ascriptions only go in match patterns",
            ),
            .range_literal => return self.fail(
                .UnsupportedSyntax,
                expr,
                "range literals only go in forloops for now",
            ),
            .slice_literal => return self.fail(
                .UnsupportedSyntax,
                expr,
                "slice literals only appear inside index expressions",
            ),
            .try_expr => |expr_ptr| {
                try self.compile(expr_ptr, true);
                try self.emit(.unwrap_result, 0);
            },
            .orelse_expr => |v| {
                try self.compile(v.left, true);
                const fail_jump = try self.jump(.jump_err);
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
                        try self.vm.internAtom("__internal_dotest"),
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
                        try self.vm.internAtom("__internal_dosuite"),
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
                const type_info = type_serde.evalTypeExpr(self, t.type_expr) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                };
                try self.type_aliases.put(ast.bareName(t), type_info);
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
                        args_to_compile.len + @intFromBool(call.implicit_self),
                    ),
                );
            },
            .fn_expr => {
                const params = call.callee.expr.fn_expr.params;
                const expanded = try expandDirectFnArgs(self, params, call.args);
                defer if (expanded.ptr != call.args.ptr) self.alloc.free(expanded);
                try self.compile(call.callee, true);
                for (expanded) |arg| {
                    if (arg.expr == .assign_expr) {
                        try self.compile(arg.expr.assign_expr.value, true);
                    } else try self.compile(arg, true);
                }
                try self.emit(
                    .call,
                    @intCast(
                        expanded.len + @intFromBool(call.implicit_self),
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
        const object_type = type_check.inferExprType(self, field.object);
        const module_name = switch (object_type.tag) {
            .string => "string",
            .table => "table",
            else => return false,
        };

        if (std.mem.eql(u8, module_name, "table") and
            std.mem.eql(u8, field.name, "add")) return false;

        // a known field shadows the stdlib method of the same name;
        // works for any table expression with a known shape, not just locals
        if (object_type.tag == .table) {
            if (object_type.tag.table.fields) |fs| {
                if (types.findField(fs, field.name) != null) return false;
            }
        }

        const module_atom = try self.vm.internAtom(module_name);
        const module = self.vm.stdlib_globals.get(module_atom) orelse return false;
        const module_table_id = module.asTable() orelse return false;
        const module_table = self.vm.tables.get(module_table_id) catch return false;

        const method_atom = try self.vm.internAtom(field.name);
        const method = module_table.getRawAtom(method_atom, self.vm) orelse return false;
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
        sig: *const types.FunctionSignature,
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

        if (reordered_args.len < sig.required_count or reordered_args.len > sig.params.len) {
            var extra_parts = try std.ArrayList(diagnostic.Part).initCapacity(self.alloc, 1);
            defer extra_parts.deinit(self.alloc);
            if (reordered_args.len > sig.params.len) {
                try self.appendUnexpectedArgPart(
                    reordered_args,
                    sig.params.len,
                    &extra_parts,
                );
            }
            const msg = if (sig.required_count == sig.params.len)
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

        const min_args = @min(sig.params.len, reordered_args.len);
        for (0..min_args) |i| {
            const expected_type = sig.params[i];
            if (expected_type.tag == .any) continue;
            const actual_type = type_check.inferExprType(
                self,
                reordered_args[i],
            );
            // type params (generics) are .type_var, skip type check
            if (expected_type.tag == .type_var) continue;
            type_check.checkType(
                expected_type,
                actual_type,
            ) catch |err| switch (err) {
                error.TypeError => {
                    const expected_str = try type_serde.formatType(self.alloc, expected_type);
                    const actual_str = try type_serde.formatType(self.alloc, actual_type);
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
        // insert missing optional/default args
        if (reordered_args.len < sig.params.len) {
            var full_args = try self.alloc.alloc(*Node, sig.params.len);
            errdefer self.alloc.free(full_args);
            for (reordered_args, 0..) |arg, idx| full_args[idx] = arg;
            for (reordered_args.len..sig.params.len) |idx| {
                if (sig.default_values[idx]) |def_node| {
                    full_args[idx] = def_node;
                } else {
                    // bare `?a` without explicit default defaults to :none
                    const span = if (reordered_args.len > 0) reordered_args[0].span else if (args.len > 0) args[0].span else ast.Span{ .start = 0, .end = 0, .line = 1, .column = 1 };
                    const none_node = try self.alloc.create(ast.Node);
                    none_node.* = .{ .span = span, .expr = .{ .hash = "none" } };
                    full_args[idx] = none_node;
                }
            }
            // type-check the inserted defaults
            for (reordered_args.len..sig.params.len) |idx| {
                const expected_type = sig.params[idx];
                if (expected_type.tag == .any or expected_type.tag == .type_var) continue;
                const actual_type = type_check.inferExprType(self, full_args[idx]);
                type_check.checkType(expected_type, actual_type) catch |err| switch (err) {
                    error.TypeError => {
                        const expected_str = try type_serde.formatType(self.alloc, expected_type);
                        const actual_str = try type_serde.formatType(self.alloc, actual_type);
                        try self.appendFailureReport(.ParseError, &.{
                            .{ .@"error" = try std.fmt.allocPrint(self.alloc, "default for `{s}` wants {s}, got {s}", .{ sig.param_names[idx], expected_str, actual_str }) },
                        });
                        had_error = true;
                    },
                    else => |e| return e,
                };
            }
            if (had_error) return error.LoweringFailed;
            // leak the original reordered slice if it was allocated
            if (reordered_args.ptr != args.ptr) self.alloc.free(reordered_args);
            return full_args;
        }
        if (had_error) return error.LoweringFailed;
        return reordered_args;
    }

    fn expandDirectFnArgs(
        self: *Compiler,
        params: []const ast.FnParam,
        args: []const *Node,
    ) InternalLowerError![]const *Node {
        if (args.len >= params.len) return args;
        var required: usize = 0;
        for (params) |p| {
            if (!p.optional and p.default_value == null) required += 1;
        }

        if (args.len < required) return args;
        var full = try self.alloc.alloc(*Node, params.len);
        errdefer self.alloc.free(full);

        for (args, 0..) |a, i| full[i] = a;
        for (args.len..params.len) |i| {
            if (params[i].default_value) |def| {
                full[i] = def;
            } else {
                const span = if (args.len > 0)
                    args[0].span
                else
                    ast.Span{ .start = 0, .end = 0, .line = 1, .column = 1 };

                const n = try self.alloc.create(ast.Node);
                n.* = .{ .span = span, .expr = .{ .hash = "none" } };
                full[i] = n;
            }
        }
        return full;
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
                try self.appendFailureReport(nested_failure.kind, nested_failure.report.parts);
                return error.LoweringFailed;
            },
            else => return err,
        };
        const artifact = try temp_compiler.finishArtifact();
        defer self.vm.runtime.alloc.free(artifact.instructions);
        defer self.vm.runtime.alloc.free(artifact.spans);
        const result = try VM.module.runCompiledModuleReport(
            self.vm,
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
            try self.appendFailureReport(.ParseError, parts);
            return error.LoweringFailed;
        }
        try self.@"const"(self.vm.mainResult());
    }

    pub fn compileBlock(self: *Compiler, exprs: []const *Node) InternalLowerError!void {
        if (exprs.len == 0) return self.pushNil();
        // local slots must not overlap with live temporaries (callee/args of an
        // enclosing call) when this block is compiled inline as an argument
        if (self.slot_allocators.items.len > 0) {
            const idx = self.slot_allocators.items.len - 1;
            if (self.slot_allocators.items[idx] < self.active_registers) {
                self.slot_allocators.items[idx] = @intCast(self.active_registers);
            }
        }
        var pushed_scope = false;
        if (state_mod.currentFunctionState(self) != null) {
            try state_mod.pushScope(self);
            pushed_scope = true;
            errdefer if (pushed_scope) state_mod.popScope(self);
            try state_mod.predeclareTypeAliases(self, exprs);
            try state_mod.predeclareFunctionBindings(self, exprs);
        }
        self.upvalue_cache.clearRetainingCapacity();
        for (exprs, 0..) |expr, idx| {
            const before = self.active_registers;
            self.compile(expr, true) catch |err| switch (err) {
                error.LoweringFailed => {
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
            try self.validateName(name, binding.target.span);
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
                try type_serde.evalTypeExpr(self, tn)
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

        if (binding.target.expr == .table_pattern) {
            switch (binding.target.expr) {
                .table_pattern => |items| try values.validateTablePatternShape(
                    self,
                    items,
                    binding.value,
                    "binding",
                ),
                else => {},
            }
            if (kind == .global) {
                try values.declareGlobalPattern(self, binding.target);
            } else {
                try values.declarePatternLocals(
                    self,
                    binding.target,
                    kind != .con,
                );
            }
        } else if (binding.target.expr == .table) {
            return self.fail(
                .UnsupportedSyntax,
                binding.target,
                "keyed tables do not destructure yet :( use keyless `{a, b}`",
            );
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
        try self.validateName(name, body.span);

        self.fn_depth += 1;
        const jump_over = try self.jump(.jump);
        const body_addr: ProgramCounter = @intCast(self.irLen());
        const caller_registers = self.active_registers;
        const caller_max_registers = self.max_registers;
        const caller_value_stack_len = self.value_stack.items.len;
        errdefer {
            self.active_registers = caller_registers;
            self.max_registers = caller_max_registers;
            self.value_stack.shrinkRetainingCapacity(caller_value_stack_len);
            self.fn_depth -= 1;
        }

        const own_sig = !(ast.isDiscardName(name) or std.mem.eql(u8, name, "<fn>"));

        var s = try FunctionState.init(self.alloc);
        s.type_params = type_params;

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
        if (own_sig and self.functions.items.len >= 2) {
            const parent = &self.functions.items[self.functions.items.len - 2];
            if (parent.fn_signatures.get(name)) |old| {
                self.alloc.free(old.params);
                self.alloc.free(old.param_names);
                if (old.default_values.len > 0) self.alloc.free(old.default_values);
                self.alloc.destroy(old);
                _ = parent.fn_signatures.remove(name);
            }
            parent.fn_signatures.put(name, sig) catch {};
        }

        // set up params on the function state in the array
        const fn_state = &self.functions.items[self.functions.items.len - 1];
        for (params, 0..) |param, idx| {
            const local: LocalVar = .{
                .name = param.name,
                .slot = @intCast(idx),
                .mutable = true,
                .initialized = true,
                .type_info = if (param.type_name) |tn| try type_serde.evalTypeExpr(self, tn) else null,
                .type_explicit = param.type_name != null,
            };
            try fn_state.locals.append(self.alloc, local);
            try fn_state.all_locals.append(self.alloc, local);
            if (param.type_name) |type_name| {
                try fn_state.type_hints.append(self.alloc, .{
                    .name = param.name,
                    .type_info = try type_serde.evalTypeExpr(self, type_name),
                });
            }
        }

        const prev_in_loop = self.in_loop_depth;
        self.in_loop_depth = 0;
        if (loop_sym != null) self.in_loop_depth += 1;
        defer self.in_loop_depth = prev_in_loop;

        var required_count: u8 = @intCast(params.len);
        for (params) |p| {
            if (p.optional or p.default_value != null) required_count -= 1;
        }
        self.active_registers = params.len;
        self.max_registers = params.len;
        self.upvalue_cache.clearRetainingCapacity();
        // signature already placed in parent for caller validation
        // dont need inner map entry (recursion finds parent)

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
        if (self.failure_reports.items.len != 0) return error.LoweringFailed;
        if (self.active_registers == 0) try self.pushNil();
        if (loop_sym) |sym| try flow.emitLoopRecurse(self, params.len, sym) else try self.emit(.ret, 1);

        const fn_register_count = self.max_registers;
        self.fn_depth -= 1;
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
        self.current_proto = proto_id;
        try self.emit(.closure, proto_id);

        if (!own_sig) {
            self.alloc.free(sig.params);
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

    pub fn appendFailureReport(
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

    pub fn finishFailure(self: *Compiler) !?LowerFailure {
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

    pub fn fail(
        self: *Compiler,
        kind: LowerErrorKind,
        expr: *const Node,
        message: []const u8,
    ) error{LoweringFailed} {
        self.appendFailureReport(kind, &.{
            .{ .@"error" = message },
            .{ .span = .{ .span = expr.span, .role = .primary } },
        }) catch {};
        return error.LoweringFailed;
    }
};

/// if `node` is an int literal in 0..=u32::MAX, return its value, else null.
/// the fold range matches what load_small_int/load_const cover, so folding
/// into an immediate operand never changes the value the op sees
pub fn immInt(node: *const Node) ?u32 {
    if (node.expr != .number or node.expr.number.is_float) return null;
    const n = node.expr.number.value;
    if (n < 0 or n > std.math.maxInt(u32) or @trunc(n) != n) return null;
    return @intFromFloat(n);
}

/// the immediate-operand opcode for a binop that folds a constant int RHS.
/// returns null for float/`div`/`pow`/`concat` (no imm form, or float math)
pub fn immOpFor(op: ast.BinOp) ?Opcode {
    return switch (op) {
        .add => .add_int_imm,
        .sub => .sub_int_imm,
        .mul => .mul_int_imm,
        .band => .band_int_imm,
        .lt => .lt_int_imm,
        else => null,
    };
}
