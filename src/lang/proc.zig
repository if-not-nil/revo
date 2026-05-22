const std = @import("std");

const revo = @import("revo");
const lang = @import("./root.zig");
const Data = revo.Data;

const ast = lang.ast;
const Expr = ast.Expr;
const Node = ast.Node;
const Span = ast.Span;
const compiler = lang.compiler;

pub const ExpandError = error{
    InvalidProcReturn,
    ProcCompileFailed,
    ProcEvalFailed,
    RecursiveProcMacro,
    UnsupportedProcValue,
} || std.mem.Allocator.Error;

pub fn register(vm: *revo.VM) !void {
    const id = try vm.functions.create(.{ .native = revo.std_lib.define(&[_]revo.std_lib.TypeSpec{.table}, iter) });
    try vm.globals.put(try vm.internAtom("__proc_iter"), .{ .function = id });
    const apply_id = try vm.functions.create(.{ .native = revo.std_lib.define(&[_]revo.std_lib.TypeSpec{ .function, .table }, procApply) });
    try vm.globals.put(try vm.internAtom("__proc_apply"), .{ .function = apply_id });
}

pub fn expandExpr(vm: *revo.VM, allocator: std.mem.Allocator, expr: *Node) ExpandError!*Node {
    var env = ProcEnv.init(allocator);
    defer env.deinit();
    return expandInEnv(vm, allocator, expr, &env, .expand);
}

const ProcDef = struct {
    name: []const u8,
    param: ast.FnParam,
    body: *Node,
};

const ProcEnv = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(ProcDef),
    active: std.ArrayList([]const u8),

    fn init(allocator: std.mem.Allocator) ProcEnv {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(ProcDef).init(allocator),
            .active = std.ArrayList([]const u8).empty,
        };
    }

    fn deinit(self: *ProcEnv) void {
        self.map.deinit();
        self.active.deinit(self.allocator);
    }

    fn clone(self: *const ProcEnv) !ProcEnv {
        var cloned = ProcEnv.init(self.allocator);
        var it = self.map.iterator();
        while (it.next()) |entry| try cloned.map.put(entry.key_ptr.*, entry.value_ptr.*);
        try cloned.active.appendSlice(self.allocator, self.active.items);
        return cloned;
    }

    fn isActive(self: *const ProcEnv, name: []const u8) bool {
        for (self.active.items) |active_name| {
            if (std.mem.eql(u8, active_name, name)) return true;
        }
        return false;
    }

    fn pushActive(self: *ProcEnv, name: []const u8) !void {
        try self.active.append(self.allocator, name);
    }

    fn popActive(self: *ProcEnv) void {
        _ = self.active.pop();
    }
};

const ProcMode = enum {
    expand,
    runtimeize,
};

fn expandInEnv(
    vm: *revo.VM,
    allocator: std.mem.Allocator,
    expr: *Node,
    env: *ProcEnv,
    mode: ProcMode,
) ExpandError!*Node {
    return switch (expr.expr) {
        .block => |items| blk: {
            var child = try env.clone();
            defer child.deinit();
            break :blk alloc(allocator, expr.span, .{
                .block = try walkSliceWith(allocator, items, ProcCtx, .{ .vm = vm, .env = &child, .mode = mode }),
            });
        },
        .con_expr => |binding| expandBinding(vm, allocator, expr.span, binding, env, mode),
        .call => |call| maybeExpandCall(vm, allocator, expr.span, call.callee, call.args, call.implicit_self, env, mode),
        .proc_macro => |pm| blk: {
            const body = try expandInEnv(vm, allocator, pm.body, env, .runtimeize);
            try env.map.put(pm.name, .{
                .name = pm.name,
                .param = pm.param,
                .body = body,
            });
            break :blk alloc(allocator, expr.span, .nil);
        },
        else => walkExpr(allocator, expr, ProcCtx, .{ .vm = vm, .env = env, .mode = mode }),
    };
}

fn expandBinding(
    vm: *revo.VM,
    allocator: std.mem.Allocator,
    span: Span,
    binding: ast.Binding,
    env: *ProcEnv,
    mode: ProcMode,
) ExpandError!*Node {
    // kinda hacky. will probably make them run normally later
    if (binding.target.expr == .ident and binding.value.expr == .proc_macro) {
        const target_name = binding.target.expr.ident;
        const proc_body = try expandInEnv(
            vm,
            allocator,
            binding.value.expr.proc_macro.body,
            env,
            .runtimeize,
        );
        try env.map.put(target_name, .{
            .name = binding.value.expr.proc_macro.name,
            .param = binding.value.expr.proc_macro.param,
            .body = proc_body,
        });
        return alloc(allocator, span, .nil);
    }

    return alloc(allocator, span, .{ .con_expr = .{
        .target = try expandInEnv(vm, allocator, binding.target, env, mode),
        .type_name = binding.type_name,
        .value = try expandInEnv(vm, allocator, binding.value, env, mode),
    } });
}

fn maybeExpandCall(
    vm: *revo.VM,
    allocator: std.mem.Allocator,
    span: Span,
    callee: *Node,
    args: []const *Node,
    implicit_self: bool,
    env: *ProcEnv,
    mode: ProcMode,
) ExpandError!*Node {
    const expanded_callee = try expandInEnv(vm, allocator, callee, env, mode);
    const expanded_args = try walkSliceWith(allocator, args, ProcCtx, .{ .vm = vm, .env = env, .mode = mode });

    if (expanded_callee.expr == .ident) {
        if (env.map.get(expanded_callee.expr.ident)) |def| {
            if (mode == .runtimeize) return makeRuntimeProcCall(allocator, span, def, expanded_args);
            return evalProcMacro(vm, span, def, expanded_args, env) catch |err| {
                reportProcExpandError(vm.runtime.alloc, def.name, span, err);
                return err;
            };
        }
    }

    return alloc(allocator, span, .{ .call = .{
        .callee = expanded_callee,
        .args = expanded_args,
        .implicit_self = implicit_self,
    } });
}

const ProcCtx = struct {
    vm: *revo.VM,
    env: *ProcEnv,
    mode: ProcMode,

    fn walk(self: ProcCtx, allocator: std.mem.Allocator, expr: *Node, _: ProcCtx) ExpandError!*Node {
        return expandInEnv(self.vm, allocator, expr, self.env, self.mode);
    }

    fn walkSlice(self: ProcCtx, allocator: std.mem.Allocator, items: []const *Node, _: ProcCtx) ExpandError![]*Node {
        return walkSliceWith(allocator, items, ProcCtx, self);
    }
};

/// could not for my life figure out how to comptimeize further
fn walkExpr(
    allocator: std.mem.Allocator,
    expr: *Node,
    comptime Transform: type,
    ctx: Transform,
) ExpandError!*Node {
    return switch (expr.expr) {
        .unary => |v| alloc(allocator, expr.span, .{ .unary = .{
            .op = v.op,
            .expr = try ctx.walk(allocator, v.expr, ctx),
        } }),
        .binary => |v| alloc(allocator, expr.span, .{ .binary = .{
            .op = v.op,
            .left = try ctx.walk(allocator, v.left, ctx),
            .right = try ctx.walk(allocator, v.right, ctx),
        } }),
        .and_expr => |v| alloc(allocator, expr.span, .{ .and_expr = .{
            .left = try ctx.walk(allocator, v.left, ctx),
            .right = try ctx.walk(allocator, v.right, ctx),
        } }),
        .or_expr => |v| alloc(allocator, expr.span, .{ .or_expr = .{
            .left = try ctx.walk(allocator, v.left, ctx),
            .right = try ctx.walk(allocator, v.right, ctx),
        } }),
        .field => |v| alloc(allocator, expr.span, .{ .field = .{
            .object = try ctx.walk(allocator, v.object, ctx),
            .name = v.name,
        } }),
        .index => |v| alloc(allocator, expr.span, .{ .index = .{
            .object = try ctx.walk(allocator, v.object, ctx),
            .key = try ctx.walk(allocator, v.key, ctx),
        } }),
        .if_expr => |v| alloc(allocator, expr.span, .{ .if_expr = .{
            .condition = try ctx.walk(allocator, v.condition, ctx),
            .then_expr = try ctx.walk(allocator, v.then_expr, ctx),
            .else_expr = if (v.else_expr) |e| try ctx.walk(allocator, e, ctx) else null,
        } }),
        .fn_expr => |v| alloc(allocator, expr.span, .{ .fn_expr = .{
            .params = v.params,
            .return_type = v.return_type,
            .body = try ctx.walk(allocator, v.body, ctx),
        } }),
        .loop_expr => |v| alloc(allocator, expr.span, .{ .loop_expr = .{
            .body = try ctx.walk(allocator, v.body, ctx),
        } }),
        .for_loop => |v| alloc(allocator, expr.span, .{ .for_loop = .{
            .params = v.params,
            .iter = try ctx.walk(allocator, v.iter, ctx),
            .body = try ctx.walk(allocator, v.body, ctx),
        } }),
        .while_loop => |v| alloc(allocator, expr.span, .{ .while_loop = .{
            .predicate = v.predicate,
            .body = try ctx.walk(allocator, v.body, ctx),
        } }),
        .break_expr => |v| alloc(allocator, expr.span, .{
            .break_expr = if (v) |inner| try ctx.walk(allocator, inner, ctx) else null,
        }),
        .return_expr => |v| alloc(allocator, expr.span, .{
            .return_expr = if (v) |inner| try ctx.walk(allocator, inner, ctx) else null,
        }),
        .import_expr => |v| alloc(allocator, expr.span, .{
            .import_expr = try ctx.walk(allocator, v, ctx),
        }),
        .comp_block => |cb| alloc(allocator, expr.span, .{ .comp_block = .{
            .expr = try ctx.walk(allocator, cb.expr, ctx),
            .is_macro = cb.is_macro,
        } }),
        .assign_expr => |v| alloc(allocator, expr.span, .{ .assign_expr = .{
            .target = try ctx.walk(allocator, v.target, ctx),
            .value = try ctx.walk(allocator, v.value, ctx),
        } }),
        .let_expr => |v| alloc(allocator, expr.span, .{ .let_expr = .{
            .target = try ctx.walk(allocator, v.target, ctx),
            .type_name = v.type_name,
            .value = try ctx.walk(allocator, v.value, ctx),
        } }),
        .con_expr => |v| alloc(allocator, expr.span, .{ .con_expr = .{
            .target = try ctx.walk(allocator, v.target, ctx),
            .type_name = v.type_name,
            .value = try ctx.walk(allocator, v.value, ctx),
        } }),
        .global => |v| alloc(allocator, expr.span, .{ .global = .{
            .target = try ctx.walk(allocator, v.target, ctx),
            .type_name = v.type_name,
            .value = try ctx.walk(allocator, v.value, ctx),
        } }),
        .tuple => |items| alloc(allocator, expr.span, .{ .tuple = try ctx.walkSlice(allocator, items, ctx) }),
        .tuple_pattern => |items| alloc(allocator, expr.span, .{ .tuple_pattern = try ctx.walkSlice(allocator, items, ctx) }),
        .block => |items| alloc(allocator, expr.span, .{ .block = try ctx.walkSlice(allocator, items, ctx) }),
        .call => |v| alloc(allocator, expr.span, .{ .call = .{
            .callee = try ctx.walk(allocator, v.callee, ctx),
            .args = try ctx.walkSlice(allocator, v.args, ctx),
            .implicit_self = v.implicit_self,
        } }),
        .match_expr => |v| walkMatch(allocator, expr.span, v, Transform, ctx),
        .table => |entries| walkTable(allocator, expr.span, entries, Transform, ctx),
        .proc_macro => |pm| alloc(allocator, expr.span, .{ .proc_macro = .{
            .name = pm.name,
            .param = pm.param,
            .body = try ctx.walk(allocator, pm.body, ctx),
        } }),
        else => expr,
    };
}

fn walkMatch(
    allocator: std.mem.Allocator,
    span: Span,
    match_expr: anytype,
    comptime Transform: type,
    ctx: Transform,
) ExpandError!*Node {
    var arms = try std.ArrayList(ast.MatchArm).initCapacity(allocator, match_expr.arms.len);
    for (match_expr.arms) |arm| {
        var matchers = try std.ArrayList(ast.MatchMatcher).initCapacity(allocator, arm.matchers.len);
        for (arm.matchers) |matcher| {
            switch (matcher) {
                .wildcard => try matchers.append(allocator, .wildcard),
                .expr => |v| try matchers.append(allocator, .{ .expr = try ctx.walk(allocator, v, ctx) }),
            }
        }
        try arms.append(allocator, .{
            .matchers = try matchers.toOwnedSlice(allocator),
            .guard = if (arm.guard) |g| try ctx.walk(allocator, g, ctx) else null,
            .then = try ctx.walk(allocator, arm.then, ctx),
        });
    }
    return alloc(allocator, span, .{ .match_expr = .{
        .subject = try ctx.walk(allocator, match_expr.subject, ctx),
        .arms = try arms.toOwnedSlice(allocator),
    } });
}

fn walkTable(
    allocator: std.mem.Allocator,
    span: Span,
    entries: []const ast.TableEntry,
    comptime Transform: type,
    ctx: Transform,
) ExpandError!*Node {
    var out = try std.ArrayList(ast.TableEntry).initCapacity(allocator, entries.len);
    for (entries) |entry| {
        try out.append(allocator, .{
            .key = if (entry.key) |k| try ctx.walk(allocator, k, ctx) else null,
            .computed = entry.computed,
            .value = try ctx.walk(allocator, entry.value, ctx),
        });
    }
    return alloc(allocator, span, .{ .table = try out.toOwnedSlice(allocator) });
}

fn walkSliceWith(
    allocator: std.mem.Allocator,
    items: []const *Node,
    comptime Transform: type,
    ctx: Transform,
) ExpandError![]*Node {
    var out = try std.ArrayList(*Node).initCapacity(allocator, items.len);
    for (items) |item| try out.append(allocator, try ctx.walk(allocator, @constCast(item), ctx));
    return out.toOwnedSlice(allocator);
}

fn evalProcMacro(
    vm: *revo.VM,
    span: Span,
    def: ProcDef,
    args: []const *Node,
    env: *ProcEnv,
) ExpandError!*Node {
    if (env.isActive(def.name)) return error.RecursiveProcMacro;
    try env.pushActive(def.name);
    defer env.popActive();

    const allocator = env.allocator;

    var serialized = try std.ArrayList(*Node).initCapacity(allocator, args.len);
    defer serialized.deinit(allocator);
    for (args) |arg| try serialized.append(allocator, try encodeExpr(allocator, arg));

    const items_list = try listNode(allocator, span, serialized.items);
    const iter_call = try callNode(
        allocator,
        span,
        try identNode(allocator, span, "__proc_iter"),
        &.{items_list},
    );
    const wrapper_fn = try fnNode(allocator, span, &.{def.param}, def.body);
    const call = try callNode(allocator, span, wrapper_fn, &.{iter_call});

    var run = try runCompileTimeProc(vm, call, def.name);
    defer run.vm.deinit();
    const decoded = try decodeProcResult(&run.vm, allocator, span, run.result);
    return expandInEnv(vm, allocator, decoded, env, .expand);
}

fn makeRuntimeProcCall(
    allocator: std.mem.Allocator,
    span: Span,
    def: ProcDef,
    args: []const *Node,
) ExpandError!*Node {
    const items_list = try listNode(allocator, span, args);
    const wrapper_fn = try fnNode(allocator, span, &.{def.param}, def.body);
    return callNode(allocator, span, try identNode(allocator, span, "__proc_apply"), &.{ wrapper_fn, items_list });
}

const ProcRun = struct {
    vm: revo.VM,
    result: Data,
};

fn runCompileTimeProc(parent_vm: *revo.VM, root: *Node, proc_name: []const u8) ExpandError!ProcRun {
    var vm = revo.VM.init(parent_vm.runtime) catch return error.ProcCompileFailed;
    errdefer vm.deinit();

    const artifact_report = compiler.lowerExprArtifactReport(&vm, root, false) catch return error.ProcCompileFailed;
    const artifact = switch (artifact_report) {
        .ok => |ok| ok,
        .err => |failure| {
            renderProcFailure(
                vm.runtime.alloc,
                proc_name,
                "compile",
                failure.span,
                failure.message,
            );
            return error.ProcCompileFailed;
        },
    };
    defer vm.runtime.alloc.free(artifact.instructions);
    defer vm.runtime.alloc.free(artifact.spans);

    const result = try revo.module.runCompiledModuleReport(&vm, "<proc>", artifact.instructions);
    switch (result) {
        .ok => {},
        .err => |failure| {
            renderProcFailure(vm.runtime.alloc, proc_name, "runtime", failure.span, failure.message);
            return error.ProcEvalFailed;
        },
    }
    return .{ .vm = vm, .result = vm.currentFiber().result };
}

fn renderProcFailure(
    allocator: std.mem.Allocator,
    proc_name: []const u8,
    stage: []const u8,
    span: ?Span,
    message: []const u8,
) void {
    var buf = std.Io.Writer.Allocating.init(allocator);
    defer buf.deinit();
    revo.renderFailureAt(allocator, &buf.writer, "<proc>", "", span, message) catch {
        std.debug.print("proc {s}: {s} error: {s}\n", .{ proc_name, stage, message });
        return;
    };
    std.debug.print("proc {s}: {s} error\n{s}", .{ proc_name, stage, buf.written() });
}

fn reportProcExpandError(
    allocator: std.mem.Allocator,
    proc_name: []const u8,
    span: Span,
    err: ExpandError,
) void {
    // ct/rt failures already render in runCompileTimeProc
    if (err == error.ProcCompileFailed or err == error.ProcEvalFailed) return;

    const message = switch (err) {
        error.UnsupportedProcValue => "unsupported proc value while encoding/decoding AST",
        error.InvalidProcReturn => "invalid proc return AST encoding",
        error.RecursiveProcMacro => "recursive proc macro expansion",
        else => @errorName(err),
    };
    renderProcFailure(allocator, proc_name, "expand", span, message);
}

fn decodeProcResult(vm: *revo.VM, allocator: std.mem.Allocator, span: Span, data: Data) ExpandError!*Node {
    return switch (data) {
        .atom => |atom| if (atom == revo.core_atoms.atom_id(.nil)) alloc(allocator, span, .nil) else error.InvalidProcReturn,
        .tuple => |tid| decodeNodeSequence(vm, allocator, span, (vm.tuples.get(tid) catch return error.InvalidProcReturn).items),
        .table => |tid| decodeNodeSequence(vm, allocator, span, (vm.tables.get(tid) catch return error.InvalidProcReturn).array.items),
        else => error.InvalidProcReturn,
    };
}

fn decodeNodeSequence(
    vm: *revo.VM,
    allocator: std.mem.Allocator,
    span: Span,
    items: []const Data,
) ExpandError!*Node {
    if (items.len == 0) return alloc(allocator, span, .nil);

    var out = try std.ArrayList(*Node).initCapacity(allocator, items.len);
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, try decodeExprNode(vm, allocator, span, item));

    if (out.items.len == 1) return out.items[0];
    return alloc(allocator, span, .{ .block = try out.toOwnedSlice(allocator) });
}

fn encodeExpr(allocator: std.mem.Allocator, node: *const Node) ExpandError!*Node {
    const tag_name = @tagName(node.expr);
    const info = @typeInfo(Expr).@"union";

    inline for (info.fields) |field| {
        if (std.mem.eql(u8, field.name, tag_name)) {
            const payload = try encodePayload(allocator, node.span, field.type, @field(node.expr, field.name));
            var items = try std.ArrayList(*Node).initCapacity(allocator, payload.len + 1);
            errdefer items.deinit(allocator);
            try items.append(allocator, try atomNode(allocator, node.span, tag_name));
            for (payload) |item| try items.append(allocator, item);
            return tupleNode(allocator, node.span, try items.toOwnedSlice(allocator));
        }
    }
    return error.UnsupportedProcValue;
}

fn encodePayload(
    allocator: std.mem.Allocator,
    span: Span,
    comptime T: type,
    value: T,
) ExpandError![]*Node {
    const ti = @typeInfo(T);
    if (ti == .void) return try allocator.alloc(*Node, 0);

    if (ti == .@"struct") {
        var out = try std.ArrayList(*Node).initCapacity(allocator, ti.@"struct".fields.len);
        errdefer out.deinit(allocator);
        inline for (ti.@"struct".fields) |field| {
            try out.append(allocator, try encodeValue(allocator, span, field.type, @field(value, field.name)));
        }
        return out.toOwnedSlice(allocator);
    }

    var out = try std.ArrayList(*Node).initCapacity(allocator, 1);
    errdefer out.deinit(allocator);
    try out.append(allocator, try encodeValue(allocator, span, T, value));
    return out.toOwnedSlice(allocator);
}

fn encodeValue(
    allocator: std.mem.Allocator,
    span: Span,
    comptime T: type,
    value: T,
) ExpandError!*Node {
    const ti = @typeInfo(T);

    return switch (ti) {
        .pointer => |pi| {
            if (pi.size == .slice and pi.child == u8) {
                return alloc(allocator, span, .{ .string = value });
            }
            if (pi.size == .slice) {
                var items = try std.ArrayList(*Node).initCapacity(allocator, value.len);
                errdefer items.deinit(allocator);
                for (value) |item| try items.append(allocator, try encodeValue(allocator, span, pi.child, item));
                return listNode(allocator, span, try items.toOwnedSlice(allocator));
            }
            if (pi.size == .one) {
                if (pi.child == Node) return encodeExpr(allocator, value);
                return encodeValue(allocator, span, pi.child, value.*);
            }
            return error.UnsupportedProcValue;
        },
        .optional => {
            if (value) |inner| {
                return encodeValue(allocator, span, ti.optional.child, inner);
            } else {
                return alloc(allocator, span, .nil);
            }
        },
        .bool => if (value) atomNode(allocator, span, "true") else atomNode(allocator, span, "false"),
        .float => alloc(allocator, span, .{ .number = @floatCast(value) }),
        .int, .comptime_int => alloc(allocator, span, .{ .number = @floatFromInt(value) }),
        .comptime_float => alloc(allocator, span, .{ .number = value }),
        .@"enum" => atomNode(allocator, span, @tagName(value)),

        .@"union" => |ui| {
            inline for (ui.fields) |field| {
                if (std.mem.eql(u8, field.name, @tagName(value))) {
                    const payload = try encodePayload(allocator, span, field.type, @field(value, field.name));
                    var items = try std.ArrayList(*Node).initCapacity(allocator, payload.len + 1);
                    errdefer items.deinit(allocator);
                    try items.append(allocator, try atomNode(allocator, span, field.name));
                    for (payload) |item| try items.append(allocator, item);
                    return tupleNode(allocator, span, try items.toOwnedSlice(allocator));
                }
            }
            return error.UnsupportedProcValue;
        },

        .@"struct" => {
            var items = try std.ArrayList(*Node).initCapacity(allocator, ti.@"struct".fields.len);
            errdefer items.deinit(allocator);
            inline for (ti.@"struct".fields) |field| {
                try items.append(allocator, try encodeValue(allocator, span, field.type, @field(value, field.name)));
            }
            return tupleNode(allocator, span, try items.toOwnedSlice(allocator));
        },

        .array => {
            var items = try std.ArrayList(*Node).initCapacity(allocator, ti.array.len);
            errdefer items.deinit(allocator);
            inline for (value) |item| try items.append(allocator, try encodeValue(allocator, span, ti.array.child, item));
            return listNode(allocator, span, try items.toOwnedSlice(allocator));
        },

        else => error.UnsupportedProcValue,
    };
}

fn decodeExprNode(vm: *revo.VM, allocator: std.mem.Allocator, span: Span, data: Data) ExpandError!*Node {
    const tuple = try expectTuple(vm, data);
    if (tuple.items.len == 0 or tuple.items[0] != .atom) return error.InvalidProcReturn;
    const tag = vm.atomName(tuple.items[0].atom);

    const info = @typeInfo(Expr).@"union";
    inline for (info.fields) |field| {
        if (std.mem.eql(u8, field.name, tag)) {
            var idx: usize = 1;
            const payload = try decodePayload(vm, allocator, span, field.type, tuple.items, &idx);
            if (idx != tuple.items.len) return error.InvalidProcReturn;
            return alloc(allocator, span, @unionInit(Expr, field.name, payload));
        }
    }
    return error.InvalidProcReturn;
}

fn decodePayload(
    vm: *revo.VM,
    allocator: std.mem.Allocator,
    span: Span,
    comptime T: type,
    items: []const Data,
    idx: *usize,
) ExpandError!T {
    const ti = @typeInfo(T);
    if (ti == .void) return {};

    if (ti == .@"struct") {
        // SAFETY: all fields set by inline for loop below
        var out: T = undefined;
        inline for (ti.@"struct".fields) |field| {
            @field(out, field.name) = try decodeValue(vm, allocator, span, field.type, items, idx);
        }
        return out;
    }

    if (idx.* >= items.len) return error.InvalidProcReturn;
    const value = try decodeValue(vm, allocator, span, T, items, idx);
    return value;
}

fn decodeValue(
    vm: *revo.VM,
    allocator: std.mem.Allocator,
    span: Span,
    comptime T: type,
    items: []const Data,
    idx: *usize,
) ExpandError!T {
    if (idx.* >= items.len) return error.InvalidProcReturn;
    const data = items[idx.*];
    idx.* += 1;

    return switch (@typeInfo(T)) {
        .optional => |opt| {
            if (isNilData(vm, data)) {
                idx.* -= 1;
                return null;
            }
            idx.* -= 1;
            return try decodeValue(vm, allocator, span, opt.child, items, idx);
        },
        .bool => switch (data) {
            .atom => |atom| blk: {
                const name = vm.atomName(atom);
                if (std.mem.eql(u8, name, "true")) break :blk true;
                if (std.mem.eql(u8, name, "false")) break :blk false;
                return error.InvalidProcReturn;
            },
            else => error.InvalidProcReturn,
        },
        // comptime numbers shouldnt appear unless i fold in parser
        .int => switch (data) {
            .number => |n| @as(T, @intFromFloat(n)),
            else => error.InvalidProcReturn,
        },
        .float => switch (data) {
            .number => |n| n,
            else => error.InvalidProcReturn,
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) return switch (data) {
                .string => |sid| allocator.dupe(u8, vm.stringValue(sid)) catch return error.OutOfMemory,
                else => error.InvalidProcReturn,
            };
            if (ptr.size == .slice) {
                idx.* -= 1;
                return try decodeSliceValue(T, vm, allocator, span, ptr.child, items, idx);
            }
            if (ptr.size == .one and ptr.child == Node) {
                return try decodeExprNode(vm, allocator, span, data);
            }
            if (ptr.size == .one) {
                var single_idx: usize = 0;
                const single_items = [_]Data{data};
                return try decodeValue(vm, allocator, span, ptr.child, &single_items, &single_idx);
            }
            return error.UnsupportedProcValue;
        },
        .@"enum" => {
            const name = switch (data) {
                .atom => |atom| vm.atomName(atom),
                else => return error.InvalidProcReturn,
            };
            const info = @typeInfo(T).@"enum";
            inline for (info.fields) |field| {
                if (std.mem.eql(u8, field.name, name)) return @enumFromInt(field.value);
            }
            return error.InvalidProcReturn;
        },
        .@"union" => |un| {
            const union_tuple = try expectTuple(vm, data);
            if (union_tuple.items.len == 0 or union_tuple.items[0] != .atom) return error.InvalidProcReturn;
            const union_tag = vm.atomName(union_tuple.items[0].atom);

            inline for (un.fields) |field| {
                if (std.mem.eql(u8, field.name, union_tag)) {
                    var union_idx: usize = 1;
                    const union_payload = try decodePayload(vm, allocator, span, field.type, union_tuple.items, &union_idx);
                    if (union_idx != union_tuple.items.len) return error.InvalidProcReturn;
                    return @unionInit(T, field.name, union_payload);
                }
            }
            return error.InvalidProcReturn;
        },
        .@"struct" => |st| {
            const struct_tuple = try expectTuple(vm, data);
            var struct_idx: usize = 0;
            // SAFETY: all fields set by inline for loop below
            var out: T = undefined;
            inline for (st.fields) |field| {
                @field(out, field.name) = try decodeValue(
                    vm,
                    allocator,
                    span,
                    field.type,
                    struct_tuple.items,
                    &struct_idx,
                );
            }
            if (struct_idx != struct_tuple.items.len) return error.InvalidProcReturn;
            return out;
        },
        .array => |arr| {
            idx.* -= 1;
            const array_items = switch (data) {
                .table => |tid| blk: {
                    const table = vm.tables.get(tid) catch return error.InvalidProcReturn;
                    break :blk table.array.items;
                },
                .tuple => |tid| blk: {
                    const tuple = vm.tuples.get(tid) catch return error.InvalidProcReturn;
                    break :blk tuple.items;
                },
                .atom => |atom| if (atom == revo.core_atoms.atom_id(.nil)) &.{} else return error.InvalidProcReturn,
                else => return error.InvalidProcReturn,
            };
            if (array_items.len != arr.len) return error.InvalidProcReturn;
            // SAFETY: all elements set by inline for loop below
            var out: T = undefined;
            var array_idx: usize = 0;
            inline for (0..arr.len) |i| {
                out[i] = try decodeValue(vm, allocator, span, arr.child, array_items, &array_idx);
            }
            return out;
        },
        else => return error.UnsupportedProcValue,
    };
}

fn decodeSliceValue(
    comptime T: type,
    vm: *revo.VM,
    allocator: std.mem.Allocator,
    span: Span,
    comptime Child: type,
    items: []const Data,
    idx: *usize,
) ExpandError!T {
    if (idx.* >= items.len) return error.InvalidProcReturn;
    const data = items[idx.*];
    idx.* += 1;

    const seq = switch (data) {
        .table => |tid| blk: {
            const table = vm.tables.get(tid) catch return error.InvalidProcReturn;
            break :blk table.array.items;
        },
        .tuple => |tid| blk: {
            const tuple = vm.tuples.get(tid) catch return error.InvalidProcReturn;
            break :blk tuple.items;
        },
        .atom => |atom| if (atom == revo.core_atoms.atom_id(.nil)) &.{} else return error.InvalidProcReturn,
        else => return error.InvalidProcReturn,
    };

    var out = try allocator.alloc(Child, seq.len);
    for (0..seq.len) |i| {
        const single = [_]Data{seq[i]};
        var single_idx: usize = 0;
        out[i] = try decodeValue(vm, allocator, span, Child, &single, &single_idx);
    }
    return out;
}

fn isNilData(vm: *revo.VM, data: Data) bool {
    return switch (data) {
        .atom => |atom| std.mem.eql(u8, vm.atomName(atom), "nil"),
        else => false,
    };
}

fn expectTuple(vm: *revo.VM, data: Data) ExpandError!*revo.tuple.Tuple {
    return switch (data) {
        .tuple => |tid| vm.tuples.get(tid) catch return error.InvalidProcReturn,
        else => error.InvalidProcReturn,
    };
}

fn tupleNode(allocator: std.mem.Allocator, span: Span, items: []const *Node) ExpandError!*Node {
    var out = try std.ArrayList(*Node).initCapacity(allocator, items.len);
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, @constCast(item));
    return alloc(allocator, span, .{ .tuple = try out.toOwnedSlice(allocator) });
}

fn listNode(allocator: std.mem.Allocator, span: Span, items: []const *Node) ExpandError!*Node {
    var out = try std.ArrayList(ast.TableEntry).initCapacity(allocator, items.len);
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .key = null, .value = @constCast(item) });
    return alloc(allocator, span, .{ .table = try out.toOwnedSlice(allocator) });
}

fn identNode(allocator: std.mem.Allocator, span: Span, name: []const u8) ExpandError!*Node {
    return alloc(allocator, span, .{ .ident = name });
}

fn callNode(allocator: std.mem.Allocator, span: Span, callee: *Node, args: []const *Node) ExpandError!*Node {
    return callNodeWithSelf(allocator, span, callee, args, false);
}

fn callNodeWithSelf(
    allocator: std.mem.Allocator,
    span: Span,
    callee: *Node,
    args: []const *Node,
    implicit_self: bool,
) ExpandError!*Node {
    var out = try std.ArrayList(*Node).initCapacity(allocator, args.len);
    errdefer out.deinit(allocator);
    for (args) |arg| try out.append(allocator, @constCast(arg));
    return alloc(allocator, span, .{ .call = .{
        .callee = callee,
        .args = try out.toOwnedSlice(allocator),
        .implicit_self = implicit_self,
    } });
}

fn fnNode(allocator: std.mem.Allocator, span: Span, params: []const ast.FnParam, body: *Node) ExpandError!*Node {
    const copied = try allocator.alloc(ast.FnParam, params.len);
    @memcpy(copied, params);
    return alloc(allocator, span, .{ .fn_expr = .{
        .params = copied,
        .body = body,
    } });
}

fn atomNode(allocator: std.mem.Allocator, span: Span, name: []const u8) ExpandError!*Node {
    return alloc(allocator, span, .{ .hash = name });
}

fn alloc(allocator: std.mem.Allocator, span: Span, expr: Expr) ExpandError!*Node {
    const node = try allocator.create(Node);
    node.* = .{ .span = span, .expr = expr };
    return node;
}

fn iter(args: []const Data, vm: *revo.VM) !revo.std_lib.NativeResult {
    if (args.len != 1) return .errArity(args.len, 1);
    const items = switch (args[0]) {
        .table, .tuple => args[0],
        else => return .errType(0, "table or tuple", revo.std_lib.dataToString(args[0])),
    };
    return .okData(try makeIterValue(vm, items));
}

fn next(args: []const Data, vm: *revo.VM) !revo.std_lib.NativeResult {
    return iterStep(args, vm, true);
}

fn peek(args: []const Data, vm: *revo.VM) !revo.std_lib.NativeResult {
    return iterStep(args, vm, false);
}

fn consumed(args: []const Data, vm: *revo.VM) !revo.std_lib.NativeResult {
    if (args.len != 1) return .errArity(args.len, 1);
    const iter_id = switch (args[0]) {
        .table => |id| id,
        else => return .errType(0, "table", revo.std_lib.dataToString(args[0])),
    };
    const iter_tbl = try vm.tables.get(iter_id);
    const index_data = iter_tbl.getRaw(.{ .atom = try vm.internAtom("index") }) orelse Data.new.num(0);
    return .{ .ok = index_data };
}

fn nextOf(args: []const Data, vm: *revo.VM) !revo.std_lib.NativeResult {
    if (args.len != 2) return .errArity(args.len, 2);
    const expected_atom = switch (args[1]) {
        .atom => |a| a,
        else => return .errType(1, "atom", revo.std_lib.dataToString(args[1])),
    };
    const expected_name = vm.atomName(expected_atom);

    const item = (try iterStep(args[0..1], vm, true)).ok;
    if (item == .atom and item.atom == revo.core_atoms.atom_id(.nil)) {
        var panic_msg = try std.ArrayList(u8).initCapacity(vm.runtime.alloc, 64);
        defer panic_msg.deinit(vm.runtime.alloc);
        try panic_msg.appendSlice(vm.runtime.alloc, "proc iter:next_of expected :");
        try panic_msg.appendSlice(vm.runtime.alloc, expected_name);
        try panic_msg.appendSlice(vm.runtime.alloc, " but reached end of stream");
        try vm.setPanicMessage(panic_msg.items);
        return .panic();
    }

    const tuple = switch (item) {
        .tuple => |tid| vm.tuples.get(tid) catch {
            try vm.setPanicMessage("proc iter:next_of expected tuple node");
            return .panic();
        },
        else => {
            try vm.setPanicMessage("proc iter:next_of expected tuple node");
            return .panic();
        },
    };
    if (tuple.items.len == 0 or tuple.items[0] != .atom) {
        try vm.setPanicMessage("proc iter:next_of expected tagged tuple node");
        return .panic();
    }
    if (!std.mem.eql(u8, vm.atomName(tuple.items[0].atom), expected_name)) {
        var panic_msg = try std.ArrayList(u8).initCapacity(vm.runtime.alloc, 64);
        defer panic_msg.deinit(vm.runtime.alloc);
        try panic_msg.appendSlice(vm.runtime.alloc, "proc iter:next_of expected :");
        try panic_msg.appendSlice(vm.runtime.alloc, expected_name);
        try panic_msg.appendSlice(vm.runtime.alloc, " got :");
        try panic_msg.appendSlice(vm.runtime.alloc, vm.atomName(tuple.items[0].atom));
        try vm.setPanicMessage(panic_msg.items);
        return .panic();
    }

    if (tuple.items.len == 1) return .{ .ok = revo.core_atoms.data(.nil) };
    if (tuple.items.len == 2) return .{ .ok = tuple.items[1] };

    const payload_id = try vm.tuples.create(tuple.items[1..]);
    return .{ .ok = .{ .tuple = payload_id } };
}

fn procApply(args: []const Data, vm: *revo.VM) !revo.std_lib.NativeResult {
    if (args.len != 2) return .errArity(args.len, 2);
    const callee = switch (args[0]) {
        .function => args[0],
        else => return .errType(0, "function", revo.std_lib.dataToString(args[0])),
    };

    const iter_value = try makeIterValue(vm, args[1]);
    const result = try vm.callFunction(callee, &.{iter_value});
    return .okData(try normalizeProcValue(vm, result));
}

fn makeIterValue(vm: *revo.VM, items: Data) !Data {
    const iter_id = try vm.tables.create();
    const iter_tbl = try vm.tables.get(iter_id);
    try iter_tbl.putRaw(.{ .atom = try vm.internAtom("items") }, items);
    try iter_tbl.putRaw(.{ .atom = try vm.internAtom("index") }, Data.new.num(0));

    const next_id = try vm.functions.create(.{ .native = revo.std_lib.define(&[_]revo.std_lib.TypeSpec{.table}, next) });
    const peek_id = try vm.functions.create(.{ .native = revo.std_lib.define(&[_]revo.std_lib.TypeSpec{.table}, peek) });
    const consumed_id = try vm.functions.create(.{ .native = revo.std_lib.define(&[_]revo.std_lib.TypeSpec{.table}, consumed) });
    const next_of_id = try vm.functions.create(.{ .native = revo.std_lib.define(&[_]revo.std_lib.TypeSpec{ .table, .atom }, nextOf) });
    try iter_tbl.putRaw(.{ .atom = try vm.internAtom("next") }, .{ .function = next_id });
    try iter_tbl.putRaw(.{ .atom = try vm.internAtom("peek") }, .{ .function = peek_id });
    try iter_tbl.putRaw(.{ .atom = try vm.internAtom("consumed") }, .{ .function = consumed_id });
    try iter_tbl.putRaw(.{ .atom = try vm.internAtom("next_of") }, .{ .function = next_of_id });
    return .{ .table = iter_id };
}

fn normalizeProcValue(vm: *revo.VM, value: Data) !Data {
    return switch (value) {
        .table => |tid| blk: {
            const table = try vm.tables.get(tid);
            if (table.array.items.len == 0) break :blk revo.core_atoms.data(.nil);
            if (table.array.items.len == 1) break :blk table.array.items[0];
            break :blk value;
        },
        else => value,
    };
}

fn iterStep(args: []const Data, vm: *revo.VM, advance: bool) !revo.std_lib.NativeResult {
    if (args.len != 1) return .errArity(args.len, 1);
    const iter_id = switch (args[0]) {
        .table => |id| id,
        else => return .errType(0, "table", revo.std_lib.dataToString(args[0])),
    };
    const iter_tbl = try vm.tables.get(iter_id);
    const items_data = iter_tbl.getRaw(.{ .atom = try vm.internAtom("items") }) orelse return .{ .ok = revo.core_atoms.data(.nil) };
    const index_data = iter_tbl.getRaw(.{ .atom = try vm.internAtom("index") }) orelse Data.new.num(0);
    const idx = switch (index_data) {
        .number => |n| try revo.asIndex(n),
        else => return error.TypeError,
    };

    const item = switch (items_data) {
        .table => |tid| blk: {
            const table = try vm.tables.get(tid);
            if (idx >= table.array.items.len) break :blk revo.core_atoms.data(.nil);
            break :blk table.array.items[idx];
        },
        .tuple => |tid| blk: {
            const tuple = try vm.tuples.get(tid);
            if (idx >= tuple.items.len) break :blk revo.core_atoms.data(.nil);
            break :blk tuple.items[idx];
        },
        else => revo.core_atoms.data(.nil),
    };

    if (advance) {
        try iter_tbl.putRaw(.{ .atom = try vm.internAtom("index") }, Data.new.num(idx + 1));
    }
    return .{ .ok = item };
}

const testing = @import("testing.zig");

test "proc macro" {
    try testing.top_number(
        \\ proc ftwo!(iter) do
        \\   let x = 40 + 2
        \\   {(:number, 42)}
        \\ end
        \\ ftwo!()
    , 42);
}

test "proc macro can rewrite to a constant expression" {
    try testing.top_number(
        \\ proc answer!(iter) do
        \\   {(:number, 42)}
        \\ end
        \\ answer!()
    , 42);
}

test "proc macro uses explicit call args only" {
    try testing.top_number(
        \\ proc add3!(iter) do
        \\   let a = iter:next()
        \\   let b = iter:next()
        \\   let c = iter:next()
        \\   {(:binary, :add, (:binary, :add, a, b), c)}
        \\ end
        \\ add3!(10, 20, 12)
    , 42);
}

test "proc macro uses peek without consuming" {
    try testing.top_number(
        \\ proc dup_add!(iter) do
        \\   let a = iter:peek()
        \\   let b = iter:next()
        \\   {(:binary, :add, a, b)}
        \\ end
        \\ dup_add!(21)
    , 42);
}

test "proc macro does not consume outer siblings" {
    try testing.top_number(
        \\ proc take1!(iter) do
        \\   let a = iter:next()
        \\   {a}
        \\ end
        \\ take1!(20)
        \\ 22
    , 22);
}

test "proc macro can build if_expr from explicit args" {
    try testing.top_number(
        \\ proc choose!(iter) do
        \\   let cond = iter:next()
        \\   let yes = iter:next()
        \\   let no = iter:next()
        \\   {(:if_expr, cond, yes, no)}
        \\ end
        \\ choose!(2 == 3, 42, 7)
        \\ choose!(2 == 2, 42, 7)
    , 42);
}

test "proc macro print! expands fmt call" {
    if (true) return error.SkipZigTest; // noisy
    try testing.top_atom(
        \\ proc print!(iter) do
        \\   let fmt = iter:next_of(:string)
        \\   let args = {}
        \\   let i = 0
        \\   args[i] = (:string, fmt)
        \\   i += 1
        \\   while iter:peek() != :nil do
        \\     args[i] = iter:next()
        \\     i += 1
        \\   end
        \\   {(:call, (:ident, "print"), {(:call, (:ident, "fmt"), args, :false)}, :false)}
        \\ end
        \\ print!("hello, %v!", "world")
        \\ :ok
    , "ok");
}

test "proc cmul from examples works" {
    if (true) return error.SkipZigTest; // noisy
    try testing.top_number(
        \\ proc cmul!(iter) do
        \\   inspect(iter:peek())
        \\   let a = 10 + iter:next_of(:number)
        \\   let b = iter:next_of(:number)
        \\   let c = iter:next_of(:number)
        \\   let acc = 0
        \\   for i in 1..5 do
        \\     acc += a * b + c
        \\   end
        \\   {(:number, acc)}
        \\ end
        \\ cmul!(10, 20, 30)
    , 1720);
}

test "nested proc passthrough can take iter next directly" {
    if (true) return error.SkipZigTest; // noisy
    try testing.top_number(
        \\ proc take1!(iter) do
        \\   let x = iter:next()
        \\   print(x)
        \\   {x}
        \\ end
        \\ proc outer!(iter) do
        \\   let first = take1!(iter:next())
        \\   {first}
        \\ end
        \\ outer!(42)
    , 42);
}

test "inspect can print iter next directly without changing it" {
    if (true) return error.SkipZigTest; // noisy
    try testing.top_number(
        \\ proc outer!(iter) do
        \\   let first = inspect(iter:next())
        \\   {first}
        \\ end
        \\ outer!(42)
    , 42);
}

test "proc iter next_of unwraps payload values" {
    try testing.top_number(
        \\ proc sum3!(iter) do
        \\   let a = iter:next_of(:number)
        \\   let b = iter:next_of(:number)
        \\   let c = iter:next_of(:number)
        \\   {(:number, a + b + c)}
        \\ end
        \\ sum3!(10, 20, 12)
    , 42);
}

test "proc macro can use comp inside body" {
    try testing.top_number(
        \\ proc add_comp!(iter) do
        \\   const n = comp (1 + 1)
        \\   {(:number, n + iter:next_of(:number))}
        \\ end
        \\ add_comp!(40)
    , 42);
}

test "recursive proc macro is rejected for now" {
    if (true) return error.SkipZigTest; // noisy
    var vm = try revo.VM.init(testing.runtime());
    defer vm.deinit();

    try std.testing.expectError(error.RecursiveProcMacro, lang.build(&vm, .{
        .text =
        \\ proc loop!(iter) do
        \\   comp (1 + 1)
        \\   {(:call, (:ident, "loop!"), {}, :false)}
        \\ end
        \\ loop!()
        ,
    }, .{}));
}
