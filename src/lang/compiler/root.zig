const std = @import("std");

const revo = @import("revo");
const Data = revo.Data;
const Instruction = revo.Instruction;
const Opcode = revo.opcode.Opcode;
const VM = revo.VM;
const UpvalueSpec = revo.functions.UpvalueSpec;
const LocalSlot = revo.LocalSlot;
const ProgramCounter = revo.ProgramCounter;
const Operand = revo.Operand;
const Register = revo.opcode.Register;
const memory = revo.memory;

const ast = @import("../ast.zig");
const Node = ast.Node;
const Binding = ast.Binding;
const StructItem = ast.StructItem;
const expander = @import("../expander.zig");
const emit = @import("emit.zig");
const flow = @import("flow.zig");
const fold = @import("fold.zig");
pub const ir = @import("ir.zig");
pub const opcode_select = @import("opcode_select.zig");
pub const state = @import("state.zig");
const state_mod = @import("state.zig");
pub const struct_layout = @import("struct_layout.zig");
pub const types = @import("types.zig");
pub const type_check = @import("type_check.zig");
const values = @import("values.zig");
const diagnostic = @import("../diagnostic.zig");

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
    instructions: std.ArrayList(Instruction),
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
    ir_ctx: ?ir.IrContext = null,
    use_ir_first: bool = false,
    upvalue_cache: std.AutoHashMap(usize, usize) = undefined,
    type_aliases: std.StringHashMap(types.TypeInfo),

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
            .instructions = try std.ArrayList(Instruction).initCapacity(arena, 32),
            .functions = try std.ArrayList(FunctionState).initCapacity(arena, 4),
            .slot_allocators = try std.ArrayList(LocalSlot).initCapacity(arena, 4),
            .failure_reports = try std.ArrayList(LowerFailure).initCapacity(arena, 4),
            .spans = try std.ArrayList(ast.Span).initCapacity(arena, 32),
            .break_jumps = try std.ArrayList(usize).initCapacity(arena, 16),
            .loop_result_regs = try std.ArrayList(usize).initCapacity(arena, 8),
            .test_suite_names = try std.ArrayList([]const u8).initCapacity(arena, 4),
            .struct_layouter = struct_layout.StructLayouter.init(arena),
            .ir_ctx = try ir.IrContext.init(arena),
            .upvalue_cache = std.AutoHashMap(usize, usize).init(arena),
            .type_aliases = std.StringHashMap(types.TypeInfo).init(arena),
        };
    }

    pub fn deinit(self: *Compiler) void {
        if (self.failure_message_owned) self.runtime_alloc.free(self.failure_message);
        for (self.functions.items) |*s| s.deinit(self.alloc);
        self.functions.deinit(self.alloc);
        self.slot_allocators.deinit(self.alloc);
        self.failure_reports.deinit(self.alloc);
        self.instructions.deinit(self.alloc);
        self.spans.deinit(self.alloc);
        self.break_jumps.deinit(self.alloc);
        self.loop_result_regs.deinit(self.alloc);
        self.test_suite_names.deinit(self.alloc);
        self.struct_layouter.deinit();
        if (self.ir_ctx) |*ctx| ctx.deinit();
        self.arena.deinit();
    }

    pub fn finishArtifact(self: *Compiler) !Artifact {
        if (self.use_ir_first) {
            if (self.ir_ctx) |*ctx| {
                var folder = try fold.ConstantFolder.init(self.alloc, self, &ctx.ir_builder);
                defer folder.deinit();
                _ = try folder.foldAll();
                const lowered = try ctx.lowerToVerifyBytecode();
                const spans_copy = try self.runtime_alloc.dupe(ast.Span, self.spans.items);
                return .{ .instructions = lowered, .spans = spans_copy };
            }
        }
        const instr_copy = try self.runtime_alloc.dupe(Instruction, self.instructions.items);
        const spans_copy = try self.runtime_alloc.dupe(ast.Span, self.spans.items);
        return .{ .instructions = instr_copy, .spans = spans_copy };
    }

    pub fn compile(self: *Compiler, expr: *const Node, keep: bool) InternalLowerError!void {
        const prev_span = self.active_span;
        self.active_span = expr.span;
        defer self.active_span = prev_span;

        try self.compileValue(expr);
        if (!keep) try emit.regRelease(self);
    }

    pub fn compileRoot(self: *Compiler, expr: *const Node) InternalLowerError!void {
        try self.compileFn(&.{}, null, expr, "__main", null);
        if (self.failure_reports.items.len != 0 or self.failure != null) return error.LoweringFailed;
        try emit.emit(self, .call, 0);
        try emit.emit(self, .halt, 0);
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
                // int literal?
                if (std.math.isFinite(value) and
                    @floor(value) == value and
                    value >= @as(f64, @floatFromInt(std.math.minInt(i64))) and
                    value <= @as(f64, @floatFromInt(std.math.maxInt(i64))) and
                    !n.is_float)
                {
                    try emit.@"const"(
                        self,
                        Data.new.num(@as(i64, @intFromFloat(value))),
                    );
                } else try emit.@"const"(self, Data.new.num(value));
            },
            .string => |s| try emit.@"const"(self, try self.vm.ownDataString(s)),
            .multiline_string => |s| try emit.@"const"(self, try self.vm.ownDataString(s)),
            .hash => |name| try emit.@"const"(self, Data.new.atom(try self.vm.internAtom(name))),
            .nil => try emit.@"const"(self, Data.new.atom(try self.vm.internAtom("nil"))),
            .ident => |name| {
                if (state_mod.resolveLocal(self, name)) |slot| {
                    try emit.emit(self, .load_local, slot);
                } else if (try state_mod.resolveUpvalue(self, name)) |upval_id| {
                    // cached reg still valid?
                    if (self.upvalue_cache.get(upval_id)) |cached_reg| {
                        if (cached_reg < self.active_registers - 1) {
                            const dst = try state.pushRegister(self);
                            const i: Instruction = .{
                                .op = .move,
                                .a = dst,
                                .b = try state.toRegister(cached_reg),
                            };
                            try self.instructions.append(self.alloc, i);
                            try self.spans.append(self.alloc, self.active_span);
                        } else {
                            try emit.emit(self, .load_upval, upval_id);
                            try self.upvalue_cache.put(upval_id, self.active_registers - 1);
                        }
                    } else {
                        try emit.emit(self, .load_upval, upval_id);
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
                } else try emit.emit(self, .load_global, try self.vm.internAtom(name));
            },
            .unary => |u| switch (u.op) {
                .negate => {
                    try self.compile(u.expr, true);
                    const operand_type = type_check.inferExprType(self, u.expr);
                    const specialized_op = opcode_select.selectUnaryOpcode(.negate, operand_type);
                    try emit.emit(self, specialized_op, 0);
                },
                .not => {
                    try self.compile(u.expr, true);
                    try emit.emit(self, .not, 0);
                },
                .join => {
                    try self.compile(u.expr, true);
                    try emit.emit(self, .join, 0);
                },
                .yield => {
                    try emit.emit(self, .yield, 0);
                    try emit.nil(self);
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
                        try emit.emit(
                            self,
                            .spawn,
                            @intCast(
                                call.args.len + @intFromBool(call.implicit_self),
                            ),
                        );
                    },
                    else => {
                        try self.compile(u.expr, true);
                        try emit.emit(self, .spawn, 0);
                    },
                },
            },
            .binary => |b| {
                if (b.op == .@"union") return self.fail(
                    .UnsupportedSyntax,
                    expr,
                    "union type expression used as a value",
                );
                if (try fold.maybeFoldConstBinary(self, b)) return;

                try self.compile(b.left, true);
                try self.compile(b.right, true);

                const left_type = type_check.inferExprType(self, b.left);
                const right_type = type_check.inferExprType(self, b.right);

                const generic_op = switch (b.op) {
                    .@"union" => unreachable,
                    inline else => |tag| @field(Opcode, @tagName(tag)),
                };

                const specialized_op = switch (b.op) {
                    .@"union" => unreachable,
                    .eq, .neq, .lt, .gt, .lte, .gte => opcode_select.selectComparisonOpcode(
                        generic_op,
                        left_type,
                        right_type,
                    ),
                    else => opcode_select.selectBinaryOpcode(
                        generic_op,
                        left_type,
                        right_type,
                    ),
                };
                try emit.emit(self, specialized_op, 0);
            },
            .and_expr => |v| try flow.compileAnd(self, v.left, v.right),
            .or_expr => |v| try flow.compileOr(self, v.left, v.right),
            .call => |call| try self.compileCall(call),
            .field => |field| {
                // typed struct field?
                if (self.resolveTypedStructFieldOffset(field.object, field.name)) |off| {
                    try self.compile(field.object, true);
                    try emit.emit(self, .struct_get_offset, @intCast(off));
                } else {
                    try self.compile(field.object, true);
                    try emit.emit(self, .table_get_atom, try self.vm.internAtom(field.name));
                }
            },
            .index => |index| {
                try self.compile(index.object, true);
                if (index.key.expr == .hash) try emit.emit(
                    self,
                    .table_get_atom,
                    try self.vm.internAtom(index.key.expr.hash),
                ) else if (state_mod.constTupleIndex(self, index)) |idx| try emit.emit(
                    self,
                    .tuple_get_const,
                    idx,
                ) else {
                    try self.compile(index.key, true);
                    try emit.emit(self, .table_get, 0);
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
            .tuple => |items| try values.compileTuple(self, items),
            .table => |entries| try values.compileTable(self, entries),
            .struct_def => |def| try values.compileStruct(self, expr, def.name, def.items),
            .return_expr => |val| {
                if (val) |v| {
                    try self.compile(v, true);
                    try validateReturnType(self, v);
                } else try emit.nil(self);
                try emit.emit(self, .ret, 1);
            },
            .import_expr => |path| {
                try emit.emit(self, .load_global, try self.vm.internAtom("import"));
                try self.compile(path, true);
                try emit.emit(self, .call, 1);
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
                try emit.emit(self, .unwrap_result, 0);
            },
            .orelse_expr => |v| {
                try self.compile(v.left, true);
                const fail_jump = try emit.jump(self, .jump_if_not_nil_and_not_err);
                try self.compile(v.right, true);
                emit.patchJump(self, fail_jump);
                try emit.emit(self, .unwrap_result, 1);
            },
            .test_block => |block| {
                if (self.test_mode and !block.skip) {
                    const test_label = try self.formatSuiteTestName(block.name);
                    defer self.alloc.free(test_label);
                    try emit.emit(
                        self,
                        .load_global,
                        try self.vm.internAtom("@dotest"),
                    );
                    try emit.@"const"(
                        self,
                        try self.vm.ownDataString(test_label),
                    );
                    try self.compile(block.body, true);
                    try emit.emit(self, .call, 2);
                    try emit.regRelease(self);
                }
                try emit.nil(self);
            },
            .test_suite => |suite| {
                if (self.test_mode) {
                    const suite_label = try self.formatSuiteTestName(suite.name);
                    defer self.alloc.free(suite_label);
                    try emit.emit(
                        self,
                        .load_global,
                        try self.vm.internAtom("@dosuite"),
                    );
                    try emit.@"const"(
                        self,
                        try self.vm.ownDataString(suite_label),
                    );
                    try self.test_suite_names.append(self.alloc, suite.name);
                    defer _ = self.test_suite_names.pop();
                    try self.compile(suite.body, true);
                    try emit.emit(self, .call, 2);
                    try emit.regRelease(self);
                }
                try emit.nil(self);
            },
            .type_alias => |t| {
                const type_info = type_check.evalTypeExpr(self, t.type_expr) catch |err| switch (err) {
                    error.TypeError => return self.fail(
                        .UnsupportedSyntax,
                        t.type_expr,
                        "invalid type expression",
                    ),
                    error.UnexpectedToken => return self.fail(
                        .ParseError,
                        t.type_expr,
                        "unexpected token in type expression",
                    ),
                    error.UnsupportedSyntax => return self.fail(
                        .UnsupportedSyntax,
                        t.type_expr,
                        "unsupported type expression syntax",
                    ),
                    error.OutOfMemory => return error.OutOfMemory,
                };
                try self.type_aliases.put(t.name, type_info);
                try emit.nil(self);
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
                    try emit.emit(
                        self,
                        .call,
                        @intCast(
                            call.args.len + @intFromBool(call.implicit_self),
                        ),
                    );
                } else {
                    if (try self.tryCompileBoundMethodCall(
                        field,
                        call.args,
                    )) return;
                    try self.compile(field.object, true);
                    try emit.@"const"(
                        self,
                        Data.new.atom(try self.vm.internAtom(field.name)),
                    );
                    for (call.args) |arg| try self.compile(arg, true);
                    const argc = call.args.len |
                        (@as(usize, @intFromBool(call.implicit_self)) << 15);
                    try emit.emit(self, .call_field, @intCast(argc));
                }
            },
            .index => |index| {
                try self.validateTypedCall(call.callee, call.args);
                try self.compile(index.object, true);
                try self.compile(index.key, true);
                for (call.args) |arg| try self.compile(arg, true);
                const argc = call.args.len |
                    (@as(usize, @intFromBool(call.implicit_self)) << 15);
                try emit.emit(self, .call_field, @intCast(argc));
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
                try emit.emit(
                    self,
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
                try emit.emit(
                    self,
                    .call,
                    @intCast(
                        call.args.len + @intFromBool(call.implicit_self),
                    ),
                );
            },
            else => {
                try self.compile(call.callee, true);
                for (call.args) |arg| try self.compile(arg, true);
                try emit.emit(
                    self,
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
                "{s} expects {d} argument(s), got {d}",
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
                self.alloc,
                expected_type,
                type_check.inferExprType(self, arg),
                arg.span,
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
                            "argument {d} (`{s}`) to `{s}` expects {s}, got {s}",
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
                            "argument {d} to `{s}` expects {s}, got {s}",
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

    fn tryCompileBoundMethodCall(
        self: *Compiler,
        field: anytype,
        args: []const *Node,
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
            if (state_mod.localHasTableField(
                self,
                field.object.expr.ident,
                field.name,
            )) return false;
        }

        const module_atom = try self.vm.internAtom(module_name);
        const module = self.vm.stdlib_globals.get(module_atom) orelse return false;
        const module_table_id = module.asTable() orelse return false;
        const module_table = self.vm.tables.get(module_table_id) catch return false;

        const method_atom = try self.vm.internAtom(field.name);
        const method = module_table.getRaw(Data.new.atom(method_atom)) orelse return false;
        if (!method.isFunction()) return false;

        try emit.emit(self, .load_stdlib_global, module_atom);
        try emit.emit(self, .table_get_atom, method_atom);
        try self.compile(field.object, true);
        for (args) |arg| try self.compile(arg, true);
        try emit.emit(self, .call, @intCast(args.len + 1));
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
        for (args) |arg| {
            if (isNamedParam(arg) != null) {
                has_named = true;
            } else if (has_named) {
                const msg = try std.fmt.allocPrint(
                    self.alloc,
                    "positional argument cannot follow named argument",
                    .{},
                );
                return self.fail(.ParseError, arg, msg);
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
                            return self.fail(.ParseError, arg, msg);
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
                    return self.fail(.ParseError, arg, msg);
                }
            } else {
                if (positional_idx >= sig.param_names.len) {
                    const msg = try std.fmt.allocPrint(
                        self.alloc,
                        "too many positional arguments",
                        .{},
                    );
                    return self.fail(.ParseError, arg, msg);
                }
                reordered[positional_idx] = arg;
                param_seen[positional_idx] = true;
                positional_idx += 1;
            }
        }

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
                "call to `{s}` expects {d} argument(s), got {d}",
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
                    self.alloc,
                    type_check.resolveTypeName(self, expected_type),
                    actual_type,
                    reordered_args[i].span,
                ) catch |err| switch (err) {
                    error.TypeError => {
                        const label = if (sig.param_names[i].len == 0)
                            try std.fmt.allocPrint(
                                self.alloc,
                                "argument {d}",
                                .{i + 1},
                            )
                        else
                            try std.fmt.allocPrint(
                                self.alloc,
                                "argument {d} (`{s}`)",
                                .{ i + 1, sig.param_names[i] },
                            );

                        const headline = if (sig.param_names[i].len == 0)
                            try std.fmt.allocPrint(
                                self.alloc,
                                "argument {d} to `{s}` expects {s}, got {s}",
                                .{
                                    i + 1,
                                    fn_name,
                                    expected_type,
                                    types.typeName(actual_type),
                                },
                            )
                        else
                            try std.fmt.allocPrint(
                                self.alloc,
                                "argument {d} (`{s}`) to `{s}` expects {s}, got {s}",
                                .{
                                    i + 1,
                                    sig.param_names[i],
                                    fn_name,
                                    expected_type,
                                    types.typeName(actual_type),
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

    fn buildTypesList(
        self: *Compiler,
        type_opts: []const ?[]const u8,
    ) ![]const []const u8 {
        var list = try std.ArrayList([]const u8).initCapacity(
            self.alloc,
            type_opts.len,
        );
        for (type_opts) |maybe_type| {
            try list.append(self.alloc, maybe_type orelse "any");
        }
        return try list.toOwnedSlice(self.alloc);
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

    fn aliasRuntimeValue(self: *Compiler, ti: types.TypeInfo) ?Data {
        return switch (ti) {
            .atom => |name| {
                const id = self.vm.internAtom(types.atomPayload(name)) catch return null;
                return Data.new.atom(id);
            },
            .@"union" => |variants| blk: {
                if (variants.len == 0) break :blk null;
                break :blk self.unionVariantRuntimeValue(variants[0]);
            },
            else => null,
        };
    }

    fn unionVariantRuntimeValue(self: *Compiler, variant: types.UnionVariant) ?Data {
        if (variant.name.len == 0) {
            if (variant.types.len == 0) return null;
            if (variant.types.len == 1) return aliasRuntimeValue(self, variant.types[0]);
            return null;
        }

        var items = std.ArrayList(Data).initCapacity(self.alloc, variant.types.len + 1) catch return null;
        defer items.deinit(self.alloc);
        const atom_id = self.vm.internAtom(types.atomPayload(variant.name)) catch return null;
        items.append(self.alloc, Data.new.atom(atom_id)) catch return null;
        for (variant.types) |payload_type| {
            const payload = aliasRuntimeValue(self, payload_type) orelse return null;
            items.append(self.alloc, payload) catch return null;
        }
        const tid = self.vm.tuples.create(items.items) catch return null;
        return Data.new.tuple(tid);
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
        try emit.@"const"(self, self.comp_vm.mainResult());
    }

    pub fn compileBlock(self: *Compiler, exprs: []const *Node) InternalLowerError!void {
        if (exprs.len == 0) return emit.nil(self);
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
            if (idx + 1 < exprs.len and self.active_registers > before) try emit.regRelease(self);
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
            if (binding.value.expr == .fn_expr) {
                try self.compileFn(
                    binding.value.expr.fn_expr.params,
                    binding.value.expr.fn_expr.return_type,
                    binding.value.expr.fn_expr.body,
                    name,
                    null,
                );
            } else try self.compile(binding.value, true);

            const inferred_type = type_check.inferExprType(self, binding.value);
            try state_mod.setLocalTypeHint(self, name, inferred_type);
            if (type_check.storedTypeName(self, inferred_type)) |stored_name| {
                if (state_mod.currentFunctionState(self)) |fn_state|
                    try fn_state.var_types.put(name, stored_name);
            }

            if (ast.isDiscardName(name)) return;
            try emit.regDupe(self);
            try emit.emit(
                self,
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
        }

        try self.compile(binding.value, true);
        const src_idx = self.active_registers - 1;
        try values.bindPattern(self, binding.target, src_idx, kind);
    }

    pub fn compileFn(
        self: *Compiler,
        params: []const ast.FnParam,
        return_type: ?[]const u8,
        body: *const Node,
        name: []const u8,
        loop_sym: ?revo.AtomID,
    ) InternalLowerError!void {
        const jump_over = try emit.jump(self, .jump);
        const body_addr: ProgramCounter = @intCast(self.instructions.items.len);
        const caller_registers = self.active_registers;
        const caller_max_registers = self.max_registers;
        errdefer {
            self.active_registers = caller_registers;
            self.max_registers = caller_max_registers;
        }

        const own_sig = !(ast.isDiscardName(name) or std.mem.eql(u8, name, "<fn>"));
        const sig = try state_mod.allocFnSig(self, params, return_type);

        var s = try FunctionState.init(self.alloc);
        s.return_type = return_type;
        for (params, 0..) |param, idx| {
            const local: LocalVar = .{
                .name = param.name,
                .slot = @intCast(idx),
                .mutable = true,
                .initialized = true,
                .type_name = param.type_name,
            };
            s.locals.append(self.alloc, local) catch |err| {
                s.deinit(self.alloc);
                return err;
            };
            s.all_locals.append(self.alloc, local) catch |err| {
                s.deinit(self.alloc);
                return err;
            };
            if (param.type_name) |type_name| try s.var_types.put(param.name, type_name);
            if (param.type_name) |type_name| {
                s.type_hints.append(self.alloc, .{
                    .name = param.name,
                    .type_info = type_check.resolveTypeName(self, type_name),
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
        try self.compile(body, true);
        if (return_type) |rt| {
            try validateImplicitReturnType(self, body, rt);
        } else {
            const inferred_type = type_check.inferExprType(self, body);
            const inferred_type_str = try self.alloc.dupe(u8, types.typeName(inferred_type));
            sig.return_type = inferred_type_str;
        }
        if (self.failure_reports.items.len != 0 or self.failure != null) return error.LoweringFailed;
        if (self.active_registers == 0) try emit.nil(self);
        if (loop_sym) |sym| try flow.emitLoopRecurse(self, params.len, sym) else try emit.emit(self, .ret, 1);

        const fn_register_count = self.max_registers;
        self.active_registers = caller_registers;
        self.max_registers = caller_max_registers;

        var finished = self.functions.pop() orelse unreachable;
        defer finished.deinit(self.alloc);

        _ = self.slot_allocators.pop() orelse unreachable;
        const const_locals = try state_mod.collectConstLocals(self, finished.all_locals.items);
        defer self.alloc.free(const_locals);

        emit.patchJump(self, jump_over);
        const proto_id = try self.vm.functions.createPrototype(.{
            .addr = body_addr,
            .arity = @intCast(params.len),
            .register_count = @intCast(fn_register_count),
            .name = name,
            .upvalue_specs = finished.upvalues.items,
            .const_locals = const_locals,
            .const_local_bits = &.{},
        });
        try emit.emit(self, .closure, proto_id);

        if (!own_sig) {
            self.alloc.free(sig.param_types);
            self.alloc.destroy(sig);
        }

        state_pushed = false;
    }

    fn typeStr(t: types.TypeInfo) []const u8 {
        return types.typeName(t);
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
        const expected = type_check.resolveTypeName(self, declared);
        type_check.checkType(self.alloc, expected, actual, val.span) catch |err| switch (err) {
            error.TypeError => {
                const msg = try std.fmt.allocPrint(
                    self.alloc,
                    "return type mismatch: wanted {s}, got {s}",
                    .{ declared, typeStr(actual) },
                );
                return self.setFailureParts(
                    .ParseError,
                    .{
                        .span = val.span,
                        .role = .primary,
                        .message = "return value",
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
        const expected = type_check.resolveTypeName(self, declared);
        type_check.checkType(self.alloc, expected, actual, last_expr.span) catch |err| switch (err) {
            error.TypeError => {
                const msg = try std.fmt.allocPrint(
                    self.alloc,
                    "return type mismatch: wanted {s}, got {s}",
                    .{ declared, typeStr(actual) },
                );
                return self.setFailureParts(
                    .ParseError,
                    .{
                        .span = last_expr.span,
                        .role = .primary,
                        .message = "return value",
                    },
                    msg,
                    &.{},
                );
            },
        };
    }

    /// compat in case i wanna add
    pub fn fail(
        self: *Compiler,
        kind: LowerErrorKind,
        expr: *const Node,
        message: []const u8,
    ) error{LoweringFailed} {
        return self.setFailureParts(kind, .{ .span = expr.span, .role = .primary }, message, &.{});
    }
};
