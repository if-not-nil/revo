const std = @import("std");

const revo = @import("revo");
const Compiler = revo.lang.compiler.Compiler;
const LocalSlot = revo.LocalSlot;
const Register = revo.opcode.Register;
const UpvalueSpec = revo.functions.UpvalueSpec;

const ast = @import("../ast.zig");
const Node = ast.Node;
const emit = @import("emit.zig");

pub const LocalValueKind = enum { unknown, tuple_literal };

pub const LocalVar = struct {
    name: []const u8,
    slot: LocalSlot,
    mutable: bool,
    initialized: bool,
    kind: LocalValueKind = .unknown,
    type_name: ?[]const u8 = null,
    table_fields: ?[]const []const u8 = null,
};

pub const FunctionState = struct {
    alloc: std.mem.Allocator,
    locals: std.ArrayList(LocalVar),
    all_locals: std.ArrayList(LocalVar),
    upvalues: std.ArrayList(UpvalueSpec),
    scope_starts: std.ArrayList(usize),
    return_type: ?[]const u8 = null,
    var_types: std.StringHashMap(?[]const u8),
    fn_signatures: std.StringHashMap(*FnSig),

    pub const FnSig = struct {
        param_types: []const ?[]const u8,
        return_type: ?[]const u8,
    };

    pub fn init(alloc: std.mem.Allocator) !FunctionState {
        return .{
            .alloc = alloc,
            .locals = try std.ArrayList(LocalVar).initCapacity(alloc, 8),
            .all_locals = try std.ArrayList(LocalVar).initCapacity(alloc, 8),
            .upvalues = try std.ArrayList(UpvalueSpec).initCapacity(alloc, 4),
            .scope_starts = try std.ArrayList(usize).initCapacity(alloc, 8),
            .var_types = std.StringHashMap(?[]const u8).init(alloc),
            .fn_signatures = std.StringHashMap(*FnSig).init(alloc),
        };
    }

    pub fn deinit(self: *FunctionState, alloc: std.mem.Allocator) void {
        self.locals.deinit(alloc);
        self.all_locals.deinit(alloc);
        self.upvalues.deinit(alloc);
        self.scope_starts.deinit(alloc);
        self.var_types.deinit();
        var it = self.fn_signatures.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.value_ptr.*.param_types);
            alloc.destroy(entry.value_ptr.*);
        }
        self.fn_signatures.deinit();
    }
};

pub const Temps = struct { pipe: usize = 0, match_subject: usize = 0, bind: usize = 0, match_temp: usize = 0 };

pub fn LoopScope(comptime T: type) type {
    return struct {
        compiler: *T,
        break_start: usize,
        prev_in_loop: usize,
        pub fn init(compiler: *T) !@This() {
            const prev = compiler.in_loop_depth;
            compiler.in_loop_depth += 1;
            const result_reg = try pushRegister(compiler);
            try emit.appendRecorded(compiler, .{ .op = .load_nil, .a = result_reg });
            try compiler.loop_result_regs.append(compiler.alloc, result_reg);
            return .{ .compiler = compiler, .break_start = compiler.break_jumps.items.len, .prev_in_loop = prev };
        }
        pub fn deinit(self: *@This()) void {
            const c = self.compiler;
            _ = c.loop_result_regs.pop();
            const exit_addr: usize = c.instructions.items.len;
            while (c.break_jumps.items.len > self.break_start) {
                const idx = c.break_jumps.pop() orelse unreachable;
                emit.patchJumpToLabel(c, idx, exit_addr);
            }
            c.in_loop_depth = self.prev_in_loop;
        }
    };
}

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

pub fn currentFunctionState(self: *Compiler) ?*FunctionState {
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

fn currentScopeStart(self: *const Compiler, fn_idx: usize) usize {
    const state = &self.functions.items[fn_idx];
    if (state.scope_starts.items.len == 0) return 0;
    return state.scope_starts.items[state.scope_starts.items.len - 1];
}

pub fn pushScope(self: *Compiler) !void {
    const state = currentFunctionState(self) orelse return;
    try state.scope_starts.append(self.alloc, state.locals.items.len);
}

pub fn popScope(self: *Compiler) void {
    const state = currentFunctionState(self) orelse return;
    const start = state.scope_starts.pop() orelse return;
    state.locals.items.len = start;
}

pub fn findLocalInCurrentScope(self: *Compiler, name: []const u8) ?*LocalVar {
    const fn_idx = self.functions.items.len - 1;
    const state = &self.functions.items[fn_idx];
    const start = currentScopeStart(self, fn_idx);
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

pub fn markLocalInitialized(self: *Compiler, slot: LocalSlot) void {
    const state = currentFunctionState(self) orelse return;
    // current scope first
    var i = state.locals.items.len;
    while (i > 0) {
        i -= 1;
        if (state.locals.items[i].slot == slot) {
            state.locals.items[i].initialized = true;
            return;
        }
    }
    // then fallback to all_locals (covers cases where popScope trimmed the list)
    i = state.all_locals.items.len;
    while (i > 0) {
        i -= 1;
        if (state.all_locals.items[i].slot == slot) {
            state.all_locals.items[i].initialized = true;
            return;
        }
    }
}

pub fn markLocalValueKind(self: *Compiler, slot: LocalSlot, kind: LocalValueKind) void {
    const state = currentFunctionState(self) orelse return;
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

pub fn setLocalType(self: *Compiler, slot: LocalSlot, type_name: ?[]const u8) void {
    const state = currentFunctionState(self) orelse return;
    var i = state.locals.items.len;
    while (i > 0) {
        i -= 1;
        if (state.locals.items[i].slot == slot) {
            state.locals.items[i].type_name = type_name;
            break;
        }
    }
    i = state.all_locals.items.len;
    while (i > 0) {
        i -= 1;
        if (state.all_locals.items[i].slot == slot) {
            state.all_locals.items[i].type_name = type_name;
            break;
        }
    }
}

pub fn setLocalTableFields(self: *Compiler, slot: LocalSlot, fields: ?[]const []const u8) void {
    const state = currentFunctionState(self) orelse return;
    var i = state.locals.items.len;
    while (i > 0) {
        i -= 1;
        if (state.locals.items[i].slot == slot) {
            state.locals.items[i].table_fields = fields;
            break;
        }
    }
    i = state.all_locals.items.len;
    while (i > 0) {
        i -= 1;
        if (state.all_locals.items[i].slot == slot) {
            state.all_locals.items[i].table_fields = fields;
            break;
        }
    }
}

pub fn localHasTableField(self: *const Compiler, name: []const u8, field_name: []const u8) bool {
    const local = resolveLocalVar(self, name) orelse return false;
    const fields = local.table_fields orelse return false;
    for (fields) |f| {
        if (std.mem.eql(u8, f, field_name)) return true;
    }
    return false;
}

pub fn predeclareFunctionBindings(self: *Compiler, exprs: []const *Node) !void {
    for (exprs) |expr| switch (expr.expr) {
        .con_expr, .let_expr => |binding| {
            if (binding.target.expr != .ident or binding.value.expr != .fn_expr) continue;
            const name = binding.target.expr.ident;
            if (ast.isDiscardName(name)) continue;
            _ = try reuseOrDeclareLocal(self, name, expr.expr == .let_expr);
            try declareFnSignature(self, name, binding.value.expr.fn_expr.params, binding.value.expr.fn_expr.return_type);
        },
        else => {},
    };
}

pub fn resolveLocalVarIn(self: *const Compiler, fn_idx: usize, name: []const u8) ?LocalVar {
    const locals = self.functions.items[fn_idx].locals.items;
    var i = locals.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, locals[i].name, name)) return locals[i];
    }
    return null;
}

pub fn resolveLocal(self: *const Compiler, name: []const u8) ?LocalSlot {
    if (self.functions.items.len == 0) return null;
    return if (resolveLocalVarIn(self, self.functions.items.len - 1, name)) |v| v.slot else null;
}

pub fn resolveLocalVar(self: *const Compiler, name: []const u8) ?LocalVar {
    if (self.functions.items.len == 0) return null;
    return resolveLocalVarIn(self, self.functions.items.len - 1, name);
}

pub fn constTupleIndex(self: *const Compiler, index: anytype) ?usize {
    const key_num = switch (index.key.expr) {
        .number => |n| n.value,
        else => return null,
    };
    if (!std.math.isFinite(key_num) or @floor(key_num) != key_num or key_num < 0 or key_num > @as(f64, @floatFromInt(std.math.maxInt(usize)))) return null;
    const is_tuple = switch (index.object.expr) {
        .ident => |name| blk: {
            const l = resolveLocalVar(self, name) orelse break :blk false;
            break :blk l.kind == .tuple_literal;
        },
        .tuple => true,
        else => false,
    };
    if (!is_tuple) return null;
    return @as(usize, @intFromFloat(key_num));
}

pub fn addUpvalue(self: *Compiler, fn_idx: usize, spec: UpvalueSpec) !revo.UpvalueID {
    const state = &self.functions.items[fn_idx];
    for (state.upvalues.items, 0..) |existing, idx| {
        if (existing.is_local == spec.is_local and existing.index == spec.index and existing.mutable == spec.mutable) return @intCast(idx);
    }
    const id: revo.UpvalueID = @intCast(state.upvalues.items.len);
    try state.upvalues.append(self.alloc, spec);
    return id;
}

pub fn resolveUpvalueRecursive(self: *Compiler, fn_idx: usize, name: []const u8) !?revo.UpvalueID {
    if (fn_idx == 0) return null;
    const enc = fn_idx - 1;
    if (resolveLocalVarIn(self, enc, name)) |local| return try addUpvalue(self, fn_idx, .{ .is_local = true, .index = local.slot, .mutable = local.mutable });
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

pub fn collectConstLocals(self: *Compiler, locals: []const LocalVar) ![]LocalSlot {
    var out = try std.ArrayList(LocalSlot).initCapacity(self.alloc, locals.len);
    defer out.deinit(self.alloc);
    for (locals) |local| if (!local.mutable) try out.append(self.alloc, local.slot);
    return out.toOwnedSlice(self.alloc);
}

pub fn allocFnSig(self: *Compiler, params: []const ast.FnParam, return_type: ?[]const u8) !*FunctionState.FnSig {
    const sig = try self.alloc.create(FunctionState.FnSig);
    errdefer self.alloc.destroy(sig);

    var param_types = try std.ArrayList(?[]const u8).initCapacity(self.alloc, params.len);
    errdefer param_types.deinit(self.alloc);
    for (params) |p| try param_types.append(self.alloc, p.type_name);

    sig.* = .{
        .param_types = try param_types.toOwnedSlice(self.alloc),
        .return_type = return_type,
    };
    return sig;
}

pub fn declareFnSignature(self: *Compiler, name: []const u8, params: []const ast.FnParam, return_type: ?[]const u8) !void {
    const state = currentFunctionState(self) orelse return;
    if (ast.isDiscardName(name)) return;
    if (state.fn_signatures.get(name) != null) return;
    const sig = try allocFnSig(self, params, return_type);
    errdefer {
        self.alloc.free(sig.param_types);
        self.alloc.destroy(sig);
    }
    try state.fn_signatures.put(name, sig);
}

pub fn findFnSignature(self: *const Compiler, name: []const u8) ?*FunctionState.FnSig {
    var i = self.functions.items.len;
    while (i > 0) {
        i -= 1;
        if (self.functions.items[i].fn_signatures.get(name)) |sig| return sig;
    }
    return null;
}
