const std = @import("std");
const Allocator = std.mem.Allocator;

const opcode = @import("opcode.zig");
const Instruction = opcode.Instruction;

const functions = @import("functions.zig");
const memory = @import("memory.zig");

const revo = @import("revo");
const lang = revo.lang;
const Span = lang.Span;
const Artifact = lang.Artifact;

pub const Error = error{
    InvalidMagic,
    VersionMismatch,
    TruncatedData,
};

pub const MAGIC = [4]u8{ 'R', 'E', 'V', 'O' };
pub const VERSION_MAJOR: u16 = 0;
pub const VERSION_MINOR: u16 = 1;

/// on-disk
pub const Header = extern struct {
    magic: [4]u8,
    version_major: u16,
    version_minor: u16,
    flags: u32,
    constants_count: u32,
    instructions_count: u32,
    spans_count: u32,
    prototypes_count: u32,
};

/// unblobbified
pub const DeserializedBytecode = struct {
    instructions: []Instruction,
    spans: []Span,
    allocator: Allocator,

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.instructions);
        self.allocator.free(self.spans);
    }
};

const VM = @import("VM.zig").VM;

//
// ser helpers
//

fn writeIntLE(buffer: *std.ArrayList(u8), allocator: Allocator, comptime IntType: type, value: IntType) !void {
    var bytes: [@sizeOf(IntType)]u8 = undefined;
    std.mem.writeInt(IntType, &bytes, value, .little);
    try buffer.appendSlice(allocator, &bytes);
}

fn serializeTuple(buffer: *std.ArrayList(u8), allocator: Allocator, vm: *VM, tid: memory.TupleID) !void {
    const tuple = try vm.tuples.get(tid);

    try writeIntLE(buffer, allocator, u32, @intCast(tuple.items.len));
    for (tuple.items) |item| {
        try writeIntLE(buffer, allocator, u8, @intFromEnum(item.tag()));
        switch (item.tag()) {
            .number => try writeIntLE(buffer, allocator, u64, @bitCast(item.asNum().?)),
            .string => {
                const sid = item.asString().?;
                const str = try vm.strings.get(sid);
                try writeIntLE(buffer, allocator, u64, str.len);
                try buffer.appendSlice(allocator, str);
            },
            .atom => {
                const aid = item.asAtom().?;
                const str = try vm.strings.get(aid);
                try writeIntLE(buffer, allocator, u64, str.len);
                try buffer.appendSlice(allocator, str);
            },
            .function => try writeIntLE(buffer, allocator, u64, item.asFunction().?),
            .table => try writeIntLE(buffer, allocator, u64, item.asTable().?),
            .tuple => try serializeTuple(buffer, allocator, vm, item.asTuple().?),
            .struct_val, .struct_type, .foreign => unreachable,
        }
    }
}

//
// serialization
//

/// write a compiled artifact + vm constants/prototypes into a byte array
pub fn serialize(vm: *VM, artifact: Artifact, allocator: Allocator) ![]u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer buffer.deinit(allocator);

    const header = Header{
        .magic = MAGIC,
        .version_major = VERSION_MAJOR,
        .version_minor = VERSION_MINOR,
        .flags = 0,
        .constants_count = @intCast(vm.constants.items.len),
        .instructions_count = @intCast(artifact.instructions.len),
        .spans_count = @intCast(artifact.spans.len),
        .prototypes_count = @intCast(vm.functions.prototypes.items.len),
    };

    // header fields
    try buffer.appendSlice(allocator, &header.magic);
    try writeIntLE(&buffer, allocator, u16, header.version_major);
    try writeIntLE(&buffer, allocator, u16, header.version_minor);
    try writeIntLE(&buffer, allocator, u32, header.flags);
    try writeIntLE(&buffer, allocator, u32, header.constants_count);
    try writeIntLE(&buffer, allocator, u32, header.instructions_count);
    try writeIntLE(&buffer, allocator, u32, header.spans_count);
    try writeIntLE(&buffer, allocator, u32, header.prototypes_count);

    for (artifact.instructions) |instr| {
        try writeIntLE(&buffer, allocator, u8, @intFromEnum(instr.op));
        try writeIntLE(&buffer, allocator, u8, @intCast(instr.a));
        try writeIntLE(&buffer, allocator, u8, @intCast(instr.b));
        try writeIntLE(&buffer, allocator, u8, @intCast(instr.c));
        try writeIntLE(&buffer, allocator, u32, @intCast(instr.bx));
    }

    for (artifact.spans) |span| {
        try writeIntLE(&buffer, allocator, u32, @intCast(span.start));
        try writeIntLE(&buffer, allocator, u32, @intCast(span.end));
        try writeIntLE(&buffer, allocator, u32, span.line);
        try writeIntLE(&buffer, allocator, u32, span.column);
    }

    for (vm.constants.items) |constant| {
        try writeIntLE(&buffer, allocator, u8, @intFromEnum(constant.tag()));
        switch (constant.tag()) {
            .number => try writeIntLE(&buffer, allocator, u64, @bitCast(constant.asNum().?)),
            .string => {
                const sid = constant.asString().?;
                const str = try vm.strings.get(sid);
                try writeIntLE(&buffer, allocator, u64, str.len);
                try buffer.appendSlice(allocator, str);
            },
            .atom => {
                const aid = constant.asAtom().?;
                const str = try vm.strings.get(aid);
                try writeIntLE(&buffer, allocator, u64, str.len);
                try buffer.appendSlice(allocator, str);
            },
            .function => try writeIntLE(&buffer, allocator, u64, constant.asFunction().?),
            .struct_val, .struct_type, .foreign => unreachable,
            .table => try writeIntLE(&buffer, allocator, u64, constant.asTable().?),
            .tuple => try serializeTuple(&buffer, allocator, vm, constant.asTuple().?),
        }
    }

    for (vm.functions.prototypes.items) |proto| {
        try writeIntLE(&buffer, allocator, u32, @intCast(proto.addr));
        try writeIntLE(&buffer, allocator, u8, proto.arity);
        try writeIntLE(&buffer, allocator, u8, @intCast(proto.register_count));
        try writeIntLE(&buffer, allocator, u32, @intCast(proto.name.len));
        try writeIntLE(&buffer, allocator, u32, @intCast(proto.upvalue_specs.len));
        try writeIntLE(&buffer, allocator, u32, @intCast(proto.const_locals.len));
        try buffer.appendSlice(allocator, proto.name);

        for (proto.upvalue_specs) |spec| {
            try writeIntLE(&buffer, allocator, u8, if (spec.is_local) 1 else 0);
            try writeIntLE(&buffer, allocator, u8, @intCast(spec.index));
            try writeIntLE(&buffer, allocator, u8, if (spec.mutable) 1 else 0);
        }

        for (proto.const_locals) |local| {
            try writeIntLE(&buffer, allocator, u8, @intCast(local));
        }

        const bits_len = (proto.const_locals.len + 7) / 8;
        try buffer.appendSlice(allocator, proto.const_local_bits[0..bits_len]);
    }

    return buffer.toOwnedSlice(allocator);
}

//
// deserialization
//

/// read a tuple value from the byte stream
fn deserializeTuple(vm: *VM, reader: *std.Io.Reader, allocator: Allocator) !memory.Data {
    const items_len = std.mem.littleToNative(u32, std.mem.readInt(u32, try reader.takeArray(4), .little));
    const items = try allocator.alloc(memory.Data, items_len);
    errdefer allocator.free(items);

    for (items) |*item| {
        const tag = (try reader.takeArray(1))[0];
        item.* = switch (tag) {
            @intFromEnum(memory.Type.number) => blk: {
                const bits = std.mem.readInt(u64, try reader.takeArray(8), .little);
                break :blk memory.Data.new.num(@as(f64, @bitCast(bits)));
            },
            @intFromEnum(memory.Type.string) => blk: {
                const len = std.mem.readInt(u64, try reader.takeArray(8), .little);
                const str = try reader.take(len);
                break :blk try vm.ownDataString(str);
            },
            @intFromEnum(memory.Type.atom) => blk: {
                const len = std.mem.readInt(u64, try reader.takeArray(8), .little);
                const str = try reader.take(len);
                const id = try vm.internAtom(str);
                break :blk memory.Data.new.atom(id);
            },
            @intFromEnum(memory.Type.function) => blk: {
                const fid = std.mem.readInt(u64, try reader.takeArray(8), .little);
                break :blk memory.Data.new.function(@intCast(fid));
            },
            @intFromEnum(memory.Type.table) => blk: {
                const tid = std.mem.readInt(u64, try reader.takeArray(8), .little);
                break :blk memory.Data.new.table(@intCast(tid));
            },
            @intFromEnum(memory.Type.tuple) => try deserializeTuple(vm, reader, allocator),
            else => blk: {
                _ = try reader.takeArray(8);
                break :blk memory.Data.new.nil();
            },
        };
    }

    const tid = try vm.tuples.create(items);
    allocator.free(items); // tuples.create copies
    return memory.Data.new.tuple(tid);
}

// load bytecode from a binary blob, populating vm constants and prototypes
pub fn deserialize(vm: *VM, data: []const u8, allocator: Allocator) !DeserializedBytecode {
    var reader: std.Io.Reader = .fixed(data);

    // header
    const header = (try reader.takeStructPointer(Header)).*;
    if (!std.mem.eql(u8, &header.magic, &MAGIC)) return error.InvalidMagic;
    if (std.mem.littleToNative(u16, header.version_major) != VERSION_MAJOR) return error.VersionMismatch;

    // inst
    const instructions = try allocator.alloc(Instruction, std.mem.littleToNative(u32, header.instructions_count));
    errdefer allocator.free(instructions);

    for (instructions) |*instr| {
        instr.* = .{
            .op = @enumFromInt((try reader.takeArray(1))[0]),
            .a = (try reader.takeArray(1))[0],
            .b = (try reader.takeArray(1))[0],
            .c = (try reader.takeArray(1))[0],
            .bx = std.mem.readInt(u32, try reader.takeArray(4), .little),
        };
    }

    // spans
    const spans = try allocator.alloc(Span, std.mem.littleToNative(u32, header.spans_count));
    errdefer allocator.free(spans);

    for (spans) |*span| {
        span.* = .{
            .start = std.mem.readInt(u32, try reader.takeArray(4), .little),
            .end = std.mem.readInt(u32, try reader.takeArray(4), .little),
            .line = std.mem.readInt(u32, try reader.takeArray(4), .little),
            .column = std.mem.readInt(u32, try reader.takeArray(4), .little),
        };
    }

    // consts
    const constants_count = std.mem.littleToNative(u32, header.constants_count);
    for (0..constants_count) |_| {
        const tag = (try reader.takeArray(1))[0];
        const constant: memory.Data = switch (tag) {
            @intFromEnum(memory.Type.number) => blk: {
                const bits = std.mem.readInt(u64, try reader.takeArray(8), .little);
                break :blk memory.Data.new.num(@as(f64, @bitCast(bits)));
            },
            @intFromEnum(memory.Type.string) => blk: {
                const len = std.mem.readInt(u64, try reader.takeArray(8), .little);
                const str = try reader.take(len);
                break :blk try vm.ownDataString(str);
            },
            @intFromEnum(memory.Type.atom) => blk: {
                const len = std.mem.readInt(u64, try reader.takeArray(8), .little);
                const str = try reader.take(len);
                const id = try vm.internAtom(str);
                break :blk memory.Data.new.atom(id);
            },
            @intFromEnum(memory.Type.function) => blk: {
                const fid = std.mem.readInt(u64, try reader.takeArray(8), .little);
                break :blk memory.Data.new.function(@intCast(fid));
            },
            @intFromEnum(memory.Type.table) => blk: {
                const tid = std.mem.readInt(u64, try reader.takeArray(8), .little);
                break :blk memory.Data.new.table(@intCast(tid));
            },
            @intFromEnum(memory.Type.tuple) => try deserializeTuple(vm, &reader, allocator),
            else => blk: {
                _ = try reader.takeArray(8); // skip u64 payload
                break :blk memory.Data.new.nil();
            },
        };
        try vm.constants.append(allocator, constant);
    }

    // prototypes
    const prototypes_count = std.mem.littleToNative(u32, header.prototypes_count);
    for (0..prototypes_count) |_| {
        const addr = std.mem.readInt(u32, try reader.takeArray(4), .little);
        const arity = (try reader.takeArray(1))[0];
        const register_count: u8 = (try reader.takeArray(1))[0];
        const name_len = std.mem.readInt(u32, try reader.takeArray(4), .little);
        const uv_count = std.mem.readInt(u32, try reader.takeArray(4), .little);
        const cl_count = std.mem.readInt(u32, try reader.takeArray(4), .little);

        const name = try allocator.alloc(u8, name_len);
        defer allocator.free(name);
        try reader.readSliceAll(name);

        const upvalue_specs = try allocator.alloc(functions.UpvalueSpec, uv_count);
        defer allocator.free(upvalue_specs);
        for (upvalue_specs) |*spec| {
            spec.* = .{
                .is_local = (try reader.takeArray(1))[0] != 0,
                .index = (try reader.takeArray(1))[0],
                .mutable = (try reader.takeArray(1))[0] != 0,
            };
        }

        const const_locals = try allocator.alloc(functions.LocalSlot, cl_count);
        defer allocator.free(const_locals);
        for (const_locals) |*local| {
            local.* = (try reader.takeArray(1))[0];
        }

        const bits_len = (cl_count + 7) / 8;
        const const_local_bits = try allocator.alloc(u8, bits_len);
        defer allocator.free(const_local_bits);
        if (bits_len > 0) try reader.readSliceAll(const_local_bits);

        // createPrototype takes ownership do NOT free these slices after pls
        _ = try vm.functions.createPrototype(.{
            .addr = addr,
            .arity = arity,
            .total_arity = arity,
            .register_count = register_count,
            .name = name,
            .upvalue_specs = upvalue_specs,
            .const_locals = const_locals,
            .const_local_bits = const_local_bits,
        });
    }

    return .{
        .instructions = instructions,
        .spans = spans,
        .allocator = allocator,
    };
}

//
// tests
//

const test_support = @import("testing.zig");
const expectEqual = std.testing.expectEqual;

test "serialize and deserialize round trip" {
    const runtime = test_support.runtime();
    var vm = try VM.init(runtime);
    defer vm.deinit();

    var instrs = [_]Instruction{
        .{ .op = .load_small_int, .a = 0, .b = 0, .c = 0, .bx = 42 },
        .{ .op = .halt, .a = 0, .b = 0, .c = 0, .bx = 0 },
    };
    var spans = [_]Span{
        .{ .start = 0, .end = 1, .line = 1, .column = 1 },
        .{ .start = 1, .end = 2, .line = 1, .column = 2 },
    };
    const artifact = Artifact{ .instructions = &instrs, .spans = &spans };

    const bytecode = try serialize(&vm, artifact, runtime.alloc);
    defer runtime.alloc.free(bytecode);

    try expectEqual('R', bytecode[0]);
    try expectEqual('E', bytecode[1]);
    try expectEqual('V', bytecode[2]);
    try expectEqual('O', bytecode[3]);

    var vm2 = try VM.init(runtime);
    defer vm2.deinit();
    var result = try deserialize(&vm2, bytecode, runtime.alloc);
    defer result.deinit();

    try expectEqual(instrs.len, result.instructions.len);
    try expectEqual(spans.len, result.spans.len);
    try expectEqual(.load_small_int, result.instructions[0].op);
    try expectEqual(42, result.instructions[0].bx);
    try expectEqual(.halt, result.instructions[1].op);
}

test "deserialize detects invalid magic" {
    const runtime = test_support.runtime();
    var vm = try VM.init(runtime);
    defer vm.deinit();

    const bad_header = "BADD" ++ "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    try std.testing.expectError(error.InvalidMagic, deserialize(&vm, bad_header, runtime.alloc));
}

test "serialize writes valid file header" {
    const runtime = test_support.runtime();
    var vm = try VM.init(runtime);
    defer vm.deinit();

    const artifact = Artifact{ .instructions = &.{}, .spans = &.{} };
    const bytecode = try serialize(&vm, artifact, runtime.alloc);
    defer runtime.alloc.free(bytecode);

    try expectEqual('R', bytecode[0]);
    try expectEqual('V', bytecode[2]);
    try expectEqual(VERSION_MAJOR, std.mem.readInt(u16, bytecode[4..6], .little));
    try expectEqual(VERSION_MINOR, std.mem.readInt(u16, bytecode[6..8], .little));
}
