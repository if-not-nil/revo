/// comparison spec
///
/// - when tags differ: eq/neq -> false/true; ordered ops -> type error
/// - when same type: numbers/strings/tuples compare by value; atoms/functions/tables by id
/// note: NaNs are canonicalized so fast bitwise equality may treat NaN as equal
const std = @import("std");
const Data = @import("memory.zig").Data;
const BOX_MASK = @import("memory.zig").BOX_MASK;
const VM = @import("VM.zig");
const Instruction = @import("opcode.zig").Instruction;
const Opcode = @import("opcode.zig").Opcode;

pub fn compare(vm: *VM, lh: Data, rh: Data) std.math.Order {
    // numbers
    if (lh.asNum()) |ln| if (rh.asNum()) |rn| {
        if (ln < rn) return .lt;
        if (ln > rn) return .gt;
        return .eq;
    };

    // strings
    if (lh.asString()) |lid| if (rh.asString()) |rid| {
        if (lid == rid) return .eq;
        const l_str = vm.stringValue(lid);
        const r_str = vm.stringValue(rid);
        return std.mem.order(u8, l_str, r_str);
    };

    // tuples
    if (lh.asTuple()) |lid| if (rh.asTuple()) |rid| {
        if (lid == rid) return .eq;
        const l_tuple = vm.tuples.get(lid) catch return .eq;
        const r_tuple = vm.tuples.get(rid) catch return .eq;
        const min_len = @min(l_tuple.items.len, r_tuple.items.len);
        var i: usize = 0;
        while (i < min_len) : (i += 1) {
            const item_order = compare(vm, l_tuple.items[i], r_tuple.items[i]);
            if (item_order != .eq) return item_order;
        }
        return std.math.order(l_tuple.items.len, r_tuple.items.len);
    };

    // atoms
    if (lh.asAtom()) |la| if (rh.asAtom()) |ra| {
        if (la == ra) return .eq;
        return if (la < ra) .lt else .gt;
    };

    return .gt;
}

pub fn evalCachedFast(slots: []Data, base: usize, vm: *VM, instr: Instruction, comptime op: Opcode) VM.EvalError!void {
    const lhs = VM.regRead(slots, base, instr.b);
    const rhs = VM.regRead(slots, base, instr.c);

    if (comptime op == .eq or op == .neq) {
        // fast path: boxed values; identical bits = identity = equality
        if ((lhs.bits & BOX_MASK) == BOX_MASK) {
            const is_eq = lhs.bits == rhs.bits;
            VM.regWrite(slots, base, instr.a, Data.new.boolean(if (op == .eq) is_eq else !is_eq));
            return;
        }
        // fast path: both are numbers; compare raw bits (handles +-0 and nan)
        if ((rhs.bits & BOX_MASK) != BOX_MASK) {
            const SIGN_MASK: u64 = @as(u64, 1) << 63;
            const CANONICAL_NAN: u64 = 0x7FF8_0000_0000_0000;
            if (lhs.bits == rhs.bits) {
                if (lhs.bits != CANONICAL_NAN) {
                    VM.regWrite(slots, base, instr.a, Data.new.boolean(op == .eq));
                    return;
                }
            } else {
                if ((lhs.bits | SIGN_MASK) == (rhs.bits | SIGN_MASK) and (lhs.bits & ~SIGN_MASK) == 0) {
                    VM.regWrite(slots, base, instr.a, Data.new.boolean(op == .eq));
                    return;
                }
            }
        }
    }

    const l_tag = lhs.tag();
    const r_tag = rhs.tag();

    if (l_tag != r_tag) {
        switch (op) {
            .eq, .neq => {
                VM.regWrite(slots, base, instr.a, Data.new.boolean(op == .neq));
                return;
            },
            else => {
                try vm.setRuntimeMessageFmt("cannot compare {s} with {s}", .{ @tagName(l_tag), @tagName(r_tag) });
                return error.TypeError;
            },
        }
    }

    const supports_order = switch (l_tag) {
        .number, .string, .tuple => true,
        else => false,
    };

    if (!supports_order) {
        switch (op) {
            .eq, .neq => {
                const is_eq = switch (l_tag) {
                    .atom => lhs.asAtom().? == rhs.asAtom().?,
                    .function => lhs.asFunction().? == rhs.asFunction().?,
                    .table => lhs.asTable().? == rhs.asTable().?,
                    .struct_val => lhs.asStructVal().? == rhs.asStructVal().?,
                    .struct_type => lhs.asStructType().? == rhs.asStructType().?,
                    else => unreachable,
                };
                VM.regWrite(slots, base, instr.a, Data.new.boolean(if (op == .eq) is_eq else !is_eq));
                return;
            },
            else => {
                try vm.setRuntimeMessageFmt("cannot compare {s} with {s}", .{ @tagName(l_tag), @tagName(r_tag) });
                return error.TypeError;
            },
        }
    }

    const order = compare(vm, lhs, rhs);

    const result = switch (op) {
        .eq => order == .eq,
        .neq => order != .eq,
        .lt => order == .lt,
        .gt => order == .gt,
        .lte => order != .gt,
        .gte => order != .lt,
        else => unreachable,
    };

    VM.regWrite(slots, base, instr.a, Data.new.boolean(result));
}
