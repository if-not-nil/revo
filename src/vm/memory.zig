const std = @import("std");

const revo = @import("revo");

pub const StringID = usize;
pub const AtomID = usize;
pub const FunctionID = usize;
pub const TableID = usize;
pub const TupleID = usize;
pub const StructTypeID = usize;
pub const StructInstanceID = usize;

// nanbox layout: numbers stored as raw f64; boxed values set BOX_MASK and hold tag+payload
// canonicalize NaN to CANONICAL_NAN for stable bitwise checks
pub const Type = enum(u4) {
    number = 0,
    string = 1,
    atom = 2,
    function = 3,
    table = 4,
    tuple = 5,
    struct_val = 6,
    struct_type = 7,
    foreign = 8,
};

pub const PAYLOAD_MASK: u64 = 0x0000_FFFF_FFFF_FFFF;
pub const BOX_MASK: u64 = 0x7FF0_0000_0000_0000;
const TAG_SHIFT: u6 = 48;
const TAG_MASK: u64 = 0x000F;
const CANONICAL_NAN: u64 = 0x7FF8_0000_0000_0000;

pub const Data = struct {
    bits: u64,

    pub const new = struct {
        pub inline fn num(val: anytype) Data {
            const n: f64 = switch (@typeInfo(@TypeOf(val))) {
                .comptime_int, .int => @as(f64, @floatFromInt(val)),
                .comptime_float, .float => val,
                else => @compileError("new.num expects int or float"),
            };
            return Data.numberRaw(n);
        }
        pub inline fn nil() Data {
            return revo.core_atoms.data(.nil);
        }
        pub inline fn str(id: StringID) Data {
            return Data.boxed(.string, id);
        }
        pub inline fn atom(id: AtomID) Data {
            return Data.boxed(.atom, id);
        }
        pub inline fn function(id: FunctionID) Data {
            return Data.boxed(.function, id);
        }
        pub inline fn boolean(val: bool) Data {
            return if (val) revo.core_atoms.data(.true) else revo.core_atoms.data(.false);
        }
        pub inline fn table(id: TableID) Data {
            return Data.boxed(.table, id);
        }
        pub inline fn tuple(id: TupleID) Data {
            return Data.boxed(.tuple, id);
        }
        pub inline fn structVal(id: StructInstanceID) Data {
            return Data.boxed(.struct_val, id);
        }
        pub inline fn structType(id: StructTypeID) Data {
            return Data.boxed(.struct_type, id);
        }
        pub inline fn foreign(ptr: ?*anyopaque) Data {
            return Data.boxed(.foreign, @intFromPtr(ptr));
        }
    };

    pub const RenderMode = enum(u1) { display, debug };

    // canonicalize NaN to a stable quiet-NaN bit pattern
    pub inline fn numberRaw(n: f64) Data {
        var bits: u64 = @bitCast(n);
        if (std.math.isNan(n)) bits = CANONICAL_NAN;
        return .{ .bits = bits };
    }

    // pack type+payload into nanbox. debug-assert payload fits PAYLOAD_MASK
    inline fn boxed(t: Type, val: usize) Data {
        if (val != std.math.maxInt(usize)) std.debug.assert(val <= PAYLOAD_MASK);
        const pl = @as(u64, @intCast(val)) & PAYLOAD_MASK;
        return .{ .bits = BOX_MASK | (@as(u64, @intFromEnum(t)) << TAG_SHIFT) | pl };
    }

    pub inline fn tag(self: Data) Type {
        if ((self.bits & BOX_MASK) != BOX_MASK) return .number;
        const raw = (self.bits >> TAG_SHIFT) & TAG_MASK;
        if (raw > @intFromEnum(Type.foreign)) return .number;
        return @enumFromInt(raw);
    }

    pub inline fn is(self: Data, t: Type) bool {
        return self.tag() == t;
    }
    pub inline fn isNumber(self: Data) bool {
        return self.tag() == .number;
    }
    pub inline fn isString(self: Data) bool {
        return self.tag() == .string;
    }
    pub inline fn isAtom(self: Data) bool {
        return self.tag() == .atom;
    }
    pub inline fn isFunction(self: Data) bool {
        return self.tag() == .function;
    }
    pub inline fn isTable(self: Data) bool {
        return self.tag() == .table;
    }
    pub inline fn isTuple(self: Data) bool {
        return self.tag() == .tuple;
    }
    pub inline fn isStructVal(self: Data) bool {
        return self.tag() == .struct_val;
    }
    pub inline fn isStructType(self: Data) bool {
        return self.tag() == .struct_type;
    }
    pub inline fn isForeign(self: Data) bool {
        return self.tag() == .foreign;
    }

    pub inline fn asStr(self: Data) ?StringID {
        if ((self.bits & BOX_MASK) == BOX_MASK and ((self.bits >> TAG_SHIFT) & TAG_MASK) == @intFromEnum(Type.string))
            return @intCast(self.bits & PAYLOAD_MASK);
        return null;
    }

    // inline numeric accessors used in hot paths
    // asNum -> ?f64, as_number -> error-union
    pub inline fn asNum(self: Data) ?f64 {
        return if (self.tag() == .number) @bitCast(self.bits) else null;
    }

    pub inline fn as_number(self: Data) !f64 {
        if (!self.isNumber()) return error.TypeError;
        return @bitCast(self.bits);
    }

    pub inline fn unboxed(self: Data) u64 {
        return @intCast(self.bits & PAYLOAD_MASK);
    }
    pub fn asString(self: Data) ?StringID {
        return if (self.isString()) @intCast(self.bits & PAYLOAD_MASK) else null;
    }
    pub fn asAtom(self: Data) ?AtomID {
        return if (self.isAtom()) @intCast(self.bits & PAYLOAD_MASK) else null;
    }
    pub fn asFunction(self: Data) ?FunctionID {
        return if (self.isFunction()) @intCast(self.bits & PAYLOAD_MASK) else null;
    }
    pub fn asTable(self: Data) ?TableID {
        return if (self.isTable()) @intCast(self.bits & PAYLOAD_MASK) else null;
    }
    pub fn asTuple(self: Data) ?TupleID {
        return if (self.isTuple()) @intCast(self.bits & PAYLOAD_MASK) else null;
    }
    pub fn asStructVal(self: Data) ?StructInstanceID {
        return if (self.isStructVal()) @intCast(self.bits & PAYLOAD_MASK) else null;
    }
    pub fn asStructType(self: Data) ?StructTypeID {
        return if (self.isStructType()) @intCast(self.bits & PAYLOAD_MASK) else null;
    }
    pub fn asForeign(self: Data) ?*anyopaque {
        return if (self.isForeign()) @ptrFromInt(@as(usize, @intCast(self.bits & PAYLOAD_MASK))) else null;
    }

    pub inline fn rawBits(self: Data) u64 {
        return self.bits;
    }

    pub fn write(self: Data, writer: *std.Io.Writer, vm: *revo.VM, mode: RenderMode) anyerror!void {
        return revo.vm.print.writeData(self, writer, vm, mode);
    }

    pub fn print(self: Data, vm: *revo.VM) void {
        var buf: [16]u8 = undefined;
        var stdout = vm.runtime.stdout.writer(vm.runtime.io, &buf);
        self.write(&stdout.interface, vm, .debug) catch {
            std.debug.print("<print-error>", .{});
            return;
        };
    }
};
