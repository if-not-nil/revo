//!
//! welcome to the shared module
//! for the gc object pools (tables, functions, upvalues)
//!
//! each pool is an append-only ArrayList whose slots never move, so ids stay stable
//! freed slots are reused through a free list sweeping
//! by scanning the whole array is O(high-water mark)
//! workloads that churn garbage grow that watermark forever even though the
//! live set stays small. so every pool threads its live slots through a
//! singly-linked list and sweep walks only that list: O(live) per collection
//!

const std = @import("std");

pub const end = std.math.maxInt(usize);

/// append a brand new slot to the allocated list; call after reserving the
/// slot in the pool array. new slots go on the tail so the sweep walks the
/// list in creation order, same order the old full-array scan used
pub fn link(first: *usize, last: *usize, next: *std.ArrayList(usize), alloc: std.mem.Allocator, id: usize) !void {
    try next.append(alloc, end);
    if (last.* == end) first.* = id else next.items[last.*] = id;
    last.* = id;
}

/// reattach a reused slot to the allocated list
pub inline fn relink(first: *usize, last: *usize, next: *std.ArrayList(usize), id: usize) void {
    next.items[id] = end;
    if (last.* == end) first.* = id else next.items[last.*] = id;
    last.* = id;
}

/// append a brand new value to a pool, reusing a dead slot if one exists.
///
/// values are boxed: the slot array holds stable *T pointers so a pointer from
/// a pool's get() stays valid across later create() calls. the boxes come from
/// box_pool (arena-backed) and are handed back to it on sweep.
pub fn create(
    alloc: std.mem.Allocator,
    comptime T: type,
    comptime ID: type,
    box_pool: *std.heap.MemoryPool(T),
    items: *std.ArrayList(?*T),
    marks: *std.DynamicBitSet,
    dead: *std.ArrayList(ID),
    first: *usize,
    last: *usize,
    next: *std.ArrayList(usize),
    value: T,
) !ID {
    if (dead.pop()) |id| {
        errdefer dead.appendAssumeCapacity(id); // restore the id on failure
        const box = try box_pool.create(alloc);
        box.* = value;
        items.items[id] = box;
        relink(first, last, next, id);
        return id;
    }
    const id: ID = @intCast(items.items.len);
    if (id >= marks.capacity()) {
        try marks.resize(id + 1, false);
    }
    const box = try box_pool.create(alloc);
    errdefer box_pool.destroy(box);
    box.* = value;
    try items.append(alloc, box);
    errdefer _ = items.pop();
    try link(first, last, next, alloc, id);
    return id;
}

/// walk the allocated list, freeing unmarked slots into the free list and
/// clearing the marks of survivors. the list always contains exactly the
/// live slots, so this touches only what marking survived
///
/// `free` releases a dead value's owned resources; the box is then returned to
/// box_pool and the slot nulled, so liveness stays exactly `slot != null` (the
/// same contract get()/mark()/isValid() relied on before boxing)
pub fn sweep(
    alloc: std.mem.Allocator,
    comptime T: type,
    comptime ID: type,
    box_pool: *std.heap.MemoryPool(T),
    items: *std.ArrayList(?*T),
    marks: *std.DynamicBitSet,
    dead: *std.ArrayList(ID),
    first: *usize,
    last: *usize,
    next: *std.ArrayList(usize),
    comptime free: fn (*T, std.mem.Allocator) void,
) void {
    const max_new_dead = items.items.len;
    const existing_dead = dead.items.len;
    _ = dead.ensureTotalCapacity(alloc, existing_dead + max_new_dead) catch return;

    var prev: usize = end;
    var id = first.*;
    while (id != end) {
        const nxt = next.items[id];
        if (!marks.isSet(id)) {
            const box = items.items[id].?;
            free(box, alloc);
            box_pool.destroy(box);
            items.items[id] = null;
            if (prev == end)
                first.* = nxt
            else
                next.items[prev] = nxt;
            dead.appendAssumeCapacity(@intCast(id));
        } else {
            marks.unset(id);
            prev = id;
        }
        id = nxt;
    }
    last.* = prev;
}
