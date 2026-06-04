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

    if (self.gc_sweep_state.phase != .idle and
        self.gc_sweep_state.phase != .done)
    {
        doIncrementalSweep(self);
        if (self.gc_sweep_state.phase == .done) {
            self.gc_sweep_state = .{};
            self.gc_pending = false;
            const live_bytes = self.tables.bytes() +
                self.tuples.bytes() +
                self.functions.bytes() +
                self.strings.bytes();

            self.gc_threshold = @max(32 * 1024, live_bytes * self.gc_pause_factor);
        }
        return;
    }

    self.gc_bytes_allocated = 0;
    self.tables.clearMarks();
    self.tuples.clearMarks();
    self.functions.clearMarks();
    self.struct_instances.clearMarks();
    self.strings.clearMarks();

    markRoots(self);
    processMarkStack(self);

    self.gc_sweep_state.phase = .tables;
    self.gc_sweep_state.cursor = 0;
    doIncrementalSweep(self);

    if (self.gc_sweep_state.phase == .done) {
        self.gc_sweep_state = .{};
        self.gc_pending = false;
        const live_bytes = self.tables.bytes() +
            self.tuples.bytes() +
            self.functions.bytes() +
            self.strings.bytes();
        self.gc_threshold = @max(32 * 1024, live_bytes * self.gc_pause_factor);
    }
}

pub fn doIncrementalSweep(self: *VM) void {
    const step_limit = 1024;
    var processed: usize = 0;

    while (processed < step_limit) {
        switch (self.gc_sweep_state.phase) {
            .idle => return,
            .tables => {
                const count = self.tables.sweepStep(
                    self.gc_sweep_state.cursor,
                    step_limit - processed,
                );
                if (count == 0 or
                    self.gc_sweep_state.cursor >= self.tables.capacity())
                {
                    self.gc_sweep_state.phase = .tuples;
                    self.gc_sweep_state.cursor = 0;
                } else {
                    self.gc_sweep_state.cursor += count;
                    processed += count;
                }
            },
            .tuples => {
                const count = self.tuples.sweepStep(
                    self.gc_sweep_state.cursor,
                    step_limit - processed,
                );
                if (count == 0 or
                    self.gc_sweep_state.cursor >= self.tuples.capacity())
                {
                    self.gc_sweep_state.phase = .functions;
                    self.gc_sweep_state.cursor = 0;
                } else {
                    self.gc_sweep_state.cursor += count;
                    processed += count;
                }
            },
            .functions => {
                const count = self.functions.sweepStep(
                    self.gc_sweep_state.cursor,
                    step_limit - processed,
                );
                if (count == 0 or
                    self.gc_sweep_state.cursor >= self.functions.capacity())
                {
                    self.gc_sweep_state.phase = .upvalues;
                    self.gc_sweep_state.cursor = 0;
                } else {
                    self.gc_sweep_state.cursor += count;
                    processed += count;
                }
            },
            .upvalues => {
                const count = self.functions.sweepUpvalueStep(
                    self.gc_sweep_state.cursor,
                    step_limit - processed,
                );
                if (count == 0 or
                    self.gc_sweep_state.cursor >= self.functions.upvalueCapacity())
                {
                    self.gc_sweep_state.phase = .structs;
                    self.gc_sweep_state.cursor = 0;
                } else {
                    self.gc_sweep_state.cursor += count;
                    processed += count;
                }
            },
            .structs => {
                const count = self.struct_instances.sweepStep(
                    self.gc_sweep_state.cursor,
                    step_limit - processed,
                );
                if (count == 0 or
                    self.gc_sweep_state.cursor >= self.struct_instances.capacity())
                {
                    self.gc_sweep_state.phase = .strings;
                    self.gc_sweep_state.cursor = 0;
                } else {
                    self.gc_sweep_state.cursor += count;
                    processed += count;
                }
            },
            .strings => {
                const count = self.strings.sweepStep(
                    self.gc_sweep_state.cursor,
                    step_limit - processed,
                );
                if (count == 0 or
                    self.gc_sweep_state.cursor >= self.strings.capacity())
                {
                    self.gc_sweep_state.phase = .done;
                    return;
                } else {
                    self.gc_sweep_state.cursor += count;
                    processed += count;
                }
            },
            .done => return,
        }
    }
}

pub fn processMarkStack(self: *VM) void {
    while (self.gc_mark_stack.pop()) |item| {
        switch (item) {
            .data => |data| markDataImpl(self, data),
            .table => |id| {
                if (id >= self.tables.tables.items.len) continue;

                const table = self.tables.tables.items[id] orelse continue;
                for (table.array.items) |entry| pushMark(self, entry);

                var it = table.hash_entries.iterator();
                while (it.next()) |entry| {
                    pushMark(self, entry.key_ptr.*);
                    pushMark(self, entry.value_ptr.*);
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
        for (fiber.frames.items) |frame| {
            if (frame.closure_id) |id|
                self.functions.mark(id, self);
        }
        {
            var next_up = fiber.open_upvalues;
            while (next_up) |id| {
                self.functions.markUpvalue(id, self);
                next_up = (self.functions.getUpvalue(id) catch break).next_open;
            }
        }
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
            self.gc_mark_stack.append(self.runtime.alloc, .{ .data = data }) catch return;
        },
        else => {},
    }
}

pub inline fn pushMarkTable(self: *VM, id: anytype) void {
    self.gc_mark_stack.append(self.runtime.alloc, .{ .table = id }) catch return;
}

pub inline fn pushMarkTuple(self: *VM, id: anytype) void {
    self.gc_mark_stack.append(self.runtime.alloc, .{ .tuple = id }) catch return;
}

pub inline fn pushMarkFunction(self: *VM, id: anytype) void {
    self.gc_mark_stack.append(self.runtime.alloc, .{ .function = id }) catch return;
}

pub inline fn pushMarkUpvalue(self: *VM, id: anytype) void {
    self.gc_mark_stack.append(self.runtime.alloc, .{ .upvalue = id }) catch return;
}

pub inline fn pushMarkStructInstance(self: *VM, id: anytype) void {
    self.gc_mark_stack.append(self.runtime.alloc, .{ .struct_instance = id }) catch return;
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
