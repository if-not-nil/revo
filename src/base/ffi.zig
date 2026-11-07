//
// ffi descriptors + marshalling
//
// no libffi here
// . this is compilable everywhere.
//

const std = @import("std");

const revo = @import("../root.zig");
const Value = revo.Value;
const VM = revo.VM;

/// c types can marshal
/// same decls mean the same bytes on every target
pub const FfiType = enum {
    i32,
    u32,
    i64,
    u64,
    f32,
    f64,
    boolean,
    ptr,
    void,
    string,

    pub fn fromName(name: []const u8) ?FfiType {
        const map = std.StaticStringMap(FfiType).initComptime(.{
            .{ "i32", .i32 },
            .{ "u32", .u32 },
            .{ "i64", .i64 },
            .{ "u64", .u64 },
            .{ "f32", .f32 },
            .{ "f64", .f64 },
            .{ "bool", .boolean },
            .{ "ptr", .ptr },
            .{ "void", .void },
            .{ "string", .string },
        });
        return map.get(name);
    }

    pub fn fromAtom(vm: *VM, id: revo.AtomID) ?FfiType {
        return fromName(vm.stringValue(id));
    }

    /// abi sizes. int/float widths fixed; ptr follows target
    pub fn sizeOf(t: FfiType) usize {
        return switch (t) {
            .i32, .u32, .f32 => 4,
            .i64, .u64, .f64, .ptr => 8,
            .boolean => 1,
            .void => 0,
            .string => @sizeOf(usize),
        };
    }
};

/// revo number to c int
/// . exact only: fractions, inf/nan, out-of-range, etc. never convert
///     (precision lost at parse stays lost)
pub fn valueToInt(comptime I: type, v: Value) ?I {
    const n = v.asNumOpt() orelse return null;
    return revo.vm.memory.numToInt(I, n);
}

/// c int to revo number   . null past f64-exact range (i32/u32 always fit)
pub fn valueFromInt(v: anytype) ?Value {
    const T = @TypeOf(v);
    const f: f64 = @floatFromInt(v);
    if (revo.vm.memory.numToInt(T, f) != v) return null;
    return Value.new.num(f);
}

/// strict bool atoms only
///   . revo truthiness cant cross into c
///   and trying to align the parts that do would be too much
pub fn valueToBool(v: Value) ?bool {
    const a = v.asAtom() orelse return null;
    if (a == revo.CoreAtoms.atomId(.true)) return true;
    if (a == revo.CoreAtoms.atomId(.false)) return false;
    return null;
}

//
// tests
//
// they dont assert anything useful, just here so that things wont get messed up further
//
test "ffi type names" {
    const t = std.testing;
    try t.expect(FfiType.fromName("string") == .string);
    try t.expect(FfiType.fromName("size_t") == null);
    try t.expect(FfiType.fromName("") == null);
}

test "ffi sizes" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 8), FfiType.u64.sizeOf());
    try t.expectEqual(@as(usize, 1), FfiType.boolean.sizeOf());
    try t.expectEqual(@sizeOf(usize), FfiType.ptr.sizeOf());
    try t.expectEqual(@as(usize, 0), FfiType.void.sizeOf());
}

test "ffi int marshalling" {
    const t = std.testing;
    try t.expectEqual(@as(?i32, 42), valueToInt(i32, Value.new.num(42)));
    try t.expectEqual(@as(?i32, -1), valueToInt(i32, Value.new.num(-1)));
    try t.expect(valueToInt(i32, Value.new.num(1.5)) == null);
    try t.expect(valueToInt(i32, Value.new.num(1e30)) == null);
    try t.expect(valueToInt(u32, Value.new.num(-1)) == null);
    try t.expect(valueToInt(i32, Value.new.nil()) == null);
}

test "ffi int returns" {
    const t = std.testing;
    try t.expect(valueFromInt(@as(i32, 42)) != null);
    try t.expect(valueFromInt(@as(u32, std.math.maxInt(u32))) != null);
    try t.expect(valueFromInt(@as(u64, 9007199254740991)) != null);
    try t.expect(valueFromInt(@as(i64, std.math.minInt(i64))) != null);
    try t.expect(valueFromInt(@as(u64, std.math.maxInt(u64))) == null);
}

test "ffi bool strict" {
    const t = std.testing;
    try t.expectEqual(@as(?bool, true), valueToBool(Value.new.boolean(true)));
    try t.expectEqual(@as(?bool, false), valueToBool(Value.new.boolean(false)));
    try t.expect(valueToBool(Value.new.num(1)) == null);
    try t.expect(valueToBool(Value.new.num(0)) == null);
    try t.expect(valueToBool(Value.new.nil()) == null);
}
