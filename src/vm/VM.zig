pub const MAX_FRAMES = 256;
pub const INIT_REG_COUNT = 256;
pub const ProgramCounter = usize;
pub const ConstantID = usize;

pub const DebugOptions = struct {
    trace: bool = false,
    dump: bool = false,
    each_instr: bool = false,
    each_stack: bool = false,
};

pub const debug_assert_types = false;

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
    registers: []Data,
    registers_len: usize = 0,
    frames_hot: std.ArrayList(FrameHot),
    frames_cold: std.ArrayList(FrameCold),
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

    pub fn init(alloc: std.mem.Allocator, id: FiberID, program: []const Instruction, reg_count: usize) !Fiber {
        var self = Fiber{
            .id = id,
            .pc = 0,
            .program = program,
            .debug_info_id = null,
            .registers = undefined,
            .frames_hot = undefined,
            .frames_cold = undefined,
            .open_upvalues = undefined,
            .running = false,
            .state = .ready,
            .in_runq = false,
            .wait = .none,
            .parked_result_slot = null,
            .waiters = undefined,
            .result = revo.core_atoms.data(.nil),
        };

        self.registers = try alloc.alloc(Data, reg_count);
        errdefer alloc.free(self.registers);
        self.frames_hot = try std.ArrayList(FrameHot).initCapacity(alloc, MAX_FRAMES);
        errdefer self.frames_hot.deinit(alloc);
        self.frames_cold = try std.ArrayList(FrameCold).initCapacity(alloc, MAX_FRAMES);
        errdefer self.frames_cold.deinit(alloc);
        self.open_upvalues = try std.ArrayList(OpenUpvalueRef).initCapacity(alloc, 8);
        errdefer self.open_upvalues.deinit(alloc);
        self.waiters = try std.ArrayList(FiberID).initCapacity(alloc, 2);
        errdefer self.waiters.deinit(alloc);

        return self;
    }

    pub fn deinit(self: *Fiber, alloc: std.mem.Allocator) void {
        alloc.free(self.registers);
        self.frames_hot.deinit(alloc);
        self.frames_cold.deinit(alloc);
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
]?mem.TableID = @splat(null),
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
c_data: ?*anyopaque = null,
gc_enabled: bool = true,
gc_pending: bool = false,
gc_bytes_allocated: usize = 0,

// optional opcode counters for benchmarking/profiling
// allocated on init
gc_threshold: usize = 512 * 1024, // 512kb initial
gc_pause_factor: usize = 2,
// 64kb nursery
gc_nursery_threshold: usize = 64 * 1024,

/// for table lookups
icache: [256]ICacheEntry = undefined,

gc_mark_stack: std.ArrayList(MarkItem),

const MarkItem = union(enum) {
    data: Data,
    table: mem.TableID,
    tuple: mem.TupleID,
    function: mem.FunctionID,
    upvalue: root.functions.UpvalueID,
    struct_instance: struct_mod.StructInstanceID,
};

pub fn init(runtime: revo.Runtime) !VM {
    var rt = runtime;
    rt.diag_arena = null;
    rt.diag_alloc = undefined;
    try rt.ensureDiagArena();
    errdefer rt.deinitDiagArena();
    var vm: VM = .{
        .runtime = rt,
        .sched = undefined,
        .constants = undefined,
        .stdlib_globals = Globals.init(rt.alloc),
        .tables = undefined,
        .tuples = undefined,
        .functions = undefined,
        .struct_types = struct_mod.StructTypePool.init(rt.alloc),
        .struct_instances = undefined,
        .strings = undefined,
        .atoms = std.StringHashMap(mem.AtomID).init(rt.alloc),
        .module_cache = ModuleCache.init(rt.alloc),
        .package_path = undefined,
        .debug_infos = undefined,
        .globals = Globals.init(rt.alloc),
        .const_globals = ConstGlobals.init(rt.alloc),
        .module_dir = null,
        .loading_stack = undefined,
        .loaded_extensions = .empty,
        .gc_mark_stack = undefined,
    };
    try revo.async_backend_impl.init(&vm.runtime.async_backend);
    errdefer revo.async_backend_impl.deinit(&vm.runtime.async_backend);

    vm.sched = try Scheduler.init(rt.alloc);
    errdefer vm.sched.deinit();
    vm.constants = try std.ArrayList(Data).initCapacity(rt.alloc, 16);
    errdefer vm.constants.deinit(rt.alloc);
    vm.tables = try TablePool.init(rt.alloc);
    errdefer vm.tables.deinit();
    vm.tuples = try TuplePool.init(rt.alloc);
    errdefer vm.tuples.deinit();
    vm.functions = try FunctionPool.init(rt.alloc);
    errdefer vm.functions.deinit();
    vm.struct_instances = try struct_mod.StructInstancePool.init(rt.alloc);
    errdefer vm.struct_instances.deinit();
    vm.strings = try Interner.init(rt.alloc);
    errdefer vm.strings.deinit();
    vm.package_path = try std.ArrayList([]const u8).initCapacity(rt.alloc, 4);
    errdefer vm.package_path.deinit(rt.alloc);
    vm.debug_infos = try std.ArrayList(DebugInfo).initCapacity(rt.alloc, 8);
    errdefer vm.debug_infos.deinit(rt.alloc);
    vm.loading_stack = try std.ArrayList([]const u8).initCapacity(rt.alloc, 1);
    errdefer vm.loading_stack.deinit(rt.alloc);
    vm.gc_mark_stack = try std.ArrayList(MarkItem).initCapacity(rt.alloc, 256);
    errdefer vm.gc_mark_stack.deinit(rt.alloc);

    // init icache with max pc to force miss
    for (&vm.icache) |*entry| {
        entry.* = .{
            .pc = std.math.maxInt(ProgramCounter),
            .table_id = 0,
            .version = 0,
            .value = undefined,
        };
    }

    try vm.package_path.appendSlice(rt.alloc, &.{ "./?", "./lib/?", "/usr/local/lib/revo/?" });

    try vm.sched.fibers.append(rt.alloc, .{
        .id = 0,
        .pc = 0,
        .program = &.{},
        .debug_info_id = null,
        .registers = try runtime.alloc.alloc(Data, INIT_REG_COUNT),
        .frames_hot = try std.ArrayList(FrameHot).initCapacity(runtime.alloc, 4),
        .frames_cold = try std.ArrayList(FrameCold).initCapacity(runtime.alloc, 4),
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

pub inline fn noteGCPressure(self: *VM, bytes: usize) void {
    vm_gc.noteGCPressure(self, bytes);
}

pub fn maybeCollectGarbage(self: *VM) void {
    vm_gc.maybeCollectGarbage(self);
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
    self.runtime.deinitDiagArena();
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
    try ensureRegCapacity(fiber, self.runtime.alloc, fiber.registers_len + 1);
    fiber.registers[fiber.registers_len] = val;
    fiber.registers_len += 1;
}

pub fn currentResult(self: *VM) Data {
    const fiber = self.currentFiber();
    if (fiber.registers_len > 0) return fiber.registers[fiber.registers_len - 1];
    return fiber.result;
}

pub inline fn mainResult(self: *VM) Data {
    const fiber = self.mainFiber();
    if (fiber.registers_len > 0) return fiber.registers[fiber.registers_len - 1];
    return fiber.result;
}

pub fn printStack(self: *VM) void {
    std.debug.print("[", .{});
    for (self.currentFiber().registers) |item| {
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

//
// slot helpers
//
pub fn pop(self: *VM) !Data {
    const fiber = self.currentFiber();
    if (fiber.registers_len == 0) return error.StackUnderflow;
    fiber.registers_len -= 1;
    return fiber.registers[fiber.registers_len];
}

fn absoluteRegisterIndex(self: *VM, reg: opcode.Register) !usize {
    const frame = try self.currentFrame();
    return frame.base + reg;
}

pub fn ensureRegCapacity(fiber: *Fiber, alloc: std.mem.Allocator, needed: usize) !void {
    if (needed <= fiber.registers.len) return;
    const new_cap = @max(needed, fiber.registers.len * 2);
    fiber.registers = try alloc.realloc(fiber.registers, new_cap);
}

fn ensureAbsoluteSlot(self: *VM, slot: usize) !void {
    const fiber = self.currentFiber();
    try ensureRegCapacity(fiber, self.runtime.alloc, slot + 1);
    if (slot < fiber.registers_len) return;
    const old_len = fiber.registers_len;
    @memset(fiber.registers[old_len .. slot + 1], revo.core_atoms.data(.missing));
    fiber.registers_len = slot + 1;
}

pub fn readRegister(self: *VM, reg: opcode.Register) !Data {
    const slot = try self.absoluteRegisterIndex(reg);
    if (slot >= self.currentFiber().registers_len)
        return revo.core_atoms.data(.missing);

    return self.currentFiber().registers[slot];
}

pub fn writeRegister(self: *VM, reg: opcode.Register, value: Data) !void {
    const slot = try self.absoluteRegisterIndex(reg);
    try self.ensureAbsoluteSlot(slot);
    self.currentFiber().registers[slot] = value;
}

/// call when 0 <= slot < slots.len
pub inline fn readRegisterUnsafe(self: *VM, slot: usize) Data {
    return self.currentFiber().registers[slot];
}

/// call when slot is valid and capacity is enough
pub inline fn writeRegisterUnsafe(self: *VM, slot: usize, value: Data) void {
    self.currentFiber().registers[slot] = value;
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
pub inline fn regWrite(slots: []Data, base: usize, reg: opcode.Register, value: Data) void {
    if (builtin.mode != .ReleaseFast) {
        const slot = base + reg;
        if (slot >= slots.len)
            @panic("register write out of bounds; this is a compiler bug, report at https://codeberg.org/lung/revo/issues");
    }
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

//
// stdlib reg
//

/// install a native fn on the heap. name fills the function's name
/// field (stack traces, mt keys)
pub fn installNative(self: *VM, name: []const u8, func: revo.std_lib.NativeFunc) !mem.FunctionID {
    var f = func;
    f.name = name;
    return self.functions.create(.{ .native = f });
}

/// register a function as a global. also records in stdlib_globals so
/// repl reset can replay the same set
pub fn registerGlobal(self: *VM, name: []const u8, fn_id: mem.FunctionID) !void {
    const atom = try self.internAtom(name);
    const val = Data.new.function(fn_id);
    try self.globals.put(atom, val);
    try self.stdlib_globals.put(atom, val);
}

/// get or create a module table and install it as a global
pub fn ensureModule(self: *VM, name: []const u8) !mem.TableID {
    const atom = try self.internAtom(name);
    if (self.globals.get(atom)) |existing| {
        if (existing.asTable()) |tid| return tid;
    }
    const tid = try self.tables.create();
    const val = Data.new.table(tid);
    try self.globals.put(atom, val);
    try self.stdlib_globals.put(atom, val);
    return tid;
}

/// put a function into a table under an interned name
pub fn putInTable(
    self: *VM,
    table_id: mem.TableID,
    name: []const u8,
    fn_id: mem.FunctionID,
) !void {
    const atom = try self.internAtom(name);
    const t = try self.tables.get(table_id);
    try t.putRawAtom(atom, Data.new.function(fn_id));
}

/// same as putInTable but the key is an already-resolved core atom
pub fn putInTableAtom(
    self: *VM,
    table_id: mem.TableID,
    atom: mem.AtomID,
    fn_id: mem.FunctionID,
) !void {
    const t = try self.tables.get(table_id);
    try t.putRawAtom(atom, Data.new.function(fn_id));
}

pub inline fn getGlobal(self: *VM, name: []const u8) ?Data {
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

pub fn spanAtPc(self: *VM, info: *const DebugInfo, pc: ProgramCounter) ?Span {
    _ = self;
    if (pc >= info.spans.len) return null;
    return info.spans[pc];
}

fn frameName(self: *VM, closure_id: ?mem.FunctionID) []const u8 {
    const id = closure_id orelse return "<entry>";
    const func = self.functions.get(id) catch return "<dead>";
    return switch (func.*) {
        .closure => |closure| if (std.mem.eql(u8, closure.name, "__main")) "<module>" else closure.name,
        .native => |f| f.name,
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

/// shorthand for TypeError with "want X, got Y"
pub fn typeError(self: *VM, comptime expected: []const u8, got: mem.Data) EvalFailure {
    const msg = std.fmt.allocPrint(
        self.runtime.alloc,
        "want {s}, got {s}",
        .{ expected, @tagName(got.tag()) },
    ) catch return self.evalFailure(error.TypeError);

    self.setRuntimeMessageOwned(msg);
    return self.evalFailure(error.TypeError);
}

pub fn fail(self: *VM, comptime err: EvalError, comptime fmt: []const u8, args: anytype) EvalFailure {
    const msg = std.fmt.allocPrint(self.runtime.alloc, fmt, args) catch
        return self.evalFailure(err);
    self.setRuntimeMessageOwned(msg);
    return self.evalFailure(err);
}

pub fn currentFrame(self: *VM) !*FrameHot {
    if (self.currentFiber().frames_hot.items.len == 0) return error.FrameUnderflow;
    return &self.currentFiber().frames_hot.items[self.currentFiber().frames_hot.items.len - 1];
}

pub fn currentFrameCold(self: *VM) !*FrameCold {
    const fiber = self.currentFiber();
    if (fiber.frames_hot.items.len == 0) return error.FrameUnderflow;
    const i = fiber.frames_hot.items.len - 1;
    return &fiber.frames_cold.items[i];
}

pub inline fn currentClosure(self: *VM) !?*root.functions.Closure {
    const frame_cold = try self.currentFrameCold();
    const closure_id = frame_cold.closure_id orelse return null;
    const func = try self.functionFast(closure_id);
    return switch (func.*) {
        .closure => |*closure| closure,
        .native, .c_function => null,
    };
}

pub inline fn captureUpvalue(self: *VM, slot_index: usize) !root.functions.UpvalueID {
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
            upvalue.closed = self.currentFiber().registers[slot_index];
            upvalue.open_index = null;
        }
        _ = open.pop();
    }
}

pub inline fn loadUpvalueData(self: *VM, upvalue_id: root.functions.UpvalueID) !Data {
    const upvalue = try self.functions.getUpvalue(upvalue_id);
    if (upvalue.open_index) |slot_index| return self.currentFiber().registers[slot_index];
    return upvalue.closed;
}

pub inline fn storeUpvalueData(self: *VM, upvalue_id: root.functions.UpvalueID, value: Data) !void {
    const upvalue = try self.functions.getUpvalue(upvalue_id);
    if (upvalue.open_index) |slot_index| {
        self.currentFiber().registers[slot_index] = value;
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
    const initial_frame_depth = fiber.frames_hot.items.len;
    const initial_pc = fiber.pc;
    const initial_slot_len = fiber.registers_len;

    // root callee before any allocation that could trigger GC
    try ensureRegCapacity(fiber, self.runtime.alloc, fiber.registers_len + 1);
    fiber.registers[fiber.registers_len] = callee;
    fiber.registers_len += 1;

    if (fiber.frames_hot.items.len == 0) {
        if (fiber.debug_info_id == null)
            fiber.debug_info_id = self.pending_debug_info_id;

        try fiber.frames_hot.append(
            self.runtime.alloc,
            .{ .return_addr = @intCast(fiber.program.len), .base = 0, .program = fiber.program },
        );
        try fiber.frames_cold.append(
            self.runtime.alloc,
            .{ .call_site_pc = null, .result_register = 0, .register_count = 0, .closure_id = null },
        );
    }

    const caller_frame_depth = fiber.frames_hot.items.len;
    const base = (try self.currentFrame()).base;
    const callee_slot = fiber.registers_len - 1;

    errdefer {
        fiber.registers_len = initial_slot_len;
        fiber.pc = initial_pc;
        self.closeUpvalues(initial_slot_len) catch {};
        while (fiber.frames_hot.items.len > initial_frame_depth) {
            _ = fiber.frames_hot.pop();
            _ = fiber.frames_cold.pop();
        }
    }

    // note: callee already rooted at callee_slot above
    // callee_slot points to where we stored it; args start at callee_slot + 1
    if (maybe_first) |first| {
        try ensureRegCapacity(fiber, self.runtime.alloc, fiber.registers_len + 1);
        fiber.registers[fiber.registers_len] = first;
        fiber.registers_len += 1;
    }
    for (args) |arg| {
        try ensureRegCapacity(fiber, self.runtime.alloc, fiber.registers_len + 1);
        fiber.registers[fiber.registers_len] = arg;
        fiber.registers_len += 1;
    }

    const call_reg_usize = callee_slot - base;
    if (call_reg_usize > std.math.maxInt(opcode.Register))
        return error.InvalidBytecode;
    const call_reg: opcode.Register = @intCast(call_reg_usize);

    const argc_usize: usize = args.len + @intFromBool(maybe_first != null);

    const argc: opcode.Register = @intCast(argc_usize);

    try self.callRegister(.{ .op = .call, .a = call_reg, .b = argc, .c = call_reg });

    if (fiber.frames_hot.items.len > caller_frame_depth) {
        if (try self.execFiberUntilDepth(caller_frame_depth)) |_| return error.Panic;
    }

    const result = fiber.registers[callee_slot];
    fiber.registers_len = callee_slot;
    return result;
}

// TODO inline everywhere
pub inline fn callFunction(self: *VM, callee: Data, args: []const Data) EvalError!Data {
    return self.callFunctionParts(callee, null, args);
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

    const hot_frames = self.currentFiber().frames_hot.items;
    const cold_frames = self.currentFiber().frames_cold.items;

    var primary_span = if (info) |debug| self.spanAtPc(debug, current_pc) else null;

    // struct ctor panics originate in generated wrapper code; prefer the user callsite
    if (kind == .Panic and self.panic_message != null) {
        if (self.panic_span) |span| primary_span = span;

        const msg = self.panic_message.?;
        const is_struct_panic =
            std.mem.indexOf(u8, msg, " for struct `") != null or
            (std.mem.indexOf(u8, msg, " on `") != null and
                std.mem.indexOf(u8, msg, " wants ") != null);

        const top_is_non_module = blk: {
            if (hot_frames.len == 0) break :blk false;
            if (cold_frames[hot_frames.len - 1].closure_id) |id| {
                break :blk !std.mem.eql(u8, self.frameName(id), "<module>");
            }
            break :blk false;
        };

        if (is_struct_panic and top_is_non_module and
            cold_frames[hot_frames.len - 1].call_site_pc != null and info != null)
        {
            primary_span = self.spanAtPc(
                info orelse unreachable,
                cold_frames[hot_frames.len - 1].call_site_pc orelse unreachable,
            );
        }
    }

    const message = if (kind == .Panic and self.panic_message != null)
        self.panic_message orelse unreachable
    else if (self.runtime_message) |msg|
        msg
    else
        kind.message();

    var failure = EvalFailure{
        .kind = kind,
        .report = .{
            .message = message,
            .source = if (info) |debug| debug.source else null,
            .source_name = if (info) |debug| debug.source_name else null,
        },
    };

    var out_idx: usize = 0;
    var i = hot_frames.len;
    while (i > 0 and
        out_idx < EvalFailure.max_trace_frames)
    {
        i -= 1;
        const frame = cold_frames[i];
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
                if (i == hot_frames.len - 1)
                    self.spanAtPc(debug, current_pc)
                else if (frame.call_site_pc) |pc|
                    self.spanAtPc(debug, pc)
                else
                    null
            else
                null,
            .pc = if (i == hot_frames.len - 1)
                current_pc
            else
                frame.call_site_pc,
        };
        out_idx += 1;
    }
    failure.trace_len = out_idx;
    failure.part_len = 2 + out_idx;
    failure.parts[0] = revo.lang.diagnostic.Part{ .@"error" = message };
    failure.parts[1] = .{ .span = .{
        .span = primary_span orelse .{ .start = 0, .end = 0, .line = 1, .column = 1 },
        .role = .primary,
    } };
    for (failure.trace[0..out_idx], 0..) |frame, idx| {
        failure.parts[2 + idx] = .{ .trace = frame };
    }
    failure.report.parts = failure.parts[0..failure.part_len];
    return failure;
}

pub inline fn getMetamethodByAtom(
    self: *VM,
    val: Data,
    atom: mem.AtomID,
) !?Data {
    const mt_id = try self.getMetatableId(val) orelse return null;
    const mt = try self.tables.get(mt_id);
    return mt.getRawAtom(atom);
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
    InvalidTuple,
    OutOfMemory,
    ConstantReassignment,
} || root.functions.NativeError;

pub inline fn tableFast(
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
    return self.functions.get(id) catch |e| {
        if (e == error.FunctionDNE) {
            try self.setPanicMessage("function does not exist");
            return error.Panic;
        }
        return e;
    };
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
            self.host_call_depth += 1;
            defer self.host_call_depth -= 1;
            const args_start = callee_slot + 1;
            const args_end = args_start + argc;
            try self.ensureAbsoluteSlot(args_end);
            const args = fiber.registers[args_start..args_end];

            var c_args_buf: [16]root.functions.CRevoData = undefined;
            const c_args = if (args.len <= 16)
                c_args_buf[0..args.len]
            else
                try self.runtime.alloc.alloc(root.functions.CRevoData, args.len);
            defer if (args.len > 16) self.runtime.alloc.free(c_args);

            for (args, 0..) |arg, i|
                c_args[i] = root.functions.CRevoData.fromData(arg);

            var c_result: root.functions.CRevoData = .{
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
            const args = fiber.registers[args_start..args_end];

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
                    "fn `{s}` wants {d} args({s}), got {d}",
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
                        "arg #{d}: want {s}, got {s}",
                        .{
                            i,
                            @tagName(spec),
                            revo.std_lib.dataToString(args[i]),
                        },
                    );
                    return error.TypeError;
                }
            }

            const result = f.func(args, self) catch |err| switch (err) {
                error.OutOfMemory => {
                    if (self.runtime_message == null)
                        try self.setRuntimeMessage(@errorName(err));
                    return error.Panic;
                },
                else => {
                    const tag = try self.internAtom(@errorName(err));
                    const items = [_]Data{
                        Data.new.atom(revo.core_atoms.atom_id(.err)),
                        Data.new.atom(tag),
                    };
                    const data = Data.new.tuple(try self.tuples.create(&items));
                    try self.ensureAbsoluteSlot(base + instr.c);
                    try self.writeRegisterFast(base, instr.c, data);
                    return;
                },
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
                                "function `{s}` wants {d} args, got {d}",
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
                                    "arg {d}: wants {s}, got {s}",
                                    .{
                                        arg,
                                        info.expected,
                                        info.got,
                                    },
                                );
                            } else {
                                try self.setRuntimeMessageFmt(
                                    "wants {s}, got {s}",
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

fn fillOptionalSlots(regs: []Data, base: usize, argc: usize, total_arity: u8, register_count: u8) void {
    if (argc < total_arity) {
        @memset(
            regs[base + argc .. base + total_arity],
            revo.core_atoms.data(.no),
        );
    }
    if (total_arity < register_count) {
        @memset(
            regs[base + total_arity .. base + register_count],
            revo.core_atoms.data(.missing),
        );
    }
}

pub fn callRegister(
    self: *VM,
    instr: Instruction,
) EvalError!void {
    const fiber = self.currentFiber();
    const frame = try self.currentFrame();
    const base = frame.base;
    const callee_slot = base + instr.a;
    const argc: usize = instr.b;

    const callee = if (callee_slot < fiber.registers_len)
        fiber.registers[callee_slot]
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
                    (argc < closure.arity or argc > closure.total_arity))
                {
                    @branchHint(.unlikely);
                    if (closure.arity == closure.total_arity) {
                        try self.setRuntimeMessageFmt(
                            "function `{s}` wants {d} args, got {d}",
                            .{ closure.name, closure.arity, argc },
                        );
                    } else {
                        try self.setRuntimeMessageFmt(
                            "function `{s}` wants between {d} and {d} args, got {d}",
                            .{ closure.name, closure.arity, closure.total_arity, argc },
                        );
                    }
                    return error.WrongArity;
                }

                if (self.host_call_depth == 0 and
                    fiber.pc < fiber.program.len and
                    fiber.program[fiber.pc].op == .ret)
                {
                    @branchHint(.unlikely);
                    const tail_frame_hot = try self.currentFrame();
                    const tail_frame_cold = try self.currentFrameCold();
                    if (tail_frame_cold.closure_id != null and
                        tail_frame_hot.base > 0)
                    {
                        const caller_fn_slot =
                            tail_frame_hot.base - 1;
                        const moved_len = argc + 1;

                        try self.closeUpvalues(
                            tail_frame_hot.base,
                        );

                        if (callee_slot != caller_fn_slot) {
                            std.mem.copyForwards(
                                Data,
                                fiber.registers[caller_fn_slot .. caller_fn_slot + moved_len],
                                fiber.registers[callee_slot .. callee_slot + moved_len],
                            );
                        }

                        tail_frame_hot.base = caller_fn_slot + 1;
                        tail_frame_cold.call_site_pc = if (fiber.pc > 0) fiber.pc - 1 else 0;
                        tail_frame_cold.closure_id = closure_id;
                        tail_frame_cold.register_count = closure.register_count;

                        const tail_needed = tail_frame_hot.base +
                            closure.register_count;
                        if (tail_needed > fiber.registers_len) {
                            try ensureRegCapacity(fiber, self.runtime.alloc, tail_needed);
                            fiber.registers_len = tail_needed;
                        }
                        fillOptionalSlots(
                            fiber.registers,
                            tail_frame_hot.base,
                            argc,
                            closure.total_arity,
                            closure.register_count,
                        );

                        if (self.functions.segments.items.len > closure.segment_id) {
                            fiber.program = self.functions.segments.items[closure.segment_id];
                        }
                        fiber.pc = closure.addr;
                        return;
                    }
                }

                const new_base = callee_slot + 1;
                const call_needed = new_base + closure.register_count;
                if (call_needed > fiber.registers_len) {
                    try ensureRegCapacity(fiber, self.runtime.alloc, call_needed);
                    fiber.registers_len = call_needed;
                }
                fillOptionalSlots(
                    fiber.registers,
                    new_base,
                    argc,
                    closure.total_arity,
                    closure.register_count,
                );

                try fiber.frames_hot.append(
                    self.runtime.alloc,
                    .{
                        .return_addr = fiber.pc,
                        .base = new_base,
                        .program = fiber.program,
                    },
                );
                try fiber.frames_cold.append(
                    self.runtime.alloc,
                    .{
                        .call_site_pc = if (fiber.pc > 0) fiber.pc - 1 else 0,
                        .result_register = instr.c,
                        .register_count = closure.register_count,
                        .closure_id = closure_id,
                    },
                );
                if (self.functions.segments.items.len > closure.segment_id) {
                    fiber.program = self.functions.segments.items[closure.segment_id];
                }
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
            const args_start = callee_slot + 1;
            const args_end = args_start + argc;
            try self.ensureAbsoluteSlot(args_end);
            const args = fiber.registers[args_start..args_end];
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
        const init_data = fiber.registers[callee_slot + 1];
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
        var cur = init_table.hash.first;
        while (cur != root.table.NULL_ID) {
            const k = init_table.hash.buckets[cur].key;
            const k_atom = k.asAtom() orelse {
                cur = init_table.hash.buckets[cur].next;
                continue;
            };
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
            cur = init_table.hash.buckets[cur].next;
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
                    "field `{s}` on `{s}` wants {s}, got {s}",
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
    _: *VM,
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
    for (&[_]revo.core_atoms{ .num, .number, .int, .integer, .float }) |at| {
        if (expected_atom == at.atom_id())
            return value.isNumber();
    }
    // some amount of work is done at compile-time to ignore complex types
    return true;
}

pub fn setStructField(
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
                "field `{s}` on `{s}` wants {s}, got {s}",
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

pub fn structGetInstance(
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

pub fn returnRegister(
    self: *VM,
    instr: Instruction,
) EvalError!void {
    const fiber = self.currentFiber();
    const result = regRead(
        fiber.registers,
        fiber.frames_hot.items[
            fiber.frames_hot.items.len - 1
        ].base,
        instr.a,
    );
    const frame_hot = fiber.frames_hot.pop() orelse unreachable;
    const frame_cold = fiber.frames_cold.pop() orelse unreachable;

    if (fiber.open_upvalues.items.len > 0)
        try self.closeUpvalues(frame_hot.base);

    fiber.pc = frame_hot.return_addr;
    fiber.program = frame_hot.program;

    // check if returning to exit frame
    // 0 or 1 frames left after pop means we're exiting (or at) module level
    const returning_to_exit =
        self.sched.current_fiber == 0 and
        fiber.frames_hot.items.len <= 1;

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

    if (fiber.frames_hot.items.len == 0 or
        fiber.pc >= fiber.program.len)
    {
        const finished_id = self.sched.current_fiber;
        try self.sched.finishFiber(finished_id, result);
        if (finished_id == 0) {
            fiber.registers_len = 0;
            try self.push(result);
        }
        return;
    }

    const parent_hot = try self.currentFrame();
    const parent_cold = try self.currentFrameCold();
    const result_slot = parent_hot.base +
        frame_cold.result_register;
    const parent_end = parent_hot.base +
        parent_cold.register_count;
    fiber.registers_len = @max(result_slot + 1, parent_end);
    fiber.registers[result_slot] = result;
}

pub inline fn spawnRegister(
    self: *VM,
    instr: Instruction,
    base: usize,
) EvalError!void {
    const argc: usize = instr.b;
    const fiber = self.currentFiber();
    const callee = regRead(fiber.registers, base, instr.a);
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
        (argc < closure.arity or argc > closure.total_arity))
    {
        @branchHint(.unlikely);
        try self.setRuntimeMessageFmt(
            "fiber closure `{s}` wants between {d} and {d} args, got {d}",
            .{ closure.name, closure.arity, closure.total_arity, argc },
        );
        return error.WrongArity;
    }

    const child_id: FiberID = self.sched.fibers.items.len;
    const child_program = if (self.functions.segments.items.len > closure.segment_id)
        self.functions.segments.items[closure.segment_id]
    else
        fiber.program;
    var child = try Fiber.init(self.runtime.alloc, child_id, child_program, closure.register_count);
    errdefer child.deinit(self.runtime.alloc);
    child.debug_info_id = fiber.debug_info_id;
    child.state = .ready;

    if (closure.register_count > child.registers.len)
        child.registers = try self.runtime.alloc.realloc(child.registers, closure.register_count);
    child.registers_len = closure.register_count;
    @memset(child.registers[0..closure.register_count], revo.core_atoms.data(.missing));

    for (0..argc) |idx| {
        // this is safe
        const src_reg = instr.a + 1 + @as(opcode.Register, @intCast(idx));
        const src_slot = base + src_reg;
        child.registers[idx] = if (src_slot < fiber.registers_len)
            fiber.registers[src_slot]
        else
            revo.core_atoms.data(.missing);
    }

    fillOptionalSlots(
        child.registers,
        0,
        argc,
        closure.total_arity,
        closure.register_count,
    );

    const child_closure_id = try self.detachClosureForFiber(
        closure_id,
    );
    try child.frames_hot.append(self.runtime.alloc, .{
        .return_addr = @intCast(child.program.len),
        .base = 0,
        .program = child.program,
    });
    try child.frames_cold.append(self.runtime.alloc, .{
        .call_site_pc = null,
        .result_register = 0,
        .register_count = closure.register_count,
        .closure_id = child_closure_id,
    });
    child.pc = closure.addr;

    try self.sched.fibers.append(self.runtime.alloc, child);
    try self.sched.enqueueRunnable(child_id);
    const result_slot = base + instr.c;
    // re-acquire fiber pointer bc append above may have reallocated
    const cur = self.currentFiber();
    if (result_slot >= cur.registers_len) {
        try ensureRegCapacity(cur, self.runtime.alloc, result_slot + 1);
        cur.registers_len = result_slot + 1;
    }
    cur.registers[result_slot] = Data.new.num(@as(i64, @intCast(child_id)));
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
pub const compare = compare_impl.compare;
const root = @import("root.zig");
pub const EvalErrorKind = root.debug.EvalErrorKind;
pub const EvalFailure = root.debug.EvalFailure;
pub const EvalResult = root.debug.EvalResult;
const FrameHot = root.functions.FrameHot;
const FrameCold = root.functions.FrameCold;
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
const execFiberUntilDepth = vm_exec.execFiberUntilDepth;
const vm_gc = @import("gc.zig");
