// zlint-disable line-length -- yeah
//! loop-carried register promotion, runs after `peephole.peepholeIr`
//!
//! keeps loop-carried locals in dedicated vm registers instead of loading and
//! storing them from slots on every iteration. the slot is loaded once before
//! the loop and stored once on exit (and on breaks). the loop body just writes
//! the register directly
//!
//! only simple linear accumulator chains are promoted (like `r = r + 1`)
//! stores must come from 2-operand ops reading the accumulator and a leaf
//! operand. plain reads become copies from the promoted register. complex
//! logic, closures, yields, and nested loops are skipped
//!
//! promoted registers are placed above all used registers and callee frames
//! so nothing can clobber them. the accumulator chain uses the promoted
//! register and the one right above it. loop conditions keep their own registers
//!
//! calls inside the loop are only allowed if the callee is a local closure
//! with a fixed frame size and no nested calls. dynamic or recursive callees
//! reject the loop because their frame sizes are unbounded

const std = @import("std");

const revo = @import("revo");
const Compiler = revo.lang.compiler.Compiler;
const Opcode = revo.opcode.Opcode;
const Register = revo.opcode.Register;
const LocalSlot = revo.LocalSlot;

const dce = @import("dce.zig");
const ir = @import("root.zig");

pub fn promoteLoopCarried(self: *Compiler) !void {
    const insts = self.ir_builder.instructions.items;
    const n = insts.len;
    if (n < 2) return;

    var inst_idx = std.AutoHashMap(*ir.IrInst, usize).init(self.alloc);
    defer inst_idx.deinit();
    for (insts, 0..) |inst, i| try inst_idx.put(inst, i);

    // find the highest register used in the function so promoted registers
    // can live above it
    var max_touched: usize = 0;
    for (insts) |inst| {
        var buf: [128]Register = undefined;
        const rcnt = dce.readRegs(inst, &buf);
        var high: usize = inst.result_reg;
        for (buf[0..rcnt]) |r| high = @max(high, r);
        if (high > max_touched) max_touched = high;
    }

    var chains = try std.ArrayList(Chain).initCapacity(self.alloc, 4);
    defer {
        for (chains.items) |*c| c.deinit(self.alloc);
        chains.deinit(self.alloc);
    }

    var claimed_leaves = std.AutoHashMap(*ir.IrInst, void).init(self.alloc);
    defer claimed_leaves.deinit();

    // loops can have multiple back-edges (main loop plus `continue`). only
    // promote the outermost one. promoting a `continue` edge would put the
    // prologue and epilogue inside the loop instead of at the real exit
    var best = std.AutoHashMap(usize, usize).init(self.alloc);
    defer best.deinit();
    for (insts, 0..) |inst, i| {
        const t = inst.op_arg;
        if (!ir.isBranch(inst.opcode) or t >= i) continue;
        const prev = best.get(t) orelse 0;
        if (i > prev) try best.put(t, i);
    }

    // find the max register window used by any valid call in the loop
    // promoted registers must live above this window
    var max_call_extent: usize = 0;
    var bit = best.iterator();
    while (bit.next()) |e| {
        const t = e.key_ptr.*;
        const i = e.value_ptr.*;
        if (inNestedFn(insts, t, i)) continue;
        var loop_extent: usize = 0;
        if (!try loopIsSimple(self, insts, t, i, &loop_extent)) continue;
        if (loop_extent > max_call_extent) max_call_extent = loop_extent;
        try collectChains(self, &chains, &claimed_leaves, insts, inst_idx, t, i);
    }
    if (chains.items.len == 0) return;

    const loop_base = @max(max_touched, max_call_extent);

    // keep promoted registers inside the 8-bit register limit. only promote
    // each slot once to avoid conflicts between sibling loops
    var promoted = try std.ArrayList(*Chain).initCapacity(self.alloc, 4);
    defer promoted.deinit(self.alloc);
    var promoted_slots = std.AutoHashMap(LocalSlot, void).init(self.alloc);
    defer promoted_slots.deinit();
    var next_reg = loop_base + 1;
    for (chains.items) |*c| {
        if (next_reg + 2 > register_limit) continue;
        if (promoted_slots.contains(c.slot)) continue;
        try promoted_slots.put(c.slot, {});
        try promoted.append(self.alloc, c);
        next_reg += 2;
    }
    if (promoted.items.len == 0) return;

    // assign new register pairs and map slots to their chains
    var slot_chain = std.AutoHashMap(LocalSlot, *Chain).init(self.alloc);
    defer slot_chain.deinit();
    for (promoted.items, 0..) |c, k| {
        c.R = @intCast(loop_base + 1 + 2 * k);
        try slot_chain.put(c.slot, c);
    }

    // find instructions that read the old accumulator register by fixed position
    // insert a `move` to copy the new promoted register back to the old one
    // so these instructions still work after renaming
    var inserts = try std.ArrayList(Insert).initCapacity(self.alloc, 4);
    defer inserts.deinit(self.alloc);

    for (promoted.items) |c| {
        try scanRemats(self, c, insts, &inserts);
    }

    // update the loop body: rename accumulators to promoted registers,
    // drop redundant loads/stores, and turn plain reads into copies
    var deleted = try self.alloc.alloc(bool, n);
    defer self.alloc.free(deleted);
    @memset(deleted, false);

    for (promoted.items) |c| {
        for (c.chain_ops.items) |op| op.result_reg = c.R;
        for (c.leaves.items) |leaf| {
            leaf.result_reg = c.R + 1;
            if (leaf.opcode == .load_local) {
                const other: LocalSlot = @intCast(leaf.op_arg);
                if (slot_chain.get(other)) |other_chain| {
                    if (other_chain.t == c.t and other_chain.slot != c.slot) {
                        // if the operand is another promoted accumulator in this
                        // loop, copy its register directly instead of loading
                        self.alloc.free(leaf.operands);
                        leaf.operands = try self.alloc.dupe(ir.IrValue, &.{.{ .reg = other_chain.R }});
                        leaf.opcode = .move;
                    }
                }
            }
        }
        for (c.stores.items) |store| {
            const idx = inst_idx.get(store).?;
            deleted[idx] = true;
        }
        for (c.chain_loads.items) |load| {
            const idx = inst_idx.get(load).?;
            deleted[idx] = true;
        }
        for (c.readers.items) |reader| {
            self.alloc.free(reader.operands);
            reader.operands = try self.alloc.dupe(ir.IrValue, &.{.{ .reg = c.R }});
            reader.opcode = .move;
            reader.op_arg = 0;
        }
        // loop results are handled by `normalizeLoopResult` and `scanRemats`,
        // so nothing extra is needed here

        const prologue = try self.alloc.create(ir.IrInst);
        prologue.* = .{
            .opcode = .load_local,
            .operands = try self.alloc.dupe(ir.IrValue, &.{}),
            .result_reg = c.R,
            .op_arg = c.slot,
        };
        c.prologue_inst = prologue;
        const epilogue = try self.alloc.create(ir.IrInst);
        epilogue.* = .{
            .opcode = .store_local,
            .operands = try self.alloc.dupe(ir.IrValue, &.{.{ .reg = c.R }}),
            .result_reg = c.R,
            .op_arg = c.slot,
        };
        try inserts.append(self.alloc, .{ .pos = c.prologue_pos, .inst = prologue, .kind = .prologue });
        try inserts.append(self.alloc, .{ .pos = c.epilogue_pos, .inst = epilogue, .kind = .epilogue });
    }
    std.sort.pdq(Insert, inserts.items, {}, lessThanInsert);

    // point users of dropped loads to the new prologue load before freeing them
    for (promoted.items) |c| {
        for (c.chain_loads.items) |load| {
            const idx = inst_idx.get(load).?;
            ir.repointUsers(insts, idx + 1, load, .{ .inst = c.prologue_inst.? });
        }
    }

    // rebuild the instruction list: drop deleted instructions, insert
    // prologues and epilogues, and update jump targets
    var new_insts = try std.ArrayList(*ir.IrInst).initCapacity(self.alloc, n + inserts.items.len);
    var new_spans = try std.ArrayList(revo.lang.ast.Span).initCapacity(self.alloc, n + inserts.items.len);
    var new_index = try self.alloc.alloc(usize, n);
    defer self.alloc.free(new_index);

    // track the first epilogue store at each position so loop breaks can
    // jump there to save all promoted slots before exiting
    var first_epilogue = std.AutoHashMap(usize, usize).init(self.alloc);
    defer first_epilogue.deinit();

    var insert_pos: usize = 0;
    var write: usize = 0;

    var i: usize = 0;
    while (i <= n) : (i += 1) {
        while (insert_pos < inserts.items.len and inserts.items[insert_pos].pos == i) : (insert_pos += 1) {
            const ins = inserts.items[insert_pos];
            const ins_idx = write;
            try new_insts.append(self.alloc, ins.inst);
            try new_spans.append(self.alloc, self.active_span);
            write += 1;
            if (ins.inst.opcode == .store_local) {
                const ep = try first_epilogue.getOrPut(ins.pos);
                if (!ep.found_existing) ep.value_ptr.* = ins_idx;
            }
        }
        if (i == n) break;
        const inst = insts[i];
        if (deleted[i]) {
            new_index[i] = write;
            self.alloc.free(inst.operands);
            self.alloc.destroy(inst);
            continue;
        }
        new_index[i] = write;
        try new_insts.append(self.alloc, inst);
        try new_spans.append(self.alloc, self.spans.items[i]);
        write += 1;
    }

    const out = new_insts.items;
    for (out) |inst| {
        if (!ir.isBranch(inst.opcode)) continue;
        if (inst.op_arg >= n) continue;
        inst.op_arg = new_index[inst.op_arg];
    }
    // redirect loop exits (false conditions, breaks) to the epilogue stores
    // so promoted slots are saved before leaving the loop
    for (promoted.items) |c| {
        const ep_idx = first_epilogue.get(c.epilogue_pos) orelse continue;
        const be_new = new_index[c.back_edge];
        for (c.t..c.back_edge + 1) |orig_k| {
            const inst = out[new_index[orig_k]];
            if (!ir.isBranch(inst.opcode)) continue;
            if (inst.op_arg > be_new) inst.op_arg = ep_idx;
        }
    }
    for (self.pending_prototypes.items) |proto_id| {
        const proto = &self.vm.functions.prototypes.items[proto_id];
        if (proto.addr < n) proto.addr = @intCast(new_index[proto.addr]);
    }

    self.ir_builder.instructions = new_insts;
    self.spans = new_spans;
    if (self.max_registers < next_reg) self.max_registers = next_reg;
    // only increase the register count for the current function's frame
    // nested closures keep their own smaller frame sizes
    for (self.pending_prototypes.items) |proto_id| {
        if (proto_id != self.current_proto) continue;
        const proto = &self.vm.functions.prototypes.items[proto_id];
        if (proto.register_count < next_reg) proto.register_count = @intCast(next_reg);
    }
}

const register_limit: usize = 250;

fn lessThanInsert(_: void, a: Insert, b: Insert) bool {
    if (a.pos != b.pos) return a.pos < b.pos;
    return insertOrder(a.kind) < insertOrder(b.kind);
}

fn insertOrder(k: Insert.Kind) u8 {
    return switch (k) {
        .prologue => 0,
        .reader => 1,
        .epilogue => 2,
    };
}

const Insert = struct {
    pos: usize,
    inst: *ir.IrInst,
    kind: Kind = .reader,

    const Kind = enum { prologue, reader, epilogue };
};

fn inList(list: []*ir.IrInst, inst: *ir.IrInst) bool {
    for (list) |x| if (x == inst) return true;
    return false;
}

const Chain = struct {
    slot: LocalSlot,
    r_old: Register,
    t: usize,
    back_edge: usize,
    prologue_pos: usize,
    epilogue_pos: usize,
    R: Register = 0,
    prologue_inst: ?*ir.IrInst = null,
    chain_ops: std.ArrayList(*ir.IrInst),
    chain_loads: std.ArrayList(*ir.IrInst),
    leaves: std.ArrayList(*ir.IrInst),
    stores: std.ArrayList(*ir.IrInst),
    readers: std.ArrayList(*ir.IrInst),

    fn init(alloc: std.mem.Allocator, slot: LocalSlot, r_old: Register, t: usize, back_edge: usize, prologue_pos: usize, epilogue_pos: usize) !Chain {
        return .{
            .slot = slot,
            .r_old = r_old,
            .t = t,
            .back_edge = back_edge,
            .prologue_pos = prologue_pos,
            .epilogue_pos = epilogue_pos,
            .chain_ops = try std.ArrayList(*ir.IrInst).initCapacity(alloc, 4),
            .chain_loads = try std.ArrayList(*ir.IrInst).initCapacity(alloc, 2),
            .leaves = try std.ArrayList(*ir.IrInst).initCapacity(alloc, 2),
            .stores = try std.ArrayList(*ir.IrInst).initCapacity(alloc, 2),
            .readers = try std.ArrayList(*ir.IrInst).initCapacity(alloc, 2),
        };
    }

    fn deinit(self: *Chain, alloc: std.mem.Allocator) void {
        self.chain_ops.deinit(alloc);
        self.chain_loads.deinit(alloc);
        self.leaves.deinit(alloc);
        self.stores.deinit(alloc);
        self.readers.deinit(alloc);
    }
};

/// checks if a loop is simple enough for promotion. rejects nested loops,
/// closures, fibers, and yields because promotion can't keep registers in sync
/// allows `continue` edges since they jump past the prologue. rejects labeled
/// breaks that exit outer scopes because they bypass the epilogue. allows
/// calls only to local closures with bounded frames and no nested calls
fn loopIsSimple(self: *Compiler, insts: []*ir.IrInst, t: usize, i: usize, out_extent: *usize) !bool {
    var extent: usize = 0;
    for (t..i) |k| {
        switch (insts[k].opcode) {
            .yield, .spawn, .closure, .call_field => return false,
            .call => {
                const info = callCalleeInfo(self, insts, k) orelse return false;
                if (protoBodyHasCalls(self, insts, info.proto)) return false;
                const window = insts[k].result_reg + info.rc;
                if (window > extent) extent = window;
            },
            else => {},
        }
        if (ir.isBranch(insts[k].opcode)) {
            const target = insts[k].op_arg;
            if (target < k and target != t) return false;
            if (target > i + 1) return false;
        }
    }
    out_extent.* = extent;
    return true;
}

const CalleeInfo = struct { proto: revo.PrototypeID, rc: usize };

/// finds the closure prototype and register count for a `.call` instruction
/// traces the callee register back through `move`s or single local loads
/// returns null for dynamic callees (upvalues, globals, call results) because
/// their frame sizes are unknown. stays within the current function depth so
/// nested frames don't leak into the resolution
fn callCalleeInfo(self: *Compiler, insts: []*ir.IrInst, k: usize) ?CalleeInfo {
    const call = insts[k];
    const depth = call.fn_depth;
    var reg = call.result_reg;
    var pos = k;
    var hops: usize = 0;
    while (hops < 8) : (hops += 1) {
        const origin = pos;
        pos = prevWrite(insts, pos, reg, depth) orelse return null;
        const def = insts[pos];
        if (branchBetween(insts, pos, origin, depth)) return null;
        switch (def.opcode) {
            .closure => {
                const proto_id = def.op_arg;
                const proto = &self.vm.functions.prototypes.items[proto_id];
                return .{ .proto = proto_id, .rc = proto.register_count };
            },
            .move => {
                if (def.operands.len != 1 or def.operands[0] != .reg) return null;
                reg = def.operands[0].reg;
            },
            .load_local => {
                const slot: LocalSlot = @intCast(def.op_arg);
                const src = slotSourceReg(insts, slot, pos, depth) orelse return null;
                reg = src.reg;
                pos = src.pos;
            },
            else => return null,
        }
    }
    return null;
}

const SlotSource = struct { reg: Register, pos: usize };

/// checks if a branch exists between two instructions at the same depth
/// used to ensure a definition strictly dominates its use, otherwise the
/// register might hold a different value on some paths
fn branchBetween(insts: []*ir.IrInst, from: usize, to: usize, depth: u16) bool {
    if (to <= from + 1) return false;
    for (insts[from + 1 .. to]) |inst| {
        if (inst.fn_depth == depth and ir.isBranch(inst.opcode)) return true;
    }
    return false;
}

/// ensures a local slot holding a callee is written exactly once before the
/// call. multiple writes mean the callee could change at runtime. returns the
/// source register and write position if valid, otherwise null
fn slotSourceReg(insts: []*ir.IrInst, slot: LocalSlot, at: usize, depth: u16) ?SlotSource {
    var found: ?SlotSource = null;
    for (insts, 0..) |inst, idx| {
        if (inst.fn_depth != depth) continue;
        if ((inst.opcode == .bind_local or inst.opcode == .store_local) and inst.op_arg == slot) {
            if (found != null or idx >= at) return null;
            found = .{ .reg = inst.result_reg, .pos = idx };
        }
    }
    return found;
}

fn prevWrite(insts: []*ir.IrInst, before: usize, reg: Register, depth: u16) ?usize {
    var k = before;
    while (k > 0) {
        k -= 1;
        const inst = insts[k];
        if (inst.fn_depth == depth and writesReg(inst, reg)) return k;
    }
    return null;
}

fn writesReg(inst: *ir.IrInst, reg: Register) bool {
    var wbuf: [3]Register = undefined;
    const wcnt = dce.writeRegs(inst, &wbuf);
    for (wbuf[0..wcnt]) |w| {
        if (w == reg) return true;
    }
    return false;
}

/// checks if a closure prototype contains any calls. returns true if it does,
/// which prevents promotion because nested calls create unpredictable register
/// frame sizes. native calls are indistinguishable at compile time, so any
/// call conservatively rejects the loop
fn protoBodyHasCalls(self: *Compiler, insts: []*ir.IrInst, proto_id: revo.PrototypeID) bool {
    var depth: ?u16 = null;
    for (insts) |inst| {
        if (inst.opcode == .closure and inst.op_arg == proto_id) {
            depth = inst.fn_depth + 1;
            break;
        }
    }
    const d = depth orelse return true;
    const addr = self.vm.functions.prototypes.items[proto_id].addr;
    if (addr >= insts.len) return true;
    for (insts[addr..]) |inst| {
        if (inst.fn_depth > d) continue;
        if (inst.fn_depth < d) break;
        switch (inst.opcode) {
            .call, .call_field => return true,
            else => {},
        }
    }
    return false;
}

/// skips promotion for loops inside nested closures. nested closures manage
/// their own separate register frames that don't cover the promoted registers
fn inNestedFn(insts: []*ir.IrInst, t: usize, i: usize) bool {
    return insts[t].fn_depth > 1 or insts[i].fn_depth > 1;
}

/// finds instructions that read the old accumulator register by fixed position
/// inserts a `move` to copy the promoted register back to the old one so
/// fixed-position reads remain valid after renaming
///
/// tracks the live accumulator value in the old register:
///   - chain ops and loads write the accumulator into `r_old`
///   - other writes replace it
///   - converted readers already put the value there
///   - the first read while the accumulator is live needs a copy-in move
fn scanRemats(
    self: *Compiler,
    c: *Chain,
    insts: []*ir.IrInst,
    inserts: *std.ArrayList(Insert),
) !void {
    const State = enum { none, pending, ready };
    var st: State = .none;
    for (c.t..c.back_edge + 1) |k| {
        const inst = insts[k];
        if (inList(c.chain_ops.items, inst) or inList(c.chain_loads.items, inst)) {
            st = .pending;
            continue;
        }
        if (inList(c.stores.items, inst)) continue;
        if (inList(c.readers.items, inst)) {
            if (inst.result_reg == c.r_old) st = .ready;
            continue;
        }
        if (inst.opcode == .range_loop) {
            if (writesReg(inst, c.r_old)) st = .none;
            continue;
        }
        var rbuf: [128]Register = undefined;
        const rcnt = dce.readRegs(inst, &rbuf);
        var reads_old = false;
        for (rbuf[0..rcnt]) |r| {
            if (r == c.r_old) {
                reads_old = true;
                break;
            }
        }
        if (reads_old and st == .pending) {
            // if an instruction reads the old accumulator by fixed position,
            // insert a `move` to copy the promoted register into the old one
            // loop result copies point at the promoted register directly
            if (inst.opcode == .move and inst.operands.len == 1 and inst.operands[0] == .reg and inst.operands[0].reg == c.r_old) {
                inst.operands[0] = .{ .reg = c.R };
            } else {
                const mv = try self.alloc.create(ir.IrInst);
                mv.* = .{
                    .opcode = .move,
                    .operands = try self.alloc.dupe(ir.IrValue, &.{.{ .reg = c.R }}),
                    .result_reg = c.r_old,
                    .op_arg = 0,
                };
                try inserts.append(self.alloc, .{ .pos = k, .inst = mv, .kind = .reader });
                st = .ready;
            }
        }
        if (writesReg(inst, c.r_old)) st = .none;
    }
}

fn isChainOp(op: Opcode) bool {
    return switch (op) {
        .add, .concat, .sub, .mul, .div, .mod, .band, .bor, .bxor, .shl, .shr, .int_div, .pow, .eq, .neq, .lt, .gt, .lte, .gte, .eq_int, .neq_int, .lt_int, .gt_int, .lte_int, .gte_int, .add_imm, .sub_imm, .mul_imm, .band_imm, .lt_int_imm => true,
        else => false,
    };
}

/// checks if an opcode is an immediate-operand operation (like `add_imm`)
/// these only use the accumulator register, so no extra leaf register is needed
fn isImmOp(op: Opcode) bool {
    return switch (op) {
        .add_imm, .sub_imm, .mul_imm, .band_imm, .lt_int_imm => true,
        else => false,
    };
}

/// checks if an opcode is a simple leaf operation (like loads or constants)
/// leaf operations are safe to rename and do not cause register spills
fn isLeaf(op: Opcode) bool {
    return switch (op) {
        .load_small_int, .load_const, .load_nil, .load_global, .load_stdlib_global, .load_upval, .load_local => true,
        else => false,
    };
}

const Reject = error{Reject};

const WalkError = Reject || std.mem.Allocator.Error;

fn collectChains(
    self: *Compiler,
    chains: *std.ArrayList(Chain),
    claimed_leaves: *std.AutoHashMap(*ir.IrInst, void),
    insts: []*ir.IrInst,
    inst_idx: std.AutoHashMap(*ir.IrInst, usize),
    t: usize,
    i: usize,
) !void {
    // group loads, stores, and bindings by local slot
    var loads = std.AutoHashMap(LocalSlot, std.ArrayList(usize)).init(self.alloc);
    defer {
        var it = loads.iterator();
        while (it.next()) |e| e.value_ptr.deinit(self.alloc);
        loads.deinit();
    }
    var stores = std.AutoHashMap(LocalSlot, std.ArrayList(usize)).init(self.alloc);
    defer {
        var it = stores.iterator();
        while (it.next()) |e| e.value_ptr.deinit(self.alloc);
        stores.deinit();
    }
    var bound = std.AutoHashMap(LocalSlot, void).init(self.alloc);
    defer bound.deinit();

    for (t..i + 1) |k| {
        const inst = insts[k];
        switch (inst.opcode) {
            .load_local => {
                const slot: LocalSlot = @intCast(inst.op_arg);
                const entry = try loads.getOrPut(slot);
                if (!entry.found_existing) entry.value_ptr.* = try std.ArrayList(usize).initCapacity(self.alloc, 4);
                try entry.value_ptr.append(self.alloc, k);
            },
            .store_local => {
                const slot: LocalSlot = @intCast(inst.op_arg);
                const entry = try stores.getOrPut(slot);
                if (!entry.found_existing) entry.value_ptr.* = try std.ArrayList(usize).initCapacity(self.alloc, 4);
                try entry.value_ptr.append(self.alloc, k);
            },
            .bind_local => {
                const slot: LocalSlot = @intCast(inst.op_arg);
                try bound.put(slot, {});
            },
            else => {},
        }
    }

    var it = stores.iterator();
    while (it.next()) |entry| {
        const slot = entry.key_ptr.*;
        if (bound.contains(slot)) continue;
        const load_list = loads.get(slot) orelse continue;

        // ensure all stores to this slot write to the same register
        const store_list = entry.value_ptr;
        var r_old: ?Register = null;
        var all_stores = true;
        for (store_list.items) |k| {
            const reg = insts[k].result_reg;
            if (r_old == null) {
                r_old = reg;
            } else if (r_old.? != reg) {
                all_stores = false;
                break;
            }
        }
        if (!all_stores) continue;

        const ro = r_old.?;
        const back_edge = i;
        const prologue_pos = if (insts[i].opcode == .range_loop) blk: {
            if (t > 0 and ir.isBranch(insts[t - 1].opcode) and insts[t - 1].op_arg >= t and insts[t - 1].op_arg <= i) {
                break :blk t - 1;
            }
            continue;
        } else t;

        var c = try Chain.init(self.alloc, slot, ro, t, back_edge, prologue_pos, i + 1);
        var committed = false;
        defer if (!committed) c.deinit(self.alloc);
        var visited = std.AutoHashMap(*ir.IrInst, void).init(self.alloc);
        defer visited.deinit();

        // trace the accumulator dataflow backward from each store
        var walk_ok = true;
        for (store_list.items) |k| {
            const store = insts[k];
            try c.stores.append(self.alloc, store);
            if (store.operands.len != 1) {
                walk_ok = false;
                break;
            }
            const val = store.operands[0];
            if (val != .inst or val.inst.result_reg != ro) {
                walk_ok = false;
                break;
            }
            tryWalk(self, &c, &visited, claimed_leaves, val.inst, slot, ro, inst_idx, t, i) catch |err| switch (err) {
                error.Reject => {
                    walk_ok = false;
                    break;
                },
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
        if (!walk_ok) continue;
        if (c.chain_loads.items.len == 0) continue;

        // change simple in-loop reads of the slot to register copies
        for (load_list.items) |k| {
            const load = insts[k];
            var is_chain = false;
            for (c.chain_loads.items) |cl| {
                if (cl == load) {
                    is_chain = true;
                    break;
                }
            }
            if (!is_chain) try c.readers.append(self.alloc, load);
        }
        try chains.append(self.alloc, c);
        committed = true;
    }
}

fn tryWalk(
    self: *Compiler,
    c: *Chain,
    visited: *std.AutoHashMap(*ir.IrInst, void),
    claimed_leaves: *std.AutoHashMap(*ir.IrInst, void),
    inst: *ir.IrInst,
    slot: LocalSlot,
    r_old: Register,
    inst_idx: std.AutoHashMap(*ir.IrInst, usize),
    t: usize,
    i: usize,
) WalkError!void {
    if (visited.contains(inst)) return;
    try visited.put(inst, {});
    const idx = inst_idx.get(inst) orelse return error.Reject;
    if (idx < t or idx > i) return error.Reject;

    if (inst.opcode == .load_local) {
        if (inst.op_arg != slot or inst.result_reg != r_old) return error.Reject;
        try c.chain_loads.append(self.alloc, inst);
        return;
    }
    if (!isChainOp(inst.opcode)) return error.Reject;
    if (inst.result_reg != r_old) return error.Reject;
    if (inst.operands.len == 1 and isImmOp(inst.opcode)) {
        // immediate operations only use the accumulator, no leaf register needed
        const lhs = inst.operands[0];
        if (lhs != .inst) return error.Reject;
        try tryWalk(self, c, visited, claimed_leaves, lhs.inst, slot, r_old, inst_idx, t, i);
        try c.chain_ops.append(self.alloc, inst);
        return;
    }
    if (inst.operands.len != 2) return error.Reject;
    const lhs = inst.operands[0];
    const rhs = inst.operands[1];
    if (lhs != .inst or rhs != .inst) return error.Reject;
    // trace the accumulator side backward through the chain
    try tryWalk(self, c, visited, claimed_leaves, lhs.inst, slot, r_old, inst_idx, t, i);
    // the other operand must be a simple leaf in the next register
    if (!isLeaf(rhs.inst.opcode)) return error.Reject;
    if (rhs.inst.result_reg != r_old + 1) return error.Reject;
    if (rhs.inst.opcode == .load_local and rhs.inst.op_arg == slot) return error.Reject;
    if (claimed_leaves.contains(rhs.inst)) return error.Reject;
    try claimed_leaves.put(rhs.inst, {});
    try c.leaves.append(self.alloc, rhs.inst);
    try c.chain_ops.append(self.alloc, inst);
}
