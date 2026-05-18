const std = @import("std");
const builtin = @import("builtin");
const revo = @import("revo");
const root = @import("root.zig");

pub const ProgramCounter = usize;
pub const ConstantID = usize;

pub const DebugOptions = struct {
    trace: bool = false,
    dump: bool = false,
    each_instr: bool = false,
    each_stack: bool = false,
};

pub const VM = @This();
pub const GlobalID = mem.StringID;
pub const Globals = std.AutoHashMap(GlobalID, Data);
pub const ConstGlobals = std.AutoHashMap(GlobalID, void);
pub const ModuleCache = std.StringHashMap(Data);
pub const ModuleSet = std.StringHashMap(void);
pub const ChannelID = mem.TableID;
pub const FiberID = usize;
pub const PerfCounters = struct {
    instructions: u64 = 0,
    gc_collections: u64 = 0,
    call_ops: u64 = 0,
    table_get_ops: u64 = 0,
    table_set_ops: u64 = 0,
    metamethod_calls: u64 = 0,
    meta_index_fallbacks: u64 = 0,
    meta_newindex_fallbacks: u64 = 0,
};

pub const DebugInfoID = usize;
pub const DebugInfo = struct {
    spans: []Span,
    source: []const u8,
    source_name: []const u8,
};

/// another way to do so would be an enum(AtomID), and making sure they always start initialization at 0
/// not sure about that! may switch over to that model later
///
/// quite a hefty struct,,, but its worth it
pub const Fiber = struct {
    pub const OpenUpvalueRef = struct {
        slot_index: usize,
        id: root.functions.UpvalueID,
    };

    pub const WaitKey = struct {
        wait_id: u64,
    };

    pub const WaitKind = union(enum) {
        none,
        join: FiberID,
        send: ChannelID,
        recv: ChannelID,
        sleep,
        io: WaitKey,
    };

    id: FiberID,
    pc: ProgramCounter,
    program: []const Instruction,
    debug_info_id: ?DebugInfoID,
    slots: std.ArrayList(Data),
    frames: std.ArrayList(Frame),
    open_upvalues: std.ArrayList(OpenUpvalueRef),

    running: bool,
    state: State,
    in_runq: bool,
    wait: WaitKind,
    parked_result_slot: ?usize,

    result: Data = Data.new.nil(), // will be set to no_result in init
    err_atom: ?mem.AtomID = null, // error channle maybe

    waiters: std.ArrayList(FiberID),

    pub fn init(alloc: std.mem.Allocator, id: FiberID, program: []const Instruction) !Fiber {
        return .{
            .id = id,
            .pc = 0,
            .program = program,
            .debug_info_id = null,
            .slots = try std.ArrayList(Data).initCapacity(alloc, 16),
            .frames = try std.ArrayList(Frame).initCapacity(alloc, 4),
            .open_upvalues = try std.ArrayList(OpenUpvalueRef).initCapacity(alloc, 8),
            .running = false,
            .state = .ready,
            .in_runq = false,
            .wait = .none,
            .parked_result_slot = null,
            .waiters = try std.ArrayList(FiberID).initCapacity(alloc, 2),
            .result = revo.core_atoms.data(.nil),
        };
    }
    pub fn deinit(self: *Fiber, alloc: std.mem.Allocator) void {
        self.slots.deinit(alloc);
        self.frames.deinit(alloc);
        self.open_upvalues.deinit(alloc);
        self.waiters.deinit(alloc);
    }
    pub const State = enum {
        running,
        ready, // can be scheduled
        waiting, // blocked on io or waits for an event
        dead, // finished, success or fail
    };
};

const Scheduler = @import("scheduler.zig");

// concurrency
sched: Scheduler,

runtime: revo.Runtime,
// TODO: move all pools and sets into one big struct, remove useless fns like intern_atom
constants: std.ArrayList(Data),
bootstrap_globals: Globals,
tables: TablePool,
tuples: TuplePool,
functions: FunctionPool,
strings: Interner,
atoms: std.StringHashMap(mem.AtomID),
debug: DebugOptions = .{},
globals: Globals,
const_globals: ConstGlobals,
module_dir: ?[]const u8,
/// matches type enum order
metatables: [@typeInfo(memory.Type).@"enum".fields.len]?mem.TableID = .{null} ** @typeInfo(memory.Type).@"enum".fields.len,
module_cache: ModuleCache,
loading_modules: ModuleSet,
debug_infos: std.ArrayList(DebugInfo),
pending_debug_info_id: ?DebugInfoID = null,
panic_message: ?[]const u8 = null,
panic_span: ?Span = null,
runtime_message: ?[]const u8 = null,
gc_instr_counter: usize = 0,
perf: PerfCounters = .{},
host_call_depth: usize = 0,
loaded_extensions: std.ArrayList(std.DynLib),

gc_enabled: bool = true,
gc_pending: bool = false,
gc_bytes_allocated: usize = 0,
gc_threshold: usize = 512 * 1024, // 512kb initial
gc_pause_factor: usize = 2,

pub fn init(runtime: revo.Runtime) !VM {
    var vm: VM = .{
        .runtime = runtime,
        .sched = try Scheduler.init(runtime.alloc),
        .constants = try std.ArrayList(Data).initCapacity(runtime.alloc, 16),
        .bootstrap_globals = Globals.init(runtime.alloc),
        .tables = try TablePool.init(runtime.alloc),
        .tuples = try TuplePool.init(runtime.alloc),
        .functions = try FunctionPool.init(runtime.alloc),
        .strings = try Interner.init(runtime.alloc),
        .atoms = std.StringHashMap(mem.AtomID).init(runtime.alloc),
        .module_cache = ModuleCache.init(runtime.alloc),
        .loading_modules = ModuleSet.init(runtime.alloc),
        .debug_infos = try std.ArrayList(DebugInfo).initCapacity(runtime.alloc, 8),
        .globals = Globals.init(runtime.alloc),
        .const_globals = ConstGlobals.init(runtime.alloc),
        .module_dir = null,
        .loaded_extensions = try .initCapacity(runtime.alloc, 0),
    };
    // wire scheduler io poll to net poll as default; runtime may replace this
    vm.sched.io_poll = revo.std_net.pollIoWaiters;
    try vm.sched.fibers.append(runtime.alloc, .{
        .id = 0,
        .pc = 0,
        .program = &.{},
        .debug_info_id = null,
        .slots = try std.ArrayList(Data).initCapacity(runtime.alloc, 16),
        .frames = try std.ArrayList(Frame).initCapacity(runtime.alloc, 4),
        .running = false,
        .open_upvalues = try std.ArrayList(Fiber.OpenUpvalueRef).initCapacity(runtime.alloc, 8),
        .state = .ready,
        .in_runq = false,
        .wait = .none,
        .parked_result_slot = null,
        .waiters = try std.ArrayList(FiberID).initCapacity(runtime.alloc, 2),
    });
    // set initial fiber result to no_result after core atoms are initialized
    vm.sched.fibers.items[0].result = revo.core_atoms.data(.no_result);

    // true and t, false and f are equivalent
    // try vm.atoms.put("f", revo.core_atoms.atom_id(.false));
    // try vm.atoms.put("t", revo.core_atoms.atom_id(.true));

    try revo.std_lib.register_stdlib(&vm);
    var it = vm.globals.iterator();
    while (it.next()) |entry| {
        try vm.bootstrap_globals.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    // leave async backend nil unless explicitly configured by runtime host
    vm.runtime.async_backend = null;
    vm.sched.io_poll = revo.std_net.pollIoWaiters;

    return vm;
}

/// TODO: use @sizeOf everywhere at callsite because this is all over the place
pub fn noteGCPressure(self: *VM, bytes: usize) void {
    if (!self.gc_enabled) return;
    self.gc_bytes_allocated += bytes;
    if (self.gc_bytes_allocated >= self.gc_threshold) self.gc_pending = true;
}

pub fn maybeCollectGarbage(self: *VM) void {
    if (!self.gc_enabled or !self.gc_pending) return;

    self.perf.gc_collections += 1;
    self.gc_bytes_allocated = 0;
    self.gc_pending = false;
    self.markRoots();
    const live_bytes =
        self.tables.bytes() +
        self.tuples.bytes() +
        self.functions.bytes() +
        self.strings.bytes();
    self.tables.sweep();
    self.functions.sweep();
    self.tuples.sweep();
    self.strings.sweep();

    self.gc_threshold = @max(32 * 1024, live_bytes * self.gc_pause_factor);
}

pub fn resetPerfCounters(self: *VM) void {
    self.perf = .{};
}

pub fn deinit(self: *VM) void {
    self.clearProgramDebugInfo();
    self.clearPanicMessage();
    self.clearRuntimeMessage();
    self.sched.deinit(self.runtime.alloc);
    self.constants.deinit(self.runtime.alloc);
    self.globals.deinit();
    self.const_globals.deinit();
    self.bootstrap_globals.deinit();
    self.tables.deinit();
    self.tuples.deinit();
    self.functions.deinit();
    self.strings.deinit();
    self.atoms.deinit();
    for (self.debug_infos.items) |info| {
        self.runtime.alloc.free(info.spans);
        self.runtime.alloc.free(info.source);
        self.runtime.alloc.free(info.source_name);
    }
    self.debug_infos.deinit(self.runtime.alloc);
    var cache_it = self.module_cache.keyIterator();
    while (cache_it.next()) |key|
        self.runtime.alloc.free(key.*);

    self.module_cache.deinit();
    var loading_it = self.loading_modules.keyIterator();
    while (loading_it.next()) |key|
        self.runtime.alloc.free(key.*);

    self.loading_modules.deinit();

    for (self.loaded_extensions.items) |*lib| {
        if (builtin.target.os.tag != .windows)
            lib.close();
    }
    self.loaded_extensions.deinit(self.runtime.alloc);
}

pub fn addConstant(self: *VM, val: Data) !ConstantID {
    const idx: ConstantID = @intCast(self.constants.items.len);
    try self.constants.append(self.runtime.alloc, val);
    return idx;
}

// TODO: make a pools field, move all pools there
pub fn ownString(self: *VM, value: []const u8) !mem.StringID {
    return try self.strings.own(value);
}

pub fn adoptString(self: *VM, value: []u8) !mem.StringID {
    return try self.strings.adopt(value);
}

/// dupes yours
pub fn ownDataString(self: *VM, value: []const u8) !Data {
    return Data.new.str(try self.ownString(value));
}

/// kills yours
pub fn adoptDataString(self: *VM, value: []u8) !Data {
    return Data.new.str(try self.adoptString(value));
}

pub fn stringValue(self: *VM, id: mem.StringID) []const u8 {
    // SAFETY: debug helper, returns placeholder on error
    return self.strings.get(id) catch "<dead>";
}

fn getConstant(self: *VM, idx: ConstantID) !Data {
    if (idx >= self.constants.items.len) return error.InvalidConstant;
    return self.constants.items[idx];
}

pub fn push(self: *VM, val: Data) !void {
    const fiber = self.currentFiber();
    try fiber.slots.append(self.runtime.alloc, val);
}

pub fn currentResult(self: *VM) Data {
    const fiber = self.currentFiber();
    if (fiber.slots.items.len > 0) return fiber.slots.items[fiber.slots.items.len - 1];
    return fiber.result;
}

pub fn mainResult(self: *VM) Data {
    const fiber = self.mainFiber();
    if (fiber.slots.items.len > 0) return fiber.slots.items[fiber.slots.items.len - 1];
    return fiber.result;
}

pub fn printStack(self: *VM) void {
    std.debug.print("[", .{});
    for (self.currentFiber().slots.items) |item| {
        item.print(self);
        std.debug.print(", ", .{});
    }
    std.debug.print("]\n", .{});
}
//
// fiber
//
/// for iterating fast, could remove later
pub inline fn currentFiber(self: *VM) *Fiber {
    return self.sched.currentFiber();
}

/// always fiber 0
pub inline fn mainFiber(self: *VM) *Fiber {
    return self.sched.mainFiber();
}

pub fn swapFiber(self: *VM, next: Fiber) Fiber {
    var tmp = next;
    std.mem.swap(Fiber, self.currentFiber(), &tmp);
    return tmp;
}

pub fn schedParkCurrentForSleepMS(self: *VM, ms: u64) !void {
    try self.sched.parkCurrentForSleepMS(self.runtime.alloc, ms, self.schedNowMonotonicNs());
}

fn schedNowMonotonicNs(self: *VM) u64 {
    const ts = std.Io.Clock.awake.now(self.runtime.io);
    return @as(u64, @intCast(ts.toNanoseconds()));
}

fn schedSleepUntilNextTimer(self: *VM) void {
    const now_ns = self.schedNowMonotonicNs();
    if (self.sched.nextSleepDelayNs(now_ns)) |diff_ns| {
        if (diff_ns > 0) std.Io.sleep(self.runtime.io, std.Io.Duration.fromNanoseconds(@intCast(diff_ns)), .awake) catch {};
    }
}

fn runReadyFibers(self: *VM) !?EvalFailure {
    while (self.sched.dequeueRunnable()) |fid| {
        self.sched.current_fiber = fid;
        if (self.currentFiber().state == .dead) continue;
        self.sched.setFiberState(fid, .running);
        self.currentFiber().running = true;

        // get the current fiber each iteration because spawn can grow the
        // scheduler's fiber list and invalidate pointers into that array
        while (self.currentFiber().running) {
            const instr = self.fetch() catch |e| switch (e) {
                error.ProgramEnd => return null,
            };
            self.perf.instructions += 1;
            if (self.debug.each_instr) std.debug.print("+ {}\n", .{instr});
            self.evalRegister(instr) catch |e| {
                if (e == error.Parked) break;
                if (self.debug.trace) self.trace(instr);
                if (self.debug.dump) self.dumpStack();
                return self.evalFailure(e);
            };
            self.gc_instr_counter +%= 1;
            if ((self.gc_instr_counter & 63) == 0) self.maybeCollectGarbage();
            if (self.debug.trace) self.trace(instr);
            if (self.debug.each_stack) self.printStack();
            if (self.debug.dump) self.dumpStack();
        }

        if (self.currentFiber().state == .ready) {
            try self.sched.enqueueRunnable(self.runtime.alloc, fid);
        }
    }
    return null;
}

//
// slot helpers
//
pub fn pop(self: *VM) !Data {
    const fiber = self.currentFiber();
    if (fiber.slots.items.len == 0) return error.StackUnderflow;
    const ret = fiber.slots.pop() orelse unreachable;
    if (self.debug.each_stack) self.printStack();
    return ret;
}

fn absoluteRegisterIndex(self: *VM, reg: opcode.Register) !usize {
    const frame = try self.currentFrame();
    return frame.base + reg;
}

fn ensureAbsoluteSlot(self: *VM, slot: usize) !void {
    const slots = &self.currentFiber().slots;
    if (slot < slots.items.len) return;
    const old_len = slots.items.len;
    try slots.resize(self.runtime.alloc, slot + 1);
    @memset(slots.items[old_len..], revo.core_atoms.data(.missing));
}

pub fn readRegister(self: *VM, reg: opcode.Register) !Data {
    const slot = try self.absoluteRegisterIndex(reg);
    if (slot >= self.currentFiber().slots.items.len) return revo.core_atoms.data(.missing);
    return self.currentFiber().slots.items[slot];
}

pub fn writeRegister(self: *VM, reg: opcode.Register, value: Data) !void {
    const slot = try self.absoluteRegisterIndex(reg);
    try self.ensureAbsoluteSlot(slot);
    self.currentFiber().slots.items[slot] = value;
}

/// call when 0 <= slot < slots.len
pub inline fn readRegisterUnsafe(self: *VM, slot: usize) Data {
    return self.currentFiber().slots.items[slot];
}

/// call when slot is valid and capacity is enough
pub inline fn writeRegisterUnsafe(self: *VM, slot: usize, value: Data) void {
    self.currentFiber().slots.items[slot] = value;
}

/// avoid recomputing currentFrame() repeatedly
/// callers should cache `base = frame.base`
pub inline fn readRegisterFast(self: *VM, base: usize, reg: opcode.Register) Data {
    const slot = base + reg;
    if (slot >= self.currentFiber().slots.items.len) return revo.core_atoms.data(.missing);
    return self.readRegisterUnsafe(slot);
}

/// avoid recomputing currentFrame() repeatedly
/// callers should cache `base = frame.base`
pub inline fn writeRegisterFast(self: *VM, base: usize, reg: opcode.Register, value: Data) !void {
    const slot = base + reg;
    // happy path: if current frame declares a register_count and the slot lies within it,
    // you can write without resizing
    if (self.currentFiber().frames.items.len > 0) {
        const f = self.currentFiber().frames.items[self.currentFiber().frames.items.len - 1];
        if (f.register_count > 0) {
            const frame_end = f.base + f.register_count;
            if (slot < frame_end) {
                self.writeRegisterUnsafe(slot, value);
                return;
            }
        }
    }
    try self.ensureAbsoluteSlot(slot);
    self.writeRegisterUnsafe(slot, value);
}

fn copyRegister(self: *VM, dst: opcode.Register, src: opcode.Register) !void {
    const dst_slot = try self.absoluteRegisterIndex(dst);
    const src_slot = try self.absoluteRegisterIndex(src);
    if (src_slot < self.currentFiber().slots.items.len) {
        try self.ensureAbsoluteSlot(dst_slot);
        self.currentFiber().slots.items[dst_slot] = self.currentFiber().slots.items[src_slot];
    } else {
        try self.ensureAbsoluteSlot(dst_slot);
        self.currentFiber().slots.items[dst_slot] = revo.core_atoms.data(.missing);
    }
}

pub fn internAtom(self: *VM, name: []const u8) !mem.AtomID {
    if (self.atoms.get(name)) |id| return id;
    const id = try self.strings.own(name);
    const owned = self.strings.getAssumeAlive(id);
    try self.atoms.put(owned, id);
    return id;
}

pub fn atomName(self: *VM, id: mem.AtomID) []const u8 {
    // SAFETY: debug helper, returns placeholder on error
    return self.strings.get(id) catch "<dead>";
}

pub fn dataAtom(self: *VM, name: []const u8) !Data {
    if (self.atoms.get(name)) |id| return .{ .atom = id };
    const id = try self.strings.own(name);
    const owned = self.strings.getAssumeAlive(id);
    try self.atoms.put(owned, id);
    return .{ .atom = id };
}

pub fn setGlobal(self: *VM, name: []const u8, val: Data) !void {
    const id = try self.internAtom(name);
    try self.globals.put(id, val);
}

pub fn seedBootstrapGlobals(self: *VM, target: *Globals) !void {
    var it = self.bootstrap_globals.iterator();
    while (it.next()) |entry| {
        try target.put(entry.key_ptr.*, entry.value_ptr.*);
    }
}

pub fn getGlobal(self: *VM, name: []const u8) ?Data {
    if (self.atoms.get(name)) |id| return self.globals.get(id);
    return revo.core_atoms.data(.undef);
}

pub fn setProgramDebugInfo(self: *VM, spans: []const Span, source: []const u8, source_name: []const u8) !void {
    const id: DebugInfoID = @intCast(self.debug_infos.items.len);
    try self.debug_infos.append(self.runtime.alloc, .{
        .spans = try self.runtime.alloc.dupe(Span, spans),
        .source = try self.runtime.alloc.dupe(u8, source),
        .source_name = try self.runtime.alloc.dupe(u8, source_name),
    });
    self.pending_debug_info_id = id;
}

pub fn setProgramSourceName(self: *VM, source_name: []const u8) !void {
    const id = self.pending_debug_info_id orelse {
        try self.setProgramDebugInfo(&.{}, "", source_name);
        return;
    };
    const info = &self.debug_infos.items[id];
    self.runtime.alloc.free(info.source_name);
    info.source_name = try self.runtime.alloc.dupe(u8, source_name);
}

pub fn clearProgramDebugInfo(self: *VM) void {
    self.pending_debug_info_id = null;
}

fn debugInfo(self: *VM, id: DebugInfoID) ?*const DebugInfo {
    if (id >= self.debug_infos.items.len) return null;
    return &self.debug_infos.items[id];
}

pub fn currentDebugInfo(self: *VM) ?*const DebugInfo {
    if (self.currentFiber().debug_info_id) |id| return self.debugInfo(id);
    if (self.pending_debug_info_id) |id| return self.debugInfo(id);
    return null;
}

pub fn currentDebugSource(self: *VM) ?[]const u8 {
    return if (self.currentDebugInfo()) |info| info.source else null;
}

pub fn currentDebugSourceName(self: *VM) ?[]const u8 {
    return if (self.currentDebugInfo()) |info| info.source_name else null;
}

fn spanAtPc(self: *VM, info: *const DebugInfo, pc: ProgramCounter) ?Span {
    _ = self;
    if (pc >= info.spans.len) return null;
    return info.spans[pc];
}

fn frameName(self: *VM, closure_id: ?mem.FunctionID) []const u8 {
    const id = closure_id orelse return "<entry>";
    const func = self.functions.get(id) catch return "<dead>";
    return switch (func.*) {
        .closure => |closure| if (std.mem.eql(u8, closure.name, "__main")) "<module>" else closure.name,
        .native => "<native>",
        .c_function => "<c func>",
    };
}

pub fn setPanicMessage(self: *VM, message: []const u8) !void {
    self.clearPanicMessage();
    self.panic_message = try self.runtime.alloc.dupe(u8, message);
}

pub fn setPanicMessageOwned(self: *VM, message: []u8) void {
    self.clearPanicMessage();
    self.panic_message = message;
}

pub fn clearPanicMessage(self: *VM) void {
    if (self.panic_message) |message| self.runtime.alloc.free(message);
    self.panic_message = null;
    self.panic_span = null;
}

pub fn setRuntimeMessage(self: *VM, message: []const u8) !void {
    self.clearRuntimeMessage();
    self.runtime_message = try self.runtime.alloc.dupe(u8, message);
}

pub fn setRuntimeMessageFmt(self: *VM, comptime fmt_str: []const u8, args: anytype) !void {
    const message = try std.fmt.allocPrint(self.runtime.alloc, fmt_str, args);
    self.clearRuntimeMessage();
    self.runtime_message = message;
}

pub fn setRuntimeMessageOwned(self: *VM, message: []u8) void {
    self.clearRuntimeMessage();
    self.runtime_message = message;
}

pub fn clearRuntimeMessage(self: *VM) void {
    if (self.runtime_message) |message| self.runtime.alloc.free(message);
    self.runtime_message = null;
}

pub fn currentFrame(self: *VM) !*Frame {
    if (self.currentFiber().frames.items.len == 0) return error.FrameUnderflow;
    return &self.currentFiber().frames.items[self.currentFiber().frames.items.len - 1];
}

fn currentClosure(self: *VM) !?*root.functions.Closure {
    const frame = try self.currentFrame();
    const closure_id = frame.closure_id orelse return null;
    const func = try self.functions.get(closure_id);
    return switch (func.*) {
        .closure => |*closure| closure,
        .native, .c_function => null,
    };
}

fn localIsConst(self: *VM, slot: root.functions.LocalSlot) !bool {
    const closure = (try self.currentClosure()) orelse return false;
    const proto = try self.functions.getPrototype(closure.prototype);
    const idx = slot / 8;
    if (idx >= proto.const_local_bits.len) return false;
    const bit: u3 = @intCast(slot % 8);
    return (proto.const_local_bits[idx] & (@as(u8, 1) << bit)) != 0;
}

fn captureUpvalue(self: *VM, slot_index: usize) !root.functions.UpvalueID {
    const open = &self.currentFiber().open_upvalues;
    for (open.items, 0..) |entry, idx| {
        if (entry.slot_index == slot_index) return entry.id;
        if (entry.slot_index > slot_index) {
            const upvalue_id = try self.functions.createUpvalue(.{
                .open_index = slot_index,
                .closed = revo.core_atoms.data(.missing),
            });
            try open.insert(self.runtime.alloc, idx, .{ .slot_index = slot_index, .id = upvalue_id });
            return upvalue_id;
        }
    }
    const upvalue_id = try self.functions.createUpvalue(.{
        .open_index = slot_index,
        .closed = revo.core_atoms.data(.missing),
    });
    try open.append(self.runtime.alloc, .{ .slot_index = slot_index, .id = upvalue_id });
    return upvalue_id;
}

fn closeUpvalues(self: *VM, from_index: usize) !void {
    const open = &self.currentFiber().open_upvalues;
    while (open.items.len > 0) {
        const last_idx = open.items.len - 1;
        const entry = open.items[last_idx];
        if (entry.slot_index < from_index) break;

        const upvalue = try self.functions.getUpvalue(entry.id);
        if (upvalue.open_index) |slot_index| {
            upvalue.closed = self.currentFiber().slots.items[slot_index];
            _ = self.const_globals.remove(slot_index);
            upvalue.open_index = null;
        }
        _ = open.pop();
    }
}

fn loadUpvalueData(self: *VM, upvalue_id: root.functions.UpvalueID) !Data {
    const upvalue = try self.functions.getUpvalue(upvalue_id);
    if (upvalue.open_index) |slot_index| return self.currentFiber().slots.items[slot_index];
    return upvalue.closed;
}

fn storeUpvalueData(self: *VM, upvalue_id: root.functions.UpvalueID, value: Data) !void {
    const upvalue = try self.functions.getUpvalue(upvalue_id);
    if (upvalue.open_index) |slot_index| {
        self.currentFiber().slots.items[slot_index] = value;
    } else {
        upvalue.closed = value;
    }
}

fn detachClosureForFiber(self: *VM, closure_id: mem.FunctionID) !mem.FunctionID {
    const func = try self.functions.get(closure_id);
    const closure = switch (func.*) {
        .closure => |value| value,
        .native, .c_function => return closure_id,
    };
    if (closure.upvalues.len == 0) return closure_id;

    var detached = try std.ArrayList(root.functions.UpvalueID).initCapacity(self.runtime.alloc, closure.upvalues.len);
    defer detached.deinit(self.runtime.alloc);

    for (closure.upvalues) |upvalue_id| {
        try detached.append(
            self.runtime.alloc,
            try self.functions.createUpvalue(.{
                .open_index = null,
                .closed = try self.loadUpvalueData(upvalue_id),
            }),
        );
    }

    return self.functions.createClosure(closure.prototype, detached.items);
}

fn fetch(self: *VM) !Instruction {
    const fiber = self.currentFiber();
    if (fiber.pc >= fiber.program.len) return error.ProgramEnd;
    const instr = fiber.program[fiber.pc];
    fiber.pc += 1;
    return instr;
}

fn trace(self: *VM, instr: Instruction) void {
    const fiber = self.currentFiber();
    std.debug.print("[{d:>4}] {s:<16}\n", .{ fiber.pc - 1, @tagName(instr.op) });
}

fn dumpStack(self: *VM) void {
    const fiber = self.currentFiber();
    std.debug.print("       stack: [ ", .{});
    for (fiber.slots.items) |item| {
        item.print(self);
        std.debug.print(" ", .{});
    }
    std.debug.print("]\n", .{});
}

pub fn run(self: *VM) !void {
    return switch (try self.runReport()) {
        .ok => {},
        .err => return error.RuntimeFailure,
    };
}

pub fn runReport(self: *VM) !EvalResult {
    self.clearPanicMessage();
    self.clearRuntimeMessage();
    if (self.mainFiber().frames.items.len == 0) {
        if (self.mainFiber().debug_info_id == null) self.mainFiber().debug_info_id = self.pending_debug_info_id;
        try self.mainFiber().frames.append(self.runtime.alloc, .{
            .return_addr = @intCast(self.mainFiber().program.len),
            .base = 0,
        });
    }
    self.sched.setFiberState(0, .ready);
    try self.sched.enqueueRunnable(self.runtime.alloc, 0);

    while (true) {
        if (try self.runReadyFibers()) |failure| {
            return .{ .err = failure };
        }
        try self.sched.wakeDueSleepers(self.runtime.alloc, self.schedNowMonotonicNs());
        const has_sleepers = self.sched.sleepers.items.len > 0;
        const has_io_waiters = self.sched.io_waiters.items.len > 0;
        const has_waiting = self.sched.waiting_cnt > 0;

        if (!has_sleepers and !has_waiting) break;

        if (has_io_waiters or (revo.has_async_backend and has_waiting)) {
            const timeout_ms: i32 = if (self.sched.nextSleepDelayNs(self.schedNowMonotonicNs())) |delay_ns|
                @as(i32, @intCast(@min(delay_ns / std.time.ns_per_ms, @as(u64, std.math.maxInt(i32)))))
            else
                -1;
            // call configured io poll helper to wait for fd events
            const io_poll = self.sched.io_poll orelse {
                try self.setRuntimeMessage("io poll is not configured");
                return .{ .err = self.evalFailure(error.Panic) };
            };
            _ = io_poll(self, timeout_ms) catch return .{ .err = self.evalFailure(error.Panic) };
            try self.sched.wakeDueSleepers(self.runtime.alloc, self.schedNowMonotonicNs());
            continue;
        }
        if (has_sleepers) {
            self.schedSleepUntilNextTimer();
            try self.sched.wakeDueSleepers(self.runtime.alloc, self.schedNowMonotonicNs());
        }
    }
    return .ok;
}

fn callFunctionParts(self: *VM, callee: Data, maybe_first: ?Data, args: []const Data) EvalError!Data {
    self.host_call_depth += 1;
    defer self.host_call_depth -= 1;

    const fiber = self.currentFiber();
    const initial_frame_depth = fiber.frames.items.len;
    const initial_pc = fiber.pc;
    const initial_slot_len = fiber.slots.items.len;
    if (fiber.frames.items.len == 0) {
        if (fiber.debug_info_id == null) fiber.debug_info_id = self.pending_debug_info_id;
        try fiber.frames.append(self.runtime.alloc, .{
            .return_addr = @intCast(fiber.program.len),
            .base = 0,
        });
    }

    const caller_frame_depth = fiber.frames.items.len;
    const base = (try self.currentFrame()).base;
    const callee_slot = fiber.slots.items.len;
    errdefer {
        fiber.slots.items.len = initial_slot_len;
        fiber.pc = initial_pc;
        while (fiber.frames.items.len > initial_frame_depth) {
            _ = fiber.frames.pop();
        }
    }
    try fiber.slots.append(self.runtime.alloc, callee);
    if (maybe_first) |first| {
        try fiber.slots.append(self.runtime.alloc, first);
    }
    for (args) |arg| try fiber.slots.append(self.runtime.alloc, arg);

    const call_reg_usize = callee_slot - base;
    if (call_reg_usize > std.math.maxInt(opcode.Register)) return error.InvalidBytecode;
    const call_reg: opcode.Register = @intCast(call_reg_usize);
    const argc_usize = args.len + if (maybe_first != null) @as(usize, 1) else @as(usize, 0);
    const argc: opcode.Register = @intCast(argc_usize);

    try self.callRegister(.{
        .op = .call,
        .a = call_reg,
        .b = argc,
        .c = call_reg,
    });

    if (fiber.frames.items.len > caller_frame_depth) {
        while (fiber.frames.items.len > caller_frame_depth) {
            const instr = try self.fetch();
            if (self.debug.each_instr) std.debug.print("+ {}\n", .{instr});
            try self.evalRegister(instr);
            if (self.debug.trace) self.trace(instr);
            if (self.debug.each_stack) self.printStack();
            if (self.debug.dump) self.dumpStack();
        }
    }

    const result = fiber.slots.items[callee_slot];
    fiber.slots.items.len = callee_slot;
    return result;
}

// TODO inline everywhere
pub inline fn callFunction(self: *VM, callee: Data, args: []const Data) EvalError!Data {
    return self.callFunctionParts(callee, null, args);
}

pub fn compare(self: *VM, lh: Data, rh: Data) std.math.Order {
    return compare_impl.compare(self, lh, rh);
}

pub fn evalFailure(self: *VM, err: EvalError) EvalFailure {
    const kind: EvalErrorKind = switch (err) {
        inline else => |tag| @field(EvalErrorKind, @errorName(tag)),
    };
    const info = self.currentDebugInfo();
    const current_pc = if (self.currentFiber().pc > 0) self.currentFiber().pc - 1 else 0;
    const frames = self.currentFiber().frames.items;
    var primary_span = if (info) |debug| self.spanAtPc(debug, current_pc) else null;

    // struct ctor panics originate in generated wrapper code; prefer the user callsite
    if (kind == .Panic and self.panic_message != null) {
        if (self.panic_span) |span| primary_span = span;
        const msg = self.panic_message.?;
        const is_struct_panic = std.mem.indexOf(u8, msg, " for struct `") != null or
            (std.mem.indexOf(u8, msg, " on `") != null and std.mem.indexOf(u8, msg, " expected ") != null);
        const top_is_non_module = blk: {
            if (frames.len == 0) break :blk false;
            if (frames[frames.len - 1].closure_id) |id| {
                break :blk !std.mem.eql(u8, self.frameName(id), "<module>");
            }
            break :blk false;
        };
        if (is_struct_panic and top_is_non_module and
            frames[frames.len - 1].call_site_pc != null and info != null)
        {
            primary_span = self.spanAtPc(info orelse unreachable, frames[frames.len - 1].call_site_pc orelse unreachable);
        }
    }

    var failure = EvalFailure{
        .kind = kind,
        .span = primary_span,
        .message = if (kind == .Panic and self.panic_message != null)
            self.panic_message orelse unreachable
        else if (self.runtime_message) |message|
            message
        else
            kind.message(),
        .source = if (info) |debug| debug.source else null,
        .source_name = if (info) |debug| debug.source_name else null,
    };

    var out_idx: usize = 0;
    var i = frames.len;
    while (i > 0 and out_idx < EvalFailure.max_trace_frames) {
        i -= 1;
        const frame = frames[i];
        if (frame.closure_id == null) continue;
        failure.trace[out_idx] = .{
            .function_name = self.frameName(frame.closure_id),
            .source_name = if (info) |debug| debug.source_name else null,
            .source = if (info) |debug| debug.source else null,
            .span = if (info) |debug|
                if (i == frames.len - 1)
                    self.spanAtPc(debug, current_pc)
                else if (frame.call_site_pc) |pc|
                    self.spanAtPc(debug, pc)
                else
                    null
            else
                null,
            .pc = if (i == frames.len - 1) current_pc else frame.call_site_pc,
        };
        out_idx += 1;
    }
    failure.trace_len = out_idx;
    return failure;
}

pub fn callBinaryMetamethodByAtom(self: *VM, a: Data, b: Data, atom: mem.AtomID) !?Data {
    if (try self.getMetamethodByAtom(a, atom)) |mm| {
        self.perf.metamethod_calls += 1;
        return try self.callFunction(mm, &.{ a, b });
    }
    if (try self.getMetamethodByAtom(b, atom)) |mm| {
        self.perf.metamethod_calls += 1;
        return try self.callFunction(mm, &.{ a, b });
    }
    return null;
}

pub fn getMetamethodByAtom(self: *VM, val: Data, atom: mem.AtomID) !?Data {
    const mt_id = try self.getMetatableId(val) orelse return null;
    const mt = try self.tables.get(mt_id);
    return mt.getRaw(.{ .atom = atom });
}

pub fn getMetatableId(self: *VM, val: Data) !?mem.TableID {
    return switch (val) {
        .table => |id| blk: {
            if (self.tables.get(id)) |value| {
                if (value.metatable) |mt_id| break :blk mt_id;
            } else |_| {}
            break :blk self.metatables[@intFromEnum(std.meta.Tag(Data).table)];
        },
        .tuple => |id| blk: {
            if (self.tuples.get(id)) |value| {
                if (value.metatable) |mt_id| break :blk mt_id;
            } else |_| {}
            break :blk self.metatables[@intFromEnum(std.meta.Tag(Data).tuple)];
        },
        .number => self.metatables[@intFromEnum(std.meta.Tag(Data).number)],
        else => self.metatables[@intFromEnum(std.meta.activeTag(val))],
    };
}

pub const EvalError = error{
    StackUnderflow,
    StackOverflow,
    InvalidConstant,
    InvalidLocal,
    TypeError,
    IncompatibleTypes,
    DivisionByZero,
    UndefinedVariable,
    NotAFunction,
    WrongArity,
    FrameUnderflow,
    InvalidBytecode,
    FunctionDNE,
    InvalidTable,
    InvalidTuple,
    OutOfMemory,
} || root.functions.NativeError;

fn writeAbsoluteSlot(self: *VM, slot: usize, value: Data) !void {
    try self.ensureAbsoluteSlot(slot);
    self.currentFiber().slots.items[slot] = value;
}

fn callRegister(self: *VM, instr: Instruction) EvalError!void {
    self.perf.call_ops += 1;
    const frame = try self.currentFrame();
    const base = frame.base;
    const callee_slot = base + instr.a;
    const argc: usize = instr.b;
    const callee = if (callee_slot < self.currentFiber().slots.items.len)
        self.currentFiber().slots.items[callee_slot]
    else
        revo.core_atoms.data(.missing);

    // try __call mm on non-fn callees
    if (callee == .table) {
        // branch check explicit __call mm
        if (try self.getMetamethodByAtom(callee, revo.core_atoms.atom_id(.__call))) |mm| {
            self.perf.metamethod_calls += 1;
            const args_start = callee_slot + 1;
            const args_end = args_start + argc;
            try self.ensureAbsoluteSlot(args_end);
            const args = self.currentFiber().slots.items[args_start..args_end];
            const result = try self.callFunctionParts(mm, callee, args);
            try self.writeRegisterFast(base, instr.c, result);
            return;
        }

        // check if this is a struct desc (has __fields key)
        const table_id = callee.table;
        const table = try self.tables.get(table_id);
        if (table.getRaw(.{ .atom = try self.internAtom("__fields") })) |_| {
            // if so call @struct_new
            const struct_new_atom = try self.internAtom("@struct_new");
            if (self.globals.get(struct_new_atom)) |struct_new_fn| {
                const args_start = callee_slot + 1;
                const args_end = args_start + argc;
                try self.ensureAbsoluteSlot(args_end);
                const args = self.currentFiber().slots.items[args_start..args_end];
                const result = try self.callFunctionParts(struct_new_fn, callee, args);
                try self.writeRegisterFast(base, instr.c, result);
                return;
            }
        }
    }

    // callee must be a function
    const func = switch (callee) {
        .function => |id| try self.functions.get(id),
        else => |other| {
            const got = switch (other) {
                .number => "number",
                else => @tagName(other),
            };
            try self.setRuntimeMessageFmt("expected function, got {s}", .{got});
            // std.debug.print("val is {}", .{other});
            return error.NotAFunction;
        },
    };

    switch (func.*) {
        .c_function => |f| {
            const args_start = callee_slot + 1;
            const args_end = args_start + argc;
            try self.ensureAbsoluteSlot(args_end);
            const args = self.currentFiber().slots.items[args_start..args_end];

            var c_args = try self.runtime.alloc.alloc(revo.ffi.CRevoData, args.len);
            defer self.runtime.alloc.free(c_args);

            var string_copies = try std.ArrayList([:0]u8).initCapacity(self.runtime.alloc, argc);
            defer {
                for (string_copies.items) |copy| self.runtime.alloc.free(copy);
                string_copies.deinit(self.runtime.alloc);
            }

            for (args, 0..) |arg, i|
                c_args[i] = try revo.ffi.CRevoData.ofData(arg, self.runtime.alloc, &self.strings, &string_copies);

            var c_result: revo.ffi.CRevoData = .{ .tag = 0, .value = 0 };
            f.fn_ptr(@ptrCast(self), argc, c_args.ptr, &c_result);

            try self.writeRegisterFast(base, instr.c, try c_result.toData(self));
        },
        .native => |f| {
            const args_start = callee_slot + 1;
            const args_end = args_start + argc;
            try self.ensureAbsoluteSlot(args_end);
            const args = self.currentFiber().slots.items[args_start..args_end];

            if ((!f.variadic and argc != f.arity) or (f.variadic and argc < f.arity)) {
                var params = try std.ArrayList(u8).initCapacity(self.runtime.alloc, 8);
                for (f.param_types, 0..) |t, i| {
                    if (i > 0) try params.appendSlice(self.runtime.alloc, ", ");
                    try params.appendSlice(self.runtime.alloc, @tagName(t));
                }
                const params_str = try params.toOwnedSlice(self.runtime.alloc);
                defer self.runtime.alloc.free(params_str);
                try self.setRuntimeMessageFmt("function expected {d} args({s}), got {d}", .{ f.arity, params_str, argc });
                return error.WrongArity;
            }

            for (f.param_types, 0..) |spec, i| {
                if (!spec.matches(args[i])) {
                    try self.setRuntimeMessageFmt("argument {d}: expected {s}, got {s}", .{ i, @tagName(spec), revo.std_lib.dataToString(args[i]) });
                    return error.TypeError;
                }
            }

            const result = f.func(args, self) catch |err| {
                if (self.runtime_message == null) {
                    try self.setRuntimeMessage(@errorName(err));
                }
                return error.Panic;
            };
            switch (result) {
                .ok => |data| try self.writeRegisterFast(base, instr.c, data),
                // maybe push err tpl here instead
                .err => |err| {
                    switch (err) {
                        .wrong_arity => |info| {
                            const name = func.name();
                            try self.setRuntimeMessageFmt(
                                "function {s} expected {d} args, got {d}",
                                .{ name, info.expected, info.got },
                            );
                            return error.WrongArity;
                        },
                        .type_error => |info| {
                            if (info.arg) |arg| {
                                try self.setRuntimeMessageFmt("argument {d}: expected {s}, got {s}", .{ arg, info.expected, info.got });
                            } else {
                                try self.setRuntimeMessageFmt("expected {s}, got {s}", .{ info.expected, info.got });
                            }
                            return error.TypeError;
                        },
                        .native_error => |native_err| return native_err,
                        .parked => {
                            self.currentFiber().parked_result_slot = try self.absoluteRegisterIndex(instr.c);
                            try self.writeRegisterFast(base, instr.c, revo.core_atoms.data(.missing));
                            return error.Parked;
                        },
                        .other => |msg| {
                            try self.setRuntimeMessage(msg);
                            return error.Panic;
                        },
                    }
                },
            }
        },
        .closure => |closure| {
            const proto = try self.functions.getPrototype(closure.prototype);
            if (closure.arity != root.functions.VARIADIC and closure.arity != argc) {
                try self.setRuntimeMessageFmt("function `{s}` expected {d} args, got {d}", .{ proto.name, closure.arity, argc });
                return error.WrongArity;
            }
            if (self.host_call_depth == 0 and
                self.currentFiber().pc < self.currentFiber().program.len and
                self.currentFiber().program[self.currentFiber().pc].op == .ret)
            {
                const tail_frame = try self.currentFrame();
                if (tail_frame.closure_id != null and tail_frame.base > 0) {
                    const caller_fn_slot = tail_frame.base - 1;
                    const moved_len = argc + 1;
                    try self.closeUpvalues(tail_frame.base);
                    if (callee_slot != caller_fn_slot) {
                        std.mem.copyForwards(
                            Data,
                            self.currentFiber().slots.items[caller_fn_slot .. caller_fn_slot + moved_len],
                            self.currentFiber().slots.items[callee_slot .. callee_slot + moved_len],
                        );
                    }
                    tail_frame.base = caller_fn_slot + 1;
                    tail_frame.call_site_pc = self.currentFiber().pc - 1;
                    tail_frame.closure_id = callee.function;
                    tail_frame.register_count = proto.register_count;
                    if (proto.register_count > 0) {
                        try self.ensureAbsoluteSlot(tail_frame.base + proto.register_count - 1);
                        for (argc..proto.register_count) |idx| {
                            self.currentFiber().slots.items[tail_frame.base + idx] = revo.core_atoms.data(.missing);
                        }
                    }
                    self.currentFiber().pc = proto.addr;
                    return;
                }
            }
            if (self.currentFiber().frames.items.len >= 256) return error.StackOverflow;

            const new_base = callee_slot + 1;
            if (proto.register_count > 0) {
                // prealloc callee reg window so inner writes dont need to resize
                const end_slot = new_base + proto.register_count - 1;
                try self.ensureAbsoluteSlot(end_slot);
                for (argc..proto.register_count) |idx| {
                    self.currentFiber().slots.items[new_base + idx] = revo.core_atoms.data(.missing);
                }
            }
            try self.currentFiber().frames.append(self.runtime.alloc, .{
                .return_addr = self.currentFiber().pc,
                .call_site_pc = self.currentFiber().pc - 1,
                .base = new_base,
                .result_register = instr.c,
                .register_count = proto.register_count,
                .closure_id = callee.function,
            });
            self.currentFiber().pc = proto.addr;
        },
    }
}

fn callFieldRegister(self: *VM, instr: Instruction) EvalError!void {
    const colon = (instr.b & @as(opcode.Register, 1 << 15)) != 0;
    const explicit_argc: usize = @intCast(instr.b & ~@as(opcode.Register, 1 << 15));

    const object = try self.readRegister(instr.a);
    const key = try self.readRegister(instr.a + 1);
    const lookup_result = (try self.resolveField(object, key)) orelse {
        try self.setRuntimeMessage("regcalled field does not exist");
        return error.NotAFunction;
    };

    const base = try self.absoluteRegisterIndex(instr.a);

    try self.writeRegister(instr.a, lookup_result.value);

    if (colon) {
        try self.writeRegister(instr.a + 1, object);
        try self.callRegister(.{ .op = .call, .a = instr.a, .b = @intCast(explicit_argc + 1), .c = instr.c });
        return;
    }

    if (explicit_argc > 0) {
        std.mem.copyForwards(
            Data,
            self.currentFiber().slots.items[base + 1 .. base + 1 + explicit_argc],
            self.currentFiber().slots.items[base + 2 .. base + 2 + explicit_argc],
        );
    }
    try self.callRegister(.{ .op = .call, .a = instr.a, .b = @intCast(explicit_argc), .c = instr.c });
}

fn returnRegister(self: *VM, instr: Instruction) EvalError!void {
    const result = try self.readRegister(instr.a);
    const frame = self.currentFiber().frames.pop() orelse unreachable;
    try self.closeUpvalues(frame.base);
    self.currentFiber().pc = frame.return_addr;

    // check if returning to the exit frame (only one frame left after pop)
    const returning_to_exit = self.sched.current_fiber == 0 and self.currentFiber().frames.items.len == 1;

    // toplevel :err tuple should panic
    if (returning_to_exit and result == .tuple) {
        const tuple = try self.tuples.get(result.tuple);
        if (tuple.items.len >= 1) {
            const tag = tuple.items[0];
            if (tag == .atom and tag.atom == revo.core_atoms.atom_id(.err)) {
                self.panic_span = if (self.currentDebugInfo()) |debug|
                    self.spanAtPc(debug, if (self.currentFiber().pc > 0) self.currentFiber().pc - 1 else 0)
                else
                    null;
                if (tuple.items.len >= 2) {
                    var buf = std.Io.Writer.Allocating.init(self.runtime.alloc);
                    defer buf.deinit();
                    tuple.items[1].write(&buf.writer, self, .display) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.Panic,
                    };
                    self.setPanicMessageOwned(try buf.toOwnedSlice());
                }
                return error.Panic;
            }
        }
    }

    if (self.currentFiber().frames.items.len == 0 or self.currentFiber().pc >= self.currentFiber().program.len) {
        const finished_id = self.sched.current_fiber;
        try self.sched.finishFiber(self.runtime.alloc, finished_id, result);
        if (finished_id == 0) {
            self.currentFiber().slots.items.len = 0;
            try self.push(result);
        }
        return;
    }

    const parent = try self.currentFrame();
    const result_slot = parent.base + frame.result_register;
    self.currentFiber().slots.items.len = result_slot + 1;
    try self.writeAbsoluteSlot(result_slot, result);
}

fn spawnRegister(self: *VM, instr: Instruction) EvalError!void {
    const argc: usize = instr.b;
    const callee = try self.readRegister(instr.a);
    const closure_id = switch (callee) {
        .function => |id| id,
        else => {
            try self.setRuntimeMessage("spawn expects function!");
            return error.NotAFunction;
        },
    };
    const func = try self.functions.get(closure_id);
    const closure = switch (func.*) {
        .closure => |f| f,
        else => {
            try self.setRuntimeMessage("spawn expects closure!");
            return error.NotAFunction;
        },
    };
    const proto = try self.functions.getPrototype(closure.prototype);
    if (closure.arity != root.functions.VARIADIC and closure.arity != argc) {
        try self.setRuntimeMessageFmt("fiber closure `{s}` expected {d} args, got {d}", .{ proto.name, closure.arity, argc });
        return error.WrongArity;
    }

    const child_id: FiberID = self.sched.fibers.items.len;
    var child = try Fiber.init(self.runtime.alloc, child_id, self.currentFiber().program);
    errdefer child.deinit(self.runtime.alloc);
    child.debug_info_id = self.currentFiber().debug_info_id;
    child.state = .ready;
    const child_slot_count: usize = @max(@as(usize, proto.register_count), argc);
    if (child_slot_count > 0) {
        try child.slots.resize(self.runtime.alloc, child_slot_count);
        @memset(child.slots.items, revo.core_atoms.data(.missing));
    }
    for (0..argc) |idx| {
        // this is safe
        const src_reg = instr.a + 1 + @as(opcode.Register, @intCast(idx));
        const src_slot = try self.absoluteRegisterIndex(src_reg);
        if (src_slot < self.currentFiber().slots.items.len) {
            child.slots.items[idx] = self.currentFiber().slots.items[src_slot];
        } else {
            child.slots.items[idx] = revo.core_atoms.data(.missing);
        }
    }
    const child_closure_id = try self.detachClosureForFiber(closure_id);
    try child.frames.append(self.runtime.alloc, .{
        .return_addr = @intCast(child.program.len),
        .base = 0,
        .result_register = 0,
        .register_count = proto.register_count,
        .closure_id = child_closure_id,
    });
    child.pc = proto.addr;

    try self.sched.fibers.append(self.runtime.alloc, child);
    try self.sched.enqueueRunnable(self.runtime.alloc, child_id);
    try self.writeRegister(instr.c, Data.new.num(@as(i64, @intCast(child_id))));
}

fn evalRegister(self: *VM, instr: Instruction) EvalError!void {
    // std.debug.print("{any}\n", .{instr});
    const cur_frame = try self.currentFrame();
    const base = cur_frame.base;
    switch (instr.op) {
        .move => try self.copyRegister(instr.a, instr.b),
        .load_const => try self.writeRegisterFast(base, instr.a, try self.getConstant(instr.bx)),
        .load_nil => try self.writeRegisterFast(base, instr.a, revo.core_atoms.data(.nil)),
        .load_small_int => try self.writeRegisterFast(base, instr.a, Data.new.num(@as(i64, @intCast(instr.bx)))),
        .add => {
            const lhs = self.readRegisterFast(base, instr.b);
            const rhs = self.readRegisterFast(base, instr.c);
            const lnum = lhs.as_number() catch null;
            const rnum = rhs.as_number() catch null;
            if (lnum != null and rnum != null) {
                try self.writeRegisterFast(base, instr.a, Data.new.num(lnum.? + rnum.?));
                return;
            }
            if (try self.callBinaryMetamethodByAtom(lhs, rhs, revo.core_atoms.atom_id(.__add))) |result| {
                try self.writeRegisterFast(base, instr.a, result);
                return;
            }
            try self.setRuntimeMessageFmt("cannot add {s} and {s}", .{ revo.std_lib.dataToString(lhs), revo.std_lib.dataToString(rhs) });
            return error.IncompatibleTypes;
        },

        .sub => {
            const lhs = self.readRegisterFast(base, instr.b);
            const rhs = self.readRegisterFast(base, instr.c);
            const lnum = lhs.as_number() catch null;
            const rnum = rhs.as_number() catch null;
            if (lnum != null and rnum != null) {
                try self.writeRegisterFast(base, instr.a, Data.new.num(lnum.? - rnum.?));
                return;
            }
            if (try self.callBinaryMetamethodByAtom(lhs, rhs, revo.core_atoms.atom_id(.__sub))) |result| {
                try self.writeRegisterFast(base, instr.a, result);
                return;
            }
            try self.setRuntimeMessageFmt("cannot subtract {s} from {s}", .{ revo.std_lib.dataToString(rhs), revo.std_lib.dataToString(lhs) });
            return error.IncompatibleTypes;
        },

        .mul => {
            const lhs = self.readRegisterFast(base, instr.b);
            const rhs = self.readRegisterFast(base, instr.c);
            const lnum = lhs.as_number() catch null;
            const rnum = rhs.as_number() catch null;
            if (lnum != null and rnum != null) {
                try self.writeRegisterFast(base, instr.a, Data.new.num(lnum.? * rnum.?));
                return;
            }
            // String * number or number * string: repeat string
            if (lhs == .string and rnum != null) {
                const str = self.stringValue(lhs.string);
                const count: usize = @intCast(std.math.clamp(@as(i64, @intFromFloat(rnum.?)), 0, std.math.maxInt(i32)));
                const cap = std.math.mul(usize, str.len, count) catch return error.OutOfMemory;
                var buf = try std.ArrayList(u8).initCapacity(self.runtime.alloc, cap);
                errdefer buf.deinit(self.runtime.alloc);
                for (0..count) |_| {
                    try buf.appendSlice(self.runtime.alloc, str);
                }
                const result_str = try self.adoptDataString(try buf.toOwnedSlice(self.runtime.alloc));
                try self.writeRegisterFast(base, instr.a, result_str);
                return;
            }
            if (rhs == .string and lnum != null) {
                const str = self.stringValue(rhs.string);
                const count: usize = @intCast(std.math.clamp(@as(i64, @intFromFloat(lnum.?)), 0, std.math.maxInt(i32)));
                const cap = std.math.mul(usize, str.len, count) catch return error.OutOfMemory;
                var buf = try std.ArrayList(u8).initCapacity(self.runtime.alloc, cap);
                errdefer buf.deinit(self.runtime.alloc);
                for (0..count) |_| {
                    try buf.appendSlice(self.runtime.alloc, str);
                }
                const result_str = try self.adoptDataString(try buf.toOwnedSlice(self.runtime.alloc));
                try self.writeRegisterFast(base, instr.a, result_str);
                return;
            }
            if (try self.callBinaryMetamethodByAtom(lhs, rhs, revo.core_atoms.atom_id(.__mul))) |result| {
                try self.writeRegisterFast(base, instr.a, result);
                return;
            }
            try self.setRuntimeMessageFmt("cannot multiply {s} and {s}", .{ revo.std_lib.dataToString(lhs), revo.std_lib.dataToString(rhs) });
            return error.IncompatibleTypes;
        },

        .div => {
            const lhs = self.readRegisterFast(base, instr.b);
            const rhs = self.readRegisterFast(base, instr.c);
            const lnum = lhs.as_number() catch null;
            const rnum = rhs.as_number() catch null;
            if (lnum != null and rnum != null) {
                const rv = rnum.?;
                if (rv == 0) return error.DivisionByZero;
                try self.writeRegisterFast(base, instr.a, Data.new.num(lnum.? / rv));
                return;
            }
            if (try self.callBinaryMetamethodByAtom(lhs, rhs, revo.core_atoms.atom_id(.__div))) |result| {
                try self.writeRegisterFast(base, instr.a, result);
                return;
            }
            try self.setRuntimeMessageFmt("cannot divide {s} by {s}", .{ revo.std_lib.dataToString(lhs), revo.std_lib.dataToString(rhs) });
            return error.IncompatibleTypes;
        },

        .mod => {
            const lhs = self.readRegisterFast(base, instr.b);
            const rhs = self.readRegisterFast(base, instr.c);
            const lnum = lhs.as_number() catch null;
            const rnum = rhs.as_number() catch null;
            if (lnum != null and rnum != null) {
                const rv = rnum.?;
                if (rv == 0) return error.DivisionByZero;
                try self.writeRegisterFast(base, instr.a, Data.new.num(@mod(lnum.?, rv)));
                return;
            }
            if (try self.callBinaryMetamethodByAtom(lhs, rhs, revo.core_atoms.atom_id(.__mod))) |result| {
                try self.writeRegisterFast(base, instr.a, result);
                return;
            }
            try self.setRuntimeMessageFmt("cannot mod {s} by {s}", .{ revo.std_lib.dataToString(lhs), revo.std_lib.dataToString(rhs) });
            return error.IncompatibleTypes;
        },

        .negate => {
            const v = self.readRegisterFast(base, instr.b);
            if (v == .number) {
                try self.writeRegisterFast(base, instr.a, Data.new.num(-v.number));
                return;
            }
            try self.setRuntimeMessageFmt("cannot negate {s}", .{revo.std_lib.dataToString(v)});
            return error.IncompatibleTypes;
        },

        inline .eq, .neq, .lt, .gt, .lte, .gte => |op| try compare_impl.eval(self, instr, op),
        .@"and" => try self.writeRegisterFast(
            base,
            instr.a,
            Data.new.boolean(!revo.isFalse(self.readRegisterFast(base, instr.b)) and !revo.isFalse(self.readRegisterFast(base, instr.c))),
        ),

        .@"or" => try self.writeRegisterFast(
            base,
            instr.a,
            Data.new.boolean(!revo.isFalse(self.readRegisterFast(base, instr.b)) or !revo.isFalse(self.readRegisterFast(base, instr.c))),
        ),

        .not => try self.writeRegisterFast(base, instr.a, Data.new.boolean(revo.isFalse(self.readRegisterFast(base, instr.b)))),

        .table_new => {
            self.noteGCPressure(64);
            try self.writeRegisterFast(base, instr.a, .{ .table = try self.tables.create() });
        },
        .table_set => {
            self.perf.table_set_ops += 1;
            const table_value = try self.readRegister(instr.a);
            const t_id = switch (table_value) {
                .table => |id| id,
                else => return error.TypeError,
            };
            const t = try self.tables.get(t_id);
            try t.put(t_id, self, self.readRegisterFast(base, instr.b), self.readRegisterFast(base, instr.c));
        },
        .table_get => {
            self.perf.table_get_ops += 1;
            const object = try self.readRegister(instr.b);
            const key = self.readRegisterFast(base, instr.c);
            if (try self.resolveField(object, key)) |resolved| {
                try self.writeRegister(instr.a, resolved.value);
            } else try self.writeRegister(instr.a, revo.core_atoms.data(.undef));
        },
        .table_set_atom => {
            self.perf.table_set_ops += 1;
            const table_value = try self.readRegister(instr.a);
            const t_id = switch (table_value) {
                .table => |id| id,
                else => return error.TypeError,
            };
            const t = try self.tables.get(t_id);
            const key = Data.new.atom(instr.bx);
            try t.put(t_id, self, key, self.readRegisterFast(base, instr.c));
            try self.writeRegisterFast(base, instr.a, .{ .table = t_id });
        },
        .table_get_atom => {
            self.perf.table_get_ops += 1;
            const object = try self.readRegister(instr.b);
            const key = Data.new.atom(instr.bx);
            if (try self.resolveField(object, key)) |resolved| {
                try self.writeRegister(instr.a, resolved.value);
            } else try self.writeRegister(instr.a, revo.core_atoms.data(.undef));
        },
        .tuple_new => {
            const start = try self.absoluteRegisterIndex(instr.b);
            const count: usize = instr.bx;
            self.noteGCPressure(@sizeOf(root.tuple.Tuple) + @sizeOf(Data) * instr.bx);
            try self.writeRegister(
                instr.a,
                .{ .tuple = try self.tuples.create(
                    self.currentFiber().slots.items[start .. start + count],
                ) },
            );
        },
        .tuple_get => {
            const tuple_id = switch (try self.readRegister(instr.b)) {
                .tuple => |id| id,
                else => return error.TypeError,
            };
            const idx_val = self.readRegisterFast(base, instr.c);

            // happy path: small non-negative number index
            if (idx_val == .number and idx_val.number >= 0 and @floor(idx_val.number) == idx_val.number) {
                const idx: usize = @intFromFloat(idx_val.number);
                const t = try self.tuples.get(tuple_id);
                if (idx < t.items.len) {
                    try self.writeRegister(instr.a, t.items[idx]);
                    return;
                }
            }

            // slow path: existing hash-based lookup for atoms/etc
            const idx = revo.asIndex(idx_val.as_number() catch return error.TypeError) catch return error.TypeError;

            const t = try self.tuples.get(tuple_id);
            if (idx >= t.items.len) {
                try self.setRuntimeMessageFmt("tuple index {d} out of range for tuple of length {d}", .{ idx, t.items.len });
                return error.InvalidTuple;
            }
            try self.writeRegister(instr.a, t.items[idx]);
        },
        .tuple_get_const => {
            const tuple_id = switch (try self.readRegister(instr.b)) {
                .tuple => |id| id,
                else => return error.TypeError,
            };
            const t = try self.tuples.get(tuple_id);
            if (instr.bx >= t.items.len) {
                try self.setRuntimeMessageFmt("tuple index {d} out of range for tuple of length {d}", .{ instr.bx, t.items.len });
                return error.InvalidTuple;
            }
            try self.writeRegister(instr.a, t.items[instr.bx]);
        },
        .jump => self.currentFiber().pc = instr.bx,
        .jump_if_false => {
            if (revo.isFalse(self.readRegisterFast(base, instr.a))) self.currentFiber().pc = instr.bx;
        },
        .jump_if_true => {
            if (!revo.isFalse(self.readRegisterFast(base, instr.a))) self.currentFiber().pc = instr.bx;
        },
        .load_global => {
            const value = self.globals.get(instr.bx) orelse {
                try self.setRuntimeMessageFmt("undefined variable `{s}`", .{self.atomName(instr.bx)});
                return error.UndefinedVariable;
            };
            try self.writeRegisterFast(base, instr.a, value);
        },
        .store_global => {
            if (self.const_globals.contains(instr.bx)) {
                try self.setRuntimeMessage("reassignment to constant!");
                return error.ConstantReassignment;
            }
            try self.globals.put(instr.bx, try self.readRegister(instr.a));
        },
        .store_global_const => {
            if (self.const_globals.contains(instr.bx)) {
                try self.setRuntimeMessage("reassignment to constant!");
                return error.ConstantReassignment;
            }
            try self.globals.put(instr.bx, try self.readRegister(instr.a));
            try self.const_globals.put(instr.bx, {});
        },
        .load_local => try self.copyRegister(instr.a, instr.b),
        .bind_local => try self.copyRegister(instr.a, instr.b),
        .store_local => {
            if (try self.localIsConst(instr.a)) return error.ConstantReassignment;
            try self.copyRegister(instr.a, instr.b);
        },
        .closure => {
            self.noteGCPressure(48);
            const proto = try self.functions.getPrototype(instr.bx);
            var upvalues = try std.ArrayList(root.functions.UpvalueID).initCapacity(self.runtime.alloc, proto.upvalue_specs.len);
            defer upvalues.deinit(self.runtime.alloc);
            for (proto.upvalue_specs) |spec| {
                if (spec.is_local) {
                    const frame = try self.currentFrame();
                    try upvalues.append(self.runtime.alloc, try self.captureUpvalue(frame.base + spec.index));
                } else {
                    const closure = (try self.currentClosure()) orelse return error.TypeError;
                    try upvalues.append(self.runtime.alloc, closure.upvalues[spec.index]);
                }
            }
            try self.writeRegisterFast(base, instr.a, .{ .function = try self.functions.createClosure(instr.bx, upvalues.items) });
        },
        .load_upval => {
            const closure = (try self.currentClosure()) orelse return error.InvalidLocal;
            try self.writeRegisterFast(base, instr.a, try self.loadUpvalueData(closure.upvalues[instr.bx]));
        },
        .store_upval => {
            const closure = (try self.currentClosure()) orelse return error.InvalidLocal;
            try self.storeUpvalueData(closure.upvalues[instr.bx], self.readRegisterFast(base, instr.a));
        },
        .call => try self.callRegister(instr),
        .call_field => try self.callFieldRegister(instr),
        .ret => try self.returnRegister(instr),
        .spawn => try self.spawnRegister(instr),
        .join => {
            const handle = try self.readRegister(instr.a);
            const target_id = switch (handle) {
                .number => |n| if (n >= 0 and @floor(n) == n) @as(usize, @intFromFloat(n)) else return error.TypeError,
                else => return error.TypeError,
            };
            if (target_id >= self.sched.fibers.items.len) return error.TypeError;
            const target = &self.sched.fibers.items[target_id];
            if (target.state == .dead) {
                try self.writeRegister(instr.a, target.result);
            } else {
                try target.waiters.append(self.runtime.alloc, self.sched.current_fiber);
                self.sched.parkCurrentWithResult(
                    .{ .join = target_id },
                    try self.absoluteRegisterIndex(instr.a),
                );
            }
        },
        .yield => {
            self.sched.setFiberState(self.sched.current_fiber, .ready);
            self.currentFiber().running = false;
        },
        .halt => {
            const result = try self.readRegister(instr.a);
            self.currentFiber().slots.items.len = 0;
            try self.push(result);
            self.currentFiber().running = false;
            self.sched.setFiberState(self.sched.current_fiber, .dead);
        },
        .range_init => {
            const start = try self.readRegister(instr.b);
            const limit = try self.readRegister(instr.c);
            const step = try self.readRegister(@intCast(instr.bx));

            // state layout in consecutive registers starting at a:
            // R[a]   = current (start initially)
            // R[a+1] = step
            // R[a+2] = limit
            try self.writeRegister(instr.a, start);
            try self.writeRegister(instr.a + 1, step);
            try self.writeRegister(instr.a + 2, limit);
        },
        .range_next => {
            // loop state in consecutive registers starting at b:
            // R[b]   = current
            // R[b+1] = step
            // R[b+2] = limit
            const current = (try self.readRegister(instr.b)).as_number() catch return error.TypeError;
            const step = (try self.readRegister(instr.b + 1)).as_number() catch return error.TypeError;
            const limit = (try self.readRegister(instr.b + 2)).as_number() catch return error.TypeError;

            const has_next = (step > 0 and current < limit) or (step < 0 and current > limit);

            // out: r[a]=value, r[c]=index (if c!=0), r[bx]=has_next
            try self.writeRegister(instr.a, Data.new.num(current));

            if (instr.c != 0) {
                const index_reg = try self.readRegister(instr.c);
                const index = if (index_reg == .number) index_reg.number else 0.0;
                try self.writeRegister(instr.c, Data.new.num(index));
            }
            try self.writeRegister(@intCast(instr.bx), Data.new.boolean(has_next));

            // advance state if there is a next iteration
            if (has_next) {
                try self.writeRegister(instr.b, Data.new.num(current + step));
                if (instr.c != 0) {
                    const index_reg = try self.readRegister(instr.c);
                    const index = if (index_reg == .number) index_reg.number else 0.0;
                    try self.writeRegister(instr.c, Data.new.num(index + 1));
                }
            }
        },
        .range_for => {
            // R[a] = current (in/out)
            // R[b] = step
            // R[c] = limit
            // bx = max iterations
            var current = (try self.readRegister(instr.a)).as_number() catch return error.TypeError;
            const step = (try self.readRegister(instr.b)).as_number() catch return error.TypeError;
            const limit = (try self.readRegister(instr.c)).as_number() catch return error.TypeError;
            const max_iter: f64 = @floatFromInt(instr.bx);

            var i: f64 = 0;
            while (i < max_iter) {
                const done = (step > 0 and current > limit) or (step < 0 and current < limit);
                if (done) break;
                current += step;
                i += 1;
            }

            try self.writeRegister(instr.a, Data.new.num(current));
        },
        .unwrap_result => {
            const val = try self.readRegister(instr.a);
            const propagate_errors = instr.bx == 0;

            // if val is (:err, ...) is true, return early
            if (val != .tuple) return;

            const tuple = try self.tuples.get(val.tuple);
            if (tuple.items.len == 0) return;

            const tag = tuple.items[0];

            // branch (:err, e)
            if (tag == .atom and tag.atom == revo.core_atoms.atom_id(.err)) {
                if (propagate_errors) {
                    if (self.currentFiber().frames.items.len == 2) {
                        if (tuple.items.len > 1) {
                            var buf = std.Io.Writer.Allocating.init(self.runtime.alloc);
                            defer buf.deinit();
                            tuple.items[1].write(&buf.writer, self, .display) catch |err| switch (err) {
                                error.OutOfMemory => return error.OutOfMemory,
                                else => return error.Panic,
                            };
                            self.setPanicMessageOwned(try buf.toOwnedSlice());
                        }
                        self.panic_span = if (self.currentDebugInfo()) |debug|
                            self.spanAtPc(debug, if (self.currentFiber().pc > 0) self.currentFiber().pc - 1 else 0)
                        else
                            null;
                        return error.Panic;
                    }

                    try self.returnRegister(.{ .op = .ret, .a = instr.a });
                    return;
                }
                // otherwise just pass thru (don't unwrap unless propagating)
                return;
            }

            // check if (:ok, v) then extract
            if (tag == .atom and tag.atom == revo.core_atoms.atom_id(.ok)) {
                if (tuple.items.len > 1) {
                    try self.writeRegister(instr.a, tuple.items[1]);
                }
                return;
            }

            // otherwise just pass thru
        },
        .jump_if_not_nil_and_not_err => {
            const val = try self.readRegister(instr.a);
            const is_nil = if (val == .atom) val.atom == revo.core_atoms.atom_id(.nil) else false;
            const is_err = if (val == .tuple) blk: {
                const tuple = try self.tuples.get(val.tuple);
                if (tuple.items.len > 0) {
                    const tag = tuple.items[0];
                    break :blk tag == .atom and tag.atom == revo.core_atoms.atom_id(.err);
                }
                break :blk false;
            } else false;
            if (!is_nil and !is_err) {
                self.currentFiber().pc = instr.bx;
            }
        },
        .jump_if_err => {
            const val = try self.readRegister(instr.a);
            const is_err = if (val == .tuple) blk: {
                const tuple = try self.tuples.get(val.tuple);
                if (tuple.items.len > 0) {
                    const tag = tuple.items[0];
                    break :blk tag == .atom and tag.atom == revo.core_atoms.atom_id(.err);
                }
                break :blk false;
            } else false;
            if (is_err) {
                self.currentFiber().pc = instr.bx;
            }
        },
    }
}

pub const resolveField = lookup.resolveField;
pub const callField = lookup.callField;
pub const resolveIndex = lookup.resolveIndex;
pub const FieldLookup = lookup.FieldLookup;
pub const getMetatable = lookup.getMetatable;
pub const getMetamethod = lookup.getMetamethod;
pub const setMetatable = lookup.setMetatable;
pub const setTableMetatable = lookup.setTableMetatable;
pub const setStructInstanceTable = lookup.setStructInstanceTable;
pub const runModule = module.runModule;
pub const metamethodTruthy = lookup.metamethodTruthy;

// gc
pub fn markData(self: *VM, data: Data) void {
    switch (data) {
        .string => |id| self.strings.mark(id),
        .table => |id| self.tables.mark(id, self),
        .tuple => |id| self.tuples.mark(id, self),
        .function => |id| self.functions.mark(id, self),
        else => {},
    }
}
fn markRoots(self: *VM) void {
    for (self.sched.fibers.items) |fiber| {
        for (fiber.slots.items) |data| self.markData(data);
        for (fiber.frames.items) |frame| {
            if (frame.closure_id) |id| self.functions.mark(id, self);
        }
        for (fiber.open_upvalues.items) |entry| self.functions.markUpvalue(entry.id, self);
    }

    var globals_it = self.globals.iterator();
    while (globals_it.next()) |global| self.markData(global.value_ptr.*);

    for (self.constants.items) |data| self.markData(data);

    var atom_it = self.atoms.iterator();
    while (atom_it.next()) |entry| {
        self.strings.mark(entry.value_ptr.*);
        if (self.strings.lookup(entry.key_ptr.*)) |alias_id| self.strings.mark(alias_id);
    }

    // important: pin all core atoms for VM lifetime
    inline for (@typeInfo(revo.core_atoms).@"enum".fields) |field| {
        const atom_id: revo.AtomID = @intFromEnum(@field(revo.core_atoms, field.name));
        self.strings.mark(atom_id);
    }

    var bootstrap_it = self.bootstrap_globals.iterator();
    while (bootstrap_it.next()) |global| self.markData(global.value_ptr.*);

    var cache_it = self.module_cache.iterator();
    while (cache_it.next()) |v| self.markData(v.value_ptr.*);

    var channel_it = self.sched.channels.iterator();
    while (channel_it.next()) |entry| {
        self.tables.mark(entry.key_ptr.*, self);
        const channel = entry.value_ptr;
        for (channel.queue.items[channel.queue_head..]) |value| self.markData(value);
        for (channel.send_waiters.items[channel.send_head..]) |waiter| {
            if (waiter.value) |v| self.markData(v);
        }
    }

    for (self.metatables) |mt|
        if (mt) |id| self.tables.mark(id, self);
}

test "is_false truthiness contract" {
    const test_rt = revo.lang.testing;
    var vm = try revo.VM.init(test_rt.runtime());
    defer vm.deinit();
    try std.testing.expect(revo.isFalse(Data.new.nil()));
    try std.testing.expect(revo.isFalse(Data.new.num(0)));
    try std.testing.expect(revo.isFalse(Data.new.num(0.0)));
    try std.testing.expect(!revo.isFalse(Data.new.num(2)));
}

test "set_metatable on number applies to all number values" {
    var vm = try VM.init(testing.runtime());
    defer vm.deinit();

    const mt_id = try vm.tables.create();
    try vm.setMetatable(Data.new.num(0), mt_id);

    const mt = try vm.getMetatableId(Data.new.num(1.5));
    try std.testing.expect(mt != null);
    try std.testing.expectEqual(mt_id, mt.?);
}

test "callFunction unwinds frames on native error" {
    const fail_native = struct {
        fn call(_: []const Data, _: *VM) anyerror!revo.std_lib.NativeResult {
            return error.Panic;
        }
    }.call;

    var vm = try VM.init(testing.runtime());
    defer vm.deinit();

    const fn_id = try vm.functions.create(.{ .native = revo.std_lib.define(&[_]revo.std_lib.TypeSpec{}, fail_native) });
    const start_frames = vm.currentFiber().frames.items.len;
    const start_slots = vm.currentFiber().slots.items.len;

    try std.testing.expectError(error.Panic, vm.callFunction(.{ .function = fn_id }, &.{}));
    try std.testing.expectEqual(start_frames, vm.currentFiber().frames.items.len);
    try std.testing.expectEqual(start_slots, vm.currentFiber().slots.items.len);
}

const lang = revo.lang;
const Span = lang.Span;
pub const EvalErrorKind = root.debug.EvalErrorKind;
pub const EvalFailure = root.debug.EvalFailure;
pub const EvalResult = root.debug.EvalResult;
const Frame = root.functions.Frame;
const FunctionPool = root.functions.FunctionPool;
pub const lookup = root.lookup;
const compare_impl = @import("compare.zig");

pub const memory = root.memory;
const mem = memory;
const Data = mem.Data;
pub const module = root.module;
pub const opcode = root.opcode;
const Instruction = opcode.Instruction;
pub const Interner = root.interner.Interner;
const TablePool = root.table.TablePool;
pub const testing = root.testing;
const TuplePool = root.tuple.TuplePool;
test {
    _ = @import("debug.zig");
    _ = @import("functions.zig");
    _ = @import("interner.zig");
    _ = @import("lookup.zig");
    _ = @import("memory.zig");
    _ = @import("module.zig");
    _ = @import("opcode.zig");
    _ = @import("table.zig");
    _ = @import("testing.zig");
    _ = @import("tests.zig");
    _ = @import("tuple.zig");
}
