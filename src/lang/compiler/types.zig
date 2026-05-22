const std = @import("std");

pub const TypeInfo = union(enum) {
    // TODO: remove
    void,
    bool,
    // TODO: maybe unify here maybe split at vm
    int,
    float,
    string,
    atom: []const u8,
    tuple: []const TypeInfo,
    @"union": []const TypeInfo,
    struct_type: []const u8,
    function: *const FunctionSignature,
    any,

    pub fn eql(self: TypeInfo, other: TypeInfo) bool {
        return switch (self) {
            .void => other == .void,
            .bool => other == .bool,
            .int => other == .int,
            .float => other == .float,
            .string => other == .string,
            .atom => |a| if (other == .atom) std.mem.eql(u8, a[1..], other.atom) else false,
            .struct_type => |s| if (other == .struct_type) std.mem.eql(u8, s, other.struct_type) else false,
            .tuple => |ts| if (other == .tuple) blk: {
                if (ts.len != other.tuple.len) break :blk false;
                for (ts, other.tuple) |a, b| if (!eql(a, b)) break :blk false;
                break :blk true;
            } else false,
            .@"union" => false,
            .function => |f| if (other == .function) f == other.function else false,
            .any => true,
        };
    }
};

pub const FunctionSignature = struct { params: []const TypeInfo, return_type: TypeInfo };

pub fn typeName(t: TypeInfo) []const u8 {
    return switch (t) {
        .struct_type => |s| s,
        .atom => |a| a,
        else => @tagName(t),
    };
}

pub fn isNumeric(t: TypeInfo) bool {
    return t == .int or t == .float;
}

pub fn canCoerce(from: TypeInfo, to: TypeInfo) bool {
    if (from.eql(to) or to == .any or from == .any) return true;
    return from == .int and to == .float;
}

pub const BinaryOp = enum { add, sub, mul, div, mod, eq, neq, lt, gt, lte, gte, @"and", @"or" };

pub fn inferBinaryOp(op: BinaryOp, l: TypeInfo, r: TypeInfo) TypeInfo {
    return switch (op) {
        .add, .sub, .mul, .div, .mod => blk: {
            if (l == .int and r == .int) break :blk .int;
            if (isNumeric(l) and isNumeric(r)) break :blk .float;
            break :blk .any;
        },
        .eq, .neq, .lt, .gt, .lte, .gte => .bool,
        .@"and", .@"or" => .bool,
    };
}

pub const UnaryOp = enum { negate, not };

pub fn inferUnaryOp(op: UnaryOp, t: TypeInfo) TypeInfo {
    return switch (op) {
        .negate => if (isNumeric(t)) t else .any,
        .not => .bool,
    };
}
