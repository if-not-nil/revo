const std = @import("std");

const revo = @import("revo");
const Compiler = @import("root.zig").Compiler;
const LocalSlot = revo.LocalSlot;
const Register = revo.opcode.Register;
const UpvalueSpec = revo.callable.UpvalueSpec;
const types = @import("types.zig");

const cst = @import("../cst.zig");
const resmap = @import("../resmap.zig");
const Node = cst.CstNode;

pub const LocalVar = struct {
    name: []const u8,
    slot: LocalSlot,
    mutable: bool,
    initialized: bool,
    type_info: ?types.TypeInfo = null,
    type_explicit: bool = false,
};

pub const FunctionState = struct {
    pub const TypeHint = struct {
        name: []const u8,
        type_info: types.TypeInfo,
    };

    alloc: std.mem.Allocator,
    locals: std.ArrayList(LocalVar),
    all_locals: std.ArrayList(LocalVar),
    upvalues: std.ArrayList(UpvalueSpec),
    import_locals: std.ArrayList(LocalVar),
    scope_starts: std.ArrayList(usize),
    type_hints: std.ArrayList(TypeHint),
    type_scope_starts: std.ArrayList(usize),
    fn_signatures: std.StringHashMap(*types.FunctionSignature),
    type_params: []const []const u8 = &.{},

    pub fn init(alloc: std.mem.Allocator) !FunctionState {
        return .{
            .alloc = alloc,
            .locals = try std.ArrayList(LocalVar).initCapacity(alloc, 8),
            .all_locals = try std.ArrayList(LocalVar).initCapacity(alloc, 8),
            .upvalues = try std.ArrayList(UpvalueSpec).initCapacity(alloc, 4),
            .import_locals = try std.ArrayList(LocalVar).initCapacity(alloc, 2),
            .scope_starts = try std.ArrayList(usize).initCapacity(alloc, 8),
            .type_hints = try std.ArrayList(TypeHint).initCapacity(alloc, 8),
            .type_scope_starts = try std.ArrayList(usize).initCapacity(alloc, 8),
            .fn_signatures = std.StringHashMap(*types.FunctionSignature).init(alloc),
        };
    }

    pub fn deinit(self: *FunctionState, alloc: std.mem.Allocator) void {
        self.locals.deinit(alloc);
        self.all_locals.deinit(alloc);
        self.upvalues.deinit(alloc);
        self.import_locals.deinit(alloc);
        self.scope_starts.deinit(alloc);
        self.type_hints.deinit(alloc);
        self.type_scope_starts.deinit(alloc);

        var it = self.fn_signatures.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.value_ptr.*.params);
            alloc.destroy(entry.value_ptr.*);
        }
        self.fn_signatures.deinit();
    }
};

pub const LoopFrame = struct {
    label: ?[]const u8,
    continue_target: usize,
    result_reg: Register,
    break_jumps: std.ArrayList(usize),
    continue_jumps: std.ArrayList(usize),
    function_index: usize,
};

pub const LoopScope = struct {
    compiler: *Compiler,
    prev_in_loop: usize,
    pub fn init(compiler: *Compiler, label: ?[]const u8) !LoopScope {
        const prev = compiler.in_loop_depth;
        compiler.in_loop_depth += 1;
        const result_reg = try pushRegister(compiler);
        try compiler.spans.append(compiler.alloc, compiler.active_span);
        const loop_idx = try compiler.vm.addConstant(revo.Value.new.core(.loop));
        try compiler.recordLoad(.load_const, result_reg, loop_idx);
        try compiler.loop_stack.append(compiler.alloc, .{
            .label = label,
            .continue_target = 0,
            .result_reg = result_reg,
            .break_jumps = try std.ArrayList(usize).initCapacity(compiler.alloc, 4),
            .continue_jumps = try std.ArrayList(usize).initCapacity(compiler.alloc, 4),
            .function_index = compiler.functions.items.len,
        });
        return .{ .compiler = compiler, .prev_in_loop = prev };
    }
    pub fn deinit(self: *@This()) void {
        const c = self.compiler;
        var frame = c.loop_stack.pop().?;
        const exit_addr: usize = c.irLen();
        while (frame.break_jumps.pop()) |idx| {
            c.patchJumpToLabel(idx, exit_addr);
        }
        while (frame.continue_jumps.pop()) |idx| {
            c.patchJumpToLabel(idx, frame.continue_target);
        }
        frame.break_jumps.deinit(c.alloc);
        frame.continue_jumps.deinit(c.alloc);
        c.in_loop_depth = self.prev_in_loop;
    }
};

pub fn toRegister(n: usize) !Register {
    std.debug.assert(n <= std.math.maxInt(Register));
    return @intCast(n);
}

pub fn pushRegister(self: *Compiler) !Register {
    const reg = try toRegister(self.active_registers);
    self.active_registers += 1;
    if (self.active_registers > self.max_registers) self.max_registers = self.active_registers;
    return reg;
}

pub fn popRegister(self: *Compiler) void {
    std.debug.assert(self.active_registers > 0);
    self.active_registers -= 1;
    if (self.slot_allocators.items.len > 0) {
        const next = self.slot_allocators.items[self.slot_allocators.items.len - 1];
        if (self.active_registers < next) self.active_registers = next;
    }
}

pub fn currentFunctionState(self: *const Compiler) ?*FunctionState {
    if (self.functions.items.len == 0) return null;
    return &self.functions.items[self.functions.items.len - 1];
}

pub fn declareLocal(self: *Compiler, name: []const u8, mutable: bool) !LocalSlot {
    var state_ptr = currentFunctionState(self);
    if (state_ptr == null) {
        const s = try FunctionState.init(self.alloc);
        try self.functions.append(self.alloc, s);
        try self.slot_allocators.append(self.alloc, 0);
        state_ptr = &self.functions.items[self.functions.items.len - 1];
    }
    const state = state_ptr orelse unreachable;
    const slot = self.slot_allocators.items[self.slot_allocators.items.len - 1];
    self.slot_allocators.items[self.slot_allocators.items.len - 1] += 1;
    const local: LocalVar = .{ .name = name, .slot = slot, .mutable = mutable, .initialized = false };
    try state.locals.append(self.alloc, local);
    try state.all_locals.append(self.alloc, local);
    return slot;
}

pub fn reserveLocalSlots(self: *Compiler) void {
    if (self.slot_allocators.items.len == 0) return;
    const next = self.slot_allocators.items[self.slot_allocators.items.len - 1];
    if (self.active_registers < next) self.active_registers = next;
    if (self.max_registers < next) self.max_registers = next;
}

pub fn pushScope(self: *Compiler) !void {
    const state = currentFunctionState(self) orelse return;
    try state.scope_starts.append(self.alloc, state.locals.items.len);
    try state.type_scope_starts.append(self.alloc, state.type_hints.items.len);
}

pub fn popScope(self: *Compiler) void {
    const state = currentFunctionState(self) orelse return;
    const start = state.scope_starts.pop() orelse return;
    state.locals.items.len = start;
    const type_start = state.type_scope_starts.pop() orelse return;
    state.type_hints.items.len = type_start;
}

pub fn findLocalInCurrentScope(self: *Compiler, name: []const u8) ?*LocalVar {
    const fn_idx = self.functions.items.len - 1;
    const state = &self.functions.items[fn_idx];
    const start = if (state.scope_starts.items.len == 0)
        0
    else
        state.scope_starts.items[state.scope_starts.items.len - 1];
    var i = state.locals.items.len;
    while (i > start) {
        i -= 1;
        if (std.mem.eql(u8, state.locals.items[i].name, name)) return &state.locals.items[i];
    }
    return null;
}

pub fn reuseOrDeclareLocal(self: *Compiler, name: []const u8, mutable: bool) !LocalSlot {
    if (findLocalInCurrentScope(self, name)) |local| if (!local.initialized) return local.slot;
    return declareLocal(self, name, mutable);
}

fn scanLocals(items: []LocalVar, slot: LocalSlot) ?*LocalVar {
    var i = items.len;
    while (i > 0) {
        i -= 1;
        if (items[i].slot == slot) return &items[i];
    }
    return null;
}

pub fn markLocalInitialized(self: *Compiler, slot: LocalSlot) void {
    const state = currentFunctionState(self) orelse return;
    if (scanLocals(state.locals.items, slot)) |l| l.initialized = true;
    if (scanLocals(state.all_locals.items, slot)) |l| l.initialized = true;
}

pub fn setLocalType(self: *Compiler, slot: LocalSlot, type_info: ?types.TypeInfo) void {
    const state = currentFunctionState(self) orelse return;
    if (scanLocals(state.locals.items, slot)) |l| l.type_info = type_info;
    if (scanLocals(state.all_locals.items, slot)) |l| l.type_info = type_info;
}

pub fn setLocalTypeExplicit(self: *Compiler, slot: LocalSlot) void {
    const state = currentFunctionState(self) orelse return;
    if (scanLocals(state.locals.items, slot)) |l| l.type_explicit = true;
    if (scanLocals(state.all_locals.items, slot)) |l| l.type_explicit = true;
}

pub fn setLocalTypeHint(self: *Compiler, name: []const u8, type_info: types.TypeInfo) !void {
    const state = currentFunctionState(self) orelse return;
    for (state.type_hints.items, 0..) |hint, i| {
        if (std.mem.eql(u8, hint.name, name)) {
            state.type_hints.items[i] = .{ .name = name, .type_info = type_info };
            return;
        }
    }
    try state.type_hints.append(self.alloc, .{ .name = name, .type_info = type_info });
}

pub fn resolveLocalTypeHint(self: *Compiler, name: []const u8) ?types.TypeInfo {
    const fn_state = currentFunctionState(self) orelse return null;
    var i = fn_state.type_hints.items.len;
    while (i > 0) {
        i -= 1;
        const hint = fn_state.type_hints.items[i];
        if (std.mem.eql(u8, hint.name, name)) return hint.type_info;
    }
    return null;
}

pub fn predeclare(self: *Compiler, exprs: []const *Node) !void {
    for (exprs) |expr| {
        if (expr.kind != .decl) continue;
        const decl = expr.kind.decl;
        switch (decl.inner.kind) {
            .type_alias => |t| {
                // declares are values, not type aliases - do not pollute type space
                if (decl.kind == .declare_decl) continue;
                if (t.segs.len == 0) continue;
                const key = t.segs[t.segs.len - 1].text;
                if (self.type_aliases.contains(key)) continue;
                const type_info = try types.evalTypeExpr(self.aliasScope(), t.type);
                try self.type_aliases.put(key, .{ .info = type_info });
            },
            .binding => {
                // shared predicate with the checker's collectPredeclared
                const pre = resmap.predeclFn(expr) orelse continue;
                const name = pre.name;
                _ = try reuseOrDeclareLocal(self, name, pre.is_let);
                // temporarily set type_params so isTypeParam works during evalTypeExpr
                const fn_def = pre.func;
                var explicit: []const []const u8 = &.{};
                if (fn_def.type_params.len > 0) {
                    const tmp = try self.alloc.alloc([]const u8, fn_def.type_params.len);
                    for (fn_def.type_params, 0..) |tok, i| tmp[i] = tok.text;
                    explicit = tmp;
                }
                const fn_state = &self.functions.items[self.functions.items.len - 1];
                const saved = fn_state.type_params;
                fn_state.type_params = try types.combinedTypeParams(self.alloc, explicit, fn_def.params);
                defer fn_state.type_params = saved;
                try declareFnSignature(
                    self,
                    name,
                    fn_def.params,
                    fn_def.return_type,
                    explicit,
                );
            },
            else => {},
        }
    }
    reserveLocalSlots(self);
}

pub fn resolveLocalVarIn(self: *Compiler, fn_idx: usize, name: []const u8) ?LocalVar {
    const fn_state = &self.functions.items[fn_idx];
    const locals = fn_state.locals.items;
    var i = locals.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, locals[i].name, name)) return locals[i];
    }
    // check bypasses scope pops from synthetic blocks
    const import_locals = fn_state.import_locals.items;
    i = import_locals.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, import_locals[i].name, name)) return import_locals[i];
    }
    return null;
}

/// bit faster than checking for whether it contains it
pub fn isMasked(self: *Compiler, name: []const u8) bool {
    for (self.masking_stack.items) |m| if (std.mem.eql(u8, m, name)) return true;
    return false;
}

pub fn resolveLocal(self: *Compiler, name: []const u8) ?LocalSlot {
    if (self.functions.items.len == 0) return null;
    if (resolveLocalMasked(self, name)) |v| return v.slot;
    if (isMasked(self, name)) return null;
    return if (resolveLocalVarIn(self, self.functions.items.len - 1, name)) |v| v.slot else null;
}

pub fn resolveLocalVar(self: *Compiler, name: []const u8) ?LocalVar {
    if (self.functions.items.len == 0) return null;
    if (resolveLocalMasked(self, name)) |v| return v;
    if (isMasked(self, name)) return null;
    return resolveLocalVarIn(self, self.functions.items.len - 1, name);
}

/// a name whose own binding is still compiling must not resolve to its fresh
/// uninitialized slot; the nearest already-initialized local wins, otherwise
/// the initializer sees the enclosing scope or a global
fn resolveLocalMasked(self: *Compiler, name: []const u8) ?LocalVar {
    if (!isMasked(self, name)) return null;
    const fn_state = &self.functions.items[self.functions.items.len - 1];
    const locals = fn_state.locals.items;
    var i = locals.len;
    while (i > 0) {
        i -= 1;
        const local = locals[i];
        if (local.initialized and std.mem.eql(u8, local.name, name)) return local;
    }
    return null;
}

pub fn addUpvalue(self: *Compiler, fn_idx: usize, spec: UpvalueSpec) !revo.UpvalueID {
    const state = &self.functions.items[fn_idx];
    for (state.upvalues.items, 0..) |existing, idx| {
        if (existing.is_local == spec.is_local and existing.index == spec.index and
            existing.mutable == spec.mutable) return @intCast(idx);
    }
    const id: revo.UpvalueID = @intCast(state.upvalues.items.len);
    try state.upvalues.append(self.alloc, spec);
    return id;
}

pub fn resolveUpvalueRecursive(self: *Compiler, fn_idx: usize, name: []const u8) !?revo.UpvalueID {
    if (fn_idx == 0) return null;
    const enc = fn_idx - 1;
    if (resolveLocalVarIn(self, enc, name)) |local| return try addUpvalue(
        self,
        fn_idx,
        .{ .is_local = true, .index = local.slot, .mutable = local.mutable },
    );

    if (try resolveUpvalueRecursive(self, enc, name)) |slot| {
        const spec = self.functions.items[enc].upvalues.items[slot];
        return try addUpvalue(self, fn_idx, .{ .is_local = false, .index = @intCast(slot), .mutable = spec.mutable });
    }
    return null;
}

pub fn resolveUpvalue(self: *Compiler, name: []const u8) !?revo.UpvalueID {
    if (self.functions.items.len == 0) return null;
    return resolveUpvalueRecursive(self, self.functions.items.len - 1, name);
}

pub fn allocFnSig(
    self: *Compiler,
    params: []const cst.CstParam,
    return_type: ?*const cst.CstType,
    type_params: []const []const u8,
) !*types.FunctionSignature {
    return try types.buildFnSig(
        self.alloc,
        self,
        params,
        return_type,
        type_params,
        null,
        .{ .degrade_param = true, .want_defaults = true },
    );
}

pub fn declareFnSignature(
    self: *Compiler,
    name: []const u8,
    params: []const cst.CstParam,
    return_type: ?*const cst.CstType,
    type_params: []const []const u8,
) !void {
    const state = currentFunctionState(self) orelse return;
    if (cst.isDiscardName(name)) return;
    if (state.fn_signatures.get(name)) |old| {
        self.alloc.free(old.params);
        self.alloc.free(old.param_names);
        if (old.default_values.len > 0) self.alloc.free(old.default_values);
        self.alloc.destroy(old);
        _ = state.fn_signatures.remove(name);
    }
    const sig = try allocFnSig(self, params, return_type, type_params);
    errdefer {
        self.alloc.free(sig.params);
        self.alloc.destroy(sig);
    }
    try state.fn_signatures.put(name, sig);
}

pub fn findFnSignature(self: *const Compiler, name: []const u8) ?*types.FunctionSignature {
    var i = self.functions.items.len;
    while (i > 0) {
        i -= 1;
        if (self.functions.items[i].fn_signatures.get(name)) |sig| return sig;
    }
    return null;
}
