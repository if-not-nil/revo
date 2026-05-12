const std = @import("std");

const lang = @import("./root.zig");
const ast = lang.ast;
const Expr = ast.Expr;
const Node = ast.Node;
const Binding = ast.Binding;
const StructField = ast.StructField;
const StructItem = ast.StructItem;
const expander = lang.expander;
const testing = lang.testing;
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

const FnExpr = @FieldType(Expr, "fn_expr");

//
// compiler result types
//
pub const LowerErrorKind = enum {
    ParseError,
    UnsupportedSyntax,
    InvalidAssignmentTarget,
    IntegerOutOfRange,
    InvalidBytecode,
};

pub const LowerFailure = struct {
    kind: LowerErrorKind,
    span: ast.Span,
    message: []const u8,
    source_name: ?[]const u8 = null,
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
    InvalidBytecode,
} || std.mem.Allocator.Error || expander.ExpandError;

// w/ internal sentinel used to short-circuit after recording failure
const InternalLowerError = LowerError || error{LoweringFailed};

pub fn lowerExprArtifactReport(vm: *VM, expr: *const Node, test_mode: bool) !ArtifactResult {
    var compiler = try Compiler.init(vm, test_mode);
    defer compiler.deinit();

    compiler.compileRoot(expr) catch |err| switch (err) {
        error.LoweringFailed => return .{ .err = compiler.failure.? },
        else => return err,
    };
    return .{ .ok = try compiler.finishArtifact() };
}

const LoopScope = struct {
    compiler: *Compiler,
    break_start: usize,
    prev_in_loop: usize,

    fn init(compiler: *Compiler) InternalLowerError!LoopScope {
        const prev = compiler.in_loop_depth;
        compiler.in_loop_depth += 1;
        try compiler.emitNil();
        const result_reg: usize = compiler.active_registers - 1;
        try compiler.loop_result_regs.append(compiler.alloc, result_reg);
        return .{
            .compiler = compiler,
            .break_start = compiler.break_jumps.items.len,
            .prev_in_loop = prev,
        };
    }

    fn deinit(self: *LoopScope) void {
        const c = self.compiler;
        _ = c.loop_result_regs.pop();
        const exit_addr: usize = c.instructions.items.len;
        while (c.break_jumps.items.len > self.break_start) {
            const idx = c.break_jumps.pop().?;
            c.instructions.items[idx].bx = @intCast(exit_addr);
        }
        c.in_loop_depth = self.prev_in_loop;
    }
};

//
// core compiler
//
pub const Compiler = struct {
    const LocalValueKind = enum {
        unknown,
        tuple_literal,
    };

    const LocalVar = struct {
        name: []const u8,
        slot: LocalSlot,
        mutable: bool,
        initialized: bool,
        kind: LocalValueKind = .unknown,
    };

    const FunctionState = struct {
        locals: std.ArrayList(LocalVar),
        all_locals: std.ArrayList(LocalVar),
        upvalues: std.ArrayList(UpvalueSpec),
        scope_starts: std.ArrayList(usize),
        next_slot: LocalSlot,

        fn init(alloc: std.mem.Allocator) !FunctionState {
            return .{
                .locals = try std.ArrayList(LocalVar).initCapacity(alloc, 8),
                .all_locals = try std.ArrayList(LocalVar).initCapacity(alloc, 8),
                .upvalues = try std.ArrayList(UpvalueSpec).initCapacity(alloc, 4),
                .scope_starts = try std.ArrayList(usize).initCapacity(alloc, 8),
                .next_slot = 0,
            };
        }

        fn deinit(self: *FunctionState, alloc: std.mem.Allocator) void {
            self.locals.deinit(alloc);
            self.all_locals.deinit(alloc);
            self.upvalues.deinit(alloc);
            self.scope_starts.deinit(alloc);
        }
    };

    vm: *VM,
    comp_vm: *VM, // separate reference for compexpr execution during compilation
    alloc: std.mem.Allocator,
    test_mode: bool,
    instructions: std.ArrayList(Instruction),
    functions: std.ArrayList(FunctionState),
    temp_counter: usize = 0,
    temp_names: std.ArrayList([]u8),
    /// flat list of break jump instruction indices for all enclosing inline loops
    /// each loop tracks its start index in this list; breaks append to it
    /// when a loop ends, it patches all jumps from its start index and shrinks the list
    break_jumps: std.ArrayList(usize),
    /// stack of result registers for inline loops (where break stores its value)
    loop_result_regs: std.ArrayList(usize),
    test_suite_names: std.ArrayList([]const u8),
    /// depth of inline loops for validating break
    in_loop_depth: usize = 0,
    failure: ?LowerFailure = null,
    spans: std.ArrayList(ast.Span),
    active_span: ast.Span = .{ .start = 0, .end = 0, .line = 1, .column = 1 },
    active_registers: usize = 0,
    max_registers: usize = 0,

    fn init(vm: *VM, test_mode: bool) !Compiler {
        return .{
            .vm = vm,
            .comp_vm = vm, // just use the same one for now
            .alloc = vm.runtime.alloc,
            .test_mode = test_mode,
            .instructions = try std.ArrayList(Instruction).initCapacity(vm.runtime.alloc, 32),
            .functions = try std.ArrayList(FunctionState).initCapacity(vm.runtime.alloc, 4),
            .spans = try std.ArrayList(ast.Span).initCapacity(vm.runtime.alloc, 32),
            .temp_names = try std.ArrayList([]u8).initCapacity(vm.runtime.alloc, 16),
            .break_jumps = try std.ArrayList(usize).initCapacity(vm.runtime.alloc, 16),
            .loop_result_regs = try std.ArrayList(usize).initCapacity(vm.runtime.alloc, 8),
            .test_suite_names = try std.ArrayList([]const u8).initCapacity(vm.runtime.alloc, 4),
        };
    }

    fn deinit(self: *Compiler) void {
        // comp_vm is just a reference to vm, so its not deinitted
        for (self.temp_names.items) |name| self.alloc.free(name);
        for (self.functions.items) |*state| state.deinit(self.alloc);
        self.functions.deinit(self.alloc);
        self.instructions.deinit(self.alloc);
        self.spans.deinit(self.alloc);
        self.temp_names.deinit(self.alloc);
        self.break_jumps.deinit(self.alloc);
        self.loop_result_regs.deinit(self.alloc);
        self.test_suite_names.deinit(self.alloc);
    }

    /// pushes a new register onto the stack and returns it,
    /// then updates max_registers
    fn pushRegister(self: *Compiler) !Register {
        const reg_val = try reg(self.active_registers);
        self.active_registers += 1;
        if (self.active_registers > self.max_registers) self.max_registers = self.active_registers;
        return reg_val;
    }

    /// pops the top register from the stack
    fn popRegister(self: *Compiler) void {
        // if (self.active_registers == 0) return; // probably gonna be caught anyways so idk if this goes here
        self.active_registers -= 1;
        if (self.currentFunctionState()) |state| {
            if (self.active_registers < state.next_slot) self.active_registers = state.next_slot;
        }
    }

    fn finishArtifact(self: *Compiler) !Artifact {
        return .{
            .instructions = try self.instructions.toOwnedSlice(self.alloc),
            .spans = try self.spans.toOwnedSlice(self.alloc),
        };
    }

    fn compile(self: *Compiler, expr: *const Node, keep: bool) InternalLowerError!void {
        // track source span so emitted instructions keep debug mapping
        const prev_span = self.active_span;
        self.active_span = expr.span;
        defer self.active_span = prev_span;
        try self.compileValue(expr);
        if (!keep) try self.releaseRegister();
    }

    fn compileRoot(self: *Compiler, expr: *const Node) InternalLowerError!void {
        try self.compileFn(&.{}, expr, "__main", null);
        try self.emit(.call, 0);
        try self.emit(.halt, 0);
    }

    fn formatSuiteTestName(self: *Compiler, test_name: []const u8) ![]u8 {
        var out = try std.ArrayList(u8).initCapacity(self.alloc, test_name.len + 16);
        errdefer out.deinit(self.alloc);

        if (self.test_suite_names.items.len == 0) {
            try out.appendSlice(self.alloc, test_name);
            return out.toOwnedSlice(self.alloc);
        }

        try out.appendSlice(self.alloc, self.test_suite_names.items[0]);
        for (self.test_suite_names.items[1..]) |suite_name| {
            try out.appendSlice(self.alloc, "::");
            try out.appendSlice(self.alloc, suite_name);
        }
        try out.appendSlice(self.alloc, "::");
        try out.appendSlice(self.alloc, test_name);
        return out.toOwnedSlice(self.alloc);
    }

    fn compileValue(self: *Compiler, expr: *const Node) InternalLowerError!void {
        switch (expr.expr) {
            //
            // atoms & identifiers
            //
            .number => |n| {
                if (std.math.isFinite(n) and @floor(n) == n and
                    n >= @as(f64, @floatFromInt(std.math.minInt(i64))) and
                    n <= @as(f64, @floatFromInt(std.math.maxInt(i64))))
                {
                    try self.emitConst(Data.new.num(@as(i64, @intFromFloat(n))));
                } else {
                    try self.emitConst(Data.new.num(n));
                }
            },
            .string => |s| try self.emitConst(try self.vm.ownDataString(s)),
            .multiline_string => |s| try self.emitConst(try self.vm.ownDataString(s)),
            .hash => |name| try self.emitConst(Data{ .atom = try self.vm.internAtom(name) }),
            .nil => try self.emitConst(Data{ .atom = try self.vm.internAtom("nil") }),
            .ident => |name| {
                if (self.resolveLocal(name)) |slot| {
                    try self.emit(.load_local, slot);
                } else if (try self.resolveUpvalue(name)) |slot| {
                    try self.emit(.load_upval, slot);
                } else {
                    try self.emit(.load_global, try self.vm.internAtom(name));
                }
            },
            //
            // unary & binary
            //
            .unary => |u| {
                switch (u.op) {
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
                        try self.emitNil();
                    },
                    .spawn => {
                        switch (u.expr.expr) {
                            .call => |call| {
                                try self.compile(call.callee, true);
                                if (call.implicit_self) switch (call.callee.expr) {
                                    .field => |field| try self.compile(field.object, true),
                                    .index => |index| try self.compile(index.object, true),
                                    else => {},
                                };
                                for (call.args) |arg| try self.compile(arg, true);
                                try self.emit(.spawn, @intCast(call.args.len + @intFromBool(call.implicit_self)));
                            },
                            else => {
                                try self.compile(u.expr, true);
                                try self.emit(.spawn, 0);
                            },
                        }
                    },
                }
            },
            .binary => |b| {
                if (try self.maybeFoldConstBinary(b)) {
                    return;
                }
                try self.compile(b.left, true);
                try self.compile(b.right, true);
                //
                // isnt it really nice how opcode tag names line up with opcode names
                try self.emit(switch (b.op) {
                    inline else => |tag| @field(Opcode, @tagName(tag)),
                }, 0);
            },
            .and_expr => |v| try self.compileAnd(v.left, v.right),
            .or_expr => |v| try self.compileOr(v.left, v.right),
            //
            // call & lookup
            //
            .call => |call| try self.compileCall(expr, call),
            .field => |field| {
                try self.compile(field.object, true);
                try self.emit(.table_get_atom, try self.vm.internAtom(field.name));
            },
            .index => |index| {
                try self.compile(index.object, true);
                if (index.key.expr == .hash) {
                    try self.emit(.table_get_atom, try self.vm.internAtom(index.key.expr.hash));
                } else if (self.constTupleIndex(index)) |idx| {
                    try self.emit(.tuple_get_const, idx);
                } else {
                    try self.compile(index.key, true);
                    try self.emit(.table_get, 0);
                }
            },
            //
            // control flow & binding
            //
            .if_expr => |v| try self.compileIf(v.condition, v.then_expr, v.else_expr),
            .con_expr => |binding| try self.compileBinding(binding, .con),
            .global => |binding| try self.compileBinding(binding, .global),
            .let_expr => |binding| try self.compileBinding(binding, .let),
            .assign_expr => |assign| try self.compileAssign(assign.target, assign.value),
            .block => |exprs| try self.compileBlock(exprs),
            .tuple => |items| try self.compileTuple(items),
            .table => |entries| try self.compileTable(entries),
            .struct_def => |def| try self.compileStruct(expr, def.name, def.items),
            .return_expr => |val| {
                if (val) |v| try self.compile(v, true) else try self.emitNil();
                try self.emit(.ret, 1);
            },
            .import_expr => |path| {
                try self.emit(.load_global, try self.vm.internAtom("import"));
                try self.compile(path, true);
                try self.emit(.call, 1);
            },
            .comp_block => |cb| try self.compileComp(cb.expr),
            //
            // core sugar
            //
            .pipe_expr => |pipe| try self.compilePipe(pipe.left, pipe.right),
            .loop_expr => |v| try self.compileLoop(v.body),
            .for_loop => |v| try self.compileFor(v.params, v.body, v.iter),
            .while_loop => |v| try self.compileWhile(v.predicate, v.body),
            .break_expr => |value| {
                if (self.in_loop_depth == 0) return self.fail(
                    .UnsupportedSyntax,
                    expr,
                    "break is only valid inside loop",
                );
                // break inside a closure-based loop (function body): use return
                if (value) |v| try self.compile(v, true) else try self.emitNil();
                try self.emit(.ret, 1);
            },
            .fn_expr => |fn_expr| try self.compileFn(fn_expr.params, fn_expr.body, "<fn>", null),
            .match_expr => |v| try self.compileMatch(v.subject, v.arms),
            .tuple_pattern => return self.fail(
                .UnsupportedSyntax,
                expr,
                "tuple patterns do not compile as values",
            ),
            .range_literal => {
                return self.fail(
                    .UnsupportedSyntax,
                    expr,
                    "range literals only go in forloops for now",
                );
            },
            .try_expr => |expr_ptr| {
                // try unwrap checks if result is error tuple and returns early if so
                // otherwise unwraps (:ok, x) to x
                try self.compile(expr_ptr, true);
                try self.emit(.unwrap_result, 0); // bx=0 for propagate errors
            },
            .orelse_expr => |v| {
                // compile left if it's error or nil use right
                try self.compile(v.left, true);
                const fail_jump = try self.emitJump(.jump_if_not_nil_and_not_err);
                try self.compile(v.right, true);
                self.patchJump(fail_jump);
                // unwrap (:ok, x) to x if it got here
                try self.emit(.unwrap_result, 1); // bx=1 for dont propagate errors
            },
            .test_block => |block| {
                if (self.test_mode) {
                    if (!block.skip) {
                        const test_label = try self.formatSuiteTestName(block.name);
                        defer self.alloc.free(test_label);
                        try self.emit(.load_global, try self.vm.internAtom("@dotest"));
                        try self.emitConst(try self.vm.ownDataString(test_label));
                        try self.compile(block.body, true);
                        try self.emit(.call, 2);
                        try self.releaseRegister();
                    }
                }
                try self.emitNil();
            },
            .test_suite => |suite| {
                if (self.test_mode) {
                    const suite_label = try self.formatSuiteTestName(suite.name);
                    defer self.alloc.free(suite_label);
                    try self.emit(.load_global, try self.vm.internAtom("@dosuite"));
                    try self.emitConst(try self.vm.ownDataString(suite_label));

                    // push for nested tests
                    try self.test_suite_names.append(self.alloc, suite.name);
                    defer _ = self.test_suite_names.pop();

                    try self.compile(suite.body, true);
                    try self.emit(.call, 2);
                    try self.releaseRegister();
                }
                try self.emitNil();
            },
            //
            // tech debt
            //
            .macro_expr => return self.fail(.UnsupportedSyntax, expr, "syntax must be expanded before compilation"),
            .proc_macro => return self.fail(.UnsupportedSyntax, expr, "proc must be expanded before compilation"),
        }
    }

    fn compileCall(self: *Compiler, expr: *const Node, call: anytype) InternalLowerError!void {
        _ = expr;
        switch (call.callee.expr) {
            .field => |field| {
                try self.compile(field.object, true);
                try self.emitConst(Data{ .atom = try self.vm.internAtom(field.name) });
                for (call.args) |arg| try self.compile(arg, true);
                const argc = call.args.len | (@as(usize, @intFromBool(call.implicit_self)) << 15);
                try self.emit(.call_field, @intCast(argc));
            },
            .index => |index| {
                try self.compile(index.object, true);
                try self.compile(index.key, true);
                for (call.args) |arg| try self.compile(arg, true);
                const argc = call.args.len | (@as(usize, @intFromBool(call.implicit_self)) << 15);
                try self.emit(.call_field, @intCast(argc));
            },
            else => {
                try self.compile(call.callee, true);
                for (call.args) |arg| try self.compile(arg, true);
                try self.emit(.call, @intCast(call.args.len + @intFromBool(call.implicit_self)));
            },
        }
    }

    //
    // binding & assignment
    //
    test "pipe" {
        try testing.top_string("2 |> tostring", "2");
    }
    test "pipe partial application" {
        try testing.top_number(
            \\ const f = fn(a, b) a + b
            \\ 2
            \\ |> f(40)
        , 42);
    }
    test "pipe partial application with multiple args compiles" {
        // piped value becomes first argument f(2, 40, 10) = 2 + (40 * 10) = 402
        try testing.top_number(
            \\ const f = fn(a, b, c) a + (b * c)
            \\ 2
            \\ |> f(40, 10)
        , 402);
    }

    fn compilePipe(self: *Compiler, left: *const Node, right: *const Node) InternalLowerError!void {
        switch (right.expr) {
            .ident, .field => {
                try self.compile(right, true);
                try self.compile(left, true);
                try self.emit(.call, 1);
            },
            .fn_expr => |fn_expr| {
                try self.compileFn(fn_expr.params, fn_expr.body, "<fn>", null);
                try self.compile(left, true);
                try self.emit(.call, 1);
            },
            .call => |call| {
                switch (call.callee.expr) {
                    .field => |field| {
                        try self.compile(field.object, true);
                        try self.emitConst(Data{ .atom = try self.vm.internAtom(field.name) });
                        try self.compile(left, true);
                        for (call.args) |arg| try self.compile(arg, true);
                        const argc = (call.args.len + 1) | (@as(usize, @intFromBool(call.implicit_self)) << 15);
                        try self.emit(.call_field, @intCast(argc));
                    },
                    .index => |index| {
                        try self.compile(index.object, true);
                        try self.compile(index.key, true);
                        try self.compile(left, true);
                        for (call.args) |arg| try self.compile(arg, true);
                        const argc = (call.args.len + 1) | (@as(usize, @intFromBool(call.implicit_self)) << 15);
                        try self.emit(.call_field, @intCast(argc));
                    },
                    else => {
                        try self.compile(call.callee, true);
                        try self.compile(left, true);
                        for (call.args) |arg| try self.compile(arg, true);
                        try self.emit(.call, @intCast(call.args.len + 1));
                    },
                }
            },
            else => return self.fail(.UnsupportedSyntax, right, "invalid pipe target"),
        }
    }

    // compile the comp as a complete program in isolation
    fn compileComp(self: *Compiler, expr: *Node) InternalLowerError!void {
        // implies shared runtime
        var temp_compiler = Compiler.init(self.vm, self.test_mode) catch {
            self.failure = .{
                .kind = .InvalidBytecode,
                .span = expr.span,
                .message = "comp: failed to create inner compiler",
            };
            return error.LoweringFailed;
        };
        defer temp_compiler.deinit();

        temp_compiler.compileRoot(expr) catch {
            // propagate nested compiler failure with proper span context
            if (temp_compiler.failure) |nested_failure| {
                self.failure = nested_failure;
            } else {
                self.failure = .{
                    .kind = .InvalidBytecode,
                    .span = expr.span,
                    .message = "comp: inner compilation failed",
                };
            }
            return error.LoweringFailed;
        };

        const artifact = temp_compiler.finishArtifact() catch {
            self.failure = .{
                .kind = .InvalidBytecode,
                .span = expr.span,
                .message = "comp: artifact finalization failed",
            };
            return error.LoweringFailed;
        };
        defer self.vm.runtime.alloc.free(artifact.instructions);
        defer self.vm.runtime.alloc.free(artifact.spans);

        const result = VM.module.runCompiledModuleReport(
            self.comp_vm,
            "<comp>",
            artifact.instructions,
        ) catch {
            self.failure = .{
                .kind = .InvalidBytecode,
                .span = expr.span,
                .message = "comp: execution failed to start",
            };
            return error.LoweringFailed;
        };

        if (result == .err) {
            // not sure how recursive eval will fare here
            const eval_failure = result.err;
            const error_message = self.alloc.dupe(u8, eval_failure.message) catch
                "comp: runtime error (allocation failed)";
            self.failure = .{
                .kind = .ParseError,
                .span = eval_failure.span orelse expr.span,
                .message = error_message,
                .source_name = eval_failure.source_name,
            };
            return error.LoweringFailed;
        }

        const res = self.comp_vm.mainResult();
        try self.emitConst(res);
    }

    fn compileBlock(self: *Compiler, exprs: []const *Node) InternalLowerError!void {
        if (exprs.len == 0)
            return self.emitNil();

        var pushed_scope = false;
        if (self.currentFunctionState() != null) {
            try self.pushScope();
            pushed_scope = true;
            errdefer if (pushed_scope) self.popScope();
            try self.predeclareFunctionBindings(exprs);
        }

        for (exprs, 0..) |expr, idx| {
            try self.compile(expr, true);
            if (idx + 1 < exprs.len) try self.releaseRegister();
        }

        if (pushed_scope) self.popScope();
    }

    const BindingKind = enum { global, let, con };
    fn compileBinding(self: *Compiler, binding: Binding, kind: BindingKind) InternalLowerError!void {
        // local bindings compile to local slots inside function scope
        // (all code is inside synthetic __main, so you're always in a function)
        if (binding.target.expr == .ident and kind != .global)
            return self.compileLocalBinding(binding.target.expr.ident, binding.value, kind != .con);

        if (binding.target.expr == .ident) {
            const name = binding.target.expr.ident;
            if (binding.value.expr == .fn_expr) {
                try self.compileFn(binding.value.expr.fn_expr.params, binding.value.expr.fn_expr.body, name, null);
            } else {
                try self.compile(binding.value, true);
            }
            if (ast.isDiscardName(name)) return;
            try self.duplicateRegister();
            try self.emit(if (kind != .con) .store_global else .store_global_const, try self.vm.internAtom(name));
            return;
        }

        try self.compile(binding.value, true);
        const src_idx = self.active_registers - 1;
        try self.bindPattern(binding.target, src_idx, kind);
    }

    fn compileLocalBinding(
        self: *Compiler,
        name: []const u8,
        value: *const Node,
        mutable: bool,
    ) InternalLowerError!void {
        const slot = if (value.expr == .fn_expr)
            try self.reuseOrDeclareLocal(name, mutable)
        else
            try self.declareLocal(name, mutable);
        if (value.expr == .fn_expr) {
            try self.compileFn(value.expr.fn_expr.params, value.expr.fn_expr.body, name, null);
        } else {
            try self.compile(value, true);
        }
        self.markLocalInitialized(slot);
        self.markLocalValueKind(slot, switch (value.expr) {
            .tuple => .tuple_literal,
            else => .unknown,
        });
        try self.duplicateRegister();
        try self.emit(.bind_local, slot);
    }

    fn bindPattern(
        self: *Compiler,
        pattern: *const Node,
        source_idx: usize,
        kind: BindingKind,
    ) InternalLowerError!void {
        switch (pattern.expr) {
            .ident => |name| {
                if (ast.isDiscardName(name)) return;
                _ = try self.pushRegister();
                const move_instr: Instruction = .{ .op = .move, .a = try reg(self.active_registers - 1), .b = try reg(source_idx) };
                try self.instructions.append(self.alloc, move_instr);
                try self.spans.append(self.alloc, self.active_span);
                switch (kind) {
                    .con => try self.emit(.store_global_const, try self.vm.internAtom(name)),
                    .let, .global => try self.emit(.store_global, try self.vm.internAtom(name)),
                }
            },
            .tuple_pattern => |items| {
                const mutable = kind != .con;
                for (items, 0..) |item, idx| {
                    switch (item.expr) {
                        .ident => |name| {
                            if (ast.isDiscardName(name)) continue;
                            _ = try self.pushRegister();
                            const move_instr: Instruction = .{ .op = .move, .a = try reg(self.active_registers - 1), .b = try reg(source_idx) };
                            try self.instructions.append(self.alloc, move_instr);
                            try self.spans.append(self.alloc, self.active_span);
                            try self.emit(.tuple_get_const, idx);
                            try self.emit(if (mutable) .store_global else .store_global_const, try self.vm.internAtom(name));
                        },
                        .tuple_pattern => {
                            _ = try self.pushRegister();
                            const move_instr: Instruction = .{ .op = .move, .a = try reg(self.active_registers - 1), .b = try reg(source_idx) };
                            try self.instructions.append(self.alloc, move_instr);
                            try self.spans.append(self.alloc, self.active_span);
                            try self.emit(.tuple_get_const, idx);
                            try self.bindPattern(item, self.active_registers - 1, kind);
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    fn compileTuple(self: *Compiler, items: []const *Node) InternalLowerError!void {
        for (items) |item| try self.compile(item, true);
        try self.emit(.tuple_new, @intCast(items.len));
    }

    fn currentFunctionState(self: *Compiler) ?*FunctionState {
        if (self.functions.items.len == 0) return null;
        return &self.functions.items[self.functions.items.len - 1];
    }

    fn declareLocal(self: *Compiler, name: []const u8, mutable: bool) !LocalSlot {
        var state_ptr = self.currentFunctionState();
        if (state_ptr == null) {
            var state = try FunctionState.init(self.alloc);
            self.functions.append(self.alloc, state) catch |err| {
                state.deinit(self.alloc);
                return err;
            };
            state_ptr = &self.functions.items[self.functions.items.len - 1];
        }
        const state = state_ptr.?;
        const slot = state.next_slot;
        state.next_slot += 1;
        const local: LocalVar = .{ .name = name, .slot = slot, .mutable = mutable, .initialized = false, .kind = .unknown };
        try state.locals.append(self.alloc, local);
        try state.all_locals.append(self.alloc, local);
        return slot;
    }

    fn reserveLocalSlots(self: *Compiler) void {
        if (self.currentFunctionState()) |state| {
            if (self.active_registers < state.next_slot) self.active_registers = state.next_slot;
            if (self.max_registers < state.next_slot) self.max_registers = state.next_slot;
        }
    }

    fn currentScopeStartIn(self: *const Compiler, fn_index: usize) usize {
        const state = self.functions.items[fn_index];
        if (state.scope_starts.items.len == 0) return 0;
        return state.scope_starts.items[state.scope_starts.items.len - 1];
    }

    fn pushScope(self: *Compiler) !void {
        const state = self.currentFunctionState() orelse return;
        try state.scope_starts.append(self.alloc, state.locals.items.len);
    }

    fn popScope(self: *Compiler) void {
        const state = self.currentFunctionState() orelse return;
        const start = state.scope_starts.pop() orelse return;
        state.locals.items.len = start;
    }

    fn findLocalInCurrentScope(self: *Compiler, name: []const u8) ?*LocalVar {
        const fn_index = if (self.functions.items.len == 0) return null else self.functions.items.len - 1;
        const state = &self.functions.items[fn_index];
        const start = self.currentScopeStartIn(fn_index);
        var i = state.locals.items.len;
        while (i > start) {
            i -= 1;
            if (std.mem.eql(u8, state.locals.items[i].name, name)) return &state.locals.items[i];
        }
        return null;
    }

    fn reuseOrDeclareLocal(self: *Compiler, name: []const u8, mutable: bool) !LocalSlot {
        if (self.findLocalInCurrentScope(name)) |local| {
            if (!local.initialized) return local.slot;
        }
        return self.declareLocal(name, mutable);
    }

    fn markLocalInitialized(self: *Compiler, slot: LocalSlot) void {
        const state = self.currentFunctionState() orelse return;
        var i = state.locals.items.len;
        while (i > 0) {
            i -= 1;
            if (state.locals.items[i].slot == slot) {
                state.locals.items[i].initialized = true;
                return;
            }
        }
        unreachable;
    }

    fn markLocalValueKind(self: *Compiler, slot: LocalSlot, kind: LocalValueKind) void {
        const state = self.currentFunctionState() orelse return;

        var i = state.locals.items.len;
        while (i > 0) {
            i -= 1;
            if (state.locals.items[i].slot == slot) {
                state.locals.items[i].kind = kind;
                break;
            }
        }

        i = state.all_locals.items.len;
        while (i > 0) {
            i -= 1;
            if (state.all_locals.items[i].slot == slot) {
                state.all_locals.items[i].kind = kind;
                break;
            }
        }
    }

    fn predeclareFunctionBindings(self: *Compiler, exprs: []const *Node) !void {
        for (exprs) |expr| switch (expr.expr) {
            .con_expr => |binding| {
                if (binding.target.expr != .ident or binding.value.expr != .fn_expr) continue;
                const name = binding.target.expr.ident;
                if (ast.isDiscardName(name)) continue;
                _ = try self.reuseOrDeclareLocal(name, false);
            },
            .let_expr => |binding| {
                if (binding.target.expr != .ident or binding.value.expr != .fn_expr) continue;
                const name = binding.target.expr.ident;
                if (ast.isDiscardName(name)) continue;
                _ = try self.reuseOrDeclareLocal(name, true);
            },
            else => {},
        };
    }

    fn resolveLocalVarIn(self: *const Compiler, fn_index: usize, name: []const u8) ?LocalVar {
        const locals = self.functions.items[fn_index].locals.items;
        var i = locals.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, locals[i].name, name)) return locals[i];
        }
        return null;
    }

    fn resolveLocal(self: *const Compiler, name: []const u8) ?LocalSlot {
        if (self.functions.items.len == 0) return null;
        return if (self.resolveLocalVarIn(self.functions.items.len - 1, name)) |v| v.slot else null;
    }

    fn resolveLocalVar(self: *const Compiler, name: []const u8) ?LocalVar {
        if (self.functions.items.len == 0) return null;
        return self.resolveLocalVarIn(self.functions.items.len - 1, name);
    }

    fn constTupleIndex(self: *const Compiler, index: @FieldType(Expr, "index")) ?usize {
        const key_num = switch (index.key.expr) {
            .number => |n| n,
            else => return null,
        };

        if (!std.math.isFinite(key_num) or @floor(key_num) != key_num or key_num < 0 or
            key_num > @as(f64, @floatFromInt(std.math.maxInt(usize))))
        {
            return null;
        }

        const object_is_tuple_local = switch (index.object.expr) {
            .ident => |name| blk: {
                const local = self.resolveLocalVar(name) orelse break :blk false;
                break :blk local.kind == .tuple_literal;
            },
            .tuple => true,
            else => false,
        };
        if (!object_is_tuple_local) return null;
        return @as(usize, @intFromFloat(key_num));
    }

    fn addUpvalue(self: *Compiler, fn_index: usize, spec: UpvalueSpec) !revo.UpvalueID {
        const state = &self.functions.items[fn_index];
        for (state.upvalues.items, 0..) |existing, idx| {
            if (existing.is_local == spec.is_local and existing.index == spec.index and existing.mutable == spec.mutable)
                return @intCast(idx);
        }
        const idx: revo.UpvalueID = @intCast(state.upvalues.items.len);
        try state.upvalues.append(self.alloc, spec);
        return idx;
    }

    fn resolveUpvalueRecursive(self: *Compiler, fn_index: usize, name: []const u8) !?revo.UpvalueID {
        // TODO: mark all recursive functions
        // walk outward through function states and capture when need be
        if (fn_index == 0) return null;
        const enc = fn_index - 1;
        if (self.resolveLocalVarIn(enc, name)) |local| {
            return try self.addUpvalue(fn_index, .{ .is_local = true, .index = local.slot, .mutable = local.mutable });
        }
        if (try self.resolveUpvalueRecursive(enc, name)) |slot| {
            const spec = self.functions.items[enc].upvalues.items[slot];
            return try self.addUpvalue(fn_index, .{ .is_local = false, .index = @intCast(slot), .mutable = spec.mutable });
        }
        return null;
    }

    fn resolveUpvalue(self: *Compiler, name: []const u8) !?revo.UpvalueID {
        if (self.functions.items.len == 0) return null;
        return self.resolveUpvalueRecursive(self.functions.items.len - 1, name);
    }

    //
    // function & loop compilation, shared closure setup/teardown
    //
    const FnOptions = struct {
        params: []const ast.FnParam,
        body: *const Node,
        name: []const u8,
        is_loop: bool,
        loop_sym: revo.AtomID = 0, // only used when is_loop
    };

    fn compileFn(
        self: *Compiler,
        params: []const ast.FnParam,
        body: *const Node,
        name: []const u8,
        loop_sym: ?revo.AtomID,
    ) InternalLowerError!void {
        const jump_over = try self.emitJump(.jump);
        const body_addr: ProgramCounter = @intCast(self.instructions.items.len);
        const caller_registers = self.active_registers;
        const caller_max_registers = self.max_registers;

        var state = try FunctionState.init(self.alloc);
        for (params, 0..) |param, idx| {
            const local: LocalVar = .{ .name = param.name, .slot = @intCast(idx), .mutable = true, .initialized = true };
            state.locals.append(self.alloc, local) catch |err| {
                state.deinit(self.alloc);
                return err;
            };
            state.all_locals.append(self.alloc, local) catch |err| {
                state.deinit(self.alloc);
                return err;
            };
        }
        state.next_slot = @intCast(params.len);
        self.functions.append(self.alloc, state) catch |err| {
            state.deinit(self.alloc);
            return err;
        };

        const prev_in_loop = self.in_loop_depth;
        if (loop_sym != null) {
            self.in_loop_depth += 1;
        } else {
            self.in_loop_depth = 0;
        }
        defer self.in_loop_depth = prev_in_loop;

        self.active_registers = params.len;
        self.max_registers = params.len;

        try self.compile(body, true);
        if (loop_sym) |sym| {
            try self.emitLoopRecurse(params.len, sym);
        } else {
            try self.emit(.ret, 1);
        }

        const fn_register_count = self.max_registers;
        self.active_registers = caller_registers;
        self.max_registers = caller_max_registers;

        var finished = self.functions.pop().?;
        defer finished.deinit(self.alloc);
        const const_locals = try self.collectConstLocals(finished.all_locals.items);
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
        try self.emit(.closure, proto_id);
    }

    fn collectConstLocals(self: *Compiler, locals: []const LocalVar) ![]LocalSlot {
        var out = try std.ArrayList(LocalSlot).initCapacity(self.alloc, locals.len);
        defer out.deinit(self.alloc);
        for (locals) |local| if (!local.mutable) try out.append(self.alloc, local.slot);
        return out.toOwnedSlice(self.alloc);
    }

    fn compileLoop(self: *Compiler, body: *const Node) InternalLowerError!void {
        var loop = try LoopScope.init(self);
        defer loop.deinit();

        const loop_start: ProgramCounter = @intCast(self.instructions.items.len);
        try self.compile(body, true);
        try self.releaseRegister();
        try self.emit(.jump, loop_start);
    }

    fn compileWhile(
        self: *Compiler,
        predicate: *const Node,
        body: *const Node,
    ) InternalLowerError!void {
        var loop = try LoopScope.init(self);
        defer loop.deinit();

        const loop_start: ProgramCounter = @intCast(self.instructions.items.len);
        try self.compile(predicate, true);
        const exit_jump = try self.emitJump(.jump_if_false);
        try self.compile(body, true);
        try self.releaseRegister();
        try self.emit(.jump, loop_start);

        // patch exit_jump to here (predicate is false, exit loop)
        // this is also where breaks should jump
        self.patchJump(exit_jump);
    }

    /// >> for (val, idx) in (:range, start, step, end) <expr>
    fn compileForRange(
        self: *Compiler,
        params: []const ast.FnParam,
        body: *const Node,
        start_expr: *const Node,
        step_expr: *const Node,
        end_expr: *const Node,
    ) InternalLowerError!void {
        var loop = try LoopScope.init(self);
        defer loop.deinit();

        try self.compile(start_expr, true);
        try self.compile(step_expr, true);
        try self.compile(end_expr, true);

        // state layout in consecutive registers starting at base:
        // R[base]   = current (start initially)
        // R[base+1] = step
        // R[base+2] = limit
        const base_reg = try reg(self.active_registers - 3);
        const range_init_instr: Instruction = .{
            .op = .range_init,
            .a = base_reg, // output: start of loop state
            .b = try reg(self.active_registers - 3), // input: start
            .bx = @intCast(self.active_registers - 2), // input: step (register index via bx)
            .c = try reg(self.active_registers - 1), // input: end
        };
        try self.instructions.append(self.alloc, range_init_instr);
        try self.spans.append(self.alloc, self.active_span);

        const needs_index = params.len == 2 and !ast.isDiscardName(params[1].name);

        try self.compileRangeLoopBody(params, body, base_reg, needs_index);
        // after loop body is done, only loop_result is left on stack
        self.active_registers = self.loop_result_regs.items[self.loop_result_regs.items.len - 1] + 1;
    }

    fn compileRangeLoopBody(
        self: *Compiler,
        params: []const ast.FnParam,
        body: *const Node,
        state_reg: Register, // base register holding loop state (current, step, limit)
        needs_index: bool,
    ) InternalLowerError!void {
        const loop_check: ProgramCounter = @intCast(self.instructions.items.len);

        // output registers for range_next
        const value_reg = try reg(self.active_registers); // new register for value
        const index_reg = if (needs_index) try reg(self.active_registers + 1) else 0; // new for index
        const has_next_reg = try reg(self.active_registers + @as(usize, if (needs_index) 2 else 1)); // new for has_next

        const range_next_instr: Instruction = .{
            .op = .range_next,
            .a = value_reg, // output: value
            .b = state_reg, // input: loop state base (current, step, limit)
            .c = index_reg, // output: index (or 0 if not needed)
            .bx = @intCast(has_next_reg), // output: has_next
        };
        try self.instructions.append(self.alloc, range_next_instr);
        try self.spans.append(self.alloc, self.active_span);
        self.active_registers += if (needs_index) 3 else 2; // +value, +index (if needed), +has_next

        // maybe exit when if !has_next (@ top of stack)
        const end_jump = try self.emitJump(.jump_if_false);
        // emitJump already consumes has_next from stack

        // bind first param (val) to the value register
        if (params.len >= 1 and !ast.isDiscardName(params[0].name)) {
            const temp_reg = try reg(self.active_registers);

            // duplicate value to top of stack before storing binding
            const move_val: Instruction = .{
                .op = .move,
                .a = temp_reg,
                .b = value_reg,
            };
            try self.instructions.append(self.alloc, move_val);
            try self.spans.append(self.alloc, self.active_span);
            self.active_registers += 1;

            // store to global (consumes top)
            try self.emit(.store_global, try self.vm.internAtom(params[0].name));
        }

        // bind second param (idx) to the index register
        if (params.len == 2 and !ast.isDiscardName(params[1].name)) {
            const temp_reg = try reg(self.active_registers);

            const move_idx: Instruction = .{
                .op = .move,
                .a = temp_reg,
                .b = index_reg,
            };
            try self.instructions.append(self.alloc, move_idx);
            try self.spans.append(self.alloc, self.active_span);
            self.active_registers += 1;

            try self.emit(.store_global, try self.vm.internAtom(params[1].name));
        }

        // drop value and index
        if (needs_index) try self.releaseRegister(); // idx
        try self.releaseRegister(); // val

        // body clobbers them if you dont reserve
        const loop_state_end = try reg(state_reg + 3);
        self.reserveRegisters(loop_state_end);

        try self.compile(body, true);

        // move body result to loop result
        const body_result_reg: Register = @intCast(self.active_registers - 1);
        const loop_result_reg: Register = @intCast(self.loop_result_regs.items[self.loop_result_regs.items.len - 1]);
        if (body_result_reg != loop_result_reg) {
            const move_res: Instruction = .{
                .op = .move,
                .a = loop_result_reg,
                .b = body_result_reg,
            };
            try self.instructions.append(self.alloc, move_res);
            try self.spans.append(self.alloc, self.active_span);
        }
        try self.releaseRegister(); // pop body result, loop_result remains

        // back to loop check
        try self.emit(.jump, loop_check);

        self.patchJump(end_jump);

        // clean up loop state registers and leftover value/index
        // stack at this point: loop_result, current, step, limit, value, [index]
        try self.releaseRegister(); // value
        if (needs_index) try self.releaseRegister(); // index
        try self.releaseRegister(); // limit
        try self.releaseRegister(); // step
        try self.releaseRegister(); // current
        // stack: loop_result
    }

    // should be replaced with just Operand
    const VarStorage = union(enum) {
        local: Operand,
        global: revo.AtomID,
    };

    fn compileFor(
        self: *Compiler,
        params: []const ast.FnParam,
        body: *const Node,
        iter: *const Node,
    ) InternalLowerError!void {
        if (params.len == 0 or params.len > 2) {
            return self.fail(.UnsupportedSyntax, iter, "for expects one or two binding names");
        }

        // theres a happy path
        if (iter.expr == .range_literal) {
            const range_info = iter.expr.range_literal;
            return self.compileForRange(
                params,
                body,
                range_info.start,
                range_info.step,
                range_info.end,
            );
        }

        var loop = try LoopScope.init(self);
        defer loop.deinit();

        // all code is now inside __main (synthetic top-level function), so always use locals
        const fn_state = &self.functions.items[self.functions.items.len - 1];
        const iter_slot: Operand = @intCast(fn_state.next_slot);
        fn_state.next_slot += 1;
        const iter_storage: VarStorage = .{ .local = iter_slot };

        const idx_slot: Operand = @intCast(fn_state.next_slot);
        fn_state.next_slot += 1;
        const idx_storage: VarStorage = .{ .local = idx_slot };

        // compile iter expression into iter storage
        try self.compile(iter, true);
        try self.emitStorageStore(iter_storage, false);

        // init idx to 0
        try self.emitConst(Data.new.num(0));
        try self.emitStorageStore(idx_storage, false);

        const loop_check: ProgramCounter = @intCast(self.instructions.items.len);

        // check idx < len(iter)
        try self.emitStorageLoad(idx_storage);
        try self.emit(.load_global, try self.vm.internAtom("len"));
        try self.emitStorageLoad(iter_storage);
        try self.emit(.call, 1);
        try self.emit(.lt, 0);
        const end_jump = try self.emitJump(.jump_if_false);

        // load iter value w tuple/table/__iter dispatch
        try self.emitForValueLoad(iter_storage, idx_storage);
        if (!ast.isDiscardName(params[0].name)) {
            try self.duplicateRegister();
            try self.emit(.store_global, try self.vm.internAtom(params[0].name));
        }
        try self.releaseRegister();

        if (params.len == 2) {
            try self.emitStorageLoad(idx_storage);
            if (!ast.isDiscardName(params[1].name)) {
                try self.duplicateRegister();
                try self.emit(.store_global, try self.vm.internAtom(params[1].name));
            }
            try self.releaseRegister();
        }

        if (iter_storage == .local) {
            self.reserveRegisters(@intCast(iter_storage.local + 1));
        }
        if (idx_storage == .local) {
            self.reserveRegisters(@intCast(idx_storage.local + 1));
        }

        try self.compile(body, true);

        // mv body result to loop result
        const body_result_reg: Register = @intCast(self.active_registers - 1);
        const loop_result_reg: Register = @intCast(self.loop_result_regs.items[self.loop_result_regs.items.len - 1]);
        if (body_result_reg != loop_result_reg) {
            const move_res: Instruction = .{
                .op = .move,
                .a = loop_result_reg,
                .b = body_result_reg,
            };
            try self.instructions.append(self.alloc, move_res);
            try self.spans.append(self.alloc, self.active_span);
        }
        try self.releaseRegister(); // pop body result, loop_result left

        // idx = idx + 1
        try self.emitStorageLoad(idx_storage);
        try self.emitConst(Data.new.num(1));
        try self.emit(.add, 0);
        try self.emitStorageStore(idx_storage, false);
        try self.emit(.jump, loop_check);

        // patch end_jump to here (loop exit)
        self.patchJump(end_jump);
    }

    fn emitStorageLoad(
        self: *Compiler,
        storage: VarStorage,
    ) InternalLowerError!void {
        switch (storage) {
            .local => |slot| try self.emit(.load_local, slot),
            .global => |sym| try self.emit(.load_global, sym),
        }
    }

    fn emitStorageStore(
        self: *Compiler,
        storage: VarStorage,
        is_const: bool,
    ) InternalLowerError!void {
        switch (storage) {
            .local => |slot| try self.emit(.store_local, slot),
            .global => |sym| try self.emit(if (is_const) .store_global_const else .store_global, sym),
        }
    }

    /// TODO: move the whole thing into vm
    fn emitForValueLoad(
        self: *Compiler,
        iter_storage: VarStorage,
        idx_storage: VarStorage,
    ) InternalLowerError!void {
        const base_depth = self.active_registers;
        const tuple_check = try self.emitForTypeCheck(iter_storage, "tuple");
        try self.emitStorageLoad(iter_storage);
        try self.emitStorageLoad(idx_storage);
        try self.emit(.tuple_get, 0);
        const done = try self.emitJump(.jump);

        self.active_registers = base_depth;
        self.patchJump(tuple_check);
        const string_check = try self.emitForTypeCheck(iter_storage, "string");
        try self.emitStorageLoad(iter_storage);
        try self.emitStorageLoad(idx_storage);
        try self.emit(.table_get, 0);
        const done2 = try self.emitJump(.jump);

        self.active_registers = base_depth;
        self.patchJump(string_check);
        const table_check = try self.emitForTypeCheck(iter_storage, "table");
        try self.emitStorageLoad(iter_storage);
        try self.emitStorageLoad(idx_storage);
        try self.emit(.table_get, 0);
        const done3 = try self.emitJump(.jump);

        self.active_registers = base_depth;
        self.patchJump(table_check);
        try self.emitStorageLoad(iter_storage);
        try self.emitConst(Data{ .atom = try self.vm.internAtom("__iter") });
        try self.emitStorageLoad(idx_storage);
        try self.emit(.call_field, 1);

        self.patchJump(done);
        self.patchJump(done2);
        self.patchJump(done3);
        self.active_registers = base_depth + 1;
    }

    fn emitForTypeCheck(
        self: *Compiler,
        iter_storage: VarStorage,
        type_name: []const u8,
    ) InternalLowerError!usize {
        try self.emit(.load_global, try self.vm.internAtom("type"));
        try self.emitStorageLoad(iter_storage);
        try self.emit(.call, 1);
        const tname = try self.vm.internAtom(type_name);
        try self.emitConst(Data.new.atom(tname));
        try self.emit(.eq, 0);
        return self.emitJump(.jump_if_false);
    }

    fn emitLoopRecurse(
        self: *Compiler,
        param_count: usize,
        loop_sym: revo.AtomID,
    ) InternalLowerError!void {
        const result_name = try self.nextTemp("__loop_result");
        const result_sym = try self.vm.internAtom(result_name);

        if (param_count > 0) {
            try self.emit(.store_global, result_sym);
        } else {
            try self.releaseRegister();
        }
        try self.emit(.load_global, loop_sym);

        if (param_count == 1) {
            try self.emit(.load_global, result_sym);
        } else if (param_count > 1) {
            for (0..param_count) |idx| {
                try self.emit(.load_global, result_sym);
                try self.emit(.tuple_get_const, idx);
            }
        }
        try self.emit(.call, @intCast(param_count));
        try self.emit(.ret, 1);
    }

    test "match guards" {
        try lang.testing.top_number(
            \\ match 2
            \\ | x when x <= 2 55
            \\ | x x
        , 55);
    }

    test "fibonacci w/ match guards" {
        try lang.testing.top_number(
            \\ fn frec(n) match n
            \\ | x when x < 2 x
            \\ | x frec(x - 1) + frec(x - 2)
            \\
            \\ frec(10)
        , 55);
    }

    test "closure capture nested" {
        try lang.testing.top_number(
            \\ fn outer() do
            \\   const x = 41
            \\   fn inner() do
            \\     x + 1
            \\   end
            \\   inner()
            \\ end
            \\
            \\ outer()
        , 42);
    }

    test "closure returned capture" {
        try lang.testing.top_number(
            \\ fn make(i) do
            \\   fn inner() do i end
            \\   inner
            \\ end
            \\ const f = make(7)
            \\ f()
        , 7);
    }

    test "closure in loop captures current" {
        try lang.testing.top_number(
            \\ let sum = 0
            \\ for i in 0..3 do
            \\   const f = fn() do i end
            \\   sum += f()
            \\ end
            \\
            \\ sum
        , 3);
    }

    fn compileMatch(
        self: *Compiler,
        subject: *const Node,
        arms: []const ast.MatchArm,
    ) InternalLowerError!void {
        const state = self.currentFunctionState() orelse
            return self.fail(.UnsupportedSyntax, subject, "match requires function scope");

        // to restore after match
        // TODO: this also means you cant define globals from within matches
        //       i am genuinely surprised this doesnt break defining globals from arms
        //
        const saved_next_slot = state.next_slot;

        // single scope for whole match's subject
        try self.pushScope();
        errdefer self.popScope();

        const subject_name = try self.nextTemp("__match_subject");
        const subject_slot = try self.declareLocal(subject_name, false);
        try self.compile(subject, true);
        self.markLocalInitialized(subject_slot);
        try self.emit(.bind_local, subject_slot);
        self.reserveLocalSlots();

        const arm_base_registers = self.active_registers;
        const subject_storage: VarStorage = .{ .local = subject_slot };

        var end_jumps = try std.ArrayList(usize).initCapacity(self.alloc, arms.len);
        defer end_jumps.deinit(self.alloc);

        for (arms) |arm| {
            self.active_registers = arm_base_registers;

            // each arm gets its own lex scope for pattern variables
            try self.pushScope();
            errdefer self.popScope();

            const matcher_expr: ?*const Node = switch (arm.matchers[0]) {
                .wildcard => null,
                .expr => |e| e,
            };

            const fail_jumps = try self.compilePatternChecks(subject_storage, matcher_expr);
            var fail_list = try std.ArrayList(usize).initCapacity(self.alloc, fail_jumps.len + 1);
            defer fail_list.deinit(self.alloc);
            try fail_list.appendSlice(self.alloc, fail_jumps);
            self.alloc.free(fail_jumps);

            if (matcher_expr) |me| try self.bindMatchPattern(me, subject_storage);

            if (arm.guard) |guard| {
                try self.compile(guard, true);
                const guard_jump = try self.emitJump(.jump_if_false);
                try fail_list.append(self.alloc, guard_jump);
            }

            try self.compile(arm.then, true);

            // move arm result to canonical result location
            const arm_result_reg: Register = @intCast(self.active_registers - 1);
            if (arm_result_reg != arm_base_registers) {
                const move_instr: Instruction = .{
                    .op = .move,
                    .a = try reg(arm_base_registers),
                    .b = try reg(arm_result_reg),
                };
                try self.instructions.append(self.alloc, move_instr);
                try self.spans.append(self.alloc, self.active_span);
            }
            try self.releaseRegister(); // pop arm result
            self.active_registers = arm_base_registers + 1; // result is now at arm_base_registers

            const end_jump = try self.emitJump(.jump);
            try end_jumps.append(self.alloc, end_jump);

            // needs to happen before patching jumps so that pattern vars go out of scope
            self.popScope();

            const next_arm = self.instructions.items.len;
            for (fail_list.items) |jump_idx| {
                self.patchJumpToLabel(jump_idx, next_arm);
            }
        }
        self.popScope();

        // so that neighbouring code gets fresh slot numbers
        state.next_slot = saved_next_slot;

        // default case & success patches
        self.active_registers = arm_base_registers;
        try self.emitNil();
        for (end_jumps.items) |jump_idx| {
            self.patchJump(jump_idx);
        }

        self.active_registers = arm_base_registers + 1;
    }

    fn patchJumpToLabel(self: *Compiler, jump_idx: usize, target: usize) void {
        self.instructions.items[jump_idx].bx = @intCast(target);
    }

    fn reserveRegisters(self: *Compiler, min_register: Register) void {
        const min_slot: LocalSlot = @intCast(min_register);
        if (self.currentFunctionState()) |state| {
            if (state.next_slot < min_slot) state.next_slot = min_slot;
        }
        if (self.active_registers < min_slot) self.active_registers = min_slot;
        if (self.max_registers < min_slot) self.max_registers = min_slot;
    }

    fn bindMatchPattern(
        self: *Compiler,
        matcher: *const Node,
        subject: VarStorage,
    ) InternalLowerError!void {
        switch (matcher.expr) {
            .ident => |name| {
                if (ast.isDiscardName(name)) return;
                try self.emitStorageLoad(subject);
                const slot = try self.declareLocal(name, true);
                self.markLocalInitialized(slot);
                try self.emit(.bind_local, slot);
                self.reserveLocalSlots();
            },
            .tuple_pattern => try self.bindMatchTuplePattern(matcher, subject),
            else => {},
        }
    }

    fn bindMatchTuplePattern(
        self: *Compiler,
        pattern: *const Node,
        source: VarStorage,
    ) InternalLowerError!void {
        switch (pattern.expr) {
            .ident => |name| {
                if (ast.isDiscardName(name)) return;
                try self.emitStorageLoad(source);
                const slot = try self.declareLocal(name, true);
                self.markLocalInitialized(slot);
                try self.emit(.bind_local, slot);
                self.reserveLocalSlots();
            },
            .tuple_pattern => |items| {
                for (items, 0..) |item, idx| {
                    switch (item.expr) {
                        .ident => |name| {
                            if (ast.isDiscardName(name)) continue;
                            try self.emitStorageLoad(source);
                            try self.emit(.tuple_get_const, idx);
                            const slot = try self.declareLocal(name, true);
                            self.markLocalInitialized(slot);
                            try self.emit(.bind_local, slot);
                            self.reserveLocalSlots();
                        },
                        .tuple_pattern => {
                            try self.emitStorageLoad(source);
                            try self.emit(.tuple_get_const, idx);
                            const nested_name = try self.nextTemp("__bind");
                            const nested_slot = try self.declareLocal(nested_name, false);
                            self.markLocalInitialized(nested_slot);
                            try self.emit(.bind_local, nested_slot);
                            self.reserveLocalSlots();
                            try self.bindMatchTuplePattern(item, .{ .local = nested_slot });
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    fn compilePatternChecks(
        self: *Compiler,
        subject: VarStorage,
        matcher: ?*const Node,
    ) InternalLowerError![]usize {
        var fail_jumps = try std.ArrayList(usize).initCapacity(self.alloc, 4);
        const expr = matcher orelse return fail_jumps.toOwnedSlice(self.alloc);

        switch (expr.expr) {
            .ident => {}, // wildcard in matcher position
            .tuple_pattern => |items| {
                // check tuple type
                try self.emit(.load_global, try self.vm.internAtom("type"));
                try self.emitStorageLoad(subject);
                try self.emit(.call, 1);
                try self.emitConst(Data.new.atom(try self.vm.internAtom("tuple")));
                try self.emit(.eq, 0);
                try fail_jumps.append(self.alloc, try self.emitJump(.jump_if_false));

                // check exact tuple length
                try self.emit(.load_global, try self.vm.internAtom("len"));
                try self.emitStorageLoad(subject);
                try self.emit(.call, 1);
                try self.emitConst(Data.new.num(items.len));
                try self.emit(.eq, 0);
                try fail_jumps.append(self.alloc, try self.emitJump(.jump_if_false));

                for (items, 0..) |item, idx| {
                    switch (item.expr) {
                        .ident => |name| if (ast.isDiscardName(name)) continue,
                        else => {},
                    }
                    const depth_before = self.active_registers;
                    try self.emitStorageLoad(subject);
                    try self.emit(.tuple_get_const, idx);
                    const nested_name = try self.nextTemp("__match");
                    const nested_slot = try self.declareLocal(nested_name, false);
                    self.markLocalInitialized(nested_slot);
                    try self.emit(.bind_local, nested_slot);
                    self.reserveLocalSlots();
                    const nested_fails = try self.compilePatternChecks(.{ .local = nested_slot }, item);
                    for (nested_fails) |jump_idx| try fail_jumps.append(self.alloc, jump_idx);
                    self.alloc.free(nested_fails);
                    self.active_registers = depth_before;
                }
            },
            else => {
                try self.emitStorageLoad(subject);
                try self.compile(expr, true);
                try self.emit(.eq, 0);
                try fail_jumps.append(self.alloc, try self.emitJump(.jump_if_false));
            },
        }
        return fail_jumps.toOwnedSlice(self.alloc);
    }

    fn compileAssign(
        self: *Compiler,
        target: *const Node,
        value: *const Node,
    ) InternalLowerError!void {
        if (target.expr == .tuple_pattern) {
            try self.compile(value, true);
            const src_idx = self.active_registers - 1;
            try self.bindPattern(target, src_idx, .let);
            return;
        }
        try self.compileAssignSimple(target, value);
    }

    fn compileAssignSimple(
        self: *Compiler,
        target: *const Node,
        value: *const Node,
    ) InternalLowerError!void {
        switch (target.expr) {
            .ident => |name| {
                try self.compile(value, true);
                try self.duplicateRegister();
                if (self.resolveLocal(name)) |slot| {
                    try self.emit(.store_local, slot);
                    self.markLocalValueKind(slot, .unknown);
                } else if (try self.resolveUpvalue(name)) |slot| {
                    try self.emit(.store_upval, slot);
                } else {
                    return self.fail(.InvalidAssignmentTarget, target, "assignment target is not declared");
                }
            },
            .field => |field| {
                try self.compile(field.object, true);
                try self.compileAssignIntoTableAtom(try self.vm.internAtom(field.name), value);
            },
            .index => |index| {
                try self.compile(index.object, true);
                if (index.key.expr == .hash) {
                    try self.compileAssignIntoTableAtom(try self.vm.internAtom(index.key.expr.hash), value);
                } else {
                    try self.compile(index.key, true);
                    try self.compileAssignIntoTable(value);
                }
            },
            else => return self.fail(.InvalidAssignmentTarget, target, "invalid assignment target"),
        }
    }

    // shared tail of field and index assignment: object/key value already loaded,
    // compile value, emit table_set, release result register
    fn compileAssignIntoTable(self: *Compiler, value: *const Node) InternalLowerError!void {
        try self.compile(value, true);
        try self.emit(.table_set, 0);
        try self.releaseRegister();
    }

    fn compileAssignIntoTableAtom(
        self: *Compiler,
        key_atom: revo.AtomID,
        value: *const Node,
    ) InternalLowerError!void {
        try self.compile(value, true);
        try self.emit(.table_set_atom, key_atom);
        try self.releaseRegister();
    }

    fn compileStruct(
        self: *Compiler,
        expr: *const Node,
        name: []const u8,
        items: []const StructItem,
    ) InternalLowerError!void {
        // always in synth toplevel __main, so always declare local
        const descriptor_slot = try self.reuseOrDeclareLocal(name, false);

        const fields_id = try self.compileStructFieldTable(items, .fields);
        const defaults_id = try self.compileStructFieldTable(items, .defaults);
        const types_id = try self.compileStructFieldTable(items, .types);

        const fields_const = try self.vm.addConstant(Data.new.table(fields_id));
        const defaults_const = try self.vm.addConstant(Data.new.table(defaults_id));
        const types_const = try self.vm.addConstant(Data.new.table(types_id));
        const name_const = try self.vm.addConstant(try self.vm.ownDataString(name));

        try self.emit(.table_new, 0);
        try self.duplicateRegister();
        const descriptor_name = try self.nextTemp("__struct_desc");
        const descriptor_sym = try self.vm.internAtom(descriptor_name);
        try self.emit(.store_global, descriptor_sym);
        try self.releaseRegister();

        // set all desc fields
        inline for (&[_]struct { key: []const u8, const_id: usize }{
            .{ .key = "__name", .const_id = name_const },
            .{ .key = "__fields", .const_id = fields_const },
            .{ .key = "__defaults", .const_id = defaults_const },
            .{ .key = "__types", .const_id = types_const },
        }) |entry| {
            try self.emit(.load_global, descriptor_sym);
            try self.emitConst(Data.new.atom(try self.vm.internAtom(entry.key)));
            try self.emitLoadConst(entry.const_id);
            try self.emit(.table_set, 0);
            try self.releaseRegister();
        }

        for (items) |item| switch (item) {
            .field => {},
            .binding => |binding| {
                if (binding.target.expr != .ident)
                    return self.fail(.UnsupportedSyntax, expr, "assignment target must be named");
                const key_atom = try self.vm.internAtom(binding.target.expr.ident);
                try self.emit(.load_global, descriptor_sym);
                try self.emitConst(Data.new.atom(key_atom));
                if (binding.value.expr == .fn_expr) {
                    try self.compileFn(binding.value.expr.fn_expr.params, binding.value.expr.fn_expr.body, binding.target.expr.ident, null);
                } else {
                    try self.compile(binding.value, true);
                }
                try self.emit(.table_set, 0);
                try self.releaseRegister();
            },
        };

        // __call mm for the desc bound to struct name
        try self.emit(.load_global, descriptor_sym);
        self.markLocalInitialized(descriptor_slot);
        try self.duplicateRegister();
        try self.emit(.bind_local, descriptor_slot);
    }

    const StructFieldTableKind = enum {
        fields,
        defaults,
        types,
    };

    const StructDescriptorValue = union(enum) {
        ident: []const u8,
        string: []const u8,
        table: revo.TableID,
    };

    fn compileStructFieldTable(
        self: *Compiler,
        items: []const StructItem,
        kind: StructFieldTableKind,
    ) InternalLowerError!revo.TableID {
        const table_id = try self.vm.tables.create();
        const table = self.vm.tables.get(table_id) catch return InternalLowerError.InvalidBytecode;

        for (items) |item| switch (item) {
            .binding => {},
            .field => |field| {
                const key = Data.new.atom(try self.vm.internAtom(field.name));
                switch (kind) {
                    // TODO: put types here
                    .fields => table.putRaw(key, revo.core_atoms.data(.true)) catch return InternalLowerError.InvalidAssignmentTarget,
                    .defaults => {
                        if (field.default_value) |value| table.putRaw(key, try self.constValueFromNode(value)) catch
                            return InternalLowerError.InvalidAssignmentTarget;
                    },
                    .types => {
                        if (field.type_name) |type_name| table.putRaw(key, Data.new.atom(try self.vm.internAtom(type_name))) catch
                            return InternalLowerError.InvalidAssignmentTarget;
                    },
                }
            },
        };

        return table_id;
    }

    fn compileStructDescriptorKey(
        self: *Compiler,
        descriptor_sym: revo.AtomID,
        key_name: []const u8,
        value: StructDescriptorValue,
    ) InternalLowerError!void {
        try self.emit(.load_global, descriptor_sym);
        try self.emitConst(Data.new.atom(try self.vm.internAtom(key_name)));
        switch (value) {
            .ident => |ident| try self.emit(.load_global, try self.vm.internAtom(ident)),
            .string => |str| try self.emitConst(try self.vm.ownDataString(str)),
            .table => |table_id| try self.emitConst(Data.new.table(table_id)),
        }
        try self.emit(.table_set, 0);
        try self.releaseRegister();
    }

    fn constValueFromNode(self: *Compiler, node: *const Node) InternalLowerError!Data {
        return switch (node.expr) {
            .number => |n| blk: {
                if (std.math.isFinite(n) and @floor(n) == n and
                    n >= @as(f64, @floatFromInt(std.math.minInt(i64))) and
                    n <= @as(f64, @floatFromInt(std.math.maxInt(i64))))
                {
                    break :blk Data.new.num(@as(i64, @intFromFloat(n)));
                }
                break :blk Data.new.num(n);
            },
            .string, .multiline_string => |s| try self.vm.ownDataString(s),
            .hash => |s| Data.new.atom(try self.vm.internAtom(s)),
            else => return self.fail(.UnsupportedSyntax, node, "struct defaults must be constant values"),
        };
    }

    //
    // control flow
    //
    fn compileIf(
        self: *Compiler,
        condition: *const Node,
        then_expr: *const Node,
        else_expr: ?*Node,
    ) InternalLowerError!void {
        try self.compile(condition, true);
        const else_jump = try self.emitJump(.jump_if_false);
        const branch_base_registers = self.active_registers;
        try self.compile(then_expr, true);
        const then_registers = self.active_registers;
        const end_jump = try self.emitJump(.jump);
        self.patchJump(else_jump);
        self.active_registers = branch_base_registers;
        if (else_expr) |branch| try self.compile(branch, true) else try self.emitNil();
        if (then_registers != self.active_registers) return error.InvalidBytecode;
        self.patchJump(end_jump);
    }

    fn compileAnd(
        self: *Compiler,
        left: *const Node,
        right: *const Node,
    ) InternalLowerError!void {
        try self.compile(left, true);
        try self.duplicateRegister();
        const short = try self.emitJump(.jump_if_false);
        try self.releaseRegister();
        try self.compile(right, true);
        const end = try self.emitJump(.jump);
        self.patchJump(short);
        self.patchJump(end);
    }

    fn compileOr(self: *Compiler, left: *const Node, right: *const Node) InternalLowerError!void {
        try self.compile(left, true);
        try self.duplicateRegister();
        const short = try self.emitJump(.jump_if_true);
        try self.releaseRegister();
        try self.compile(right, true);
        const end = try self.emitJump(.jump);
        self.patchJump(short);
        self.patchJump(end);
    }

    //
    // table & tuple
    //
    fn compileTable(self: *Compiler, entries: []const ast.TableEntry) InternalLowerError!void {
        try self.emit(.table_new, 0);
        var array_index: i64 = 0;
        for (entries) |entry| {
            try self.duplicateRegister();
            if (entry.key) |key| {
                if (entry.computed) {
                    try self.compile(key, true);
                } else switch (key.expr) {
                    .ident => |name| try self.emitConst(Data{ .atom = try self.vm.internAtom(name) }),
                    else => try self.compile(key, true),
                }
            } else {
                try self.emitConst(Data.new.num(array_index));
                array_index += 1;
            }
            try self.compile(entry.value, true);
            try self.emit(.table_set, 0);
            try self.releaseRegister();
        }
    }

    //
    // emit helpers
    //
    fn emitConst(self: *Compiler, value: Data) InternalLowerError!void {
        if (value == .number and value.number >= 0 and value.number <= 65535 and @trunc(value.number) == value.number) {
            return self.emitSmallInt(@intFromFloat(value.number));
        }
        const idx = try self.vm.addConstant(value);
        const dst = try self.pushRegister();
        const instr: Instruction = .{
            .op = .load_const,
            .a = dst,
            .bx = idx,
        };
        try self.instructions.append(self.alloc, instr);
        try self.spans.append(self.alloc, self.active_span);
    }

    fn emitMove(self: *Compiler, dst: LocalSlot, src: LocalSlot) InternalLowerError!void {
        const instr: Instruction = .{
            .op = .move,
            .a = @intCast(dst),
            .b = @intCast(src),
        };
        try self.instructions.append(self.alloc, instr);
        try self.spans.append(self.alloc, self.active_span);
    }

    fn emitLoadConst(self: *Compiler, idx: revo.ConstantID) InternalLowerError!void {
        const dst = try self.pushRegister();
        const instr: Instruction = .{
            .op = .load_const,
            .a = dst,
            .bx = idx,
        };
        try self.instructions.append(self.alloc, instr);
        try self.spans.append(self.alloc, self.active_span);
    }

    fn emitNil(self: *Compiler) InternalLowerError!void {
        const dst = try self.pushRegister();
        const instr: Instruction = .{
            .op = .load_nil,
            .a = dst,
        };
        try self.instructions.append(self.alloc, instr);
        try self.spans.append(self.alloc, self.active_span);
    }

    fn emitSmallInt(self: *Compiler, val: usize) InternalLowerError!void {
        const dst = try self.pushRegister();
        const instr: Instruction = .{
            .op = .load_small_int,
            .a = dst,
            .bx = val,
        };
        try self.instructions.append(self.alloc, instr);
        try self.spans.append(self.alloc, self.active_span);
    }

    fn duplicateRegister(self: *Compiler) InternalLowerError!void {
        if (self.active_registers == 0) return error.InvalidBytecode;
        const dst = try reg(self.active_registers);
        const src = try reg(self.active_registers - 1);
        const instr: Instruction = .{
            .op = .move,
            .a = dst,
            .b = src,
        };
        try self.instructions.append(self.alloc, instr);
        try self.spans.append(self.alloc, self.active_span);
        self.active_registers += 1;
        if (self.active_registers > self.max_registers)
            self.max_registers = self.active_registers;
    }

    fn releaseRegister(self: *Compiler) InternalLowerError!void {
        if (self.active_registers == 0) return error.InvalidBytecode;
        self.popRegister();
    }

    fn emit(self: *Compiler, op: Opcode, operand: Operand) !void {
        var instr: Instruction = .{ .op = .halt };
        var depth = self.active_registers;

        switch (op) {
            .add,
            .sub,
            .mul,
            .div,
            .mod,
            .eq,
            .neq,
            .lt,
            .gt,
            .lte,
            .gte,
            .@"and",
            .@"or",
            => {
                if (depth < 2) return error.InvalidBytecode;
                instr = .{ .op = op, .a = try reg(depth - 2), .b = try reg(depth - 2), .c = try reg(depth - 1) };
                depth -= 1;
            },
            .negate, .not => {
                if (depth == 0) return error.InvalidBytecode;
                instr = .{ .op = op, .a = try reg(depth - 1), .b = try reg(depth - 1) };
            },

            .halt => {
                instr = .{ .op = .halt, .a = if (depth == 0) 0 else try reg(depth - 1) };
            },
            .jump => {
                instr = .{ .op = .jump, .bx = operand };
            },
            .jump_if_false, .jump_if_true => {
                if (depth == 0) return error.InvalidBytecode;
                instr = .{ .op = op, .a = try reg(depth - 1), .bx = operand };
                depth -= 1;
            },

            .store_global, .store_global_const => {
                if (depth == 0) return error.InvalidBytecode;
                instr = .{ .op = if (op == .store_global_const) .store_global_const else .store_global, .a = try reg(depth - 1), .bx = operand };
                depth -= 1;
            },
            .load_global => {
                instr = .{ .op = .load_global, .a = try reg(depth), .bx = operand };
                depth += 1;
            },
            .load_local => {
                instr = .{ .op = .load_local, .a = try reg(depth), .b = try reg(operand) };
                depth += 1;
            },
            .bind_local, .store_local => {
                if (depth == 0) return error.InvalidBytecode;
                instr = .{ .op = if (op == .bind_local) .bind_local else .store_local, .a = try reg(operand), .b = try reg(depth - 1) };
                depth -= 1;
            },

            .closure => {
                instr = .{ .op = .closure, .a = try reg(depth), .bx = operand };
                depth += 1;
            },
            .load_upval => {
                instr = .{ .op = .load_upval, .a = try reg(depth), .bx = operand };
                depth += 1;
            },
            .store_upval => {
                if (depth == 0) return error.InvalidBytecode;
                instr = .{ .op = .store_upval, .a = try reg(depth - 1), .bx = operand };
                depth -= 1;
            },

            .tuple_new => {
                if (depth < operand) return error.InvalidBytecode;
                const first = depth - operand;
                instr = .{ .op = .tuple_new, .a = try reg(first), .b = try reg(first), .bx = operand };
                depth = first + 1;
            },
            .tuple_get => {
                if (depth < 2) return error.InvalidBytecode;
                instr = .{ .op = .tuple_get, .a = try reg(depth - 2), .b = try reg(depth - 2), .c = try reg(depth - 1) };
                depth -= 1;
            },
            .table_new => {
                instr = .{ .op = .table_new, .a = try reg(depth) };
                depth += 1;
            },
            .table_set => {
                if (depth < 3) return error.InvalidBytecode;
                instr = .{ .op = .table_set, .a = try reg(depth - 3), .b = try reg(depth - 2), .c = try reg(depth - 1) };
                depth -= 2;
            },
            .table_get => {
                if (depth < 2) return error.InvalidBytecode;
                instr = .{ .op = .table_get, .a = try reg(depth - 2), .b = try reg(depth - 2), .c = try reg(depth - 1) };
                depth -= 1;
            },
            .table_set_atom => {
                if (depth < 2) return error.InvalidBytecode;
                instr = .{ .op = .table_set_atom, .a = try reg(depth - 2), .c = try reg(depth - 1), .bx = operand };
                depth -= 1;
            },
            .table_get_atom => {
                if (depth < 1) return error.InvalidBytecode;
                instr = .{ .op = .table_get_atom, .a = try reg(depth - 1), .b = try reg(depth - 1), .bx = operand };
            },
            .tuple_get_const => {
                if (depth < 1) return error.InvalidBytecode;
                instr = .{ .op = .tuple_get_const, .a = try reg(depth - 1), .b = try reg(depth - 1), .bx = operand };
            },
            .call => {
                if (depth < operand + 1) return error.InvalidBytecode;
                const base = depth - operand - 1;
                instr = .{ .op = .call, .a = try reg(base), .b = try reg(operand), .c = try reg(base) };
                depth = base + 1;
            },
            .call_field => {
                const is_colon = (operand & (1 << 15)) != 0;
                const explicit_argc = operand & ~@as(Operand, 1 << 15);
                _ = is_colon;
                const needed = explicit_argc + 2;
                if (depth < needed) return error.InvalidBytecode;
                const base = depth - needed;
                instr = .{
                    .op = .call_field,
                    .a = try reg(base),
                    .b = try reg(operand),
                    .c = try reg(base),
                };
                depth = base + 1;
            },
            .ret => {
                instr = .{ .op = .ret, .a = if (depth == 0) 0 else try reg(depth - 1) };
            },
            .spawn => {
                if (depth < operand + 1) return error.InvalidBytecode;
                const base = depth - operand - 1;
                instr = .{ .op = .spawn, .a = try reg(base), .b = try reg(operand), .c = try reg(base) };
                depth = base + 1;
            },
            .join => {
                if (depth == 0) return error.InvalidBytecode;
                instr = .{ .op = .join, .a = try reg(depth - 1) };
            },
            .yield => {
                instr = .{ .op = .yield };
            },
            .move, .load_const => unreachable,
            .load_nil => {
                instr = .{ .op = .load_nil, .a = try reg(depth) };
                depth += 1;
            },
            .load_small_int => {
                instr = .{ .op = .load_small_int, .a = try reg(depth) };
                depth += 1;
            },
            .range_init => {
                if (depth < 3) return error.InvalidBytecode;
                instr = .{ .op = .range_init, .a = try reg(depth - 3), .b = try reg(depth - 3), .c = try reg(depth - 1) };
            },
            .range_next => {
                if (depth < 3) return error.InvalidBytecode;
                instr = .{ .op = .range_next, .a = try reg(depth), .b = try reg(depth - 3), .c = try reg(depth + 1) };
                depth += 3;
            },
            .range_for => {
                if (depth < 3) return error.InvalidBytecode;
                instr = .{ .op = .range_for, .a = try reg(depth - 3), .b = try reg(depth - 2), .c = try reg(depth - 1) };
            },
            .unwrap_result => {
                // if TOS is (:err, ...) and bx=0, return early
                // if TOS is (:ok, x), extract x; otherwise no-op
                if (depth == 0) return error.InvalidBytecode;
                instr = .{ .op = .unwrap_result, .a = try reg(depth - 1), .bx = operand };
            },
            .jump_if_not_nil_and_not_err => {
                // if tos is not nil and not (:err, ...), jump
                if (depth == 0) return error.InvalidBytecode;
                instr = .{ .op = .jump_if_not_nil_and_not_err, .a = try reg(depth - 1), .bx = operand };
                depth -= 1;
            },
        }

        try self.instructions.append(self.alloc, instr);
        try self.spans.append(self.alloc, self.active_span);

        self.active_registers = depth;
        if (depth > self.max_registers) self.max_registers = depth;
    }

    fn emitJump(self: *Compiler, op: Opcode) !usize {
        const index = self.instructions.items.len;
        try self.emit(op, 0);
        return index;
    }

    fn patchJump(self: *Compiler, index: usize) void {
        self.instructions.items[index].bx = @intCast(self.instructions.items.len);
    }

    fn nextTemp(self: *Compiler, comptime prefix: []const u8) ![]const u8 {
        // i need to have my string interpolation like this look at him
        const name = try std.fmt.allocPrint(self.alloc, "{s}_{d}", .{ prefix, self.temp_counter });
        try self.temp_names.append(self.alloc, name);
        self.temp_counter += 1;
        return name;
    }

    fn maybeFoldConstBinary(self: *Compiler, b: anytype) !bool {
        const left: Expr = b.left.expr;
        const right: Expr = b.right.expr;

        if (left == .number and right == .number) {
            const lhs = left.number;
            const rhs = right.number;

            const maybe_fold = fops.getFoldFn(b.op);
            if (maybe_fold == null) return false;

            const result = maybe_fold.?(lhs, rhs) orelse return false;

            if (!std.math.isFinite(result)) return false;
            if (@floor(result) != result) return false;
            if (result < @as(f64, @floatFromInt(std.math.minInt(i64))) or
                result > @as(f64, @floatFromInt(std.math.maxInt(i64))))
                return false;

            try self.emitConst(Data.new.num(@as(i64, @intFromFloat(result))));
            return true;
        } else if (left == .string and right == .string) {
            if (b.op != .add) return false;

            const result = try std.mem.concat(self.alloc, u8, &[2][]const u8{ left.string, right.string });
            defer self.alloc.free(result);
            const data = try self.vm.ownDataString(result);
            try self.emitConst(data);
            return true;
        }
        return false;
    }

    fn fail(
        self: *Compiler,
        kind: LowerErrorKind,
        expr: *const Node,
        message: []const u8,
    ) error{LoweringFailed} {
        self.failure = .{ .kind = kind, .span = expr.span, .message = message };
        return error.LoweringFailed;
    }
};

fn reg(n: usize) !Register {
    if (n > std.math.maxInt(Register)) return error.InvalidBytecode;
    return @intCast(n);
}

const fops = struct {
    const FoldFn = *const fn (f64, f64) ?f64;

    pub fn add(lhs: f64, rhs: f64) ?f64 {
        return lhs + rhs;
    }

    pub fn sub(lhs: f64, rhs: f64) ?f64 {
        return lhs - rhs;
    }

    pub fn mul(lhs: f64, rhs: f64) ?f64 {
        return lhs * rhs;
    }

    pub fn div(lhs: f64, rhs: f64) ?f64 {
        if (rhs == 0) return null;
        return lhs / rhs;
    }

    pub fn mod_op(lhs: f64, rhs: f64) ?f64 {
        if (rhs == 0) return null;
        return @mod(lhs, rhs);
    }

    // full comptime dw
    pub const fold_table = blk: {
        var table = std.EnumArray(ast.BinOp, ?FoldFn).initFill(null);

        const info = @typeInfo(@This()).@"struct";
        for (info.fields) |field| {
            if (field.type == FoldFn) {
                const tag_name = if (std.mem.eql(u8, field.name, "mod_op")) "mod" else field.name;

                for (std.enums.values(ast.BinOp)) |tag|
                    if (std.mem.eql(u8, @tagName(tag), tag_name)) {
                        table.set(tag, @field(@This(), field.name));
                        break;
                    };
            }
        }
        break :blk table;
    };

    pub fn getFoldFn(op: ast.BinOp) ?FoldFn {
        return fold_table.get(op);
    }
};
