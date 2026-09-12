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
pub const VERSION_MAJOR: u16 = 1; // 1: nanbox tag values changed (0, 8-15)
pub const VERSION_MINOR: u16 = 2; // 2: const_local_bits serialized at its real width

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

fn serializeData(buffer: *std.ArrayList(u8), allocator: Allocator, vm: *VM, item: memory.Data) anyerror!void {
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
        .foreign => unreachable,
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

    try buffer.appendSlice(allocator, std.mem.sliceAsBytes(artifact.instructions));

    for (artifact.spans) |span| {
        try writeIntLE(&buffer, allocator, u32, @intCast(span.start));
        try writeIntLE(&buffer, allocator, u32, @intCast(span.end));
        try writeIntLE(&buffer, allocator, u32, span.line);
        try writeIntLE(&buffer, allocator, u32, span.column);
    }

    for (vm.constants.items) |constant| try serializeData(&buffer, allocator, vm, constant);

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

        const bits_len = proto.const_local_bits.len;
        try writeIntLE(&buffer, allocator, u32, @intCast(bits_len));
        try buffer.appendSlice(allocator, proto.const_local_bits[0..bits_len]);
    }

    return buffer.toOwnedSlice(allocator);
}

//
// deserialization
//

/// read a single Data value from the byte stream
fn readDataValue(vm: *VM, reader: *std.Io.Reader) anyerror!memory.Data {
    const tag = (try reader.takeArray(1))[0];
    return switch (tag) {
        @intFromEnum(memory.Type.number) => blk: {
            const bits = std.mem.readInt(u64, try reader.takeArray(8), .little);
            break :blk memory.Data.new.num(@as(f64, @bitCast(bits)));
        },
        @intFromEnum(memory.Type.string) => blk: {
            const len = std.mem.readInt(u64, try reader.takeArray(8), .little);
            const str = try reader.take(@intCast(len));
            break :blk try vm.ownDataString(str);
        },
        @intFromEnum(memory.Type.atom) => blk: {
            const len = std.mem.readInt(u64, try reader.takeArray(8), .little);
            const str = try reader.take(@intCast(len));
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
        else => blk: {
            _ = try reader.takeArray(8); // skip u64 payload
            break :blk memory.Data.new.nil();
        },
    };
}

// load bytecode from a binary blob, populating vm constants and prototypes
pub fn deserialize(vm: *VM, data: []const u8, allocator: Allocator) !DeserializedBytecode {
    var reader: std.Io.Reader = .fixed(data);

    // header, read field-by-field (endian-aware, unlike takeStructPointer)
    const magic = (try reader.takeArray(4)).*;
    if (!std.mem.eql(u8, &magic, &MAGIC)) return error.InvalidMagic;
    const version_major = std.mem.readInt(u16, try reader.takeArray(2), .little);
    if (version_major != VERSION_MAJOR) return error.VersionMismatch;
    _ = std.mem.readInt(u16, try reader.takeArray(2), .little); // version_minor
    _ = std.mem.readInt(u32, try reader.takeArray(4), .little); // flags
    const constants_count = std.mem.readInt(u32, try reader.takeArray(4), .little);
    const instructions_count = std.mem.readInt(u32, try reader.takeArray(4), .little);
    const spans_count = std.mem.readInt(u32, try reader.takeArray(4), .little);
    const prototypes_count = std.mem.readInt(u32, try reader.takeArray(4), .little);

    // inst
    const instructions = try allocator.alloc(Instruction, instructions_count);
    errdefer allocator.free(instructions);
    const instr_bytes = try reader.take(instructions_count * @sizeOf(Instruction));
    @memcpy(std.mem.sliceAsBytes(instructions), instr_bytes);

    // spans
    const spans = try allocator.alloc(Span, spans_count);
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
    for (0..constants_count) |_| {
        try vm.constants.append(allocator, try readDataValue(vm, &reader));
    }

    // prototypes
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

        const const_bits_len = std.mem.readInt(u32, try reader.takeArray(4), .little);
        const const_local_bits = try allocator.alloc(u8, const_bits_len);
        defer allocator.free(const_local_bits);
        if (const_bits_len > 0) try reader.readSliceAll(const_local_bits);

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

const expectEqual = std.testing.expectEqual;

test "serialize and deserialize round trip" {
    const runtime = revo.lang.testing.runtime();
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
    const runtime = revo.lang.testing.runtime();
    var vm = try VM.init(runtime);
    defer vm.deinit();

    const bad_header = "BADD" ++ "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++
        "\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    try std.testing.expectError(error.InvalidMagic, deserialize(&vm, bad_header, runtime.alloc));
}

test "serialize writes valid file header" {
    const runtime = revo.lang.testing.runtime();
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
