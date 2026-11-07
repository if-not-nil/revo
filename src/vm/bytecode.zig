const std = @import("std");
const Allocator = std.mem.Allocator;

const opcode = @import("opcode.zig");
const Instruction = opcode.Instruction;

const functions = @import("callable.zig");
const memory = @import("memory.zig");

const revo = @import("revo");
const lang = revo.lang;
const Span = lang.Span;
const Bytecode = lang.Bytecode;

pub const Error = error{
    InvalidMagic,
    VersionMismatch,
    TruncatedValue,
};

pub const MAGIC = [4]u8{ 'R', 'E', 'V', 'O' };
pub const VERSION_MAJOR: u16 = 2; // 2: atoms travel by name, older files bake vm-specific ids
pub const VERSION_MINOR: u16 = 0; // 0: optional bundle of the import graph after the atoms

/// header flag: the import graph's files and edges follow the atoms
pub const FLAG_BUNDLE: u32 = 1;
/// header flag: the atoms the instructions name follow the templates, by name
/// , ids are per vm, so a load re-interns them and remaps
pub const FLAG_ATOMS: u32 = 2;

/// ops whose `bx` is an atom id
fn atomOperand(op: opcode.Opcode) bool {
    return switch (op) {
        .load_user_global, .load_builtin_global, .store_user_global, .store_user_global_const, .table_set_atom, .table_get_atom => true,
        else => false,
    };
}

/// on-disk
pub const Header = extern struct {
    magic: [4]u8,
    version_major: u16,
    version_minor: u16,
    flags: u32,
    constants_count: u32,
    instructions_count: u32,
    spans_count: u32,
    templates_count: u32,
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

fn serializeValue(buffer: *std.ArrayList(u8), allocator: Allocator, vm: *VM, item: memory.Value) anyerror!void {
    try writeIntLE(buffer, allocator, u8, @backingInt(item.tag()));
    switch (item.tag()) {
        .number => try writeIntLE(buffer, allocator, u64, @bitCast(item.asNumOpt().?)),
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
        // by value, a table id means nothing in the vm that loads it (`comp` results)
        .table => {
            const t = try vm.tables.get(item.asTable().?);
            try writeIntLE(buffer, allocator, u64, t.array.items.len);
            for (t.array.items) |v| try serializeValue(buffer, allocator, vm, v);
            try writeIntLE(buffer, allocator, u64, t.hash.count);
            var it = t.hash.orderedIterator();
            while (it.next()) |e| {
                try serializeValue(buffer, allocator, vm, e.key);
                try serializeValue(buffer, allocator, vm, e.value);
            }
        },
        .@"opaque" => unreachable,
        .resource => unreachable,
    }
}

//
// serialization
//

/// write compiled bytecode + vm constants/templates into a byte array
/// ; with `bundle`, every module it reached rides along, so it runs without them on disk
pub fn serialize(vm: *VM, bytecode: Bytecode, allocator: Allocator, bundle: ?*const lang.import_graph.Graph) ![]u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer buffer.deinit(allocator);

    const header = Header{
        .magic = MAGIC,
        .version_major = VERSION_MAJOR,
        .version_minor = VERSION_MINOR,
        .flags = FLAG_ATOMS | @as(u32, if (bundle != null) FLAG_BUNDLE else 0),
        .constants_count = @intCast(vm.constants.items.len),
        .instructions_count = @intCast(bytecode.instructions.len),
        .spans_count = @intCast(bytecode.spans.len),
        .templates_count = @intCast(vm.callable.templates.items.len),
    };

    // header fields
    try buffer.appendSlice(allocator, &header.magic);
    try writeIntLE(&buffer, allocator, u16, header.version_major);
    try writeIntLE(&buffer, allocator, u16, header.version_minor);
    try writeIntLE(&buffer, allocator, u32, header.flags);
    try writeIntLE(&buffer, allocator, u32, header.constants_count);
    try writeIntLE(&buffer, allocator, u32, header.instructions_count);
    try writeIntLE(&buffer, allocator, u32, header.spans_count);
    try writeIntLE(&buffer, allocator, u32, header.templates_count);

    try buffer.appendSlice(allocator, std.mem.sliceAsBytes(bytecode.instructions));

    for (bytecode.spans) |span| {
        try writeIntLE(&buffer, allocator, u32, @intCast(span.start));
        try writeIntLE(&buffer, allocator, u32, @intCast(span.end));
        try writeIntLE(&buffer, allocator, u32, span.line);
        try writeIntLE(&buffer, allocator, u32, span.column);
    }

    for (vm.constants.items) |constant| try serializeValue(&buffer, allocator, vm, constant);

    for (vm.callable.templates.items) |template| {
        try writeIntLE(&buffer, allocator, u32, @intCast(template.addr));
        try writeIntLE(&buffer, allocator, u8, template.arity);
        try writeIntLE(&buffer, allocator, u8, @intCast(template.register_count));
        try writeIntLE(&buffer, allocator, u32, @intCast(template.name.len));
        try writeIntLE(&buffer, allocator, u32, @intCast(template.upvalue_specs.len));
        try writeIntLE(&buffer, allocator, u32, @intCast(template.const_locals.len));
        try buffer.appendSlice(allocator, template.name);

        for (template.upvalue_specs) |spec| {
            try writeIntLE(&buffer, allocator, u8, if (spec.is_local) 1 else 0);
            try writeIntLE(&buffer, allocator, u8, @intCast(spec.index));
            try writeIntLE(&buffer, allocator, u8, if (spec.mutable) 1 else 0);
        }

        for (template.const_locals) |local| {
            try writeIntLE(&buffer, allocator, u8, @intCast(local));
        }

        const bits_len = template.const_local_bits.len;
        try writeIntLE(&buffer, allocator, u32, @intCast(bits_len));
        try buffer.appendSlice(allocator, template.const_local_bits[0..bits_len]);
    }

    var atoms: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
    defer atoms.deinit(allocator);
    for (bytecode.instructions) |i| if (atomOperand(i.op)) try atoms.put(allocator, i.bx, {});
    try writeIntLE(&buffer, allocator, u32, @intCast(atoms.count()));
    for (atoms.keys()) |id| {
        const name = try vm.strings.get(id);
        try writeIntLE(&buffer, allocator, u32, id);
        try writeIntLE(&buffer, allocator, u32, @intCast(name.len));
        try buffer.appendSlice(allocator, name);
    }

    if (bundle) |b| {
        try writeIntLE(&buffer, allocator, u32, @intCast(b.files.count()));
        for (b.files.keys(), b.files.values()) |path, source| {
            try writeIntLE(&buffer, allocator, u32, @intCast(path.len));
            try buffer.appendSlice(allocator, path);
            try writeIntLE(&buffer, allocator, u64, source.len);
            try buffer.appendSlice(allocator, source);
        }
        try writeIntLE(&buffer, allocator, u32, @intCast(b.edges.count()));
        var it = b.edges.iterator();
        while (it.next()) |e| {
            try writeIntLE(&buffer, allocator, u32, @intCast(e.key_ptr.len));
            try buffer.appendSlice(allocator, e.key_ptr.*);
            try writeIntLE(&buffer, allocator, u32, @intCast(e.value_ptr.len));
            try buffer.appendSlice(allocator, e.value_ptr.*);
        }
    }

    return buffer.toOwnedSlice(allocator);
}

//
// deserialization
//

/// read a single Value value from the byte stream
fn readValue(vm: *VM, reader: *std.Io.Reader) anyerror!memory.Value {
    const tag = (try reader.takeArray(1))[0];
    return switch (tag) {
        @backingInt(memory.ValueTag.number) => blk: {
            const bits = std.mem.readInt(u64, try reader.takeArray(8), .little);
            break :blk memory.Value.new.num(@as(f64, @bitCast(bits)));
        },
        @backingInt(memory.ValueTag.string) => blk: {
            const len = std.mem.readInt(u64, try reader.takeArray(8), .little);
            const str = try reader.take(@intCast(len));
            break :blk try vm.ownValueString(str);
        },
        @backingInt(memory.ValueTag.atom) => blk: {
            const len = std.mem.readInt(u64, try reader.takeArray(8), .little);
            const str = try reader.take(@intCast(len));
            const id = try vm.internAtom(str);
            break :blk memory.Value.new.atom(id);
        },
        @backingInt(memory.ValueTag.function) => blk: {
            const fid = std.mem.readInt(u64, try reader.takeArray(8), .little);
            break :blk memory.Value.new.function(@intCast(fid));
        },
        @backingInt(memory.ValueTag.table) => blk: {
            const tid = try vm.tables.create();
            const items = std.mem.readInt(u64, try reader.takeArray(8), .little);
            for (0..items) |_| {
                const v = try readValue(vm, reader);
                const t = try vm.tables.get(tid);
                try t.array.append(vm.runtime.alloc, v);
            }

            const entries = std.mem.readInt(u64, try reader.takeArray(8), .little);
            for (0..entries) |_| {
                const k = try readValue(vm, reader);
                const v = try readValue(vm, reader);
                const t = try vm.tables.get(tid);
                try t.putRaw(k, v, vm);
            }
            break :blk memory.Value.new.table(tid);
        },
        else => blk: {
            _ = try reader.takeArray(8); // skip u64 payload
            break :blk memory.Value.new.nil();
        },
    };
}

// load bytecode from a binary blob, populating vm constants and templates
pub fn deserialize(vm: *VM, data: []const u8, allocator: Allocator) !DeserializedBytecode {
    var reader: std.Io.Reader = .fixed(data);

    // header, read field-by-field (endian-aware, unlike takeStructPointer)
    const magic = (try reader.takeArray(4)).*;
    if (!std.mem.eql(u8, &magic, &MAGIC)) return error.InvalidMagic;
    const version_major = std.mem.readInt(u16, try reader.takeArray(2), .little);
    if (version_major != VERSION_MAJOR) return error.VersionMismatch;
    _ = std.mem.readInt(u16, try reader.takeArray(2), .little); // version_minor

    const flags = std.mem.readInt(u32, try reader.takeArray(4), .little);
    const constants_count = std.mem.readInt(u32, try reader.takeArray(4), .little);
    const instructions_count = std.mem.readInt(u32, try reader.takeArray(4), .little);
    const spans_count = std.mem.readInt(u32, try reader.takeArray(4), .little);
    const templates_count = std.mem.readInt(u32, try reader.takeArray(4), .little);

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
        try vm.constants.append(allocator, try readValue(vm, &reader));
    }

    var template_ids = try std.ArrayList(usize).initCapacity(allocator, templates_count);
    defer template_ids.deinit(allocator);

    // templates
    for (0..templates_count) |_| {
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

        // createTemplate takes ownership do NOT free these slices after pls
        const template_id = try vm.callable.createTemplate(.{
            .addr = addr,
            .arity = arity,
            .total_arity = arity,
            .register_count = register_count,
            .name = name,
            .upvalue_specs = upvalue_specs,
            .const_locals = const_locals,
            .const_local_bits = const_local_bits,
        });
        template_ids.appendAssumeCapacity(template_id);
    }

    if (flags & FLAG_ATOMS != 0) try remapAtoms(vm, &reader, instructions, allocator);
    if (flags & FLAG_BUNDLE != 0) try readBundle(vm, &reader);

    // templates run from their own copy of the program
    // ; segment 0 might already hold code compiled at runtime (a loaded module, `revo.eval`)
    const segment_id = try vm.callable.addBytecodeSegment(try vm.callable.alloc.dupe(Instruction, instructions));
    for (template_ids.items) |id| vm.callable.templates.items[id].segment_id = segment_id;

    return .{
        .instructions = instructions,
        .spans = spans,
        .allocator = allocator,
    };
}

/// atom ids from the compiling vm -> this vm's, rewritten in place
fn remapAtoms(vm: *VM, reader: *std.Io.Reader, instructions: []Instruction, allocator: Allocator) !void {
    var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer map.deinit(allocator);
    const count = std.mem.readInt(u32, try reader.takeArray(4), .little);
    for (0..count) |_| {
        const old = std.mem.readInt(u32, try reader.takeArray(4), .little);
        const name = try reader.take(std.mem.readInt(u32, try reader.takeArray(4), .little));
        try map.put(allocator, old, @intCast(try vm.internAtom(name)));
    }
    for (instructions) |*i| {
        if (!atomOperand(i.op)) continue;
        i.bx = map.get(i.bx) orelse return error.InvalidBytecode;
    }
}

/// the bundled graph becomes `vm.bundle`, imports resolve and load from it
fn readBundle(vm: *VM, reader: *std.Io.Reader) !void {
    const alloc = vm.runtime.alloc;
    const graph = try alloc.create(lang.import_graph.Graph);
    errdefer alloc.destroy(graph);
    graph.* = .init(alloc);
    errdefer graph.deinit();

    const files = std.mem.readInt(u32, try reader.takeArray(4), .little);
    for (0..files) |_| {
        const path = try reader.take(std.mem.readInt(u32, try reader.takeArray(4), .little));
        const owned_path = try alloc.dupe(u8, path);
        errdefer alloc.free(owned_path);
        const source = try reader.take(@intCast(std.mem.readInt(u64, try reader.takeArray(8), .little)));
        try graph.addFile(owned_path, source);
        alloc.free(owned_path);
    }

    const edges = std.mem.readInt(u32, try reader.takeArray(4), .little);
    for (0..edges) |_| {
        const key = try alloc.dupe(u8, try reader.take(std.mem.readInt(u32, try reader.takeArray(4), .little)));
        errdefer alloc.free(key);
        const path = try alloc.dupe(u8, try reader.take(std.mem.readInt(u32, try reader.takeArray(4), .little)));
        errdefer alloc.free(path);
        try graph.edges.put(alloc, key, path);
    }

    if (vm.bundle) |old| {
        old.deinit();
        alloc.destroy(old);
    }

    vm.bundle = graph;
}

//
// tests
//

const expectEqual = std.testing.expectEqual;

test "serialize and deserialize round trip" {
    const runtime = revo.lang.test_helpers.runtime();
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
    const input = Bytecode{ .instructions = &instrs, .spans = &spans };

    const bytecode = try serialize(&vm, input, runtime.alloc, null);
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
    const runtime = revo.lang.test_helpers.runtime();
    var vm = try VM.init(runtime);
    defer vm.deinit();

    const bad_header = "BADD" ++ "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++
        "\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    try std.testing.expectError(error.InvalidMagic, deserialize(&vm, bad_header, runtime.alloc));
}

test "serialize writes valid file header" {
    const runtime = revo.lang.test_helpers.runtime();
    var vm = try VM.init(runtime);
    defer vm.deinit();

    const input = Bytecode{ .instructions = &.{}, .spans = &.{} };
    const bytecode = try serialize(&vm, input, runtime.alloc, null);
    defer runtime.alloc.free(bytecode);

    try expectEqual('R', bytecode[0]);
    try expectEqual('V', bytecode[2]);
    try expectEqual(VERSION_MAJOR, std.mem.readInt(u16, bytecode[4..6], .little));
    try expectEqual(VERSION_MINOR, std.mem.readInt(u16, bytecode[6..8], .little));
}

test "deserialize refuses a version 1 file" {
    const runtime = revo.lang.test_helpers.runtime();
    var vm = try VM.init(runtime);
    defer vm.deinit();

    // version 1 baked vm-specific atom ids, there's nothing to remap
    var old: [28]u8 = @splat(0);
    @memcpy(old[0..8], "REVO\x01\x00\x02\x00");
    try std.testing.expectError(error.VersionMismatch, deserialize(&vm, &old, runtime.alloc));
}

test "table constants and atoms survive a round trip into a vm that interned other atoms first" {
    const runtime = revo.lang.test_helpers.runtime();
    const blob = blk: {
        var vm = try VM.init(runtime);
        defer vm.deinit();
        const bytecode = switch (try lang.build(&vm, .{ .name = "t.rv", .text = "fn get(r) r.zz_a + r.zz_b[1]\nget(comp ({zz_a = 1, zz_b = {2, 3}}))" }, .{})) {
            .ok => |ok| ok,
            .err => return error.ParseError,
        };
        defer runtime.alloc.free(bytecode.instructions);
        defer runtime.alloc.free(bytecode.spans);
        break :blk try serialize(&vm, bytecode, runtime.alloc, null);
    };
    defer runtime.alloc.free(blob);

    var vm = try VM.init(runtime);
    defer vm.deinit();

    // shift the ids the compiling vm handed out
    for ([_][]const u8{ "zz_one", "zz_two", "zz_b", "zz_a" }) |n| _ = try vm.internAtom(n);

    var loaded = try deserialize(&vm, blob, runtime.alloc);
    defer loaded.deinit();
    const res = try revo.run.runBytecodeReport(&vm, "t.rv", loaded.instructions);
    try std.testing.expect(res == .ok);
    try std.testing.expectEqual(memory.Value.new.num(4), vm.mainResult());
}
