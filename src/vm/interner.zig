const std = @import("std");

const lang = revo.lang;
const lang_testing = revo.lang.test_helpers;
const revo = @import("revo");

const VM = revo.VM;

const memory = @import("memory.zig");

pub const Interner = @This();

alloc: std.mem.Allocator,
slots: std.ArrayList(?[]u8),
marks: std.bit_set.Dynamic,
dead: std.ArrayList(memory.StringID),
by_name: std.StringHashMap(memory.StringID),

pub fn init(alloc: std.mem.Allocator) !Interner {
    const core_atom_names = @typeInfo(revo.CoreAtoms).@"enum".field_names;
    var self = Interner{
        .alloc = alloc,
        .slots = try std.ArrayList(?[]u8).initCapacity(alloc, core_atom_names.len),
        .marks = try std.bit_set.Dynamic.initEmpty(alloc, 64),
        .dead = .empty,
        .by_name = std.StringHashMap(memory.StringID).init(alloc),
    };
    errdefer self.slots.deinit(alloc);
    errdefer self.marks.deinit(self.alloc);

    inline for (core_atom_names) |atom_name| {
        _ = try self.own(atom_name);
    }
    return self;
}

pub fn deinit(self: *Interner) void {
    for (self.slots.items) |*maybe_s| {
        if (maybe_s.*) |s| self.alloc.free(s);
    }
    self.by_name.deinit();
    self.slots.deinit(self.alloc);
    self.marks.deinit(self.alloc);
    self.dead.deinit(self.alloc);
}

pub fn adoptNoDedup(self: *Interner, owned: []u8) !memory.StringID {
    if (self.dead.pop()) |id| {
        self.slots.items[id] = owned;
        return id;
    }
    const id: memory.StringID = @intCast(self.slots.items.len);
    try self.slots.append(self.alloc, owned);
    if (id >= self.marks.capacity()) {
        try self.marks.resize(self.alloc, self.slots.items.len, false);
    }
    return id;
}

pub fn own(self: *Interner, value: []const u8) !memory.StringID {
    if (self.by_name.get(value)) |id| return id;
    const owned = try self.alloc.dupe(u8, value);
    errdefer self.alloc.free(owned);
    const id = try self.adoptNoDedup(owned);
    try self.by_name.put(owned, id);
    return id;
}

pub fn adopt(self: *Interner, value: []u8) !memory.StringID {
    if (self.by_name.get(value)) |id| {
        self.alloc.free(value);
        return id;
    }
    const id = try self.adoptNoDedup(value);
    try self.by_name.put(value, id);
    return id;
}

pub fn ownNoDedup(self: *Interner, value: []const u8) !memory.StringID {
    const owned = try self.alloc.dupe(u8, value);
    errdefer self.alloc.free(owned);
    return self.adoptNoDedup(owned);
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
    const existing_dead = self.dead.items.len;
    const max_new_dead = self.slots.items.len;
    self.dead.ensureTotalCapacity(self.alloc, existing_dead + max_new_dead) catch return;
    for (self.slots.items, 0..) |*maybe_s, idx| {
        const s = maybe_s.* orelse continue;
        if (self.marks.isSet(idx)) continue;
        _ = self.by_name.remove(s);
        self.alloc.free(s);
        maybe_s.* = null;
        self.dead.appendAssumeCapacity(@intCast(idx));
    }
    self.marks.unsetAll();
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
    self.marks.unsetAll();
}

pub fn capacity(self: *const Interner) usize {
    return self.slots.items.len;
}

test "string literals survive source free" {
    var vm = try VM.init(lang_testing.runtime());
    defer vm.deinit();

    const alloc = lang_testing.runtime().alloc;
    const source = try alloc.dupe(u8, "\"hello\"");
    const bytecode = switch (try lang.build(&vm, .{ .text = source }, .{})) {
        .ok => |ok| ok,
        .err => |err| {
            defer lang.deinitError(err);
            return error.ParseFailed;
        },
    };
    alloc.free(source);
    defer alloc.free(bytecode.instructions);
    defer alloc.free(bytecode.spans);

    vm.mainFiber().program = bytecode.instructions;

    switch (try revo.vm.dispatch.runReport(&vm)) {
        .err => return error.Failed,
        .ok => {},
    }

    const value = try vm.pop();
    try std.testing.expect(value.tag() == .string);
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
