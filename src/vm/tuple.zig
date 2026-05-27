const std = @import("std");

const revo = @import("revo");

const memory = revo.memory;
const Data = revo.Data;
const testing = revo.lang.testing;

pub const Tuple = struct {
    alloc: std.mem.Allocator,
    items: []Data,
    metatable: ?memory.TableID = null,

    pub fn deinit(self: *Tuple) void {
        self.alloc.free(self.items);
    }

    pub fn len(self: *const Tuple) usize {
        return self.items.len;
    }

    pub fn write(self: *Tuple, writer: *std.Io.Writer, vm: *revo.VM, mode: Data.RenderMode) anyerror!void {
        return revo.vm.print.writeTuple(self, writer, vm, mode);
    }
};

pub const TuplePool = struct {
    alloc: std.mem.Allocator,
    tuples: std.ArrayList(?Tuple),
    marks: std.DynamicBitSet,
    dead: std.ArrayList(memory.TupleID),

    pub fn init(alloc: std.mem.Allocator) !TuplePool {
        return .{
            .alloc = alloc,
            .tuples = try std.ArrayList(?Tuple).initCapacity(alloc, 4),
            .marks = try std.DynamicBitSet.initEmpty(alloc, 64),
            .dead = try std.ArrayList(memory.TupleID).initCapacity(alloc, 0),
        };
    }

    pub fn deinit(self: *TuplePool) void {
        for (self.tuples.items) |*maybe_t| {
            if (maybe_t.*) |*t| t.deinit();
        }
        self.tuples.deinit(self.alloc);
        self.marks.deinit();
        self.dead.deinit(self.alloc);
    }

    pub fn create(self: *TuplePool, items: []const Data) !memory.TupleID {
        const owned = try self.alloc.dupe(Data, items);
        errdefer self.alloc.free(owned);
        if (self.dead.pop()) |id| {
            self.tuples.items[id] = .{ .alloc = self.alloc, .items = owned };
            return id;
        }
        const id: memory.TupleID = @intCast(self.tuples.items.len);
        try self.tuples.append(self.alloc, .{ .alloc = self.alloc, .items = owned });
        if (id >= self.marks.capacity()) {
            try self.marks.resize(self.tuples.items.len, false);
        }
        return id;
    }

    pub fn get(self: *TuplePool, id: memory.TupleID) !*Tuple {
        if (id >= self.tuples.items.len) return error.InvalidTuple;
        if (self.tuples.items[id]) |*t| return t;
        return error.InvalidTuple;
    }

    pub fn mark(self: *TuplePool, id: memory.TupleID, vm: *revo.VM) void {
        if (id >= self.tuples.items.len) return;
        if (self.marks.isSet(id)) return;
        if (self.tuples.items[id] == null) return;
        self.marks.set(id);
        vm.pushMarkTuple(id);
    }

    pub fn sweep(self: *TuplePool) void {
        const max_dead = self.tuples.items.len;
        self.dead.ensureTotalCapacity(self.alloc, max_dead) catch return;
        self.dead.items.len = 0;
        for (self.tuples.items, 0..) |*maybe_t, idx| {
            if (maybe_t.* == null) continue;
            if (self.marks.isSet(idx)) continue;
            maybe_t.*.?.deinit();
            maybe_t.* = null;
            self.dead.appendAssumeCapacity(@intCast(idx));
        }
        self.marks.unmanaged.unsetAll();
    }

    pub fn bytes(self: *const TuplePool) usize {
        var total: usize = 0;
        for (self.tuples.items) |maybe_t| {
            if (maybe_t) |t| {
                total += 32;
                total += @sizeOf(Data) * t.items.len;
            }
        }
        return total;
    }

    pub fn clearMarks(self: *TuplePool) void {
        self.marks.unmanaged.unsetAll();
    }

    pub fn capacity(self: *const TuplePool) usize {
        return self.tuples.items.len;
    }

    pub fn sweepStep(self: *TuplePool, cursor: usize, limit: usize) usize {
        if (cursor >= self.tuples.items.len) return 0;

        const end = @min(cursor + limit, self.tuples.items.len);
        var processed: usize = 0;

        for (cursor..end) |i| {
            if (self.tuples.items[i]) |*t| {
                if (!self.marks.isSet(i)) {
                    t.deinit();
                    self.tuples.items[i] = null;
                    self.dead.append(self.alloc, @intCast(i)) catch {};
                }
            }
            processed += 1;
        }

        return processed;
    }
};

test "parses tuple literals and keeps paren grouping distinct" {
    try testing.expectPrinted("(1, 2, 3)", "(tuple 1 2 3)");
    try testing.expectPrinted("(_, x)", "(tuple _ x)");
    try testing.expectPrinted("(1,)", "(tuple 1)");
    try testing.expectPrinted("(1)", "1");
    try testing.top_nil("()");
}

test "parses tuple destructuring in bindings assignment and match" {
    try testing.expectPrinted(
        \\ const a, b = (:ok, "value")
        \\ (a, b) = (:err, "other")
        \\ match (:ok, "x")
        \\ | (:ok, value) => value
        \\ | (:err, err) => err
    , "(block (const (tuple-pattern a b) (tuple :ok \"value\")) (assign (tuple-pattern a b) (tuple :err \"other\")) (match (tuple :ok \"x\") (arm (tuple-pattern :ok value) value) (arm (tuple-pattern :err err) err)))");
}

test "tuple destructuring ignores extras but errors when too short" {
    try testing.top_number(
        \\ const a, b = (1, 2, 3)
        \\ a + b
    , 3);
}

test "tuple destructuring" {
    try testing.top_true(":true");
}

test "tuple length" {
    try testing.top_number(
        \\ const t = (1, 2, 3, 4, 5)
        \\ len(t)
    , 5);
}
