const std = @import("std");

const revo = @import("revo");
const Compiler = @import("root.zig").Compiler;
const Value = revo.Value;
const ProgramCounter = revo.ProgramCounter;
const Operand = revo.Operand;
const Opcode = revo.opcode.Opcode;
const Register = revo.opcode.Register;
const LocalSlot = revo.LocalSlot;

const cst = @import("../cst.zig");
const Lexer = @import("../Lexer.zig");
const Node = cst.CstNode;
const ir = @import("../ir/root.zig");
const locals = @import("locals.zig");
const toRegister = locals.toRegister;
const TypeHint = locals.FunctionState.TypeHint;
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
    var loop = try locals.LoopScope.init(self, label);
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
    var loop = try locals.LoopScope.init(self, label);
    defer loop.deinit();

    const loop_start: ProgramCounter = @intCast(self.irLen());
    self.loop_stack.items[self.loop_stack.items.len - 1].continue_target = loop_start;
    try self.compile(predicate, true);
    const exit_jump = try self.jump(.jump_if_false);
    try self.compile(body, true);

    try self.regRelease();
    try self.emit(.jump, loop_start);

    self.patchJump(exit_jump);
    // same as compileLoop
    self.active_registers = self.loop_stack.items[self.loop_stack.items.len - 1].result_reg + 1;
}

pub fn compileForRange(
    self: *Compiler,
    params: []const Lexer.Token,
    body: *const Node,
    start_expr: *const Node,
    step_expr: *const Node,
    end_expr: *const Node,
    label: ?[]const u8,
) !void {
    var loop = try locals.LoopScope.init(self, label);
    defer loop.deinit();

    try self.compile(start_expr, true); // contiguous triple for range_init
    try self.compile(step_expr, true);
    try self.compile(end_expr, true);

    const base_reg = try toRegister(self.active_registers - 3);
    try self.spans.append(self.alloc, self.active_span);
    try self.recordStackOp(.range_init, 3, 0, base_reg, 0);

    const needs_index = params.len == 2 and !cst.isDiscardName(params[1].text);

    try compileRangeLoopBody(self, params, body, base_reg, needs_index);
    // collapse to result
    self.active_registers = self.loop_stack.items[self.loop_stack.items.len - 1].result_reg + 1;
}

pub fn compileRangeLoopBody(
    self: *Compiler,
    params: []const Lexer.Token,
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
    // (cst for-params are bare tokens, always numeric)
    if (params.len >= 1 and !cst.isDiscardName(params[0].text)) {
        value_slot = try locals.declareLocal(self, params[0].text, false);
        locals.setLocalType(self, value_slot.?, .{ .tag = .number });
        try locals.setLocalTypeHint(self, params[0].text, .{ .tag = .number });
    }

    if (params.len == 2 and !cst.isDiscardName(params[1].text)) {
        index_slot = try locals.declareLocal(self, params[1].text, false);
        locals.setLocalType(self, index_slot.?, .{ .tag = .number });
        try locals.setLocalTypeHint(self, params[1].text, .{ .tag = .number });
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

    // drain the LoopScope result load that used to feed jump_if_false
    _ = try self.pop();

    if (value_slot) |slot| {
        locals.markLocalInitialized(self, slot);
        try self.emitBind(.bind_local, slot, value_reg);
    }

    if (index_slot) |slot| {
        locals.markLocalInitialized(self, slot);
        try self.emitBind(.bind_local, slot, index_reg);
    }

    if (needs_index) try self.regRelease();
    try self.regRelease();

    const loop_state_end = try toRegister(state_reg + 3);
    reserveRegisters(self, loop_state_end); // pin range state so body can't clobber it

    try self.compile(body, true);

    try self.regRelease();

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

/// synthesized `number` node for default range bounds
fn numNode(self: *Compiler, span: Lexer.Span, value: f64) !*Node {
    const tok = cst.syntheticToken("", span);
    return cst.allocNode(self.alloc, span, .{ .number = .{ .tok = tok, .value = value, .is_float = false } });
}

pub fn compileFor(
    self: *Compiler,
    params: []const Lexer.Token,
    body: *const Node,
    iter: *const Node,
    label: ?[]const u8,
) !void {
    if (params.len == 0 or params.len > 2) {
        const msg = try self.alloc.print(
            "for expects one or two binding names, got {d}",
            .{params.len},
        );
        return self.fail(.UnsupportedSyntax, iter, msg);
    }

    const iter_u = cst.unwrapParen(iter) orelse return self.fail(.UnsupportedSyntax, iter, "for over nothing");

    if (iter_u.kind == .range) {
        const r = iter_u.kind.range;
        if (r.dot2_tok != null) {
            const end = r.end orelse return self.fail(.UnsupportedSyntax, iter, "open range needs an end");
            return compileForRange(self, params, body, r.start, r.mid, end, label);
        }

        // `a..b` is start..end with step 1
        const step = try numNode(self, r.mid.span, 1);
        return compileForRange(self, params, body, r.start, step, r.mid, label);
    }
    if (iter_u.kind == .for_range) {
        const r = iter_u.kind.for_range;
        const one = try numNode(self, iter.span, 1);
        const start = if (r.start) |s| s else try numNode(self, iter.span, 0);

        if (r.dot2_tok == null) {
            if (r.mid) |m| {
                const step = try numNode(self, m.span, 1);
                return compileForRange(self, params, body, start, step, m, label);
            }
            const end = try numNode(self, iter.span, cst.sentinelForCstStep(one));
            return compileForRange(self, params, body, start, one, end, label);
        }

        const mid = r.mid orelse return self.fail(.UnsupportedSyntax, iter, "open range needs a step");
        if (r.end) |e| return compileForRange(self, params, body, start, mid, e, label);
        const end = try numNode(self, iter.span, cst.sentinelForCstStep(mid));

        return compileForRange(self, params, body, start, mid, end, label);
    }

    var loop = try locals.LoopScope.init(self, label);
    defer loop.deinit();

    // wrap expression with to_iter
    try self.emit(.load_user_global, revo.CoreAtoms.to_iter.atomId());
    try self.compile(iter, true);
    try self.emit(.call, 1);
    const it_slot: LocalSlot = @intCast(self.active_registers - 1);
    reserveRegisters(self, @intCast(it_slot + 1));

    // idx <- 0
    try self.emit(.load_small_int, 0);
    const idx_slot: LocalSlot = @intCast(self.active_registers - 1);
    try self.emit(.store_local, idx_slot);
    reserveRegisters(self, @intCast(idx_slot + 1));

    const needs_index = params.len == 2 and !cst.isDiscardName(params[1].text);
    var value_storage: ?VarStorage = null;
    var index_storage: ?VarStorage = null;
    if (!cst.isDiscardName(params[0].text)) {
        const value_slot = try locals.declareLocal(self, params[0].text, false);
        value_storage = .{ .local = value_slot };
    }
    if (needs_index) {
        const index_slot = try locals.declareLocal(self, params[1].text, false);
        index_storage = .{ .local = index_slot };
    }

    locals.reserveLocalSlots(self);

    const loop_check: ProgramCounter = @intCast(self.irLen());
    self.loop_stack.items[self.loop_stack.items.len - 1].continue_target = loop_check;

    // it() -> value | :none
    try self.emit(.load_local, it_slot);
    try self.emit(.call, 0);
    // check for :done
    try self.regDupe();
    try self.@"const"(Value.new.atom(revo.CoreAtoms.done.atomId()));
    try self.emit(.eq, 0);
    const end_jump = try self.jump(.jump_if_true);

    if (value_storage) |storage| {
        const value_slot: LocalSlot = @intCast(storage.local);
        locals.markLocalInitialized(self, value_slot);
        try self.emit(.bind_local, value_slot);
    } else {
        try self.regRelease();
    }
    if (needs_index) {
        try self.emit(.load_local, idx_slot);
        if (index_storage) |storage| {
            const index_slot2: LocalSlot = @intCast(storage.local);
            locals.markLocalInitialized(self, index_slot2);
            try self.emit(.bind_local, index_slot2);
        } else {
            try self.regRelease();
        }
    }

    locals.reserveLocalSlots(self);

    try self.compile(body, true);

    try self.regRelease();

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
        .global => |sym| try self.emit(.load_user_global, sym),
    }
}

pub const PatternSrc = union(enum) { reg: usize, storage: VarStorage };

/// fetch table element idx from src, leaves it on stack top.
/// reg sources move to a fresh register first, storage sources load directly
pub fn fetchPatternElem(self: *Compiler, src: PatternSrc, idx: usize) !void {
    switch (src) {
        .reg => |r| {
            const mv_dst = try locals.pushRegister(self);
            try self.spans.append(self.alloc, self.active_span);
            _ = try self.record(.move, &.{.{ .reg = try toRegister(r) }}, true, mv_dst, 0);
        },
        .storage => |s| try emitStorageLoad(self, s),
    }
    try self.emit(.load_small_int, idx);
    try self.emit(.table_get, 0);
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
    try self.emit(.load_user_global, loop_sym);

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
    arms: []const cst.CstArm,
    subject_type: types_mod.TypeInfo,
) !void {
    if (locals.currentFunctionState(self) == null)
        return self.fail(.UnsupportedSyntax, subject, "match requires function scope");

    const saved = saveRegState(self);

    try locals.pushScope(self);
    errdefer locals.popScope(self);
    errdefer restoreRegState(self, saved);

    // slots n regs share the same frame storage
    // , so locals must not alias live temporaries from enclosing expressions
    // (like how thee `print` in `print(match ...)` is at r0 while next_slot may still be 0)
    //
    // pin the slot allocator above active registers before declaring
    if (self.slot_allocators.items.len > 0) {
        const idx = self.slot_allocators.items.len - 1;
        if (self.slot_allocators.items[idx] < self.active_registers) {
            self.slot_allocators.items[idx] = @intCast(self.active_registers);
        }
    }

    // evaluated once, loaded per arm
    const subject_slot = try locals.declareLocal(self, "__match_subject", false);
    try self.compile(subject, true);
    locals.markLocalInitialized(self, subject_slot);
    try self.emit(.bind_local, subject_slot);
    locals.reserveLocalSlots(self);

    const arm_base_registers = self.active_registers;
    const subject_next_slot = self.slot_allocators.items[self.slot_allocators.items.len - 1];
    const subject_storage: VarStorage = .{ .local = subject_slot };

    var end_jumps = try std.ArrayList(usize).initCapacity(self.alloc, arms.len);
    defer end_jumps.deinit(self.alloc);

    for (arms) |arm| {
        self.active_registers = arm_base_registers;

        try locals.pushScope(self);
        errdefer locals.popScope(self);

        // one slot per bound name, shared by every matcher in the arm
        //   ; nil until the winning matcher binds
        var bound_names = try std.ArrayList([]const u8).initCapacity(self.alloc, 4);
        defer bound_names.deinit(self.alloc);
        for (arm.matchers) |m| {
            if (m == .expr) try collectBindNames(self.alloc, m.expr, &bound_names);
        }

        for (bound_names.items) |name| {
            const slot = try locals.declareLocal(self, name, true);
            try self.pushNil();
            try self.emit(.bind_local, slot);

            locals.reserveLocalSlots(self);
        }

        // bound slots are live for the whole arm; temporaries for pat
        // checks, guards n the body must start above them
        // , otherwise somethig like `load_user_global r1,:print` would clobber `v` in slot1
        const arm_body_base = self.active_registers;

        // capture subject type before patternTypeInfo overwrites the hint
        const pre_narrow_subject_type = subject_type;

        //
        // matchers are alternatives:
        //
        // each one checks, binds, and jumps to the shared body
        // ; a miss falls through to the next matcher
        var body_jumps = try std.ArrayList(usize).initCapacity(self.alloc, arm.matchers.len);
        defer body_jumps.deinit(self.alloc);
        var fail_list = try std.ArrayList(usize).initCapacity(self.alloc, 4);
        defer fail_list.deinit(self.alloc);

        for (arm.matchers, 0..) |matcher, mi| {
            self.active_registers = arm_body_base;
            const matcher_expr: ?*const Node = switch (matcher) {
                .wildcard => null,
                .expr => |e| e,
            };
            if (matcher_expr == null) {
                // wildcard matches everything after it
                // ; later matchers are dead
                try body_jumps.append(self.alloc, try self.jump(.jump));
                break;
            }

            const fail_jumps = try compilePatternChecks(self, subject_storage, matcher_expr);
            const me = matcher_expr.?;
            if (cst.unwrapParen(subject)) |su| {
                if (su.kind == .ident) {
                    if (patternTypeInfo(self, me)) |ti| {
                        try locals.setLocalTypeHint(self, su.kind.ident.tok.text, ti);
                    }
                }
            }
            try bindMatchPattern(self, me, subject_storage);
            try narrowMatchPattern(self, me, pre_narrow_subject_type);
            try body_jumps.append(self.alloc, try self.jump(.jump));

            if (mi + 1 < arm.matchers.len) {
                const next_matcher = self.irLen();
                for (fail_jumps) |jump_idx| self.patchJumpToLabel(jump_idx, next_matcher);
            } else {
                try fail_list.appendSlice(self.alloc, fail_jumps);
            }
            self.alloc.free(fail_jumps);
        }

        self.active_registers = arm_body_base;
        const body = self.irLen();
        for (body_jumps.items) |jump_idx| self.patchJumpToLabel(jump_idx, body);

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

        locals.popScope(self);

        // bound slots (and any __bind_tmp/__match_tmp leaks) are dead after the arm
        //
        // reuse the same indices for the next arm
        self.slot_allocators.items[self.slot_allocators.items.len - 1] = subject_next_slot;

        const next_arm = self.irLen();
        for (fail_list.items) |jump_idx| self.patchJumpToLabel(jump_idx, next_arm);
    }
    locals.popScope(self);

    // reclaim subject slot
    self.slot_allocators.items[self.slot_allocators.items.len - 1] = saved.next_slot;

    self.active_registers = arm_base_registers;
    try self.pushNil(); // fallthrough when no arm matched
    for (end_jumps.items) |jump_idx| self.patchJump(jump_idx);

    self.active_registers = arm_base_registers + 1;

    // locals (subject n arm bindings) are dead now
    // , BUT arm_base can sit above the entry base
    // , leaving a hole (e.g. `print(match ...)` has print in r0, subject in slot1, result in r2)
    //
    // calls require contiguous [callee, args], so compact the result down to the entry base
    if (arm_base_registers != saved.active) {
        try self.spans.append(self.alloc, self.active_span);
        _ = try self.record(.move, &.{.{ .reg = try toRegister(arm_base_registers) }}, true, try toRegister(saved.active), 0);
        self.active_registers = saved.active + 1;
        if (self.max_registers < self.active_registers) self.max_registers = self.active_registers;
    }
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

// bound idents in a pattern, deduped;
// arm slots are hoisted from these
fn collectBindNames(alloc: std.mem.Allocator, pattern: *const Node, out: *std.ArrayList([]const u8)) !void {
    const u = cst.unwrapParen(pattern) orelse return;
    switch (u.kind) {
        .ident => |n| {
            const name = n.tok.text;
            if (cst.isDiscardName(name)) return;
            for (out.items) |have| if (std.mem.eql(u8, have, name)) return;
            try out.append(alloc, name);
        },
        .table => |tbl| for (tbl.entries) |entry| {
            if (entry != .bare) continue;
            try collectBindNames(alloc, entry.bare.value, out);
        },
        .ascribed => |a| try collectBindNames(alloc, a.expr, out),
        else => {},
    }
}

pub fn bindMatchPattern(
    self: *Compiler,
    matcher: *const Node,
    subject: VarStorage,
) !void {
    const u = cst.unwrapParen(matcher) orelse return;
    switch (u.kind) {
        .ident => |n| {
            const name = n.tok.text;
            if (cst.isDiscardName(name)) return;
            try emitStorageLoad(self, subject);
            try bindMatchIdent(self, name);
        },
        .table => |tbl| {
            var idx: usize = 0;
            for (tbl.entries) |entry| {
                if (entry != .bare) continue;
                const item = entry.bare.value;
                const iu = cst.unwrapParen(item) orelse {
                    idx += 1;
                    continue;
                };
                switch (iu.kind) {
                    .ident => |n| {
                        const name = n.tok.text;
                        if (cst.isDiscardName(name)) {
                            idx += 1;
                            continue;
                        }
                        try fetchPatternElem(self, .{ .storage = subject }, idx);
                        try bindMatchIdent(self, name);
                    },
                    .table, .ascribed => {
                        try fetchPatternElem(self, .{ .storage = subject }, idx);

                        // temp for nested pattern
                        const nested_slot = try locals.declareLocal(self, "__bind_tmp", false);
                        locals.markLocalInitialized(self, nested_slot);
                        try self.emit(.bind_local, nested_slot);
                        locals.reserveLocalSlots(self);

                        try bindMatchPattern(self, item, .{ .local = nested_slot });
                    },
                    else => {},
                }
                idx += 1;
            }
        },
        .ascribed => |a| try bindMatchPattern(self, a.expr, subject),
        else => {},
    }
}

/// bind the loaded value to the hoisted arm slot when present,
/// so every matcher binds the same one
fn bindMatchIdent(self: *Compiler, name: []const u8) !void {
    const slot = if (locals.findLocalInCurrentScope(self, name)) |l| l.slot else try locals.declareLocal(self, name, true);
    locals.markLocalInitialized(self, slot);
    try self.emit(.bind_local, slot);

    locals.reserveLocalSlots(self);
}

pub fn compilePatternChecks(
    self: *Compiler,
    subject: VarStorage,
    matcher: ?*const Node,
) ![]usize {
    var fail_jumps = try std.ArrayList(usize).initCapacity(self.alloc, 4);
    const expr = matcher orelse return fail_jumps.toOwnedSlice(self.alloc);
    const eu = cst.unwrapParen(expr) orelse return fail_jumps.toOwnedSlice(self.alloc);

    switch (eu.kind) {
        .ident => {}, // always matches
        .ascribed => |a| {
            // type check first, then the inner pattern
            //   ; fail fast
            const asc_ti = types_mod.evalTypeExpr(self.aliasScope(), a.type) catch types_mod.TypeInfo{ .tag = .any };

            const type_fails = try compileTypeSatisfies(self, subject, asc_ti);
            defer self.alloc.free(type_fails);
            try fail_jumps.appendSlice(self.alloc, type_fails);

            const inner_fails = try compilePatternChecks(self, subject, a.expr);
            defer self.alloc.free(inner_fails);
            try fail_jumps.appendSlice(self.alloc, inner_fails);
        },
        .table => |tbl| {
            // type check
            //  , then array length
            //  , then each element
            try self.emit(.load_user_global, try self.vm.internAtom("typeof"));
            try emitStorageLoad(self, subject);
            try self.emit(.call, 1);
            try self.@"const"(Value.new.atom(try self.vm.internAtom("table")));
            try self.emit(.eq, 0);
            try fail_jumps.append(self.alloc, try self.jump(.jump_if_false));

            // alen counts the array part only
            //  , hash entries don't matter
            var bare_count: usize = 0;
            for (tbl.entries) |entry| if (entry == .bare) {
                bare_count += 1;
            };
            try self.emit(.load_builtin_global, try self.vm.internAtom("table"));
            try self.emit(.table_get_atom, try self.vm.internAtom("alen"));
            try emitStorageLoad(self, subject);
            try self.emit(.call, 1);
            try self.@"const"(Value.new.num(bare_count));
            try self.emit(.eq, 0);
            try fail_jumps.append(self.alloc, try self.jump(.jump_if_false));

            var idx: usize = 0;
            for (tbl.entries) |entry| {
                if (entry != .bare) continue;
                const item = entry.bare.value;
                const iu = cst.unwrapParen(item);
                if (iu != null and iu.?.kind == .ident) {
                    if (cst.isDiscardName(iu.?.kind.ident.tok.text)) {
                        idx += 1;
                        continue;
                    }
                }
                const depth_before = self.active_registers;
                const slot_before = self.slot_allocators.items[self.slot_allocators.items.len - 1];
                try emitStorageLoad(self, subject);
                try self.emit(.load_small_int, idx);
                try self.emit(.table_get, 0);

                // to not reindex in nested checks
                const nested_slot = try locals.declareLocal(self, "__match_tmp", false);
                locals.markLocalInitialized(self, nested_slot);
                try self.emit(.bind_local, nested_slot);
                locals.reserveLocalSlots(self);

                const nested_fails = try compilePatternChecks(self, .{ .local = nested_slot }, item);
                for (nested_fails) |jump_idx| try fail_jumps.append(self.alloc, jump_idx);

                self.alloc.free(nested_fails);
                self.active_registers = depth_before;
                self.slot_allocators.items[self.slot_allocators.items.len - 1] = slot_before;
                idx += 1;
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

/// `typeof(x) == :name`
///   ; fail jump when not
fn jumpIfNotType(self: *Compiler, subject: VarStorage, name: []const u8) !usize {
    try self.emit(.load_user_global, try self.vm.internAtom("typeof"));
    try emitStorageLoad(self, subject);
    try self.emit(.call, 1);
    try self.@"const"(Value.new.atom(try self.vm.internAtom(name)));
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
        .resource => try fail_jumps.append(self.alloc, try jumpIfNotType(self, subject, "resource")),
        .function => try fail_jumps.append(self.alloc, try jumpIfNotType(self, subject, "function")),
        .bool => {
            // bools are :true/:false atoms
            try emitStorageLoad(self, subject);
            try self.@"const"(Value.new.atom(try self.vm.internAtom("true")));
            try self.emit(.eq, 0);
            const ok_jump = try self.jump(.jump_if_true);

            try emitStorageLoad(self, subject);
            try self.@"const"(Value.new.atom(try self.vm.internAtom("false")));
            try self.emit(.eq, 0);
            try fail_jumps.append(self.alloc, try self.jump(.jump_if_false));

            self.patchJump(ok_jump);
        },
        .atom => |name| {
            if (name.len == 0) {
                try fail_jumps.append(self.alloc, try jumpIfNotType(self, subject, "atom"));
            } else {
                const base = cst.atomName(name);
                const want: Value = if (std.mem.eql(u8, base, "nil"))
                    Value.new.nil()
                else
                    Value.new.atom(try self.vm.internAtom(base));

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
                    try self.emit(.load_builtin_global, try self.vm.internAtom("table"));
                    try self.emit(.table_get_atom, try self.vm.internAtom("alen"));
                    try emitStorageLoad(self, subject);
                    try self.emit(.call, 1);
                    try self.@"const"(Value.new.num(max_pos));
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

                        const nested_slot = try locals.declareLocal(self, "__match_tmp", false);
                        locals.markLocalInitialized(self, nested_slot);
                        try self.emit(.bind_local, nested_slot);
                        locals.reserveLocalSlots(self);

                        const nested_fails = try compileTypeSatisfies(self, .{ .local = nested_slot }, f.field_type);
                        try fail_jumps.appendSlice(self.alloc, nested_fails);
                        self.alloc.free(nested_fails);
                    } else |_| {
                        // named fields must be present
                        //   ; missing reads as :undef
                        const key_atom = try self.vm.internAtom(f.name);
                        try emitStorageLoad(self, subject);
                        try self.emit(.table_get_atom, key_atom);

                        const nested_slot = try locals.declareLocal(self, "__match_tmp", false);
                        locals.markLocalInitialized(self, nested_slot);
                        try self.emit(.bind_local, nested_slot);
                        locals.reserveLocalSlots(self);

                        const nested_storage: VarStorage = .{ .local = nested_slot };
                        try emitStorageLoad(self, nested_storage);
                        try self.@"const"(Value.new.core(.undef));
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
    try compileConditional(self, condition, then_expr, else_expr, .jump_if_false, "if requires function scope");
}

pub fn compileUnless(
    self: *Compiler,
    condition: *const Node,
    then_expr: *const Node,
    else_expr: ?*Node,
) !void {
    try compileConditional(self, condition, then_expr, else_expr, .jump_if_true, "unless requires function scope");
}

fn compileConditional(
    self: *Compiler,
    condition: *const Node,
    then_expr: *const Node,
    else_expr: ?*Node,
    jump_op: Opcode,
    scope_err: []const u8,
) !void {
    if (locals.currentFunctionState(self) == null)
        return self.fail(.UnsupportedSyntax, condition, scope_err);

    const saved = saveRegState(self);
    errdefer restoreRegState(self, saved);

    try self.compile(condition, true);
    const else_jump = try self.jump(jump_op);
    const branch_base_registers = self.active_registers;
    const join_depth = self.value_stack.items.len;

    try locals.pushScope(self);
    errdefer locals.popScope(self);
    if (conditionTypeHint(condition)) |hint| {
        try locals.setLocalTypeHint(self, hint.name, hint.type_info);
    }
    try self.compile(then_expr, true);
    locals.popScope(self);
    const then_registers = self.active_registers;

    if (self.value_stack.items.len > join_depth) {
        const then_val = self.value_stack.items[self.value_stack.items.len - 1];
        if (then_val.result_reg != branch_base_registers) {
            try self.spans.append(self.alloc, self.active_span);
            _ = try self.record(.move, &.{.{ .inst = then_val }}, true, @intCast(branch_base_registers), 0);
        }
    }

    const end_jump = try self.jump(.jump);
    self.patchJump(else_jump);
    self.active_registers = branch_base_registers;

    try locals.pushScope(self);
    errdefer locals.popScope(self);
    if (else_expr) |branch| {
        try self.compile(branch, true);
    } else try self.pushNil();
    locals.popScope(self);

    if (self.value_stack.items.len > join_depth) {
        const else_val = self.value_stack.items[self.value_stack.items.len - 1];
        if (else_val.result_reg != branch_base_registers) {
            try self.spans.append(self.alloc, self.active_span);
            _ = try self.record(.move, &.{.{ .inst = else_val }}, true, @intCast(branch_base_registers), 0);
        }
    }

    if (then_registers != self.active_registers) {
        while (self.active_registers < then_registers)
            try self.pushNil();
        self.active_registers = then_registers;
    }
    self.patchJump(end_jump);
}

fn conditionTypeHint(condition: *const Node) ?TypeHint {
    const cu = cst.unwrapParen(condition) orelse return null;
    return switch (cu.kind) {
        .call => |call| blk: {
            const cname = cst.identText(call.callee) orelse break :blk null;
            if (call.args.len != 1 or !std.mem.endsWith(u8, cname, "?")) break :blk null;
            const au = cst.unwrapParen(call.args[0]) orelse break :blk null;
            if (au.kind != .ident) break :blk null;

            const type_info = if (std.mem.eql(u8, cname, "number?"))
                typeNameInfo("number")
            else if (std.mem.eql(u8, cname, "string?"))
                typeNameInfo("string")
            else if (std.mem.eql(u8, cname, "bool?"))
                typeNameInfo("bool")
            else if (std.mem.eql(u8, cname, "table?"))
                typeNameInfo("table")
            else
                null;

            const unwrapped = type_info orelse break :blk null;
            break :blk .{ .name = au.kind.ident.tok.text, .type_info = unwrapped };
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
    const tu = cst.unwrapParen(type_expr) orelse return null;
    if (tu.kind != .call) return null;
    const call = tu.kind.call;

    const cname = cst.identText(call.callee) orelse return null;
    if (call.args.len != 1) return null;
    if (!std.mem.eql(u8, cname, "typeof")) return null;
    const au = cst.unwrapParen(call.args[0]) orelse return null;
    if (au.kind != .ident) return null;
    const vu = cst.unwrapParen(value_expr) orelse return null;
    if (vu.kind != .atom) return null;

    const type_info = typeNameInfo(cst.atomName(vu.kind.atom.tok.text)) orelse return null;
    return .{ .name = au.kind.ident.tok.text, .type_info = type_info };
}

fn typeNameInfo(name: []const u8) ?types_mod.TypeInfo {
    if (std.mem.eql(u8, name, "number")) return .{
        .tag = .{ .@"union" = &.{
            .{ .name = "", .types = &.{.{ .tag = .number }} },
            .{ .name = "", .types = &.{.{ .tag = .number }} },
        } },
    };
    return types_mod.type_name_map.get(name);
}

fn patternTypeInfo(self: *Compiler, pattern: *const Node) ?types_mod.TypeInfo {
    const u = cst.unwrapParen(pattern) orelse return null;
    return switch (u.kind) {
        .ascribed => |a| types_mod.evalTypeExpr(self.aliasScope(), a.type) catch null,
        .number => .{ .tag = .number },
        .string, .interpolated => .{ .tag = .string },
        .atom => |a| .{ .tag = .{ .atom = cst.atomName(a.tok.text) } },
        .table => |tbl| blk: {
            var bare_count: usize = 0;
            for (tbl.entries) |entry| if (entry == .bare) {
                bare_count += 1;
            };
            var fields = std.ArrayList(types_mod.RecordField).initCapacity(self.alloc, bare_count) catch break :blk null;
            defer fields.deinit(self.alloc);

            var idx: usize = 0;
            for (tbl.entries) |entry| {
                if (entry != .bare) continue;
                const item = entry.bare.value;
                var buf: [16]u8 = undefined;
                const name = std.mem.print(&buf, "{d}", .{idx}) catch break :blk null;
                const owned = self.alloc.dupe(u8, name) catch break :blk null;

                fields.append(self.alloc, .{
                    .name = owned,
                    .field_type = patternTypeInfo(self, item) orelse types_mod.TypeInfo{ .tag = .any },
                }) catch break :blk null;
                idx += 1;
            }

            const owned_fields = fields.toOwnedSlice(self.alloc) catch break :blk null;
            const value_ptr = self.alloc.create(types_mod.TypeInfo) catch break :blk null;

            value_ptr.* = .{ .tag = .any };
            break :blk types_mod.makeTable(null, value_ptr, owned_fields);
        },
        .ident => {
            // look up the variable type from hints or local state
            // // and type narrowing from variable names is handled somewher else
            return null;
        },
        .err => .{ .tag = .{ .atom = ":nil" } },
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
    const pu = cst.unwrapParen(pattern) orelse return;
    if (pu.kind == .ascribed) {
        const a = pu.kind.ascribed;

        if (cst.identText(a.expr)) |iname| {
            if (!cst.isDiscardName(iname)) {
                const ti = types_mod.evalTypeExpr(self.aliasScope(), a.type) catch types_mod.TypeInfo{ .tag = .any };
                try locals.setLocalTypeHint(self, iname, ti);

                return;
            }
        }

        return try narrowMatchPattern(self, a.expr, subject_type);
    }

    const tu = cst.unwrapParen(pattern) orelse return;
    if (tu.kind != .table) return;
    var bare_items: [32]*const Node = undefined;
    var bare_len: usize = 0;
    for (tu.kind.table.entries) |entry| {
        if (entry != .bare) return;
        if (bare_len >= bare_items.len) return;
        bare_items[bare_len] = entry.bare.value;
        bare_len += 1;
    }
    const items = bare_items[0..bare_len];

    // ascribed items narrow from their annotation
    //   ; whatever the subject
    for (items) |item| {
        const iu = cst.unwrapParen(item) orelse continue;
        if (iu.kind != .ascribed) continue;
        const a = iu.kind.ascribed;

        if (cst.identText(a.expr)) |iname| {
            if (!cst.isDiscardName(iname)) {
                const ti = types_mod.evalTypeExpr(self.aliasScope(), a.type) catch types_mod.TypeInfo{ .tag = .any };
                try locals.setLocalTypeHint(self, iname, ti);
            }
        }
    }

    if (subject_type.tag != .@"union") return;

    if (items.len == 0) return;

    const first = items[0];
    const fu = cst.unwrapParen(first) orelse return;
    const tag = if (fu.kind == .atom) cst.atomName(fu.kind.atom.tok.text) else return;

    for (subject_type.tag.@"union") |variant| {
        if (!types_mod.unionVariantTagEql(variant, tag)) continue;
        var payload = std.ArrayList(types_mod.TypeInfo).initCapacity(self.alloc, 4) catch return;
        defer payload.deinit(self.alloc);
        try types_mod.appendUnionVariantPayload(self.alloc, variant, &payload);

        for (items[1..], 0..) |item, i| {
            const iu = cst.unwrapParen(item) orelse continue;
            // ascriptions win over the union payload
            //   ; for the names they cover
            if (iu.kind == .ascribed) {
                const a = iu.kind.ascribed;

                if (cst.identText(a.expr)) |iname| {
                    if (!cst.isDiscardName(iname)) {
                        const ti = types_mod.evalTypeExpr(self.aliasScope(), a.type) catch types_mod.TypeInfo{ .tag = .any };
                        try locals.setLocalTypeHint(self, iname, ti);
                    }
                }

                continue;
            }

            if (cst.identText(item)) |iname| {
                if (!cst.isDiscardName(iname)) {
                    const narrowed = if (i < payload.items.len) payload.items[i] else types_mod.TypeInfo{ .tag = .any };
                    try locals.setLocalTypeHint(self, iname, narrowed);
                }
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
    const left_reg: Register = left_inst.result_reg;

    try self.compile(right, true);
    const right_inst = try self.pop();
    const right_reg: Register = right_inst.result_reg;

    //
    // left and right usually share the same register because
    //   active_registers is restored before compiling right
    //
    // but slot pinning (reserveLocalSlots / popRegister clamping to dead local slots)
    //   can push right above left, leaving the join to test garbage on the short path
    //
    // without this (check git blame):
    //
    //   load r11, has_id
    //   jump_if_false r11 -> L91   # short skips right, r13 garbage
    //   load r13, has_classes
    //   not r13
    //   move r11, r13  # missing before fix
    //   L91: jump_if_false r13 ... # tested garbage
    //
    // copy right down so both paths leave the result in left_reg
    //
    var result_inst = left_inst;
    if (right_reg != left_reg) {
        try self.spans.append(self.alloc, self.active_span);
        result_inst = try self.record(
            .move,
            &.{.{ .inst = right_inst }},
            true,
            left_reg,
            0,
        );
        // drop pushed move so end jump patching sees the stack it needs
        // its reappended below after active is fixed
        _ = try self.pop();
    }

    const end = try self.jump(.jump);

    self.patchJump(short);
    self.patchJump(end);
    try self.value_stack.append(self.alloc, result_inst);

    self.active_registers = @as(usize, left_reg) + 1;
    if (self.max_registers < self.active_registers)
        self.max_registers = self.active_registers;
}

pub fn compileAnd(self: *Compiler, left: *const Node, right: *const Node) !void {
    try compileShortCircuit(self, left, right, .jump_if_false);
}

pub fn compileOr(self: *Compiler, left: *const Node, right: *const Node) !void {
    try compileShortCircuit(self, left, right, .jump_if_true);
}

fn findLoopFrame(self: *Compiler, label: ?[]const u8) !?*locals.LoopFrame {
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
        const msg = if (label) |lbl| try self.alloc.print(
            "no matching label for break/{s}",
            .{lbl},
        ) else "break is only valid inside loop";

        return self.fail(.UnsupportedSyntax, expr, msg);
    };

    if (label == null) {
        if (value) |v| {
            try self.compile(v, true);
            try self.regRelease();
        }
        const jump_idx = try self.jump(.jump);
        try frame.break_jumps.append(self.alloc, jump_idx);
        return;
    }

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
        const msg = if (label) |lbl| try self.alloc.print(
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
    var loop = try locals.LoopScope.init(self, label);
    defer loop.deinit();

    self.loop_stack.items[self.loop_stack.items.len - 1].continue_target = self.irLen();
    try self.compile(body, true);

    try normalizeLoopResult(self);

    self.active_registers = self.loop_stack.items[self.loop_stack.items.len - 1].result_reg + 1;
}
