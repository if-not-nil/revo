//!
//! nonblocking tcp sockets parked on the schedulers io poll
//!
//! ~ every socket is nonblocking and close-on-exec
//! ~ calls that would block instead park the current fiber with `parkCurrentForIo`
//!   and return `.parked()`:
//!   ~ `connect` waits for writability
//!   ~ `accept` and `recv` for readability
//!   ~ `send` for writability
//! ~ the scheduler's `pollIoWaiters` runs the blocking `poll` without the gil
//!   , then replays each ready fd through its `on[Something]Ready` callback
//!

const builtin = @import("builtin");
const std = @import("std");

const revo = @import("../root.zig");
const Scheduler = revo.vm.Scheduler;
const Value = revo.Value;
const VM = revo.VM;
const metatable_mod = @import("metatable.zig");
const root = @import("root.zig");
const specs = @import("specs.zig");
const HostResult = root.host.HostResult;
const Args = root.host.ArgTypes;

pub const Impl = struct {
    pub fn connect(vm: *VM, host: Args.string, port: Args.number) !HostResult {
        const host_str = vm.stringValue(@backingInt(host));
        const port_int: u16 = root.host.numToInt(u16, port) orelse
            return .errType(1, "port number 0..65535", root.typeof(Value.new.num(port), vm));

        const host_to_use = if (std.mem.eql(u8, host_str, "localhost")) "127.0.0.1" else host_str;
        const addr = std.Io.net.IpAddress.parseIp4(host_to_use, port_int) catch |err| {
            return HostResult.Err(vm, @errorName(err));
        };

        if (revo.can_async) {
            const ip4 = switch (addr) {
                .ip4 => |a| a,
                .ip6 => return HostResult.Err(vm, "AddressFamilyUnsupported"),
            };

            const sock_fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
            if (sock_fd < 0) return HostResult.Err(vm, "SocketSetupFailed");
            setSocketFlags(sock_fd) catch {
                _ = std.c.close(sock_fd);
                return HostResult.Err(vm, "SocketSetupFailed");
            };

            var sock_addr: std.posix.sockaddr.in = .{
                .port = std.mem.nativeToBig(u16, ip4.port),
                .addr = std.mem.bigToNative(u32, //
                    @as(u32, ip4.bytes[0]) << 24 |
                        @as(u32, ip4.bytes[1]) << 16 |
                        @as(u32, ip4.bytes[2]) << 8 |
                        ip4.bytes[3]),
            };

            const status = std.c.connect(sock_fd, @ptrCast(&sock_addr), @sizeOf(std.posix.sockaddr.in));
            switch (std.posix.errno(status)) {
                .SUCCESS => return HostResult.Ok(vm, try wrapConnectedSocket(vm, sock_fd)),
                .INPROGRESS, .AGAIN => {
                    try vm.sched.parkCurrentForIo(
                        @intCast(sock_fd),
                        .write,
                        0,
                        onConnectReady,
                        null,
                    );
                    return .parked();
                },
                else => |err| {
                    _ = std.c.close(sock_fd);
                    return HostResult.Err(vm, @tagName(err));
                },
            }
        }

        const stream = addr.connect(vm.runtime.io, .{
            .mode = std.Io.net.Socket.Mode.stream,
            .protocol = std.Io.net.Protocol.tcp,
        }) catch |err| {
            return HostResult.Err(vm, @errorName(err));
        };

        setSocketFlags(stream.socket.handle) catch |err| {
            stream.close(vm.runtime.io);
            return HostResult.Err(vm, @errorName(err));
        };

        const entry_ptr = try vm.runtime.alloc.create(SocketEntry);
        entry_ptr.* = .{ .stream = .{ .socket = stream } };

        return HostResult.Ok(vm, try wrapSocket(vm, entry_ptr, false));
    }

    pub fn accept(vm: *VM, self: Args.table) !HostResult {
        if (builtin.target.os.tag == .windows) return error.OsNotSupported;
        const socket_data = Value.new.table(@backingInt(self));

        if (!try isServer(socket_data, vm)) return HostResult.Err(vm, "NotServerSocket");

        const entry_ptr = try getEntryPtr(socket_data, vm);
        const server = switch (entry_ptr.*) {
            .server => |*s| s,
            .stream => return HostResult.Err(vm, "NotServerSocket"),
        };

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

        setSocketFlags(handle) catch |err| {
            _ = std.c.close(handle);
            return HostResult.Err(vm, @errorName(err));
        };
        return HostResult.Ok(vm, try wrapConnectedSocket(vm, handle));
    }

    pub fn send(vm: *VM, self: Args.table, data: Args.string) !HostResult {
        if (builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) return error.OsNotSupported;
        const socket_data = Value.new.table(@backingInt(self));
        const message = vm.stringValue(@backingInt(data));

        if (try isServer(socket_data, vm)) return HostResult.Err(vm, "CannotSendOnServer");

        const entry_ptr = try getEntryPtr(socket_data, vm);
        const stream = switch (entry_ptr.*) {
            .stream => |*s| s,
            .server => return HostResult.Err(vm, "CannotSendOnServer"),
        };

        const handle = stream.socket.socket.handle;

        const flags: u32 = std.posix.MSG.DONTWAIT | std.posix.MSG.NOSIGNAL;
        const rc = std.c.send(handle, message.ptr, message.len, flags);
        // bytes already accepted; waiter resumes at this offset
        const offset: usize = switch (std.posix.errno(rc)) {
            .AGAIN => 0,
            .SUCCESS => blk: {
                const sent: usize = @intCast(rc);
                if (sent >= message.len) return HostResult.Ok(vm, Value.new.num(sent));
                break :blk sent;
            },
            else => |err| return HostResult.Err(vm, @tagName(err)),
        };

        const token_ptr = try vm.runtime.alloc.create(SendWaitToken);
        token_ptr.* = .{ .message = @backingInt(data), .offset = offset };
        try vm.sched.parkCurrentForIo(
            @intCast(handle),
            .write,
            @intFromPtr(token_ptr),
            onSendReady,
            deinitSendToken,
        );
        return .parked();
    }

    pub fn recv(vm: *VM, self: Args.table, opts: Args.table) !HostResult {
        if (builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) return error.OsNotSupported;
        const socket_data = Value.new.table(@backingInt(self));
        const opts_data = Value.new.table(@backingInt(opts));

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
                if (stream.pending.len > 0)
                    return HostResult.Ok(vm, try takePending(vm, stream, parsed.max_bytes));
                const recv_buf = try vm.runtime.alloc.alloc(u8, parsed.max_bytes);
                defer vm.runtime.alloc.free(recv_buf);
                const rc = std.c.recv(handle, recv_buf.ptr, recv_buf.len, flags);
                switch (std.posix.errno(rc)) {
                    .AGAIN => {},
                    .SUCCESS => {
                        const n: usize = @intCast(rc);
                        if (n == 0) return HostResult.Err(vm, "SocketClosed");
                        return HostResult.Ok(vm, try vm.ownValueString(recv_buf[0..n]));
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
                        if (try drainPendingEof(vm, stream)) |payload|
                            return HostResult.Ok(vm, payload);
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
                        if (try drainPendingEof(vm, stream)) |payload|
                            return HostResult.Ok(vm, payload);
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

    pub fn close(vm: *VM, self: Args.table) !HostResult {
        const socket_data = Value.new.table(@backingInt(self));
        try closeEntry(socket_data, vm);
        return HostResult.Ok(vm, revo.Value.new.core(.nil));
    }
};

pub const impls: []const specs.Impl = if (@import("build_options").is_freestanding)
    &[_]specs.Impl{}
else
    root.host.impls(Impl).val ++ &[_]specs.Impl{
        .{ .name = "listen", .f = root.host.defineVariadic(&.{.number}, listen_fn) },
    };

/// > net:listen(port: number [, backlog: number]) -> socket
fn listen_fn(args: []const Value, vm: *VM) !HostResult {
    const port: u16 = root.host.numToInt(u16, args[0].asNumOpt().?) orelse
        return .errType(0, "port number 0..65535", root.typeof(args[0], vm));
    const backlog: u31 = if (args.len > 1)
        root.host.numToInt(u31, args[1].asNumOpt().?) orelse return .errType(1, "backlog number", root.typeof(args[1], vm))
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

    setSocketFlags(server.socket.handle) catch |err| {
        std.Io.net.Server.deinit(&server, vm.runtime.io);
        return HostResult.Err(vm, @errorName(err));
    };

    const entry_ptr = try vm.runtime.alloc.create(SocketEntry);
    entry_ptr.* = .{ .server = server };

    return HostResult.Ok(vm, try wrapSocket(vm, entry_ptr, true));
}

/// server or stream with a pending buf
/// `recv` serves `read_some` / `read_line` / `read_all` from it first,
/// so a parked waiter isnt gonna loses bytes read early
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

/// where a partial send resumes; onSendReady picks up at offset
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

/// nonblocking + close-on-exec for socket fds
/// , raw std.c.socket/accept set neither, so system children
/// , would inherit them without this
pub fn setSocketFlags(handle: std.posix.fd_t) !void {
    if (builtin.target.os.tag == .windows) {
        return;
    }
    const flags = std.c.fcntl(handle, std.posix.F.GETFL, @as(c_int, 0));
    if (flags == -1) return error.Unexpected;
    const new_flags: c_int = flags | @as(c_int, @bitCast(std.posix.O{ .NONBLOCK = true }));
    const rc = std.c.fcntl(handle, std.posix.F.SETFL, new_flags);
    if (rc == -1) return error.Unexpected;
    const clo = std.c.fcntl(handle, std.posix.F.SETFD, @as(c_int, std.posix.FD_CLOEXEC));
    if (clo == -1) return error.Unexpected;
}

fn wakeFiber(vm: *VM, fiber_id: VM.FiberID, tag: revo.CoreAtoms, payload: Value) !void {
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
    freePending(alloc, &stream.pending);
    stream.pending = merged;
}

fn tryExtractPendingDelimited(vm: *VM, stream: *StreamEntry, delimiter: u8) !?Value {
    const idx = std.mem.findScalar(u8, stream.pending, delimiter) orelse return null;
    const line = try vm.ownValueString(stream.pending[0..idx]);
    const rest = stream.pending[idx + 1 ..];
    if (rest.len > 0) {
        const new_pending = try vm.runtime.alloc.dupe(u8, rest);
        freePending(vm.runtime.alloc, &stream.pending);
        stream.pending = new_pending;
    } else {
        freePending(vm.runtime.alloc, &stream.pending);
    }
    return line;
}

fn deinitToken(comptime T: type, alloc: std.mem.Allocator, token: usize) void {
    if (token == 0) return;
    alloc.destroy(@as(*T, @ptrFromInt(token)));
}

fn completeWaiter(vm: *VM, waiter: *Scheduler.WaitEntry, tag: revo.CoreAtoms, payload: Value) !Scheduler.IoDispatchResult {
    try wakeFiber(vm, waiter.fiber_id, tag, payload);
    return .{ .completed = true, .woke = true };
}

/// complete a waiter and free its heap token, exactly once
/// , callbacks free the token themselves and zero it
/// , pollIoWaiters only frees leftovers when one completes without doing so
fn completeAndFree(
    comptime T: type,
    vm: *VM,
    waiter: *Scheduler.WaitEntry,
    tag: revo.CoreAtoms,
    payload: Value,
) !Scheduler.IoDispatchResult {
    deinitToken(T, vm.runtime.alloc, waiter.token);
    waiter.token = 0;
    return try completeWaiter(vm, waiter, tag, payload);
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
        else => |err| return try completeAndFree(SendWaitToken, vm, waiter, .err, try vm.atomValue(@tagName(err))),
    }
    const sent: usize = @intCast(rc);
    const next_offset = t.offset + sent;
    if (next_offset >= msg.len) {
        return try completeAndFree(SendWaitToken, vm, waiter, .ok, Value.new.num(msg.len));
    }
    t.offset = next_offset;
    return .{};
}

fn freePending(alloc: std.mem.Allocator, pending: *[]u8) void {
    if (pending.len > 0) alloc.free(pending.*);
    pending.* = &.{};
}

/// take up to max_bytes from the pending buf, updating it
fn takePending(vm: *VM, stream: *StreamEntry, max_bytes: usize) !Value {
    const take = @min(max_bytes, stream.pending.len);
    const payload = try vm.ownValueString(stream.pending[0..take]);
    if (take < stream.pending.len) {
        const rest = try vm.runtime.alloc.dupe(u8, stream.pending[take..]);
        freePending(vm.runtime.alloc, &stream.pending);
        stream.pending = rest;
    } else {
        freePending(vm.runtime.alloc, &stream.pending);
    }
    return payload;
}

/// drain the whole pending buf on eof, null when empty
fn drainPendingEof(vm: *VM, stream: *StreamEntry) !?Value {
    if (stream.pending.len == 0) return null;
    const payload = try vm.ownValueString(stream.pending);
    freePending(vm.runtime.alloc, &stream.pending);
    return payload;
}

fn onRecvReady(vm: *VM, waiter: *Scheduler.WaitEntry, _: i16) !Scheduler.IoDispatchResult {
    const t: *RecvWaitToken = @ptrFromInt(waiter.token);
    const entry_ptr = t.entry_ptr orelse return .{ .completed = true, .woke = false };
    const stream = switch (entry_ptr.*) {
        .stream => |*s| s,
        .server => return try completeAndFree(RecvWaitToken, vm, waiter, .err, revo.Value.new.core(.CannotRecvOnServer)),
    };

    switch (t.mode) {
        .read_some => {
            if (stream.pending.len > 0) {
                const payload = try takePending(vm, stream, t.max_bytes);
                return try completeAndFree(RecvWaitToken, vm, waiter, .ok, payload);
            }
        },
        .read_line => {
            if (try tryExtractPendingDelimited(vm, stream, t.delimiter)) |line| {
                return try completeAndFree(RecvWaitToken, vm, waiter, .ok, line);
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
        else => |err| return try completeAndFree(RecvWaitToken, vm, waiter, .err, try vm.atomValue(@tagName(err))),
    }
    const n: usize = @intCast(rc);
    if (n == 0) {
        if (try drainPendingEof(vm, stream)) |payload| {
            return try completeAndFree(RecvWaitToken, vm, waiter, .ok, payload);
        }
        return try completeAndFree(RecvWaitToken, vm, waiter, .err, revo.Value.new.core(.SocketClosed));
    }

    switch (t.mode) {
        .read_some => {
            return try completeAndFree(RecvWaitToken, vm, waiter, .ok, try vm.ownValueString(temp_buf[0..n]));
        },
        .read_line => {
            try appendPending(vm.runtime.alloc, stream, temp_buf[0..n]);
            if (try tryExtractPendingDelimited(vm, stream, t.delimiter)) |line| {
                return try completeAndFree(RecvWaitToken, vm, waiter, .ok, line);
            }
            return .{};
        },
        .read_all => {
            try appendPending(vm.runtime.alloc, stream, temp_buf[0..n]);
            return .{};
        },
    }
}

fn wrapConnectedSocket(vm: *VM, handle: std.posix.fd_t) !Value {
    const new_entry_ptr = try vm.runtime.alloc.create(SocketEntry);
    errdefer vm.runtime.alloc.destroy(new_entry_ptr);
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
    return try wrapSocket(vm, new_entry_ptr, false);
}

fn onConnectReady(vm: *VM, waiter: *Scheduler.WaitEntry, _: i16) !Scheduler.IoDispatchResult {
    const handle: std.posix.fd_t = @intCast(waiter.wait_id);
    var err_code: c_int = 0;
    var err_len: std.posix.socklen_t = @sizeOf(c_int);

    const status = std.c.getsockopt(
        handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.ERROR,
        @ptrCast(&err_code),
        &err_len,
    );

    if (status != 0 or err_code != 0) {
        _ = std.c.close(handle);
        return try completeWaiter(vm, waiter, .err, revo.Value.new.core(.ConnectionFailed));
    }
    return try completeWaiter(vm, waiter, .ok, try wrapConnectedSocket(vm, handle));
}

fn onAcceptReady(vm: *VM, waiter: *Scheduler.WaitEntry, _: i16) !Scheduler.IoDispatchResult {
    const rc = std.c.accept(@as(std.posix.fd_t, @intCast(waiter.wait_id)), null, null);
    switch (std.posix.errno(rc)) {
        .AGAIN => return .{},
        .SUCCESS => {},
        else => |err| return try completeWaiter(vm, waiter, .err, try vm.atomValue(@tagName(err))),
    }

    const handle: std.posix.fd_t = @intCast(rc);
    setSocketFlags(handle) catch |err| {
        _ = std.c.close(handle);
        return try completeWaiter(vm, waiter, .err, try vm.atomValue(@errorName(err)));
    };
    return try completeWaiter(vm, waiter, .ok, try wrapConnectedSocket(vm, handle));
}

/// snapshot under lock, poll without the gil, claim each hit before running it
/// , true when anything got woken
pub fn pollIoWaiters(vm: *VM, timeout_ms: i32) !bool {
    if (builtin.target.os.tag == .windows) {
        return false;
    }

    // snapshot under lock
    //
    // the list can grow while we poll, and fds can recycle on close/reopen (generation disambiguates on revalidate)
    // callbacks run GIL-held (all callers), so the heap is safe
    vm.sched.lock();
    var snap_buf = std.ArrayList(Scheduler.WaitEntry).initCapacity(
        vm.runtime.alloc,
        vm.sched.io_waiters.items.len,
    ) catch {
        vm.sched.unlock();
        return error.OutOfMemory;
    };

    snap_buf.appendSliceAssumeCapacity(vm.sched.io_waiters.items);
    vm.sched.unlock();
    defer snap_buf.deinit(vm.runtime.alloc);

    var poll_fds = try std.ArrayList(std.posix.pollfd).initCapacity(vm.runtime.alloc, snap_buf.items.len + 1);
    defer poll_fds.deinit(vm.runtime.alloc);

    // scheduler wakeup pipe first when present
    //
    // runq work landing while we block; level-triggered, drained below
    const use_wakeup = vm.sched.wakeup_r >= 0;
    const off: usize = @intFromBool(use_wakeup);
    if (use_wakeup) {
        poll_fds.appendAssumeCapacity(.{
            .fd = vm.sched.wakeup_r,
            .events = std.posix.POLL.IN,
            .revents = 0,
        });
    }

    for (snap_buf.items) |waiter| {
        const events: i16 = switch (waiter.intent) {
            .read => std.posix.POLL.IN,
            .write => std.posix.POLL.OUT,
            .read_write => std.posix.POLL.IN | std.posix.POLL.OUT,
        };
        poll_fds.appendAssumeCapacity(.{
            .fd = @as(std.posix.fd_t, @intCast(waiter.wait_id)),
            .events = events,
            .revents = 0,
        });
    }

    if (poll_fds.items.len == 0) return false;

    // drop the GIL around the blocking poll only
    // ; claim loop and callbacks below touch the heap, caller holds it on entry
    const depth = revo.vm.dispatch.gilDropForBlocking(vm);
    const poll_result = std.posix.poll(poll_fds.items, timeout_ms);
    revo.vm.dispatch.gilTakeAfterBlocking(vm, depth);
    _ = try poll_result;

    if (use_wakeup and poll_fds.items[0].revents != 0) drainWakeup(vm);

    var woke_any = false;

    for (0..snap_buf.items.len) |rev| {
        const snap_idx = snap_buf.items.len - 1 - rev;
        const poll_idx = snap_idx + off;
        const snap = snap_buf.items[snap_idx];
        if (poll_fds.items[poll_idx].revents == 0) continue;
        const pfd = poll_fds.items[poll_idx];

        // claim under lock
        // ; the entry is ours alone from here
        //   , so later appends, removals, or array growth can't invalidate the callback
        vm.sched.lock();
        const live_idx = findWaiter(vm, &snap);
        if (live_idx == null) {
            vm.sched.unlock();
            continue;
        }
        var owned = vm.sched.io_waiters.swapRemove(live_idx.?);
        vm.sched.unlock();

        if (owned.fiber_id >= vm.sched.fibers.items.len) {
            if (owned.on_deinit) |deinit_fn| deinit_fn(vm.runtime.alloc, owned.token);
            continue;
        }

        const dispatch = try owned.on_ready(vm, &owned, pfd.revents);
        if (dispatch.completed) {
            // callbacks deinit the token themselves and zero it
            //   , so this only fires when a path completed without doing so
            if (owned.on_deinit) |deinit_fn|
                deinit_fn(vm.runtime.alloc, owned.token);
        } else {
            vm.sched.lock();
            vm.sched.io_generation += 1;
            owned.generation = vm.sched.io_generation;

            vm.sched.io_waiters.append(vm.runtime.alloc, owned) catch {
                vm.sched.unlock();
                if (owned.on_deinit) |deinit_fn| deinit_fn(vm.runtime.alloc, owned.token);
                return error.OutOfMemory;
            };
            vm.sched.unlock();
        }
        woke_any = woke_any or dispatch.woke;
    }

    return woke_any;
}

pub fn drainWakeup(vm: *VM) void {
    var buf: [64]u8 = undefined;
    while (true) {
        const n = std.c.read(vm.sched.wakeup_r, &buf, buf.len);
        if (n <= 0) break;
    }
}

/// live index of a snapshotted waiter; call with sched mutex held.
/// null when removed or replaced (fd recycled with a new generation).
fn findWaiter(vm: *VM, snap: *const Scheduler.WaitEntry) ?usize {
    for (vm.sched.io_waiters.items, 0..) |*w, i| {
        if (w.wait_id == snap.wait_id and w.fiber_id == snap.fiber_id and
            w.intent == snap.intent and w.generation == snap.generation)
            return i;
    }
    return null;
}

/// tags the table (__is_server, __entry_ptr, socket __index) and closes it
/// , through a finalizer when swept
pub fn wrapSocket(vm: *VM, entry_ptr: *SocketEntry, is_server: bool) !Value {
    const sock_table = try vm.tables.create();
    var table = try vm.tables.get(sock_table);

    try table.putRawAtom(revo.CoreAtoms.__is_server.atomId(), Value.new.boolean(is_server), vm);

    try table.putRawAtom(revo.CoreAtoms.__entry_ptr.atomId(), Value.new.num(@intFromPtr(entry_ptr)), vm);

    if (is_server) {
        const port = switch (entry_ptr.*) {
            .server => |s| s.socket.address.getPort(),
            .stream => 0,
        };
        try table.putRawAtom(revo.CoreAtoms.port.atomId(), Value.new.num(port), vm);
    }

    const metatable = try vm.tables.create();
    var mt = try vm.tables.get(metatable);
    const socket_module_data = vm.user_globals.get(revo.CoreAtoms.socket.atomId()) orelse
        return error.SocketModuleNotFound;

    const socket_module = try vm.tables.get(socket_module_data.asTable().?);
    const close_fn_data = socket_module.getRaw(try vm.atomValue("close"), vm) orelse
        return error.SocketModuleNotFound;

    try mt.putRawAtom(revo.CoreAtoms.__index.atomId(), socket_module_data, vm);

    const mt_array = [_]Value{ Value.new.table(sock_table), Value.new.table(metatable) };
    const set_result = try metatable_mod.set_meta(&mt_array, vm);
    if (set_result != .ok) return error.SetMetatableFailed;

    try vm.registerFinalizer(sock_table, close_fn_data);

    return Value.new.table(sock_table);
}

fn isServer(socket_data: Value, vm: *VM) !bool {
    const table = try vm.tables.get(socket_data.asTable().?);
    const d = table.getRawAtom(revo.CoreAtoms.__is_server.atomId(), vm) orelse
        return error.InvalidSocket;
    return !revo.isFalse(d);
}

fn getEntryPtr(socket_data: Value, vm: *VM) !*SocketEntry {
    const table = try vm.tables.get(socket_data.asTable().?);
    const d = table.getRawAtom(revo.CoreAtoms.__entry_ptr.atomId(), vm) orelse
        return error.InvalidSocket;
    const addr: usize = root.host.numToInt(usize, d.asNumOpt().?) orelse return error.InvalidSocket;
    if (addr == 0) return error.SocketClosed;
    return @as(*SocketEntry, @ptrFromInt(addr));
}

fn fdId(fd: std.posix.fd_t) u64 {
    return switch (@typeInfo(std.posix.fd_t)) {
        .pointer => @intFromPtr(fd),
        else => @intCast(fd),
    };
}

/// wake everyone parked on the fd with SocketClosed, tokens freed
fn cancelWaitersFor(vm: *VM, fd: std.posix.fd_t) !void {
    var taken = try vm.sched.takeIoWaitersFor(fdId(fd));
    defer taken.deinit(vm.runtime.alloc);

    for (taken.items) |*waiter| {
        _ = try completeWaiter(vm, waiter, .err, revo.Value.new.core(.SocketClosed));
        if (waiter.on_deinit) |deinit_fn| deinit_fn(vm.runtime.alloc, waiter.token);
    }
}

fn closeEntry(socket_data: Value, vm: *VM) !void {
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
            freePending(vm.runtime.alloc, &s.pending);
            s.socket.close(io);
        },
        .server => |s| std.Io.net.Server.deinit(@constCast(&s), io),
    }
    vm.runtime.alloc.destroy(entry_ptr);

    var tbl = try vm.tables.get(socket_data.asTable().?);
    try tbl.putRawAtom(revo.CoreAtoms.__entry_ptr.atomId(), Value.new.num(0), vm);
    vm.unregisterFinalizer(socket_data.asTable().?);
}

fn parseRecvOptions(opts_data: Value, vm: *VM) !RecvWaitToken {
    var token: RecvWaitToken = .{};
    const opts = try vm.tables.get(opts_data.asTable().?);

    if (opts.getRawAtom(revo.CoreAtoms.max_bytes.atomId(), vm)) |max_d| {
        if (!max_d.isNumber()) return error.TypeError;
        token.max_bytes = root.host.numToInt(usize, max_d.asNumOpt().?) orelse return error.TypeError;
    }
    if (token.max_bytes == 0) token.max_bytes = 1;

    if (opts.getRawAtom(revo.CoreAtoms.delimiter.atomId(), vm)) |delim_d| {
        if (!delim_d.isString()) return error.TypeError;
        const s = vm.stringValue(delim_d.asString().?);
        if (s.len == 0) return error.TypeError;
        token.delimiter = s[0];
    }

    if (opts.getRawAtom(revo.CoreAtoms.mode.atomId(), vm)) |mode_d| {
        if (!mode_d.isAtom()) return error.TypeError;
        const a = mode_d.asAtom().?;
        if (a == revo.CoreAtoms.read_some.atomId()) {
            token.mode = .read_some;
        } else if (a == revo.CoreAtoms.read_all.atomId()) {
            token.mode = .read_all;
        } else if (a == revo.CoreAtoms.read_line.atomId()) {
            token.mode = .read_line;
        } else {
            return error.TypeError;
        }
    }

    return token;
}
