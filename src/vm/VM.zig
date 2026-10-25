//!
//! welcome to vm
//! this is for values, fibers, calls, and memory pools
//!
//! if you're looking for the dispatch loop, see `exec.zig`
//!   , this file holds the state it runs on plus the call machinery
//!

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

pub const UserGlobals = std.AutoHashMap(GlobalID, Value);
pub const FrozenGlobals = std.AutoHashMap(GlobalID, void);

pub const ImportStamp = struct {
    mtime: u64,
    size: usize,
};

pub const ImportCache = std.StringHashMap(struct {
    result: Value,
    stamp: ImportStamp,
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

/// a single call frame. the hot fields (return_addr, base, program) come
/// first so the dispatch loop's per-instruction frame reads hit the same
/// offsets as the old dedicated hot frame; the cold fields are only touched
/// on return, stack traces, and gc marking
pub const Frame = struct {
    return_addr: ProgramCounter,
    base: usize,
    program: []const revo.Instruction,
    call_site_pc: ?ProgramCounter,
    result_register: opcode.Register,
    register_count: opcode.Register,
    closure_id: ?mem.FunctionID,
};

/// quite a hefty struct,,, but its worth it
pub const Fiber = struct {
    pub const OpenUpvalueRef = struct {
        slot_index: usize,
        id: root.callable.UpvalueID,
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
    registers: []Value,
    registers_len: usize = 0,
    frames: std.ArrayList(Frame),
    /// cached base of the top frame; the dispatch loop reads this instead of
    /// indexing frames[frames.len-1] on every call/ret. kept in sync at every
    /// frame push/pop site
    top_base: usize = 0,
    open_upvalues: std.ArrayList(OpenUpvalueRef),

    running: bool,
    state: State,
    in_run_queue: bool,
    wait: WaitKind,
    /// woken value lands here when set, else it gets pushed on the stack
    parked_result_slot: ?usize,
    // will be set to no_result in init
    result: Value = Value.new.nil(),
    // error channel maybe
    err_atom: ?mem.AtomID = null,
    /// fibers joining on this one, woken at finish
    waiters: std.ArrayList(FiberID),
    // host call a fresh fiber runs on first dispatch
    // ; closures run bytecode instead and never set this.
    // run: execute the call; done: a wake delivered the result
    // into regs[0] already, just finish. never re-runs.
    pending_host: ?HostStart = null,

    pub const HostStart = union(enum) {
        run: PendingHost,
        done: void,
    };

    pub const PendingHost = struct {
        func: mem.FunctionID,
        argc: opcode.Register,
    };

    pub fn init(alloc: std.mem.Allocator, id: FiberID, program: []const Instruction, reg_count: usize) !Fiber {
        const registers = try alloc.alloc(Value, reg_count);
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
            .in_run_queue = false,
            .wait = .none,
            .parked_result_slot = null,
            .waiters = waiters,
            .result = revo.Value.new.core(.nil),
            .pending_host = null,
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
// held for a whole dispatch; released on park/yield/halt
gil: Scheduler.SpinLock = .{},
/// workers set this and stop the pool on first failure
mt_failed: std.atomic.Value(bool) = .init(false),
/// the failure itself, reported by the main thread
mt_failure: ?RunFailure = null,
/// how deep runReport is nested; idle math exempts our own quanta
run_depth: usize = 0,

constants: std.ArrayList(Value),
builtin_globals: UserGlobals,
/// iface specs loaded at init; released by `deinit` through `specs.freeLoadedSpecs`
loaded_specs: []const []const revo.baselib.specs.FnSpec = &.{},
tables: TablePool,
callable: FunctionPool,
resources: ResourcePool,
strings: Interner,
atoms: std.StringHashMap(mem.AtomID),
debug: DebugOptions = .{},
user_globals: UserGlobals,
frozen_globals: FrozenGlobals,
import_dir: ?[]const u8,
project_root: []const u8 = "",
loading_stack: std.ArrayList([]const u8),

/// indexed by @intFromEnum(mem.ValueTag); tags are non-contiguous (0, 8-13)
metatables: [
    @as(usize, @backingInt(memory.ValueTag.@"opaque")) + 1
]?mem.TableID = @splat(null),
import_cache: ImportCache,
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

// perf counters for benchmarking/profiling (only with -Dperf:
// every bump compiles away otherwise, see `perf.zig`)
perf_enabled: bool = false,
perf: vm_perf.PerfCounters = .{},
gc_threshold: usize = 512 * 1024, // 512kb initial
gc_pause_factor: usize = 4,
// upper bound on the collection trigger; keeps the heap from growing
// without bound while avoiding pathological full collections on
// allocation-heavy, small-live workloads (bench/storage.rv collected
// every ~64kb, spending ~90% of its time in the GC)
gc_nursery_threshold: usize = 8 * 1024 * 1024,

gc_mark_stack: std.ArrayList(MarkItem),
gc_finalizers: std.AutoHashMap(mem.TableID, Value),
gc_in_finalizer: bool = false,

/// pinned for c callers (`revo_ref`), roots til `revo_unref`
/// , ids monotonic, never reused, 0 never valid
c_refs: std.AutoHashMap(u64, Value),
c_ref_next: u64 = 1,
/// last failed `revo_call`, freed on the next call + destroy
c_last_error: ?[:0]u8 = null,
/// last foreign-call errno, read via `ffi.errno`
ffi_errno: c_int = 0,
/// last foreign-call errno, read via `ffi.errno`
const MarkItem = union(enum) {
    data: Value,
    table: mem.TableID,
    function: mem.FunctionID,
    resource: mem.ResourceID,
    upvalue: root.callable.UpvalueID,
};

/// nonblocking self-pipe for scheduler wakeups
/// , null when uncreatable (callers fall back to bounded poll timeouts)
/// null when uncreatable, callers fall back to bounded poll timeouts
fn makeWakeupPipe() ?[2]c_int {
    var fds: [2]c_int = undefined;
    if (std.c.pipe(&fds) == -1) return null;
    errdefer {
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
    }
    inline for (fds) |fd| {
        const cur = std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
        if (cur == -1) return null;
        const nb = std.c.fcntl(fd, std.posix.F.SETFL, cur | @as(c_int, @bitCast(std.posix.O{ .NONBLOCK = true })));
        if (nb == -1) return null;
        const clo = std.c.fcntl(fd, std.posix.F.SETFD, @as(c_int, std.posix.FD_CLOEXEC));
        if (clo == -1) return null;
    }
    return fds;
}

pub fn init(runtime: revo.Runtime) !VM {
    var rt = runtime;
    rt.diag_arena = null;

    if (rt.threads == 0) rt.threads = 1;
    if (rt.threads > 1 and !revo.can_async) rt.threads = 1;
    if (rt.threads > 64) rt.threads = 64;

    try rt.ensureDiagArena();
    errdefer rt.deinitDiagArena();
    var sched = try Scheduler.init(rt.alloc);
    errdefer sched.deinit();
    sched.thread_count = rt.threads;
    var constants = try std.ArrayList(Value).initCapacity(rt.alloc, 16);
    errdefer constants.deinit(rt.alloc);
    var tables = try TablePool.init(rt.alloc);
    errdefer tables.deinit();
    var callable = try FunctionPool.init(rt.alloc);
    errdefer callable.deinit();
    var resources = try ResourcePool.init(rt.alloc);
    errdefer resources.deinit();
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
        .builtin_globals = UserGlobals.init(rt.alloc),
        .tables = tables,
        .callable = callable,
        .resources = resources,
        .strings = strings,
        .atoms = std.StringHashMap(mem.AtomID).init(rt.alloc),
        .import_cache = ImportCache.init(rt.alloc),
        .package_path = package_path,
        .debug_infos = debug_infos,
        .user_globals = UserGlobals.init(rt.alloc),
        .frozen_globals = FrozenGlobals.init(rt.alloc),
        .import_dir = null,
        .loaded_specs = &.{},
        .loading_stack = loading_stack,
        .loaded_extensions = .empty,
        .gc_mark_stack = gc_mark_stack,
        .gc_finalizers = std.AutoHashMap(mem.TableID, Value).init(rt.alloc),
        .c_refs = std.AutoHashMap(u64, Value).init(rt.alloc),
    };
    if (revo.can_async) {
        if (makeWakeupPipe()) |fds| {
            vm.sched.wakeup_r = fds[0];
            vm.sched.wakeup_w = fds[1];
        }
    }

    try vm.package_path.appendSlice(rt.alloc, &.{ "./?", "./lib/?", "/usr/local/lib/revo/?" });

    _ = try vm.sched.appendFiber(.{
        .id = 0,
        .pc = 0,
        .program = &.{},
        .debug_info_id = null,
        .registers = try runtime.alloc.alloc(Value, INIT_REG_COUNT),
        .frames = try std.ArrayList(Frame).initCapacity(runtime.alloc, INITIAL_HOT_FRAMES),
        .running = false,
        .open_upvalues = try std.ArrayList(Fiber.OpenUpvalueRef).initCapacity(runtime.alloc, 1),
        .state = .ready,
        .in_run_queue = false,
        .wait = .none,
        .parked_result_slot = null,
        .waiters = try std.ArrayList(FiberID).initCapacity(runtime.alloc, 1),
    });

    // set initial fiber result to no_result
    // after core atoms are initialized
    vm.sched.fibers.items[0].result = revo.Value.new.core(.no_result);

    try revo.baselib.register_baselib(&vm);

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

///
/// perf counters (only for -Dperf)
///
pub inline fn perfActive(self: *VM) bool {
    if (comptime !vm_perf.enabled) return false;
    return self.perf_enabled;
}

pub fn enablePerf(self: *VM) void {
    if (comptime !vm_perf.enabled) return;
    self.perf_enabled = true;
}

pub fn disablePerf(self: *VM) void {
    if (comptime !vm_perf.enabled) return;
    self.perf_enabled = false;
}

pub fn resetPerf(self: *VM) void {
    if (comptime !vm_perf.enabled) return;
    self.perf.reset();
}

pub inline fn bumpPerf(self: *VM, op: opcode.Opcode) void {
    if (comptime !vm_perf.enabled) return;
    if (!self.perf_enabled) return;
    self.perf.countOp(op);
}

/// batch bump for fused/skipped instructions (concat chaining)
pub inline fn bumpPerfN(self: *VM, op: opcode.Opcode, n: usize) void {
    if (comptime !vm_perf.enabled) return;
    if (!self.perf_enabled) return;
    self.perf.countOpN(op, n);
}

pub fn deinit(self: *VM) void {
    self.clearProgramDebugInfo();
    self.clearPanicMessage();
    self.clearRuntimeMessage();
    if (revo.can_async) {
        if (self.sched.wakeup_r >= 0) _ = std.c.close(self.sched.wakeup_r);
        if (self.sched.wakeup_w >= 0) _ = std.c.close(self.sched.wakeup_w);
        self.sched.wakeup_r = -1;
        self.sched.wakeup_w = -1;
    }

    self.constants.deinit(self.runtime.alloc);
    self.user_globals.deinit();
    self.frozen_globals.deinit();
    self.builtin_globals.deinit();
    revo.baselib.specs.freeLoadedSpecs(self.runtime.alloc, self.loaded_specs);

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
                    _ = self.callFunctionParts(func, null, &.{Value.new.table(id)}, null) catch {};
                }
            }
        }
    }
    self.gc_finalizers.deinit();
    self.c_refs.deinit();
    if (self.c_last_error) |m| self.runtime.alloc.free(m);
    // run pending resource __gc while tables are alive
    {
        var id = self.resources.first;
        while (id != root.alloc_pool.end) {
            const nxt = self.resources.next.items[id];
            _ = self.runResourceGc(id);
            id = nxt;
        }
    }
    self.resources.deinit();
    self.sched.deinit();
    self.tables.deinit();
    self.callable.deinit();
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

    var cache_it = self.import_cache.keyIterator();
    while (cache_it.next()) |key|
        self.runtime.alloc.free(key.*);

    self.import_cache.deinit();

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

/// func runs when the table gets swept
pub fn registerFinalizer(self: *VM, table_id: mem.TableID, func: Value) !void {
    try self.gc_finalizers.put(table_id, func);
}

pub fn unregisterFinalizer(self: *VM, table_id: mem.TableID) void {
    _ = self.gc_finalizers.remove(table_id);
}

/// run a handle's metatable `__gc` on the handle; false when none
pub fn runResourceGc(self: *VM, id: mem.ResourceID) bool {
    const cell = self.resources.get(id) catch return false;
    const mt = cell.metatable orelse return false;
    const mt_tbl = self.tables.get(mt) catch return false;
    const func = mt_tbl.getRawAtom(revo.CoreAtoms.atomId(.__gc), self) orelse return false;
    if (func.asFunction() == null) return false;
    _ = self.callFunctionParts(func, null, &.{Value.new.resource(id)}, null) catch {};
    return true;
}

/// true when the table has a finalizer pending
pub fn hasFinalizer(self: *VM, table_id: mem.TableID) bool {
    return self.gc_finalizers.contains(table_id);
}

pub fn importStamp(self: *VM, path: []const u8) !ImportStamp {
    const stat = try std.Io.Dir.cwd().statFile(self.runtime.io, path, .{});
    return .{
        .mtime = @intCast(stat.mtime.toNanoseconds()),
        .size = @intCast(stat.size),
    };
}

pub fn invalidateImportCache(self: *VM, path: []const u8) bool {
    if (self.import_cache.fetchRemove(path)) |entry| {
        self.runtime.alloc.free(entry.key);
        return true;
    }
    return false;
}

pub fn addConstant(self: *VM, val: Value) !ConstantID {
    const idx: ConstantID = @intCast(self.constants.items.len);
    try self.constants.append(self.runtime.alloc, val);
    return idx;
}

//
// data creation helpers
//

// TODO: make a pools field, move all pools there
/// dupes yours
pub fn ownValueString(self: *VM, value: []const u8) !Value {
    return Value.new.str(try self.strings.own(value));
}

/// kills yours
pub fn adoptValueString(self: *VM, value: []u8) !Value {
    return Value.new.str(try self.strings.adopt(value));
}

pub fn adoptValueStringNoDedup(self: *VM, value: []u8) !Value {
    return Value.new.str(try self.strings.adoptNoDedup(value));
}

pub fn ownValueStringNoDedup(self: *VM, value: []const u8) !Value {
    return Value.new.str(try self.strings.ownNoDedup(value));
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
pub fn tableOfSlice(self: *VM, val: []const Value) !Value {
    const id = try self.tables.create();
    const ptr = try self.tables.get(id);
    try ptr.array.appendSlice(self.runtime.alloc, val);
    return Value.new.table(id);
}

/// `{:tag, payload}` result table, the `{:ok, v}` / `{:err, e}` shape
pub fn resultTable(self: *VM, tag: revo.CoreAtoms, payload: Value) !Value {
    return self.tableOfSlice(&[_]Value{
        Value.new.atom(tag.atomId()),
        payload,
    });
}

/// split of a `{:tag, ...}` table: tag in [0], payload in [1] when present
pub const ResultParts = struct { tag: Value, payload: ?Value, len: usize };
pub fn resultParts(self: *VM, val: Value) ?ResultParts {
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
pub fn isErrTable(self: *VM, val: Value) bool {
    const parts = self.resultParts(val) orelse return false;
    const atom = parts.tag.asAtom() orelse return false;
    return atom == revo.CoreAtoms.atomId(.err);
}

/// `:ok` table check, pairs `isErrTable`
pub fn isOkTable(self: *VM, val: Value) bool {
    const parts = self.resultParts(val) orelse return false;
    const atom = parts.tag.asAtom() orelse return false;
    return atom == revo.CoreAtoms.atomId(.ok);
}

/// named-field write without the intern dance
pub fn putField(self: *VM, tid: mem.TableID, name: []const u8, val: Value) !void {
    const t = try self.tables.get(tid);
    try t.putRawAtom(try self.internAtom(name), val, self);
}

/// named-field raw read, null when missing or not a table
/// never interns, so core names resolve even if nothing interned them yet
pub fn getField(self: *VM, val: Value, name: []const u8) ?Value {
    const tid = val.asTable() orelse return null;
    const t = self.tables.get(tid) catch return null;
    const id = self.atoms.get(name) orelse self.strings.lookup(name) orelse return null;
    return t.getRawAtom(id, self);
}

/// remove a named field, false when missing or not a table
pub fn removeField(self: *VM, val: Value, name: []const u8) bool {
    const tid = val.asTable() orelse return false;
    const t = self.tables.get(tid) catch return false;
    const id = self.atoms.get(name) orelse self.strings.lookup(name) orelse return false;
    return t.remove(Value.new.atom(id), self);
}

/// array-part read with bounds check, null when out of range
pub fn arrayGet(self: *VM, tid: mem.TableID, idx: usize) ?Value {
    const t = self.tables.get(tid) catch return null;
    if (idx >= t.array.items.len) return null;
    return t.array.items[idx];
}

/// deep copy of a table: array part in order, then keyed entries
pub fn tableCopy(self: *VM, src: mem.TableID) !Value {
    const s = try self.tables.get(src);
    const id = try self.tables.create();
    const d = try self.tables.get(id);

    try d.array.appendSlice(self.runtime.alloc, s.array.items);
    var it = s.hash.orderedIterator();

    while (it.next()) |entry|
        try d.putRaw(entry.key, entry.value, self);
    return Value.new.table(id);
}

/// recursive clone with cycle guard
pub fn tableDeepCopy(
    vm: *VM,
    src: revo.memory.TableID,
) anyerror!Value {
    const aux = struct {
        fn deepCopyInto(
            _vm: *VM,
            _src: revo.memory.TableID,
            seen: *std.AutoHashMap(revo.memory.TableID, revo.memory.TableID),
        ) anyerror!Value {
            if (seen.get(_src)) |id| return Value.new.table(id);
            const id = try _vm.tables.create();
            try seen.put(_src, id);
            const s = try _vm.tables.get(_src);
            const d = try _vm.tables.get(id);

            for (s.array.items) |item| {
                const v = if (item.asTable()) |tid| try deepCopyInto(_vm, tid, seen) else item;
                try d.array.append(_vm.runtime.alloc, v);
            }
            var it = s.hash.orderedIterator();
            while (it.next()) |entry| {
                const k = if (entry.key.asTable()) |tid| try deepCopyInto(_vm, tid, seen) else entry.key;
                const v = if (entry.value.asTable()) |tid| try deepCopyInto(_vm, tid, seen) else entry.value;
                try d.putRaw(k, v, _vm);
            }
            return Value.new.table(id);
        }
    }.deepCopyInto;

    var seen = std.AutoHashMap(revo.memory.TableID, revo.memory.TableID).init(vm.runtime.alloc);
    defer seen.deinit();
    return aux(vm, src, &seen);
}

pub fn push(self: *VM, val: Value) !void {
    const fiber = self.currentFiber();
    try ensureRegCapacity(fiber, self.runtime.alloc, fiber.registers_len + 1);
    fiber.registers[fiber.registers_len] = val;
    fiber.registers_len += 1;
}

pub fn currentResult(self: *VM) Value {
    const fiber = self.currentFiber();
    if (fiber.registers_len > 0) return fiber.registers[fiber.registers_len - 1];
    return fiber.result;
}

pub inline fn mainResult(self: *VM) Value {
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
pub fn pop(self: *VM) !Value {
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
    @memset(fiber.registers[old_len .. slot + 1], revo.Value.new.core(.missing));
    fiber.registers_len = slot + 1;
}

/// call when slot is valid and capacity is enough
pub inline fn writeRegisterUnsafe(self: *VM, slot: usize, value: Value) void {
    self.currentFiber().registers[slot] = value;
}

/// register read using a cached slots pointer (avoids currentFiber call)
pub inline fn regRead(slots: []const Value, base: usize, reg: opcode.Register) Value {
    if (builtin.mode != .fast) {
        const slot = base + reg;
        if (slot >= slots.len)
            return revo.Value.new.core(.missing);
    }
    return slots[base + reg];
}

/// register write using a cached slots pointer (avoids currentFiber call)
pub inline fn regWrite(slots: []Value, base: usize, reg: opcode.Register, value: Value) void {
    if (builtin.mode != .fast) {
        const slot = base + reg;
        if (slot >= slots.len)
            @panic("register write out of bounds; this is a compiler bug, report at " ++
                "https://codeberg.org/lung/revo/issues");
    }
    slots[base + reg] = value;
}

/// avoid recomputing currentFrame() repeatedly
/// callers should cache `base = frame.base`
pub inline fn writeRegisterFast(self: *VM, base: usize, reg: opcode.Register, value: Value) !void {
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

pub fn atomValue(self: *VM, name: []const u8) !Value {
    return Value.new.atom(try self.internAtom(name));
}

pub fn setGlobal(self: *VM, name: []const u8, val: Value) !void {
    const id = try self.internAtom(name);
    try self.user_globals.put(id, val);
}

//
// baselib reg
//

/// install a Host fn on the heap. name fills the function's name
/// field (stack traces, mt keys)
pub fn installHost(self: *VM, name: []const u8, func: revo.baselib.host.HostFunc) !mem.FunctionID {
    var f = func;
    f.name = name;
    return self.callable.create(.{ .host = f });
}

/// register a function as a global. also records in builtin_globals so
/// repl reset can replay the same set
pub fn registerGlobal(self: *VM, name: []const u8, fn_id: mem.FunctionID) !void {
    const atom = try self.internAtom(name);
    const val = Value.new.function(fn_id);
    try self.user_globals.put(atom, val);
    try self.builtin_globals.put(atom, val);
}

/// get or create a module table and install it as a global
pub fn ensureModule(self: *VM, name: []const u8) !mem.TableID {
    const atom = try self.internAtom(name);
    if (self.user_globals.get(atom)) |existing| {
        if (existing.asTable()) |tid| return tid;
    }
    const tid = try self.tables.create();
    const val = Value.new.table(tid);
    try self.user_globals.put(atom, val);
    try self.builtin_globals.put(atom, val);
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
    try t.putRawAtom(atom, Value.new.function(fn_id), self);
}

pub inline fn getGlobal(self: *VM, name: []const u8) ?Value {
    if (self.atoms.get(name)) |id| return self.user_globals.get(id);
    return revo.Value.new.core(.undef);
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
    const func = self.callable.get(id) catch return "<dead>";
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
pub fn panicFromErrPayload(self: *VM, payload: ?Value, pc: usize) error{ OutOfMemory, Panic }!void {
    if (payload) |p| {
        var buf = std.Io.Writer.Allocating.init(self.runtime.alloc);
        defer buf.deinit();
        p.write(&buf.writer, self, .pretty, self.runtime.supports_color) catch |err| switch (err) {
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
    const message = try self.runtime.alloc.print(fmt_str, args);
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
pub fn typeError(self: *VM, comptime expected: []const u8, got: mem.Value) RunFailure {
    const msg = self.runtime.alloc.print(
        "want {s}, got {s}",
        .{ expected, @tagName(got.tag()) },
    ) catch return self.runFailure(error.TypeError);

    self.setRuntimeMessageOwned(msg);
    return self.runFailure(error.TypeError);
}

pub fn fail(self: *VM, comptime err: RunError, comptime fmt: []const u8, args: anytype) RunFailure {
    const msg = self.runtime.alloc.print(fmt, args) catch
        return self.runFailure(err);
    self.setRuntimeMessageOwned(msg);
    return self.runFailure(err);
}

pub fn currentFrame(self: *VM) !*Frame {
    if (self.currentFiber().frames.items.len == 0) return error.FrameUnderflow;
    return &self.currentFiber().frames.items[self.currentFiber().frames.items.len - 1];
}

pub inline fn currentClosure(self: *VM) !?*root.callable.Closure {
    return self.currentClosureIn(self.currentFiber());
}

/// currentClosure without re deriving the fiber
///
/// dispatch already has it, and these run per upvalue access on hot paths
pub inline fn currentClosureIn(self: *VM, fiber: *Fiber) !?*root.callable.Closure {
    if (fiber.frames.items.len == 0) return error.FrameUnderflow;
    const frame = &fiber.frames.items[fiber.frames.items.len - 1];
    const closure_id = frame.closure_id orelse return null;
    const func = try self.functionFast(closure_id);

    return switch (func.*) {
        .closure => |*closure| closure,
        .host, .c_function => null,
    };
}

/// open upvalues stay sorted by slot, closers pop from the end
pub inline fn captureUpvalue(self: *VM, slot_index: usize) !root.callable.UpvalueID {
    const fiber = self.currentFiber();
    const open = &fiber.open_upvalues;
    for (open.items, 0..) |entry, idx| {
        if (entry.slot_index == slot_index) return entry.id;
        if (entry.slot_index > slot_index) {
            const upvalue_id = try self.callable.createUpvalue(.{
                .open_index = slot_index,
                .closed = revo.Value.new.core(.missing),
                .owner_fiber_id = fiber.id,
            });
            try open.insert(self.runtime.alloc, idx, .{ .slot_index = slot_index, .id = upvalue_id });
            return upvalue_id;
        }
    }
    const upvalue_id = try self.callable.createUpvalue(.{
        .open_index = slot_index,
        .closed = revo.Value.new.core(.missing),
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

        const upvalue = try self.callable.getUpvalue(entry.id);
        if (upvalue.open_index) |slot_index| {
            upvalue.closed = fiber.registers[slot_index];
            upvalue.open_index = null;
        }
        _ = open.pop();
    }
}

pub inline fn loadUpvalueValue(self: *VM, upvalue_id: root.callable.UpvalueID) !Value {
    const upvalue = try self.callable.getUpvalue(upvalue_id);
    if (upvalue.open_index) |slot_index| {
        const fid = upvalue.owner_fiber_id orelse return upvalue.closed;
        return self.sched.fibers.items[fid].registers[slot_index];
    }
    return upvalue.closed;
}

pub inline fn storeUpvalueValue(self: *VM, fiber: *Fiber, upvalue_id: root.callable.UpvalueID, value: Value) !void {
    const upvalue = try self.callable.getUpvalue(upvalue_id);

    if (upvalue.open_index) |slot_index| {
        const owner_regs = if (upvalue.owner_fiber_id) |fid|
            self.sched.fibers.items[fid].registers
        else
            fiber.registers;

        std.debug.assert(slot_index < owner_regs.len);
        owner_regs[slot_index] = value;
    } else {
        upvalue.closed = value;
    }
}

/// snapshot upvalues per child, so loopscope reuse never leaks into an offspring
fn detachClosureForFiber(self: *VM, closure_id: mem.FunctionID) !mem.FunctionID {
    const func = try self.callable.get(closure_id);
    const closure = switch (func.*) {
        .closure => |value| value,
        .host, .c_function => return closure_id,
    };

    // always snapshot
    // : sharing the parent's open upvalues would let later
    //   writes to the same register slot
    //     (next loop iteration, scope reuse)
    //   leak into the child fiber
    var detached = try std.ArrayList(root.callable.UpvalueID).initCapacity(
        self.runtime.alloc,
        closure.upvalues.len,
    );
    defer detached.deinit(self.runtime.alloc);

    for (closure.upvalues) |upvalue_id| {
        try detached.append(
            self.runtime.alloc,
            try self.callable.createUpvalue(.{
                .open_index = null,
                .closed = try self.loadUpvalueValue(upvalue_id),
                .owner_fiber_id = null,
            }),
        );
    }

    return self.callable.createClosure(closure.template, detached.items);
}

/// `result_reg` is a register (relative to the caller frame's base) where a
/// parked callee's eventual result should land. host callers that consume the
/// value through dispatch instructions (index, concat, call) pass the
/// instruction's result register so a park mid-callee resumes with the value
/// in place; callers that discard or consume the result directly pass null.
pub fn callFunctionParts(self: *VM, callee: Value, maybe_first: ?Value, args: []const Value, result_reg: ?opcode.Register) RunError!Value {
    self.host_call_depth += 1;
    defer self.host_call_depth -= 1;

    // running the callee can spawn fibers
    //   , which appends to the fibers array and may realloc it
    // . any cached fiber pointer dangles after
    //   that, so track the fiber by id
    //     and re-fetch after each nested run
    const fiber_id = self.sched.currentID();
    var fiber = self.currentFiber();
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
    // pc must survive so the io waiter can resume where it stopped
    // . every other error unwinds back to the caller state
    const unwind = unwindToCaller;

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
        fiber = self.sched.fibers.items[fiber_id];
        if (e == error.Parked) {
            self.rerouteParked(fiber, base, caller_frame_depth, result_reg);
            return e;
        }
        unwind(self, fiber, initial_slot_len, initial_pc, initial_frame_depth);
        return e;
    };

    fiber = self.sched.fibers.items[fiber_id];
    if (fiber.frames.items.len > caller_frame_depth) {
        const exec_result = vm_dispatch.execFiberUntilDepth(self, caller_frame_depth) catch |e| {
            fiber = self.sched.fibers.items[fiber_id];
            if (e == error.Parked) {
                self.rerouteParked(fiber, base, caller_frame_depth, result_reg);
                return e;
            }
            unwind(self, fiber, initial_slot_len, initial_pc, initial_frame_depth);
            return e;
        };
        if (exec_result) |_| return error.Panic;
    }

    fiber = self.sched.fibers.items[fiber_id];
    const result = fiber.registers[callee_slot];
    fiber.registers_len = callee_slot;
    return result;
}

/// put caller regs, pc, and frames back after a failed nested call
/// , parked fibers keep their state, everything else unwinds here
fn unwindToCaller(v: *VM, f: *Fiber, slot_len: usize, pc: usize, frame_depth: usize) void {
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

pub fn runFailure(self: *VM, err: RunError) RunFailure {
    const kind: RunErrorKind = switch (err) {
        inline else => |tag| @field(RunErrorKind, @errorName(tag)),
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

    var failure = RunFailure{
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
        out_idx < RunFailure.max_trace_frames)
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
    val: Value,
    atom: mem.AtomID,
) !?Value {
    const mt_id = try self.getMetatableId(val) orelse return null;
    const mt = try self.tables.get(mt_id);
    return mt.getRawAtom(atom, self);
}

pub fn getMetatableId(
    self: *VM,
    val: Value,
) !?mem.TableID {
    return switch (val.tag()) {
        .table => blk: {
            const id = val.asTable().?;
            if (self.tables.get(id)) |value| {
                if (value.metatable) |mt_id|
                    break :blk mt_id;
            } else |_| {}
            break :blk self.metatables[
                @backingInt(
                    mem.ValueTag.table,
                )
            ];
        },
        .resource => blk: {
            const id = val.asResource().?;
            if (self.resources.get(id)) |cell| {
                if (cell.metatable) |mt_id|
                    break :blk mt_id;
            } else |_| {}
            break :blk self.metatables[@backingInt(mem.ValueTag.resource)];
        },
        else => |e| self.metatables[@backingInt(e)],
    };
}

pub const RunError = error{
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
} || root.callable.RunError;

pub inline fn tableFast(
    self: *VM,
    id: mem.TableID,
) !*root.table.Table {
    if (builtin.mode == .fast) {
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
) !*root.callable.Function {
    if (builtin.mode == .fast) {
        std.debug.assert(
            id < self.callable.functions.items.len,
        );
        std.debug.assert(
            self.callable.functions.items[id] != null,
        );
        return self.callable.functions.items[id].?;
    }
    return self.callable.get(id) catch |e| {
        if (e == error.FunctionDNE) {
            try self.setPanicMessage("function does not exist");
            return error.Panic;
        }
        return e;
    };
}

fn callNonClosureFunction(
    self: *VM,
    func: root.callable.Function,
    instr: Instruction,
    base: usize,
    callee_slot: usize,
    argc: usize,
) RunError!void {
    const fiber = self.currentFiber();
    switch (func) {
        .c_function => |f| {
            if (self.perfActive()) self.perf.c_calls += 1;
            self.host_call_depth += 1;
            defer self.host_call_depth -= 1;
            const args_start = callee_slot + 1;
            const args_end = args_start + argc;
            try self.ensureAbsoluteSlot(args_end);
            const args = fiber.registers[args_start..args_end];

            var c_args_buf: [16]mem.Value = @splat(.{ .bits = 0 });
            const c_args = if (args.len <= 16)
                c_args_buf[0..args.len]
            else
                try self.runtime.alloc.alloc(mem.Value, args.len);
            defer if (args.len > 16) self.runtime.alloc.free(c_args);

            for (args, 0..) |arg, i|
                c_args[i] = arg;

            var c_result: mem.Value = .{ .bits = 0 };
            self.clearRuntimeMessage();
            const rc = f.fn_ptr(
                @ptrCast(self),
                argc,
                c_args.ptr,
                &c_result,
            );
            if (rc != root.callable.c_ok) {
                if (self.runtime_message == null)
                    try self.setRuntimeMessage("c function failed");
                return switch (rc) {
                    root.callable.c_err_arity => error.WrongArity,
                    root.callable.c_err_type => error.TypeError,
                    else => error.Panic,
                };
            }
            try self.ensureAbsoluteSlot(base + instr.c);
            try self.writeRegisterFast(
                base,
                instr.c,
                c_result,
            );
        },
        .host => |f| {
            if (self.perfActive()) self.perf.host_calls += 1;
            const args_start = callee_slot + 1;
            const args_end = args_start + argc;
            try self.ensureAbsoluteSlot(args_end);
            // copy
            // : host funcs call back into nested calls that append
            //   to these same regs
            //   and may realloc the buffer mid-execution
            var stack_buf: [16]Value = undefined;
            var heap_buf: ?[]Value = null;
            defer if (heap_buf) |h| self.runtime.alloc.free(h);
            const args: []const Value = if (argc <= stack_buf.len) blk: {
                @memcpy(stack_buf[0..argc], fiber.registers[args_start..args_end]);
                break :blk stack_buf[0..argc];
            } else blk: {
                const h = try self.runtime.alloc.alloc(Value, argc);
                heap_buf = h;
                @memcpy(h, fiber.registers[args_start..args_end]);
                break :blk h;
            };

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
                            revo.baselib.typeof(args[i], self),
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
                    const res = try self.resultTable(.err, Value.new.atom(tag));
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
                                revo.Value.new.core(.parked),
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
inline fn fillMissingSlots(regs: []Value, base: usize, total_arity: u8, register_count: u8) void {
    if (total_arity >= register_count) return;
    @memset(
        regs[base + total_arity .. base + register_count],
        revo.Value.new.core(.missing),
    );
}

/// closures push a frame and return, hosts run inline and may park
pub fn callRegister(
    self: *VM,
    instr: Instruction,
) RunError!void {
    var fiber = self.currentFiber();
    const base = fiber.top_base;
    const callee_slot = base + instr.a;
    const argc: usize = instr.b;

    const callee = if (callee_slot < fiber.registers_len)
        fiber.registers[callee_slot]
    else
        revo.Value.new.core(.missing);

    // seemingly the likeliest for both rec and non-rec
    if (callee.tag() == .function) {
        @branchHint(.likely);
        const closure_id = callee.asFunction().?;
        const func = try self.functionFast(closure_id);
        return switch (func.*) {
            .closure => |closure| {
                if (closure.arity !=
                    root.callable.VARIADIC and
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
                                Value,
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

                        if (self.callable.segments.items.len > closure.segment_id) {
                            fiber.program = self.callable.segments.items[closure.segment_id];
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
                if (self.callable.segments.items.len > closure.segment_id) {
                    fiber.program = self.callable.segments.items[closure.segment_id];
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
    // , resources go through the same path (handles calling like tables)
    if (callee.asTable() != null or callee.asResource() != null) {
        @branchHint(.unlikely);
        if (try self.resolveField(
            callee,
            Value.new.atom(revo.CoreAtoms.atomId(.__call)),
            null,
        )) |field| {
            // resolveField could run __index user code
            // , which may spawn and realloc the fibers array
            fiber = self.currentFiber();
            const args_start = callee_slot + 1;
            const args_end = args_start + argc;

            try self.ensureAbsoluteSlot(args_end);
            const args = fiber.registers[args_start..args_end];
            // copy
            //   the nested call appends to these same registers and
            //   may realloc the buffer args points into mid-copy
            var stack_buf: [16]Value = undefined;
            var heap_buf: ?[]Value = null;
            defer if (heap_buf) |h| self.runtime.alloc.free(h);

            const owned_args: []const Value = if (argc <= stack_buf.len) blk: {
                @memcpy(stack_buf[0..argc], args);
                break :blk stack_buf[0..argc];
            } else blk: {
                const h = try self.runtime.alloc.alloc(Value, argc);
                heap_buf = h;
                @memcpy(h, args);
                break :blk h;
            };

            const result = try self.callFunctionParts(
                field.value,
                callee,
                owned_args,
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
        .function => try self.callable.get(
            callee.asFunction().?,
        ),
        else => {
            const got = switch (callee.tag()) {
                .number => "number",
                .atom => if (callee.bits == revo.Value.new.core(.missing).bits)
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

/// pop a frame into the caller slot; an empty fiber finishes instead
pub fn returnRegister(
    self: *VM,
    instr: Instruction,
) RunError!void {
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
        self.sched.currentID() == 0 and
        fiber.frames.items.len <= 1;

    if (returning_to_exit) if (self.resultParts(result)) |parts| {
        const tag = parts.tag.asAtom() orelse null;
        if (tag != null and tag.? == revo.CoreAtoms.atomId(.err)) {
            try self.panicFromErrPayload(parts.payload, fiber.pc);
            return error.Panic;
        }
    };

    if (fiber.frames.items.len == 0 or
        fiber.pc >= fiber.program.len)
    {
        const finished_id = self.sched.currentID();
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

/// what a spawn runs: a function id plus the table itself when spawned
/// through `__call`
const SpawnTarget = struct { func_id: mem.FunctionID, self_arg: ?Value };

/// resolve a spawn callee to a function
/// , `__call` tables spawn like direct calls do, with the table passed first
fn resolveSpawnTarget(self: *VM, callee: Value) RunError!SpawnTarget {
    if (callee.asFunction()) |fid| return .{ .func_id = fid, .self_arg = null };
    if (callee.asTable()) |_| {
        const mm = try self.resolveField(callee, Value.new.atom(revo.CoreAtoms.atomId(.__call)), null) orelse {
            try self.setRuntimeMessage("spawn expects function!");
            return error.NotAFunction;
        };
        const func_id = mm.value.asFunction() orelse {
            try self.setRuntimeMessage("spawn expects function!");
            return error.NotAFunction;
        };
        return .{ .func_id = func_id, .self_arg = callee };
    }
    try self.setRuntimeMessage("spawn expects function!");
    return error.NotAFunction;
}

/// reuse a dead fiber id or allocate a fresh one, reset for `program` with
/// room for `reg_need` registers
/// , cache the parents registers first, the append below may realloc
fn reuseSpawnFiber(self: *VM, parent: *Fiber, program: []const Instruction, reg_need: usize) !FiberID {
    const child_id: FiberID = if (self.sched.free_fibers.pop()) |fid| blk: {
        const f = self.sched.fibers.items[fid];
        f.pc = 0;
        f.program = program;
        f.debug_info_id = parent.debug_info_id;
        f.running = false;
        f.state = .ready;
        f.in_run_queue = false;
        f.wait = .none;
        f.parked_result_slot = null;
        f.err_atom = null;
        f.pending_host = null;
        f.registers_len = 0;
        f.frames.items.len = 0;
        f.top_base = 0;
        f.open_upvalues.items.len = 0;
        f.waiters.items.len = 0;
        break :blk fid;
    } else if (self.sched.free_slots.pop()) |fid| blk: {
        // buffers were freed at death; re-init the slot
        const child = try Fiber.init(self.runtime.alloc, fid, program, reg_need);
        self.sched.fibers.items[fid].* = child;
        break :blk fid;
    } else blk: {
        const fid = self.sched.fibers.items.len;
        const child = try Fiber.init(self.runtime.alloc, fid, program, reg_need);
        break :blk try self.sched.appendFiber(child);
    };

    const child = self.sched.fibers.items[child_id];
    if (reg_need > child.registers.len)
        child.registers = try self.runtime.alloc.realloc(child.registers, reg_need);
    child.registers_len = reg_need;
    @memset(child.registers[0..reg_need], revo.Value.new.core(.missing));
    return child_id;
}

/// copy spawn args from the parent into the child at `dst_base`
/// , `self_arg` goes first when present
fn copySpawnArgs(
    parent_regs: []const Value,
    parent_len: usize,
    child: *Fiber,
    dst_base: usize,
    base: usize,
    callee_reg: opcode.Register,
    eff_argc: usize,
    self_arg: ?Value,
) void {
    const self_arg_count: usize = @intFromBool(self_arg != null);
    for (0..eff_argc) |idx| {
        if (idx == 0 and self_arg != null) {
            child.registers[dst_base + idx] = self_arg.?;
            continue;
        }
        const src_reg = callee_reg + 1 + @as(opcode.Register, @intCast(idx - self_arg_count));
        const src_slot = base + src_reg;
        child.registers[dst_base + idx] = if (src_slot < parent_len)
            parent_regs[src_slot]
        else
            revo.Value.new.core(.missing);
    }
}

/// publish the `{:fiber, id}` handle into the parents result register
fn publishSpawnHandle(self: *VM, base: usize, result_reg: opcode.Register, child_id: FiberID) !void {
    if (self.perfActive()) self.perf.fibers_spawned += 1;
    try self.sched.enqueueRunnable(child_id);
    const result_slot = base + result_reg;
    const cur = self.currentFiber();
    if (result_slot >= cur.registers_len) {
        try ensureRegCapacity(cur, self.runtime.alloc, result_slot + 1);
        cur.registers_len = result_slot + 1;
    }
    self.noteGCPressure(@sizeOf(Value) * 2 + 64);
    cur.registers[result_slot] = try self.tableOfSlice(&[_]Value{
        Value.new.atom(revo.CoreAtoms.atomId(.fiber)),
        Value.new.num(@as(i64, @intCast(child_id))),
    });
}

/// start a fiber and hand back its handle; __call tables pass self first
pub inline fn spawnRegister(
    self: *VM,
    instr: Instruction,
    base: usize,
) RunError!void {
    const argc: usize = instr.b;
    const fiber = self.currentFiber();
    const callee = regRead(fiber.registers, base, instr.a);

    const target = try resolveSpawnTarget(self, callee);
    const func_id = target.func_id;
    const self_arg = target.self_arg;
    const eff_argc = argc + @intFromBool(self_arg != null);

    const func = try self.functionFast(func_id);
    const closure = switch (func.*) {
        .closure => |f| f,
        .host, .c_function => return try self.spawnHostRegister(instr, base, func_id, argc, self_arg),
    };

    if (closure.arity != root.callable.VARIADIC and
        (eff_argc < closure.arity or eff_argc > closure.total_arity))
    {
        @branchHint(.unlikely);
        try self.setRuntimeMessageFmt(
            "fiber closure `{s}` wants between {d} and {d} args, got {d}",
            .{ closure.name, closure.arity, closure.total_arity, eff_argc },
        );
        return error.WrongArity;
    }

    const child_program = if (self.callable.segments.items.len > closure.segment_id)
        self.callable.segments.items[closure.segment_id]
    else
        fiber.program;

    // cache parent register data before any append that could realloc the fibers array
    const parent_regs = fiber.registers;
    const parent_regs_len = fiber.registers_len;

    const need_regs = @max(closure.register_count, eff_argc);
    const child_id = try self.reuseSpawnFiber(fiber, child_program, need_regs);
    const child = self.sched.fibers.items[child_id];
    copySpawnArgs(parent_regs, parent_regs_len, child, 0, base, instr.a, eff_argc, self_arg);

    const child_closure_id = try self.detachClosureForFiber(func_id);
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

    try self.publishSpawnHandle(base, instr.c, child_id);
}

/// run a host fn on a fresh fiber through pending_host
fn spawnHostRegister(self: *VM, instr: Instruction, base: usize, func_id: mem.FunctionID, argc: usize, self_arg: ?Value) RunError!void {
    const fiber = self.currentFiber();
    const parent_regs = fiber.registers;
    const parent_regs_len = fiber.registers_len;
    const eff_argc = argc + @intFromBool(self_arg != null);
    const need = eff_argc + 1;

    const child_id = try self.reuseSpawnFiber(fiber, &.{}, need);
    const child = self.sched.fibers.items[child_id];
    child.registers[0] = Value.new.function(func_id);
    copySpawnArgs(parent_regs, parent_regs_len, child, 1, base, instr.a, eff_argc, self_arg);

    // dummy root frame so park paths have a frame to hang the result slot on
    // ; the entry prologue runs the call, this frame never dispatches
    try child.frames.append(self.runtime.alloc, .{
        .return_addr = 0,
        .base = 0,
        .program = &.{},
        .call_site_pc = null,
        .result_register = 0,
        .register_count = @min(need, std.math.maxInt(root.callable.RegisterCount)),
        .closure_id = func_id,
    });
    child.top_base = 0;
    child.pc = 0;
    child.pending_host = .{ .run = .{ .func = func_id, .argc = @intCast(eff_argc) } };

    try self.publishSpawnHandle(base, instr.c, child_id);
}

// gc
pub fn markValue(self: *VM, data: Value) void {
    vm_gc.markValue(self, data);
}

test {
    _ = @import("errors.zig");
    _ = @import("callable.zig");
    _ = @import("interner.zig");
    _ = @import("lookup.zig");
    _ = @import("memory.zig");
    _ = @import("run.zig");
    _ = @import("opcode.zig");
    _ = @import("table.zig");
    _ = @import("tests.zig");
    _ = @import("dispatch.zig");
    _ = @import("gc.zig");
    _ = @import("perf.zig");
}

const builtin = @import("builtin");
const std = @import("std");

const revo = @import("revo");
const lang = revo.lang;
const Span = lang.Span;

const compare_impl = @import("compare.zig");
pub const compare = compare_impl.compare;
const root = @import("root.zig");
pub const RunErrorKind = root.errors.RunErrorKind;
pub const RunFailure = root.errors.RunFailure;
pub const RunResult = root.errors.RunResult;
const FunctionPool = root.callable.FunctionPool;
pub const lookup = root.lookup;
pub const memory = root.memory;
const mem = memory;
const Value = mem.Value;
pub const run = root.run;
pub const opcode = root.opcode;
const Instruction = opcode.Instruction;
pub const Interner = root.interner.Interner;
const TablePool = root.table.TablePool;
const ResourcePool = root.resource.ResourcePool;
pub const GlobalID = mem.StringID;
pub const ChannelID = mem.TableID;
pub const resolveField = lookup.resolveField;
pub const FieldLookup = lookup.FieldLookup;
pub const setMetatable = lookup.setMetatable;
pub const setTableMetatable = lookup.setTableMetatable;
pub const setResourceMetatable = lookup.setResourceMetatable;
pub const runImportedModule = run.runImportedModule;
const Scheduler = @import("scheduler.zig");
const vm_dispatch = @import("dispatch.zig");
const vm_gc = @import("gc.zig");
const vm_perf = @import("perf.zig");
