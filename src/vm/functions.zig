const std = @import("std");

const revo = @import("revo");

const mem = revo.memory;
const Data = mem.Data;
const t = revo.lang.testing;
const pool = @import("pool.zig");

pub const HostError = revo.vm.HostError;
pub const HostErrPayload = revo.std_lib.HostErrPayload;
pub const HostResult = revo.std_lib.HostResult;

pub const ProgramCounter = usize;
pub const LocalSlot = revo.opcode.Register;
pub const Register = revo.opcode.Register;
pub const RegisterCount = Register;
pub const PrototypeID = usize;
pub const UpvalueID = usize;

/// a single call frame. the hot fields (return_addr, base, program) come
/// first so the dispatch loop's per-instruction frame reads hit the same
/// offsets as the old dedicated hot frame; the cold fields are only touched
/// on return, stack traces, and gc marking
pub const Frame = struct {
    return_addr: ProgramCounter,
    base: usize,
    program: []const revo.Instruction,
    call_site_pc: ?ProgramCounter,
    result_register: Register,
    register_count: RegisterCount,
    closure_id: ?mem.FunctionID,
};

pub const HostFn = *const fn (args: []const Data, vm: *revo.VM) anyerror!HostResult;

/// binding table entry for a dlopen'd extension; every binding lands in
/// the module table under the import's name. the typed interface for an
/// extension is its sibling `<stem>.d.rv` manifest
pub const RevoBinding = extern struct {
    name: [*:0]const u8,
    fn_ptr: *const anyopaque,
};

/// native binding entry for zig extensions that use HostFn directly
/// extensions gotta export a null-terminated array of these as `revo_native_bindings`
/// the vm registers each as a host function with arity checking
pub const HostBinding = extern struct {
    name: [*:0]const u8,
    fn_ptr: *const anyopaque,
    arity: u8,
    variadic: bool,
};

pub const CFnPtr = *const fn (
    vm: *anyopaque,
    argc: usize,
    argv: [*]const Data,
    out_result: *Data,
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
    owner_fiber_id: ?usize,
};

pub const Function = union(enum) {
    closure: Closure,
    host: revo.std_lib.HostFunc,
    c_function: CFunction,

    pub fn arity(self: Function) u8 {
        return switch (self) {
            .closure => |f| f.arity,
            .host => |f| @intCast(f.arity),
            .c_function => VARIADIC,
        };
    }

    pub fn name(self: Function) []const u8 {
        return switch (self) {
            .closure => |f| f.name,
            .host => |f| if (f.name.len > 0) f.name else "<host>",
            .c_function => |f| f.name,
        };
    }
};

pub const FunctionPool = struct {
    alloc: std.mem.Allocator,
    // boxed: function/upvalue slots hold stable pointers, so a *Function or
    // *Upvalue from get() survives later create() calls.
    function_box_pool: std.heap.MemoryPool(Function),
    functions: std.ArrayList(?*Function),
    function_marks: std.DynamicBitSet,
    function_dead: std.ArrayList(mem.FunctionID),
    function_first: usize = pool.end,
    function_last: usize = pool.end,
    function_next: std.ArrayList(usize),
    prototypes: std.ArrayList(Prototype),
    upvalue_box_pool: std.heap.MemoryPool(Upvalue),
    upvalues: std.ArrayList(?*Upvalue),
    upvalue_marks: std.DynamicBitSet,
    upvalue_dead: std.ArrayList(UpvalueID),
    upvalue_first: usize = pool.end,
    upvalue_last: usize = pool.end,
    upvalue_next: std.ArrayList(usize),
    segments: std.ArrayList([]const revo.Instruction),

    pub fn init(alloc: std.mem.Allocator) !FunctionPool {
        return FunctionPool{
            .alloc = alloc,
            .function_box_pool = .empty,
            .functions = try .initCapacity(alloc, 16),
            .function_marks = try .initEmpty(alloc, 64),
            .function_dead = .empty,
            .function_next = try .initCapacity(alloc, 16),
            .prototypes = try .initCapacity(alloc, 16),
            .upvalue_box_pool = .empty,
            .upvalues = try .initCapacity(alloc, 16),
            .upvalue_marks = try .initEmpty(alloc, 64),
            .upvalue_dead = .empty,
            .upvalue_next = try .initCapacity(alloc, 16),
            .segments = try .initCapacity(alloc, 4),
        };
    }

    pub fn deinit(self: *FunctionPool) void {
        for (self.functions.items) |maybe_f| {
            if (maybe_f) |f| switch (f.*) {
                .closure => |closure| self.alloc.free(closure.upvalues),
                .c_function => {},
                .host => {},
            };
        }
        for (self.prototypes.items) |proto| {
            self.alloc.free(proto.name);
            self.alloc.free(proto.upvalue_specs);
            self.alloc.free(proto.const_locals);
            self.alloc.free(proto.const_local_bits);
        }
        for (self.segments.items) |seg| self.alloc.free(seg);
        self.function_box_pool.deinit(self.alloc);
        self.upvalue_box_pool.deinit(self.alloc);
        self.functions.deinit(self.alloc);
        self.function_marks.deinit();
        self.function_dead.deinit(self.alloc);
        self.function_next.deinit(self.alloc);
        self.prototypes.deinit(self.alloc);
        self.upvalues.deinit(self.alloc);
        self.upvalue_marks.deinit();
        self.upvalue_dead.deinit(self.alloc);
        self.upvalue_next.deinit(self.alloc);
        self.segments.deinit(self.alloc);
    }

    pub inline fn create(self: *FunctionPool, func: Function) !mem.FunctionID {
        return pool.create(
            self.alloc,
            Function,
            mem.FunctionID,
            &self.function_box_pool,
            &self.functions,
            &self.function_marks,
            &self.function_dead,
            &self.function_first,
            &self.function_last,
            &self.function_next,
            func,
        );
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

    pub inline fn createClosure(
        self: *FunctionPool,
        prototype_id: PrototypeID,
        upvalues: []const UpvalueID,
    ) !mem.FunctionID {
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
        return pool.create(
            self.alloc,
            Upvalue,
            UpvalueID,
            &self.upvalue_box_pool,
            &self.upvalues,
            &self.upvalue_marks,
            &self.upvalue_dead,
            &self.upvalue_first,
            &self.upvalue_last,
            &self.upvalue_next,
            upvalue,
        );
    }

    pub inline fn get(self: *FunctionPool, id: mem.FunctionID) !*Function {
        if (id >= self.functions.items.len) return error.FunctionDNE;
        if (self.functions.items[id]) |f| return f;
        return error.FunctionDNE;
    }

    pub inline fn getPrototype(self: *FunctionPool, id: PrototypeID) !*Prototype {
        if (id >= self.prototypes.items.len) return error.FunctionDNE;
        return &self.prototypes.items[id];
    }

    pub inline fn getUpvalue(self: *FunctionPool, id: UpvalueID) !*Upvalue {
        if (id >= self.upvalues.items.len) return error.FunctionDNE;
        if (self.upvalues.items[id]) |u| return u;
        return error.FunctionDNE;
    }

    pub fn mark(self: *FunctionPool, id: mem.FunctionID, vm: *revo.VM) void {
        if (id >= self.functions.items.len) return;
        if (self.function_marks.isSet(id)) return;
        if (self.functions.items[id] == null) return;
        self.function_marks.set(id);
        vm.gc_mark_stack.append(vm.runtime.alloc, .{ .function = id }) catch @panic("OOM in GC marking");
    }

    pub fn markUpvalue(self: *FunctionPool, id: UpvalueID, vm: *revo.VM) void {
        if (id >= self.upvalues.items.len) return;
        if (self.upvalue_marks.isSet(id)) return;
        if (self.upvalues.items[id] == null) return;
        self.upvalue_marks.set(id);
        vm.gc_mark_stack.append(vm.runtime.alloc, .{ .upvalue = id }) catch @panic("OOM in GC marking");
    }

    pub fn sweep(self: *FunctionPool) void {
        pool.sweep(
            self.alloc,
            Function,
            mem.FunctionID,
            &self.function_box_pool,
            &self.functions,
            &self.function_marks,
            &self.function_dead,
            &self.function_first,
            &self.function_last,
            &self.function_next,
            freeFunction,
        );

        pool.sweep(
            self.alloc,
            Upvalue,
            UpvalueID,
            &self.upvalue_box_pool,
            &self.upvalues,
            &self.upvalue_marks,
            &self.upvalue_dead,
            &self.upvalue_first,
            &self.upvalue_last,
            &self.upvalue_next,
            freeUpvalue,
        );
    }

    pub inline fn bytes(self: *const FunctionPool) usize {
        var total: usize = 0;
        var fid = self.function_first;
        while (fid != pool.end) {
            const f = self.functions.items[fid].?;
            total += 48;
            switch (f.*) {
                .closure => |closure| total += @sizeOf(UpvalueID) * closure.upvalues.len,
                .host, .c_function => {},
            }
            fid = self.function_next.items[fid];
        }
        var uid = self.upvalue_first;
        while (uid != pool.end) {
            total += 24;
            uid = self.upvalue_next.items[uid];
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
};

fn freeFunction(f: *Function, alloc: std.mem.Allocator) void {
    switch (f.*) {
        .closure => |closure| alloc.free(closure.upvalues),
        .host, .c_function => {},
    }
}

fn freeUpvalue(_: *Upvalue, _: std.mem.Allocator) void {}

test "functions call with lexical locals" {
    try t.topNumber(
        \\ const id = fn(x) x
        \\ id(42)
    , 42);
    try t.topNumber(
        \\ const add = fn(a, b) a + b
        \\ add(20, 22)
    , 42);
    try t.topNumber(
        \\ const forty_two = fn() 42
        \\ forty_two()
    , 42);
}

test "functions return exactly one value" {
    try t.topNumber(
        \\ const f = fn() do
        \\     1
        \\     2
        \\ end
        \\ f()
    , 2);
    try t.topNumber(
        \\ const f = fn() do
        \\     return 41
        \\     0
        \\ end
        \\ f()
    , 41);
    try t.topNil(
        \\ const f = fn() do
        \\     return :nil
        \\ end
        \\ f()
    );
    try t.topType(
        \\ const f = fn() {1, 2}
        \\ f()
    , .table);
    try t.topNumber(
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
    var fn_pool = try FunctionPool.init(std.testing.allocator);
    defer fn_pool.deinit();

    var name_buf = [_]u8{ 'f', 'n' };
    var specs = [_]UpvalueSpec{.{ .is_local = true, .index = 0, .mutable = false }};
    var consts = [_]LocalSlot{1};

    const proto_id = try fn_pool.createPrototype(.{
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

    const stored = try fn_pool.getPrototype(proto_id);
    try std.testing.expectEqualStrings("fn", stored.name);
    try std.testing.expectEqual(@as(LocalSlot, 0), stored.upvalue_specs[0].index);
    try std.testing.expectEqual(@as(LocalSlot, 1), stored.const_locals[0]);

    const up_id = try fn_pool.createUpvalue(.{ .open_index = null, .closed = Data.new.num(1), .owner_fiber_id = null });
    fn_pool.sweep();
    const up_reused = try fn_pool.createUpvalue(
        .{ .open_index = null, .closed = Data.new.num(2), .owner_fiber_id = null },
    );

    try std.testing.expectEqual(up_id, up_reused);
}
