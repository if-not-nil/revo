const Ts = root.T;

pub const Impl = struct {
    pub fn connect(vm: *VM, host: Ts.string, port: Ts.number) !HostResult {
        const host_str = vm.stringValue(@intFromEnum(host));
        const port_int: u16 = root.numToInt(u16, port) orelse
            return .errType(1, "port num 0..65535", root.typeof(Data.new.num(port), vm));

        const host_to_use = if (std.mem.eql(u8, host_str, "localhost")) "127.0.0.1" else host_str;
        const addr = std.Io.net.IpAddress.parseIp4(host_to_use, port_int) catch |err| {
            return HostResult.Err(vm, @errorName(err));
        };

        if (revo.has_async_backend) {
            const ip4 = switch (addr) {
                .ip4 => |a| a,
                .ip6 => return HostResult.Err(vm, "AddressFamilyUnsupported"),
            };
            const addr_buf = try vm.runtime.alloc.alloc(u8, 6);
            addr_buf[0] = ip4.bytes[0];
            addr_buf[1] = ip4.bytes[1];
            addr_buf[2] = ip4.bytes[2];
            addr_buf[3] = ip4.bytes[3];
            std.mem.writeInt(u16, addr_buf[4..6], ip4.port, .native);

            const job = try vm.runtime.alloc.create(revo.async_backend.AsyncJob);
            job.* = .{
                .fiber_id = vm.sched.current_fiber,
                .kind = revo.async_backend.AsyncJobKind.socket_connect,
                .handle = -1,
                .message_id = 0,
                .offset = 0,
                .buffer = addr_buf,
                .max_bytes = 0,
            };
            _ = try revo.async_backend_impl.submit(
                &vm.runtime.async_backend,
                @ptrCast(vm),
                job,
            );
            vm.sched.parkCurrent(.{ .io = .{ .wait_id = 0 } });
            return .parked();
        }

        const stream = addr.connect(vm.runtime.io, .{
            .mode = std.Io.net.Socket.Mode.stream,
            .protocol = std.Io.net.Protocol.tcp,
        }) catch |err| {
            return HostResult.Err(vm, @errorName(err));
        };

        setSocketNonBlocking(stream.socket.handle) catch |err| {
            stream.close(vm.runtime.io);
            return HostResult.Err(vm, @errorName(err));
        };

        const entry_ptr = try vm.runtime.alloc.create(SocketEntry);
        entry_ptr.* = .{ .stream = .{ .socket = stream } };

        return HostResult.Ok(vm, try wrapSocket(vm, entry_ptr, false));
    }

    pub fn accept(vm: *VM, self: Ts.table) !HostResult {
        if (builtin.target.os.tag == .windows) return error.OsNotSupported;
        const socket_data = Data.new.table(@intFromEnum(self));

        if (!try isServer(socket_data, vm)) return HostResult.Err(vm, "NotServerSocket");

        const entry_ptr = try getEntryPtr(socket_data, vm);
        const server = switch (entry_ptr.*) {
            .server => |*s| s,
            .stream => return HostResult.Err(vm, "NotServerSocket"),
        };

        if (revo.has_async_backend) {
            const job = try vm.runtime.alloc.create(revo.async_backend.AsyncJob);
            job.* = .{
                .fiber_id = vm.sched.current_fiber,
                .kind = revo.async_backend.AsyncJobKind.socket_accept,
                .handle = server.socket.handle,
                .message_id = 0,
                .offset = 0,
                .buffer = null,
                .max_bytes = 0,
            };
            _ = try revo.async_backend_impl.submit(
                &vm.runtime.async_backend,
                @ptrCast(vm),
                job,
            );
            vm.sched.parkCurrent(.{ .io = .{ .wait_id = @intCast(server.socket.handle) } });
            return .parked();
        }

        const rc = std.c.accept(server.socket.handle, null, null);
        switch (std.posix.errno(rc)) {
            .AGAIN => {
                try vm.sched.parkCurrentForIo(
                    @intCast(server.socket.handle),
                    .read,
                    0,
                    onAcceptReady,
                    null,
                );
                return .parked();
            },
            .SUCCESS => {},
            else => |err| return HostResult.Err(vm, @tagName(err)),
        }
        const handle: std.posix.fd_t = @intCast(rc);
        setSocketNonBlocking(handle) catch |err| {
            _ = std.c.close(handle);
            return HostResult.Err(vm, @errorName(err));
        };
        const new_entry_ptr = try vm.runtime.alloc.create(SocketEntry);
        new_entry_ptr.* = .{
            .stream = .{
                .socket = .{
                    .socket = .{
                        .handle = handle,
                        .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } },
                    },
                },
                .pending = &.{},
            },
        };
        return HostResult.Ok(vm, try wrapSocket(vm, new_entry_ptr, false));
    }

    pub fn send(vm: *VM, self: Ts.table, data: Ts.string) !HostResult {
        if (builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) return error.OsNotSupported;
        const socket_data = Data.new.table(@intFromEnum(self));
        const message = vm.stringValue(@intFromEnum(data));

        if (try isServer(socket_data, vm)) return HostResult.Err(vm, "CannotSendOnServer");

        const entry_ptr = try getEntryPtr(socket_data, vm);
        const stream = switch (entry_ptr.*) {
            .stream => |*s| s,
            .server => return HostResult.Err(vm, "CannotSendOnServer"),
        };

        const handle = stream.socket.socket.handle;

        if (revo.has_async_backend) {
            const job = try vm.runtime.alloc.create(revo.async_backend.AsyncJob);
            job.* = .{
                .fiber_id = vm.sched.current_fiber,
                .kind = revo.async_backend.AsyncJobKind.socket_send,
                .handle = handle,
                .message_id = @intFromEnum(data),
                .offset = 0,
                .buffer = null,
                .max_bytes = 0,
            };
            _ = try revo.async_backend_impl.submit(
                &vm.runtime.async_backend,
                @ptrCast(vm),
                job,
            );
            vm.sched.parkCurrent(.{ .io = .{ .wait_id = @intCast(handle) } });
            return .parked();
        }

        const flags: u32 = std.posix.MSG.DONTWAIT | std.posix.MSG.NOSIGNAL;
        const rc = std.c.send(handle, message.ptr, message.len, flags);
        switch (std.posix.errno(rc)) {
            .AGAIN => {
                const token_ptr = try vm.runtime.alloc.create(SendWaitToken);
                token_ptr.* = .{ .message = @intFromEnum(data), .offset = 0 };
                try vm.sched.parkCurrentForIo(
                    @intCast(handle),
                    .write,
                    @intFromPtr(token_ptr),
                    onSendReady,
                    deinitSendToken,
                );
                return .parked();
            },
            .SUCCESS => {},
            else => |err| return HostResult.Err(vm, @tagName(err)),
        }
        const sent: usize = @intCast(rc);
        if (sent >= message.len) return HostResult.Ok(vm, Data.new.num(sent));
        const token_ptr = try vm.runtime.alloc.create(SendWaitToken);
        token_ptr.* = .{ .message = @intFromEnum(data), .offset = sent };
        try vm.sched.parkCurrentForIo(
            @intCast(handle),
            .write,
            @intFromPtr(token_ptr),
            onSendReady,
            deinitSendToken,
        );
        return .parked();
    }

    pub fn recv(vm: *VM, self: Ts.table, opts: Ts.table) !HostResult {
        if (builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) return error.OsNotSupported;
        const socket_data = Data.new.table(@intFromEnum(self));
        const opts_data = Data.new.table(@intFromEnum(opts));

        if (try isServer(socket_data, vm)) return HostResult.Err(vm, "CannotRecvOnServer");

        const entry_ptr = try getEntryPtr(socket_data, vm);
        const stream = switch (entry_ptr.*) {
            .stream => |*s| s,
            .server => return HostResult.Err(vm, "CannotRecvOnServer"),
        };

        var parsed = parseRecvOptions(opts_data, vm) catch return .errType(1, "recv opts table", root.typeof(opts_data, vm));
        parsed.entry_ptr = entry_ptr;

        const handle = stream.socket.socket.handle;
        const flags: u32 = std.posix.MSG.DONTWAIT | std.posix.MSG.NOSIGNAL;

        switch (parsed.mode) {
            .read_some => {
                if (stream.pending.len > 0) {
                    const take = @min(parsed.max_bytes, stream.pending.len);
                    const payload = try vm.ownDataString(stream.pending[0..take]);
                    if (take < stream.pending.len) {
                        const rest = try vm.runtime.alloc.dupe(u8, stream.pending[take..]);
                        if (stream.pending.len > 0) vm.runtime.alloc.free(stream.pending);
                        stream.pending = rest;
                    } else {
                        if (stream.pending.len > 0) vm.runtime.alloc.free(stream.pending);
                        stream.pending = &.{};
                    }
                    return HostResult.Ok(vm, payload);
                }
                const recv_buf = try vm.runtime.alloc.alloc(u8, parsed.max_bytes);
                defer vm.runtime.alloc.free(recv_buf);
                const rc = std.c.recv(handle, recv_buf.ptr, recv_buf.len, flags);
                switch (std.posix.errno(rc)) {
                    .AGAIN => {},
                    .SUCCESS => {
                        const n: usize = @intCast(rc);
                        if (n == 0) return HostResult.Err(vm, "SocketClosed");
                        return HostResult.Ok(vm, try vm.ownDataString(recv_buf[0..n]));
                    },
                    else => |err| return HostResult.Err(vm, @tagName(err)),
                }
            },
            .read_line => {
                if (try tryExtractPendingDelimited(vm, stream, parsed.delimiter)) |line| return HostResult.Ok(vm, line);
                while (true) {
                    const recv_buf = try vm.runtime.alloc.alloc(u8, parsed.max_bytes);
                    defer vm.runtime.alloc.free(recv_buf);
                    const rc = std.c.recv(handle, recv_buf.ptr, recv_buf.len, flags);
                    switch (std.posix.errno(rc)) {
                        .AGAIN => break,
                        .SUCCESS => {},
                        else => |err| return HostResult.Err(vm, @tagName(err)),
                    }
                    const n: usize = @intCast(rc);
                    if (n == 0) {
                        if (stream.pending.len > 0) {
                            const payload = try vm.ownDataString(stream.pending);
                            if (stream.pending.len > 0) vm.runtime.alloc.free(stream.pending);
                            stream.pending = &.{};
                            return HostResult.Ok(vm, payload);
                        }
                        return HostResult.Err(vm, "SocketClosed");
                    }
                    try appendPending(vm.runtime.alloc, stream, recv_buf[0..n]);
                    if (try tryExtractPendingDelimited(vm, stream, parsed.delimiter)) |line| return HostResult.Ok(vm, line);
                }
            },
            .read_all => {
                while (true) {
                    const recv_buf = try vm.runtime.alloc.alloc(u8, parsed.max_bytes);
                    defer vm.runtime.alloc.free(recv_buf);
                    const rc = std.c.recv(handle, recv_buf.ptr, recv_buf.len, flags);
                    switch (std.posix.errno(rc)) {
                        .AGAIN => break,
                        .SUCCESS => {},
                        else => |err| return HostResult.Err(vm, @tagName(err)),
                    }
                    const n: usize = @intCast(rc);
                    if (n == 0) {
                        if (stream.pending.len > 0) {
                            const payload = try vm.ownDataString(stream.pending);
                            if (stream.pending.len > 0) vm.runtime.alloc.free(stream.pending);
                            stream.pending = &.{};
                            return HostResult.Ok(vm, payload);
                        }
                        return HostResult.Err(vm, "SocketClosed");
                    }
                    try appendPending(vm.runtime.alloc, stream, recv_buf[0..n]);
                }
            },
        }

        const token_ptr = try vm.runtime.alloc.create(RecvWaitToken);
        token_ptr.* = parsed;
        try vm.sched.parkCurrentForIo(
            @intCast(handle),
            .read,
            @intFromPtr(token_ptr),
            onRecvReady,
            deinitRecvToken,
        );
        return .parked();
    }

    pub fn close(vm: *VM, self: Ts.table) !HostResult {
        const socket_data = Data.new.table(@intFromEnum(self));
        try closeEntry(socket_data, vm);
        return HostResult.Ok(vm, revo.Data.new.core(.nil));
    }
};

pub const impls: []const api.Impl = if (@import("build_options").is_freestanding)
    &[_]api.Impl{}
else
    root.impls(Impl).val ++ &[_]api.Impl{
        .{ .name = "listen", .f = root.defineVariadic(&.{.number}, listen_fn) },
    };

/// > net:listen(port: num [, backlog: num]) -> socket
fn listen_fn(args: []const Data, vm: *VM) !HostResult {
    const port: u16 = root.numToInt(u16, args[0].asNum().?) orelse
        return .errType(0, "port num 0..65535", root.typeof(args[0], vm));
    const backlog: u31 = if (args.len > 1)
        root.numToInt(u31, args[1].asNum().?) orelse return .errType(1, "backlog num", root.typeof(args[1], vm))
    else
        128;

    const addr = std.Io.net.IpAddress.parseIp4("0.0.0.0", port) catch |err| {
        return HostResult.Err(vm, @errorName(err));
    };

    var server = addr.listen(vm.runtime.io, .{
        .mode = std.Io.net.Socket.Mode.stream,
        .protocol = std.Io.net.Protocol.tcp,
        .kernel_backlog = backlog,
        .reuse_address = true,
    }) catch |err| {
        return HostResult.Err(vm, @errorName(err));
    };

    setSocketNonBlocking(server.socket.handle) catch |err| {
        std.Io.net.Server.deinit(&server, vm.runtime.io);
        return HostResult.Err(vm, @errorName(err));
    };

    const entry_ptr = try vm.runtime.alloc.create(SocketEntry);
    entry_ptr.* = .{ .server = server };

    return HostResult.Ok(vm, try wrapSocket(vm, entry_ptr, true));
}

// -- internal helpers (unchanged) --

pub const SocketEntry = union(enum) {
    stream: StreamEntry,
    server: std.Io.net.Server,
};

pub const StreamEntry = struct {
    socket: std.Io.net.Stream,
    pending: []u8 = &.{},
};

const RecvMode = enum {
    read_some,
    read_all,
    read_line,
};

const SendWaitToken = struct {
    message: VM.memory.StringID,
    offset: usize = 0,
};

const RecvWaitToken = struct {
    entry_ptr: ?*SocketEntry = null,
    mode: RecvMode = .read_some,
    max_bytes: usize = 4096,
    delimiter: u8 = '\n',
};

pub fn setSocketNonBlocking(handle: std.posix.fd_t) !void {
    if (builtin.target.os.tag == .windows) {
        return;
    }
    const flags = std.c.fcntl(handle, std.posix.F.GETFL, @as(c_int, 0));
    if (flags == -1) return error.Unexpected;
    const new_flags: c_int = flags | @as(c_int, @bitCast(std.posix.O{ .NONBLOCK = true }));
    const rc = std.c.fcntl(handle, std.posix.F.SETFL, new_flags);
    if (rc == -1) return error.Unexpected;
}

fn wakeFiber(vm: *VM, fiber_id: VM.FiberID, tag: revo.core_atoms, payload: Data) !void {
    try vm.sched.wakeFiber(
        fiber_id,
        try vm.resultTable(tag, payload),
    );
}

fn appendPending(alloc: std.mem.Allocator, stream: *StreamEntry, chunk: []const u8) !void {
    if (chunk.len == 0) return;
    if (stream.pending.len == 0) {
        stream.pending = try alloc.dupe(u8, chunk);
        return;
    }
    const merged = try std.mem.concat(alloc, u8, &[_][]const u8{ stream.pending, chunk });
    if (stream.pending.len > 0) alloc.free(stream.pending);
    stream.pending = merged;
}

fn tryExtractPendingDelimited(vm: *VM, stream: *StreamEntry, delimiter: u8) !?Data {
    const idx = std.mem.findScalar(u8, stream.pending, delimiter) orelse return null;
    const line = try vm.ownDataString(stream.pending[0..idx]);
    const rest = stream.pending[idx + 1 ..];
    if (rest.len > 0) {
        const new_pending = try vm.runtime.alloc.dupe(u8, rest);
        if (stream.pending.len > 0) vm.runtime.alloc.free(stream.pending);
        stream.pending = new_pending;
    } else {
        if (stream.pending.len > 0) vm.runtime.alloc.free(stream.pending);
        stream.pending = &.{};
    }
    return line;
}

fn deinitToken(comptime T: type, alloc: std.mem.Allocator, token: usize) void {
    if (token == 0) return;
    alloc.destroy(@as(*T, @ptrFromInt(token)));
}

fn completeWaiter(vm: *VM, waiter: *Scheduler.WaitEntry, tag: revo.core_atoms, payload: Data) !Scheduler.IoDispatchResult {
    try wakeFiber(vm, waiter.fiber_id, tag, payload);
    return .{ .completed = true, .woke = true };
}

fn deinitSendToken(alloc: std.mem.Allocator, token: usize) void {
    deinitToken(SendWaitToken, alloc, token);
}

fn deinitRecvToken(alloc: std.mem.Allocator, token: usize) void {
    deinitToken(RecvWaitToken, alloc, token);
}

fn onSendReady(vm: *VM, waiter: *Scheduler.WaitEntry, _: i16) !Scheduler.IoDispatchResult {
    const t: *SendWaitToken = @ptrFromInt(waiter.token);
    const msg = vm.stringValue(t.message);
    const remaining = msg[t.offset..];
    const flags: u32 = std.posix.MSG.DONTWAIT | std.posix.MSG.NOSIGNAL;
    const rc = std.c.send(@as(std.posix.fd_t, @intCast(waiter.wait_id)), remaining.ptr, remaining.len, flags);
    switch (std.posix.errno(rc)) {
        .AGAIN => return .{},
        .SUCCESS => {},
        else => |err| {
            deinitToken(SendWaitToken, vm.runtime.alloc, waiter.token);
            waiter.token = 0;
            return try completeWaiter(vm, waiter, .err, try vm.dataAtom(@tagName(err)));
        },
    }
    const sent: usize = @intCast(rc);
    const next_offset = t.offset + sent;
    if (next_offset >= msg.len) {
        deinitToken(SendWaitToken, vm.runtime.alloc, waiter.token);
        waiter.token = 0;
        return try completeWaiter(vm, waiter, .ok, Data.new.num(msg.len));
    }
    t.offset = next_offset;
    return .{};
}

fn freePending(alloc: std.mem.Allocator, pending: *[]u8) void {
    if (pending.len > 0) alloc.free(pending.*);
    pending.* = &.{};
}

fn onRecvReady(vm: *VM, waiter: *Scheduler.WaitEntry, _: i16) !Scheduler.IoDispatchResult {
    const t: *RecvWaitToken = @ptrFromInt(waiter.token);
    const entry_ptr = t.entry_ptr orelse return .{ .completed = true, .woke = false };
    const stream = switch (entry_ptr.*) {
        .stream => |*s| s,
        .server => {
            deinitToken(RecvWaitToken, vm.runtime.alloc, waiter.token);
            waiter.token = 0;
            return try completeWaiter(vm, waiter, .err, revo.Data.new.core(.CannotRecvOnServer));
        },
    };

    switch (t.mode) {
        .read_some => {
            if (stream.pending.len > 0) {
                const take = @min(t.max_bytes, stream.pending.len);
                const payload = try vm.ownDataString(stream.pending[0..take]);
                if (take < stream.pending.len) {
                    const rest = try vm.runtime.alloc.dupe(u8, stream.pending[take..]);
                    freePending(vm.runtime.alloc, &stream.pending);
                    stream.pending = rest;
                } else {
                    freePending(vm.runtime.alloc, &stream.pending);
                }
                deinitToken(RecvWaitToken, vm.runtime.alloc, waiter.token);
                waiter.token = 0;
                return try completeWaiter(vm, waiter, .ok, payload);
            }
        },
        .read_line => {
            if (try tryExtractPendingDelimited(vm, stream, t.delimiter)) |line| {
                deinitToken(RecvWaitToken, vm.runtime.alloc, waiter.token);
                waiter.token = 0;
                return try completeWaiter(vm, waiter, .ok, line);
            }
        },
        .read_all => {},
    }

    const temp_buf = try vm.runtime.alloc.alloc(u8, t.max_bytes);
    defer vm.runtime.alloc.free(temp_buf);
    const flags: u32 = std.posix.MSG.DONTWAIT | std.posix.MSG.NOSIGNAL;
    const rc = std.c.recv(@as(std.posix.fd_t, @intCast(waiter.wait_id)), temp_buf.ptr, temp_buf.len, flags);
    switch (std.posix.errno(rc)) {
        .AGAIN => return .{},
        .SUCCESS => {},
        else => |err| {
            deinitToken(RecvWaitToken, vm.runtime.alloc, waiter.token);
            waiter.token = 0;
            return try completeWaiter(vm, waiter, .err, try vm.dataAtom(@tagName(err)));
        },
    }
    const n: usize = @intCast(rc);
    if (n == 0) {
        deinitToken(RecvWaitToken, vm.runtime.alloc, waiter.token);
        waiter.token = 0;
        if (stream.pending.len > 0) {
            const payload = try vm.ownDataString(stream.pending);
            freePending(vm.runtime.alloc, &stream.pending);
            return try completeWaiter(vm, waiter, .ok, payload);
        } else {
            return try completeWaiter(vm, waiter, .err, revo.Data.new.core(.SocketClosed));
        }
    }

    switch (t.mode) {
        .read_some => {
            deinitToken(RecvWaitToken, vm.runtime.alloc, waiter.token);
            waiter.token = 0;
            return try completeWaiter(vm, waiter, .ok, try vm.ownDataString(temp_buf[0..n]));
        },
        .read_line => {
            try appendPending(vm.runtime.alloc, stream, temp_buf[0..n]);
            if (try tryExtractPendingDelimited(vm, stream, t.delimiter)) |line| {
                deinitToken(RecvWaitToken, vm.runtime.alloc, waiter.token);
                waiter.token = 0;
                return try completeWaiter(vm, waiter, .ok, line);
            }
            return .{};
        },
        .read_all => {
            try appendPending(vm.runtime.alloc, stream, temp_buf[0..n]);
            return .{};
        },
    }
}

fn onAcceptReady(vm: *VM, waiter: *Scheduler.WaitEntry, _: i16) !Scheduler.IoDispatchResult {
    const rc = std.c.accept(@as(std.posix.fd_t, @intCast(waiter.wait_id)), null, null);
    switch (std.posix.errno(rc)) {
        .AGAIN => return .{},
        .SUCCESS => {},
        else => |err| return try completeWaiter(vm, waiter, .err, try vm.dataAtom(@tagName(err))),
    }
    const handle: std.posix.fd_t = @intCast(rc);
    setSocketNonBlocking(handle) catch |err| {
        _ = std.c.close(handle);
        return try completeWaiter(vm, waiter, .err, try vm.dataAtom(@errorName(err)));
    };
    const new_entry_ptr = try vm.runtime.alloc.create(SocketEntry);
    new_entry_ptr.* = .{
        .stream = .{
            .socket = .{
                .socket = .{
                    .handle = handle,
                    .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } },
                },
            },
            .pending = &.{},
        },
    };
    return try completeWaiter(vm, waiter, .ok, try wrapSocket(vm, new_entry_ptr, false));
}

pub fn pollIoWaiters(vm: *VM, timeout_ms: i32) !bool {
    if (builtin.target.os.tag == .windows) {
        return false;
    }
    var poll_fds = try std.ArrayList(std.posix.pollfd).initCapacity(vm.runtime.alloc, 4);
    defer poll_fds.deinit(vm.runtime.alloc);

    var poll_to_waiter = try std.ArrayList(usize).initCapacity(vm.runtime.alloc, 4);
    defer poll_to_waiter.deinit(vm.runtime.alloc);

    var completed_waiters = try std.ArrayList(usize).initCapacity(vm.runtime.alloc, 4);
    defer completed_waiters.deinit(vm.runtime.alloc);

    for (vm.sched.io_waiters.items, 0..) |waiter, idx| {
        const events: i16 = switch (waiter.intent) {
            .read => std.posix.POLL.IN,
            .write => std.posix.POLL.OUT,
            .read_write => std.posix.POLL.IN | std.posix.POLL.OUT,
        };
        try poll_fds.append(vm.runtime.alloc, .{
            .fd = @as(std.posix.fd_t, @intCast(waiter.wait_id)),
            .events = events,
            .revents = 0,
        });
        try poll_to_waiter.append(vm.runtime.alloc, idx);
    }

    if (poll_fds.items.len == 0) return false;

    _ = try std.posix.poll(poll_fds.items, timeout_ms);

    var woke_any = false;
    var poll_idx = poll_fds.items.len;
    while (poll_idx > 0) {
        poll_idx -= 1;
        const pfd = poll_fds.items[poll_idx];
        if (pfd.revents == 0) continue;

        const waiter_idx = poll_to_waiter.items[poll_idx];
        if (waiter_idx >= vm.sched.io_waiters.items.len) continue;

        const waiter = &vm.sched.io_waiters.items[waiter_idx];
        if (waiter.fiber_id >= vm.sched.fibers.items.len) {
            try completed_waiters.append(vm.runtime.alloc, waiter_idx);
            continue;
        }

        const dispatch = try waiter.on_ready(vm, waiter, pfd.revents);
        if (dispatch.completed) try completed_waiters.append(vm.runtime.alloc, waiter_idx);
        woke_any = woke_any or dispatch.woke;
    }

    while (completed_waiters.items.len > 0) {
        var best_pos: usize = 0;
        var best_waiter: usize = completed_waiters.items[0];
        for (completed_waiters.items[1..], 1..) |waiter_idx, pos| {
            if (waiter_idx > best_waiter) {
                best_waiter = waiter_idx;
                best_pos = pos;
            }
        }
        const removed = vm.sched.io_waiters.swapRemove(best_waiter);
        if (removed.on_deinit) |deinit_fn| deinit_fn(vm.runtime.alloc, removed.token);
        _ = completed_waiters.swapRemove(best_pos);
    }

    return woke_any;
}

pub fn wrapSocket(vm: *VM, entry_ptr: *SocketEntry, is_server: bool) !Data {
    const sock_table = try vm.tables.create();
    var table = try vm.tables.get(sock_table);

    try table.putRawAtom(revo.core_atoms.__is_server.atomId(), Data.new.boolean(is_server), vm);

    try table.putRawAtom(revo.core_atoms.__entry_ptr.atomId(), Data.new.num(@intFromPtr(entry_ptr)), vm);

    if (is_server) {
        const port = switch (entry_ptr.*) {
            .server => |s| s.socket.address.getPort(),
            .stream => 0,
        };
        try table.putRawAtom(revo.core_atoms.port.atomId(), Data.new.num(port), vm);
    }

    const metatable = try vm.tables.create();
    var mt = try vm.tables.get(metatable);
    const socket_module_data = vm.globals.get(revo.core_atoms.socket.atomId()) orelse
        return error.SocketModuleNotFound;

    const socket_module = try vm.tables.get(socket_module_data.asTable().?);
    const close_fn_data = socket_module.getRaw(try vm.dataAtom("close"), vm) orelse
        return error.SocketModuleNotFound;

    try mt.putRawAtom(revo.core_atoms.__index.atomId(), socket_module_data, vm);

    const mt_array = [_]Data{ Data.new.table(sock_table), Data.new.table(metatable) };
    const set_result = try meta.set_meta(&mt_array, vm);
    if (set_result != .ok) return error.SetMetatableFailed;

    try vm.registerFinalizer(sock_table, close_fn_data);

    return Data.new.table(sock_table);
}

fn isServer(socket_data: Data, vm: *VM) !bool {
    const table = try vm.tables.get(socket_data.asTable().?);
    const d = table.getRawAtom(revo.core_atoms.__is_server.atomId(), vm) orelse
        return error.InvalidSocket;
    return !revo.isFalse(d);
}

fn getEntryPtr(socket_data: Data, vm: *VM) !*SocketEntry {
    const table = try vm.tables.get(socket_data.asTable().?);
    const d = table.getRawAtom(revo.core_atoms.__entry_ptr.atomId(), vm) orelse
        return error.InvalidSocket;
    const addr: usize = root.numToInt(usize, d.asNum().?) orelse return error.InvalidSocket;
    if (addr == 0) return error.SocketClosed;
    return @as(*SocketEntry, @ptrFromInt(addr));
}

fn fdId(fd: std.posix.fd_t) u64 {
    return switch (@typeInfo(std.posix.fd_t)) {
        .pointer => @intFromPtr(fd),
        else => @intCast(fd),
    };
}

fn cancelWaitersFor(vm: *VM, fd: std.posix.fd_t) !void {
    var idx = vm.sched.io_waiters.items.len;
    while (idx > 0) {
        idx -= 1;
        const waiter = &vm.sched.io_waiters.items[idx];
        if (waiter.wait_id != fdId(fd)) continue;
        _ = try completeWaiter(vm, waiter, .err, revo.Data.new.core(.SocketClosed));
        const removed = vm.sched.io_waiters.swapRemove(idx);
        if (removed.on_deinit) |deinit_fn| deinit_fn(vm.runtime.alloc, removed.token);
    }
}

fn closeEntry(socket_data: Data, vm: *VM) !void {
    const entry_ptr = getEntryPtr(socket_data, vm) catch |e| switch (e) {
        error.SocketClosed => return,
        else => return e,
    };

    const fd: std.posix.fd_t = switch (entry_ptr.*) {
        .stream => |*s| s.socket.socket.handle,
        .server => |s| s.socket.handle,
    };
    try cancelWaitersFor(vm, fd);

    const io = vm.runtime.io;
    switch (entry_ptr.*) {
        .stream => |*s| {
            if (s.pending.len > 0) vm.runtime.alloc.free(s.pending);
            s.socket.close(io);
        },
        .server => |s| std.Io.net.Server.deinit(@constCast(&s), io),
    }
    vm.runtime.alloc.destroy(entry_ptr);

    var tbl = try vm.tables.get(socket_data.asTable().?);
    try tbl.putRawAtom(revo.core_atoms.__entry_ptr.atomId(), Data.new.num(0), vm);
    vm.unregisterFinalizer(socket_data.asTable().?);
}

fn parseRecvOptions(opts_data: Data, vm: *VM) !RecvWaitToken {
    var token: RecvWaitToken = .{};
    const opts = try vm.tables.get(opts_data.asTable().?);

    if (opts.getRawAtom(revo.core_atoms.max_bytes.atomId(), vm)) |max_d| {
        if (!max_d.isNumber()) return error.TypeError;
        token.max_bytes = root.numToInt(usize, max_d.asNum().?) orelse return error.TypeError;
    }
    if (token.max_bytes == 0) token.max_bytes = 1;

    if (opts.getRawAtom(revo.core_atoms.delimiter.atomId(), vm)) |delim_d| {
        if (!delim_d.isString()) return error.TypeError;
        const s = vm.stringValue(delim_d.asString().?);
        if (s.len == 0) return error.TypeError;
        token.delimiter = s[0];
    }

    if (opts.getRawAtom(revo.core_atoms.mode.atomId(), vm)) |mode_d| {
        if (!mode_d.isAtom()) return error.TypeError;
        const a = mode_d.asAtom().?;
        if (a == revo.core_atoms.read_some.atomId()) {
            token.mode = .read_some;
        } else if (a == revo.core_atoms.read_all.atomId()) {
            token.mode = .read_all;
        } else if (a == revo.core_atoms.read_line.atomId()) {
            token.mode = .read_line;
        } else {
            return error.TypeError;
        }
    }

    return token;
}

const std = @import("std");
const builtin = @import("builtin");

const revo = @import("../root.zig");
const Scheduler = revo.vm.Scheduler;
const Data = revo.Data;
const VM = revo.VM;
const api = @import("api.zig");
const meta = @import("meta.zig");
const root = @import("root.zig");
const HostResult = root.HostResult;
