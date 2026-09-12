const std = @import("std");

const revo = @import("revo");
const Compiler = revo.lang.compiler.Compiler;
const Data = revo.Data;
const ProgramCounter = revo.ProgramCounter;
const Operand = revo.Operand;
const Opcode = revo.opcode.Opcode;
const Register = revo.opcode.Register;
const LocalSlot = revo.LocalSlot;

const ast = @import("../ast.zig");
const Node = ast.Node;
const ir = @import("../ir/root.zig");
const state = @import("state.zig");
const toRegister = state.toRegister;
const TypeHint = state.FunctionState.TypeHint;
const type_check = @import("type_check.zig");
const type_serde = @import("../type_serde.zig");
const types_mod = @import("types.zig");

pub const VarStorage = union(enum) {
    local: Operand,
    global: revo.AtomID,
};

fn normalizeLoopResult(self: *Compiler) !void {
    const body_result: Register = @intCast(self.active_registers - 1);
    const loop_result: Register = self.loop_stack.items[self.loop_stack.items.len - 1].result_reg;

    if (body_result != loop_result) {
        try self.spans.append(self.alloc, self.active_span);
        _ = try self.record(.move, &.{.{ .reg = body_result }}, true, loop_result, 0);
    }

    try self.regRelease();
}

pub fn compileLoop(self: *Compiler, body: *const Node, label: ?[]const u8) !void {
    const LoopScopeT = state.LoopScope(@TypeOf(self.*));
    var loop = try LoopScopeT.init(self, label);
    defer loop.deinit();

    const loop_start: ProgramCounter = @intCast(self.irLen());
    self.loop_stack.items[self.loop_stack.items.len - 1].continue_target = loop_start;
    try self.compile(body, true);
    try self.regRelease();
    try self.emit(.jump, loop_start);
    // result visible to next binding
    self.active_registers = self.loop_stack.items[self.loop_stack.items.len - 1].result_reg + 1;
}

pub fn compileWhile(
    self: *Compiler,
    predicate: *const Node,
    body: *const Node,
    label: ?[]const u8,
) !void {
    const LoopScopeT = state.LoopScope(@TypeOf(self.*));
    var loop = try LoopScopeT.init(self, label);
    defer loop.deinit();

    const loop_start: ProgramCounter = @intCast(self.irLen());
    self.loop_stack.items[self.loop_stack.items.len - 1].continue_target = loop_start;
    try self.compile(predicate, true);
    const exit_jump = try self.jump(.jump_if_false);
    try self.compile(body, true);

    try normalizeLoopResult(self);
    try self.emit(.jump, loop_start);

    self.patchJump(exit_jump);
    // same as compileLoop
    self.active_registers = self.loop_stack.items[self.loop_stack.items.len - 1].result_reg + 1;
}

pub fn compileForRange(
    self: *Compiler,
    params: []const ast.FnParam,
    body: *const Node,
    start_expr: *const Node,
    step_expr: *const Node,
    end_expr: *const Node,
    label: ?[]const u8,
) !void {
    const LoopScopeT = state.LoopScope(@TypeOf(self.*));
    var loop = try LoopScopeT.init(self, label);
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
    self.active_registers = self.loop_stack.items[self.loop_stack.items.len - 1].result_reg + 1;
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

    // slots don't overlap with temporaries from enclosing call/expressions
    if (self.slot_allocators.items.len > 0) {
        const idx = self.slot_allocators.items.len - 1;
        if (self.slot_allocators.items[idx] < self.active_registers) {
            self.slot_allocators.items[idx] = @intCast(self.active_registers);
        }
    }

    // declare before loop_check so range_loop can fill them each iteration
    if (params.len >= 1 and !ast.isDiscardName(params[0].name)) {
        value_slot = try state.declareLocal(self, params[0].name, false);
        if (params[0].type_name) |tn| {
            const declared = try type_serde.evalTypeExpr(self, tn);
            if (declared.tag != .number) {
                const msg = try std.fmt.allocPrint(
                    self.alloc,
                    "range loop variable must be num, got {s}",
                    .{@tagName(declared.tag)},
                );
                try self.appendFailureReport(.ParseError, &.{.{ .@"error" = msg }});
                return error.LoweringFailed;
            }
        }
        state.setLocalType(self, value_slot.?, .{ .tag = .number });
        try state.setLocalTypeHint(self, params[0].name, .{ .tag = .number });
    }
    if (params.len == 2 and !ast.isDiscardName(params[1].name)) {
        index_slot = try state.declareLocal(self, params[1].name, false);
        if (params[1].type_name) |tn| {
            const declared = try type_serde.evalTypeExpr(self, tn);
            if (declared.tag != .number) {
                const msg = try std.fmt.allocPrint(
                    self.alloc,
                    "range loop variable must be num, got {s}",
                    .{@tagName(declared.tag)},
                );
                try self.appendFailureReport(.ParseError, &.{.{ .@"error" = msg }});
                return error.LoweringFailed;
            }
        }
        state.setLocalType(self, index_slot.?, .{ .tag = .number });
        try state.setLocalTypeHint(self, params[1].name, .{ .tag = .number });
    }

    // L_body: the top of the loop body, where range_loop backbranches
    const value_reg = try toRegister(self.active_registers);
    const index_reg = if (needs_index) try toRegister(self.active_registers + 1) else 0;

    // value (and index) live across the whole loop; the bottom range_loop
    // rewrites them right before each iteration's bind
    const n: usize = if (needs_index) 2 else 1;
    self.active_registers += n;
    if (self.active_registers > self.max_registers) self.max_registers = self.active_registers;

    // entry: skip the body, land on the bottom range check
    const entry_jump = try self.jump(.jump);

    const loop_check: ProgramCounter = @intCast(self.irLen());

    // drain the LoopScope result load_nil that used to feed jump_if_false
    _ = try self.pop();

    if (value_slot) |slot| {
        state.markLocalInitialized(self, slot);
        try self.emitBind(.bind_local, slot, value_reg);
    }

    if (index_slot) |slot| {
        state.markLocalInitialized(self, slot);
        try self.emitBind(.bind_local, slot, index_reg);
    }

    if (needs_index) try self.regRelease();
    try self.regRelease();

    const loop_state_end = try toRegister(state_reg + 3);
    reserveRegisters(self, loop_state_end); // pin range state so body can't clobber it

    try self.compile(body, true);

    try normalizeLoopResult(self);

    // L_check: bottom-tested range check with fused backbranch
    const check_idx: ProgramCounter = @intCast(self.irLen());
    try self.spans.append(self.alloc, self.active_span);
    const ops: []const ir.IrValue = if (needs_index) &.{.{ .reg = index_reg }} else &.{};
    _ = try self.record(.range_loop, ops, false, value_reg, loop_check);
    self.loop_stack.items[self.loop_stack.items.len - 1].continue_target = check_idx;
    self.patchJumpToLabel(entry_jump, check_idx);

    // reverse order: index (if used), value, range state (3 regs)
    if (needs_index) try self.regRelease();
    try self.regRelease();
    try self.regRelease();
    try self.regRelease();
    try self.regRelease();
}

pub fn compileFor(
    self: *Compiler,
    params: []const ast.FnParam,
    body: *const Node,
    iter: *const Node,
    label: ?[]const u8,
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
        return compileForRange(self, params, body, range_info.start, range_info.step, range_info.end, label);
    }

    const LoopScopeT = state.LoopScope(@TypeOf(self.*));
    var loop = try LoopScopeT.init(self, label);
    defer loop.deinit();

    // wrap expression with to_iter
    try self.emit(.load_global, revo.core_atoms.to_iter.atomId());
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
    self.loop_stack.items[self.loop_stack.items.len - 1].continue_target = loop_check;

    // it() -> value | :none
    try self.emit(.load_local, it_slot);
    try self.emit(.call, 0);
    // check for :done
    try self.regDupe();
    try self.@"const"(Data.new.atom(revo.core_atoms.done.atomId()));
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

    try normalizeLoopResult(self);

    // idx += 1
    try self.emit(.load_local, idx_slot);
    try self.emit(.load_small_int, 1);
    try self.emit(.add, 0);
    try self.emit(.store_local, idx_slot);

    try self.emit(.jump, loop_check);

    self.patchJump(end_jump);

    self.active_registers = self.loop_stack.items[self.loop_stack.items.len - 1].result_reg + 1;
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
    // `loop foo` tail-recurses, load args from result table, call, ret -- avoids stack growth
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
        for (0..param_count) |idx| { // unpack result table into args
            try self.emit(.load_local, result_slot);
            try self.emit(.load_small_int, idx);
            try self.emit(.table_get, 0);
        }
    }
    try self.emit(.call, @intCast(param_count));
    try self.emit(.ret, 1);
}

const RegisterState = struct {
    next_slot: LocalSlot,
    active: usize,
    max: usize,
};

fn saveRegState(self: *Compiler) RegisterState {
    return .{
        .next_slot = self.slot_allocators.items[self.slot_allocators.items.len - 1],
        .active = self.active_registers,
        .max = self.max_registers,
    };
}

fn restoreRegState(self: *Compiler, s: RegisterState) void {
    self.active_registers = s.active;
    self.max_registers = s.max;
    self.slot_allocators.items[self.slot_allocators.items.len - 1] = s.next_slot;
}

pub fn compileMatch(
    self: *Compiler,
    subject: *const Node,
    arms: []const ast.MatchArm,
) !void {
    if (state.currentFunctionState(self) == null)
        return self.fail(.UnsupportedSyntax, subject, "match requires function scope");

    const saved = saveRegState(self);

    try state.pushScope(self);
    errdefer state.popScope(self);
    errdefer restoreRegState(self, saved);

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
            // capture subject type before patternTypeInfo overwrites the hint
            const pre_narrow_subject_type = type_check.inferExprType(self, subject);
            if (subject.expr == .ident) {
                if (patternTypeInfo(self, me)) |ti| {
                    try state.setLocalTypeHint(self, subject.expr.ident, ti);
                }
            }
            try bindMatchPattern(self, me, subject_storage);
            try narrowMatchPattern(self, me, pre_narrow_subject_type);
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
    self.slot_allocators.items[self.slot_allocators.items.len - 1] = saved.next_slot;

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
        .table_pattern => |items| {
            for (items, 0..) |item, idx| {
                switch (item.expr) {
                    .ident => |name| {
                        if (ast.isDiscardName(name)) continue;
                        try emitStorageLoad(self, subject);
                        try self.emit(.load_small_int, idx);
                        try self.emit(.table_get, 0);

                        const slot = try state.declareLocal(self, name, true);
                        state.markLocalInitialized(self, slot);
                        try self.emit(.bind_local, slot);

                        state.reserveLocalSlots(self);
                    },
                    .table_pattern, .ascribed => {
                        try emitStorageLoad(self, subject);
                        try self.emit(.load_small_int, idx);
                        try self.emit(.table_get, 0);

                        // temp for nested pattern
                        const nested_slot = try state.declareLocal(self, "__bind_tmp", false);
                        state.markLocalInitialized(self, nested_slot);
                        try self.emit(.bind_local, nested_slot);
                        state.reserveLocalSlots(self);

                        try bindMatchPattern(self, item, .{ .local = nested_slot });
                    },
                    else => {},
                }
            }
        },
        .ascribed => |a| try bindMatchPattern(self, a.expr, subject),
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
        .ascribed => |a| {
            // type check first, then the inner pattern
            //   ; fail fast
            const asc_ti = type_serde.evalTypeExpr(self, a.type_name) catch types_mod.TypeInfo{ .tag = .any };

            const type_fails = try compileTypeSatisfies(self, subject, asc_ti);
            defer self.alloc.free(type_fails);
            try fail_jumps.appendSlice(self.alloc, type_fails);

            const inner_fails = try compilePatternChecks(self, subject, a.expr);
            defer self.alloc.free(inner_fails);
            try fail_jumps.appendSlice(self.alloc, inner_fails);
        },
        .table_pattern => |items| {
            // type check
            //  , then array length
            //  , then each element
            try self.emit(.load_global, revo.core_atoms.type.atomId());
            try emitStorageLoad(self, subject);
            try self.emit(.call, 1);
            try self.@"const"(Data.new.atom(try self.vm.internAtom("table")));
            try self.emit(.eq, 0);
            try fail_jumps.append(self.alloc, try self.jump(.jump_if_false));

            // alen counts the array part only
            //  , hash entries don't matter
            try self.emit(.load_stdlib_global, try self.vm.internAtom("table"));
            try self.emit(.table_get_atom, try self.vm.internAtom("alen"));
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
                try self.emit(.load_small_int, idx);
                try self.emit(.table_get, 0);

                // to not reindex in nested checks
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
            // literal or expression
            //   ; evaluate & cmp
            try emitStorageLoad(self, subject);
            try self.compile(expr, true);
            try self.emit(.eq, 0);
            try fail_jumps.append(self.alloc, try self.jump(.jump_if_false));
        },
    }
    return fail_jumps.toOwnedSlice(self.alloc);
}

/// `type(x) == :name`
///   ; fail jump when not
fn jumpIfNotType(self: *Compiler, subject: VarStorage, name: []const u8) !usize {
    try self.emit(.load_global, revo.core_atoms.type.atomId());
    try emitStorageLoad(self, subject);
    try self.emit(.call, 1);
    try self.@"const"(Data.new.atom(try self.vm.internAtom(name)));
    try self.emit(.eq, 0);

    return try self.jump(.jump_if_false);
}

/// runtime check that the stored value satisfies a type
///   (`x: T` ascriptions)
/// ; fail jumps go to the next match arm
fn compileTypeSatisfies(
    self: *Compiler,
    subject: VarStorage,
    ti: types_mod.TypeInfo,
) ![]usize {
    var fail_jumps = try std.ArrayList(usize).initCapacity(self.alloc, 4);
    errdefer fail_jumps.deinit(self.alloc);

    switch (ti.tag) {
        .any, .type_var => {},
        .never => try fail_jumps.append(self.alloc, try self.jump(.jump)),
        .number => try fail_jumps.append(self.alloc, try jumpIfNotType(self, subject, "number")),
        .string => try fail_jumps.append(self.alloc, try jumpIfNotType(self, subject, "string")),
        .function => try fail_jumps.append(self.alloc, try jumpIfNotType(self, subject, "function")),
        .bool => {
            // bools are :true/:false atoms
            try emitStorageLoad(self, subject);
            try self.@"const"(Data.new.atom(try self.vm.internAtom("true")));
            try self.emit(.eq, 0);
            const ok_jump = try self.jump(.jump_if_true);

            try emitStorageLoad(self, subject);
            try self.@"const"(Data.new.atom(try self.vm.internAtom("false")));
            try self.emit(.eq, 0);
            try fail_jumps.append(self.alloc, try self.jump(.jump_if_false));

            self.patchJump(ok_jump);
        },
        .atom => |name| {
            if (name.len == 0) {
                try fail_jumps.append(self.alloc, try jumpIfNotType(self, subject, "atom"));
            } else {
                const base = ast.atomName(name);
                const want: Data = if (std.mem.eql(u8, base, "nil"))
                    Data.new.nil()
                else
                    Data.new.atom(try self.vm.internAtom(base));

                try emitStorageLoad(self, subject);
                try self.@"const"(want);
                try self.emit(.eq, 0);
                try fail_jumps.append(self.alloc, try self.jump(.jump_if_false));
            }
        },
        .table => |tbl| {
            try fail_jumps.append(self.alloc, try jumpIfNotType(self, subject, "table"));

            if (tbl.fields) |fields| {
                var max_pos: usize = 0;
                var has_pos = false;

                for (fields) |f| {
                    const idx = std.fmt.parseInt(usize, f.name, 10) catch continue;
                    has_pos = true;
                    if (idx + 1 > max_pos) max_pos = idx + 1;
                }

                // open subtyping like record coercion
                //   ; extras ok, so at-least
                if (has_pos) {
                    try self.emit(.load_stdlib_global, try self.vm.internAtom("table"));
                    try self.emit(.table_get_atom, try self.vm.internAtom("alen"));
                    try emitStorageLoad(self, subject);
                    try self.emit(.call, 1);
                    try self.@"const"(Data.new.num(max_pos));
                    try self.emit(.gte, 0);
                    try fail_jumps.append(self.alloc, try self.jump(.jump_if_false));
                }

                for (fields) |f| {
                    const depth_before = self.active_registers;
                    const slot_before = self.slot_allocators.items[self.slot_allocators.items.len - 1];

                    if (std.fmt.parseInt(usize, f.name, 10)) |idx| {
                        try emitStorageLoad(self, subject);
                        try self.emit(.load_small_int, idx);
                        try self.emit(.table_get, 0);

                        const nested_slot = try state.declareLocal(self, "__match_tmp", false);
                        state.markLocalInitialized(self, nested_slot);
                        try self.emit(.bind_local, nested_slot);
                        state.reserveLocalSlots(self);

                        const nested_fails = try compileTypeSatisfies(self, .{ .local = nested_slot }, f.field_type);
                        try fail_jumps.appendSlice(self.alloc, nested_fails);
                        self.alloc.free(nested_fails);
                    } else |_| {
                        // named fields must be present
                        //   ; missing reads as :undef
                        const key_atom = try self.vm.internAtom(f.name);
                        try emitStorageLoad(self, subject);
                        try self.emit(.table_get_atom, key_atom);

                        const nested_slot = try state.declareLocal(self, "__match_tmp", false);
                        state.markLocalInitialized(self, nested_slot);
                        try self.emit(.bind_local, nested_slot);
                        state.reserveLocalSlots(self);

                        const nested_storage: VarStorage = .{ .local = nested_slot };
                        try emitStorageLoad(self, nested_storage);
                        try self.@"const"(Data.new.core(.undef));
                        try self.emit(.eq, 0);
                        try fail_jumps.append(self.alloc, try self.jump(.jump_if_true));

                        const nested_fails = try compileTypeSatisfies(self, nested_storage, f.field_type);
                        try fail_jumps.appendSlice(self.alloc, nested_fails);
                        self.alloc.free(nested_fails);
                    }

                    self.active_registers = depth_before;
                    self.slot_allocators.items[self.slot_allocators.items.len - 1] = slot_before;
                }
            }
        },
        .@"union" => |us| {
            if (us.len == 0) {
                try fail_jumps.append(self.alloc, try self.jump(.jump));
            } else {
                // try each variant in turn
                //   ; only the last ones failures escape
                var ok_jumps = try std.ArrayList(usize).initCapacity(self.alloc, us.len);
                defer ok_jumps.deinit(self.alloc);

                for (us, 0..) |variant, i| {
                    var variant_fails = try std.ArrayList(usize).initCapacity(self.alloc, 4);
                    errdefer variant_fails.deinit(self.alloc);

                    if (variant.types.len == 1) {
                        const inner = try compileTypeSatisfies(self, subject, variant.types[0]);
                        try variant_fails.appendSlice(self.alloc, inner);
                        self.alloc.free(inner);
                    } else {
                        // empty and multi-type shapes gont satisfy
                        try variant_fails.append(self.alloc, try self.jump(.jump));
                    }

                    if (i + 1 < us.len) {
                        try ok_jumps.append(self.alloc, try self.jump(.jump));
                        const next = self.irLen();
                        for (variant_fails.items) |jump_idx| self.patchJumpToLabel(jump_idx, next);
                        variant_fails.deinit(self.alloc);
                    } else {
                        try fail_jumps.appendSlice(self.alloc, variant_fails.items);
                        variant_fails.deinit(self.alloc);
                    }
                }

                const done = self.irLen();
                for (ok_jumps.items) |jump_idx| self.patchJumpToLabel(jump_idx, done);
            }
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

    const saved = saveRegState(self);
    errdefer restoreRegState(self, saved);

    try self.compile(condition, true);
    const else_jump = try self.jump(.jump_if_false);
    const branch_base_registers = self.active_registers;
    const join_depth = self.value_stack.items.len;

    try state.pushScope(self);
    errdefer state.popScope(self);
    if (conditionTypeHint(condition)) |hint| {
        try state.setLocalTypeHint(self, hint.name, hint.type_info);
    }
    try self.compile(then_expr, true);
    state.popScope(self);
    const then_registers = self.active_registers;

    // both paths must leave the if expr's value in the shared branch
    // register; single-expression branches go there by themselves, but
    // do/stmt blocks push their value in a fresh register, so copy
    // it into place before jumping to the join
    if (self.value_stack.items.len > join_depth) {
        const then_val = self.value_stack.items[self.value_stack.items.len - 1];
        if (then_val.result_reg != branch_base_registers) {
            try self.spans.append(self.alloc, self.active_span);
            _ = try self.record(.move, &.{.{ .inst = then_val }}, true, @intCast(branch_base_registers), 0);
        }
    }

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

    // same normalization for the else path, emitted at the join so the
    // then path (which jumped past it) is unaffected
    if (self.value_stack.items.len > join_depth) {
        const else_val = self.value_stack.items[self.value_stack.items.len - 1];
        if (else_val.result_reg != branch_base_registers) {
            try self.spans.append(self.alloc, self.active_span);
            _ = try self.record(.move, &.{.{ .inst = else_val }}, true, @intCast(branch_base_registers), 0);
        }
    }

    if (then_registers != self.active_registers) {
        // equalize, push nils if else was shorter, then clamp
        while (self.active_registers < then_registers)
            try self.pushNil();
        self.active_registers = then_registers;
    }
    self.patchJump(end_jump);
}

pub fn compileUnless(
    self: *Compiler,
    condition: *const Node,
    then_expr: *const Node,
    else_expr: ?*Node,
) !void {
    if (state.currentFunctionState(self) == null)
        return self.fail(.UnsupportedSyntax, condition, "unless requires function scope");

    const saved = saveRegState(self);
    errdefer restoreRegState(self, saved);

    try self.compile(condition, true);
    const else_jump = try self.jump(.jump_if_true);
    const branch_base_registers = self.active_registers;
    const join_depth = self.value_stack.items.len;

    try state.pushScope(self);
    errdefer state.popScope(self);
    if (conditionTypeHint(condition)) |hint| {
        try state.setLocalTypeHint(self, hint.name, hint.type_info);
    }
    try self.compile(then_expr, true);
    state.popScope(self);
    const then_registers = self.active_registers;

    // both paths must leave the if expr's value in the shared branch
    // register; single-expression branches go there by themselves, but
    // do/stmt blocks push their value in a fresh register, so copy
    // it into place before jumping to the join
    if (self.value_stack.items.len > join_depth) {
        const then_val = self.value_stack.items[self.value_stack.items.len - 1];
        if (then_val.result_reg != branch_base_registers) {
            try self.spans.append(self.alloc, self.active_span);
            _ = try self.record(.move, &.{.{ .inst = then_val }}, true, @intCast(branch_base_registers), 0);
        }
    }

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

    // same normalization for the else path, emitted at the join so the
    // then path (which jumped past it) is unaffected
    if (self.value_stack.items.len > join_depth) {
        const else_val = self.value_stack.items[self.value_stack.items.len - 1];
        if (else_val.result_reg != branch_base_registers) {
            try self.spans.append(self.alloc, self.active_span);
            _ = try self.record(.move, &.{.{ .inst = else_val }}, true, @intCast(branch_base_registers), 0);
        }
    }

    if (then_registers != self.active_registers) {
        // equalize, push nils if else was shorter, then clamp
        while (self.active_registers < then_registers)
            try self.pushNil();
        self.active_registers = then_registers;
    }
    self.patchJump(end_jump);
}

fn conditionTypeHint(condition: *const Node) ?TypeHint {
    return switch (condition.expr) {
        .call => |call| blk: {
            if (call.args.len != 1 or call.callee.expr != .ident or
                !std.mem.endsWith(u8, call.callee.expr.ident, "?")) break :blk null;
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
            const left = typeCompareHint(b.left, b.right) orelse typeCompareHint(
                b.right,
                b.left,
            ) orelse break :blk null;

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
    if (std.mem.eql(u8, name, "num") or std.mem.eql(u8, name, "number")) return .{
        .tag = .{ .@"union" = &.{
            .{ .name = "", .types = &.{.{ .tag = .number }} },
            .{ .name = "", .types = &.{.{ .tag = .number }} },
        } },
    };
    return types_mod.type_name_map.get(name);
}

fn patternTypeInfo(self: *Compiler, pattern: *const Node) ?types_mod.TypeInfo {
    return switch (pattern.expr) {
        .ascribed => |a| type_serde.evalTypeExpr(self, a.type_name) catch null,
        .number => .{ .tag = .number },
        .string, .multiline_string => .{ .tag = .string },
        .hash => |name| .{ .tag = .{ .atom = name } },
        .table_pattern => |items| blk: {
            var fields = std.ArrayList(types_mod.RecordField).initCapacity(self.alloc, items.len) catch break :blk null;
            defer fields.deinit(self.alloc);

            for (items, 0..) |item, idx| {
                var buf: [16]u8 = undefined;
                const name = std.fmt.bufPrint(&buf, "{d}", .{idx}) catch break :blk null;
                const owned = self.alloc.dupe(u8, name) catch break :blk null;

                fields.append(self.alloc, .{
                    .name = owned,
                    .field_type = patternTypeInfo(self, item) orelse types_mod.TypeInfo{ .tag = .any },
                }) catch break :blk null;
            }

            const owned_fields = fields.toOwnedSlice(self.alloc) catch break :blk null;
            const value_ptr = self.alloc.create(types_mod.TypeInfo) catch break :blk null;

            value_ptr.* = .{ .tag = .any };
            break :blk types_mod.makeTable(null, value_ptr, owned_fields);
        },
        .ident => |name| {
            // look up the variable type from hints or local state
            // // and type narrowing from variable names is handled somewher else
            _ = name;
            return null;
        },
        .nil => .{ .tag = .{ .atom = ":nil" } },
        else => null,
    };
}

/// narrow pattern variables by subject's union type:
///     `| {:ok, v} =>`
///     narrows `v` to the payload
///     type of the `:ok` variant
fn narrowMatchPattern(
    self: *Compiler,
    pattern: *const Node,
    subject_type: types_mod.TypeInfo,
) !void {
    // ascriptions apply regardless of subject type
    //   ; and win over union narrowing
    if (pattern.expr == .ascribed) {
        const a = pattern.expr.ascribed;

        if (a.expr.expr == .ident and !ast.isDiscardName(a.expr.expr.ident)) {
            const ti = type_serde.evalTypeExpr(self, a.type_name) catch types_mod.TypeInfo{ .tag = .any };
            try state.setLocalTypeHint(self, a.expr.expr.ident, ti);

            return;
        }

        return try narrowMatchPattern(self, a.expr, subject_type);
    }

    const items = switch (pattern.expr) {
        .table_pattern => |items| items,
        else => return,
    };

    // ascribed items narrow from their annotation
    //   ; whatever the subject
    for (items) |item| {
        if (item.expr != .ascribed) continue;
        const a = item.expr.ascribed;

        if (a.expr.expr == .ident and !ast.isDiscardName(a.expr.expr.ident)) {
            const ti = type_serde.evalTypeExpr(self, a.type_name) catch types_mod.TypeInfo{ .tag = .any };
            try state.setLocalTypeHint(self, a.expr.expr.ident, ti);
        }
    }

    if (subject_type.tag != .@"union") return;

    if (items.len == 0) return;

    const first = items[0];
    const tag = if (first.expr == .hash) first.expr.hash else return;

    for (subject_type.tag.@"union") |variant| {
        if (!types_mod.unionVariantTagEql(variant, tag)) continue;
        var payload = std.ArrayList(types_mod.TypeInfo).initCapacity(self.alloc, 4) catch return;
        defer payload.deinit(self.alloc);
        try types_mod.appendUnionVariantPayload(self.alloc, variant, &payload);

        for (items[1..], 0..) |item, i| {
            // ascriptions win over the union payload
            //   ; for the names they cover
            if (item.expr == .ascribed) {
                const a = item.expr.ascribed;

                if (a.expr.expr == .ident and !ast.isDiscardName(a.expr.expr.ident)) {
                    const ti = type_serde.evalTypeExpr(self, a.type_name) catch types_mod.TypeInfo{ .tag = .any };
                    try state.setLocalTypeHint(self, a.expr.expr.ident, ti);
                }

                continue;
            }

            if (item.expr == .ident and !ast.isDiscardName(item.expr.ident)) {
                const narrowed = if (i < payload.items.len) payload.items[i] else types_mod.TypeInfo{ .tag = .any };
                try state.setLocalTypeHint(self, item.expr.ident, narrowed);
            }
        }
        return;
    }
}

fn compileShortCircuit(self: *Compiler, left: *const Node, right: *const Node, short_op: Opcode) !void {
    try self.compile(left, true);
    try self.regDupe();
    const short = try self.jump(short_op);

    try self.regRelease();
    const left_inst = try self.pop();

    try self.compile(right, true);
    const end = try self.jump(.jump);

    self.patchJump(short);
    self.patchJump(end);
    try self.value_stack.append(self.alloc, left_inst);
}

pub fn compileAnd(self: *Compiler, left: *const Node, right: *const Node) !void {
    try compileShortCircuit(self, left, right, .jump_if_false);
}

pub fn compileOr(self: *Compiler, left: *const Node, right: *const Node) !void {
    try compileShortCircuit(self, left, right, .jump_if_true);
}

fn findLoopFrame(self: *Compiler, label: ?[]const u8) !?*state.LoopFrame {
    const fn_index = self.functions.items.len;
    if (label) |lbl| {
        var i: usize = self.loop_stack.items.len;
        while (i > 0) {
            i -= 1;
            const frame = &self.loop_stack.items[i];
            if (frame.function_index != fn_index) continue;
            if (std.mem.eql(u8, frame.label orelse "", lbl)) return frame;
        }
        return null;
    }
    var i: usize = self.loop_stack.items.len;
    while (i > 0) {
        i -= 1;
        const frame = &self.loop_stack.items[i];
        if (frame.function_index == fn_index) return frame;
    }
    return null;
}

pub fn compileBreak(self: *Compiler, expr: *const Node, value: ?*const Node, label: ?[]const u8) !void {
    const frame = try findLoopFrame(self, label) orelse {
        const msg = if (label) |lbl| try std.fmt.allocPrint(
            self.alloc,
            "no matching label for break/{s}",
            .{lbl},
        ) else "break is only valid inside loop";

        return self.fail(.UnsupportedSyntax, expr, msg);
    };

    if (value) |v| try self.compile(v, true) else try self.pushNil();

    const r = self.active_registers - 1;
    try self.spans.append(self.alloc, self.active_span);
    _ = try self.record(.move, &.{.{ .reg = try toRegister(r) }}, true, try toRegister(frame.result_reg), 0);
    const jump_idx = try self.jump(.jump);
    try frame.break_jumps.append(self.alloc, jump_idx);
}

pub fn compileContinue(self: *Compiler, expr: *const Node, value: ?*const Node, label: ?[]const u8) !void {
    _ = value;
    const frame = try findLoopFrame(self, label) orelse {
        const msg = if (label) |lbl| try std.fmt.allocPrint(
            self.alloc,
            "no matching label for continue/{s}",
            .{lbl},
        ) else "continue is only valid inside loop";

        return self.fail(.UnsupportedSyntax, expr, msg);
    };

    // the loop's re-check point may sit after the body (fused range loops),
    // so the target is patched when the loop scope closes
    const jump_idx = try self.jump(.jump);
    try frame.continue_jumps.append(self.alloc, jump_idx);
}

pub fn compileLabeledBlock(self: *Compiler, label: []const u8, body: *const Node) !void {
    const LoopScopeT = state.LoopScope(@TypeOf(self.*));
    var loop = try LoopScopeT.init(self, label);
    defer loop.deinit();

    self.loop_stack.items[self.loop_stack.items.len - 1].continue_target = self.irLen();
    try self.compile(body, true);

    try normalizeLoopResult(self);

    self.active_registers = self.loop_stack.items[self.loop_stack.items.len - 1].result_reg + 1;
}
