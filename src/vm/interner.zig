const std = @import("std");

const lang = revo.lang;
const lang_testing = revo.lang.testing;
const revo = @import("revo");

const VM = revo.VM;

const memory = @import("memory.zig");

pub const Interner = @This();

alloc: std.mem.Allocator,
slots: std.ArrayList(?[]u8),
marks: std.DynamicBitSet,
dead: std.ArrayList(memory.StringID),
by_name: std.StringHashMap(memory.StringID),

pub fn init(alloc: std.mem.Allocator) !Interner {
    var self = Interner{
        .alloc = alloc,
        .slots = undefined,
        .marks = undefined,
        .dead = .empty,
        .by_name = std.StringHashMap(memory.StringID).init(alloc),
    };
    const core_atoms_fields = @typeInfo(revo.core_atoms).@"enum".fields;

    self.slots = try std.ArrayList(?[]u8).initCapacity(alloc, core_atoms_fields.len);
    errdefer self.slots.deinit(alloc);
    self.marks = try std.DynamicBitSet.initEmpty(alloc, 64);
    errdefer self.marks.deinit();

    inline for (core_atoms_fields) |field| {
        _ = try self.own(field.name);
    }
    return self;
}

pub fn deinit(self: *Interner) void {
    for (self.slots.items) |*maybe_s| {
        if (maybe_s.*) |s| self.alloc.free(s);
    }
    self.by_name.deinit();
    self.slots.deinit(self.alloc);
    self.marks.deinit();
    self.dead.deinit(self.alloc);
}

fn insert(self: *Interner, owned: []u8) !memory.StringID {
    if (self.dead.pop()) |id| {
        self.slots.items[id] = owned;
        return id;
    }
    const id: memory.StringID = @intCast(self.slots.items.len);
    try self.slots.append(self.alloc, owned);
    if (id >= self.marks.capacity()) {
        try self.marks.resize(self.slots.items.len, false);
    }
    return id;
}

pub fn own(self: *Interner, value: []const u8) !memory.StringID {
    if (self.by_name.get(value)) |id| return id;
    const owned = try self.alloc.dupe(u8, value);
    errdefer self.alloc.free(owned);
    const id = try self.insert(owned);
    try self.by_name.put(owned, id);
    return id;
}

pub fn adopt(self: *Interner, value: []u8) !memory.StringID {
    if (self.by_name.get(value)) |id| {
        self.alloc.free(value);
        return id;
    }
    const id = try self.insert(value);
    try self.by_name.put(value, id);
    return id;
}

pub fn adoptNoDedup(self: *Interner, value: []u8) !memory.StringID {
    return self.insert(value);
}

pub fn ownNoDedup(self: *Interner, value: []const u8) !memory.StringID {
    const owned = try self.alloc.dupe(u8, value);
    errdefer self.alloc.free(owned);
    return self.insert(owned);
}

pub fn lookup(self: *const Interner, value: []const u8) ?memory.StringID {
    return self.by_name.get(value);
}

pub fn get(self: *const Interner, id: memory.StringID) ![]const u8 {
    if (id >= self.slots.items.len) return error.InvalidString;
    return self.slots.items[id] orelse error.InvalidString;
}

pub fn getAssumeAlive(self: *const Interner, id: memory.StringID) []const u8 {
    return self.slots.items[id].?;
}

pub fn mark(self: *Interner, id: memory.StringID) void {
    if (id >= self.slots.items.len) return;
    if (self.slots.items[id] != null) self.marks.set(id);
}

pub fn sweep(self: *Interner) void {
    const max_dead = self.slots.items.len;
    self.dead.ensureTotalCapacity(self.alloc, max_dead) catch return;
    self.dead.items.len = 0;
    for (self.slots.items, 0..) |*maybe_s, idx| {
        const s = maybe_s.* orelse continue;
        if (self.marks.isSet(idx)) continue;
        _ = self.by_name.remove(s);
        self.alloc.free(s);
        maybe_s.* = null;
        self.dead.appendAssumeCapacity(@intCast(idx));
    }
    self.marks.unmanaged.unsetAll();
}

pub fn contains(self: *Interner, id: memory.StringID) bool {
    return id < self.slots.items.len and self.slots.items[id] != null;
}

pub fn bytes(self: *const Interner) usize {
    var total: usize = 0;
    for (self.slots.items) |maybe_s| {
        if (maybe_s) |s| {
            total += 24;
            total += s.len;
        }
    }
    return total;
}

pub fn clearMarks(self: *Interner) void {
    self.marks.unmanaged.unsetAll();
}

pub fn capacity(self: *const Interner) usize {
    return self.slots.items.len;
}

pub fn sweepStep(self: *Interner, cursor: usize, limit: usize) usize {
    if (cursor >= self.slots.items.len) return 0;

    const end = @min(cursor + limit, self.slots.items.len);
    var processed: usize = 0;

    var i = cursor;
    while (i < end) : (i += 1) {
        if (self.slots.items[i]) |s| {
            if (!self.marks.isSet(i)) {
                _ = self.by_name.remove(s);
                self.alloc.free(s);
                self.slots.items[i] = null;
                self.dead.append(self.alloc, @intCast(i)) catch {};
            }
        }
        processed += 1;
    }

    return processed;
}

test "string literals survive source free" {
    var vm = try VM.init(lang_testing.runtime());
    defer vm.deinit();

    const alloc = lang_testing.runtime().alloc;
    const source = try alloc.dupe(u8, "\"hello\"");
    const artifact = switch (try lang.build(&vm, .{ .text = source }, .{})) {
        .ok => |ok| ok,
        .err => |err| {
            defer lang.deinitError(alloc, err);
            return error.ParseFailed;
        },
    };
    alloc.free(source);
    defer alloc.free(artifact.instructions);
    defer alloc.free(artifact.spans);

    vm.mainFiber().program = artifact.instructions;

    switch (try vm.runReport()) {
        .err => return error.Failed,
        .ok => {},
    }

    const value = try vm.pop();
    try std.testing.expect(value.isString());
    try std.testing.expectEqualStrings("hello", vm.stringValue(value.asString().?));
}

test "interner deduplicates and reuses freed slot ids" {
    var interner = try Interner.init(std.testing.allocator);
    defer interner.deinit();

    const first = try interner.own("abc");
    const second = try interner.own("abc");
    try std.testing.expectEqual(first, second);

    interner.sweep();
    try std.testing.expect(!interner.contains(first));

    const reused = try interner.own("new");
    try std.testing.expectEqual(first, reused);
    try std.testing.expectEqualStrings("new", try interner.get(reused));
}
