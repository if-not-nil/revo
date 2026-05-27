pub const MAX_FRAMES = 256;
pub const ProgramCounter = usize;
pub const ConstantID = usize;

pub const DebugOptions = struct {
    trace: bool = false,
    dump: bool = false,
    each_instr: bool = false,
    each_stack: bool = false,
};

pub const VM = @This();

pub const Globals = std.AutoHashMap(GlobalID, Data);
pub const ConstGlobals = std.AutoHashMap(GlobalID, void);

pub const ModuleStamp = struct {
    mtime: u64,
    size: usize,
};

pub const ModuleCache = std.StringHashMap(struct {
    result: Data,
    stamp: ModuleStamp,
});

pub const FiberID = usize;
pub const DebugInfoID = usize;

pub const DebugInfo = struct {
    spans: []Span,
    source: []const u8,
    source_name: []const u8,
};

// direct-mapped inline cache for table lookups
// compare pc/table_id/version then use val
pub const ICacheEntry = struct {
    pc: ProgramCounter,
    table_id: mem.TableID,
    version: usize,
    value: Data,
};

// main loop: run runnable fibers, wake sleepers
// wait for io/timers if needed
pub fn runReport(self: *VM) !EvalResult {
    return vm_exec.runReport(self);
}

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
    // will be set to no_result in init
    result: Data = Data.new.nil(),
    // error channel maybe
    err_atom: ?mem.AtomID = null,
    waiters: std.ArrayList(FiberID),

    pub fn init(alloc: std.mem.Allocator, id: FiberID, program: []const Instruction) !Fiber {
        return .{
            .id = id,
            .pc = 0,
            .program = program,
            .debug_info_id = null,
            .slots = try std.ArrayList(Data).initCapacity(alloc, 256),
            .frames = try std.ArrayList(Frame).initCapacity(alloc, MAX_FRAMES),
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
        waiting, // blocked on io or event
        dead, // finished, success or fail
    };
};

// concurrency
sched: Scheduler,
runtime: revo.Runtime,

// TODO: move all pools and sets into one big struct
// remove useless fns like intern_atom
constants: std.ArrayList(Data),
stdlib_globals: Globals,
tables: TablePool,
tuples: TuplePool,
functions: FunctionPool,
struct_types: struct_mod.StructTypePool,
struct_instances: struct_mod.StructInstancePool,
modules: revo.module.NamespacePool,
strings: Interner,
atoms: std.StringHashMap(mem.AtomID),
debug: DebugOptions = .{},
globals: Globals,
const_globals: ConstGlobals,
module_dir: ?[]const u8,
loading_stack: std.ArrayList([]const u8),

/// matches type enum order
metatables: [
    @typeInfo(memory.Type).@"enum".fields.len
]?mem.TableID = .{null} ** @typeInfo(memory.Type).@"enum".fields.len,
module_cache: ModuleCache,
package_path: std.ArrayList([]const u8),
debug_infos: std.ArrayList(DebugInfo),
pending_debug_info_id: ?DebugInfoID = null,
panic_message: ?[]const u8 = null,
panic_span: ?Span = null,
runtime_message: ?[]const u8 = null,
gc_instr_counter: usize = 0,
host_call_depth: usize = 0,
loaded_extensions: std.ArrayList(std.DynLib),
gc_enabled: bool = true,
gc_pending: bool = false,
gc_bytes_allocated: usize = 0,

// optional opcode counters for benchmarking/profiling
// allocated on init
gc_threshold: usize = 512 * 1024, // 512kb initial
gc_pause_factor: usize = 2,
// 64kb nursery
gc_nursery_threshold: usize = 64 * 1024,
debug_assert_types: bool = false,

/// for table lookups
icache: [32]ICacheEntry = undefined,

// gc work state for incremental
gc_mark_stack: std.ArrayList(MarkItem),
gc_sweep_state: struct {
    phase: enum {
        idle,
        tables,
        tuples,
        functions,
        upvalues,
        structs,
        modules,
        strings,
        done,
    } = .idle,
    cursor: usize = 0,
},

const MarkItem = union(enum) {
    data: Data,
    table: mem.TableID,
    tuple: mem.TupleID,
    function: mem.FunctionID,
    upvalue: root.functions.UpvalueID,
    struct_instance: struct_mod.StructInstanceID,
    module: mem.NamespaceID,
};

pub fn init(runtime: revo.Runtime) !VM {
    var vm: VM = .{
        .runtime = runtime,
        .sched = try Scheduler.init(runtime.alloc),
        .constants = try std.ArrayList(Data).initCapacity(runtime.alloc, 16),
        .stdlib_globals = Globals.init(runtime.alloc),
        .tables = try TablePool.init(runtime.alloc),
        .tuples = try TuplePool.init(runtime.alloc),
        .functions = try FunctionPool.init(runtime.alloc),
        .struct_types = struct_mod.StructTypePool.init(runtime.alloc),
        .struct_instances = try struct_mod.StructInstancePool.init(runtime.alloc),
        .modules = try revo.module.NamespacePool.init(runtime.alloc),
        .strings = try Interner.init(runtime.alloc),
        .atoms = std.StringHashMap(mem.AtomID).init(runtime.alloc),
        .module_cache = ModuleCache.init(runtime.alloc),
        .package_path = try std.ArrayList([]const u8).initCapacity(runtime.alloc, 4),
        .debug_infos = try std.ArrayList(DebugInfo).initCapacity(runtime.alloc, 8),
        .globals = Globals.init(runtime.alloc),
        .const_globals = ConstGlobals.init(runtime.alloc),
        .module_dir = null,
        .loading_stack = try std.ArrayList([]const u8).initCapacity(runtime.alloc, 1),
        .loaded_extensions = try .initCapacity(runtime.alloc, 0),
        .gc_mark_stack = try std.ArrayList(MarkItem).initCapacity(runtime.alloc, 256),
        .gc_sweep_state = .{},
    };
    try revo.async_backend_impl.init(&vm.runtime.async_backend);
    errdefer revo.async_backend_impl.deinit(&vm.runtime.async_backend);

    // init icache with max pc to force miss
    for (&vm.icache) |*entry| {
        entry.* = .{
            .pc = std.math.maxInt(ProgramCounter),
            .table_id = 0,
            .version = 0,
            .value = undefined,
        };
    }

    try vm.package_path.appendSlice(runtime.alloc, &.{ "./?", "./lib/?", "/usr/local/lib/revo/?" });

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

    // set initial fiber result to no_result
    // after core atoms are initialized
    vm.sched.fibers.items[0].result = revo.core_atoms.data(.no_result);

    try revo.std_lib.register_stdlib(&vm);
    try revo.lang.proc.register(&vm);

    return vm;
}

/// TODO: use @sizeOf everywhere at callsite because this is all over the place
pub inline fn noteGCPressure(self: *VM, bytes: usize) void {
    vm_gc.noteGCPressure(self, bytes);
}

pub fn maybeCollectGarbage(self: *VM) void {
    vm_gc.maybeCollectGarbage(self);
}

fn doIncrementalSweep(self: *VM) void {
    vm_gc.doIncrementalSweep(self);
}

fn processMarkStack(self: *VM) void {
    vm_gc.processMarkStack(self);
}

inline fn markRoots(self: *VM) void {
    vm_gc.markRoots(self);
}

inline fn pushMark(self: *VM, data: Data) void {
    vm_gc.pushMark(self, data);
}

//
// probably shouldnt be here but its fine
//
pub inline fn pushMarkTable(self: *VM, id: mem.TableID) void {
    vm_gc.pushMarkTable(self, id);
}

pub inline fn pushMarkTuple(self: *VM, id: mem.TupleID) void {
    vm_gc.pushMarkTuple(self, id);
}

pub inline fn pushMarkFunction(self: *VM, id: mem.FunctionID) void {
    vm_gc.pushMarkFunction(self, id);
}

pub inline fn pushMarkUpvalue(self: *VM, id: root.functions.UpvalueID) void {
    vm_gc.pushMarkUpvalue(self, id);
}

pub inline fn pushMarkStructInstance(self: *VM, id: struct_mod.StructInstanceID) void {
    vm_gc.pushMarkStructInstance(self, id);
}

pub inline fn pushMarkNamespace(self: *VM, id: mem.NamespaceID) void {
    vm_gc.pushMarkNamespace(self, id);
}

inline fn markDataImpl(self: *VM, data: Data) void {
    vm_gc.markDataImpl(self, data);
}

pub fn deinit(self: *VM) void {
    self.clearProgramDebugInfo();
    self.clearPanicMessage();
    self.clearRuntimeMessage();
    revo.async_backend_impl.deinit(&self.runtime.async_backend);
    self.sched.deinit();
    self.constants.deinit(self.runtime.alloc);
    self.globals.deinit();
    self.const_globals.deinit();
    self.stdlib_globals.deinit();

    for (self.loading_stack.items) |path|
        self.runtime.alloc.free(path);
    self.loading_stack.deinit(self.runtime.alloc);

    self.tables.deinit();
    self.tuples.deinit();
    self.functions.deinit();
    self.struct_types.deinit();
    self.struct_instances.deinit();
    self.modules.deinit();
    self.strings.deinit();
    self.atoms.deinit();

    for (self.debug_infos.items) |info| {
        self.runtime.alloc.free(info.spans);
        self.runtime.alloc.free(info.source);
        self.runtime.alloc.free(info.source_name);
    }
    self.debug_infos.deinit(self.runtime.alloc);
    self.package_path.deinit(self.runtime.alloc);

    var cache_it = self.module_cache.keyIterator();
    while (cache_it.next()) |key|
        self.runtime.alloc.free(key.*);

    self.module_cache.deinit();

    for (self.loaded_extensions.items) |*lib| {
        if (builtin.target.os.tag != .windows)
            lib.close();
    }
    self.loaded_extensions.deinit(self.runtime.alloc);
    self.gc_mark_stack.deinit(self.runtime.alloc);
}

pub fn moduleStamp(self: *VM, path: []const u8) !ModuleStamp {
    const stat = std.Io.Dir.cwd().statFile(self.runtime.io, path, .{}) catch |err| {
        return err;
    };
    return .{
        .mtime = @intCast(stat.mtime.toNanoseconds()),
        .size = stat.size,
    };
}

pub fn invalidateModuleCache(self: *VM, path: []const u8) bool {
    if (self.module_cache.fetchRemove(path)) |entry| {
        self.runtime.alloc.free(entry.key);
        return true;
    }
    return false;
}

pub fn clearModuleCache(self: *VM) void {
    var it = self.module_cache.iterator();
    while (it.next()) |entry| self.runtime.alloc.free(entry.key_ptr.*);
    self.module_cache.clearRetainingCapacity();
}

pub fn createNamespace(self: *VM, path: []const u8, exports_table: mem.TableID) !Data {
    const id = try self.modules.create(path, exports_table);
    return Data.new.module(id);
}

pub fn moduleExportsTable(self: *VM, value: Data) !mem.TableID {
    if (value.asTable()) |table_id| return table_id;
    const ns_id = value.asNamespace() orelse return error.TypeError;
    const ns = self.modules.get(ns_id) catch return error.TypeError;
    return ns.exports;
}

pub fn modulePath(self: *VM, value: Data) ![]const u8 {
    const ns_id = value.asNamespace() orelse return error.TypeError;
    const ns = self.modules.get(ns_id) catch return error.TypeError;
    return ns.path;
}

pub fn setNamespaceExports(self: *VM, ns_id: mem.NamespaceID, exports_table: mem.TableID) !void {
    const ns = self.modules.get(ns_id) catch return;
    ns.exports = exports_table;
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

pub fn adoptDataStringNoDedup(self: *VM, value: []u8) !Data {
    return Data.new.str(try self.strings.adoptNoDedup(value));
}

pub fn ownDataStringNoDedup(self: *VM, value: []const u8) !Data {
    return Data.new.str(try self.strings.ownNoDedup(value));
}

pub fn stringValue(self: *VM, id: mem.StringID) []const u8 {
    return self.strings.get(id) catch "<dead>";
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

pub inline fn mainResult(self: *VM) Data {
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
    try self.sched.parkCurrentForSleepMS(ms, self.schedNowMonotonicNs());
}

pub inline fn schedNowMonotonicNs(self: *VM) u64 {
    const ts = std.Io.Clock.awake.now(self.runtime.io);
    return @as(u64, @intCast(ts.toNanoseconds()));
}

inline fn runReadyFibers(self: *VM) !?EvalFailure {
    return vm_exec.runReadyFibers(self);
}

//
// slot helpers
//
pub fn pop(self: *VM) !Data {
    const fiber = self.currentFiber();
    if (fiber.slots.items.len == 0) return error.StackUnderflow;

    const ret = fiber.slots.pop() orelse unreachable;
    // if (self.debug.each_stack) self.printStack();
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
    if (slot >= self.currentFiber().slots.items.len)
        return revo.core_atoms.data(.missing);

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

/// register read using a cached slots pointer (avoids currentFiber call)
pub inline fn regRead(slots: []const Data, base: usize, reg: opcode.Register) Data {
    if (builtin.mode != .ReleaseFast) {
        const slot = base + reg;
        if (slot >= slots.len)
            return revo.core_atoms.data(.missing);
    }
    return slots[base + reg];
}

pub inline fn regReadUnchecked(slots: []const Data, base: usize, reg: opcode.Register) Data {
    return slots[base + reg];
}

/// register write using a cached slots pointer (avoids currentFiber call)
/// caller must ensure slot < slots.len
pub inline fn regWrite(slots: []Data, base: usize, reg: opcode.Register, value: Data) void {
    slots[base + reg] = value;
}

/// avoid recomputing currentFrame() repeatedly
/// callers should cache `base = frame.base`
pub inline fn writeRegisterFast(self: *VM, base: usize, reg: opcode.Register, value: Data) !void {
    const slot = base + reg;
    self.writeRegisterUnsafe(slot, value);
}

pub fn internAtom(self: *VM, name: []const u8) !mem.AtomID {
    if (self.atoms.get(name)) |id| return id;
    const id = try self.strings.own(name);
    const owned = self.strings.getAssumeAlive(id);
    try self.atoms.put(owned, id);
    return id;
}

pub inline fn atomName(self: *VM, id: mem.AtomID) []const u8 {
    return self.strings.get(id) catch "<dead>";
}

pub fn dataAtom(self: *VM, name: []const u8) !Data {
    if (self.atoms.get(name)) |id| return Data.new.atom(id);
    const id = try self.strings.own(name);
    const owned = self.strings.getAssumeAlive(id);
    try self.atoms.put(owned, id);
    return Data.new.atom(id);
}

pub fn setGlobal(self: *VM, name: []const u8, val: Data) !void {
    const id = try self.internAtom(name);
    try self.globals.put(id, val);
}

pub fn seedBootstrapGlobals(self: *VM, target: *Globals) !void {
    var it = self.stdlib_globals.iterator();
    while (it.next()) |entry| {
        try target.put(entry.key_ptr.*, entry.value_ptr.*);
    }
}

pub fn getGlobal(self: *VM, name: []const u8) ?Data {
    if (self.atoms.get(name)) |id| return self.globals.get(id);
    return revo.core_atoms.data(.undef);
}

pub fn setProgramDebugInfo(
    self: *VM,
    spans: []const Span,
    source: []const u8,
    source_name: []const u8,
) !void {
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

inline fn currentClosure(self: *VM) !?*root.functions.Closure {
    const frame = try self.currentFrame();
    const closure_id = frame.closure_id orelse return null;
    const func = try self.functionFast(closure_id);
    return switch (func.*) {
        .closure => |*closure| closure,
        .native, .c_function => null,
    };
}

inline fn captureUpvalue(self: *VM, slot_index: usize) !root.functions.UpvalueID {
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
            upvalue.open_index = null;
        }
        _ = open.pop();
    }
}

inline fn loadUpvalueData(self: *VM, upvalue_id: root.functions.UpvalueID) !Data {
    const upvalue = try self.functions.getUpvalue(upvalue_id);
    if (upvalue.open_index) |slot_index| return self.currentFiber().slots.items[slot_index];
    return upvalue.closed;
}

inline fn storeUpvalueData(self: *VM, upvalue_id: root.functions.UpvalueID, value: Data) !void {
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

    var detached = try std.ArrayList(root.functions.UpvalueID).initCapacity(
        self.runtime.alloc,
        closure.upvalues.len,
    );
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
    return vm_exec.fetch(self);
}

fn trace(self: *VM, instr: Instruction) void {
    vm_exec.trace(self, instr);
}

fn dumpStack(self: *VM) void {
    vm_exec.dumpStack(self);
}

pub fn run(self: *VM) !void {
    return switch (try self.runReport()) {
        .ok => {},
        .err => return error.RuntimeFailure,
    };
}

fn callFunctionParts(self: *VM, callee: Data, maybe_first: ?Data, args: []const Data) EvalError!Data {
    self.host_call_depth += 1;
    defer self.host_call_depth -= 1;

    const fiber = self.currentFiber();
    const initial_frame_depth = fiber.frames.items.len;
    const initial_pc = fiber.pc;
    const initial_slot_len = fiber.slots.items.len;

    if (fiber.frames.items.len == 0) {
        if (fiber.debug_info_id == null)
            fiber.debug_info_id = self.pending_debug_info_id;

        try fiber.frames.append(
            self.runtime.alloc,
            .{ .return_addr = @intCast(fiber.program.len), .base = 0 },
        );
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
    if (call_reg_usize > std.math.maxInt(opcode.Register))
        return error.InvalidBytecode;
    const call_reg: opcode.Register = @intCast(call_reg_usize);

    const argc_usize: usize = args.len + @intFromBool(maybe_first != null);

    const argc: opcode.Register = @intCast(argc_usize);

    try self.callRegister(.{ .op = .call, .a = call_reg, .b = argc, .c = call_reg });

    if (fiber.frames.items.len > caller_frame_depth) {
        while (fiber.frames.items.len > caller_frame_depth) {
            const instr = try self.fetch();
            try self.evalRegister(instr);
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
    const current_pc = if (self.currentFiber().pc > 0)
        self.currentFiber().pc - 1
    else
        0;

    const frames = self.currentFiber().frames.items;

    var primary_span = if (info) |debug| self.spanAtPc(debug, current_pc) else null;

    // struct ctor panics originate in generated wrapper code; prefer the user callsite
    if (kind == .Panic and self.panic_message != null) {
        if (self.panic_span) |span| primary_span = span;

        const msg = self.panic_message.?;
        const is_struct_panic =
            std.mem.indexOf(u8, msg, " for struct `") != null or
            (std.mem.indexOf(u8, msg, " on `") != null and
                std.mem.indexOf(u8, msg, " expected ") != null);

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
            primary_span = self.spanAtPc(
                info orelse unreachable,
                frames[frames.len - 1].call_site_pc orelse unreachable,
            );
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
        .source_name = if (info) |debug|
            debug.source_name
        else
            null,
    };

    var out_idx: usize = 0;
    var i = frames.len;
    while (i > 0 and
        out_idx < EvalFailure.max_trace_frames)
    {
        i -= 1;
        const frame = frames[i];
        if (frame.closure_id == null) continue;
        failure.trace[out_idx] = .{
            .function_name = self.frameName(
                frame.closure_id,
            ),
            .source_name = if (info) |debug|
                debug.source_name
            else
                null,
            .source = if (info) |debug|
                debug.source
            else
                null,
            .span = if (info) |debug|
                if (i == frames.len - 1)
                    self.spanAtPc(debug, current_pc)
                else if (frame.call_site_pc) |pc|
                    self.spanAtPc(debug, pc)
                else
                    null
            else
                null,
            .pc = if (i == frames.len - 1)
                current_pc
            else
                frame.call_site_pc,
        };
        out_idx += 1;
    }
    failure.trace_len = out_idx;
    return failure;
}

pub fn getMetamethodByAtom(
    self: *VM,
    val: Data,
    atom: mem.AtomID,
) !?Data {
    const mt_id = try self.getMetatableId(val) orelse return null;
    const mt = try self.tables.get(mt_id);
    return mt.getRaw(Data.new.atom(atom));
}

pub fn getMetatableId(
    self: *VM,
    val: Data,
) !?mem.TableID {
    return switch (val.tag()) {
        .table => blk: {
            const id = val.asTable().?;
            if (self.tables.get(id)) |value| {
                if (value.metatable) |mt_id|
                    break :blk mt_id;
            } else |_| {}
            break :blk self.metatables[
                @intFromEnum(
                    mem.Type.table,
                )
            ];
        },
        .tuple => blk: {
            const id = val.asTuple().?;
            if (self.tuples.get(id)) |value| {
                if (value.metatable) |mt_id|
                    break :blk mt_id;
            } else |_| {}
            break :blk self.metatables[
                @intFromEnum(
                    mem.Type.tuple,
                )
            ];
        },
        else => |e| self.metatables[@intFromEnum(e)],
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
    ConstantReassignment,
} || root.functions.NativeError;

inline fn tableFast(
    self: *VM,
    id: mem.TableID,
) !*root.table.Table {
    if (builtin.mode == .ReleaseFast) {
        std.debug.assert(id < self.tables.tables.items.len);
        std.debug.assert(
            self.tables.tables.items[id] != null,
        );
        return &self.tables.tables.items[id].?;
    }
    return self.tables.get(id);
}

inline fn functionFast(
    self: *VM,
    id: mem.FunctionID,
) !*root.functions.Function {
    if (builtin.mode == .ReleaseFast) {
        std.debug.assert(
            id < self.functions.functions.items.len,
        );
        std.debug.assert(
            self.functions.functions.items[id] != null,
        );
        return &self.functions.functions.items[id].?;
    }
    return self.functions.get(id);
}

fn callNonClosureFunction(
    self: *VM,
    func: root.functions.Function,
    instr: Instruction,
    base: usize,
    callee_slot: usize,
    argc: usize,
) EvalError!void {
    const fiber = self.currentFiber();
    switch (func) {
        .c_function => |f| {
            const args_start = callee_slot + 1;
            const args_end = args_start + argc;
            try self.ensureAbsoluteSlot(args_end);
            const args = fiber.slots.items[args_start..args_end];

            var c_args = try self.runtime.alloc.alloc(
                revo.ffi.CRevoData,
                args.len,
            );
            defer self.runtime.alloc.free(c_args);

            var string_copies = try std.ArrayList(
                [:0]u8,
            ).initCapacity(
                self.runtime.alloc,
                argc,
            );
            defer {
                for (string_copies.items) |copy|
                    self.runtime.alloc.free(copy);
                string_copies.deinit(self.runtime.alloc);
            }

            for (args, 0..) |arg, i|
                c_args[i] = try revo.ffi.CRevoData.ofData(
                    arg,
                    self.runtime.alloc,
                    &self.strings,
                    &string_copies,
                );

            var c_result: revo.ffi.CRevoData = .{
                .tag = 0,
                .value = 0,
            };
            f.fn_ptr(
                @ptrCast(self),
                argc,
                c_args.ptr,
                &c_result,
            );
            try self.ensureAbsoluteSlot(base + instr.c);
            try self.writeRegisterFast(
                base,
                instr.c,
                try c_result.toData(self),
            );
        },
        .native => |f| {
            const args_start = callee_slot + 1;
            const args_end = args_start + argc;
            try self.ensureAbsoluteSlot(args_end);
            const args = fiber.slots.items[args_start..args_end];

            if ((!f.variadic and argc != f.arity) or
                (f.variadic and argc < f.arity))
            {
                var params = try std.ArrayList(u8).initCapacity(
                    self.runtime.alloc,
                    8,
                );
                for (f.param_types, 0..) |t, i| {
                    if (i > 0)
                        try params.appendSlice(
                            self.runtime.alloc,
                            ", ",
                        );
                    try params.appendSlice(
                        self.runtime.alloc,
                        @tagName(t),
                    );
                }
                const params_str = try params.toOwnedSlice(
                    self.runtime.alloc,
                );
                defer self.runtime.alloc.free(params_str);
                try self.setRuntimeMessageFmt(
                    "function `{s}` expected {d} args({s}), got {d}",
                    .{
                        func.name(),
                        f.arity,
                        params_str,
                        argc,
                    },
                );
                return error.WrongArity;
            }

            for (f.param_types, 0..) |spec, i| {
                if (!spec.matches(args[i])) {
                    try self.setRuntimeMessageFmt(
                        "argument {d}: expected {s}, got {s}",
                        .{
                            i,
                            @tagName(spec),
                            revo.std_lib.dataToString(args[i]),
                        },
                    );
                    return error.TypeError;
                }
            }

            const result = f.func(args, self) catch |err| {
                if (self.runtime_message == null) {
                    try self.setRuntimeMessage(
                        @errorName(err),
                    );
                }
                return error.Panic;
            };

            switch (result) {
                .ok => |data| {
                    try self.ensureAbsoluteSlot(base + instr.c);
                    try self.writeRegisterFast(base, instr.c, data);
                },
                .err => |err| {
                    switch (err) {
                        .wrong_arity => |info| {
                            try self.setRuntimeMessageFmt(
                                "function `{s}` expected {d} args, got {d}",
                                .{
                                    func.name(),
                                    info.expected,
                                    info.got,
                                },
                            );
                            return error.WrongArity;
                        },
                        .type_error => |info| {
                            if (info.arg) |arg| {
                                try self.setRuntimeMessageFmt(
                                    "argument {d}: expected {s}, got {s}",
                                    .{
                                        arg,
                                        info.expected,
                                        info.got,
                                    },
                                );
                            } else {
                                try self.setRuntimeMessageFmt(
                                    "expected {s}, got {s}",
                                    .{
                                        info.expected,
                                        info.got,
                                    },
                                );
                            }
                            return error.TypeError;
                        },
                        .native_error => |native_err| return native_err,
                        .parked => {
                            self.currentFiber().parked_result_slot = try self.absoluteRegisterIndex(
                                instr.c,
                            );
                            try self.ensureAbsoluteSlot(base + instr.c);
                            try self.writeRegisterFast(
                                base,
                                instr.c,
                                revo.core_atoms.data(.missing),
                            );
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
        .closure => unreachable,
    }
}

fn callRegister(
    self: *VM,
    instr: Instruction,
) EvalError!void {
    // self.perf.call_ops += 1;
    const fiber = self.currentFiber();
    const frame = try self.currentFrame();
    const base = frame.base;
    const callee_slot = base + instr.a;
    const argc: usize = instr.b;

    const callee = if (callee_slot < fiber.slots.items.len)
        fiber.slots.items[callee_slot]
    else
        revo.core_atoms.data(.missing);

    // seemingly the likeliest for both rec and non-rec
    if (callee.tag() == .function) {
        @branchHint(.likely);
        const closure_id = callee.asFunction().?;
        const func = try self.functionFast(closure_id);
        return switch (func.*) {
            .closure => |closure| {
                if (closure.arity !=
                    root.functions.VARIADIC and
                    closure.arity != argc)
                {
                    @branchHint(.unlikely);
                    try self.setRuntimeMessageFmt(
                        "function `{s}` expected {d} args, got {d}",
                        .{
                            closure.name,
                            closure.arity,
                            argc,
                        },
                    );
                    return error.WrongArity;
                }

                if (self.host_call_depth == 0 and
                    fiber.pc < fiber.program.len and
                    fiber.program[fiber.pc].op == .ret)
                {
                    @branchHint(.unlikely);
                    const tail_frame = try self.currentFrame();
                    if (tail_frame.closure_id != null and
                        tail_frame.base > 0)
                    {
                        const caller_fn_slot =
                            tail_frame.base - 1;
                        const moved_len = argc + 1;

                        try self.closeUpvalues(
                            tail_frame.base,
                        );

                        if (callee_slot != caller_fn_slot) {
                            std.mem.copyForwards(
                                Data,
                                fiber.slots.items[caller_fn_slot .. caller_fn_slot + moved_len],
                                fiber.slots.items[callee_slot .. callee_slot + moved_len],
                            );
                        }

                        tail_frame.base = caller_fn_slot + 1;
                        tail_frame.call_site_pc = fiber.pc - 1;
                        tail_frame.closure_id = closure_id;
                        tail_frame.register_count = closure.register_count;

                        if (tail_frame.base +
                            closure.register_count >
                            fiber.slots.items.len)
                        {
                            try fiber.slots.resize(
                                self.runtime.alloc,
                                tail_frame.base +
                                    closure.register_count,
                            );
                        }
                        if (argc < closure.register_count) {
                            @memset(
                                fiber.slots.items[tail_frame.base + argc .. tail_frame.base + closure.register_count],
                                revo.core_atoms.data(.missing),
                            );
                        }

                        fiber.pc = closure.addr;
                        return;
                    }
                }

                const new_base = callee_slot + 1;
                if (new_base + closure.register_count >
                    fiber.slots.items.len)
                {
                    try fiber.slots.resize(
                        self.runtime.alloc,
                        new_base + closure.register_count,
                    );
                }
                if (argc < closure.register_count) {
                    @memset(
                        fiber.slots.items[new_base + argc .. new_base + closure.register_count],
                        revo.core_atoms.data(.missing),
                    );
                }

                try fiber.frames.append(
                    self.runtime.alloc,
                    .{
                        .return_addr = fiber.pc,
                        .call_site_pc = fiber.pc - 1,
                        .base = new_base,
                        .result_register = instr.c,
                        .register_count = closure.register_count,
                        .closure_id = closure_id,
                    },
                );
                fiber.pc = closure.addr;
            },
            else => self.callNonClosureFunction(
                func.*,
                instr,
                base,
                callee_slot,
                argc,
            ),
        };
    }

    // try __call mm on non-fn callees
    if (callee.asTable()) |_| {
        @branchHint(.unlikely);
        // branch check explicit __call mm
        if (try self.getMetamethodByAtom(
            callee,
            revo.core_atoms.atom_id(.__call),
        )) |mm| {
            // self.perf.metamethod_calls += 1;
            const args_start = callee_slot + 1;
            const args_end = args_start + argc;
            try self.ensureAbsoluteSlot(args_end);
            const args = fiber.slots.items[args_start..args_end];
            const result = try self.callFunctionParts(
                mm,
                callee,
                args,
            );
            try self.ensureAbsoluteSlot(base + instr.c);
            try self.writeRegisterFast(
                base,
                instr.c,
                result,
            );
            return;
        }
    }

    // .struct_type callee is constructor
    if (callee.isStructType()) {
        const type_id = callee.asStructType().?;
        return self.callStructConstructor(
            type_id,
            instr,
            base,
            callee_slot,
            argc,
        );
    }

    // callee must be a function
    const func = switch (callee.tag()) {
        .function => try self.functions.get(
            callee.asFunction().?,
        ),
        else => {
            const got = switch (callee.tag()) {
                .number => "number",
                else => @tagName(callee.tag()),
            };
            try self.setRuntimeMessageFmt(
                "cannot call {s} value",
                .{got},
            );
            return error.NotAFunction;
        },
    };
    return self.callNonClosureFunction(
        func.*,
        instr,
        base,
        callee_slot,
        argc,
    );
}

fn callStructConstructor(
    self: *VM,
    type_id: revo.StructTypeID,
    instr: Instruction,
    base: usize,
    callee_slot: usize,
    argc: usize,
) EvalError!void {
    const fiber = self.currentFiber();
    const desc = self.struct_types.getType(type_id) orelse {
        try self.setRuntimeMessage("invalid struct type");
        return error.Panic;
    };

    const instance_id = try self.struct_instances.create(
        type_id,
        desc.fields.len,
    );
    const instance = self.structGetInstance(instance_id) catch return error.Panic;

    for (desc.fields, 0..) |f, i| {
        if (f.default_val) |dv|
            instance.fields[i] = dv;
    }

    if (argc > 1) {
        try self.setRuntimeMessageFmt(
            "struct `{s}` expects at most 1 init table, got {}",
            .{ desc.name, argc },
        );
        return error.TypeError;
    }

    if (argc == 1) {
        const init_data = fiber.slots.items[callee_slot + 1];
        const init_id = init_data.asTable() orelse {
            try self.setRuntimeMessageFmt(
                "struct `{s}` expects an init table, got {s}",
                .{
                    desc.name,
                    revo.std_lib.typeof(init_data),
                },
            );
            return error.TypeError;
        };
        const init_table = try self.tables.get(init_id);
        for (desc.fields, 0..) |f, i| {
            if (init_table.getRaw(
                Data.new.atom(f.name_atom),
            )) |val| {
                instance.fields[i] = val;
            }
        }
        for (init_table.hash_order.items) |k| {
            const k_atom = k.asAtom() orelse continue;
            if (desc.fieldIndex(k_atom) == null) {
                try self.setRuntimeMessageFmt(
                    "unknown field `{s}` for struct `{s}`",
                    .{
                        self.atomName(k_atom),
                        desc.name,
                    },
                );
                return error.Panic;
            }
        }
    }

    for (desc.fields, 0..) |f, i| {
        if (instance.fields[i].rawBits() ==
            revo.core_atoms.data(.undef).rawBits() and
            f.default_val == null)
        {
            try self.setRuntimeMessageFmt(
                "missing field `{s}` for struct `{s}`",
                .{
                    self.atomName(f.name_atom),
                    desc.name,
                },
            );
            return error.Panic;
        }
        if (f.type_atom) |expected_atom| {
            const val = instance.fields[i];
            if (!self.structFieldValueMatches(
                expected_atom,
                val,
            )) {
                try self.setRuntimeMessageFmt(
                    "field `{s}` on `{s}` expected {s}, got {s}",
                    .{
                        self.atomName(f.name_atom),
                        desc.name,
                        self.atomName(expected_atom),
                        revo.std_lib.typeof(val),
                    },
                );
                return error.TypeError;
            }
        }
    }

    try self.ensureAbsoluteSlot(base + instr.c);
    try self.writeRegisterFast(base, instr.c, Data.new.structVal(instance_id));
}

fn structFieldValueMatches(
    self: *VM,
    expected_atom: revo.memory.AtomID,
    value: Data,
) bool {
    if (expected_atom == revo.core_atoms.bool.atom_id()) {
        const true_id = revo.core_atoms.atom_id(.true);
        const false_id = revo.core_atoms.atom_id(.false);
        return if (value.asAtom()) |v|
            v == true_id or v == false_id
        else
            false;
    }
    if (expected_atom == revo.core_atoms.num.atom_id()) return value.isNumber();
    if (expected_atom == revo.core_atoms.int.atom_id()) return value.isNumber();
    if (expected_atom == revo.core_atoms.float.atom_id()) return value.isNumber();

    if (expected_atom == revo.core_atoms.bool.atom_id()) {
        const true_id = revo.core_atoms.atom_id(.true);
        const false_id = revo.core_atoms.atom_id(.false);
        return if (value.asAtom()) |a|
            a == true_id or a == false_id
        else
            false;
    }
    const expected_name = self.atomName(expected_atom);
    return std.mem.eql(u8, expected_name, revo.std_lib.typeof(value));
}

fn setStructField(
    self: *VM,
    object: Data,
    field_atom: revo.memory.AtomID,
    value: Data,
) EvalError!bool {
    const instance_id = object.asStructVal() orelse return false;
    const instance = self.structGetInstance(instance_id) catch return error.Panic;
    const desc = self.struct_types.getType(
        instance.type_id,
    ) orelse {
        try self.setRuntimeMessage("invalid struct type");
        return error.Panic;
    };
    const idx = desc.fieldIndex(field_atom) orelse {
        try self.setRuntimeMessageFmt(
            "unknown field `{s}` for struct `{s}`",
            .{ self.atomName(field_atom), desc.name },
        );
        return error.Panic;
    };
    if (desc.fields[idx].type_atom) |expected_atom| {
        if (!self.structFieldValueMatches(
            expected_atom,
            value,
        )) {
            try self.setRuntimeMessageFmt(
                "field `{s}` on `{s}` expected {s}, got {s}",
                .{
                    self.atomName(field_atom),
                    desc.name,
                    self.atomName(expected_atom),
                    revo.std_lib.typeof(value),
                },
            );
            return error.TypeError;
        }
    }
    instance.fields[idx] = value;
    return true;
}

fn structGetInstance(
    self: *VM,
    id: revo.vm.struct_mod.StructInstanceID,
) EvalError!*revo.vm.struct_mod.StructInstance {
    return self.struct_instances.get(id) catch |e| switch (e) {
        error.InvalidStruct => {
            try self.setRuntimeMessage(
                "invalid struct instance",
            );
            return error.Panic;
        },
    };
}

fn returnRegister(
    self: *VM,
    instr: Instruction,
) EvalError!void {
    const fiber = self.currentFiber();
    const result = regRead(
        fiber.slots.items,
        fiber.frames.items[
            fiber.frames.items.len - 1
        ].base,
        instr.a,
    );
    const frame = fiber.frames.pop() orelse unreachable;

    if (fiber.open_upvalues.items.len > 0)
        try self.closeUpvalues(frame.base);

    fiber.pc = frame.return_addr;

    // check if returning to exit frame
    // only one frame left after pop
    const returning_to_exit =
        self.sched.current_fiber == 0 and
        fiber.frames.items.len == 1;

    // toplevel :err tuple should panic
    if (returning_to_exit) {
        if (result.asTuple()) |result_tid| {
            const tuple = try self.tuples.get(result_tid);
            if (tuple.items.len >= 1) {
                const tag = tuple.items[0];
                if (tag.asAtom() ==
                    revo.core_atoms.atom_id(.err))
                {
                    self.panic_span = if (self.currentDebugInfo()) |debug|
                        self.spanAtPc(debug, if (fiber.pc > 0) fiber.pc - 1 else 0)
                    else
                        null;

                    if (tuple.items.len >= 2) {
                        var buf = std.Io.Writer.Allocating.init(
                            self.runtime.alloc,
                        );
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
    }

    if (fiber.frames.items.len == 0 or
        fiber.pc >= fiber.program.len)
    {
        const finished_id = self.sched.current_fiber;
        try self.sched.finishFiber(finished_id, result);
        if (finished_id == 0) {
            fiber.slots.items.len = 0;
            try self.push(result);
        }
        return;
    }

    const parent = try self.currentFrame();
    const result_slot = parent.base +
        frame.result_register;
    const parent_end = parent.base +
        parent.register_count;
    fiber.slots.items.len = @max(result_slot + 1, parent_end);
    fiber.slots.items[result_slot] = result;
}

inline fn spawnRegister(
    self: *VM,
    instr: Instruction,
) EvalError!void {
    const argc: usize = instr.b;
    const fiber = self.currentFiber();
    const callee = try self.readRegister(instr.a);
    const closure_id = callee.asFunction() orelse {
        try self.setRuntimeMessage("spawn expects function!");
        return error.NotAFunction;
    };

    const func = try self.functionFast(closure_id);
    const closure = switch (func.*) {
        .closure => |f| f,
        else => {
            try self.setRuntimeMessage("spawn expects closure!");
            return error.NotAFunction;
        },
    };

    if (closure.arity != root.functions.VARIADIC and
        closure.arity != argc)
    {
        @branchHint(.unlikely);
        try self.setRuntimeMessageFmt(
            "fiber closure `{s}` expected {d} args, got {d}",
            .{ closure.name, closure.arity, argc },
        );
        return error.WrongArity;
    }

    const child_id: FiberID = self.sched.fibers.items.len;
    var child = try Fiber.init(self.runtime.alloc, child_id, fiber.program);
    errdefer child.deinit(self.runtime.alloc);
    child.debug_info_id = fiber.debug_info_id;
    child.state = .ready;

    try child.slots.resize(self.runtime.alloc, closure.register_count);
    @memset(child.slots.items, revo.core_atoms.data(.missing));

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

    const child_closure_id = try self.detachClosureForFiber(
        closure_id,
    );
    try child.frames.append(self.runtime.alloc, .{
        .return_addr = @intCast(child.program.len),
        .base = 0,
        .result_register = 0,
        .register_count = closure.register_count,
        .closure_id = child_closure_id,
    });
    child.pc = closure.addr;

    try self.sched.fibers.append(self.runtime.alloc, child);
    try @call(.always_inline, Scheduler.enqueueRunnable, .{ &self.sched, child_id });
    try self.writeRegister(
        instr.c,
        Data.new.num(@as(i64, @intCast(child_id))),
    );
}

pub inline fn evalRegister(
    self: *VM,
    instr: Instruction,
) EvalError!void {
    const fiber = self.currentFiber();
    const base = fiber.frames.items[fiber.frames.items.len - 1].base;
    const slots = fiber.slots.items;
    const alloc = self.runtime.alloc;

    switch (instr.op) {
        .move => {
            const val = regRead(slots, base, instr.b);
            regWrite(slots, base, instr.a, val);
        },
        .load_const => {
            if (instr.bx >= self.constants.items.len)
                return error.InvalidConstant;
            regWrite(slots, base, instr.a, self.constants.items[instr.bx]);
        },
        .load_nil => regWrite(slots, base, instr.a, revo.core_atoms.data(.nil)),
        .load_small_int => regWrite(
            slots,
            base,
            instr.a,
            Data.new.num(@as(i64, @intCast(instr.bx))),
        ),
        .add => {
            const lhs = regRead(slots, base, instr.b);
            const rhs = regRead(slots, base, instr.c);
            if (lhs.asNum()) |ln| if (rhs.asNum()) |rn| {
                regWrite(slots, base, instr.a, Data.new.num(ln + rn));
                return;
            };
            if (lhs.asStr()) |ls| if (rhs.asStr()) |rs| {
                const result_str = try self.adoptDataStringNoDedup(
                    try std.mem.concat(
                        alloc,
                        u8,
                        &.{ self.stringValue(ls), self.stringValue(rs) },
                    ),
                );
                regWrite(slots, base, instr.a, result_str);
                return;
            };
            try self.setRuntimeMessageFmt(
                "cannot add {s} and {s}",
                .{ revo.std_lib.dataToString(lhs), revo.std_lib.dataToString(rhs) },
            );
            return error.IncompatibleTypes;
        },
        .sub => {
            const lhs = regRead(slots, base, instr.b);
            const rhs = regRead(slots, base, instr.c);
            if (lhs.asNum()) |ln| if (rhs.asNum()) |rn| {
                regWrite(slots, base, instr.a, Data.new.num(ln - rn));
                return;
            };
            try self.setRuntimeMessageFmt(
                "cannot subtract {s} from {s}",
                .{ revo.std_lib.dataToString(rhs), revo.std_lib.dataToString(lhs) },
            );
            return error.IncompatibleTypes;
        },
        .mul => {
            const lhs = regRead(slots, base, instr.b);
            const rhs = regRead(slots, base, instr.c);
            if (lhs.asNum()) |ln| if (rhs.asNum()) |rn| {
                regWrite(slots, base, instr.a, Data.new.num(ln * rn));
                return;
            };
            const StrNum = struct { s: mem.StringID, n: f64 };
            const str_and_num: ?StrNum = blk: {
                if (lhs.asStr()) |ls| if (rhs.asNum()) |n|
                    break :blk .{ .s = ls, .n = n };
                if (rhs.asStr()) |rs| if (lhs.asNum()) |n|
                    break :blk .{ .s = rs, .n = n };
                break :blk null;
            };
            if (str_and_num) |pair| {
                const str = self.stringValue(pair.s);
                const count: usize = @intCast(
                    std.math.clamp(
                        @as(i64, @intFromFloat(pair.n)),
                        0,
                        std.math.maxInt(i32),
                    ),
                );
                _ = std.math.mul(usize, str.len, count) catch
                    return error.OutOfMemory;
                const result = try alloc.alloc(u8, str.len * count);
                for (0..count) |i|
                    @memcpy(result[i * str.len ..][0..str.len], str);
                regWrite(slots, base, instr.a, try self.adoptDataStringNoDedup(result));
                return;
            }
            try self.setRuntimeMessageFmt(
                "cannot multiply {s} and {s}",
                .{ revo.std_lib.dataToString(lhs), revo.std_lib.dataToString(rhs) },
            );
            return error.IncompatibleTypes;
        },
        .div => {
            const lhs = regRead(slots, base, instr.b);
            const rhs = regRead(slots, base, instr.c);
            if (lhs.asNum()) |ln| if (rhs.asNum()) |rn| {
                if (rn == 0) return error.DivisionByZero;
                regWrite(slots, base, instr.a, Data.new.num(ln / rn));
                return;
            };
            try self.setRuntimeMessageFmt(
                "cannot divide {s} by {s}",
                .{ revo.std_lib.dataToString(lhs), revo.std_lib.dataToString(rhs) },
            );
            return error.IncompatibleTypes;
        },
        .mod => {
            const lhs = regRead(slots, base, instr.b);
            const rhs = regRead(slots, base, instr.c);
            if (lhs.asNum()) |ln| if (rhs.asNum()) |rn| {
                if (rn == 0) return error.DivisionByZero;
                regWrite(slots, base, instr.a, Data.new.num(@mod(ln, rn)));
                return;
            };
            try self.setRuntimeMessageFmt(
                "cannot mod {s} by {s}",
                .{ revo.std_lib.dataToString(lhs), revo.std_lib.dataToString(rhs) },
            );
            return error.IncompatibleTypes;
        },
        .mod_int => {
            const lhs = regRead(slots, base, instr.b);
            const rhs = regRead(slots, base, instr.c);
            if (self.debug_assert_types) {
                std.debug.assert(lhs.isNumber());
                std.debug.assert(rhs.isNumber());
            }
            const li = @as(
                i64,
                @intFromFloat(@as(f64, @bitCast(lhs.bits))),
            );
            const ri = @as(
                i64,
                @intFromFloat(@as(f64, @bitCast(rhs.bits))),
            );
            if (ri == 0) return error.DivisionByZero;
            regWrite(
                slots,
                base,
                instr.a,
                Data.new.num(@as(f64, @floatFromInt(@mod(li, ri)))),
            );
        },
        .negate => {
            const v = regRead(slots, base, instr.b);
            if (v.asNum()) |n| {
                regWrite(slots, base, instr.a, Data.new.num(-n));
                return;
            }
            try self.setRuntimeMessageFmt("cannot negate {s}", .{revo.std_lib.dataToString(v)});
            return error.IncompatibleTypes;
        },
        .negate_int => {
            const v = regRead(slots, base, instr.b);
            if (self.debug_assert_types)
                std.debug.assert(v.isNumber());
            const v_int = @as(
                i64,
                @intFromFloat(@as(f64, @bitCast(v.bits))),
            );
            regWrite(
                slots,
                base,
                instr.a,
                Data.new.num(@as(f64, @floatFromInt(-v_int))),
            );
        },
        .negate_float => {
            const v = regRead(slots, base, instr.b);
            if (self.debug_assert_types)
                std.debug.assert(v.isNumber());
            regWrite(slots, base, instr.a, Data.new.num(-@as(
                f64,
                @bitCast(v.bits),
            )));
        },
        // specialized arith opcodes for typed int/float
        // direct @bitCast, no tag check
        .add_int => {
            const lhs = regRead(slots, base, instr.b);
            const rhs = regRead(slots, base, instr.c);
            if (self.debug_assert_types) {
                std.debug.assert(lhs.isNumber());
                std.debug.assert(rhs.isNumber());
            }
            regWrite(slots, base, instr.a, Data.new.num(@as(f64, @bitCast(lhs.bits)) +
                @as(f64, @bitCast(rhs.bits))));
        },
        .sub_int => {
            const lhs = regRead(slots, base, instr.b);
            const rhs = regRead(slots, base, instr.c);
            if (self.debug_assert_types) {
                std.debug.assert(lhs.isNumber());
                std.debug.assert(rhs.isNumber());
            }
            regWrite(
                slots,
                base,
                instr.a,
                Data.new.num(@as(
                    f64,
                    @bitCast(lhs.bits),
                ) - @as(
                    f64,
                    @bitCast(rhs.bits),
                )),
            );
        },
        .mul_int => {
            const lhs = regRead(slots, base, instr.b);
            const rhs = regRead(slots, base, instr.c);
            if (self.debug_assert_types) {
                std.debug.assert(lhs.isNumber());
                std.debug.assert(rhs.isNumber());
            }
            regWrite(
                slots,
                base,
                instr.a,
                Data.new.num(@as(
                    f64,
                    @bitCast(lhs.bits),
                ) * @as(
                    f64,
                    @bitCast(rhs.bits),
                )),
            );
        },
        .div_int => {
            const lhs = regRead(slots, base, instr.b);
            const rhs = regRead(slots, base, instr.c);
            if (self.debug_assert_types) {
                std.debug.assert(lhs.isNumber());
                std.debug.assert(rhs.isNumber());
            }
            const rv = @as(f64, @bitCast(rhs.bits));
            if (rv == 0) return error.DivisionByZero;
            regWrite(
                slots,
                base,
                instr.a,
                Data.new.num(@divTrunc(
                    @as(
                        i64,
                        @intFromFloat(@as(
                            f64,
                            @bitCast(lhs.bits),
                        )),
                    ),
                    @as(
                        i64,
                        @intFromFloat(rv),
                    ),
                )),
            );
        },
        .div_float => {
            const lhs = regRead(slots, base, instr.b);
            const rhs = regRead(slots, base, instr.c);
            if (self.debug_assert_types) {
                std.debug.assert(lhs.isNumber());
                std.debug.assert(rhs.isNumber());
            }
            if (@as(f64, @bitCast(rhs.bits)) == 0)
                return error.DivisionByZero;
            regWrite(
                slots,
                base,
                instr.a,
                Data.new.num(@as(
                    f64,
                    @bitCast(lhs.bits),
                ) / @as(
                    f64,
                    @bitCast(rhs.bits),
                )),
            );
        },
        inline .eq, .neq, .lt, .gt, .lte, .gte => |op| try compare_impl.evalCachedFast(
            slots,
            base,
            self,
            instr,
            op,
        ),
        // specialized typed comparison opcodes
        inline .eq_int, .neq_int, .lt_int, .gt_int, .lte_int, .gte_int => |op| {
            const lhs_val = regRead(slots, base, instr.b);
            const rhs_val = regRead(slots, base, instr.c);
            const lhs: f64 = @bitCast(lhs_val.bits);
            const rhs: f64 = @bitCast(rhs_val.bits);
            const result = switch (op) {
                .eq_int => lhs == rhs,
                .neq_int => lhs != rhs,
                .lt_int => lhs < rhs,
                .gt_int => lhs > rhs,
                .lte_int => lhs <= rhs,
                .gte_int => lhs >= rhs,
                else => unreachable,
            };
            regWrite(
                slots,
                base,
                instr.a,
                Data.new.boolean(result),
            );
        },
        .@"and" => regWrite(
            slots,
            base,
            instr.a,
            Data.new.boolean(
                !revo.isFalse(regRead(
                    slots,
                    base,
                    instr.b,
                )) and
                    !revo.isFalse(regRead(
                        slots,
                        base,
                        instr.c,
                    )),
            ),
        ),
        .@"or" => regWrite(
            slots,
            base,
            instr.a,
            Data.new.boolean(
                !revo.isFalse(regRead(
                    slots,
                    base,
                    instr.b,
                )) or
                    !revo.isFalse(regRead(
                        slots,
                        base,
                        instr.c,
                    )),
            ),
        ),
        .not => regWrite(
            slots,
            base,
            instr.a,
            Data.new.boolean(revo.isFalse(regRead(
                slots,
                base,
                instr.b,
            ))),
        ),
        .table_new => {
            self.noteGCPressure(64);
            regWrite(
                slots,
                base,
                instr.a,
                Data.new.table(try self.tables.create()),
            );
        },
        .table_set => {
            // self.perf.table_set_ops += 1;
            const table_value = regRead(
                slots,
                base,
                instr.a,
            );
            const key = regRead(slots, base, instr.b);
            if (key.asAtom()) |atom| {
                if (try self.setStructField(
                    table_value,
                    atom,
                    regRead(slots, base, instr.c),
                )) return;
            }
            const t_id = try self.moduleExportsTable(table_value);
            const t = try self.tableFast(t_id);
            try t.put(
                t_id,
                self,
                key,
                regRead(slots, base, instr.c),
            );
        },
        .table_get => {
            // self.perf.table_get_ops += 1;
            const object = regRead(slots, base, instr.b);
            const key = regRead(slots, base, instr.c);
            if (object.asTable()) |t_id| {
                const t = try self.tableFast(t_id);
                if (t.getRaw(key)) |value| {
                    regWrite(
                        slots,
                        base,
                        instr.a,
                        value,
                    );
                    return;
                }
            }
            if (try self.resolveField(object, key)) |resolved| {
                regWrite(
                    slots,
                    base,
                    instr.a,
                    resolved.value,
                );
            } else regWrite(
                slots,
                base,
                instr.a,
                revo.core_atoms.data(.undef),
            );
        },
        .table_set_atom => {
            // self.perf.table_set_ops += 1;
            const table_value = regRead(
                slots,
                base,
                instr.a,
            );
            if (try self.setStructField(
                table_value,
                instr.bx,
                regRead(slots, base, instr.c),
            )) return;
            const t_id = try self.moduleExportsTable(table_value);
            const t = try self.tableFast(t_id);
            const key = Data.new.atom(instr.bx);
            try t.put(
                t_id,
                self,
                key,
                regRead(slots, base, instr.c),
            );
        },
        .table_get_atom => {
            // self.perf.table_get_ops += 1;
            const object = regRead(slots, base, instr.b);
            const t_id = object.asTable() orelse {
                const key = Data.new.atom(instr.bx);
                if (try self.resolveField(
                    object,
                    key,
                )) |resolved| {
                    regWrite(
                        slots,
                        base,
                        instr.a,
                        resolved.value,
                    );
                } else regWrite(
                    slots,
                    base,
                    instr.a,
                    revo.core_atoms.data(.undef),
                );
                return;
            };
            const pc = fiber.pc - 1;
            const ic = &self.icache[pc & (self.icache.len - 1)];
            const t = try self.tableFast(t_id);

            if (ic.pc == pc and
                ic.table_id == t_id and
                ic.version == t.ic_version)
            {
                @branchHint(.likely);
                regWrite(
                    slots,
                    base,
                    instr.a,
                    ic.value,
                );
            } else {
                const key = Data.new.atom(instr.bx);
                if (t.getRaw(key)) |value| {
                    ic.* = .{
                        .pc = pc,
                        .table_id = t_id,
                        .version = t.ic_version,
                        .value = value,
                    };
                    regWrite(
                        slots,
                        base,
                        instr.a,
                        value,
                    );
                    return;
                }
                if (try self.resolveField(
                    object,
                    key,
                )) |resolved| {
                    ic.* = .{
                        .pc = pc,
                        .table_id = t_id,
                        .version = t.ic_version,
                        .value = resolved.value,
                    };
                    regWrite(
                        slots,
                        base,
                        instr.a,
                        resolved.value,
                    );
                } else regWrite(
                    slots,
                    base,
                    instr.a,
                    revo.core_atoms.data(.undef),
                );
            }
        },
        .tuple_new => {
            const start = base + instr.b;
            const count: usize = instr.bx;
            self.noteGCPressure(
                @sizeOf(root.tuple.Tuple) +
                    @sizeOf(Data) * instr.bx,
            );
            regWrite(
                slots,
                base,
                instr.a,
                Data.new.tuple(try self.tuples.create(
                    slots[start .. start + count],
                )),
            );
        },
        .tuple_get => {
            const tuple_id = (regRead(
                slots,
                base,
                instr.b,
            )).asTuple() orelse return error.TypeError;
            const idx_val = regRead(slots, base, instr.c);
            const idx_num = idx_val.asNum() orelse return error.TypeError;
            if (idx_num < 0 or
                @floor(idx_num) != idx_num) return error.TypeError;
            if (idx_num > @as(
                f64,
                @floatFromInt(std.math.maxInt(usize)),
            )) return error.TypeError;
            const idx: usize = @intFromFloat(idx_num);
            const t = try self.tuples.get(tuple_id);
            if (idx >= t.items.len) {
                try self.setRuntimeMessageFmt(
                    "tuple index {d} out of range for tuple of length {d}",
                    .{ idx, t.items.len },
                );
                return error.InvalidTuple;
            }
            regWrite(
                slots,
                base,
                instr.a,
                t.items[idx],
            );
        },
        .tuple_get_const => {
            const tuple_id = (regRead(
                slots,
                base,
                instr.b,
            )).asTuple() orelse return error.TypeError;
            const t = try self.tuples.get(tuple_id);
            if (instr.bx >= t.items.len) {
                try self.setRuntimeMessageFmt(
                    "tuple index {d} out of range for tuple of length {d}",
                    .{ instr.bx, t.items.len },
                );
                return error.InvalidTuple;
            }
            regWrite(
                slots,
                base,
                instr.a,
                t.items[instr.bx],
            );
        },
        .struct_new => {
            const type_id: revo.StructTypeID = instr.bx;
            const desc = self.struct_types.getType(
                type_id,
            ) orelse {
                try self.setRuntimeMessage(
                    "invalid struct type",
                );
                return error.Panic;
            };
            const instance_id = try self.struct_instances.create(
                type_id,
                desc.fields.len,
            );
            const instance = self.structGetInstance(
                instance_id,
            ) catch return error.Panic;
            //
            // defaults
            for (desc.fields, 0..) |f, i| {
                if (f.default_val) |dv|
                    instance.fields[i] = dv;
            }
            regWrite(
                slots,
                base,
                instr.a,
                Data.new.structVal(instance_id),
            );
        },
        .struct_set_method => {
            const type_val = regRead(
                slots,
                base,
                instr.a,
            );
            const type_id = type_val.asStructType() orelse return error.TypeError;
            const name_atom_data = regRead(
                slots,
                base,
                instr.b,
            );
            const name_atom = name_atom_data.asAtom() orelse return error.TypeError;
            const method = regRead(
                slots,
                base,
                instr.c,
            );
            const desc = self.struct_types.getType(
                type_id,
            ) orelse return error.TypeError;
            try desc.methods.put(
                self.atomName(name_atom),
                method,
            );
        },
        .struct_get_offset => {
            const object = regRead(slots, base, instr.b);
            const instance_id = object.asStructVal() orelse return error.TypeError;
            const instance = self.structGetInstance(
                instance_id,
            ) catch return error.Panic;
            regWrite(
                slots,
                base,
                instr.a,
                instance.get(instr.bx),
            );
        },
        .struct_set_offset => {
            const object = regRead(slots, base, instr.a);
            const instance_id = object.asStructVal() orelse return error.TypeError;
            const instance = self.structGetInstance(
                instance_id,
            ) catch return error.Panic;
            const value = regRead(slots, base, instr.c);
            instance.set(instr.bx, value);
            regWrite(
                slots,
                base,
                instr.a,
                Data.new.structVal(instance_id),
            );
        },
        .jump => fiber.pc = instr.bx,
        .jump_if_false => {
            @branchHint(.unlikely);
            if (revo.isFalse(regRead(
                slots,
                base,
                instr.a,
            ))) fiber.pc = instr.bx;
        },
        .jump_if_true => {
            @branchHint(.unlikely);
            if (!revo.isFalse(regRead(
                slots,
                base,
                instr.a,
            ))) fiber.pc = instr.bx;
        },
        .load_global => {
            const value = self.globals.get(instr.bx) orelse {
                try self.setRuntimeMessageFmt(
                    "undefined variable `{s}`",
                    .{self.atomName(instr.bx)},
                );
                return error.UndefinedVariable;
            };
            regWrite(
                slots,
                base,
                instr.a,
                value,
            );
        },
        .load_stdlib_global => {
            const value = self.stdlib_globals.get(
                instr.bx,
            ) orelse {
                try self.setRuntimeMessageFmt(
                    "undefined stdlib variable `{s}`",
                    .{self.atomName(instr.bx)},
                );
                return error.UndefinedVariable;
            };
            regWrite(
                slots,
                base,
                instr.a,
                value,
            );
        },
        .store_global => {
            if (self.const_globals.contains(instr.bx)) {
                try self.setRuntimeMessage(
                    "reassignment to constant!",
                );
                return error.ConstantReassignment;
            }
            try self.globals.put(
                instr.bx,
                try self.readRegister(instr.a),
            );
        },
        .store_global_const => {
            if (self.const_globals.contains(instr.bx)) {
                try self.setRuntimeMessage(
                    "reassignment to constant!",
                );
                return error.ConstantReassignment;
            }
            try self.globals.put(
                instr.bx,
                try self.readRegister(instr.a),
            );
            try self.const_globals.put(instr.bx, {});
        },
        .load_local, .bind_local => {
            const dst = base + instr.a;
            const src = base + instr.b;
            if (builtin.mode != .ReleaseFast and
                src >= slots.len)
            {
                regWrite(
                    slots,
                    base,
                    instr.a,
                    revo.core_atoms.data(.missing),
                );
            } else {
                slots[dst] = slots[src];
            }
        },
        .store_local => {
            if (try self.currentClosure()) |closure| blk: {
                const proto = try self.functions.getPrototype(
                    closure.prototype,
                );
                const idx = instr.a / 8;
                if (idx >= proto.const_local_bits.len)
                    break :blk;
                const bit: u3 = @intCast(instr.a % 8);
                if ((proto.const_local_bits[idx] &
                    (@as(u8, 1) << bit)) != 0) return error.ConstantReassignment;
            }
            const dst = base + instr.a;
            const src = base + instr.b;
            if (builtin.mode != .ReleaseFast and
                src >= slots.len)
            {
                regWrite(
                    slots,
                    base,
                    instr.a,
                    revo.core_atoms.data(.missing),
                );
            } else {
                slots[dst] = slots[src];
            }
        },
        .closure => {
            self.noteGCPressure(48);
            const proto = try self.functions.getPrototype(
                instr.bx,
            );
            var upvalues = try std.ArrayList(
                root.functions.UpvalueID,
            ).initCapacity(
                self.runtime.alloc,
                proto.upvalue_specs.len,
            );
            defer upvalues.deinit(self.runtime.alloc);

            for (proto.upvalue_specs) |spec| {
                if (spec.is_local) {
                    const frame = fiber.frames.items[
                        fiber.frames.items.len - 1
                    ];
                    try upvalues.append(
                        self.runtime.alloc,
                        try self.captureUpvalue(frame.base + spec.index),
                    );
                } else {
                    const closure = (try self.currentClosure()) orelse return error.TypeError;
                    try upvalues.append(self.runtime.alloc, closure.upvalues[spec.index]);
                }
            }
            regWrite(
                slots,
                base,
                instr.a,
                Data.new.function(try self.functions.createClosure(instr.bx, upvalues.items)),
            );
        },
        .load_upval => {
            const closure = (try self.currentClosure()) orelse return error.InvalidLocal;
            regWrite(
                slots,
                base,
                instr.a,
                try self.loadUpvalueData(closure.upvalues[instr.bx]),
            );
        },
        .store_upval => {
            const closure = (try self.currentClosure()) orelse return error.InvalidLocal;
            try self.storeUpvalueData(closure.upvalues[instr.bx], regRead(slots, base, instr.a));
        },
        .call => try self.callRegister(instr),
        .call_field => {
            const colon = (instr.b & @as(opcode.Register, 1 << 15)) != 0;
            const explicit_argc: usize = @intCast(
                instr.b & ~@as(opcode.Register, 1 << 15),
            );
            const object = try self.readRegister(instr.a);
            const key = try self.readRegister(instr.a + 1);

            const lookup_result = (try self.resolveField(
                object,
                key,
            )) orelse {
                const key_name = if (key.asAtom()) |atom|
                    self.atomName(atom)
                else
                    revo.std_lib.dataToString(key);
                try self.setRuntimeMessageFmt(
                    "field `{s}` does not exist on {s}",
                    .{ key_name, revo.std_lib.typeof(object) },
                );
                return error.NotAFunction;
            };

            if (colon) {
                try self.writeRegister(instr.a, lookup_result.value);
                try self.writeRegister(instr.a + 1, object);
                try self.callRegister(.{ .op = .call, .a = instr.a, .b = @intCast(explicit_argc + 1), .c = instr.c });
                return;
            }

            // keep argv continuous without shifting
            // callee in a+1, args already start at a+2
            try self.writeRegister(instr.a + 1, lookup_result.value);
            try self.callRegister(.{ .op = .call, .a = instr.a + 1, .b = @intCast(explicit_argc), .c = instr.c });
        },
        .ret => try self.returnRegister(instr),
        .spawn => try self.spawnRegister(instr),
        .join => {
            const handle = regRead(slots, base, instr.a);
            const target_num = handle.asNum() orelse return error.TypeError;
            const target_id = if (target_num >= 0 and
                @floor(target_num) == target_num)
                @as(usize, @intFromFloat(target_num))
            else
                return error.TypeError;
            if (target_id >= self.sched.fibers.items.len)
                return error.TypeError;
            const target = &self.sched.fibers.items[target_id];
            if (target.state == .dead) {
                regWrite(slots, base, instr.a, target.result);
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
            fiber.running = false;
        },
        .halt => {
            const result = regRead(slots, base, instr.a);
            fiber.slots.items.len = 0;
            try self.push(result);
            fiber.running = false;
            self.sched.setFiberState(self.sched.current_fiber, .dead);
        },
        .range_init => {
            const start = regRead(slots, base, instr.b);
            const limit = regRead(slots, base, instr.c);
            const step = regRead(slots, base, @intCast(instr.bx));

            // state layout in consecutive registers
            // starting at a:
            // R[a]   = current (start initially)
            // R[a+1] = step
            // R[a+2] = limit
            regWrite(slots, base, instr.a, start);
            regWrite(slots, base, instr.a + 1, step);
            regWrite(slots, base, instr.a + 2, limit);
        },
        .range_next => {
            // loop state in consecutive registers
            // starting at b:
            // R[b]   = current
            // R[b+1] = step
            // R[b+2] = limit
            const current = (regRead(slots, base, instr.b)).as_number() catch return error.TypeError;
            const step = (regRead(slots, base, instr.b + 1)).as_number() catch return error.TypeError;
            const limit = (regRead(slots, base, instr.b + 2)).as_number() catch return error.TypeError;

            const has_next = (step > 0 and current < limit) or
                (step < 0 and current > limit);

            // out: r[a]=value, r[c]=index (if c!=0)
            // r[bx]=has_next
            regWrite(slots, base, instr.a, Data.new.num(current));
            if (instr.c != 0) {
                const index_reg = regRead(slots, base, instr.c);
                const index = index_reg.asNum() orelse 0.0;
                if (has_next)
                    regWrite(slots, base, instr.c, Data.new.num(index + 1));
            }
            regWrite(slots, base, @intCast(instr.bx), Data.new.boolean(has_next));

            if (has_next)
                regWrite(slots, base, instr.b, Data.new.num(current + step));
        },
        .range_for => {
            // R[a] = current (in/out)
            // R[b] = step
            // R[c] = limit
            // bx = max iterations
            var current = (regRead(slots, base, instr.a)).as_number() catch return error.TypeError;
            const step = (regRead(slots, base, instr.b)).as_number() catch return error.TypeError;
            const limit = (regRead(slots, base, instr.c)).as_number() catch return error.TypeError;
            const max_iter: f64 = @floatFromInt(instr.bx);

            var i: f64 = 0;
            while (i < max_iter) {
                const done = (step > 0 and current > limit) or
                    (step < 0 and current < limit);
                if (done) break;
                current += step;
                i += 1;
            }
            regWrite(
                slots,
                base,
                instr.a,
                Data.new.num(current),
            );
        },
        .unwrap_result => {
            const val = regRead(slots, base, instr.a);
            const propagate_errors = instr.bx == 0;

            // if val is (:err, ...) is true, return early
            const tuple_id = val.asTuple() orelse return;
            const tuple = try self.tuples.get(tuple_id);
            if (tuple.items.len == 0) return;

            const tag = tuple.items[0];

            // branch (:err, e)
            if (tag.asAtom() == revo.core_atoms.atom_id(.err)) {
                if (propagate_errors) {
                    if (fiber.frames.items.len == 2) {
                        if (tuple.items.len > 1) {
                            var buf = std.Io.Writer.Allocating.init(
                                self.runtime.alloc,
                            );
                            defer buf.deinit();
                            tuple.items[1].write(
                                &buf.writer,
                                self,
                                .display,
                            ) catch |err| switch (err) {
                                error.OutOfMemory => return error.OutOfMemory,
                                else => return error.Panic,
                            };
                            self.setPanicMessageOwned(
                                try buf.toOwnedSlice(),
                            );
                        }
                        self.panic_span = if (self.currentDebugInfo()) |debug|
                            self.spanAtPc(
                                debug,
                                if (fiber.pc > 0)
                                    fiber.pc - 1
                                else
                                    0,
                            )
                        else
                            null;
                        return error.Panic;
                    }
                    try self.returnRegister(.{
                        .op = .ret,
                        .a = instr.a,
                    });
                    return;
                }
                // otherwise just pass thru
                // don't unwrap unless propagating
                return;
            }

            // check if (:ok, v) then extract
            if (tag.asAtom() == revo.core_atoms.atom_id(.ok)) {
                if (tuple.items.len > 1) {
                    regWrite(
                        slots,
                        base,
                        instr.a,
                        tuple.items[1],
                    );
                }
                return;
            }

            // otherwise just pass thru
        },
        .jump_if_not_nil_and_not_err => {
            const val = regRead(slots, base, instr.a);
            const is_nil = if (val.asAtom()) |a|
                a == revo.core_atoms.atom_id(.nil)
            else
                false;
            const is_err = if (val.asTuple()) |tid| blk: {
                const tuple = try self.tuples.get(tid);
                if (tuple.items.len > 0) {
                    const tag = tuple.items[0];
                    break :blk tag.asAtom() ==
                        revo.core_atoms.atom_id(.err);
                }
                break :blk false;
            } else false;

            if (!is_nil and !is_err) {
                fiber.pc = instr.bx;
            }
        },
        .jump_if_err => {
            const val = regRead(slots, base, instr.a);
            const is_err = if (val.asTuple()) |tid| blk: {
                const tuple = try self.tuples.get(tid);
                if (tuple.items.len > 0) {
                    const tag = tuple.items[0];
                    break :blk tag.asAtom() ==
                        revo.core_atoms.atom_id(.err);
                }
                break :blk false;
            } else false;

            if (is_err) {
                fiber.pc = instr.bx;
            }
        },
    }
}

// gc
pub fn markData(self: *VM, data: Data) void {
    vm_gc.markData(self, data);
}

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
    _ = @import("exec.zig");
    _ = @import("gc.zig");
}

const std = @import("std");
const builtin = @import("builtin");

const revo = @import("revo");
const lang = revo.lang;
const Span = lang.Span;

const compare_impl = @import("compare.zig");
const root = @import("root.zig");
pub const EvalErrorKind = root.debug.EvalErrorKind;
pub const EvalFailure = root.debug.EvalFailure;
pub const EvalResult = root.debug.EvalResult;
const Frame = root.functions.Frame;
const FunctionPool = root.functions.FunctionPool;
pub const lookup = root.lookup;
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
pub const GlobalID = mem.StringID;
pub const ChannelID = mem.TableID;
pub const resolveField = lookup.resolveField;
pub const callField = lookup.callField;
pub const resolveIndex = lookup.resolveIndex;
pub const FieldLookup = lookup.FieldLookup;
pub const getMetatable = lookup.getMetatable;
pub const getMetamethod = lookup.getMetamethod;
pub const setMetatable = lookup.setMetatable;
pub const setTableMetatable = lookup.setTableMetatable;
pub const runModule = module.runModule;
pub const runImportedModule = module.runImportedModule;
const Scheduler = @import("scheduler.zig");
const struct_mod = @import("struct.zig");
const vm_exec = @import("exec.zig");
const vm_gc = @import("gc.zig");
