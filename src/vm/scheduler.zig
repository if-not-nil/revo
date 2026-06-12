const std = @import("std");

const root = @import("root.zig");
const Data = root.Data;
const VM = root.VM;
const Fiber = VM.Fiber;
const FiberID = VM.FiberID;
const ChannelID = VM.ChannelID;

//
// scheduler
//

pub const Scheduler = @This();

/// fiber waiting on channel, send or recv
pub const ChannelWaiter = struct {
    fiber_id: FiberID,
    value: ?Data = null,
};

/// buffered or unbuffered
pub const ChannelState = struct {
    cap: usize = 0,
    queue: std.ArrayList(Data),
    queue_head: usize = 0,
    send_waiters: std.ArrayList(ChannelWaiter),
    send_head: usize = 0,
    recv_waiters: std.ArrayList(ChannelWaiter),
    recv_head: usize = 0,

    pub fn init(alloc: std.mem.Allocator, cap: usize) !ChannelState {
        var self = ChannelState{
            .cap = cap,
            .queue = undefined,
            .send_waiters = undefined,
            .recv_waiters = undefined,
        };
        self.queue = try std.ArrayList(Data).initCapacity(alloc, if (cap == 0) 1 else cap);
        errdefer self.queue.deinit(alloc);
        self.send_waiters = try std.ArrayList(ChannelWaiter).initCapacity(alloc, 2);
        errdefer self.send_waiters.deinit(alloc);
        self.recv_waiters = try std.ArrayList(ChannelWaiter).initCapacity(alloc, 2);
        errdefer self.recv_waiters.deinit(alloc);

        return self;
    }

    pub fn deinit(self: *ChannelState, alloc: std.mem.Allocator) void {
        self.queue.deinit(alloc);
        self.send_waiters.deinit(alloc);
        self.recv_waiters.deinit(alloc);
    }

    fn queueLen(self: *const ChannelState) usize {
        return self.queue.items.len - self.queue_head;
    }

    fn pushQueue(self: *ChannelState, alloc: std.mem.Allocator, value: Data) !void {
        try self.queue.append(alloc, value);
    }

    fn popQueue(self: *ChannelState) ?Data {
        if (self.queue_head >= self.queue.items.len) return null;
        const value = self.queue.items[self.queue_head];
        self.queue_head += 1;
        maybeCompactList(Data, &self.queue, &self.queue_head);
        return value;
    }

    fn popSendWaiter(self: *ChannelState) ?ChannelWaiter {
        if (self.send_head >= self.send_waiters.items.len) return null;
        const waiter = self.send_waiters.items[self.send_head];
        self.send_head += 1;
        maybeCompactList(ChannelWaiter, &self.send_waiters, &self.send_head);
        return waiter;
    }

    fn popRecvWaiter(self: *ChannelState) ?ChannelWaiter {
        if (self.recv_head >= self.recv_waiters.items.len) return null;
        const waiter = self.recv_waiters.items[self.recv_head];
        self.recv_head += 1;
        maybeCompactList(ChannelWaiter, &self.recv_waiters, &self.recv_head);
        return waiter;
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

/// a fiber waiting on a timer
pub const SleepWaiter = struct {
    fiber_id: FiberID,
    wake_at_ns: u64,
};

pub const IoDispatchResult = struct {
    completed: bool = false,
    woke: bool = false,
};

pub const IoReadyFn = *const fn (vm: *VM, waiter: *WaitEntry, revents: i16) anyerror!IoDispatchResult;
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
};

/// mark a fiber as waiting and store its wait info
inline fn parkFiber(self: *@This(), fid: FiberID, wait: Fiber.WaitKind, result_slot: ?usize) void {
    if (fid >= self.fibers.items.len) return;
    const fiber = &self.fibers.items[fid];
    self.setFiberState(fid, .waiting);
    fiber.running = false; // yield execution
    fiber.wait = wait;
    fiber.parked_result_slot = result_slot;
}

/// park the currently running fiber
pub inline fn parkCurrent(self: *@This(), wait: Fiber.WaitKind) void {
    self.parkFiber(self.current_fiber, wait, null);
}

/// park current fiber and fill a specific result slot when woken
pub fn parkCurrentWithResult(self: *@This(), wait: Fiber.WaitKind, result_slot: usize) void {
    self.parkFiber(self.current_fiber, wait, result_slot);
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
    try self.io_waiters.append(self.alloc, .{
        .fiber_id = self.current_fiber,
        .wait_id = wait_id,
        .intent = intent,
        .token = token,
        .on_ready = on_ready,
        .on_deinit = on_deinit,
    });
    self.parkCurrent(.{ .io = .{ .wait_id = wait_id } });
}

/// wake a waiting fiber, passing optional result into its slot or stack
pub fn wakeFiber(self: *@This(), fid: FiberID, result: ?Data) !void {
    if (fid >= self.fibers.items.len) return;
    var fiber = &self.fibers.items[fid];
    if (fiber.state != .waiting) return;

    if (fiber.parked_result_slot) |slot| {
        if (result) |value| fiber.registers[slot] = value;
    } else if (result) |value| {
        try VM.ensureRegCapacity(fiber, self.alloc, fiber.registers_len + 1);
        fiber.registers[fiber.registers_len] = value;
        fiber.registers_len += 1;
    }

    self.setFiberState(fid, .ready);
    fiber.running = false;
    fiber.wait = .none;
    fiber.parked_result_slot = null;
    try self.enqueueRunnable(fid);
}

current_fiber: FiberID,
alloc: std.mem.Allocator,
fibers: std.ArrayList(Fiber),
ring_buf: []FiberID, // runq
ring_head: usize,
ring_tail: usize,
ring_mask: usize,
sleepers: std.ArrayList(SleepWaiter),
io_waiters: std.ArrayList(WaitEntry),
channels: std.AutoHashMap(ChannelID, ChannelState),
waiting_cnt: usize,

/// init with a 64-slot runq
pub fn init(alloc: std.mem.Allocator) !@This() {
    const ring_cap = 64;
    var self = Scheduler{
        .current_fiber = 0,
        .alloc = alloc,
        .fibers = undefined,
        .ring_buf = undefined,
        .ring_head = 0,
        .ring_tail = 0,
        .ring_mask = ring_cap - 1,
        .sleepers = undefined,
        .io_waiters = undefined,
        .channels = .init(alloc),
        .waiting_cnt = 0,
    };
    self.fibers = try std.ArrayList(Fiber).initCapacity(alloc, 1);
    errdefer self.fibers.deinit(alloc);
    self.ring_buf = try alloc.alloc(FiberID, ring_cap);
    errdefer alloc.free(self.ring_buf);
    self.sleepers = try std.ArrayList(SleepWaiter).initCapacity(alloc, 4);
    errdefer self.sleepers.deinit(alloc);
    self.io_waiters = try std.ArrayList(WaitEntry).initCapacity(alloc, 4);
    errdefer self.io_waiters.deinit(alloc);

    return self;
}

pub fn deinit(self: *@This()) void {
    for (self.fibers.items) |*fiber| fiber.deinit(self.alloc);
    self.fibers.deinit(self.alloc);
    self.alloc.free(self.ring_buf);
    self.sleepers.deinit(self.alloc);
    self.io_waiters.deinit(self.alloc);
    var channel_it = self.channels.valueIterator();
    while (channel_it.next()) |channel| channel.deinit(self.alloc);
    self.channels.deinit();
}

/// get the currently executing fiber
pub inline fn currentFiber(self: *@This()) *Fiber {
    return &self.fibers.items[self.current_fiber];
}

/// get the root (main) fiber
pub inline fn mainFiber(self: *@This()) *Fiber {
    return &self.fibers.items[0];
}

/// update fiber state n track waiting count
pub inline fn setFiberState(self: *@This(), fid: FiberID, new_state: Fiber.State) void {
    if (fid >= self.fibers.items.len) return;
    const fiber = &self.fibers.items[fid];
    const old_state = fiber.state;
    if (old_state == new_state) return;
    // adjust waiting cnt on transition
    if (old_state == .waiting) self.waiting_cnt -|= 1;
    if (new_state == .waiting) self.waiting_cnt += 1;
    fiber.state = new_state;
}

/// add a fiber to the runq; grows if full
pub inline fn enqueueRunnable(self: *@This(), fid: FiberID) !void {
    if (fid >= self.fibers.items.len) return;
    const fiber = &self.fibers.items[fid];
    if (fiber.in_runq or fiber.state != .ready) return;
    const new_tail = (self.ring_tail + 1) & self.ring_mask;
    if (new_tail == self.ring_head) {
        // ring full; grow
        const old_cap = self.ring_buf.len;
        const new_cap = old_cap * 2;
        const new_buf = try self.alloc.alloc(FiberID, new_cap);
        const count = if (self.ring_tail >= self.ring_head) self.ring_tail - self.ring_head else self.ring_tail + old_cap - self.ring_head;
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
        self.ring_buf[self.ring_tail] = fid;
        self.ring_tail = (self.ring_tail + 1) & self.ring_mask;
    } else {
        self.ring_buf[self.ring_tail] = fid;
        self.ring_tail = new_tail;
    }
    fiber.in_runq = true;
}

/// pop the next runnable fiber from runq
pub inline fn dequeueRunnable(self: *@This()) ?FiberID {
    if (self.ring_head == self.ring_tail) return null;
    const fid = self.ring_buf[self.ring_head];
    self.ring_head = (self.ring_head + 1) & self.ring_mask;
    self.fibers.items[fid].in_runq = false;
    return fid;
}

/// mark a fiber as dead and wake all its waiters
pub fn finishFiber(self: *@This(), fid: FiberID, result: Data) !void {
    var fiber = &self.fibers.items[fid];
    fiber.result = result;
    fiber.running = false;
    self.setFiberState(fid, .dead);
    fiber.wait = .none;
    for (fiber.waiters.items) |waiter_id|
        try self.wakeFiber(waiter_id, fiber.result);
    fiber.waiters.items.len = 0;
}

/// park current fiber for a duration in ms
pub fn parkCurrentForSleepMS(self: *@This(), ms: u64, now_ns: u64) !void {
    const wake_at = now_ns + (ms * std.time.ns_per_ms);
    try self.sleepers.append(self.alloc, .{ .fiber_id = self.current_fiber, .wake_at_ns = wake_at });
    self.parkCurrent(.sleep);
}

/// wake any fibers whose sleep timer has expired
pub fn wakeDueSleepers(self: *@This(), now_ns: u64) !void {
    var i: usize = 0;
    while (i < self.sleepers.items.len) {
        const sleeper = self.sleepers.items[i];
        if (sleeper.wake_at_ns <= now_ns) {
            _ = self.sleepers.swapRemove(i);
            try self.wakeFiber(sleeper.fiber_id, null);
            continue;
        }
        i += 1;
    }
}

// ns until the next sleeper wakes (null if none)
pub fn nextSleepDelayNs(self: *@This(), now_ns: u64) ?u64 {
    if (self.sleepers.items.len == 0) return null;
    var min_wake = self.sleepers.items[0].wake_at_ns;
    for (self.sleepers.items[1..]) |sleeper| {
        if (sleeper.wake_at_ns < min_wake) min_wake = sleeper.wake_at_ns;
    }
    if (min_wake <= now_ns) return 0;
    return min_wake - now_ns;
}

pub fn channelCreate(
    self: *@This(),
    tables: anytype,
    cap: usize,
) !ChannelID {
    const id = try tables.create();
    var state = try ChannelState.init(self.alloc, cap);
    errdefer state.deinit(self.alloc);
    try self.channels.put(id, state);
    return id;
}

pub fn channelSend(
    self: *@This(),
    channel_id: ChannelID,
    value: Data,
) !void {
    var channel = self.channels.getPtr(channel_id) orelse return error.InvalidChannel;

    // maybe wake receiver, but validate fiber is still valid and waiting
    while (channel.popRecvWaiter()) |waiter| {
        // fiber id might be stale
        if (waiter.fiber_id >= self.fibers.items.len) continue;
        const recv_fiber = &self.fibers.items[waiter.fiber_id];
        // fiber must still be waiting on this channel
        if (recv_fiber.state != .waiting) continue;
        const waiting_on_recv = switch (recv_fiber.wait) {
            Fiber.WaitKind.recv => |cid| cid == channel_id,
            else => false,
        };
        if (!waiting_on_recv) continue;
        try self.wakeFiber(waiter.fiber_id, value);
        return;
    }

    if (channel.cap > 0 and channel.queueLen() < channel.cap) {
        try channel.pushQueue(self.alloc, value);
        return;
    }

    try channel.send_waiters.append(self.alloc, .{ .fiber_id = self.current_fiber, .value = value });
    const fiber = self.currentFiber();
    self.setFiberState(self.current_fiber, .waiting);
    fiber.running = false;
    fiber.wait = .{ .send = channel_id };
}

pub fn channelRecv(self: *@This(), channel_id: ChannelID) !?Data {
    var channel = self.channels.getPtr(channel_id) orelse return error.InvalidChannel;

    if (channel.queueLen() > 0) {
        const value = channel.popQueue() orelse unreachable;

        // maybe wake sender, if fiber is still valid
        while (channel.cap > 0 and channel.queueLen() < channel.cap) {
            const sender = channel.popSendWaiter() orelse break;
            if (sender.fiber_id >= self.fibers.items.len) continue;
            const sender_fiber = &self.fibers.items[sender.fiber_id];
            if (sender_fiber.state != .waiting) continue;
            const waiting_on_send = switch (sender_fiber.wait) {
                Fiber.WaitKind.send => |cid| cid == channel_id,
                else => false,
            };
            if (!waiting_on_send) continue;
            try channel.pushQueue(self.alloc, sender.value orelse unreachable);
            try self.wakeFiber(sender.fiber_id, null);
            break;
        }
        return value;
    }

    // maybe wake sender directly
    while (channel.popSendWaiter()) |sender| {
        if (sender.fiber_id >= self.fibers.items.len) continue;
        const sender_fiber = &self.fibers.items[sender.fiber_id];
        if (sender_fiber.state != .waiting) continue;
        const waiting_on_send = switch (sender_fiber.wait) {
            Fiber.WaitKind.send => |cid| cid == channel_id,
            else => false,
        };
        if (!waiting_on_send) continue;
        try self.wakeFiber(sender.fiber_id, null);
        return sender.value.?;
    }

    try channel.recv_waiters.append(self.alloc, .{ .fiber_id = self.current_fiber });
    const fiber = self.currentFiber();
    self.setFiberState(self.current_fiber, .waiting);
    fiber.running = false;
    fiber.wait = .{ .recv = channel_id };
    return null;
}
