// zlint-disable line-length -- yeah
const std = @import("std");

const revo = @import("revo");
const Value = revo.Value;
const Instruction = revo.Instruction;
const Opcode = revo.opcode.Opcode;
const Operand = revo.Operand;
const Register = revo.opcode.Register;
const VM = revo.VM;
const LocalSlot = revo.LocalSlot;
const ProgramCounter = revo.ProgramCounter;

const cst = @import("../cst.zig");
const Node = cst.CstNode;
const Lexer = @import("../Lexer.zig");
const control = @import("control.zig");
const ir = @import("../ir/root.zig");
const opt = @import("../ir/opt.zig");
const state_mod = @import("locals.zig");

const bindings = @import("bindings.zig");
const diagnostic = @import("../diagnostic.zig");
const type_syntax = @import("../type_syntax.zig");
pub const types = @import("types.zig");

const toRegister = state_mod.toRegister;

pub const CompileErrorKind = enum {
    ParseError,
    CompileError,
    UnsupportedSyntax,
    InvalidAssignmentTarget,
    IntegerOutOfRange,
};

pub const CompileResult = union(enum) {
    ok: []Instruction,
    err: CompileFailure,
};

pub const Bytecode = struct {
    instructions: []Instruction,
    spans: []Lexer.Span,
};

pub const BytecodeResult = union(enum) {
    ok: Bytecode,
    err: CompileFailure,
};

/// synthesized nodes legitimately miss, source nodes should not
pub const AnnotationMiss = struct {
    kind: []const u8,
    span: Lexer.Span,
};

/// debug ctrs for the annotation-only compiler
/// populated by compileExprReportStats, zero-ish calls are free otherwise
pub const CompileStats = struct {
    annotation_misses: usize = 0,
    first_annotation_miss: ?AnnotationMiss = null,
};

pub const CompileError = error{
    ParseError,
    UnsupportedSyntax,
    InvalidAssignmentTarget,
    IntegerOutOfRange,
} || std.mem.Allocator.Error;

const InternalCompileError = CompileError || error{CompileFailed};

pub const CompileFailure = diagnostic.Diagnostic(CompileErrorKind);

pub fn compileExprReport(
    vm: *VM,
    expr: *const Node,
    test_mode: bool,
    annotations: ?types.Annotations,
) !BytecodeResult {
    return compileExprReportStats(vm, expr, test_mode, annotations, null, null);
}

/// compile and optionally report annotation coverage
///   stats are filled even when compilation fails after init
pub fn compileExprReportStats(
    vm: *VM,
    expr: *const Node,
    test_mode: bool,
    annotations: ?types.Annotations,
    stats: ?*CompileStats,
    source_text: ?[]const u8,
) !BytecodeResult {
    // expr must be lowered (hir.lower): paren/pipe arms below are unreachable
    var arena = std.heap.ArenaAllocator.init(vm.runtime.alloc);
    defer arena.deinit();

    var compiler = try Compiler.init(
        vm,
        test_mode,
        arena.allocator(),
        vm.runtime.alloc,
    );
    compiler.annotations = annotations;
    compiler.source_text = source_text;

    defer compiler.deinit();
    defer {
        if (stats) |out| out.* = compiler.stats();
    }

    compiler.compileRoot(expr) catch |err| switch (err) {
        error.CompileFailed => {
            const failure = try compiler.finishFailure() orelse return error.CompileFailed;
            const report = try failure.report.copy(vm.runtime.diag_alloc);
            return .{ .err = .{
                .kind = failure.kind,
                .report = report,
            } };
        },
        else => return err,
    };

    return .{ .ok = try compiler.finishBytecode() };
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
    failure_reports: std.ArrayList(CompileFailure),
    spans: std.ArrayList(Lexer.Span),
    active_span: Lexer.Span = .{
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
    type_aliases: std.StringHashMap(types.Alias),
    annotations: ?types.Annotations = null,
    annotation_misses: usize = 0,
    first_annotation_miss: ?AnnotationMiss = null,
    /// debug ctx for annotation-miss logs, never used for sema
    source_text: ?[]const u8 = null,
    pending_templates: std.ArrayList(revo.TemplateID),
    declared_globals: std.StringHashMap(void),
    current_template: revo.TemplateID = 0,
    fn_depth: usize = 0,
    // names whose locals are currently being initialized; branch-local slots are
    // hidden from name resolution so initializers see the outer binding
    // (single `let x = ...` masks one name, `{a, b} = ...` masks many)
    masking_stack: std.ArrayList([]const u8),

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
            .failure_reports = try std.ArrayList(CompileFailure).initCapacity(arena, 4),
            .spans = try std.ArrayList(Lexer.Span).initCapacity(arena, 32),
            .loop_stack = try std.ArrayList(state_mod.LoopFrame).initCapacity(arena, 8),
            .test_suite_names = try std.ArrayList([]const u8).initCapacity(arena, 4),
            .ir_builder = try ir.IrBuilder.init(arena),
            .value_stack = try std.ArrayList(*ir.IrInst).initCapacity(arena, 32),
            .upvalue_cache = std.AutoHashMap(usize, usize).init(arena),
            .type_aliases = std.StringHashMap(types.Alias).init(arena),
            .declared_globals = std.StringHashMap(void).init(arena),
            .pending_templates = try std.ArrayList(revo.TemplateID).initCapacity(arena, 4),
            .masking_stack = try std.ArrayList([]const u8).initCapacity(arena, 4),
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
        self.pending_templates.deinit(self.alloc);
        self.masking_stack.deinit(self.alloc);
        self.ir_builder.deinit();
        self.value_stack.deinit(self.alloc);
    }

    // the CheckCtx scope for types.zig inference
    //   has annotations so nested inference reads the table, not live scope
    pub fn check(self: *Compiler) types.CheckCtx {
        var ctx = types.CheckCtx.init(self, self.alloc);
        ctx.annotations = self.annotations;
        ctx.annotations_only = self.annotations != null;
        ctx.scope = self.aliasScope();
        return ctx;
    }

    pub fn aliasScope(self: *Compiler) types.AliasScope {
        const fn_state = state_mod.currentFunctionState(self);
        return .{
            .alloc = self.alloc,
            .type_params = if (fn_state) |st| st.type_params else &.{},
            .aliases = &self.type_aliases,
        };
    }

    pub fn inferExprType(self: *Compiler, node: *const Node) types.TypeInfo {
        if (self.lookupAnnotation(node)) |ti| return ti;
        // annotations are authoritative in pipeline builds
        //   only the public no-annotation API keeps live inference
        if (self.annotations != null) return .{ .tag = .any };
        return types.inferExprType(self.check(), node);
    }

    /// pipeline lowering reads this, never live inference
    ///   miss means lowering-synthesized or never-analyzed: safe any fallback
    pub fn annotatedType(self: *Compiler, node: *const Node) types.TypeInfo {
        return self.lookupAnnotation(node) orelse .{ .tag = .any };
    }

    fn lookupAnnotation(self: *Compiler, node: *const Node) ?types.TypeInfo {
        const ann = self.annotations orelse return null;
        const id = ann.map.get(node) orelse {
            self.noteAnnotationMiss(node);
            return null;
        };
        return ann.table.get(id);
    }

    fn noteAnnotationMiss(self: *Compiler, node: *const Node) void {
        self.annotation_misses += 1;
        if (self.first_annotation_miss == null) {
            self.first_annotation_miss = .{
                .kind = @tagName(std.meta.activeTag(node.kind)),
                .span = node.span,
            };
        }
    }

    fn spanText(self: *const Compiler, span: Lexer.Span) []const u8 {
        const source = self.source_text orelse return "";
        if (span.start >= span.end or span.end > source.len) return "";
        return source[span.start..span.end];
    }

    pub fn stats(self: *const Compiler) CompileStats {
        return .{
            .annotation_misses = self.annotation_misses,
            .first_annotation_miss = self.first_annotation_miss,
        };
    }

    pub fn inferIdentType(self: *Compiler, name: []const u8) types.TypeInfo {
        if (state_mod.resolveLocalTypeHint(self, name)) |hint| return hint;
        const local = state_mod.resolveLocalVar(self, name) orelse return inferTypeMap(self, name);
        if (local.type_info) |ti| return ti;

        return inferTypeMap(self, name);
    }

    fn inferTypeMap(self: *Compiler, name: []const u8) types.TypeInfo {
        if (self.type_aliases.get(name)) |aliased| return aliased.info;
        return .{ .tag = .any };
    }

    pub fn inferCallReturnType(
        self: *Compiler,
        callee: *const Node,
        args: []const *const Node,
        type_args: []const []const u8,
        implicit_self: bool,
    ) types.TypeInfo {
        const callee_type = self.inferExprType(callee);
        if (callee_type.tag == .function) {
            const fn_sig = callee_type.tag.function;
            const ret = fn_sig.return_type;

            if (fn_sig.type_params.len > 0 and ret.tag != .any)
                return types.substCallReturn(self.check(), fn_sig, callee, args, type_args, implicit_self);
            if (ret.tag != .any) return ret;

            const cu = cst.unwrapParen(callee);
            if (cu != null and cu.?.kind == .fn_def and cu.?.kind.fn_def.return_type == null)
                return self.inferExprType(cu.?.kind.fn_def.body);
        }

        // local sigs are only a fallback for the public no-annotation api
        //   pipeline builds always trust semantic
        if (self.annotations != null) return .{ .tag = .any };

        {
            const cu = cst.unwrapParen(callee);
            if (cu != null and cu.?.kind == .ident) {
                const fn_name = cu.?.kind.ident.tok.text;
                const sig = state_mod.findFnSignature(self, fn_name) orelse return .{ .tag = .any };
                if (sig.type_params.len > 0 and sig.return_type.tag != .any)
                    return types.substCallReturn(self.check(), sig, callee, args, type_args, implicit_self);
                return sig.return_type;
            }
        }

        return .{ .tag = .any };
    }

    pub fn inferFieldType(self: *Compiler, object: *const Node, name: []const u8) types.TypeInfo {
        return switch (self.inferExprType(object).tag) {
            // `t.name` where t: { name: string } infers string
            .table => |tbl| blk: {
                if (tbl.fields) |fields| {
                    if (types.findField(fields, name)) |f| break :blk f.field_type;
                }
                break :blk .{ .tag = .any };
            },
            else => .{ .tag = .any },
        };
    }

    pub fn inferFnType(
        self: *Compiler,
        params: []const cst.CstParam,
        return_type: ?*const cst.CstType,
        type_params: []const []const u8,
        doc: ?[]const u8,
    ) types.TypeInfo {
        if (self.annotations != null) return .{ .tag = .any };
        const sig = types.buildFnSig(
            self.alloc,
            self,
            params,
            return_type,
            type_params,
            doc,
            .{ .degrade_param = true },
        ) catch return .{ .tag = .any };

        return .{ .tag = .{ .function = sig } };
    }

    pub fn finishBytecode(self: *Compiler) !Bytecode {
        if (self.annotation_misses > 0) {
            if (self.first_annotation_miss) |miss| {
                std.log.scoped(.compiler).debug(
                    "annotation misses: {d}; first {s} at {d}:{d} `{s}`",
                    .{
                        self.annotation_misses,
                        miss.kind,
                        miss.span.line,
                        miss.span.column,
                        self.spanText(miss.span),
                    },
                );
            }
        }
        // if (self.ir_builder.instructions.items.len < 40) {
        //     std.debug.print("[RAWFN]\n", .{});
        //     for (self.ir_builder.instructions.items) |inst| {
        //         std.debug.print("  op={any} res_r={d} arg={d}\n", .{ inst.opcode, inst.result_reg, inst.op_arg });
        //     }
        // }
        try opt.optimize(self);
        const bytecode = try self.toBytecode();
        const instr_copy = try self.runtime_alloc.dupe(Instruction, bytecode);
        defer self.alloc.free(bytecode);

        if (self.pending_templates.items.len > 0) {
            const segment_copy = try self.runtime_alloc.dupe(Instruction, bytecode);
            const segment_id = try self.vm.callable.addBytecodeSegment(segment_copy);
            for (self.pending_templates.items) |template_id| {
                self.vm.callable.templates.items[template_id].segment_id = segment_id;
            }
            self.pending_templates.items.len = 0;
        }

        const spans_copy = try self.runtime_alloc.dupe(Lexer.Span, self.spans.items);
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
            try self.spans.append(self.alloc, self.active_span);
            _ = try self.record(.load_nil, &.{}, true, result_reg, 0);
            return;
        }
        const src = self.value_stack.items[self.value_stack.items.len - 1];
        // self-move is a register no-op
        // alias it instead of emitting `move r,r` for peephole to clean up later
        if (ir.valueReg(.{ .inst = src }) == result_reg) {
            try self.value_stack.append(self.alloc, src);
            return;
        }
        try self.spans.append(self.alloc, self.active_span);
        _ = try self.record(.move, &.{.{ .inst = src }}, true, result_reg, 0);
    }

    pub fn toBytecode(self: *Compiler) ![]Instruction {
        var out = try std.ArrayList(Instruction)
            .initCapacity(self.alloc, self.ir_builder.instructions.items.len);
        defer out.deinit(self.alloc);
        for (self.ir_builder.instructions.items) |inst| try ir.lowerInst(self.alloc, &out, inst);
        return try out.toOwnedSlice(self.alloc);
    }

    pub fn irLen(self: *Compiler) usize {
        return self.ir_builder.instructions.items.len;
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
            if (ir.isBranch(inst.opcode)) inst.op_arg = new_index[inst.op_arg];
        }
        for (self.pending_templates.items) |template_id| {
            const template = &self.vm.callable.templates.items[template_id];
            template.addr = @intCast(new_index[template.addr]);
        }
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
        self.active_registers += 1;
        if (self.active_registers > self.max_registers) self.max_registers = self.active_registers;
        try self.recordMove(dst);
    }

    pub fn regRelease(self: *Compiler) !void {
        std.debug.assert(self.active_registers != 0);
        state_mod.popRegister(self);
    }

    pub fn validateName(self: *Compiler, name: []const u8, span: Lexer.Span) InternalCompileError!void {
        if (cst.isDiscardName(name) or std.mem.eql(u8, name, "<fn>")) return;
        if (std.mem.findAny(u8, name[0..name.len -| 1], "!?") != null) {
            try self.appendFailureReport(.ParseError, &.{
                .{ .@"error" = "! and ? are only allowed at the end of names" },
                .{ .span = .{ .span = span, .role = .primary, .message = name } },
            });
            return error.CompileFailed;
        }
        if (std.mem.endsWith(u8, name, "!")) {
            try self.appendFailureReport(.ParseError, &.{
                .{ .@"error" = "macros are gone, but not forever" },
                .{ .span = .{ .span = span, .role = .primary, .message = name } },
            });
            return error.CompileFailed;
        }
    }

    pub fn pushNil(self: *Compiler) !void {
        const dst = try state_mod.pushRegister(self);
        try self.spans.append(self.alloc, self.active_span);
        try self.recordLoad(.load_nil, dst, 0);
    }

    pub fn @"const"(self: *Compiler, v: Value) !void {
        if (v.asNumOpt()) |n| {
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
    /// , bypassing the value_stack. avoids a redundant move in patterns like
    /// , `move Rsrc,Rdst + bind_local slot,Rdst` -> `bind_local slot,Rsrc`
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
            .add_imm, .sub_imm, .mul_imm, .band_imm, .lt_int_imm => {
                std.debug.assert(d > 0);
                result_reg = try toRegister(d - 1);
                try self.recordStackOp(op, 1, 1, result_reg, op_arg);
            },
            .load_user_global, .load_builtin_global, .load_local, .load_upval, .make_closure, .table_new, .load_nil, .load_small_int, .load_const => {
                result_reg = try toRegister(d);
                d += 1;
                try self.recordStackOp(op, 0, 1, result_reg, op_arg);
            },
            .halt, .ret => {
                result_reg = if (d == 0) 0 else try toRegister(d - 1);
                if (d > 0) {
                    d -= 1;
                    try self.recordStackOp(op, 1, 0, result_reg, op_arg);
                } else {
                    try self.recordStackOp(op, 0, 0, result_reg, op_arg);
                }
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
            .store_user_global, .store_user_global_const, .store_upval => {
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

    pub fn compile(self: *Compiler, expr: *const Node, keep: bool) InternalCompileError!void {
        const prev_span = self.active_span;
        self.active_span = expr.span;
        defer self.active_span = prev_span;

        try self.compileValue(expr);
        if (!keep) try self.regRelease();
    }

    pub fn compileRoot(self: *Compiler, expr: *const Node) InternalCompileError!void {
        try self.compileFn(&.{}, null, expr, "__main", null, &.{});
        if (self.failure_reports.items.len != 0) return error.CompileFailed;
        try self.emit(.call, 0);
        try self.emit(.halt, 0);
    }

    pub fn formatSuiteTestName(self: *Compiler, test_name: []const u8) ![]u8 {
        const prefix = try std.mem.join(self.alloc, "::", self.test_suite_names.items);
        if (prefix.len == 0) return self.alloc.dupe(u8, test_name);
        defer self.alloc.free(prefix);
        return self.alloc.print("{s}::{s}", .{ prefix, test_name });
    }

    /// atom text without a leading colon (`:nil` and `nil` both give `nil`)
    fn atomText(text: []const u8) []const u8 {
        return if (text.len > 0 and text[0] == ':') text[1..] else text;
    }

    pub fn compileValue(self: *Compiler, expr: *const Node) InternalCompileError!void {
        switch (expr.kind) {
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
                        Value.new.num(@as(i64, @intFromFloat(value))),
                    );
                } else try self.@"const"(Value.new.num(value));
            },
            .string => |s| try self.@"const"(try self.vm.ownValueString(s.tok.text)),
            .interpolated => return self.fail(
                .UnsupportedSyntax,
                expr,
                "interpolated string must be lowered before compilation",
            ),
            .atom => |a| try self.@"const"(Value.new.atom(try self.vm.internAtom(atomText(a.tok.text)))),
            .err => try self.@"const"(Value.new.atom(revo.CoreAtoms.nil.atomId())),
            .ident => |n| {
                const name = n.tok.text;
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
                        try self.recordMove(dst);
                    } else {
                        try self.emit(.load_upval, upval_id);
                        try self.upvalue_cache.put(upval_id, self.active_registers - 1);
                    }
                } else if (self.type_aliases.get(name)) |_| {
                    // type used as value
                    const msg = try self.alloc.print(
                        "type name `{s}` used as a value",
                        .{name},
                    );
                    return self.fail(.ParseError, expr, msg);
                } else try self.emit(.load_user_global, try self.vm.internAtom(name));
            },
            .yield => {
                try self.emit(.yield, 0);
                try self.pushNil();
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
                .yield => {
                    try self.emit(.yield, 0);
                    try self.pushNil();
                },
                .spawn => {
                    const su = cst.unwrapParen(u.expr) orelse return self.fail(
                        .UnsupportedSyntax,
                        u.expr,
                        "spawn takes a function call, e.g. spawn f(x)",
                    );
                    switch (su.kind) {
                        .call => |call| {
                            var spawn_args: []const *Node = call.args;
                            var spawn_expanded: ?[]const *Node = null;
                            defer if (spawn_expanded) |ea| if (ea.ptr != call.args.ptr) self.alloc.free(ea);
                            const cu = cst.unwrapParen(call.callee);
                            if (cu != null and cu.?.kind == .ident) {
                                const ra = try validateCallArgs(self, cu.?.kind.ident.tok.text, cu.?.span, call.args);
                                if (ra.ptr != call.args.ptr) {
                                    spawn_expanded = ra;
                                    spawn_args = ra;
                                }
                            } else if (cu != null and cu.?.kind == .fn_def) {
                                const ea = try expandDirectFnArgs(self, cu.?.kind.fn_def.params, call.args);
                                if (ea.ptr != call.args.ptr) {
                                    spawn_expanded = ea;
                                    spawn_args = ea;
                                }
                            }
                            try self.compile(call.callee, true);
                            for (spawn_args) |arg| {
                                if (cst.namedArgValue(arg)) |v| try self.compile(v, true) else try self.compile(arg, true);
                            }
                            try self.emit(.spawn, @intCast(spawn_args.len));
                        },
                        .bare_call => |b| {
                            const one = [_]*Node{b.arg};
                            var spawn_args: []const *Node = one[0..];
                            var spawn_expanded: ?[]const *Node = null;

                            defer if (spawn_expanded) |ea|
                                if (ea.ptr != one[0..].ptr)
                                    self.alloc.free(ea);

                            const cu = cst.unwrapParen(b.callee);

                            if (cu != null and cu.?.kind == .ident) {
                                const ra =
                                    try validateCallArgs(self, cu.?.kind.ident.tok.text, cu.?.span, one[0..]);

                                if (ra.ptr != one[0..].ptr) {
                                    spawn_expanded = ra;
                                    spawn_args = ra;
                                }
                            } else if (cu != null and cu.?.kind == .fn_def) {
                                const ea =
                                    try expandDirectFnArgs(self, cu.?.kind.fn_def.params, one[0..]);

                                if (ea.ptr != one[0..].ptr) {
                                    spawn_expanded = ea;
                                    spawn_args = ea;
                                }
                            }

                            try self.compile(b.callee, true);

                            for (spawn_args) |arg| {
                                if (cst.namedArgValue(arg)) |v|
                                    try self.compile(v, true)
                                else
                                    try self.compile(arg, true);
                            }
                            try self.emit(.spawn, @intCast(spawn_args.len));
                        },
                        .method_call => |m| {
                            try self.compile(m.object, true);
                            const mname = atomText(m.atom_tok.text);
                            try self.@"const"(Value.new.atom(try self.vm.internAtom(mname)));
                            for (m.args) |arg| {
                                if (cst.namedArgValue(arg)) |v| try self.compile(v, true) else try self.compile(arg, true);
                            }
                            const argc = m.args.len | (@as(usize, 1) << 7);
                            try self.emit(.spawn, @intCast(argc));
                        },
                        .generic_call => |g| {
                            try self.compile(g.receiver, true);
                            for (g.args) |arg| {
                                if (cst.namedArgValue(arg)) |v| try self.compile(v, true) else try self.compile(arg, true);
                            }
                            try self.emit(.spawn, @intCast(g.args.len));
                        },
                        else => {
                            return self.fail(
                                .UnsupportedSyntax,
                                u.expr,
                                "spawn takes a function call, e.g. spawn f(x)",
                            );
                        },
                    }
                },
            },
            .binary => |b| {
                if (b.op == .@"union") return self.fail(
                    .UnsupportedSyntax,
                    expr,
                    "union type expression used as a value",
                );

                const left_type = self.annotatedType(b.left);
                const right_type = self.annotatedType(b.right);

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

                // a constant int rhs folds into the opcode as an immediate
                // , both literals keep two-reg form so fold pass still collapses
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
            .logical => |l| switch (l.op) {
                .and_op => try control.compileAnd(self, l.left, l.right),
                .or_op => try control.compileOr(self, l.left, l.right),
                .orelse_op => {
                    try self.compile(l.left, true);
                    const fail_jump = try self.jump(.jump_err);
                    try self.compile(l.right, true);
                    self.patchJump(fail_jump);
                    try self.emit(.unwrap_result, 1);
                },
            },
            .call => |c| try self.compileCallCst(c.callee, c.args),
            // bare calls are exactly one-argument calls; share arg fixup so
            // defaults/optional params behave the same
            .bare_call => |b| try self.compileCallCst(b.callee, &[_]*Node{b.arg}),
            // type args erase at runtime; dispatch on the receiver
            .generic_call => |g| try self.compileCallCst(g.receiver, g.args),
            .method_call => |m| try self.compileMethodCall(m),
            .field => |field| {
                try self.compile(field.object, true);
                try self.emit(.table_get_atom, try self.vm.internAtom(field.name_tok.text));
            },
            .dotted_index => |d| {
                try self.compile(d.object, true);
                const key = try cst.allocNode(self.alloc, d.num_tok.span(), .{ .number = .{ .tok = d.num_tok, .value = d.value, .is_float = false } });
                try self.compile(key, true);
                try self.emit(.table_get, 0);
            },
            .index => |index| {
                try self.compile(index.object, true);
                const ku = cst.unwrapParen(index.key);
                if (ku != null and ku.?.kind == .range) {
                    const r = ku.?.kind.range;
                    if (r.dot2_tok != null) {
                        const end = r.end orelse return self.fail(.UnsupportedSyntax, index.key, "open range needs an end");
                        try self.compile(r.start, true);
                        try self.compile(r.mid, true);
                        try self.compile(end, true);
                    } else {
                        // `a..b` slices start..end with nil step
                        try self.compile(r.start, true);
                        try self.emit(.load_nil, 0);
                        try self.compile(r.mid, true);
                    }
                    try self.emit(.slice, 0);
                } else if (ku != null and (ku.?.kind == .slice or ku.?.kind == .for_range)) {
                    if (ku.?.kind == .slice) {
                        const slice = ku.?.kind.slice;
                        if (slice.start) |n| try self.compile(n, true) else try self.emit(.load_nil, 0);
                        if (slice.mid) |n| try self.compile(n, true) else try self.emit(.load_nil, 0);
                        if (slice.end) |n| try self.compile(n, true) else try self.emit(.load_nil, 0);
                    } else {
                        // for_range bounds as slice bounds (nils for missing)
                        const fr = ku.?.kind.for_range;
                        if (fr.start) |n| try self.compile(n, true) else try self.emit(.load_nil, 0);
                        if (fr.mid) |n| try self.compile(n, true) else try self.emit(.load_nil, 0);
                        if (fr.end) |n| try self.compile(n, true) else try self.emit(.load_nil, 0);
                    }
                    try self.emit(.slice, 0);
                } else if (ku != null and ku.?.kind == .atom) try self.emit(
                    .table_get_atom,
                    try self.vm.internAtom(atomText(ku.?.kind.atom.tok.text)),
                ) else {
                    try self.compile(index.key, true);
                    try self.emit(.table_get, 0);
                }
            },
            .if_expr => |c| {
                if (c.unless) {
                    try control.compileUnless(self, c.cond, c.then, c.else_);
                } else {
                    try control.compileIf(self, c.cond, c.then, c.else_);
                }
            },
            .decl => |d| {
                const inner = cst.unwrapParen(d.inner) orelse return self.pushNil();
                switch (inner.kind) {
                    .binding => |*b| {
                        const bv = cst.unwrapParen(b.value);
                        const bt = cst.unwrapParen(b.target);
                        if (bv != null and bv.?.kind == .import and bt != null and bt.?.kind == .ident) {
                            // imports must be const, no type annotations
                            const user_name = bt.?.kind.ident.tok.text;
                            if (d.kind != .@"const") {
                                return self.fail(.ParseError, expr, "import binding must be const");
                            }
                            // compile import directly so it handles its own slot
                            // then also bind the user-specified name if it differs
                            // (single autobind items already carry the target
                            // name from bindImportNames, so this is usually a no-op)
                            try self.compile(b.value, true);
                            const im = bv.?.kind.import;
                            const first_name = if (im.items.len > 0)
                                importItemName(im.items[0])
                            else
                                user_name;
                            if (!std.mem.eql(u8, user_name, first_name)) {
                                const slot = try state_mod.declareLocal(self, user_name, false);
                                state_mod.reserveLocalSlots(self);
                                try self.regDupe();
                                try self.emit(.bind_local, slot);
                            }
                            return;
                        }
                        const kind: bindings.BindingKind = switch (d.kind) {
                            .@"const" => .@"const",
                            .let => .let,
                            .global => .global,
                            .global_const => .global_const,
                            else => .@"const",
                        };
                        return try self.compileBinding(b.*, kind);
                    },
                    .type_alias => {
                        if (d.kind == .declare_decl) {
                            try self.pushNil();
                            return;
                        }
                    },
                    .fn_def => |f| {
                        // named fn declarations bind like `const name = fn ...`
                        const fname: []const u8 = switch (f.head) {
                            .named => |n| n.name,
                            else => "<fn>",
                        };
                        const kind: bindings.BindingKind = switch (d.kind) {
                            .@"const" => .@"const",
                            .let => .let,
                            .global => .global,
                            .global_const => .global_const,
                            else => .@"const",
                        };
                        const target = try cst.allocIdent(self.alloc, inner.span, fname);
                        const bind = try cst.allocNode(self.alloc, inner.span, .{ .binding = .{
                            .kind_tok = cst.syntheticToken("const", inner.span),
                            .kind = .@"const",
                            .target = target,
                            .colon_tok = null,
                            .type = null,
                            .eq_tok = null,
                            .value = d.inner,
                        } });
                        return try self.compileBinding(bind.kind.binding, kind);
                    },
                    else => {},
                }
                return self.compile(d.inner, true);
            },
            .assign => |a| try bindings.compileAssign(self, a.target, a.value),
            .compound => |c| try bindings.compileCompound(self, c.target, c.op, c.value),
            .block => |b| try self.compileBlock(b.stmts),
            .root => |r| try self.compileBlock(r.stmts),
            .do_block => |d| {
                if (d.label_tok) |lt| {
                    const body = try cst.allocNode(self.alloc, expr.span, .{ .block = .{
                        .stmts = d.stmts,
                        .semis = d.semis,
                    } });
                    try control.compileLabeledBlock(self, lt.text, body);
                } else try self.compileBlock(d.stmts);
            },
            .paren => |p| {
                // stripped by hir.lower; only `()` survives this far
                if (p.expr) |_| unreachable else try self.pushNil();
            },
            .pipe => unreachable, // desugared by hir.lower
            .table => |tbl| try bindings.compileTable(self, tbl.entries),
            .return_expr => |r| {
                if (r.value) |v| {
                    try self.compile(v, true);
                } else try self.pushNil();
                try self.emit(.ret, 1);
            },
            .import => |im| {
                for (im.items) |item| {
                    try self.compileImportItem(item);
                }
                // importing is a statement; leave the last value on top
                // (single imports leave one value, matching old behavior)
            },
            .comp_block => |cb| try self.compileComp(cb.expr),
            .loop_expr => |v| try control.compileLoop(self, v.body, cst.labelText(v.label_tok)),
            .for_loop => |v| try control.compileFor(self, v.params, v.body, v.iter, cst.labelText(v.label_tok)),
            .while_loop => |v| try control.compileWhile(self, v.pred, v.body, cst.labelText(v.label_tok)),
            .break_expr => |b| {
                const value = if (b.value) |vv| vv else try self.nilNode();
                try control.compileBreak(self, expr, value, cst.labelText(b.label_tok));
            },
            .continue_expr => |c| try control.compileContinue(self, expr, null, cst.labelText(c.label_tok)),
            .fn_def => |f| {
                const fname: []const u8 = switch (f.head) {
                    .named => |n| n.name,
                    else => "<fn>",
                };
                const tps = try cst.tokenTexts(self.alloc, f.type_params);
                try self.compileFn(f.params, f.return_type, f.body, fname, null, tps);
            },
            .fn_method => |f| try self.compileFnMethod(f),
            .match => |v| {
                const subject = if (v.subject) |st| st else try self.trueNode();
                // the synthesized `:true` subject has no semantic annotation
                const subject_type: types.TypeInfo = if (v.subject) |st|
                    self.annotatedType(st)
                else
                    .{ .tag = .any };
                try control.compileMatch(self, subject, v.arms, subject_type);
            },
            .ascribed => return self.fail(
                .UnsupportedSyntax,
                expr,
                "type ascriptions only go in match patterns",
            ),
            .range => return self.fail(
                .UnsupportedSyntax,
                expr,
                "range literals only go in forloops for now",
            ),
            .for_range => return self.fail(
                .UnsupportedSyntax,
                expr,
                "range literals only go in forloops for now",
            ),
            .slice => return self.fail(
                .UnsupportedSyntax,
                expr,
                "slice literals only appear inside index expressions",
            ),
            .try_expr => |t| {
                try self.compile(t.expr, true);
                try self.emit(.unwrap_result, 0);
            },
            .test_block => |block| {
                if (self.test_mode and block.skip_tok == null) {
                    const test_label = try self.formatSuiteTestName(block.name.text);
                    defer self.alloc.free(test_label);
                    try self.emit(
                        .load_user_global,
                        try self.vm.internAtom("__internal_dotest"),
                    );
                    try self.@"const"(
                        try self.vm.ownValueString(test_label),
                    );
                    try self.compileTestBody(block.body);
                    try self.emit(.call, 2);
                    try self.regRelease();
                }
                try self.pushNil();
            },
            .test_suite => |suite| {
                if (self.test_mode) {
                    const suite_label = try self.formatSuiteTestName(suite.name.text);
                    defer self.alloc.free(suite_label);
                    try self.emit(
                        .load_user_global,
                        try self.vm.internAtom("__internal_dosuite"),
                    );
                    try self.@"const"(
                        try self.vm.ownValueString(suite_label),
                    );
                    try self.test_suite_names.append(self.alloc, suite.name.text);
                    defer _ = self.test_suite_names.pop();
                    try self.compileTestBody(suite.body);
                    try self.emit(.call, 2);
                    try self.regRelease();
                }
                try self.pushNil();
            },
            .type_alias => |t| {
                const type_info = types.evalTypeExpr(self.aliasScope(), t.type) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                };
                const tname = if (t.segs.len > 0) t.segs[t.segs.len - 1].text else "?";
                try self.type_aliases.put(tname, .{ .info = type_info });
                try self.pushNil();
            },
        }
    }

    /// `true` atom node for subject-less matches
    fn trueNode(self: *Compiler) !*Node {
        return cst.allocNode(self.alloc, self.active_span, .{ .atom = .{ .tok = cst.syntheticToken(":true", self.active_span) } });
    }

    /// `nil` node for bare break/return
    fn nilNode(self: *Compiler) !*Node {
        return cst.allocNode(self.alloc, self.active_span, .{ .err = .{ .toks = &.{} } });
    }

    fn compileImportItem(self: *Compiler, item: cst.CstImportItem) !void {
        const name = importItemName(item);
        const path = item.path.text;
        const err_node = try cst.allocNode(self.alloc, item.span, .{ .err = .{ .toks = &.{} } });
        const cur = state_mod.currentFunctionState(self) orelse return self.fail(
            .ParseError,
            err_node,
            "import statement outside function context",
        );
        if (state_mod.findLocalInCurrentScope(self, name)) |_| {
            const msg = try self.alloc.print("name `{s}` is already defined", .{name});
            return self.fail(.ParseError, err_node, msg);
        }
        // also check import_locals to prevent double import of same name
        for (cur.import_locals.items) |il| {
            if (std.mem.eql(u8, il.name, name)) {
                const msg = try self.alloc.print("name `{s}` is already defined by another import", .{name});
                return self.fail(.ParseError, err_node, msg);
            }
        }
        const slot = self.slot_allocators.items[self.slot_allocators.items.len - 1];
        self.slot_allocators.items[self.slot_allocators.items.len - 1] += 1;

        const import_local = LocalVar{ .name = name, .slot = slot, .mutable = false, .initialized = true };
        try cur.import_locals.append(self.alloc, import_local);
        try cur.all_locals.append(self.alloc, import_local);

        state_mod.reserveLocalSlots(self);

        try self.emit(.load_user_global, revo.CoreAtoms.import.atomId());
        try self.@"const"(try self.vm.ownValueString(path));

        try self.emit(.call, 1);
        try self.regDupe();

        try self.emit(.bind_local, slot);
    }

    /// `fn obj:m() ...` / `fn obj.m() ...`: compile fn, store into index
    fn compileFnMethod(self: *Compiler, f: @FieldType(cst.CstKind, "fn_method")) InternalCompileError!void {
        const span = self.active_span;
        const obj_text: []const u8 = switch (f.head) {
            .method_colon => |m| m.obj_tok.text,
            .method_dot => |m| m.obj_tok.text,
            else => return self.fail(.UnsupportedSyntax, f.body, "bad method head"),
        };
        const key_text: []const u8 = switch (f.head) {
            .method_colon => |m| atomText(m.atom_tok.text),
            .method_dot => |m| m.name_tok.text,
            else => return self.fail(.UnsupportedSyntax, f.body, "bad method head"),
        };
        // colon methods get an explicit `self` first param
        var params: []const cst.CstParam = f.params;
        var owned: []cst.CstParam = &.{};
        if (f.head == .method_colon) {
            owned = try self.alloc.alloc(cst.CstParam, f.params.len + 1);
            owned[0] = .{ .name_tok = cst.syntheticToken("self", span) };
            @memcpy(owned[1..], f.params);
            params = owned;
        }
        defer if (owned.len > 0) self.alloc.free(owned);
        const tps = try cst.tokenTexts(self.alloc, f.type_params);
        // compile the fn value onto the stack
        try self.compileFn(params, f.return_type, f.body, key_text, null, tps);
        // store into obj[key], keep value on top like assignment
        const obj_node = try cst.allocIdent(self.alloc, span, obj_text);
        try self.compile(obj_node, true);
        try self.regDupe();
        const key_atom = try self.vm.internAtom(key_text);
        try self.emit(.table_set_atom, key_atom);
        try self.emit(.table_get_atom, key_atom);
    }

    /// wrap a test body in a zero-param closure and compile it
    fn compileTestBody(self: *Compiler, body: *const Node) !void {
        try self.compileFn(&.{}, null, body, "<test>", null, &.{});
    }

    /// bound name of an import item (explicit or path stem)
    fn importItemName(item: cst.CstImportItem) []const u8 {
        if (item.name_tok) |nt| return nt.text;
        return std.Io.Dir.path.stem(item.path.text);
    }

    pub fn compileCallCst(
        self: *Compiler,
        callee: *const Node,
        args: []const *Node,
    ) InternalCompileError!void {
        const cu = cst.unwrapParen(callee) orelse callee;
        switch (cu.kind) {
            .field => |field| {
                const fname = field.name_tok.text;
                if (try self.tryCompileBoundMethodCall(
                    field.object,
                    fname,
                    args,
                    false,
                )) return;
                try self.compile(field.object, true);
                try self.@"const"(
                    Value.new.atom(try self.vm.internAtom(fname)),
                );
                for (args) |arg| try self.compile(arg, true);
                const argc = args.len;
                try self.emit(.call_field, @intCast(argc));
            },
            .index => |index| {
                try self.compile(index.object, true);
                try self.compile(index.key, true);
                for (args) |arg| try self.compile(arg, true);
                const argc = args.len;
                try self.emit(.call_field, @intCast(argc));
            },
            .ident => |n| {
                const fn_name = n.tok.text;
                const reordered_args = try validateCallArgs(
                    self,
                    fn_name,
                    callee.span,
                    args,
                );
                try self.compile(callee, true);

                // use reordered args if named params were used
                const args_to_compile = if (reordered_args.ptr != args.ptr)
                    reordered_args
                else
                    args;

                for (args_to_compile) |arg| {
                    if (cst.namedArgValue(arg)) |v| {
                        // in call context, assignment expressions should only compile their values
                        try self.compile(v, true);
                    } else {
                        try self.compile(arg, true);
                    }
                }
                if (reordered_args.ptr != args.ptr) self.alloc.free(
                    reordered_args,
                );
                try self.emit(
                    .call,
                    @intCast(
                        args_to_compile.len,
                    ),
                );
            },
            .fn_def => |f| {
                const expanded = try expandDirectFnArgs(self, f.params, args);
                defer if (expanded.ptr != args.ptr) self.alloc.free(expanded);
                try self.compile(callee, true);
                for (expanded) |arg| {
                    if (cst.namedArgValue(arg)) |v| {
                        try self.compile(v, true);
                    } else try self.compile(arg, true);
                }
                try self.emit(
                    .call,
                    @intCast(
                        expanded.len,
                    ),
                );
            },
            .paren => |pr| {
                // stripped by hir.lower; only `()` survives, which cannot call
                if (pr.expr) |_| unreachable;
                return self.fail(.UnsupportedSyntax, callee, "cannot call nothing");
            },
            else => {
                try self.compile(callee, true);
                for (args) |arg| try self.compile(arg, true);
                try self.emit(
                    .call,
                    @intCast(
                        args.len,
                    ),
                );
            },
        }
    }

    /// `obj:method(args)`:
    ///   object is arg 0 at runtime
    pub fn compileMethodCall(
        self: *Compiler,
        m: @FieldType(cst.CstKind, "method_call"),
    ) InternalCompileError!void {
        const mname = atomText(m.atom_tok.text);
        if (try self.tryCompileBoundMethodCall(m.object, mname, m.args, true)) return;
        try self.compile(m.object, true);
        try self.@"const"(Value.new.atom(try self.vm.internAtom(mname)));
        for (m.args) |arg| {
            if (cst.namedArgValue(arg)) |v| try self.compile(v, true) else try self.compile(arg, true);
        }
        const argc = m.args.len | (@as(usize, 1) << 7);
        try self.emit(.call_field, @intCast(argc));
    }

    fn tryCompileBoundMethodCall(
        self: *Compiler,
        object: *const Node,
        name: []const u8,
        args: []const *Node,
        implicit_self: bool,
    ) InternalCompileError!bool {
        const object_type = self.annotatedType(object);
        // same module table the semantic lookup resolves through, for every
        // module-backed primitive; unannotated receivers stay on call_field
        const module_name = switch (object_type.tag) {
            .number => "number",
            .string => "string",
            .table => "table",
            else => return false,
        };

        if (std.mem.eql(u8, module_name, "table") and
            std.mem.eql(u8, name, "add")) return false;

        // a known field shadows the baselib method of the same name;
        // works for any table expression with a known shape, not just locals
        if (object_type.tag == .table) {
            if (object_type.tag.table.fields) |fs| {
                if (types.findField(fs, name) != null) return false;
            }
        }

        const module_atom = try self.vm.internAtom(module_name);
        const module = self.vm.builtin_globals.get(module_atom) orelse return false;
        const module_table_id = module.asTable() orelse return false;
        const module_table = self.vm.tables.get(module_table_id) catch return false;

        const method_atom = try self.vm.internAtom(name);
        const method = module_table.getRawAtom(method_atom, self.vm) orelse return false;
        if (!method.isFunction()) return false;

        try self.emit(.load_builtin_global, module_atom);
        try self.emit(.table_get_atom, method_atom);
        if (implicit_self)
            try self.compile(object, true);
        for (args) |arg| {
            if (cst.namedArgValue(arg)) |v| try self.compile(v, true) else try self.compile(arg, true);
        }
        try self.emit(.call, @intCast(args.len + @intFromBool(implicit_self)));
        return true;
    }

    fn tryReorderNamedParams(
        self: *Compiler,
        args: []const *Node,
        sig: *const types.FunctionSignature,
    ) ![]const *Node {
        var has_named = false;
        var had_error = false;
        for (args) |arg| {
            if (cst.namedArgName(arg) != null) {
                has_named = true;
            } else if (has_named) {
                const msg = try self.alloc.print(
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
            if (cst.namedArgName(arg)) |param_name| {
                var found = false;
                for (sig.param_names, 0..) |sig_name, param_idx| {
                    if (std.mem.eql(u8, sig_name, param_name)) {
                        if (param_seen[param_idx]) {
                            const msg = try self.alloc.print(
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
                    const msg = try self.alloc.print(
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
                    const msg = try self.alloc.print(
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

        if (had_error) return error.CompileFailed;
        return reordered;
    }

    fn validateCallArgs(
        self: *Compiler,
        fn_name: []const u8,
        callee_span: Lexer.Span,
        args: []const *Node,
    ) InternalCompileError![]const *Node {
        const sig = state_mod.findFnSignature(self, fn_name) orelse return args;
        const reordered_args = try tryReorderNamedParams(self, args, sig);
        var had_error = false;

        if (reordered_args.len < sig.required_count or reordered_args.len > sig.params.len) {
            const msg = if (sig.required_count == sig.params.len)
                try self.alloc.print(
                    "call to `{s}` wants {d} arg(s), got {d}",
                    .{ fn_name, sig.required_count, reordered_args.len },
                )
            else
                try self.alloc.print(
                    "call to `{s}` wants at least {d} arg(s), got {d}",
                    .{ fn_name, sig.required_count, reordered_args.len },
                );

            // the caret goes on the arguments that don't fit
            // with too few there is nothing specific to underline
            // , so the call itself is it
            var span = callee_span;
            var label: []const u8 = "";
            if (reordered_args.len > sig.params.len) {
                span = reordered_args[sig.params.len].span;

                for (reordered_args[sig.params.len + 1 ..]) |arg|
                    span = Lexer.Span.merge(span, arg.span);

                // single-line calls keep the header at the callee
                // , so `file:line:col` still points at the call
                if (span.line == callee_span.line) span.column = callee_span.column;
                label = "extra args";
            }
            try self.appendFailureReport(.ParseError, &.{
                .{ .@"error" = msg },
                .{ .span = .{ .span = span, .role = .primary, .message = label } },
            });
            had_error = true;
        }

        const min_args = @min(sig.params.len, reordered_args.len);
        for (0..min_args) |i| {
            const expected_type = sig.params[i];
            if (expected_type.tag == .any) continue;

            // named args are `name = value`; the value carries the type
            const arg = cst.namedArgValue(reordered_args[i]) orelse reordered_args[i];
            const actual_type = self.annotatedType(arg);

            // type params (generics) are .type_var, skip type check
            if (expected_type.tag == .type_var) continue;
            types.ensureCoercible(
                expected_type,
                actual_type,
            ) catch |err| switch (err) {
                error.TypeError => {
                    const expected_str = try type_syntax.formatTypeOpts(self.alloc, expected_type, .{});
                    const actual_str = try type_syntax.formatTypeOpts(self.alloc, actual_type, .{});
                    const label = if (sig.param_names[i].len == 0)
                        try self.alloc.print(
                            "arg {d}",
                            .{i + 1},
                        )
                    else
                        try self.alloc.print(
                            "arg {d} (`{s}`)",
                            .{ i + 1, sig.param_names[i] },
                        );

                    const headline = if (sig.param_names[i].len == 0)
                        try self.alloc.print(
                            "arg {d} to `{s}` wants {s}, got {s}",
                            .{ i + 1, fn_name, expected_str, actual_str },
                        )
                    else
                        try self.alloc.print(
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
                    full_args[idx] = @constCast(def_node);
                } else {
                    // bare `?a` without explicit default defaults to :none
                    const span = if (reordered_args.len > 0) reordered_args[0].span else if (args.len > 0) args[0].span else Lexer.Span{ .start = 0, .end = 0, .line = 1, .column = 1 };
                    full_args[idx] = try cst.allocNode(self.alloc, span, .{ .atom = .{ .tok = cst.syntheticToken("none", span) } });
                }
            }
            // type-check the inserted defaults
            for (reordered_args.len..sig.params.len) |idx| {
                const expected_type = sig.params[idx];
                if (expected_type.tag == .any or expected_type.tag == .type_var) continue;
                // defaults analyze once in semantic; synthesized nones are
                // always atom literals, no scope needed to type them
                const actual_type = blk: {
                    const fu = cst.unwrapParen(full_args[idx]);
                    if (fu != null and fu.?.kind == .atom) break :blk types.TypeInfo{ .tag = .{ .atom = atomText(fu.?.kind.atom.tok.text) } };
                    break :blk self.annotatedType(full_args[idx]);
                };
                types.ensureCoercible(expected_type, actual_type) catch |err| switch (err) {
                    error.TypeError => {
                        const expected_str = try type_syntax.formatTypeOpts(self.alloc, expected_type, .{});
                        const actual_str = try type_syntax.formatTypeOpts(self.alloc, actual_type, .{});
                        try self.appendFailureReport(.ParseError, &.{
                            .{ .@"error" = try self.alloc.print("default for `{s}` wants {s}, got {s}", .{ sig.param_names[idx], expected_str, actual_str }) },
                        });
                        had_error = true;
                    },
                    else => |e| return e,
                };
            }
            if (had_error) return error.CompileFailed;
            // leak the original reordered slice if it was allocated
            if (reordered_args.ptr != args.ptr) self.alloc.free(reordered_args);
            return full_args;
        }
        if (had_error) return error.CompileFailed;
        return reordered_args;
    }

    fn expandDirectFnArgs(
        self: *Compiler,
        params: []const cst.CstParam,
        args: []const *Node,
    ) InternalCompileError![]const *Node {
        if (args.len >= params.len) return args;
        var required: usize = 0;
        for (params) |p| {
            if (p.qmark_tok == null and p.default == null) required += 1;
        }

        if (args.len < required) return args;
        var full = try self.alloc.alloc(*Node, params.len);
        errdefer self.alloc.free(full);

        for (args, 0..) |a, i| full[i] = a;
        for (args.len..params.len) |i| {
            if (params[i].default) |def| {
                full[i] = def;
            } else {
                const span = if (args.len > 0)
                    args[0].span
                else
                    Lexer.Span{ .start = 0, .end = 0, .line = 1, .column = 1 };

                full[i] = try cst.allocNode(self.alloc, span, .{ .atom = .{ .tok = cst.syntheticToken("none", span) } });
            }
        }
        return full;
    }

    pub fn compileComp(self: *Compiler, expr: *Node) InternalCompileError!void {
        var temp_compiler = try Compiler.init(
            self.vm,
            self.test_mode,
            self.alloc,
            self.runtime_alloc,
        );
        defer temp_compiler.deinit();
        // comp bodies come from the analyzed tree, so parent annotations hold
        temp_compiler.annotations = self.annotations;
        temp_compiler.compileRoot(expr) catch |err| switch (err) {
            error.CompileFailed => {
                const nested_failure = try temp_compiler.finishFailure() orelse unreachable;
                try self.appendFailureReport(nested_failure.kind, nested_failure.report.parts);
                return error.CompileFailed;
            },
            else => return err,
        };
        const bytecode = try temp_compiler.finishBytecode();
        defer self.vm.runtime.alloc.free(bytecode.instructions);
        defer self.vm.runtime.alloc.free(bytecode.spans);

        self.annotation_misses += temp_compiler.annotation_misses;
        if (self.first_annotation_miss == null)
            self.first_annotation_miss = temp_compiler.first_annotation_miss;
        const result = try VM.run.runBytecodeReport(
            self.vm,
            "<comp>",
            bytecode.instructions,
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
                    // parens are transparent (the old parser stripped them),
                    // so attribute to the inner expression
                    const inner = cst.unwrapParen(expr) orelse expr;
                    parts[1].span = .{
                        .span = inner.span,
                        .role = .primary,
                    };
                }
            }
            try self.appendFailureReport(.ParseError, parts);
            return error.CompileFailed;
        }
        try self.@"const"(self.vm.mainResult());
    }

    pub fn compileBlock(self: *Compiler, exprs: []const *Node) InternalCompileError!void {
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
            try state_mod.predeclare(self, exprs);
        }
        self.upvalue_cache.clearRetainingCapacity();
        for (exprs, 0..) |expr, idx| {
            const before = self.active_registers;
            self.compile(expr, true) catch |err| switch (err) {
                error.CompileFailed => {
                    self.active_registers = before;
                    continue;
                },
                else => return err,
            };
            if (idx + 1 < exprs.len and self.active_registers > before) try self.regRelease();
        }
        if (pushed_scope) state_mod.popScope(self);
    }

    const BindingKind = bindings.BindingKind;

    pub fn compileBinding(
        self: *Compiler,
        binding: @FieldType(cst.CstKind, "binding"),
        kind: BindingKind,
    ) InternalCompileError!void {
        const target_u = cst.unwrapParen(binding.target);
        const target_is_ident = if (target_u) |u| u.kind == .ident else false;
        if (target_is_ident and kind != .global and kind != .global_const) {
            return bindings.compileLocalBinding(
                self,
                target_u.?.kind.ident.tok.text,
                binding.value,
                kind != .@"const",
                binding.type,
            );
        }

        if (target_is_ident) {
            const name = target_u.?.kind.ident.tok.text;
            try self.validateName(name, binding.target.span);
            const vu = cst.unwrapParen(binding.value);
            if (vu != null and vu.?.kind == .fn_def) {
                const f = vu.?.kind.fn_def;
                const tps = try cst.tokenTexts(self.alloc, f.type_params);
                try self.compileFn(
                    f.params,
                    f.return_type,
                    f.body,
                    name,
                    null,
                    tps,
                );
            } else try self.compile(binding.value, true);

            const inferred_type = if (binding.type) |tn|
                try types.evalTypeExpr(self.aliasScope(), tn)
            else
                self.annotatedType(binding.value);
            try state_mod.setLocalTypeHint(self, name, inferred_type);

            if (cst.isDiscardName(name)) return;
            try self.regDupe();
            try self.declared_globals.put(name, {});
            try self.emit(
                if (kind == .global_const or kind == .@"const") .store_user_global_const else .store_user_global,
                try self.vm.internAtom(name),
            );
            return;
        }

        if (cst.isTablePattern(binding.target)) {
            if (cst.patternBareEntries(binding.target)) |items| try bindings.validateTablePatternShape(
                self,
                items,
                binding.value,
                "binding",
            );
            if (kind == .global or kind == .global_const) {
                try bindings.declareGlobalPattern(self, binding.target);
            } else {
                try bindings.declarePatternLocals(
                    self,
                    binding.target,
                    kind != .@"const",
                );
            }
        } else if (target_u != null and target_u.?.kind == .table) {
            return self.fail(
                .UnsupportedSyntax,
                binding.target,
                "keyed tables do not destructure yet :( use keyless `{a, b}`",
            );
        } else {
            return self.fail(
                .InvalidAssignmentTarget,
                binding.target,
                "cannot bind to this target",
            );
        }

        // hide fresh pattern slots while rhs compiles so
        // `let {a, b} = {b, a}` reads the outer a/b, not the
        // uninitialized shadows (same as single `let x = x + 1`)
        const mask_start = self.masking_stack.items.len;
        if (kind != .global and cst.isTablePattern(binding.target)) {
            try bindings.collectPatternNames(binding.target, &self.masking_stack, self.alloc);
        }

        errdefer self.masking_stack.items.len = mask_start;
        try self.compile(binding.value, true);
        self.masking_stack.items.len = mask_start;
        const src_idx = self.active_registers - 1;

        if (kind == .global) {
            try bindings.bindPattern(self, binding.target, src_idx, kind);
        } else {
            try bindings.bindDeclaredPattern(self, binding.target, src_idx, kind);
        }
    }

    pub fn compileFn(
        self: *Compiler,
        params: []const cst.CstParam,
        return_type: ?*const cst.CstType,
        body: *const Node,
        name: []const u8,
        loop_sym: ?revo.AtomID,
        type_params: []const []const u8,
    ) InternalCompileError!void {
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

        const own_sig = !(cst.isDiscardName(name) or std.mem.eql(u8, name, "<fn>"));

        var s = try FunctionState.init(self.alloc);
        s.type_params = try types.combinedTypeParams(self.alloc, type_params, params);

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
            const pname = param.name_tok.text;
            const local: LocalVar = .{
                .name = pname,
                .slot = @intCast(idx),
                .mutable = true,
                .initialized = true,
                .type_info = if (param.type) |tn| try types.evalTypeExpr(self.aliasScope(), tn) else null,
                .type_explicit = param.type != null,
            };
            try fn_state.locals.append(self.alloc, local);
            try fn_state.all_locals.append(self.alloc, local);
            if (param.type) |type_name| {
                try fn_state.type_hints.append(self.alloc, .{
                    .name = pname,
                    .type_info = try types.evalTypeExpr(self.aliasScope(), type_name),
                });
            }
        }

        const prev_in_loop = self.in_loop_depth;
        self.in_loop_depth = 0;
        if (loop_sym != null) self.in_loop_depth += 1;
        defer self.in_loop_depth = prev_in_loop;

        const required_count: u8 = @intCast(types.requiredCount(params));
        self.active_registers = params.len;
        self.max_registers = params.len;
        self.upvalue_cache.clearRetainingCapacity();
        // signature already placed in parent for caller validation
        // dont need inner map entry (recursion finds parent)

        try self.compile(body, true);
        if (return_type) |rt| {
            _ = rt;
        } else {
            const inferred_type = self.annotatedType(body);
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
        if (self.failure_reports.items.len != 0) return error.CompileFailed;
        if (self.active_registers == 0) try self.pushNil();
        if (loop_sym) |sym| {
            try control.emitLoopRecurse(self, params.len, sym);
        } else if (self.value_stack.items.len > caller_value_stack_len) {
            try self.emit(.ret, 1);
        } else {
            // body already returned, nothing left to pop; bare ret keeps
            // the fn ending in ret without touching an empty stack
            try self.spans.append(self.alloc, self.active_span);
            try self.recordStackOp(.ret, 0, 0, 0, 0);
        }

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
        const template_id = try self.vm.callable.createTemplate(.{
            .addr = body_addr,
            .arity = required_count,
            .total_arity = @intCast(params.len),
            .register_count = @intCast(fn_register_count),
            .name = name,
            .upvalue_specs = finished.upvalues.items,
            .const_locals = const_locals,
            .const_local_bits = &.{},
        });
        try self.pending_templates.append(self.alloc, template_id);
        self.current_template = template_id;
        try self.emit(.make_closure, template_id);

        if (!own_sig) {
            self.alloc.free(sig.params);
            self.alloc.destroy(sig);
        }

        state_pushed = false;
    }

    pub fn appendFailureReport(
        self: *Compiler,
        kind: CompileErrorKind,
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

    pub fn finishFailure(self: *Compiler) !?CompileFailure {
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
        kind: CompileErrorKind,
        expr: *const Node,
        message: []const u8,
    ) error{CompileFailed} {
        self.appendFailureReport(kind, &.{
            .{ .@"error" = message },
            .{ .span = .{ .span = expr.span, .role = .primary } },
        }) catch {};
        return error.CompileFailed;
    }
};

/// if `node` is an int literal in 0..=u32::MAX, return its value, else null
/// , fold range matches load_small_int/load_const cover, value unchanged
pub fn immInt(node: *const Node) ?u32 {
    const u = cst.unwrapParen(node) orelse return null;
    if (u.kind != .number or u.kind.number.is_float) return null;
    const n = u.kind.number.value;
    if (n < 0 or n > std.math.maxInt(u32) or @trunc(n) != n) return null;
    return @intFromFloat(n);
}

/// the immediate-operand opcode for a binop that folds a constant int rhs
/// , returns null for float/`div`/`pow`/`concat` (no imm form, or float math)
pub fn immOpFor(op: cst.BinOp) ?Opcode {
    return switch (op) {
        .add => .add_imm,
        .sub => .sub_imm,
        .mul => .mul_imm,
        .band => .band_imm,
        .lt => .lt_int_imm,
        else => null,
    };
}
