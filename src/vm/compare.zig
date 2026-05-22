/// comparison spec
///
/// when tags differ:
///    - eq/neq return false/true respectively
///    - ordered ops (< > <= >=) throw typeerror with message
/// when same-type:
///    - atoms/functions/tables: identity only, eq/neq compare ids, ordered ops crash
///    - numbers
///    - strings: lexicographic byte-order comparison
///    - tuples: recursive (for nested tuples) lexicographic element-wise comparison, length breaks ties
const std = @import("std");
const revo = @import("revo");
const Data = @import("memory.zig").Data;
const VM = @import("VM.zig");
const Instruction = @import("opcode.zig").Instruction;
const Opcode = @import("opcode.zig").Opcode;

pub fn compare(vm: *VM, lh: Data, rh: Data) std.math.Order {
    // numbers
    if (lh == .number and rh == .number) {
        const ln = lh.as_number() catch return .eq;
        const rn = rh.as_number() catch return .eq;
        if (ln < rn) return .lt;
        if (ln > rn) return .gt;
        return .eq;
    }

    // strings
    if (lh == .string and rh == .string) {
        const lid = lh.string;
        const rid = rh.string;
        if (lid == rid) return .eq;
        const l_str = vm.stringValue(lid);
        const r_str = vm.stringValue(rid);
        return std.mem.order(u8, l_str, r_str);
    }

    // tuples
    if (lh == .tuple and rh == .tuple) {
        const lid = lh.tuple;
        const rid = rh.tuple;
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
    }

    return .gt;
}

pub inline fn eval(vm: *VM, instr: Instruction, comptime op: Opcode) VM.EvalError!void {
    const lhs = try vm.readRegister(instr.b);
    const rhs = try vm.readRegister(instr.c);
    return evalImpl(vm, lhs, rhs, instr, op);
}

/// cached version; takes pre-fetched slots and base (no currentFiber calls)
pub inline fn evalCached(slots: []Data, base: usize, vm: *VM, instr: Instruction, comptime op: Opcode) VM.EvalError!void {
    const lhs = VM.regRead(slots, base, instr.b);
    const rhs = VM.regRead(slots, base, instr.c);
    return evalImpl(vm, lhs, rhs, instr, op);
}

fn evalImpl(vm: *VM, lhs: Data, rhs: Data, instr: Instruction, comptime op: Opcode) VM.EvalError!void {

    // type check
    const l_tag = std.meta.activeTag(lhs);
    const r_tag = std.meta.activeTag(rhs);

    if (l_tag != r_tag) {
        switch (op) {
            .eq, .neq => {
                try vm.writeRegister(instr.a, Data.new.boolean(op == .eq));
                return;
            },
            else => {
                try vm.setRuntimeMessageFmt("cannot compare {s} with {s}", .{ @tagName(l_tag), @tagName(r_tag) });
                return error.TypeError;
            },
        }
    }

    // check if type supports ordered comparison
    const supports_order = switch (l_tag) {
        .number, .string, .tuple => true,
        else => false,
    };

    if (!supports_order) {
        switch (op) {
            .eq, .neq => {
                // identity check for atoms/functions/tables
                const is_eq = switch (l_tag) {
                    .atom => lhs.atom == rhs.atom,
                    .function => lhs.function == rhs.function,
                    .table => lhs.table == rhs.table,
                    else => unreachable,
                };
                try vm.writeRegister(instr.a, Data.new.boolean(if (op == .eq) is_eq else !is_eq));
                return;
            },
            else => {
                try vm.setRuntimeMessageFmt("cannot compare {s} with {s}", .{ @tagName(l_tag), @tagName(r_tag) });
                return error.TypeError;
            },
        }
    }

    // default comparison for numbers/strings/tuples
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

    try vm.writeRegister(instr.a, Data.new.boolean(result));
}
