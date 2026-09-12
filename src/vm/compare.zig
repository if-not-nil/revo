///
/// comparison spec
///
/// - when tags differ: eq/neq -> false/true; ordered ops -> type error
/// - when same type: numbers/strings compare by value; atoms/functions by id;
///   tables compare by value (array part in order, then keyed entries)
///
const std = @import("std");
const Data = @import("memory.zig").Data;
const BOX_MASK = @import("memory.zig").BOX_MASK;
const BOX_TAG = @import("memory.zig").BOX_TAG;
const VM = @import("VM.zig");
const Instruction = @import("opcode.zig").Instruction;
const Opcode = @import("opcode.zig").Opcode;

/// deep value equality for two table ids; identity is the fast path
fn tablesEqual(vm: *VM, lid: usize, rid: usize) bool {
    if (lid == rid) return true;
    const l_table = vm.tables.get(lid) catch return false;
    const r_table = vm.tables.get(rid) catch return false;
    if (l_table.count() != r_table.count()) return false;

    if (l_table.array.items.len != r_table.array.items.len) return false;
    for (l_table.array.items, 0..) |l_val, i| {
        if (compare(vm, l_val, r_table.array.items[i]) != .eq) return false;
    }

    var it = l_table.hash.orderedIterator();
    while (it.next()) |entry| {
        const r_val = r_table.getRaw(entry.key, vm) orelse return false;
        if (compare(vm, entry.value, r_val) != .eq) return false;
    }
    return true;
}

pub fn compare(vm: *VM, lh: Data, rh: Data) std.math.Order {
    // numbers
    // ; nan is unordered so it equals nothing
    //   (not even itself here, identical bits already shortcut in fastEq,
    //     and orders as .gt, the incomparable sentinel below)
    if (lh.asNum()) |ln| if (rh.asNum()) |rn| {
        if (std.math.isNan(ln) or std.math.isNan(rn)) return .gt;
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

    // atoms
    if (lh.asAtom()) |la| if (rh.asAtom()) |ra| {
        if (la == ra) return .eq;
        return if (la < ra) .lt else .gt;
    };

    // deep value comparison for tables
    if (lh.asTable()) |lid| if (rh.asTable()) |rid| {
        return if (tablesEqual(vm, lid, rid)) .eq else .gt;
    };

    return .gt;
}

pub inline fn evalCachedFast(
    slots: []Data,
    base: usize,
    vm: *VM,
    instr: Instruction,
    comptime op: Opcode,
) VM.EvalError!void {
    const lhs = VM.regRead(slots, base, instr.b);
    const rhs = VM.regRead(slots, base, instr.c);

    // fast path: both values are numbers
    //
    // for eq/neq: either being unboxed means a number is involved; a boxed
    // non-number bitcasts to a NaN, and NaN != NaN below does the correct
    // false/true result (tags differ). for ordered ops require both unboxed,
    // which guarantees real doubles (the boxed marker is the quiet-NaN
    // pattern; all real doubles, including +-inf, differ from it), so no
    // NaN branch is needed
    if (comptime op == .eq or op == .neq) {
        if ((lhs.bits & rhs.bits & BOX_MASK) != BOX_TAG) {
            const lf: f64 = @bitCast(lhs.bits);
            const rf: f64 = @bitCast(rhs.bits);
            if (lf != lf or rf != rf) {
                VM.regWrite(slots, base, instr.a, Data.new.boolean(op == .neq));
                return;
            }
            const is_eq = lf == rf;
            VM.regWrite(slots, base, instr.a, Data.new.boolean(if (op == .eq) is_eq else !is_eq));
            return;
        }
    } else {
        if ((lhs.bits & BOX_MASK) != BOX_TAG and
            (rhs.bits & BOX_MASK) != BOX_TAG)
        {
            const lf: f64 = @bitCast(lhs.bits);
            const rf: f64 = @bitCast(rhs.bits);
            const result = switch (op) {
                .lt => lf < rf,
                .gt => lf > rf,
                .lte => lf <= rf,
                .gte => lf >= rf,
                else => unreachable,
            };
            VM.regWrite(slots, base, instr.a, Data.new.boolean(result));
            return;
        }
    }

    // per IEEE 754 nan is unordered so all comparisons with NaN are false and neq is true
    if (lhs.asNum()) |ln| {
        if (rhs.asNum()) |rn| {
            if (std.math.isNan(ln) or std.math.isNan(rn)) {
                VM.regWrite(slots, base, instr.a, Data.new.boolean(op == .neq));
                return;
            }
        }
    }

    if (comptime op == .eq or op == .neq) {
        // fast path: boxed values; identical bits = identity = equality
        // strings are value types, fall through to compare()
        if ((lhs.bits & BOX_MASK) == BOX_TAG) {
            const tag = lhs.tag();
            if (tag != .string and tag != .number and tag != .table) {
                const is_eq = lhs.bits == rhs.bits;
                VM.regWrite(slots, base, instr.a, Data.new.boolean(if (op == .eq) is_eq else !is_eq));
                return;
            }
        }
        // fast path: both are numbers; compare raw bits (handles +-0)
        if ((rhs.bits & BOX_MASK) != BOX_TAG) {
            const SIGN_MASK: u64 = @as(u64, 1) << 63;
            if (lhs.bits == rhs.bits) {
                VM.regWrite(slots, base, instr.a, Data.new.boolean(op == .eq));
                return;
            }
            if ((lhs.bits | SIGN_MASK) == (rhs.bits | SIGN_MASK) and (lhs.bits & ~SIGN_MASK) == 0) {
                VM.regWrite(slots, base, instr.a, Data.new.boolean(op == .eq));
                return;
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
        .number, .string => true,
        else => false,
    };

    if (!supports_order) {
        switch (op) {
            .eq, .neq => {
                const is_eq = switch (l_tag) {
                    .atom => lhs.asAtom().? == rhs.asAtom().?,
                    .function => lhs.asFunction().? == rhs.asFunction().?,
                    .table => blk: {
                        break :blk tablesEqual(
                            vm,
                            lhs.asTable().?,
                            rhs.asTable().?,
                        );
                    },
                    .foreign => lhs.asForeign().? == rhs.asForeign().?,
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

pub fn fastEq(vm: *VM, a: Data, b: Data) bool {
    if (a.bits == b.bits) return true;
    if (a.tag() != b.tag()) return false;
    return (compare(vm, a, b) == .eq);
}
