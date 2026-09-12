const std = @import("std");
const revo = @import("revo");
const VM = @import("VM.zig");

pub inline fn noteGCPressure(self: *VM, bytes: usize) void {
    if (!self.gc_enabled) return;
    self.gc_bytes_allocated += bytes;

    const trigger = @min(self.gc_nursery_threshold, self.gc_threshold);
    if (self.gc_bytes_allocated >= trigger)
        self.gc_pending = true;

    self.gc_check_counter += 1;
    if ((self.gc_check_counter & 15) == 0)
        self.maybeCollectGarbage();
}

pub fn maybeCollectGarbage(self: *VM) void {
    if (!self.gc_enabled or !self.gc_pending) return;
    if (self.host_call_depth > 0) return;
    if (self.gc_in_finalizer) return;

    self.gc_bytes_allocated = 0;
    self.strings.clearMarks();

    markRoots(self);
    processMarkStack(self);

    const finalizer_pending = collectFinalizers(self);

    self.tables.sweep();
    self.functions.sweep();
    self.strings.sweep();

    if (finalizer_pending) |pending| {
        self.gc_in_finalizer = true;
        defer self.gc_in_finalizer = false;
        var pending_list = pending;
        for (pending_list.items) |id| {
            const entry = self.gc_finalizers.fetchRemove(id) orelse continue;
            const table_val = revo.Data.new.table(id);
            _ = self.callFunctionParts(entry.value, null, &.{table_val}, null) catch {};
        }
        pending_list.deinit(self.runtime.alloc);
    }

    self.gc_pending = false;
    const live_bytes = self.tables.bytes() +
        self.functions.bytes() +
        self.strings.bytes();

    self.gc_threshold = @max(512 * 1024, live_bytes * self.gc_pause_factor);
}

fn collectFinalizers(self: *VM) ?std.ArrayList(revo.memory.TableID) {
    const alloc = self.runtime.alloc;
    var pending: ?std.ArrayList(revo.memory.TableID) = null;
    var to_remove: ?std.ArrayList(revo.memory.TableID) = null;
    var it = self.gc_finalizers.iterator();

    while (it.next()) |entry| {
        const id = entry.key_ptr.*;
        if (id >= self.tables.tables.items.len or self.tables.tables.items[id] == null) {
            if (to_remove == null)
                to_remove = std.ArrayList(revo.memory.TableID).initCapacity(alloc, 4) catch @panic("OOM in GC");
            to_remove.?.append(alloc, id) catch @panic("OOM in GC");
            continue;
        }

        if (self.tables.marks.isSet(id)) continue;
        if (pending == null) pending = std.ArrayList(revo.memory.TableID).initCapacity(alloc, 4) catch @panic(
            "OOM in GC",
        );

        pending.?.append(alloc, id) catch @panic("OOM in GC");
        self.tables.marks.set(id);
    }
    if (to_remove) |*remove_list| {
        for (remove_list.items) |id| _ = self.gc_finalizers.remove(id);
        remove_list.deinit(alloc);
    }
    return pending;
}

pub fn processMarkStack(self: *VM) void {
    while (self.gc_mark_stack.pop()) |item| {
        switch (item) {
            .data => |data| self.markData(data),
            .table => |id| {
                if (id >= self.tables.tables.items.len) continue;

                const table = self.tables.tables.items[id] orelse continue;
                var cur = table.cursor();
                while (cur.nextEntry()) |entry| {
                    pushMark(self, entry.key);
                    pushMark(self, entry.value);
                }
                if (table.metatable) |mt|
                    self.tables.mark(mt, self);
            },
            .function => |id| {
                if (id >= self.functions.functions.items.len) continue;

                const func = self.functions.functions.items[id] orelse continue;
                switch (func.*) {
                    .closure => |closure| {
                        for (closure.upvalues) |upvalue_id|
                            self.functions.markUpvalue(upvalue_id, self);
                    },
                    .host, .c_function => {},
                }
            },
            .upvalue => |id| {
                if (id >= self.functions.upvalues.items.len)
                    continue;
                const upvalue = self.functions.upvalues.items[id] orelse continue;
                if (upvalue.open_index == null)
                    pushMark(self, upvalue.closed);
            },
        }
    }
}

pub inline fn markRoots(self: *VM) void {
    for (self.sched.fibers.items) |fiber| {
        for (fiber.registers[0..fiber.registers_len]) |data|
            pushMark(self, data);
        for (fiber.frames.items) |frame| {
            if (frame.closure_id) |id|
                self.functions.mark(id, self);
        }
        for (fiber.open_upvalues.items) |entry|
            self.functions.markUpvalue(entry.id, self);
    }

    var globals_it = self.globals.iterator();
    while (globals_it.next()) |global|
        pushMark(self, global.value_ptr.*);

    for (self.constants.items) |data|
        pushMark(self, data);

    var atom_it = self.atoms.iterator();
    while (atom_it.next()) |entry| {
        self.strings.mark(entry.value_ptr.*);
    }

    inline for (@typeInfo(revo.core_atoms).@"enum".fields) |field| {
        const atom_id: revo.AtomID = @intFromEnum(
            @field(revo.core_atoms, field.name),
        );
        self.strings.mark(atom_id);
    }

    var cache_it = self.module_cache.iterator();
    while (cache_it.next()) |v| pushMark(self, v.value_ptr.*.result);

    var channel_it = self.sched.channels.iterator();
    while (channel_it.next()) |entry| {
        self.tables.mark(entry.key_ptr.*, self);
        const channel = entry.value_ptr;
        {
            const cap = channel.queue.items.len;
            const count = channel.queue_count;
            for (0..count) |i| pushMark(self, channel.queue.items[(channel.queue_head + i) % cap]);
        }

        for (channel.send_waiters.items[channel.send_head..]) |waiter| {
            if (waiter.value) |v| pushMark(self, v);
        }
    }

    for (self.metatables) |mt_id| {
        if (mt_id) |id| self.tables.mark(id, self);
    }
}

pub inline fn pushMark(self: *VM, data: revo.Data) void {
    switch (data.tag()) {
        .string, .table, .function => {
            self.gc_mark_stack.append(self.runtime.alloc, .{ .data = data }) catch @panic("OOM in GC marking");
        },
        else => {},
    }
}

pub inline fn pushMarkTable(self: *VM, id: anytype) void {
    self.gc_mark_stack.append(self.runtime.alloc, .{ .table = id }) catch @panic("OOM in GC marking");
}

pub inline fn pushMarkFunction(self: *VM, id: anytype) void {
    self.gc_mark_stack.append(self.runtime.alloc, .{ .function = id }) catch @panic("OOM in GC marking");
}

pub inline fn pushMarkUpvalue(self: *VM, id: anytype) void {
    self.gc_mark_stack.append(self.runtime.alloc, .{ .upvalue = id }) catch @panic("OOM in GC marking");
}

pub fn markData(self: *VM, data: revo.Data) void {
    switch (data.tag()) {
        .string => self.strings.mark(data.asString().?),
        .table => self.tables.mark(
            data.asTable().?,
            self,
        ),
        .function => self.functions.mark(
            data.asFunction().?,
            self,
        ),
        else => {},
    }
}
