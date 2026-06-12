const std = @import("std");

const revo = @import("revo");

const mem = revo.memory;
const Data = mem.Data;
const t = revo.lang.testing;

pub const NativeError = revo.vm.NativeError;
pub const NativeErrPayload = revo.std_lib.NativeErrPayload;
pub const NativeResult = revo.std_lib.NativeResult;

pub const ProgramCounter = usize;
pub const LocalSlot = revo.opcode.Register;
pub const Register = revo.opcode.Register;
pub const RegisterCount = Register;
pub const PrototypeID = usize;
pub const UpvalueID = usize;

pub const FrameHot = struct {
    return_addr: ProgramCounter,
    base: usize,
    program: []const revo.Instruction,
};

pub const FrameCold = struct {
    call_site_pc: ?ProgramCounter,
    result_register: Register,
    register_count: RegisterCount,
    closure_id: ?mem.FunctionID,
};

pub const NativeFn = *const fn (args: []const Data, vm: *revo.VM) NativeResult;

pub const RevoBinding = extern struct {
    name: [*:0]const u8,
    fn_ptr: *const anyopaque,
};

/// not the real repr, converted from the underlying type
/// (currently only nanbox, but if i start supporting x32, that would be very handy)
pub const CRevoData = extern struct {
    tag: u64,
    value: u64,

    pub fn toData(self: *const CRevoData, _: *revo.VM) !Data {
        const tag: mem.Type = @enumFromInt(
            @as(@typeInfo(mem.Type).@"enum".tag_type, @intCast(self.tag)),
        );
        return switch (tag) {
            .number => Data.numberRaw(@bitCast(self.value)),
            .string => Data.new.str(@intCast(self.value)),
            .atom => Data.new.atom(@intCast(self.value)),
            .function => Data.new.function(@intCast(self.value)),
            .table => Data.new.table(@intCast(self.value)),
            .tuple => Data.new.tuple(@intCast(self.value)),
            .struct_val, .struct_type => unreachable,
        };
    }

    pub fn fromData(data: Data) CRevoData {
        const tag = data.tag();
        return .{
            .tag = @intFromEnum(tag),
            .value = switch (tag) {
                .number => @bitCast(data.asNum().?),
                .string => data.asString().?,
                .atom => data.asAtom().?,
                .function => data.asFunction().?,
                .table => data.asTable().?,
                .tuple => data.asTuple().?,
                .struct_val => data.asStructVal().?,
                .struct_type => data.asStructType().?,
            },
        };
    }
};

pub const CFnPtr = *const fn (
    vm: *anyopaque,
    argc: usize,
    argv: [*]CRevoData,
    out_result: *CRevoData,
) callconv(.c) void;
/// TODO: make functions have fixed arity too
pub const VARIADIC: u8 = 0xFF;

pub const CFunction = struct {
    name: []const u8,
    fn_ptr: CFnPtr,
};

pub const UpvalueSpec = struct {
    is_local: bool,
    index: LocalSlot,
    mutable: bool,
};

pub const Prototype = struct {
    addr: ProgramCounter,
    segment_id: usize = 0,
    arity: u8,
    total_arity: u8,
    register_count: RegisterCount = 0,
    name: []const u8,
    upvalue_specs: []UpvalueSpec,
    const_locals: []LocalSlot,
    const_local_bits: []u8,
};

pub const Closure = struct {
    // cache prototype id and register_count so VM can size frames without a prototype lookup
    prototype: PrototypeID,
    segment_id: usize = 0,
    addr: ProgramCounter,
    arity: u8,
    total_arity: u8,
    register_count: RegisterCount,
    name: []const u8,
    upvalues: []UpvalueID,
};

pub const Upvalue = struct {
    open_index: ?usize,
    closed: Data,
};

pub const Function = union(enum) {
    closure: Closure,
    native: revo.std_lib.NativeFunc,
    c_function: CFunction,

    pub fn arity(self: Function) u8 {
        return switch (self) {
            .closure => |f| f.arity,
            .native => |f| @intCast(f.arity),
            .c_function => VARIADIC,
        };
    }

    pub fn name(self: Function) []const u8 {
        return switch (self) {
            .closure => |f| f.name,
            .native => |f| if (f.name.len > 0) f.name else "<native>",
            .c_function => |f| f.name,
        };
    }
};

pub const FunctionPool = struct {
    alloc: std.mem.Allocator,
    functions: std.ArrayList(?Function),
    function_marks: std.DynamicBitSet,
    function_dead: std.ArrayList(mem.FunctionID),
    prototypes: std.ArrayList(Prototype),
    upvalues: std.ArrayList(?Upvalue),
    upvalue_marks: std.DynamicBitSet,
    upvalue_dead: std.ArrayList(UpvalueID),
    segments: std.ArrayList([]const revo.Instruction),

    pub fn init(alloc: std.mem.Allocator) !FunctionPool {
        var self = FunctionPool{
            .alloc = alloc,
            .functions = undefined,
            .function_marks = undefined,
            .function_dead = .empty,
            .prototypes = undefined,
            .upvalues = undefined,
            .upvalue_marks = undefined,
            .upvalue_dead = .empty,
            .segments = undefined,
        };
        self.functions = try std.ArrayList(?Function).initCapacity(alloc, 16);
        errdefer self.functions.deinit(alloc);
        self.function_marks = try std.DynamicBitSet.initEmpty(alloc, 64);
        errdefer self.function_marks.deinit();
        self.prototypes = try std.ArrayList(Prototype).initCapacity(alloc, 16);
        errdefer self.prototypes.deinit(alloc);
        self.upvalues = try std.ArrayList(?Upvalue).initCapacity(alloc, 16);
        errdefer self.upvalues.deinit(alloc);
        self.upvalue_marks = try std.DynamicBitSet.initEmpty(alloc, 64);
        errdefer self.upvalue_marks.deinit();
        self.segments = try std.ArrayList([]const revo.Instruction).initCapacity(alloc, 4);
        errdefer self.segments.deinit(alloc);

        return self;
    }

    pub fn deinit(self: *FunctionPool) void {
        for (self.functions.items) |*maybe_f| {
            if (maybe_f.*) |f| switch (f) {
                .closure => |closure| self.alloc.free(closure.upvalues),
                .c_function => {},
                .native => {},
            };
        }
        for (self.prototypes.items) |proto| {
            self.alloc.free(proto.name);
            self.alloc.free(proto.upvalue_specs);
            self.alloc.free(proto.const_locals);
            self.alloc.free(proto.const_local_bits);
        }
        for (self.segments.items) |seg| self.alloc.free(seg);
        self.functions.deinit(self.alloc);
        self.function_marks.deinit();
        self.function_dead.deinit(self.alloc);
        self.prototypes.deinit(self.alloc);
        self.upvalues.deinit(self.alloc);
        self.upvalue_marks.deinit();
        self.upvalue_dead.deinit(self.alloc);
        self.segments.deinit(self.alloc);
    }

    pub inline fn create(self: *FunctionPool, func: Function) !mem.FunctionID {
        if (self.function_dead.pop()) |id| {
            self.functions.items[id] = func;
            return id;
        }
        const id: mem.FunctionID = @intCast(self.functions.items.len);
        try self.functions.append(self.alloc, func);
        if (id >= self.function_marks.capacity()) {
            try self.function_marks.resize(self.functions.items.len, false);
        }
        return id;
    }

    pub fn createPrototype(self: *FunctionPool, proto: Prototype) !PrototypeID {
        const const_bits_len = if (proto.const_local_bits.len != 0)
            proto.const_local_bits.len
        else blk: {
            var max_slot: usize = 0;
            for (proto.const_locals) |slot| {
                if (slot > max_slot) max_slot = slot;
            }
            break :blk if (proto.const_locals.len == 0) 0 else (max_slot / 8) + 1;
        };
        var const_bits = try self.alloc.alloc(u8, const_bits_len);
        errdefer self.alloc.free(const_bits);
        @memset(const_bits, 0);
        if (proto.const_local_bits.len != 0) {
            @memcpy(const_bits, proto.const_local_bits);
        } else {
            for (proto.const_locals) |slot| {
                const idx = slot / 8;
                const bit: u3 = @intCast(slot % 8);
                const_bits[idx] |= (@as(u8, 1) << bit);
            }
        }

        const id: PrototypeID = @intCast(self.prototypes.items.len);
        try self.prototypes.append(self.alloc, .{
            .addr = proto.addr,
            .arity = proto.arity,
            .total_arity = proto.total_arity,
            .register_count = proto.register_count,
            .name = try self.alloc.dupe(u8, proto.name),
            .upvalue_specs = try self.alloc.dupe(UpvalueSpec, proto.upvalue_specs),
            .const_locals = try self.alloc.dupe(LocalSlot, proto.const_locals),
            .const_local_bits = const_bits,
        });
        return id;
    }

    pub inline fn createClosure(self: *FunctionPool, prototype_id: PrototypeID, upvalues: []const UpvalueID) !mem.FunctionID {
        const proto = try self.getPrototype(prototype_id);
        return self.create(.{ .closure = .{
            .prototype = prototype_id,
            .segment_id = proto.segment_id,
            .arity = proto.arity,
            .total_arity = proto.total_arity,
            .addr = proto.addr,
            .register_count = proto.register_count,
            .name = proto.name,
            .upvalues = try self.alloc.dupe(UpvalueID, upvalues),
        } });
    }

    pub fn addBytecodeSegment(self: *FunctionPool, instructions: []const revo.Instruction) !usize {
        const id = self.segments.items.len;
        try self.segments.append(self.alloc, instructions);
        return id;
    }

    pub inline fn createUpvalue(self: *FunctionPool, upvalue: Upvalue) !UpvalueID {
        if (self.upvalue_dead.pop()) |id| {
            self.upvalues.items[id] = upvalue;
            return id;
        }
        const id: UpvalueID = @intCast(self.upvalues.items.len);
        try self.upvalues.append(self.alloc, upvalue);
        if (id >= self.upvalue_marks.capacity()) {
            try self.upvalue_marks.resize(self.upvalues.items.len, false);
        }
        return id;
    }

    pub inline fn get(self: *FunctionPool, id: mem.FunctionID) !*Function {
        if (id >= self.functions.items.len) return error.FunctionDNE;
        if (self.functions.items[id]) |*f| return f;
        return error.FunctionDNE;
    }

    pub inline fn getPrototype(self: *FunctionPool, id: PrototypeID) !*Prototype {
        if (id >= self.prototypes.items.len) return error.FunctionDNE;
        return &self.prototypes.items[id];
    }

    pub inline fn getUpvalue(self: *FunctionPool, id: UpvalueID) !*Upvalue {
        if (id >= self.upvalues.items.len) return error.FunctionDNE;
        if (self.upvalues.items[id]) |*u| return u;
        return error.FunctionDNE;
    }

    pub fn mark(self: *FunctionPool, id: mem.FunctionID, vm: *revo.VM) void {
        if (id >= self.functions.items.len) return;
        if (self.function_marks.isSet(id)) return;
        if (self.functions.items[id] == null) return;
        self.function_marks.set(id);
        vm.pushMarkFunction(id);
    }

    pub fn markUpvalue(self: *FunctionPool, id: UpvalueID, vm: *revo.VM) void {
        if (id >= self.upvalues.items.len) return;
        if (self.upvalue_marks.isSet(id)) return;
        if (self.upvalues.items[id] == null) return;
        self.upvalue_marks.set(id);
        vm.pushMarkUpvalue(id);
    }

    pub fn sweep(self: *FunctionPool) void {
        {
            const max_dead = self.functions.items.len;
            self.function_dead.ensureTotalCapacity(self.alloc, max_dead) catch return;
            self.function_dead.items.len = 0;
            for (self.functions.items, 0..) |*maybe_f, idx| {
                if (maybe_f.* == null) continue;
                if (self.function_marks.isSet(idx)) continue;
                switch (maybe_f.*.?) {
                    .closure => |closure| self.alloc.free(closure.upvalues),
                    .native, .c_function => {},
                }
                maybe_f.* = null;
                self.function_dead.appendAssumeCapacity(@intCast(idx));
            }
            self.function_marks.unmanaged.unsetAll();
        }
        {
            const max_dead = self.upvalues.items.len;
            self.upvalue_dead.ensureTotalCapacity(self.alloc, max_dead) catch return;
            self.upvalue_dead.items.len = 0;
            for (self.upvalues.items, 0..) |*maybe_u, idx| {
                if (maybe_u.* == null) continue;
                if (self.upvalue_marks.isSet(idx)) continue;
                maybe_u.* = null;
                self.upvalue_dead.appendAssumeCapacity(@intCast(idx));
            }
            self.upvalue_marks.unmanaged.unsetAll();
        }
    }

    pub inline fn bytes(self: *const FunctionPool) usize {
        var total: usize = 0;
        for (self.functions.items) |maybe_f| {
            if (maybe_f) |f| {
                total += 48;
                switch (f) {
                    .closure => |closure| total += @sizeOf(UpvalueID) * closure.upvalues.len,
                    .native, .c_function => {},
                }
            }
        }
        for (self.upvalues.items) |maybe_u| {
            if (maybe_u != null)
                total += 24;
        }
        return total;
    }

    pub fn clearMarks(self: *FunctionPool) void {
        self.function_marks.unmanaged.unsetAll();
        self.upvalue_marks.unmanaged.unsetAll();
    }

    pub fn capacity(self: *const FunctionPool) usize {
        return self.functions.items.len;
    }

    pub fn sweepStep(self: *FunctionPool, cursor: usize, limit: usize) usize {
        if (cursor >= self.functions.items.len) return 0;

        const end = @min(cursor + limit, self.functions.items.len);
        var processed: usize = 0;

        for (cursor..end) |i| {
            if (self.functions.items[i]) |*f| {
                if (!self.function_marks.isSet(i)) {
                    switch (f.*) {
                        .closure => |closure| self.alloc.free(closure.upvalues),
                        .native, .c_function => {},
                    }
                    self.functions.items[i] = null; // mark as dead/free
                    self.function_dead.append(self.alloc, @intCast(i)) catch {};
                }
            }
            processed += 1;
        }

        return processed;
    }

    pub fn upvalueCapacity(self: *const FunctionPool) usize {
        return self.upvalues.items.len;
    }

    pub fn sweepUpvalueStep(self: *FunctionPool, cursor: usize, limit: usize) usize {
        if (cursor >= self.upvalues.items.len) return 0;

        const end = @min(cursor + limit, self.upvalues.items.len);
        var processed: usize = 0;

        for (cursor..end) |i| {
            if (self.upvalues.items[i] != null and !self.upvalue_marks.isSet(i)) {
                self.upvalues.items[i] = null;
                self.upvalue_dead.append(self.alloc, @intCast(i)) catch {};
            }
            processed += 1;
        }

        return processed;
    }
};

test "functions call with lexical locals" {
    try t.top_number(
        \\ const id = fn(x) x
        \\ id(42)
    , 42);
    try t.top_number(
        \\ const add = fn(a, b) a + b
        \\ add(20, 22)
    , 42);
    try t.top_number(
        \\ const forty_two = fn() 42
        \\ forty_two()
    , 42);
}

test "functions return exactly one value" {
    try t.top_number(
        \\ const f = fn() do
        \\     1
        \\     2
        \\ end
        \\ f()
    , 2);
    try t.top_number(
        \\ const f = fn() do
        \\     return 41
        \\     0
        \\ end
        \\ f()
    , 41);
    try t.top_nil(
        \\ const f = fn() do
        \\     return
        \\ end
        \\ f()
    );
    try t.top_type(
        \\ const f = fn() (1, 2)
        \\ f()
    , .tuple);
    try t.top_number(
        \\ const f = fn() do
        \\ return 1 2 end
        \\ f()
    , 1);
}

test "functions reject wrong arity" {
    try t.expectCompileError(
        \\ const id = fn(x) x
        \\ id()
    , .ParseError);
    try t.expectCompileError(
        \\ const forty_two = fn() 42
        \\ forty_two(1)
    , .ParseError);
    try t.expectCompileError(
        \\ const all = fn(a, b, c) a + b * c
        \\ all(1, 2)
    , .ParseError);
    try t.expectCompileError(
        \\ const all = fn(a, b, c) a + b * c
        \\ all(1, 2, 3, 4)
    , .ParseError);
}

test "function pool prototype ownership and upvalue slot reuse" {
    var pool = try FunctionPool.init(std.testing.allocator);
    defer pool.deinit();

    var name_buf = [_]u8{ 'f', 'n' };
    var specs = [_]UpvalueSpec{.{ .is_local = true, .index = 0, .mutable = false }};
    var consts = [_]LocalSlot{1};

    const proto_id = try pool.createPrototype(.{
        .addr = 9,
        .arity = 1,
        .total_arity = 1,
        .name = name_buf[0..],
        .upvalue_specs = specs[0..],
        .const_locals = consts[0..],
        .const_local_bits = &.{},
    });

    name_buf[0] = 'x';
    specs[0].index = 99;
    consts[0] = 77;

    const stored = try pool.getPrototype(proto_id);
    try std.testing.expectEqualStrings("fn", stored.name);
    try std.testing.expectEqual(@as(LocalSlot, 0), stored.upvalue_specs[0].index);
    try std.testing.expectEqual(@as(LocalSlot, 1), stored.const_locals[0]);

    const up_id = try pool.createUpvalue(.{ .open_index = null, .closed = Data.new.num(1) });
    pool.sweep();
    const up_reused = try pool.createUpvalue(.{ .open_index = null, .closed = Data.new.num(2) });
    try std.testing.expectEqual(up_id, up_reused);
}
