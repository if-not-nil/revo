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

pub const LowerErrorKind = enum { ParseError, UnsupportedSyntax, InvalidAssignmentTarget, IntegerOutOfRange };
pub const LowerFailure = struct { kind: LowerErrorKind, span: ast.Span, message: []const u8, source_name: ?[]const u8 = null };
pub const LowerResult = union(enum) { ok: []Instruction, err: LowerFailure };
pub const Artifact = struct { instructions: []Instruction, spans: []ast.Span };
pub const ArtifactResult = union(enum) { ok: Artifact, err: LowerFailure };
pub const LowerError = error{ ParseError, UnsupportedSyntax, InvalidAssignmentTarget, IntegerOutOfRange } || std.mem.Allocator.Error || expander.ExpandError;
const InternalLowerError = LowerError || error{LoweringFailed};

pub fn lowerExprArtifactReport(vm: *VM, expr: *const Node, test_mode: bool) !ArtifactResult {
    var arena = std.heap.ArenaAllocator.init(vm.runtime.alloc);
    defer arena.deinit();
    var compiler = try Compiler.init(vm, test_mode, arena.allocator(), vm.runtime.alloc);
    defer compiler.deinit();
    compiler.compileRoot(expr) catch |err| switch (err) {
        error.LoweringFailed => return .{ .err = compiler.failure.? },
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
    spans: std.ArrayList(ast.Span),
    active_span: ast.Span = .{ .start = 0, .end = 0, .line = 1, .column = 1 },
    active_registers: usize = 0,
    max_registers: usize = 0,
    struct_layouter: struct_layout.StructLayouter,
    ir_ctx: ?ir.IrContext = null,
    use_ir_first: bool = false,

    pub fn init(vm: *VM, test_mode: bool, arena: std.mem.Allocator, runtime_alloc: std.mem.Allocator) !Compiler {
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
            .spans = try std.ArrayList(ast.Span).initCapacity(arena, 32),
            .break_jumps = try std.ArrayList(usize).initCapacity(arena, 16),
            .loop_result_regs = try std.ArrayList(usize).initCapacity(arena, 8),
            .test_suite_names = try std.ArrayList([]const u8).initCapacity(arena, 4),
            .struct_layouter = struct_layout.StructLayouter.init(arena),
            .ir_ctx = try ir.IrContext.init(arena),
        };
    }

    pub fn deinit(self: *Compiler) void {
        for (self.functions.items) |*s| s.deinit(self.alloc);
        self.functions.deinit(self.alloc);
        self.slot_allocators.deinit(self.alloc);
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
            .number => |n| {
                if (std.math.isFinite(n) and @floor(n) == n and n >= @as(f64, @floatFromInt(std.math.minInt(i64))) and n <= @as(f64, @floatFromInt(std.math.maxInt(i64)))) {
                    try emit.@"const"(self, Data.new.num(@as(i64, @intFromFloat(n))));
                } else try emit.@"const"(self, Data.new.num(n));
            },
            .string => |s| try emit.@"const"(self, try self.vm.ownDataString(s)),
            .multiline_string => |s| try emit.@"const"(self, try self.vm.ownDataString(s)),
            .hash => |name| try emit.@"const"(self, Data{ .atom = try self.vm.internAtom(name) }),
            .nil => try emit.@"const"(self, Data{ .atom = try self.vm.internAtom("nil") }),
            .ident => |name| {
                if (state_mod.resolveLocal(self, name)) |slot| {
                    try emit.emit(self, .load_local, slot);
                } else if (try state_mod.resolveUpvalue(self, name)) |slot| {
                    try emit.emit(self, .load_upval, slot);
                } else try emit.emit(self, .load_global, try self.vm.internAtom(name));
            },
            .unary => |u| switch (u.op) {
                .negate => {
                    try self.compile(u.expr, true);
                    var operand_type: ?[]const u8 = null;
                    if (state_mod.currentFunctionState(self)) |fn_state| {
                        if (u.expr.expr == .ident)
                            operand_type = fn_state.var_types.get(u.expr.expr.ident) orelse null;
                    }
                    const specialized_op = opcode_select.selectUnaryOpcode(.negate, operand_type);
                    try emit.emit(self, specialized_op, 0);
                    propagateUnaryType(self, u);
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
                        try emit.emit(self, .spawn, @intCast(call.args.len + @intFromBool(call.implicit_self)));
                    },
                    else => {
                        try self.compile(u.expr, true);
                        try emit.emit(self, .spawn, 0);
                    },
                },
            },
            .binary => |b| {
                if (try fold.maybeFoldConstBinary(self, b)) return;
                try self.compile(b.left, true);
                try self.compile(b.right, true);
                var left_type: ?[]const u8 = null;
                var right_type: ?[]const u8 = null;
                if (state_mod.currentFunctionState(self)) |fn_state| {
                    if (b.left.expr == .ident) left_type = fn_state.var_types.get(b.left.expr.ident) orelse null;
                    if (b.right.expr == .ident) right_type = fn_state.var_types.get(b.right.expr.ident) orelse null;
                }
                const generic_op = switch (b.op) {
                    inline else => |tag| @field(Opcode, @tagName(tag)),
                };
                const specialized_op = switch (b.op) {
                    .eq, .neq, .lt, .gt, .lte, .gte => opcode_select.selectComparisonOpcode(generic_op, left_type, right_type),
                    else => opcode_select.selectBinaryOpcode(generic_op, left_type, right_type),
                };
                try emit.emit(self, specialized_op, 0);
                propagateBinaryType(self, b);
            },
            .and_expr => |v| try flow.compileAnd(self, v.left, v.right),
            .or_expr => |v| try flow.compileOr(self, v.left, v.right),
            .call => |call| try self.compileCall(expr, call),
            .field => |field| {
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
                if (index.key.expr == .hash) try emit.emit(self, .table_get_atom, try self.vm.internAtom(index.key.expr.hash)) else if (state_mod.constTupleIndex(self, index)) |idx| try emit.emit(self, .tuple_get_const, idx) else {
                    try self.compile(index.key, true);
                    try emit.emit(self, .table_get, 0);
                }
            },
            .if_expr => |v| try flow.compileIf(self, v.condition, v.then_expr, v.else_expr),
            .con_expr => |binding| try self.compileBinding(binding, .con),
            .global => |binding| try self.compileBinding(binding, .global),
            .let_expr => |binding| try self.compileBinding(binding, .let),
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
            .tuple_pattern => return self.fail(.UnsupportedSyntax, expr, "tuple patterns do not compile as values"),
            .range_literal => return self.fail(.UnsupportedSyntax, expr, "range literals only go in forloops for now"),
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
                    try emit.emit(self, .load_global, try self.vm.internAtom("@dotest"));
                    try emit.@"const"(self, try self.vm.ownDataString(test_label));
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
                    try emit.emit(self, .load_global, try self.vm.internAtom("@dosuite"));
                    try emit.@"const"(self, try self.vm.ownDataString(suite_label));
                    try self.test_suite_names.append(self.alloc, suite.name);
                    defer _ = self.test_suite_names.pop();
                    try self.compile(suite.body, true);
                    try emit.emit(self, .call, 2);
                    try emit.regRelease(self);
                }
                try emit.nil(self);
            },
            .macro_expr => return self.fail(.UnsupportedSyntax, expr, "syntax must be expanded before compilation"),
            .proc_macro => return self.fail(.UnsupportedSyntax, expr, "proc must be expanded before compilation"),
        }
    }

    pub fn compileCall(self: *Compiler, expr: *const Node, call: anytype) InternalLowerError!void {
        _ = expr;
        switch (call.callee.expr) {
            .field => |field| {
                const desugared = call.args.len > 0 and call.args[0] == field.object;
                if (desugared) {
                    try self.compile(call.callee, true);
                    for (call.args) |arg| try self.compile(arg, true);
                    try emit.emit(self, .call, @intCast(call.args.len + @intFromBool(call.implicit_self)));
                } else {
                    try self.compile(field.object, true);
                    try emit.@"const"(self, Data{ .atom = try self.vm.internAtom(field.name) });
                    for (call.args) |arg| try self.compile(arg, true);
                    const argc = call.args.len | (@as(usize, @intFromBool(call.implicit_self)) << 15);
                    try emit.emit(self, .call_field, @intCast(argc));
                }
            },
            .index => |index| {
                try self.compile(index.object, true);
                try self.compile(index.key, true);
                for (call.args) |arg| try self.compile(arg, true);
                const argc = call.args.len | (@as(usize, @intFromBool(call.implicit_self)) << 15);
                try emit.emit(self, .call_field, @intCast(argc));
            },
            .ident => |fn_name| {
                try validateCallArgs(self, fn_name, call.args);
                try self.compile(call.callee, true);
                for (call.args) |arg| try self.compile(arg, true);
                try emit.emit(self, .call, @intCast(call.args.len + @intFromBool(call.implicit_self)));
            },
            else => {
                try self.compile(call.callee, true);
                for (call.args) |arg| try self.compile(arg, true);
                try emit.emit(self, .call, @intCast(call.args.len + @intFromBool(call.implicit_self)));
            },
        }
    }

    fn validateCallArgs(self: *Compiler, fn_name: []const u8, args: []const *Node) !void {
        const fn_state = state_mod.currentFunctionState(self) orelse return;
        const sig = fn_state.fn_signatures.get(fn_name) orelse return;
        const min_args = @min(sig.param_types.len, args.len);
        var i: usize = 0;
        while (i < min_args) : (i += 1) {
            if (sig.param_types[i]) |expected_type| {
                const actual_type = type_check.inferExprType(self, args[i]);
                type_check.checkType(self.alloc, type_check.typeInfoFromName(expected_type), actual_type, args[i].span) catch |err| switch (err) {
                    error.TypeError => return self.fail(.ParseError, args[i], "type mismatch in function call"),
                };
            }
        }
    }

    pub fn resolveTypedStructFieldOffset(self: *Compiler, object: *const Node, field_name: []const u8) ?usize {
        if (object.expr != .ident) return null;
        const fn_state = state_mod.currentFunctionState(self) orelse return null;
        const type_name = fn_state.var_types.get(object.expr.ident) orelse return null;
        const layout = self.struct_layouter.getLayout(type_name orelse return null) orelse return null;
        for (layout.fields, 0..) |field, idx| if (std.mem.eql(u8, field.name, field_name)) return idx;
        return null;
    }

    pub fn compileComp(self: *Compiler, expr: *Node) InternalLowerError!void {
        var temp_compiler = try Compiler.init(self.vm, self.test_mode, self.alloc, self.runtime_alloc);
        defer temp_compiler.deinit();
        temp_compiler.compileRoot(expr) catch |err| switch (err) {
            error.LoweringFailed => {
                if (temp_compiler.failure) |nested_failure| self.failure = nested_failure else unreachable;
                return error.LoweringFailed;
            },
            else => return err,
        };
        const artifact = try temp_compiler.finishArtifact();
        defer self.vm.runtime.alloc.free(artifact.instructions);
        defer self.vm.runtime.alloc.free(artifact.spans);
        const result = try VM.module.runCompiledModuleReport(self.comp_vm, "<comp>", artifact.instructions);
        if (result == .err) {
            const eval_failure = result.err;
            self.failure = .{ .kind = .ParseError, .span = eval_failure.span orelse expr.span, .message = eval_failure.message, .source_name = eval_failure.source_name };
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
            try self.compile(expr, true);
            if (idx + 1 < exprs.len) try emit.regRelease(self);
        }
        if (pushed_scope) state_mod.popScope(self);
    }

    const BindingKind = values.BindingKind;
    pub fn compileBinding(self: *Compiler, binding: Binding, kind: BindingKind) InternalLowerError!void {
        if (binding.target.expr == .ident and kind != .global) return values.compileLocalBinding(self, binding.target.expr.ident, binding.value, kind != .con, binding.type_name);
        if (binding.target.expr == .ident) {
            const name = binding.target.expr.ident;
            if (binding.value.expr == .fn_expr) {
                try self.compileFn(binding.value.expr.fn_expr.params, binding.value.expr.fn_expr.return_type, binding.value.expr.fn_expr.body, name, null);
            } else try self.compile(binding.value, true);
            if (ast.isDiscardName(name)) return;
            try emit.regDupe(self);
            try emit.emit(self, if (kind != .con) .store_global else .store_global_const, try self.vm.internAtom(name));
            return;
        }
        try self.compile(binding.value, true);
        const src_idx = self.active_registers - 1;
        try values.bindPattern(self, binding.target, src_idx, kind);
    }

    pub fn compileFn(self: *Compiler, params: []const ast.FnParam, return_type: ?[]const u8, body: *const Node, name: []const u8, loop_sym: ?revo.AtomID) InternalLowerError!void {
        const jump_over = try emit.jump(self, .jump);
        const body_addr: ProgramCounter = @intCast(self.instructions.items.len);
        const caller_registers = self.active_registers;
        const caller_max_registers = self.max_registers;
        errdefer {
            self.active_registers = caller_registers;
            self.max_registers = caller_max_registers;
        }

        var param_types = try std.ArrayList(?[]const u8).initCapacity(self.alloc, params.len);
        defer param_types.deinit(self.alloc);
        for (params) |p| param_types.append(self.alloc, p.type_name) catch return error.OutOfMemory;
        const sig = try self.alloc.create(FunctionState.FnSig);
        errdefer {
            self.alloc.free(sig.param_types);
            self.alloc.destroy(sig);
        }
        sig.* = .{
            .param_types = try param_types.toOwnedSlice(self.alloc),
            .return_type = return_type,
        };

        var s = try FunctionState.init(self.alloc);
        s.return_type = return_type;
        for (params, 0..) |param, idx| {
            const local: LocalVar = .{ .name = param.name, .slot = @intCast(idx), .mutable = true, .initialized = true };
            s.locals.append(self.alloc, local) catch |err| {
                s.deinit(self.alloc);
                return err;
            };
            s.all_locals.append(self.alloc, local) catch |err| {
                s.deinit(self.alloc);
                return err;
            };
            if (param.type_name) |type_name| try s.var_types.put(param.name, type_name);
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
        try self.compile(body, true);
        if (return_type) |rt| {
            try validateImplicitReturnType(self, body, rt);
        }
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
        const proto_id = try self.vm.functions.createPrototype(.{ .addr = body_addr, .arity = @intCast(params.len), .register_count = @intCast(fn_register_count), .name = name, .upvalue_specs = finished.upvalues.items, .const_locals = const_locals, .const_local_bits = &.{} });
        try emit.emit(self, .closure, proto_id);

        if (state_mod.currentFunctionState(self)) |enclosing| {
            try enclosing.fn_signatures.put(name, sig);
        } else {
            self.alloc.free(sig.param_types);
            self.alloc.destroy(sig);
        }

        state_pushed = false;
    }

    fn propagateBinaryType(self: *Compiler, b: anytype) void {
        const left_type = type_check.inferExprType(self, b.left);
        const right_type = type_check.inferExprType(self, b.right);

        const result_type = types.inferBinaryOp(
            switch (b.op) {
                inline else => |tag| @field(types.BinaryOp, @tagName(tag)),
            },
            left_type,
            right_type,
        );
        if (result_type != .any) {
            const type_str = typeStr(result_type);
            if (state_mod.currentFunctionState(self)) |fn_state| {
                _ = fn_state.var_types.put("__result", type_str) catch {};
            }
        }
    }

    fn propagateUnaryType(self: *Compiler, u: anytype) void {
        const operand_type = type_check.inferExprType(self, u.expr);
        const result_type = types.inferUnaryOp(
            switch (u.op) {
                .negate => types.UnaryOp.negate,
                .not => types.UnaryOp.not,
                .spawn, .join, .yield => return,
            },
            operand_type,
        );
        if (result_type != .any) {
            const type_str = typeStr(result_type);
            if (state_mod.currentFunctionState(self)) |fn_state| {
                _ = fn_state.var_types.put("__result", type_str) catch {};
            }
        }
    }

    fn typeStr(t: types.TypeInfo) []const u8 {
        return switch (t) {
            .struct_type => |s| s,
            else => @tagName(t),
        };
    }

    fn validateReturnType(self: *Compiler, val: *const Node) !void {
        const fn_state = state_mod.currentFunctionState(self) orelse return;
        const declared = fn_state.return_type orelse return;
        const actual = type_check.inferExprType(self, val);
        const expected = type_check.typeInfoFromName(declared);
        type_check.checkType(self.alloc, expected, actual, val.span) catch |err| switch (err) {
            error.TypeError => {
                const msg = try std.fmt.allocPrint(self.alloc, "return type mismatch: wanted {s}, got {s}", .{ declared, typeStr(actual) });
                return self.fail(.ParseError, val, msg);
            },
        };
    }

    fn validateImplicitReturnType(self: *Compiler, body: *const Node, declared: []const u8) !void {
        const last_expr = switch (body.expr) {
            .block => |exprs| if (exprs.len > 0) exprs[exprs.len - 1] else return,
            else => body,
        };
        if (last_expr.expr == .return_expr) return;
        const actual = type_check.inferExprType(self, last_expr);
        const expected = type_check.typeInfoFromName(declared);
        type_check.checkType(self.alloc, expected, actual, last_expr.span) catch |err| switch (err) {
            error.TypeError => {
                const msg = try std.fmt.allocPrint(self.alloc, "return type mismatch: wanted {s}, got {s}", .{ declared, typeStr(actual) });
                return self.fail(.ParseError, last_expr, msg);
            },
        };
    }

    pub fn fail(self: *Compiler, kind: LowerErrorKind, expr: *const Node, message: []const u8) error{LoweringFailed} {
        return emit.fail(self, kind, expr, message);
    }
};
