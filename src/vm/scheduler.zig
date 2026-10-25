//!
//! scheduler? i hardly know her
//!   one per vm, owns every fiber, channel, timer, and io waiter
//!
//! ~ fibers are cooperative: bytecode runs til it parks (channel, sleep,
//!   join, io), yields, or finishes, then runq hands the next ready fiber to whoever is free
//!   ~ threads only ever pick up whole fibers
//!   , a  fiber thats going never migrates mid-quantum
//! ~ locking: everything on Scheduler takes `mutex` unless the name ends in
//!   `Locked`, in which case you already hold it
//!

const std = @import("std");

const revo = @import("revo");
const root = @import("root.zig");
const Value = root.Value;
const VM = root.VM;
const Fiber = VM.Fiber;
const FiberID = VM.FiberID;
const ChannelID = VM.ChannelID;

/// tiny mutex for the scheduler
/// , short critical sections only, never across syscalls or heap work
pub const SpinLock = struct {
    state: std.atomic.Value(u8) = .init(0),

    pub fn lock(self: *@This()) void {
        while (!self.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn tryLock(self: *@This()) bool {
        return self.state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null;
    }

    pub fn unlock(self: *@This()) void {
        self.state.store(0, .release);
    }
};

pub const Scheduler = @This();

threadlocal var tl_sched: ?*Scheduler = null;
threadlocal var tl_fid: FiberID = 0;

/// fiber waiting on channel, send or recv
pub const ChannelWaiter = struct {
    fiber_id: FiberID,
    value: ?Value = null,
};

/// buffered or unbuffered
/// , cap 0 means rendezvous, nothing ever sits in the queue
pub const ChannelState = struct {
    cap: usize = 0,
    /// ring buf; items.len is the capacity
    queue: std.ArrayList(Value),
    queue_head: usize = 0,
    queue_count: usize = 0,
    send_waiters: std.ArrayList(ChannelWaiter),
    send_head: usize = 0,
    recv_waiters: std.ArrayList(ChannelWaiter),
    recv_head: usize = 0,

    pub fn init(alloc: std.mem.Allocator, cap: usize) !ChannelState {
        const queue_cap = if (cap == 0) 1 else cap;
        var queue = try std.ArrayList(Value).initCapacity(alloc, queue_cap);
        errdefer queue.deinit(alloc);
        var send_waiters = try std.ArrayList(ChannelWaiter).initCapacity(alloc, 2);
        errdefer send_waiters.deinit(alloc);
        var recv_waiters = try std.ArrayList(ChannelWaiter).initCapacity(alloc, 2);
        errdefer recv_waiters.deinit(alloc);
        queue.items.len = queue_cap;

        return .{
            .cap = cap,
            .queue = queue,
            .queue_head = 0,
            .queue_count = 0,
            .send_waiters = send_waiters,
            .recv_waiters = recv_waiters,
        };
    }

    pub fn deinit(self: *ChannelState, alloc: std.mem.Allocator) void {
        self.queue.deinit(alloc);
        self.send_waiters.deinit(alloc);
        self.recv_waiters.deinit(alloc);
    }

    fn queueLen(self: *const ChannelState) usize {
        return self.queue_count;
    }

    fn pushQueue(self: *ChannelState, value: Value) !void {
        const cap = self.queue.items.len;
        const tail = (self.queue_head + self.queue_count) % cap;
        self.queue.items[tail] = value;
        self.queue_count += 1;
    }

    fn popQueue(self: *ChannelState) ?Value {
        if (self.queue_count == 0) return null;

        const value = self.queue.items[self.queue_head];
        self.queue_head = (self.queue_head + 1) % self.queue.items.len;
        self.queue_count -= 1;
        return value;
    }
};

/// compact runq when head is past midpoint
fn maybeCompactList(comptime T: type, list: *std.ArrayList(T), head: *usize) void {
    if (head.* == 0) return;
    if (head.* < list.items.len / 2) return;

    const remaining = list.items.len - head.*;
    std.mem.copyForwards(T, list.items[0..remaining], list.items[head.*..]);
    list.items.len = remaining;
    head.* = 0;
}

fn popWaiter(list: *std.ArrayList(ChannelWaiter), head: *usize) ?ChannelWaiter {
    if (head.* >= list.items.len) return null;
    const waiter = list.items[head.*];
    head.* += 1;
    maybeCompactList(ChannelWaiter, list, head);

    return waiter;
}

/// pop the next waiter still parked on this channel, skipping the stale ones
/// , reused ids, woken fibers, re-parked waits
fn popLiveWaiter(
    self: *@This(),
    list: *std.ArrayList(ChannelWaiter),
    head: *usize,
    channel_id: ChannelID,
    dir: enum { send, recv },
) ?ChannelWaiter {
    while (popWaiter(list, head)) |waiter| {
        if (waiter.fiber_id >= self.fibers.items.len) continue;
        const fiber = self.fibers.items[waiter.fiber_id];
        if (fiber.state != .waiting) continue;

        const matches = switch (fiber.wait) {
            .send => |cid| dir == .send and cid == channel_id,
            .recv => |cid| dir == .recv and cid == channel_id,
            else => false,
        };

        if (!matches) continue;
        return waiter;
    }
    return null;
}

/// a fiber waiting on a timer
pub const SleepWaiter = struct {
    fiber_id: FiberID,
    wake_at_ns: u64,
};

/// min-heap sift helper keyed on wake_at_ns
fn siftUp(list: *std.ArrayList(SleepWaiter), idx: usize) void {
    var i = idx;
    while (i > 0) {
        const parent = (i - 1) / 2;
        if (list.items[parent].wake_at_ns <= list.items[i].wake_at_ns) break;
        std.mem.swap(SleepWaiter, &list.items[parent], &list.items[i]);

        i = parent;
    }
}

/// min-heap sift helper keyed on wake_at_ns
fn siftDown(list: *std.ArrayList(SleepWaiter), idx: usize) void {
    var i = idx;
    while (true) {
        const left = i * 2 + 1;
        if (left >= list.items.len) break;
        const right = left + 1;

        const smallest = if (right < list.items.len and
            list.items[right].wake_at_ns < list.items[left].wake_at_ns) right else left;

        if (list.items[smallest].wake_at_ns >= list.items[i].wake_at_ns) break;
        std.mem.swap(SleepWaiter, &list.items[i], &list.items[smallest]);

        i = smallest;
    }
}

/// push a sleeper onto the timer heap
fn pushSleeperLocked(self: *@This(), sleeper: SleepWaiter) !void {
    try self.sleepers.append(self.alloc, sleeper);
    siftUp(&self.sleepers, self.sleepers.items.len - 1);
}

/// pop the earliest sleeper off the timer heap
fn popSleeperLocked(self: *@This()) ?SleepWaiter {
    if (self.sleepers.items.len == 0) return null;
    const top = self.sleepers.items[0];
    const last = self.sleepers.items.len - 1;

    self.sleepers.items[0] = self.sleepers.items[last];
    self.sleepers.items.len = last;
    if (self.sleepers.items.len > 0) siftDown(&self.sleepers, 0);

    return top;
}

pub const IoDispatchResult = struct {
    completed: bool = false,
    woke: bool = false,
};

/// runs gil-held on a poll hit; completed=false means keep waiting
pub const IoReadyFn = *const fn (vm: *VM, waiter: *WaitEntry, revents: i16) anyerror!IoDispatchResult;
/// frees the waiter token once it completes; zero token is a no-op
pub const IoDeinitFn = *const fn (alloc: std.mem.Allocator, token: usize) void;

/// read, write, or both
pub const IoIntent = enum(u8) {
    read = 1,
    write = 2,
    read_write = 3,
};

/// a fiber waiting on an io event with completion callback
pub const WaitEntry = struct {
    fiber_id: FiberID,
    wait_id: u64,
    intent: IoIntent,
    token: usize,
    on_ready: IoReadyFn,
    on_deinit: ?IoDeinitFn = null,
    /// bumps per park, tells apart fd reuse across close/reopen
    generation: u64 = 0,
};

///
/// remove all waiters parked on an fd, returning them owned for completion outside the lock
/// , caller completes each (heap work)
///
pub fn takeIoWaitersFor(self: *@This(), wait_id: u64) !std.ArrayList(WaitEntry) {
    self.mutex.lock();
    defer self.mutex.unlock();
    var out = try std.ArrayList(WaitEntry).initCapacity(self.alloc, 2);
    errdefer out.deinit(self.alloc);
    var idx = self.io_waiters.items.len;

    while (idx > 0) {
        idx -= 1;
        if (self.io_waiters.items[idx].wait_id != wait_id) continue;
        try out.append(self.alloc, self.io_waiters.swapRemove(idx));
    }
    return out;
}

/// mark a fiber as waiting and store its wait info
inline fn parkFiberLocked(self: *@This(), fid: FiberID, wait: Fiber.WaitKind, result_slot: ?usize) void {
    if (fid >= self.fibers.items.len) return;
    const fiber = self.fibers.items[fid];
    self.setFiberStateLocked(fid, .waiting);

    fiber.running = false; // yield execution
    fiber.wait = wait;
    fiber.parked_result_slot = result_slot;

    self.signalWakeup();
}

/// best-effort wakeup write for threads blocked in poll; call with mutex held
/// , a new waiter, sleeper, or queued fiber can unblock the poller
/// , a full pipe still reads as ready and the write end never blocks
inline fn signalWakeup(self: *@This()) void {
    if (revo.can_async and self.thread_count > 1 and self.wakeup_w >= 0) {
        var one: [1]u8 = .{0};
        _ = std.c.write(self.wakeup_w, &one, 1);
    }
}

/// ask workers to drain; pairs every shutdown set so parked
/// workers observe it through the wakeup pipe
pub inline fn requestShutdown(self: *@This()) void {
    self.shutdown.store(true, .release);
    self.signalWakeup();
}

/// park the currently running fiber
pub inline fn parkCurrent(self: *@This(), wait: Fiber.WaitKind) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.parkFiberLocked(self.currentID(), wait, null);
}

/// park current fiber and fill a specific result slot when woken
pub fn parkCurrentWithResult(self: *@This(), wait: Fiber.WaitKind, result_slot: usize) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.parkFiberLocked(self.currentID(), wait, result_slot);
}

/// park current fiber waiting for io with generic token/callback
pub fn parkCurrentForIo(
    self: *@This(),
    wait_id: u64,
    intent: IoIntent,
    token: usize,
    on_ready: IoReadyFn,
    on_deinit: ?IoDeinitFn,
) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.io_generation += 1;
    try self.io_waiters.append(self.alloc, .{
        .fiber_id = self.currentID(),
        .wait_id = wait_id,
        .intent = intent,
        .token = token,
        .on_ready = on_ready,
        .on_deinit = on_deinit,
        .generation = self.io_generation,
    });
    self.parkFiberLocked(self.currentID(), .{ .io = .{ .wait_id = wait_id } }, null);
}

/// wake a waiting fiber, passing optional result into its slot or stack
pub fn wakeFiber(self: *@This(), fid: FiberID, result: ?Value) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    try self.wakeFiberLocked(fid, result);
}

fn wakeFiberLocked(self: *@This(), fid: FiberID, result: ?Value) !void {
    if (fid >= self.fibers.items.len) return;
    var fiber = self.fibers.items[fid];
    if (fiber.state != .waiting) return;

    if (fiber.parked_result_slot) |slot| {
        if (result) |value| fiber.registers[slot] = value;
    } else if (result) |value| {
        try VM.ensureRegCapacity(fiber, self.alloc, fiber.registers_len + 1);
        fiber.registers[fiber.registers_len] = value;
        fiber.registers_len += 1;
    }

    self.setFiberStateLocked(fid, .ready);
    fiber.running = false;
    fiber.wait = .none;
    fiber.parked_result_slot = null;
    try self.enqueueRunnableLocked(fid);
}

current_fiber: FiberID,
alloc: std.mem.Allocator,
mutex: SpinLock = .{},
thread_count: usize = 1,
/// fibers checked out by workers; idle counts these so theft never looks like quiescence
active: usize = 0,
shutdown: std.atomic.Value(bool) = .init(false),
workers: std.ArrayList(std.Thread) = .empty,
// self-pipe to wake a thread blocked in poll when runq work lands
// owned by the VM (created/closed there)
// ; -1 when unavailable
// ; level-triggered and best-effort, a full pipe still reads ready
wakeup_r: c_int = -1,
wakeup_w: c_int = -1,
fiber_arena: *std.heap.ArenaAllocator,
fiber_box_pool: std.heap.MemoryPool(Fiber) = .empty,
fibers: std.ArrayList(*Fiber),
ring_buf: []FiberID, // runq
ring_head: usize,
ring_tail: usize,
ring_mask: usize,
sleepers: std.ArrayList(SleepWaiter),
io_waiters: std.ArrayList(WaitEntry),
/// bumps per park, stamps WaitEntry.generation
io_generation: u64 = 0,
channels: std.AutoHashMap(ChannelID, ChannelState),
/// how many fibers sit in .waiting
waiting_cnt: usize,
/// dead ids with buffers kept, ready to reuse
free_fibers: std.ArrayList(FiberID),
/// dead ids with buffers freed, re-init on reuse
free_slots: std.ArrayList(FiberID),

/// init with a 64-slot runq
pub fn init(alloc: std.mem.Allocator) !@This() {
    const ring_cap = 64;
    const fiber_arena = try alloc.create(std.heap.ArenaAllocator);
    fiber_arena.* = std.heap.ArenaAllocator.init(alloc);
    errdefer {
        fiber_arena.deinit();
        alloc.destroy(fiber_arena);
    }
    var self = Scheduler{
        .current_fiber = 0,
        .alloc = alloc,
        .fiber_arena = fiber_arena,
        .fibers = .empty,
        .ring_buf = &[_]FiberID{},
        .ring_head = 0,
        .ring_tail = 0,
        .ring_mask = ring_cap - 1,
        .sleepers = .empty,
        .io_waiters = .empty,
        .channels = .init(alloc),
        .waiting_cnt = 0,
        .free_fibers = .empty,
        .free_slots = .empty,
    };
    self.fibers = try std.ArrayList(*Fiber).initCapacity(alloc, 1);
    errdefer self.fibers.deinit(alloc);
    self.ring_buf = try alloc.alloc(FiberID, ring_cap);
    errdefer alloc.free(self.ring_buf);
    self.sleepers = try std.ArrayList(SleepWaiter).initCapacity(alloc, 4);
    errdefer self.sleepers.deinit(alloc);
    self.io_waiters = try std.ArrayList(WaitEntry).initCapacity(alloc, 4);
    errdefer self.io_waiters.deinit(alloc);
    self.free_fibers = try std.ArrayList(FiberID).initCapacity(alloc, 8);
    errdefer self.free_fibers.deinit(alloc);
    self.free_slots = try std.ArrayList(FiberID).initCapacity(alloc, 8);
    errdefer self.free_slots.deinit(alloc);
    self.workers = try std.ArrayList(std.Thread).initCapacity(alloc, 4);
    errdefer self.workers.deinit(alloc);

    return self;
}

pub fn deinit(self: *@This()) void {
    for (self.fibers.items) |box| {
        box.deinit(self.alloc);
    }
    self.fiber_box_pool.deinit(self.alloc);
    self.fibers.deinit(self.alloc);
    self.alloc.free(self.ring_buf);
    self.sleepers.deinit(self.alloc);
    self.io_waiters.deinit(self.alloc);
    self.free_fibers.deinit(self.alloc);
    self.free_slots.deinit(self.alloc);
    std.debug.assert(self.workers.items.len == 0);
    self.workers.deinit(self.alloc);
    var channel_it = self.channels.valueIterator();
    while (channel_it.next()) |channel| channel.deinit(self.alloc);
    self.channels.deinit();
    self.fiber_arena.deinit();
    self.alloc.destroy(self.fiber_arena);
}

///
/// box a fresh fiber into the pool
/// , boxes stay put across appends so dispatchers can cache *Fiber while others spawn
///
pub fn appendFiber(self: *@This(), child: Fiber) !FiberID {
    const box = try self.fiber_box_pool.create(self.alloc);
    errdefer self.fiber_box_pool.destroy(box);
    box.* = child;
    errdefer box.deinit(self.alloc);

    try self.fibers.append(self.alloc, box);
    return @intCast(self.fibers.items.len - 1);
}

/// get the currently executing fiber
pub inline fn currentFiber(self: *@This()) *Fiber {
    return self.fibers.items[self.currentID()];
}

///
/// this thread's fiber on this scheduler if dispatching, else the field
/// , dispatch always sets both via setCurrent, so solo behavior is unchanged
///
pub inline fn currentID(self: *@This()) FiberID {
    if (tl_sched == self) return tl_fid;
    return self.current_fiber;
}

/// record a quantum's fiber for this thread; always paired with the field
/// , the threadlocals skip the `mutex` rule, this is what keeps them in sync
pub inline fn setCurrent(self: *@This(), fid: FiberID) void {
    tl_sched = self;
    tl_fid = fid;
    self.current_fiber = fid;
}

pub inline fn lock(self: *@This()) void {
    self.mutex.lock();
}

pub inline fn unlock(self: *@This()) void {
    self.mutex.unlock();
}

///
/// dequeue a fiber and mark it checked out
/// , pair with quantumDone; idle detection counts checked-out fibers so a stolen fiber never looks like global idle
///
pub fn takeRunnable(self: *@This()) ?FiberID {
    self.mutex.lock();
    defer self.mutex.unlock();
    const fid = self.dequeueRunnableLocked() orelse return null;

    self.active += 1;
    return fid;
}

pub fn quantumDone(self: *@This()) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.active -= 1;
}

/// false while anything is runnable, waiting, sleeping, or checked out
/// , baseline exempts our own ancestral quanta
pub fn isIdle(self: *@This(), active_baseline: usize) bool {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.active > active_baseline) return false;
    if (self.ring_head != self.ring_tail) return false;
    if (self.waiting_cnt > 0) return false;
    if (self.sleepers.items.len > 0) return false;

    return true;
}

/// get the root (main) fiber
pub inline fn mainFiber(self: *@This()) *Fiber {
    return self.fibers.items[0];
}

/// update fiber state and track waiting count
pub inline fn setFiberState(self: *@This(), fid: FiberID, new_state: Fiber.State) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    self.setFiberStateLocked(fid, new_state);
}

inline fn setFiberStateLocked(self: *@This(), fid: FiberID, new_state: Fiber.State) void {
    if (fid >= self.fibers.items.len) return;
    const fiber = self.fibers.items[fid];
    const old_state = fiber.state;

    if (old_state == new_state) return;
    // adjust waiting cnt on transition
    if (old_state == .waiting) self.waiting_cnt -|= 1;
    if (new_state == .waiting) self.waiting_cnt += 1;

    fiber.state = new_state;
}

/// add a fiber to the runq; grows if full
pub inline fn enqueueRunnable(self: *@This(), fid: FiberID) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    try self.enqueueRunnableLocked(fid);
}

inline fn enqueueRunnableLocked(self: *@This(), fid: FiberID) !void {
    if (fid >= self.fibers.items.len) return;
    const fiber = self.fibers.items[fid];
    if (fiber.in_run_queue or fiber.state != .ready) return;

    const new_tail = (self.ring_tail + 1) & self.ring_mask;
    if (new_tail == self.ring_head) try self.growRingLocked();

    self.ring_buf[self.ring_tail] = fid;
    self.ring_tail = (self.ring_tail + 1) & self.ring_mask;
    fiber.in_run_queue = true;

    self.signalWakeup();
}

/// double the runq ring keeping dequeue order
/// , call with the mutex held when head meets tail
fn growRingLocked(self: *@This()) !void {
    const old_cap = self.ring_buf.len;
    const new_cap = old_cap * 2;
    const new_buf = try self.alloc.alloc(FiberID, new_cap);
    const count = if (self.ring_tail >= self.ring_head)
        self.ring_tail - self.ring_head
    else
        self.ring_tail + old_cap - self.ring_head;
    if (self.ring_head + count <= old_cap) {
        @memcpy(new_buf[0..count], self.ring_buf[self.ring_head..][0..count]);
    } else {
        const first = old_cap - self.ring_head;
        @memcpy(new_buf[0..first], self.ring_buf[self.ring_head..]);
        @memcpy(new_buf[first..][0..(count - first)], self.ring_buf[0..(count - first)]);
    }

    self.alloc.free(self.ring_buf);
    self.ring_buf = new_buf;
    self.ring_head = 0;
    self.ring_tail = count;
    self.ring_mask = new_cap - 1;
}

/// pop the next runnable fiber from runq
pub inline fn dequeueRunnable(self: *@This()) ?FiberID {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.dequeueRunnableLocked();
}

inline fn dequeueRunnableLocked(self: *@This()) ?FiberID {
    if (self.ring_head == self.ring_tail) return null;

    const fid = self.ring_buf[self.ring_head];
    self.ring_head = (self.ring_head + 1) & self.ring_mask;
    self.fibers.items[fid].in_run_queue = false;

    return fid;
}

/// used by dispatcher to switch fibers inplace instead of unwinding run loop
pub inline fn switchNext(self: *@This()) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.switchNextLocked();
}

inline fn switchNextLocked(self: *@This()) bool {
    while (self.dequeueRunnableLocked()) |fid| {
        const fiber = self.fibers.items[fid];
        if (fiber.state == .dead) continue;
        self.setCurrent(fid);
        self.setFiberStateLocked(fid, .running);
        fiber.running = true;
        return true;
    }
    return false;
}

/// dead fibers kept warm on the free list for reuse; beyond this, buffers
/// are freed so spawn-heavy programs don't retain a buffer per fiber forever
const FREE_FIBER_CAP: usize = 256;
/// buffer-free dead fiber slots kept for id reuse beyond FREE_FIBER_CAP
const FREE_SLOT_CAP: usize = 1024;

/// mark a fiber as dead and wake all its waiters
pub fn finishFiber(self: *@This(), fid: FiberID, result: Value) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    try self.finishFiberLocked(fid, result);
}

fn finishFiberLocked(self: *@This(), fid: FiberID, result: Value) !void {
    var fiber = self.fibers.items[fid];
    fiber.result = result;
    fiber.running = false;
    self.setFiberStateLocked(fid, .dead);
    fiber.wait = .none;

    for (fiber.waiters.items) |waiter_id|
        try self.wakeFiberLocked(waiter_id, fiber.result);

    fiber.waiters.items.len = 0;
    fiber.frames.items.len = 0;
    fiber.top_base = 0;
    fiber.open_upvalues.items.len = 0;

    if (fid != 0) {
        if (self.free_fibers.items.len < FREE_FIBER_CAP) {
            try self.free_fibers.append(self.alloc, fid);
        } else {
            // past the warm pool, drop buffers so spawn-heavy programs dont
            // retain a buffer per fiber forever; the id stays reusable
            // through `free_slots` when theres room
            fiber.deinit(self.alloc);
            fiber.registers = &.{};
            fiber.frames = .empty;
            fiber.open_upvalues = .empty;
            fiber.waiters = .empty;
            if (self.free_slots.items.len < FREE_SLOT_CAP)
                try self.free_slots.append(self.alloc, fid);
        }
    }
}

/// park current fiber for a duration in ms
pub fn parkCurrentForSleepMS(self: *@This(), ms: u64, now_ns: u64) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    const wake_at = now_ns + (ms * std.time.ns_per_ms);
    try self.pushSleeperLocked(.{ .fiber_id = self.currentID(), .wake_at_ns = wake_at });
    self.parkFiberLocked(self.currentID(), .sleep, null);
}

/// wake any fibers whose sleep timer has expired
pub inline fn wakeDueSleepers(self: *@This(), now_ns: u64) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    try self.wakeDueSleepersLocked(now_ns);
}

inline fn wakeDueSleepersLocked(self: *@This(), now_ns: u64) !void {
    while (self.sleepers.items.len > 0) {
        if (self.sleepers.items[0].wake_at_ns > now_ns) break;
        const sleeper = self.popSleeperLocked() orelse break;
        try self.wakeFiberLocked(sleeper.fiber_id, null);
    }
}

// ns until the next sleeper wakes (null if none)
pub inline fn nextSleepDelayNs(self: *@This(), now_ns: u64) ?u64 {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.sleepers.items.len == 0) return null;
    const min_wake = self.sleepers.items[0].wake_at_ns;
    if (min_wake <= now_ns) return 0;
    return min_wake - now_ns;
}

pub fn channelCreate(
    self: *@This(),
    tables: anytype,
    cap: usize,
) !ChannelID {
    self.mutex.lock();
    defer self.mutex.unlock();

    const id = try tables.create();
    var state = try ChannelState.init(self.alloc, cap);
    errdefer state.deinit(self.alloc);
    try self.channels.put(id, state);

    return id;
}

/// deliver or park; parks the sender when nobody can take it right now
pub fn channelSend(
    self: *@This(),
    channel_id: ChannelID,
    value: Value,
) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    try self.channelSendLocked(channel_id, value);
}

fn channelSendLocked(
    self: *@This(),
    channel_id: ChannelID,
    value: Value,
) !void {
    var channel = self.channels.getPtr(channel_id) orelse return error.InvalidChannel;

    // hand off straight to a live receiver when one is parked
    if (popLiveWaiter(self, &channel.recv_waiters, &channel.recv_head, channel_id, .recv)) |waiter| {
        try self.wakeFiberLocked(waiter.fiber_id, value);
        return;
    }

    if (channel.cap > 0 and channel.queueLen() < channel.cap) {
        try channel.pushQueue(value);
        return;
    }

    try channel.send_waiters.append(self.alloc, .{ .fiber_id = self.currentID(), .value = value });
    const fiber = self.currentFiber();
    self.setFiberStateLocked(self.currentID(), .waiting);
    fiber.running = false;
    fiber.wait = .{ .send = channel_id };
    self.signalWakeup();
}

/// null means parked, the value gets delivered on wake
pub fn channelRecv(self: *@This(), channel_id: ChannelID) !?Value {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.channelRecvLocked(channel_id);
}

fn channelRecvLocked(self: *@This(), channel_id: ChannelID) !?Value {
    var channel = self.channels.getPtr(channel_id) orelse return error.InvalidChannel;

    if (channel.queueLen() > 0) {
        const value = channel.popQueue() orelse unreachable;

        // refill a freed buffer slot from a parked sender
        while (channel.cap > 0 and channel.queueLen() < channel.cap) {
            const sender = popLiveWaiter(self, &channel.send_waiters, &channel.send_head, channel_id, .send) orelse break;
            try channel.pushQueue(sender.value orelse unreachable);
            try self.wakeFiberLocked(sender.fiber_id, null);
            break;
        }
        return value;
    }

    // rendezvous: no buffer, hand the sender value straight over
    if (popLiveWaiter(self, &channel.send_waiters, &channel.send_head, channel_id, .send)) |sender| {
        try self.wakeFiberLocked(sender.fiber_id, null);
        return sender.value.?;
    }

    try channel.recv_waiters.append(self.alloc, .{ .fiber_id = self.currentID() });
    const fiber = self.currentFiber();
    self.setFiberStateLocked(self.currentID(), .waiting);
    fiber.running = false;
    fiber.wait = .{ .recv = channel_id };
    self.signalWakeup();
    return null;
}
