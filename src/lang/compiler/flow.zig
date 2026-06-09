const std = @import("std");

const revo = @import("revo");
const Compiler = revo.lang.compiler.Compiler;
const Data = revo.Data;
const ProgramCounter = revo.ProgramCounter;
const Operand = revo.Operand;
const Register = revo.opcode.Register;
const LocalSlot = revo.LocalSlot;

const ast = @import("../ast.zig");
const Node = ast.Node;
const state = @import("state.zig");
const toRegister = state.toRegister;
const type_check = @import("type_check.zig");
const types_mod = @import("types.zig");

const TypeHint = struct {
    name: []const u8,
    type_info: types_mod.TypeInfo,
};

pub const VarStorage = union(enum) {
    local: Operand,
    global: revo.AtomID,
};

pub fn compileLoop(self: *Compiler, body: *const Node) !void {
    const LoopScopeT = state.LoopScope(@TypeOf(self.*));
    var loop = try LoopScopeT.init(self);
    defer loop.deinit();

    const loop_start: ProgramCounter = @intCast(self.irLen());
    try self.compile(body, true);
    try self.regRelease();
    try self.emit(.jump, loop_start);
    // result visible to next binding
    self.active_registers = self.loop_result_regs.items[self.loop_result_regs.items.len - 1] + 1;
}

pub fn compileWhile(
    self: *Compiler,
    predicate: *const Node,
    body: *const Node,
) !void {
    const LoopScopeT = state.LoopScope(@TypeOf(self.*));
    var loop = try LoopScopeT.init(self);
    defer loop.deinit();

    const loop_start: ProgramCounter = @intCast(self.irLen());
    try self.compile(predicate, true);
    const exit_jump = try self.jump(.jump_if_false);
    try self.compile(body, true);

    const body_result_reg: Register = @intCast(self.active_registers - 1);
    const loop_result_reg: Register = @intCast(self.loop_result_regs.items[self.loop_result_regs.items.len - 1]);
    if (body_result_reg != loop_result_reg) {
        try self.spans.append(self.alloc, self.active_span);
        _ = try self.record(.move, &.{.{ .reg = body_result_reg }}, true, loop_result_reg, 0);
    }
    try self.regRelease();
    try self.emit(.jump, loop_start);

    self.patchJump(exit_jump);
    // same as compileLoop
    self.active_registers = self.loop_result_regs.items[self.loop_result_regs.items.len - 1] + 1;
}

pub fn compileForRange(
    self: *Compiler,
    params: []const ast.FnParam,
    body: *const Node,
    start_expr: *const Node,
    step_expr: *const Node,
    end_expr: *const Node,
) !void {
    const LoopScopeT = state.LoopScope(@TypeOf(self.*));
    var loop = try LoopScopeT.init(self);
    defer loop.deinit();

    try self.compile(start_expr, true); // contiguous triple for range_init
    try self.compile(step_expr, true);
    try self.compile(end_expr, true);

    const base_reg = try toRegister(self.active_registers - 3);
    try self.spans.append(self.alloc, self.active_span);
    try self.recordStackOp(.range_init, 3, 0, base_reg, 0);

    const needs_index = params.len == 2 and !ast.isDiscardName(params[1].name);

    try compileRangeLoopBody(self, params, body, base_reg, needs_index);
    // collapse to result
    self.active_registers = self.loop_result_regs.items[self.loop_result_regs.items.len - 1] + 1;
}

pub fn compileRangeLoopBody(
    self: *Compiler,
    params: []const ast.FnParam,
    body: *const Node,
    state_reg: Register,
    needs_index: bool,
) !void {
    var value_slot: ?LocalSlot = null;
    var index_slot: ?LocalSlot = null;

    // declare before loop_check so range_next can fill them each iteration
    if (params.len >= 1 and !ast.isDiscardName(params[0].name)) {
        value_slot = try state.declareLocal(self, params[0].name, false);
        if (params[0].type_name) |tn| {
            const declared = try type_check.evalTypeExpr(self, tn);
            if (declared != .int) {
                const msg = try std.fmt.allocPrint(
                    self.alloc,
                    "range loop variable must be int, got {s}",
                    .{@tagName(declared)},
                );
                return self.setFailureParts(.ParseError, null, msg, &.{});
            }
        }
        state.setLocalType(self, value_slot.?, "int");
        try state.setLocalTypeHint(self, params[0].name, .int);
    }
    if (params.len == 2 and !ast.isDiscardName(params[1].name)) {
        index_slot = try state.declareLocal(self, params[1].name, false);
        if (params[1].type_name) |tn| {
            const declared = try type_check.evalTypeExpr(self, tn);
            if (declared != .int) {
                const msg = try std.fmt.allocPrint(
                    self.alloc,
                    "range loop variable must be int, got {s}",
                    .{@tagName(declared)},
                );
                return self.setFailureParts(.ParseError, null, msg, &.{});
            }
        }
        state.setLocalType(self, index_slot.?, "int");
        try state.setLocalTypeHint(self, params[1].name, .int);
    }

    const loop_check: ProgramCounter = @intCast(self.irLen());

    const value_reg = try toRegister(self.active_registers);
    const index_reg = if (needs_index) try toRegister(self.active_registers + 1) else 0;

    try self.spans.append(self.alloc, self.active_span);
    try self.recordStackOp(.range_next, 0, 0, value_reg, if (needs_index) @as(Operand, 1) else 0);
    self.active_registers += if (needs_index) 3 else 2;

    const end_jump = try self.jump(.jump_if_false);

    if (value_slot) |slot| {
        const temp_reg = try toRegister(self.active_registers);
        try self.spans.append(self.alloc, self.active_span);
        _ = try self.record(.move, &.{.{ .reg = value_reg }}, true, temp_reg, 0);
        self.active_registers += 1;
        state.markLocalInitialized(self, slot);
        try self.emit(.bind_local, slot);
    }

    if (index_slot) |slot| {
        const temp_reg = try toRegister(self.active_registers);
        try self.spans.append(self.alloc, self.active_span);
        _ = try self.record(.move, &.{.{ .reg = index_reg }}, true, temp_reg, 0);
        self.active_registers += 1;
        state.markLocalInitialized(self, slot);
        try self.emit(.bind_local, slot);
    }

    if (needs_index) try self.regRelease();
    try self.regRelease();

    const loop_state_end = try toRegister(state_reg + 3);
    reserveRegisters(self, loop_state_end); // pin range state so body can't clobber it

    try self.compile(body, true);

    // normalise into loop result slot so break and natural exit agree
    const body_result_reg: Register = @intCast(self.active_registers - 1);
    const loop_result_reg: Register = @intCast(self.loop_result_regs.items[self.loop_result_regs.items.len - 1]);
    if (body_result_reg != loop_result_reg) {
        try self.spans.append(self.alloc, self.active_span);
        _ = try self.record(.move, &.{.{ .reg = body_result_reg }}, true, loop_result_reg, 0);
    }
    try self.regRelease();

    try self.emit(.jump, loop_check);
    self.patchJump(end_jump);

    // reverse order: has_next, index (if used), value, range state (3 regs)
    try self.regRelease();
    if (needs_index) try self.regRelease();
    try self.regRelease();
    try self.regRelease();
    try self.regRelease();
}

pub fn compileFor(
    self: *Compiler,
    params: []const ast.FnParam,
    body: *const Node,
    iter: *const Node,
) !void {
    if (params.len == 0 or params.len > 2) {
        const msg = try std.fmt.allocPrint(
            self.alloc,
            "for expects one or two binding names, got {d}",
            .{params.len},
        );
        return self.fail(.UnsupportedSyntax, iter, msg);
    }

    if (iter.expr == .range_literal) {
        const range_info = iter.expr.range_literal;
        return compileForRange(self, params, body, range_info.start, range_info.step, range_info.end);
    }

    const LoopScopeT = state.LoopScope(@TypeOf(self.*));
    var loop = try LoopScopeT.init(self);
    defer loop.deinit();

    // wrap expression with to_iter
    try self.emit(.load_global, try self.vm.internAtom("to_iter"));
    try self.compile(iter, true);
    try self.emit(.call, 1);
    const it_slot: LocalSlot = @intCast(self.active_registers - 1);
    reserveRegisters(self, @intCast(it_slot + 1));

    // idx <- 0
    try self.emit(.load_small_int, 0);
    const idx_slot: LocalSlot = @intCast(self.active_registers - 1);
    try self.emit(.store_local, idx_slot);
    reserveRegisters(self, @intCast(idx_slot + 1));

    const needs_index = params.len == 2 and !ast.isDiscardName(params[1].name);
    var value_storage: ?VarStorage = null;
    var index_storage: ?VarStorage = null;
    if (!ast.isDiscardName(params[0].name)) {
        const value_slot = try state.declareLocal(self, params[0].name, false);
        value_storage = .{ .local = value_slot };
    }
    if (needs_index) {
        const index_slot = try state.declareLocal(self, params[1].name, false);
        index_storage = .{ .local = index_slot };
    }

    state.reserveLocalSlots(self);

    const loop_check: ProgramCounter = @intCast(self.irLen());

    // it() -> value | :none
    try self.emit(.load_local, it_slot);
    try self.emit(.call, 0);
    // check for :done
    try self.regDupe();
    try self.@"const"(Data.new.atom(try self.vm.internAtom("done")));
    try self.emit(.eq, 0);
    const end_jump = try self.jump(.jump_if_true);

    if (value_storage) |storage| {
        const value_slot: LocalSlot = @intCast(storage.local);
        state.markLocalInitialized(self, value_slot);
        try self.emit(.bind_local, value_slot);
    } else {
        try self.regRelease();
    }
    if (needs_index) {
        try self.emit(.load_local, idx_slot);
        if (index_storage) |storage| {
            const index_slot2: LocalSlot = @intCast(storage.local);
            state.markLocalInitialized(self, index_slot2);
            try self.emit(.bind_local, index_slot2);
        } else {
            try self.regRelease();
        }
    }

    state.reserveLocalSlots(self);

    try self.compile(body, true);

    // normalise result into loop result slot
    const body_result_reg: Register = @intCast(self.active_registers - 1);
    const loop_result_reg: Register = @intCast(self.loop_result_regs.items[self.loop_result_regs.items.len - 1]);
    if (body_result_reg != loop_result_reg) {
        try self.spans.append(self.alloc, self.active_span);
        try self.recordMove(loop_result_reg);
    }
    try self.regRelease();

    // idx += 1
    try self.emit(.load_local, idx_slot);
    try self.emit(.load_small_int, 1);
    try self.emit(.add, 0);
    try self.emit(.store_local, idx_slot);

    try self.emit(.jump, loop_check);

    self.patchJump(end_jump);

    self.active_registers = self.loop_result_regs.items[self.loop_result_regs.items.len - 1] + 1;
}

pub fn emitStorageLoad(self: *Compiler, storage: VarStorage) !void {
    switch (storage) {
        .local => |slot| try self.emit(.load_local, slot),
        .global => |sym| try self.emit(.load_global, sym),
    }
}

pub fn emitLoopRecurse(
    self: *Compiler,
    param_count: usize,
    loop_sym: revo.AtomID,
) !void {
    // `loop foo` tail-recurses, load args from result tuple, call, ret -- avoids stack growth
    const result_slot = self.slot_allocators.items[self.slot_allocators.items.len - 1];
    self.slot_allocators.items[self.slot_allocators.items.len - 1] += 1;
    if (self.max_registers < result_slot + 1) self.max_registers = result_slot + 1;

    if (param_count > 0) {
        try self.emit(.bind_local, result_slot);
    } else {
        try self.regRelease();
    }
    try self.emit(.load_global, loop_sym);

    if (param_count == 1) {
        try self.emit(.load_local, result_slot);
    } else if (param_count > 1) {
        for (0..param_count) |idx| { // unpack result tuple into args
            try self.emit(.load_local, result_slot);
            try self.emit(.tuple_get_const, idx);
        }
    }
    try self.emit(.call, @intCast(param_count));
    try self.emit(.ret, 1);
}

pub fn compileMatch(
    self: *Compiler,
    subject: *const Node,
    arms: []const ast.MatchArm,
) !void {
    if (state.currentFunctionState(self) == null)
        return self.fail(.UnsupportedSyntax, subject, "match requires function scope");

    const saved_next_slot = self.slot_allocators.items[self.slot_allocators.items.len - 1];
    const saved_active = self.active_registers;
    const saved_max = self.max_registers;

    try state.pushScope(self);
    errdefer state.popScope(self);
    errdefer {
        self.active_registers = saved_active;
        self.max_registers = saved_max;
        self.slot_allocators.items[self.slot_allocators.items.len - 1] = saved_next_slot;
    }

    // evaluated once, loaded per arm
    const subject_slot = try state.declareLocal(self, "__match_subject", false);
    try self.compile(subject, true);
    state.markLocalInitialized(self, subject_slot);
    try self.emit(.bind_local, subject_slot);
    state.reserveLocalSlots(self);

    const arm_base_registers = self.active_registers;
    const subject_storage: VarStorage = .{ .local = subject_slot };

    var end_jumps = try std.ArrayList(usize).initCapacity(self.alloc, arms.len);
    defer end_jumps.deinit(self.alloc);

    for (arms) |arm| {
        self.active_registers = arm_base_registers;

        try state.pushScope(self);
        errdefer state.popScope(self);

        const matcher_expr: ?*const Node = switch (arm.matchers[0]) {
            .wildcard => null,
            .expr => |e| e,
        };

        const fail_jumps = try compilePatternChecks(self, subject_storage, matcher_expr);
        var fail_list = try std.ArrayList(usize).initCapacity(self.alloc, fail_jumps.len + 1);
        defer fail_list.deinit(self.alloc);
        try fail_list.appendSlice(self.alloc, fail_jumps);
        self.alloc.free(fail_jumps);

        if (matcher_expr) |me| {
            if (subject.expr == .ident) {
                if (patternTypeInfo(self, me)) |ti| {
                    try state.setLocalTypeHint(self, subject.expr.ident, ti);
                }
            }
            try bindMatchPattern(self, me, subject_storage);
        }

        if (arm.guard) |guard| {
            try self.compile(guard, true);
            const guard_jump = try self.jump(.jump_if_false);
            try fail_list.append(self.alloc, guard_jump);
        }

        try self.compile(arm.then, true);

        // move arm result to arm_base_registers, all arms must leave stack at same depth
        const arm_result_reg: Register = @intCast(self.active_registers - 1);
        if (arm_result_reg != arm_base_registers) {
            try self.spans.append(self.alloc, self.active_span);
            _ = try self.record(.move, &.{.{ .reg = arm_result_reg }}, true, try toRegister(arm_base_registers), 0);
        }
        try self.regRelease();
        self.active_registers = arm_base_registers + 1;

        const end_jump = try self.jump(.jump);
        try end_jumps.append(self.alloc, end_jump);

        state.popScope(self);

        const next_arm = self.irLen();
        for (fail_list.items) |jump_idx| self.patchJumpToLabel(jump_idx, next_arm);
    }
    state.popScope(self);

    // reclaim subject slot
    self.slot_allocators.items[self.slot_allocators.items.len - 1] = saved_next_slot;

    self.active_registers = arm_base_registers;
    try self.pushNil(); // fallthrough when no arm matched
    for (end_jumps.items) |jump_idx| self.patchJump(jump_idx);

    self.active_registers = arm_base_registers + 1;
}

pub fn reserveRegisters(self: *Compiler, min_register: Register) void {
    // bumps slot allocator and active/max, no reuse of live register
    const min_slot: LocalSlot = @intCast(min_register);
    if (self.slot_allocators.items.len > 0) {
        if (self.slot_allocators.items[self.slot_allocators.items.len - 1] < min_slot) {
            self.slot_allocators.items[self.slot_allocators.items.len - 1] = min_slot;
        }
    }
    if (self.active_registers < min_slot) self.active_registers = min_slot;
    if (self.max_registers < min_slot) self.max_registers = min_slot;
}

pub fn bindMatchPattern(
    self: *Compiler,
    matcher: *const Node,
    subject: VarStorage,
) !void {
    switch (matcher.expr) {
        .ident => |name| {
            if (ast.isDiscardName(name)) return;
            try emitStorageLoad(self, subject);
            const slot = try state.declareLocal(self, name, true);
            state.markLocalInitialized(self, slot);
            try self.emit(.bind_local, slot);
            state.reserveLocalSlots(self);
        },
        .tuple_pattern => try bindMatchTuplePattern(self, matcher, subject),
        else => {},
    }
}

pub fn bindMatchTuplePattern(
    self: *Compiler,
    pattern: *const Node,
    source: VarStorage,
) !void {
    switch (pattern.expr) {
        .ident => |name| {
            if (ast.isDiscardName(name)) return;
            try emitStorageLoad(self, source);
            const slot = try state.declareLocal(self, name, true);
            state.markLocalInitialized(self, slot);
            try self.emit(.bind_local, slot);
            state.reserveLocalSlots(self);
        },
        .tuple_pattern => |items| {
            for (items, 0..) |item, idx| {
                switch (item.expr) {
                    .ident => |name| {
                        if (ast.isDiscardName(name)) continue;
                        try emitStorageLoad(self, source);
                        try self.emit(.tuple_get_const, idx);
                        const slot = try state.declareLocal(self, name, true);
                        state.markLocalInitialized(self, slot);
                        try self.emit(.bind_local, slot);
                        state.reserveLocalSlots(self);
                    },
                    .tuple_pattern => {
                        try emitStorageLoad(self, source);
                        try self.emit(.tuple_get_const, idx);
                        // temp for nested pattern
                        const nested_slot = try state.declareLocal(self, "__bind_tmp", false);
                        state.markLocalInitialized(self, nested_slot);
                        try self.emit(.bind_local, nested_slot);
                        state.reserveLocalSlots(self);
                        try bindMatchTuplePattern(self, item, .{ .local = nested_slot });
                    },
                    else => {},
                }
            }
        },
        else => {},
    }
}

pub fn compilePatternChecks(
    self: *Compiler,
    subject: VarStorage,
    matcher: ?*const Node,
) ![]usize {
    var fail_jumps = try std.ArrayList(usize).initCapacity(self.alloc, 4);
    const expr = matcher orelse return fail_jumps.toOwnedSlice(self.alloc);

    switch (expr.expr) {
        .ident => {}, // always matches
        .tuple_pattern => |items| {
            // type check, then length, then each element
            try self.emit(.load_global, try self.vm.internAtom("type"));
            try emitStorageLoad(self, subject);
            try self.emit(.call, 1);
            try self.@"const"(Data.new.atom(try self.vm.internAtom("tuple")));
            try self.emit(.eq, 0);
            try fail_jumps.append(self.alloc, try self.jump(.jump_if_false));

            try self.emit(.load_global, try self.vm.internAtom("len"));
            try emitStorageLoad(self, subject);
            try self.emit(.call, 1);
            try self.@"const"(Data.new.num(items.len));
            try self.emit(.eq, 0);
            try fail_jumps.append(self.alloc, try self.jump(.jump_if_false));

            for (items, 0..) |item, idx| {
                switch (item.expr) {
                    .ident => |name| if (ast.isDiscardName(name)) continue,
                    else => {},
                }
                const depth_before = self.active_registers;
                const slot_before = self.slot_allocators.items[self.slot_allocators.items.len - 1];
                try emitStorageLoad(self, subject);
                try self.emit(.tuple_get_const, idx);
                // avoids re-indexing in nested checks
                const nested_slot = try state.declareLocal(self, "__match_tmp", false);
                state.markLocalInitialized(self, nested_slot);
                try self.emit(.bind_local, nested_slot);
                state.reserveLocalSlots(self);
                const nested_fails = try compilePatternChecks(self, .{ .local = nested_slot }, item);
                for (nested_fails) |jump_idx| try fail_jumps.append(self.alloc, jump_idx);
                self.alloc.free(nested_fails);
                self.active_registers = depth_before;
                self.slot_allocators.items[self.slot_allocators.items.len - 1] = slot_before;
            }
        },
        else => {
            // literal or expression; evaluate and compare
            try emitStorageLoad(self, subject);
            try self.compile(expr, true);
            try self.emit(.eq, 0);
            try fail_jumps.append(self.alloc, try self.jump(.jump_if_false));
        },
    }
    return fail_jumps.toOwnedSlice(self.alloc);
}

pub fn compileIf(
    self: *Compiler,
    condition: *const Node,
    then_expr: *const Node,
    else_expr: ?*Node,
) !void {
    if (state.currentFunctionState(self) == null)
        return self.fail(.UnsupportedSyntax, condition, "if requires function scope");

    const saved_next_slot = self.slot_allocators.items[self.slot_allocators.items.len - 1];
    const saved_active = self.active_registers;
    const saved_max = self.max_registers;
    errdefer {
        self.active_registers = saved_active;
        self.max_registers = saved_max;
        self.slot_allocators.items[self.slot_allocators.items.len - 1] = saved_next_slot;
    }

    try self.compile(condition, true);
    const else_jump = try self.jump(.jump_if_false);
    const branch_base_registers = self.active_registers;

    try state.pushScope(self);
    errdefer state.popScope(self);
    if (conditionTypeHint(condition)) |hint| {
        try state.setLocalTypeHint(self, hint.name, hint.type_info);
    }
    try self.compile(then_expr, true);
    state.popScope(self);
    const then_registers = self.active_registers;
    const end_jump = try self.jump(.jump);
    self.patchJump(else_jump);
    self.active_registers = branch_base_registers; // reset before else so both branches start at same depth

    try state.pushScope(self);
    errdefer state.popScope(self);
    if (else_expr) |branch| {
        try self.compile(branch, true);
        _ = type_check.inferExprType(self, branch);
    } else try self.pushNil();
    state.popScope(self);

    if (then_registers != self.active_registers) {
        // then-branch may differ from that nil
        while (self.active_registers < then_registers)
            try self.pushNil();
        while (self.active_registers > then_registers)
            try self.regRelease();
    }
    self.patchJump(end_jump);
}

fn conditionTypeHint(condition: *const Node) ?TypeHint {
    return switch (condition.expr) {
        .call => |call| blk: {
            if (call.args.len != 1 or call.callee.expr != .ident or !std.mem.endsWith(u8, call.callee.expr.ident, "?")) break :blk null;
            if (call.args[0].expr != .ident) break :blk null;
            const type_info = if (std.mem.eql(u8, call.callee.expr.ident, "number?"))
                typeNameInfo("number")
            else if (std.mem.eql(u8, call.callee.expr.ident, "string?"))
                typeNameInfo("string")
            else if (std.mem.eql(u8, call.callee.expr.ident, "bool?"))
                typeNameInfo("bool")
            else if (std.mem.eql(u8, call.callee.expr.ident, "table?"))
                typeNameInfo("table")
            else
                null;
            const unwrapped = type_info orelse break :blk null;
            break :blk .{ .name = call.args[0].expr.ident, .type_info = unwrapped };
        },
        .binary => |b| blk: {
            if (b.op != .eq) break :blk null;
            const left = typeCompareHint(b.left, b.right) orelse typeCompareHint(b.right, b.left) orelse break :blk null;
            break :blk left;
        },
        else => null,
    };
}

fn typeCompareHint(type_expr: *const Node, value_expr: *const Node) ?TypeHint {
    if (type_expr.expr != .call) return null;
    const call = type_expr.expr.call;
    if (call.args.len != 1 or call.callee.expr != .ident) return null;
    if (!std.mem.eql(u8, call.callee.expr.ident, "type")) return null;
    if (call.args[0].expr != .ident) return null;
    if (value_expr.expr != .hash) return null;
    const type_info = typeNameInfo(value_expr.expr.hash) orelse return null;
    return .{ .name = call.args[0].expr.ident, .type_info = type_info };
}

fn typeNameInfo(name: []const u8) ?types_mod.TypeInfo {
    if (std.mem.eql(u8, name, "number")) return .{
        .@"union" = &.{
            .{ .name = "", .types = &.{.int} },
            .{ .name = "", .types = &.{.float} },
        },
    };
    if (std.mem.eql(u8, name, "string")) return .string;
    if (std.mem.eql(u8, name, "bool")) return .bool;
    if (std.mem.eql(u8, name, "table")) return .{ .struct_type = "table" };
    return null;
}

fn patternTypeInfo(self: *Compiler, pattern: *const Node) ?types_mod.TypeInfo {
    return switch (pattern.expr) {
        .number => |n| if (n.is_float) .float else .int,
        .string, .multiline_string => .string,
        .hash => |name| .{ .atom = name },
        .tuple_pattern => |items| blk: {
            var types = std.ArrayList(types_mod.TypeInfo).initCapacity(self.alloc, items.len) catch break :blk null;
            defer types.deinit(self.alloc);
            for (items) |item| {
                types.append(self.alloc, patternTypeInfo(self, item) orelse .any) catch break :blk null;
            }
            const tuple_items = types.toOwnedSlice(self.alloc) catch break :blk null;
            break :blk types_mod.TypeInfo{ .tuple = tuple_items };
        },
        else => null,
    };
}

pub fn compileAnd(self: *Compiler, left: *const Node, right: *const Node) !void {
    // short-circuit: false left skips right, returns left
    try self.compile(left, true);
    try self.regDupe();
    const short = try self.jump(.jump_if_false);
    try self.regRelease();
    try self.compile(right, true);
    const end = try self.jump(.jump);
    self.patchJump(short);
    self.patchJump(end);
}

pub fn compileOr(self: *Compiler, left: *const Node, right: *const Node) !void {
    // short-circuit: true left skips right, returns left
    try self.compile(left, true);
    try self.regDupe();
    const short = try self.jump(.jump_if_true);
    try self.regRelease();
    try self.compile(right, true);
    const end = try self.jump(.jump);
    self.patchJump(short);
    self.patchJump(end);
}

pub fn compileBreak(self: *Compiler, expr: *const Node, value: ?*const Node) !void {
    if (self.in_loop_depth == 0) {
        return self.fail(.UnsupportedSyntax, expr, "break is only valid inside loop");
    }
    if (self.loop_result_regs.items.len <= 0) return;

    if (value) |v| try self.compile(v, true) else try self.pushNil();

    const r = self.active_registers - 1;
    const loop_res = self.loop_result_regs.items[self.loop_result_regs.items.len - 1];
    // round-trip: value must be in both the result slot and the stack top callers expect
    try self.spans.append(self.alloc, self.active_span);
    _ = try self.record(.move, &.{.{ .reg = try toRegister(r) }}, true, try toRegister(loop_res), 0);
    try self.spans.append(self.alloc, self.active_span);
    _ = try self.record(.move, &.{.{ .reg = try toRegister(loop_res) }}, true, try toRegister(r), 0);
    const jump_idx = try self.jump(.jump);
    try self.break_jumps.append(self.alloc, jump_idx);
}
