pub const INITIAL_HOT_FRAMES = 16;
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

// main loop: run runnable fibers, wake sleepers
// wait for io/timers if needed

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
    frames: std.ArrayList(Frame),
    /// cached base of the top frame; the dispatch loop reads this instead of
    /// indexing frames[frames.len-1] on every call/ret. kept in sync at every
    /// frame push/pop site
    top_base: usize = 0,
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
        const registers = try alloc.alloc(Data, reg_count);
        errdefer alloc.free(registers);
        var frames = try std.ArrayList(Frame).initCapacity(alloc, INITIAL_HOT_FRAMES);
        errdefer frames.deinit(alloc);
        var open_upvalues = try std.ArrayList(OpenUpvalueRef).initCapacity(alloc, 1);
        errdefer open_upvalues.deinit(alloc);
        var waiters = try std.ArrayList(FiberID).initCapacity(alloc, 1);
        errdefer waiters.deinit(alloc);
        const self = Fiber{
            .id = id,
            .pc = 0,
            .program = program,
            .debug_info_id = null,
            .registers = registers,
            .frames = frames,
            .open_upvalues = open_upvalues,
            .running = false,
            .state = .ready,
            .in_runq = false,
            .wait = .none,
            .parked_result_slot = null,
            .waiters = waiters,
            .result = revo.Data.new.core(.nil),
        };

        return self;
    }

    pub fn deinit(self: *Fiber, alloc: std.mem.Allocator) void {
        alloc.free(self.registers);
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

constants: std.ArrayList(Data),
stdlib_globals: Globals,
/// iface specs loaded at init; released by `deinit` through `api.freeLoadedSpecs`
loaded_specs: []const []const revo.std_lib.api.FnSpec = &.{},
tables: TablePool,
functions: FunctionPool,
strings: Interner,
atoms: std.StringHashMap(mem.AtomID),
debug: DebugOptions = .{},
globals: Globals,
const_globals: ConstGlobals,
module_dir: ?[]const u8,
project_root: []const u8 = "",
loading_stack: std.ArrayList([]const u8),

/// indexed by @intFromEnum(mem.Type); tags are non-contiguous (0, 8-13)
metatables: [
    @as(usize, @intFromEnum(memory.Type.foreign)) + 1
]?mem.TableID = @splat(null),
module_cache: ModuleCache,
package_path: std.ArrayList([]const u8),
debug_infos: std.ArrayList(DebugInfo),
pending_debug_info_id: ?DebugInfoID = null,
panic_message: ?[]const u8 = null,
panic_span: ?Span = null,
runtime_message: ?[]const u8 = null,
gc_check_counter: usize = 0,
host_call_depth: usize = 0,
loaded_extensions: std.ArrayList(std.DynLib),
c_data: ?*anyopaque = null,
gc_enabled: bool = true,
gc_pending: bool = false,
gc_bytes_allocated: usize = 0,

// optional opcode counters for benchmarking/profiling
// allocated on init
gc_threshold: usize = 512 * 1024, // 512kb initial
gc_pause_factor: usize = 4,
// upper bound on the collection trigger; keeps the heap from growing
// without bound while avoiding pathological full collections on
// allocation-heavy, small-live workloads (bench/storage.rv collected
// every ~64kb, spending ~90% of its time in the GC)
gc_nursery_threshold: usize = 8 * 1024 * 1024,

gc_mark_stack: std.ArrayList(MarkItem),
gc_finalizers: std.AutoHashMap(mem.TableID, Data),
gc_in_finalizer: bool = false,

const MarkItem = union(enum) {
    data: Data,
    table: mem.TableID,
    function: mem.FunctionID,
    upvalue: root.functions.UpvalueID,
};

pub fn init(runtime: revo.Runtime) !VM {
    var rt = runtime;
    rt.diag_arena = null;
    try rt.ensureDiagArena();
    errdefer rt.deinitDiagArena();
    var sched = try Scheduler.init(rt.alloc);
    errdefer sched.deinit();
    var constants = try std.ArrayList(Data).initCapacity(rt.alloc, 16);
    errdefer constants.deinit(rt.alloc);
    var tables = try TablePool.init(rt.alloc);
    errdefer tables.deinit();
    var functions = try FunctionPool.init(rt.alloc);
    errdefer functions.deinit();
    var strings = try Interner.init(rt.alloc);
    errdefer strings.deinit();
    var package_path = try std.ArrayList([]const u8).initCapacity(rt.alloc, 4);
    errdefer package_path.deinit(rt.alloc);
    var debug_infos = try std.ArrayList(DebugInfo).initCapacity(rt.alloc, 8);
    errdefer debug_infos.deinit(rt.alloc);
    var loading_stack = try std.ArrayList([]const u8).initCapacity(rt.alloc, 1);
    errdefer loading_stack.deinit(rt.alloc);
    var gc_mark_stack = try std.ArrayList(MarkItem).initCapacity(rt.alloc, 256);
    errdefer gc_mark_stack.deinit(rt.alloc);
    var vm: VM = .{
        .runtime = rt,
        .sched = sched,
        .constants = constants,
        .stdlib_globals = Globals.init(rt.alloc),
        .tables = tables,
        .functions = functions,
        .strings = strings,
        .atoms = std.StringHashMap(mem.AtomID).init(rt.alloc),
        .module_cache = ModuleCache.init(rt.alloc),
        .package_path = package_path,
        .debug_infos = debug_infos,
        .globals = Globals.init(rt.alloc),
        .const_globals = ConstGlobals.init(rt.alloc),
        .module_dir = null,
        .loaded_specs = &.{},
        .loading_stack = loading_stack,
        .loaded_extensions = .empty,
        .gc_mark_stack = gc_mark_stack,
        .gc_finalizers = std.AutoHashMap(mem.TableID, Data).init(rt.alloc),
    };
    try revo.async_backend_impl.init(&vm.runtime.async_backend);
    errdefer revo.async_backend_impl.deinit(&vm.runtime.async_backend);

    try vm.package_path.appendSlice(rt.alloc, &.{ "./?", "./lib/?", "/usr/local/lib/revo/?" });

    try vm.sched.fibers.append(rt.alloc, .{
        .id = 0,
        .pc = 0,
        .program = &.{},
        .debug_info_id = null,
        .registers = try runtime.alloc.alloc(Data, INIT_REG_COUNT),
        .frames = try std.ArrayList(Frame).initCapacity(runtime.alloc, INITIAL_HOT_FRAMES),
        .running = false,
        .open_upvalues = try std.ArrayList(Fiber.OpenUpvalueRef).initCapacity(runtime.alloc, 1),
        .state = .ready,
        .in_runq = false,
        .wait = .none,
        .parked_result_slot = null,
        .waiters = try std.ArrayList(FiberID).initCapacity(runtime.alloc, 1),
    });

    // set initial fiber result to no_result
    // after core atoms are initialized
    vm.sched.fibers.items[0].result = revo.Data.new.core(.no_result);

    try revo.std_lib.register_stdlib(&vm);
    try revo.lang.proc.register(&vm);

    return vm;
}

//
// probably shouldnt be here but its fine
//
pub const maybeCollectGarbage = vm_gc.maybeCollectGarbage;
pub const noteGCPressure = vm_gc.noteGCPressure;
pub const pushMarkTable = vm_gc.pushMarkTable;
pub const pushMarkFunction = vm_gc.pushMarkFunction;
pub const pushMarkUpvalue = vm_gc.pushMarkUpvalue;

pub fn deinit(self: *VM) void {
    self.clearProgramDebugInfo();
    self.clearPanicMessage();
    self.clearRuntimeMessage();
    revo.async_backend_impl.deinit(&self.runtime.async_backend);
    self.constants.deinit(self.runtime.alloc);
    self.globals.deinit();
    self.const_globals.deinit();
    self.stdlib_globals.deinit();
    revo.std_lib.api.freeLoadedSpecs(self.runtime.alloc, self.loaded_specs);

    for (self.loading_stack.items) |path|
        self.runtime.alloc.free(path);
    self.loading_stack.deinit(self.runtime.alloc);

    // run pending gc finalizers while scheduler + pools are alive
    {
        var it = self.gc_finalizers.iterator();
        while (it.next()) |entry| {
            const id = entry.key_ptr.*;
            const func = entry.value_ptr.*;
            if (id < self.tables.tables.items.len) {
                if (self.tables.tables.items[id] != null) {
                    _ = self.callFunctionParts(func, null, &.{Data.new.table(id)}, null) catch {};
                }
            }
        }
    }
    self.gc_finalizers.deinit();
    self.sched.deinit();
    self.tables.deinit();
    self.functions.deinit();
    self.strings.deinit();
    self.atoms.deinit();

    for (self.debug_infos.items) |info| {
        self.runtime.alloc.free(info.spans);
        self.runtime.alloc.free(info.source);
        self.runtime.alloc.free(info.source_name);
    }
    self.debug_infos.deinit(self.runtime.alloc);
    self.package_path.deinit(self.runtime.alloc);
    if (self.project_root.len > 0) self.runtime.alloc.free(self.project_root);

    var cache_it = self.module_cache.keyIterator();
    while (cache_it.next()) |key|
        self.runtime.alloc.free(key.*);

    self.module_cache.deinit();

    if (!revo.is_freestanding) {
        for (self.loaded_extensions.items) |*lib| {
            if (builtin.target.os.tag != .windows and builtin.target.os.tag != .wasi)
                lib.close();
        }
    }
    self.loaded_extensions.deinit(self.runtime.alloc);
    self.gc_mark_stack.deinit(self.runtime.alloc);
    self.runtime.deinitDiagArena();
}

pub fn registerFinalizer(self: *VM, table_id: mem.TableID, func: Data) !void {
    try self.gc_finalizers.put(table_id, func);
}

pub fn unregisterFinalizer(self: *VM, table_id: mem.TableID) void {
    _ = self.gc_finalizers.remove(table_id);
}

pub fn moduleStamp(self: *VM, path: []const u8) !ModuleStamp {
    const stat = try std.Io.Dir.cwd().statFile(self.runtime.io, path, .{});
    return .{
        .mtime = @intCast(stat.mtime.toNanoseconds()),
        .size = @intCast(stat.size),
    };
}

pub fn invalidateModuleCache(self: *VM, path: []const u8) bool {
    if (self.module_cache.fetchRemove(path)) |entry| {
        self.runtime.alloc.free(entry.key);
        return true;
    }
    return false;
}

pub fn addConstant(self: *VM, val: Data) !ConstantID {
    const idx: ConstantID = @intCast(self.constants.items.len);
    try self.constants.append(self.runtime.alloc, val);
    return idx;
}

//
// data creation helpers
//

// TODO: make a pools field, move all pools there
/// dupes yours
pub fn ownDataString(self: *VM, value: []const u8) !Data {
    return Data.new.str(try self.strings.own(value));
}

/// kills yours
pub fn adoptDataString(self: *VM, value: []u8) !Data {
    return Data.new.str(try self.strings.adopt(value));
}

pub fn adoptDataStringNoDedup(self: *VM, value: []u8) !Data {
    return Data.new.str(try self.strings.adoptNoDedup(value));
}

pub fn ownDataStringNoDedup(self: *VM, value: []const u8) !Data {
    return Data.new.str(try self.strings.ownNoDedup(value));
}

pub fn stringValue(self: *VM, id: mem.StringID) []const u8 {
    return self.strings.get(id) catch {
        std.debug.print("id: {any};\n", .{id});
        @panic("tried to get dead string value");
    };
}

/// single-shot array table from items
/// ; no calls happen between create and fill
/// so callers must pass a side buffer, never pool-borrowed memory
pub fn tableOfSlice(self: *VM, val: []const Data) !Data {
    const id = try self.tables.create();
    const ptr = try self.tables.get(id);
    try ptr.array.appendSlice(ptr.alloc, val);
    return Data.new.table(id);
}

/// `{:tag, payload}` result table, the `{:ok, v}` / `{:err, e}` shape
pub fn resultTable(self: *VM, tag: revo.core_atoms, payload: Data) !Data {
    return self.tableOfSlice(&[_]Data{
        Data.new.atom(tag.atomId()),
        payload,
    });
}

/// split of a `{:tag, ...}` table: tag in [0], payload in [1] when present
pub const ResultParts = struct { tag: Data, payload: ?Data, len: usize };
pub fn resultParts(self: *VM, val: Data) ?ResultParts {
    const tid = val.asTable() orelse return null;
    const t = self.tables.get(tid) catch return null;
    if (t.array.items.len == 0) return null;
    return .{
        .tag = t.array.items[0],
        .payload = if (t.array.items.len > 1) t.array.items[1] else null,
        .len = t.array.items.len,
    };
}

/// `:err` table check, for `?`, `orelse`, jumps, `try`
pub fn isErrTable(self: *VM, val: Data) bool {
    const parts = self.resultParts(val) orelse return false;
    const atom = parts.tag.asAtom() orelse return false;
    return atom == revo.core_atoms.atomId(.err);
}

/// `:ok` table check, pairs `isErrTable`
pub fn isOkTable(self: *VM, val: Data) bool {
    const parts = self.resultParts(val) orelse return false;
    const atom = parts.tag.asAtom() orelse return false;
    return atom == revo.core_atoms.atomId(.ok);
}

/// named-field write without the intern dance
pub fn putField(self: *VM, tid: mem.TableID, name: []const u8, val: Data) !void {
    const t = try self.tables.get(tid);
    try t.putRawAtom(try self.internAtom(name), val, self);
}

/// named-field raw read, null when missing or not a table
/// never interns, so core names resolve even if nothing interned them yet
pub fn getField(self: *VM, val: Data, name: []const u8) ?Data {
    const tid = val.asTable() orelse return null;
    const t = self.tables.get(tid) catch return null;
    const id = self.atoms.get(name) orelse self.strings.lookup(name) orelse return null;
    return t.getRawAtom(id, self);
}

/// remove a named field, false when missing or not a table
pub fn removeField(self: *VM, val: Data, name: []const u8) bool {
    const tid = val.asTable() orelse return false;
    const t = self.tables.get(tid) catch return false;
    const id = self.atoms.get(name) orelse self.strings.lookup(name) orelse return false;
    return t.remove(Data.new.atom(id), self);
}

/// array-part read with bounds check, null when out of range
pub fn arrayGet(self: *VM, tid: mem.TableID, idx: usize) ?Data {
    const t = self.tables.get(tid) catch return null;
    if (idx >= t.array.items.len) return null;
    return t.array.items[idx];
}

/// deep copy of a table: array part in order, then keyed entries
pub fn copyTable(self: *VM, src: mem.TableID) !Data {
    const s = try self.tables.get(src);
    const id = try self.tables.create();
    const d = try self.tables.get(id);

    try d.array.appendSlice(d.alloc, s.array.items);
    var it = s.hash.orderedIterator();

    while (it.next()) |entry|
        try d.putRaw(entry.key, entry.value, self);
    return Data.new.table(id);
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
    @memset(fiber.registers[old_len .. slot + 1], revo.Data.new.core(.missing));
    fiber.registers_len = slot + 1;
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
            return revo.Data.new.core(.missing);
    }
    return slots[base + reg];
}

/// register write using a cached slots pointer (avoids currentFiber call)
pub inline fn regWrite(slots: []Data, base: usize, reg: opcode.Register, value: Data) void {
    if (builtin.mode != .ReleaseFast) {
        const slot = base + reg;
        if (slot >= slots.len)
            @panic("register write out of bounds; this is a compiler bug, report at " ++
                "https://codeberg.org/lung/revo/issues");
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

pub fn dataAtom(self: *VM, name: []const u8) !Data {
    return Data.new.atom(try self.internAtom(name));
}

pub fn setGlobal(self: *VM, name: []const u8, val: Data) !void {
    const id = try self.internAtom(name);
    try self.globals.put(id, val);
}

//
// stdlib reg
//

/// install a Host fn on the heap. name fills the function's name
/// field (stack traces, mt keys)
pub fn installHost(self: *VM, name: []const u8, func: revo.std_lib.HostFunc) !mem.FunctionID {
    var f = func;
    f.name = name;
    return self.functions.create(.{ .host = f });
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

/// put a function into a table under an already-resolved core atom
pub fn putInTable(
    self: *VM,
    table_id: mem.TableID,
    atom: mem.AtomID,
    fn_id: mem.FunctionID,
) !void {
    const t = try self.tables.get(table_id);
    try t.putRawAtom(atom, Data.new.function(fn_id), self);
}

pub inline fn getGlobal(self: *VM, name: []const u8) ?Data {
    if (self.atoms.get(name)) |id| return self.globals.get(id);
    return revo.Data.new.core(.undef);
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
        .host => |f| f.name,
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

/// set the panic message + source span from an `:err` table's message
/// item (payload, skipped when absent); `pc` points one past the instruction
/// that produced the error
pub fn panicFromErrPayload(self: *VM, payload: ?Data, pc: usize) error{ OutOfMemory, Panic }!void {
    if (payload) |p| {
        var buf = std.Io.Writer.Allocating.init(self.runtime.alloc);
        defer buf.deinit();
        p.write(&buf.writer, self, .pretty) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Panic,
        };
        self.setPanicMessageOwned(try buf.toOwnedSlice());
    }
    self.panic_span = if (self.currentDebugInfo()) |debug|
        self.spanAtPc(debug, if (pc > 0) pc - 1 else 0)
    else
        null;
}

/// push the root call frame of a bare (frame-less) fiber: it runs the whole
/// program and returns at the end; caller keeps ownership of register setup
pub fn pushRootFrame(self: *VM, fiber: *Fiber, register_count: u8) !void {
    if (fiber.frames.items.len != 0) return;
    if (fiber.debug_info_id == null)
        fiber.debug_info_id = self.pending_debug_info_id;
    try fiber.frames.append(self.runtime.alloc, .{
        .return_addr = @intCast(fiber.program.len),
        .base = 0,
        .program = fiber.program,
        .call_site_pc = null,
        .result_register = 0,
        .register_count = register_count,
        .closure_id = null,
    });
    fiber.top_base = 0;
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

pub fn currentFrame(self: *VM) !*Frame {
    if (self.currentFiber().frames.items.len == 0) return error.FrameUnderflow;
    return &self.currentFiber().frames.items[self.currentFiber().frames.items.len - 1];
}

pub inline fn currentClosure(self: *VM) !?*root.functions.Closure {
    const frame = try self.currentFrame();
    const closure_id = frame.closure_id orelse return null;
    const func = try self.functionFast(closure_id);
    return switch (func.*) {
        .closure => |*closure| closure,
        .host, .c_function => null,
    };
}

pub inline fn captureUpvalue(self: *VM, slot_index: usize) !root.functions.UpvalueID {
    const fiber = self.currentFiber();
    const open = &fiber.open_upvalues;
    for (open.items, 0..) |entry, idx| {
        if (entry.slot_index == slot_index) return entry.id;
        if (entry.slot_index > slot_index) {
            const upvalue_id = try self.functions.createUpvalue(.{
                .open_index = slot_index,
                .closed = revo.Data.new.core(.missing),
                .owner_fiber_id = fiber.id,
            });
            try open.insert(self.runtime.alloc, idx, .{ .slot_index = slot_index, .id = upvalue_id });
            return upvalue_id;
        }
    }
    const upvalue_id = try self.functions.createUpvalue(.{
        .open_index = slot_index,
        .closed = revo.Data.new.core(.missing),
        .owner_fiber_id = fiber.id,
    });
    try open.append(self.runtime.alloc, .{ .slot_index = slot_index, .id = upvalue_id });
    return upvalue_id;
}

fn closeUpvalues(self: *VM, from_index: usize) !void {
    try self.closeUpvalueList(self.currentFiber(), from_index);
}

/// close every open upvalue in `fiber`'s list with slot >= from_index,
/// snapshotting the register value into `closed` so the upvalue no longer
/// depends on the fiber's register buffer (which may be freed or reused)
pub fn closeUpvalueList(self: *VM, fiber: *Fiber, from_index: usize) !void {
    const open = &fiber.open_upvalues;
    while (open.items.len > 0) {
        const last_idx = open.items.len - 1;
        const entry = open.items[last_idx];
        if (entry.slot_index < from_index) break;

        const upvalue = try self.functions.getUpvalue(entry.id);
        if (upvalue.open_index) |slot_index| {
            upvalue.closed = fiber.registers[slot_index];
            upvalue.open_index = null;
        }
        _ = open.pop();
    }
}

pub inline fn loadUpvalueData(self: *VM, upvalue_id: root.functions.UpvalueID) !Data {
    const upvalue = try self.functions.getUpvalue(upvalue_id);
    if (upvalue.open_index) |slot_index| {
        const fid = upvalue.owner_fiber_id orelse return upvalue.closed;
        return self.sched.fibers.items[fid].registers[slot_index];
    }
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
        .host, .c_function => return closure_id,
    };

    if (closure.sharable_upvalues) return closure_id;

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
                .owner_fiber_id = null,
            }),
        );
    }

    return self.functions.createClosure(closure.prototype, detached.items);
}

/// `result_reg` is a register (relative to the caller frame's base) where a
/// parked callee's eventual result should land. host callers that consume the
/// value through dispatch instructions (index, concat, call) pass the
/// instruction's result register so a park mid-callee resumes with the value
/// in place; callers that discard or consume the result directly pass null.
pub fn callFunctionParts(self: *VM, callee: Data, maybe_first: ?Data, args: []const Data, result_reg: ?opcode.Register) EvalError!Data {
    self.host_call_depth += 1;
    defer self.host_call_depth -= 1;

    const fiber = self.currentFiber();
    const initial_frame_depth = fiber.frames.items.len;
    const initial_pc = fiber.pc;
    const initial_slot_len = fiber.registers_len;

    // root callee before any allocation that could trigger GC
    try ensureRegCapacity(fiber, self.runtime.alloc, fiber.registers_len + 1);
    fiber.registers[fiber.registers_len] = callee;
    fiber.registers_len += 1;

    try self.pushRootFrame(fiber, 0);

    const caller_frame_depth = fiber.frames.items.len;
    const base = fiber.top_base;
    const callee_slot = fiber.registers_len - 1;

    // on error.Parked the fiber suspends mid-callee: frames, registers, and
    // pc must survive so the io waiter can resume the callee where it
    // stopped. every other error unwinds back to the caller state.
    const unwind = struct {
        fn go(
            v: *VM,
            f: *Fiber,
            slot_len: usize,
            pc: usize,
            frame_depth: usize,
        ) void {
            f.registers_len = slot_len;
            f.pc = pc;
            v.closeUpvalues(slot_len) catch {};
            while (f.frames.items.len > frame_depth) {
                _ = f.frames.pop();
            }
            f.top_base = if (f.frames.items.len == 0)
                0
            else
                f.frames.items[f.frames.items.len - 1].base;
        }
    }.go;

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

    self.callRegister(.{ .op = .call, .a = call_reg, .b = argc, .c = call_reg }) catch |e| {
        if (e == error.Parked) {
            self.rerouteParked(fiber, base, caller_frame_depth, result_reg);
            return e;
        }
        unwind(self, fiber, initial_slot_len, initial_pc, initial_frame_depth);
        return e;
    };

    if (fiber.frames.items.len > caller_frame_depth) {
        const exec_result = vm_exec.execFiberUntilDepth(self, caller_frame_depth) catch |e| {
            if (e == error.Parked) {
                self.rerouteParked(fiber, base, caller_frame_depth, result_reg);
                return e;
            }
            unwind(self, fiber, initial_slot_len, initial_pc, initial_frame_depth);
            return e;
        };
        if (exec_result) |_| return error.Panic;
    }

    const result = fiber.registers[callee_slot];
    fiber.registers_len = callee_slot;
    return result;
}

/// reroute a parked callee's wake-up or ret to a dispatch result register.
/// the callee's closure frame (if any) is still on the fiber, so its eventual
/// ret writes through the frame's result_register; a Host callee wrote
/// parked_result_slot at park time and wakeFiber fills it on completion
fn rerouteParked(self: *VM, fiber: *Fiber, base: usize, caller_frame_depth: usize, result_reg: ?opcode.Register) void {
    _ = self;
    const rr = result_reg orelse return;
    if (fiber.frames.items.len > caller_frame_depth) {
        fiber.frames.items[fiber.frames.items.len - 1].result_register = rr;
    } else {
        fiber.parked_result_slot = base + rr;
    }
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

    if (kind == .Panic and self.panic_message != null) {
        if (self.panic_span) |span| primary_span = span;
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
    return mt.getRawAtom(atom, self);
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
    ShiftAmountOutOfRange,
    UndefinedVariable,
    NotAFunction,
    WrongArity,
    FrameUnderflow,
    InvalidBytecode,
    FunctionDNE,
    OutOfMemory,
    ConstantReassignment,
} || root.functions.HostError;

pub inline fn tableFast(
    self: *VM,
    id: mem.TableID,
) !*root.table.Table {
    if (builtin.mode == .ReleaseFast) {
        std.debug.assert(id < self.tables.tables.items.len);
        std.debug.assert(
            self.tables.tables.items[id] != null,
        );
        return self.tables.tables.items[id].?;
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
        return self.functions.functions.items[id].?;
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

            var c_args_buf: [16]mem.Data = @splat(.{ .bits = 0 });
            const c_args = if (args.len <= 16)
                c_args_buf[0..args.len]
            else
                try self.runtime.alloc.alloc(mem.Data, args.len);
            defer if (args.len > 16) self.runtime.alloc.free(c_args);

            for (args, 0..) |arg, i|
                c_args[i] = arg;

            var c_result: mem.Data = .{ .bits = 0 };
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
                c_result,
            );
        },
        .host => |f| {
            const args_start = callee_slot + 1;
            const args_end = args_start + argc;
            try self.ensureAbsoluteSlot(args_end);
            const args = fiber.registers[args_start..args_end];

            const total = if (f.total_arity > 0) f.total_arity else f.arity;
            if ((!f.variadic and (argc < f.arity or argc > total)) or
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
                if (f.arity == total) {
                    try self.setRuntimeMessageFmt(
                        "`{s}` wants {d} args({s}), got {d}",
                        .{
                            func.name(),
                            f.arity,
                            params_str,
                            argc,
                        },
                    );
                } else {
                    try self.setRuntimeMessageFmt(
                        "`{s}` wants between {d} and {d} args({s}), got {d}",
                        .{
                            func.name(),
                            f.arity,
                            total,
                            params_str,
                            argc,
                        },
                    );
                }
                return error.WrongArity;
            }

            for (f.param_types, 0..) |spec, i| {
                if (i < argc and !spec.matches(args[i])) {
                    try self.setRuntimeMessageFmt(
                        "arg #{d}: want {s}, got {s}",
                        .{
                            i,
                            @tagName(spec),
                            revo.std_lib.typeof(args[i], self),
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
                    const res = try self.resultTable(.err, Data.new.atom(tag));
                    try self.ensureAbsoluteSlot(base + instr.c);
                    try self.writeRegisterFast(base, instr.c, res);
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
                        .host_error => |host_err| return host_err,
                        .parked => {
                            const frame = try self.currentFrame();
                            self.currentFiber().parked_result_slot = frame.base + instr.c;
                            try self.ensureAbsoluteSlot(base + instr.c);
                            try self.writeRegisterFast(
                                base,
                                instr.c,
                                revo.Data.new.core(.missing),
                            );
                            return error.Parked;
                        },
                        .other => |msg| {
                            try self.setRuntimeMessage(msg);
                            return error.Panic;
                        },
                        .module_not_found => {
                            return error.ModuleNotFound;
                        },
                        .cyclic_import => {
                            return error.CyclicImport;
                        },
                        .import_failed => |msg| {
                            try self.setRuntimeMessage(msg);
                            return error.ImportFailed;
                        },
                        .assertion_failed => |msg| {
                            try self.setPanicMessage(msg);
                            return error.Panic;
                        },
                        .io_error => |msg| {
                            try self.setRuntimeMessage(msg);
                            return error.IoError;
                        },
                    }
                },
            }
        },
        .closure => unreachable,
    }
}

// TODO: remove
inline fn fillMissingSlots(regs: []Data, base: usize, total_arity: u8, register_count: u8) void {
    if (total_arity >= register_count) return;
    @memset(
        regs[base + total_arity .. base + register_count],
        revo.Data.new.core(.missing),
    );
}

pub fn callRegister(
    self: *VM,
    instr: Instruction,
) EvalError!void {
    const fiber = self.currentFiber();
    const base = fiber.top_base;
    const callee_slot = base + instr.a;
    const argc: usize = instr.b;

    const callee = if (callee_slot < fiber.registers_len)
        fiber.registers[callee_slot]
    else
        revo.Data.new.core(.missing);

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
                                fiber.registers[caller_fn_slot .. caller_fn_slot + moved_len],
                                fiber.registers[callee_slot .. callee_slot + moved_len],
                            );
                        }

                        tail_frame.base = caller_fn_slot + 1;
                        tail_frame.call_site_pc = if (fiber.pc > 0) fiber.pc - 1 else 0;
                        tail_frame.closure_id = closure_id;
                        tail_frame.register_count = closure.register_count;
                        fiber.top_base = tail_frame.base;

                        const tail_needed = tail_frame.base +
                            closure.register_count;
                        if (tail_needed > fiber.registers_len) {
                            try ensureRegCapacity(fiber, self.runtime.alloc, tail_needed);
                            fiber.registers_len = tail_needed;
                        }
                        fillMissingSlots(
                            fiber.registers,
                            tail_frame.base,
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
                fillMissingSlots(
                    fiber.registers,
                    new_base,
                    closure.total_arity,
                    closure.register_count,
                );

                try fiber.frames.append(
                    self.runtime.alloc,
                    .{
                        .return_addr = fiber.pc,
                        .base = new_base,
                        .program = fiber.program,
                        .call_site_pc = if (fiber.pc > 0) fiber.pc - 1 else 0,
                        .result_register = instr.c,
                        .register_count = closure.register_count,
                        .closure_id = closure_id,
                    },
                );
                fiber.top_base = new_base;
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

    // try __call on non-fn callees: table fields first, then metatables
    if (callee.asTable()) |_| {
        @branchHint(.unlikely);
        if (try self.resolveField(
            callee,
            Data.new.atom(revo.core_atoms.atomId(.__call)),
            null,
        )) |field| {
            const args_start = callee_slot + 1;
            const args_end = args_start + argc;
            try self.ensureAbsoluteSlot(args_end);
            const args = fiber.registers[args_start..args_end];
            const result = try self.callFunctionParts(
                field.value,
                callee,
                args,
                instr.c,
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

    // callee must be a function
    const func = switch (callee.tag()) {
        .function => try self.functions.get(
            callee.asFunction().?,
        ),
        else => {
            const got = switch (callee.tag()) {
                .number => "number",
                .atom => if (callee.bits == revo.Data.new.core(.missing).bits //
                or callee.bits == revo.Data.new.core(.missing).bits)
                    "<non-existing function>"
                else
                    "atom",
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

pub fn returnRegister(
    self: *VM,
    instr: Instruction,
) EvalError!void {
    const fiber = self.currentFiber();
    const read_base = fiber.top_base;
    const reg_slot = read_base + @as(usize, instr.a);
    const result = fiber.registers[reg_slot];

    const frame_idx = fiber.frames.items.len - 1;
    const frame = fiber.frames.items[frame_idx];
    fiber.frames.items.len = frame_idx;

    if (fiber.open_upvalues.items.len > 0)
        try self.closeUpvalues(frame.base);

    fiber.pc = frame.return_addr;
    fiber.program = frame.program;

    const returning_to_exit =
        self.sched.current_fiber == 0 and
        fiber.frames.items.len <= 1;

    if (returning_to_exit) if (self.resultParts(result)) |parts| {
        const tag = parts.tag.asAtom() orelse null;
        if (tag != null and tag.? == revo.core_atoms.atomId(.err)) {
            try self.panicFromErrPayload(parts.payload, fiber.pc);
            return error.Panic;
        }
    };

    if (fiber.frames.items.len == 0 or
        fiber.pc >= fiber.program.len)
    {
        const finished_id = self.sched.current_fiber;
        // close the dying fiber's open upvalues before its register buffer is
        // dropped or its id reused: closures held by other fibers read the
        // final value from `closed`, never from a dead fiber's slots
        if (fiber.open_upvalues.items.len > 0)
            try self.closeUpvalues(0);
        try self.sched.finishFiber(finished_id, result);
        if (finished_id == 0) {
            fiber.registers_len = 0;
            try self.push(result);
        }
        return;
    }

    const parent = &fiber.frames.items[fiber.frames.items.len - 1];
    fiber.top_base = parent.base;
    const result_slot = parent.base +
        frame.result_register;
    const parent_end = parent.base +
        parent.register_count;
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

    const child_program = if (self.functions.segments.items.len > closure.segment_id)
        self.functions.segments.items[closure.segment_id]
    else
        fiber.program;

    // cache parent register data before any append that could realloc the fibers array
    const parent_regs = fiber.registers;
    const parent_regs_len = fiber.registers_len;

    const child_id: FiberID = if (self.sched.free_fibers.pop()) |fid| blk: {
        const f = &self.sched.fibers.items[fid];
        f.pc = 0;
        f.program = child_program;
        f.debug_info_id = fiber.debug_info_id;
        f.running = false;
        f.state = .ready;
        f.in_runq = false;
        f.wait = .none;
        f.parked_result_slot = null;
        f.err_atom = null;
        f.registers_len = 0;
        f.frames.items.len = 0;
        f.top_base = 0;
        f.open_upvalues.items.len = 0;
        f.waiters.items.len = 0;
        break :blk fid;
    } else if (self.sched.free_slots.pop()) |fid| blk: {
        // buffers were freed at death; re-init the slot
        const child = try Fiber.init(self.runtime.alloc, fid, child_program, closure.register_count);
        self.sched.fibers.items[fid] = child;
        break :blk fid;
    } else blk: {
        const fid = self.sched.fibers.items.len;
        var child = try Fiber.init(self.runtime.alloc, fid, child_program, closure.register_count);
        errdefer child.deinit(self.runtime.alloc);
        try self.sched.fibers.append(self.runtime.alloc, child);
        break :blk fid;
    };

    const child = &self.sched.fibers.items[child_id];

    if (closure.register_count > child.registers.len)
        child.registers = try self.runtime.alloc.realloc(child.registers, closure.register_count);
    child.registers_len = closure.register_count;
    @memset(child.registers[0..closure.register_count], revo.Data.new.core(.missing));

    for (0..argc) |idx| {
        const src_reg = instr.a + 1 + @as(opcode.Register, @intCast(idx));
        const src_slot = base + src_reg;
        child.registers[idx] = if (src_slot < parent_regs_len)
            parent_regs[src_slot]
        else
            revo.Data.new.core(.missing);
    }

    const child_closure_id = if (closure.sharable_upvalues)
        closure_id
    else
        try self.detachClosureForFiber(closure_id);
    try child.frames.append(self.runtime.alloc, .{
        .return_addr = @intCast(child.program.len),
        .base = 0,
        .program = child.program,
        .call_site_pc = null,
        .result_register = 0,
        .register_count = closure.register_count,
        .closure_id = child_closure_id,
    });
    child.top_base = 0;
    child.pc = closure.addr;

    try self.sched.enqueueRunnable(child_id);
    const result_slot = base + instr.c;
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
    _ = @import("tests.zig");
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
pub const GlobalID = mem.StringID;
pub const ChannelID = mem.TableID;
pub const resolveField = lookup.resolveField;
pub const FieldLookup = lookup.FieldLookup;
pub const setMetatable = lookup.setMetatable;
pub const setTableMetatable = lookup.setTableMetatable;
pub const runImportedModule = module.runImportedModule;
const Scheduler = @import("scheduler.zig");
const vm_exec = @import("exec.zig");
const vm_gc = @import("gc.zig");
