const std = @import("std");
const revo = @import("../root.zig");
const async_backend = @import("./async_backend.zig");

// default async backend
//   worker threads + completion pipe
//   workers do blocking syscalls and write completions to a pipe
//   main thread polls the pipe and processes completions in poll_impl

pub const BackendState = struct {
    control_r: c_int = -1,
    control_w: c_int = -1,
};

pub fn init(bs: *BackendState) anyerror!void {
    var fds: [2]c_int = undefined;
    if (std.c.pipe(&fds) == -1) return error.Unexpected;
    bs.control_r = fds[0];
    bs.control_w = fds[1];
    //
    // so that drain_pipe doesn't hang when queue is empty
    const cur = std.c.fcntl(bs.control_r, std.posix.F.GETFL, @as(c_int, 0));
    if (cur >= 0) {
        _ = std.c.fcntl(bs.control_r, std.posix.F.SETFL, @as(c_int, @bitCast(std.posix.O{ .NONBLOCK = true })));
    }
}

pub fn deinit(bs: *BackendState) void {
    if (bs.control_r >= 0) _ = std.c.close(bs.control_r);
    if (bs.control_w >= 0 and bs.control_w != bs.control_r) _ = std.c.close(bs.control_w);
    bs.control_r = -1;
    bs.control_w = -1;
}

fn wakeTuple(vm: *revo.VM, fiber_id: revo.VM.FiberID, tag: revo.core_atoms, payload: revo.Data) !void {
    const items = [_]revo.Data{ revo.Data.new.atom(@intFromEnum(tag)), payload };
    try vm.sched.wakeFiber(fiber_id, revo.Data.new.tuple(try vm.tuples.create(&items)));
}

const CompletionRecord = extern struct {
    job_ptr: *async_backend.AsyncJob,
    fiber_id: usize,
    kind: u8,
    status: i32,
    bytes: usize,
};

// CompletionRecord has to be be POD and reasonably small so pipe writes are atomic/cheap
// if this fails, the ipc encoding must figure out how to use smaller values
comptime {
    if (!(@sizeOf(CompletionRecord) <= 1024)) @compileError("CompletionRecord too large for pipe ipc");
    if (!(@alignOf(CompletionRecord) <= @alignOf(usize))) @compileError("CompletionRecord alignment is unexpected");
}

// worker; runs in separate thread and puts CompletionRecord down the pipe
fn worker(wfd: c_int, job: *async_backend.AsyncJob) void {
    var status: i32 = 0;
    var bytes: usize = 0;

    switch (job.kind) {
        .socket_send => {
            if (job.buffer) |buf| {
                const rc = std.c.send(job.handle, buf.ptr + job.offset, buf.len - job.offset, 0);
                if (rc >= 0) {
                    bytes = @intCast(rc);
                } else {
                    status = @as(i32, @intFromEnum(std.posix.errno(rc)));
                }
            } else {
                status = -1;
            }
        },
        .socket_recv => {
            if (job.buffer) |buf| {
                const rc = std.c.recv(job.handle, buf.ptr, job.max_bytes, 0);
                if (rc >= 0)
                    bytes = @intCast(rc)
                else
                    status = @as(i32, @intFromEnum(std.posix.errno(rc)));
            } else {
                status = -1;
            }
        },
        .socket_accept => {
            const old_flags = std.c.fcntl(job.handle, std.posix.F.GETFL, @as(c_int, 0));
            if (old_flags == -1) {
                status = @as(i32, @intFromEnum(std.posix.errno(old_flags)));
            } else {
                var set_rc: c_int = 0;
                const block_flags: c_int = old_flags & ~@as(c_int, @bitCast(std.posix.O{ .NONBLOCK = true }));
                set_rc = std.c.fcntl(job.handle, std.posix.F.SETFL, block_flags);
                if (set_rc == -1) {
                    status = @as(i32, @intFromEnum(std.posix.errno(set_rc)));
                } else {
                    const rc = std.c.accept(job.handle, null, null);
                    if (rc >= 0) {
                        bytes = @intCast(rc);
                    } else {
                        status = @as(i32, @intFromEnum(std.posix.errno(rc)));
                    }
                    _ = std.c.fcntl(job.handle, std.posix.F.SETFL, old_flags);
                }
            }
        },
    }

    var rec: CompletionRecord = .{ .job_ptr = job, .fiber_id = job.fiber_id, .kind = @as(u8, @intFromEnum(job.kind)), .status = status, .bytes = bytes };
    // write record to pipe; best-effort but log if odd
    const written = std.c.write(wfd, @ptrCast(@alignCast(&rec)), @sizeOf(CompletionRecord));
    _ = written;
}

pub fn submit(self: *BackendState, vm_ptr: *anyopaque, job: *async_backend.AsyncJob) anyerror!async_backend.AsyncTicket {
    const vm: *revo.VM = @ptrCast(@alignCast(vm_ptr));
    errdefer {
        if (job.buffer) |buf| vm.runtime.alloc.free(buf);
        vm.runtime.alloc.destroy(job);
    }
    // if sending a message id, copy message into buffer so worker can use it
    if (job.kind == async_backend.AsyncJobKind.socket_send and job.message_id != 0) {
        const msg = vm.stringValue(job.message_id);
        const buf = try vm.runtime.alloc.alloc(u8, msg.len);
        var i: usize = 0;
        while (i < msg.len) : (i += 1) buf[i] = msg[i];
        job.buffer = buf;
    }
    const t = try std.Thread.spawn(.{}, worker, .{ self.control_w, job });
    t.detach();
    return 0;
}

fn process_completion(vm: *revo.VM, rec: CompletionRecord) !void {
    const job = rec.job_ptr;
    switch (job.kind) {
        .socket_send => {
            if (rec.status == 0) {
                try wakeTuple(vm, rec.fiber_id, .ok, revo.Data.new.num(rec.bytes));
            } else {
                try wakeTuple(vm, rec.fiber_id, .err, revo.Data.new.core(.SendFailed));
            }
        },
        .socket_recv => {
            if (rec.status == 0) {
                if (rec.bytes == 0) {
                    try wakeTuple(vm, rec.fiber_id, .err, revo.Data.new.core(.SocketClosed));
                } else {
                    if (rec.job_ptr.*.buffer) |b| {
                        const buf_slice = b[0..rec.bytes];
                        const payload = try vm.ownDataString(buf_slice);
                        try wakeTuple(vm, rec.fiber_id, .ok, payload);
                    } else {
                        try wakeTuple(vm, rec.fiber_id, .err, revo.Data.new.core(.RecvFailed));
                    }
                }
            } else {
                try wakeTuple(vm, rec.fiber_id, .err, revo.Data.new.core(.RecvFailed));
            }
            // free buffer owned by backend
            if (rec.job_ptr.*.buffer) |b_free| {
                vm.runtime.alloc.free(b_free);
            }
        },

        .socket_accept => {
            if (rec.status == 0) {
                const new_fd: std.posix.fd_t = @intCast(rec.bytes);
                // wrap and wake with socket entry
                const new_entry_ptr = try vm.runtime.alloc.create(revo.std_net.SocketEntry);
                new_entry_ptr.* = .{
                    .stream = .{
                        .socket = .{ .socket = .{
                            .handle = new_fd,
                            .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } },
                        } },
                        .pending = &.{},
                    },
                };
                try wakeTuple(vm, rec.fiber_id, .ok, try revo.std_net.wrapSocket(vm, new_entry_ptr, false));
            } else {
                try wakeTuple(vm, rec.fiber_id, .err, revo.Data.new.core(.AcceptFailed));
            }
        },
    }

    // owned by backend after submit
    vm.runtime.alloc.destroy(job);
}

fn drain_pipe(vm: *revo.VM, bs: *BackendState) !bool {
    var buf_arr: [@sizeOf(CompletionRecord)]u8 align(@alignOf(CompletionRecord)) = undefined;
    var any = false;
    while (true) {
        const n = std.c.read(bs.control_r, &buf_arr, @sizeOf(CompletionRecord));
        if (n <= 0) break;
        if (n < @as(isize, @sizeOf(CompletionRecord))) break;
        const rec_ptr: *CompletionRecord = @ptrCast(@alignCast(&buf_arr));
        const rec = rec_ptr.*;
        try process_completion(vm, rec);
        any = true;
    }
    return any;
}

fn poll_impl(bs: *BackendState, vm_ptr: *anyopaque, timeout_ms: i32) anyerror!bool {
    const vm: *revo.VM = @ptrCast(@alignCast(vm_ptr));
    var woke_any = false;
    var used_timeout = timeout_ms;

    var one = [_]std.posix.pollfd{
        .{ .fd = bs.control_r, .events = std.posix.POLL.IN, .revents = 0 },
    };
    _ = try std.posix.poll(&one, timeout_ms);
    if (one[0].revents != 0) {
        const did = try drain_pipe(vm, bs);
        woke_any = woke_any or did;
    }
    used_timeout = 0;

    const io_woke = try revo.std_net.pollIoWaiters(vm, used_timeout);
    return woke_any or io_woke;
}

pub fn poll_all(bs: *BackendState, vm: *anyopaque, timeout_ms: i32) anyerror!bool {
    return poll_impl(bs, vm, timeout_ms);
}
