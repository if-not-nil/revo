const revo = @import("revo");
const VM = @import("VM.zig");

pub inline fn noteGCPressure(self: *VM, bytes: usize) void {
    if (!self.gc_enabled) return;
    self.gc_bytes_allocated += bytes;

    const trigger = @min(self.gc_nursery_threshold, self.gc_threshold);
    if (self.gc_bytes_allocated >= trigger)
        self.gc_pending = true;

    self.gc_instr_counter += 1;
    if ((self.gc_instr_counter & 15) == 0)
        self.maybeCollectGarbage();
}

pub fn maybeCollectGarbage(self: *VM) void {
    if (!self.gc_enabled or !self.gc_pending) return;
    if (self.host_call_depth > 0) return;

    self.gc_bytes_allocated = 0;
    self.tables.clearMarks();
    self.tuples.clearMarks();
    self.functions.clearMarks();
    self.struct_instances.clearMarks();
    self.strings.clearMarks();

    markRoots(self);
    processMarkStack(self);

    self.tables.sweep();
    self.tuples.sweep();
    self.functions.sweep();
    self.struct_instances.sweep();
    self.strings.sweep();

    self.gc_pending = false;
    const live_bytes = self.tables.bytes() +
        self.tuples.bytes() +
        self.functions.bytes() +
        self.strings.bytes();

    self.gc_threshold = @max(32 * 1024, live_bytes * self.gc_pause_factor);
}

pub fn processMarkStack(self: *VM) void {
    while (self.gc_mark_stack.pop()) |item| {
        switch (item) {
            .data => |data| markDataImpl(self, data),
            .table => |id| {
                if (id >= self.tables.tables.items.len) continue;

                const table = self.tables.tables.items[id] orelse continue;
                for (table.array.items) |entry| pushMark(self, entry);

                var cur = table.hash.first;
                while (cur != revo.table.NULL_ID) {
                    pushMark(self, table.hash.buckets[cur].key);
                    pushMark(self, table.hash.buckets[cur].val);
                    cur = table.hash.buckets[cur].next;
                }
                if (table.metatable) |mt|
                    self.tables.mark(mt, self);
            },
            .tuple => |id| {
                if (id >= self.tuples.tuples.items.len) continue;

                const tuple = self.tuples.tuples.items[id] orelse continue;
                for (tuple.items) |entry|
                    pushMark(self, entry);
                if (tuple.metatable) |mt|
                    self.tables.mark(mt, self);
            },
            .function => |id| {
                if (id >= self.functions.functions.items.len) continue;

                const func = self.functions.functions.items[id] orelse continue;
                switch (func) {
                    .closure => |closure| {
                        for (closure.upvalues) |upvalue_id|
                            self.functions.markUpvalue(upvalue_id, self);
                    },
                    .native, .c_function => {},
                }
            },
            .upvalue => |id| {
                if (id >= self.functions.upvalues.items.len)
                    continue;
                const upvalue = self.functions.upvalues.items[id] orelse continue;
                if (upvalue.open_index == null)
                    pushMark(self, upvalue.closed);
            },
            .struct_instance => |id| {
                if (id >= self.struct_instances.instances.items.len)
                    continue;
                const instance = self.struct_instances.instances.items[id] orelse continue;
                for (instance.fields) |entry|
                    pushMark(self, entry);
            },
        }
    }
}

pub inline fn markRoots(self: *VM) void {
    for (self.sched.fibers.items) |fiber| {
        for (fiber.registers[0..fiber.registers_len]) |data|
            pushMark(self, data);
        for (fiber.frames_cold.items) |frame| {
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

    for (self.struct_types.types.items) |*desc| {
        for (desc.fields) |field| {
            if (field.default_val) |val| pushMark(self, val);
        }

        var method_it = desc.methods.iterator();
        while (method_it.next()) |entry| pushMark(self, entry.value_ptr.*);
    }

    var channel_it = self.sched.channels.iterator();
    while (channel_it.next()) |entry| {
        self.tables.mark(entry.key_ptr.*, self);
        const channel = entry.value_ptr;
        for (channel.queue.items[channel.queue_head..]) |value| pushMark(self, value);

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
        .string, .table, .tuple, .function, .struct_val => {
            self.gc_mark_stack.append(self.runtime.alloc, .{ .data = data }) catch @panic("OOM in GC marking");
        },
        else => {},
    }
}

pub inline fn pushMarkTable(self: *VM, id: anytype) void {
    self.gc_mark_stack.append(self.runtime.alloc, .{ .table = id }) catch @panic("OOM in GC marking");
}

pub inline fn pushMarkTuple(self: *VM, id: anytype) void {
    self.gc_mark_stack.append(self.runtime.alloc, .{ .tuple = id }) catch @panic("OOM in GC marking");
}

pub inline fn pushMarkFunction(self: *VM, id: anytype) void {
    self.gc_mark_stack.append(self.runtime.alloc, .{ .function = id }) catch @panic("OOM in GC marking");
}

pub inline fn pushMarkUpvalue(self: *VM, id: anytype) void {
    self.gc_mark_stack.append(self.runtime.alloc, .{ .upvalue = id }) catch @panic("OOM in GC marking");
}

pub inline fn pushMarkStructInstance(self: *VM, id: anytype) void {
    self.gc_mark_stack.append(self.runtime.alloc, .{ .struct_instance = id }) catch @panic("OOM in GC marking");
}

pub inline fn markDataImpl(self: *VM, data: revo.Data) void {
    switch (data.tag()) {
        .string => self.strings.mark(data.asString().?),
        .table => self.tables.mark(
            data.asTable().?,
            self,
        ),
        .tuple => self.tuples.mark(
            data.asTuple().?,
            self,
        ),
        .function => self.functions.mark(
            data.asFunction().?,
            self,
        ),
        .struct_val => self.struct_instances.mark(
            data.asStructVal().?,
            self,
        ),
        else => {},
    }
}

pub fn markData(self: *VM, data: revo.Data) void {
    switch (data.tag()) {
        .string => self.strings.mark(data.asString().?),
        .table => self.tables.mark(
            data.asTable().?,
            self,
        ),
        .tuple => self.tuples.mark(
            data.asTuple().?,
            self,
        ),
        .function => self.functions.mark(
            data.asFunction().?,
            self,
        ),
        .struct_val => self.struct_instances.mark(
            data.asStructVal().?,
            self,
        ),
        else => {},
    }
}
