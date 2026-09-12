---
title: 'the async runtime'
---

# async runtime

revo runs fibers cooperatively. when a fiber hits i/o, it goes on to do more important things than waiting,
on other fibers. the scheduler picks another ready fiber. when i/o completes, the fiber wakes up

it's important to me that your async code looks blocking but isn't, because it makes simple scripts faster for free

this lets you spawn hundreds of fibers without threads, callbacks or other nasty things

## fibers

a fiber is just a lightweight task the scheduler managws. you spawn them like this:

```revo
fn client() do
  const s = (net.connect("localhost", 5000))?
  s:send("hello")?
  const msg = s:recv({})?
  inspect(msg)
end

fn server() do
  const listener = (net.listen(5000))?
  let accepted = 0
  while accepted < 3 do
    const client = listener:accept()?
    const msg = client:recv({})?
    client:send(msg)?
    accepted = accepted + 1
  end
end

spawn client()
spawn server()
```

when `s:send()` would block, that fiber parks. the scheduler runs server fiber instead. once data is ready, the client fiber resumes with the result

# concurrent networking for dummies

run it, open another terminal, type `nc localhost 6767` and you'll have yourself a shell
you can then open infinity more terminals and run the same command and have them be handled at once

```revo
const server = (net.listen(6767))?
print!("serving on localhost:%d...", server.port)

fn serve(peer) do
  let counter = 0
  let iterations = 0
  print!("new peer %v", peer)

  while iterations < 5 do
    # send a prompt; if the socket is not writable yet, this fiber parks here
    # and resumes after the runtime gets a writable event for this fd
    peer:send("$ ")?
  
    # wait for one full line; read_line keeps appending chunks until it sees "\n"
    # other modes are read_some (as much as you can, this is the default) and read_all (until EOF)
    match peer:recv({ mode = :read_line })
    | (:ok, "x") => do
      # send a final message, then close the socket so future IO becomes
      # SocketClosed instead of reusing a dead fd
      peer:send("goodbye\n")?
      peer:close()?
      return :exited
    end
    | (:ok, "ping") => do
        counter = counter + 1
        # send the current counter back to the client
        peer:send("pong " + string(counter) + "\n")?
    end
    | (:ok, line) => do
        # echo any other line back to the same peer
        peer:send(line + "\n")?
    end
    | (:err, :SocketClosed) => do
      # the other side hung up, so just close our handle and stop this fiber
      peer:close()?
      return :client_closed
    end
    | (:err, reason) => do
      print!("recv failed: %s \n", string(reason))
      # close here too: once recv fails, the socket is no longer useful
      peer:close()?
      # this is not an error but a status, which is why we use snake_case instead of PascalCase
      return :recv_failed
    end
    iterations = iterations + 1
  end
end

let accepted = 0
while accepted < 3 do
  # accept the next connection; if none is ready, this fiber parks until the
  # runtime sees a connection on the listening socket.
  let conn = server:accept()?
  # the only thing you have to do to make it async is to add `spawn` here! 
  # to make the server itself async,
  # all you have to do is just move the while loop into a closure and spawn that
  spawn serve(conn)
  accepted = accepted + 1
end
```

## the scheduler
the coolest thing here is that async ops operate on generic tokens. that means, you can plug in
any backend, as long as it returns the right results

the scehduler, `src/vm/scheduler.zig`,
- tracks fiber state (ready, waiting, running)
- maintains the runqueue
- tracks which fibers are waiting on i/o

the key type is `WaitEntry`:
```
`fiber_id`:
    which fiber to wake
`wait_id`:
    file descriptor / socket handle
`intent`:
    read, write, or both
`token`:
    opaque state from the i/o layer
`on_ready`:
    callback when data arrives
`on_deinit`:
    cleanup
```

## i/o polling

`pollIoWaiters()` in `src/std/net.zig` uses `std.posix.poll()` on posix. when a file descriptor is ready:

- `on_ready` callback fires
- callback does the syscall (send/recv/accept)
- if done, calls `completeWaiter()` to wake the fiber
- fiber goes back on runqueue

```zig
fn onRecvReady(vm: *VM, waiter: *Scheduler.WaitEntry, events: i16) !Scheduler.IoDispatchResult {
    const token = @as(*RecvWaitToken, @ptrFromInt(waiter.token));
    const rc = std.c.recv(waiter.wait_id, buffer.ptr, buffer.len, flags);
    
    deinitToken(RecvWaitToken, vm.runtime.alloc, waiter.token);
    waiter.token = 0;
    return try completeWaiter(vm, waiter, .ok, data);
}
```

## the async backend

optional. lets you offload blocking syscalls to worker threads so the main thread never blocks

the interface is in `src/runtime/async_backend.zig`:

```zig
pub const AsyncBackend = struct {
    submit: ?*const anyopaque,
    cancel: ?*const anyopaque,
    poll: ?*const anyopaque,
    shutdown: ?*const anyopaque,
    data: ?*anyopaque,
};

pub const AsyncJob = struct {
    fiber_id: usize,
    kind: AsyncJobKind,
    handle: std.posix.fd_t,
    message_id: usize,
    offset: usize,
    buffer: ?[]u8,
    max_bytes: usize,
};
```

the default backend (`src/runtime/async_backend_posix.zig`) spins up worker threads. job goes to a thread, thread does the syscall, writes completion to a pipe, main thread polls it and wakes up the fiber

## socket:send(data)

```revo
const socket = (net.connect("example.com", 80))?
const result = socket:send("hello")?
```

- `send_fn` called
- `SendWaitToken` allocated with message ID and offset
- if backend exists, job queued to backend
- if not, fiber parks with `onSendReady` callback
- socket becomes writable, `onSendReady` fires
- sends bytes, updates offset if needed
- when all sent, wakes fiber with `(:ok, bytes_sent)`

## socket:recv(opts)

```revo
const socket = (net.connect("example.com", 80))?
const msg = socket:recv({ max_bytes = 1024 })?
```

- `recv_fn` called with options (read_some/read_line/read_all, max_bytes, delimiter)
- `RecvWaitToken` allocated
- socket parks with `onRecvReady`
- when data arrives, `onRecvReady` reads into buffer
- for `read_some`: wakes immediately
- for `read_line`: keeps buffering in `stream.pending` until delimiter
- for `read_all`: keeps buffering until close

## socket:accept()

```revo
const listener = (net.listen(8080))?
const client = listener:accept()?
```

- `accept_fn` checks socket is a server
- if backend, job queued
- if not, `onAcceptReady` runs via polling
- connection arrives, `onAcceptReady` calls `std.c.accept()`
- wraps socket in `SocketEntry`
- wakes fiber with `(:ok, new_socket_table)`

# writing a custom backend

you need:

- backend state struct
- four functions (submit, poll, cancel, shutdown)
- register in VM

## state

```zig
// src/runtime/async_backend_custom.zig
const std = @import("std");
const revo = @import("../root.zig");
const async_backend = @import("./async_backend.zig");

pub const CustomBackendState = struct {
    job_queue: std.ArrayList(*async_backend.AsyncJob),
    completions: std.ArrayList(CompletionRecord),
};

const CompletionRecord = struct {
    job_ptr: *async_backend.AsyncJob,
    status: i32,
    bytes: usize,
};
```

## submit

queue a job. you own it after this

```zig
pub fn submit(backend: *async_backend.AsyncBackend, vm_ptr: *anyopaque, job: *async_backend.AsyncJob) anyerror!async_backend.AsyncTicket {
    const state = @as(*CustomBackendState, @ptrCast(@alignCast(backend.data)));
    const vm = @as(*revo.VM, @ptrCast(@alignCast(vm_ptr)));
    
    try state.job_queue.append(vm.runtime.alloc, job);
    return state.job_queue.items.len - 1;
}
```

## poll

check for completions. wake fibers

```zig
pub fn poll(backend: *async_backend.AsyncBackend, vm_ptr: *anyopaque) anyerror!bool {
    const state = @as(*CustomBackendState, @ptrCast(@alignCast(backend.data)));
    const vm = @as(*revo.VM, @ptrCast(@alignCast(vm_ptr)));
    
    var woke_any = false;
    
    while (state.completions.popOrNull()) |completion| {
        if (completion.job_ptr.fiber_id >= vm.sched.fibers.items.len) {
            vm.runtime.alloc.destroy(completion.job_ptr);
            continue;
        }
        
        const result_data = if (completion.status != 0)
            try vm.dataAtom(std.posix.errno(@as(u32, @bitCast(completion.status))))
        else
            revo.Data.new.num(@floatFromInt(completion.bytes));
        
        try vm.sched.wakeFiber(
            completion.job_ptr.fiber_id,
            try vm.resultTable(.ok, result_data),
        );
        
        vm.runtime.alloc.destroy(completion.job_ptr);
        woke_any = true;
    }
    
    return woke_any;
}
```

## cancel

remove a job from the queue before it runs

```zig
pub fn cancel(backend: *async_backend.AsyncBackend, ticket: async_backend.AsyncTicket) void {
    const state = @as(*CustomBackendState, @ptrCast(@alignCast(backend.data)));
    
    if (ticket < state.job_queue.items.len) {
        _ = state.job_queue.swapRemove(ticket);
    }
}
```

## shutdown

clean up. optional, but do it anyway

```zig
pub fn shutdown(backend: *async_backend.AsyncBackend, alloc: std.mem.Allocator) void {
    const state = @as(*CustomBackendState, @ptrCast(@alignCast(backend.data)));
    
    state.job_queue.deinit(alloc);
    state.completions.deinit(alloc);
    alloc.destroy(state);
}
```

## register

in VM init:

```zig
const backend_state = try vm.runtime.alloc.create(async_backend_custom.CustomBackendState);
backend_state.* = .{
    .job_queue = std.ArrayList(*async_backend.AsyncJob).init(vm.runtime.alloc),
    .completions = std.ArrayList(async_backend_custom.CompletionRecord).init(vm.runtime.alloc),
};

try async_backend_custom.init(backend_state);

vm.runtime.async_backend = async_backend.AsyncBackend{
    .submit = &async_backend_custom.submit,
    .cancel = &async_backend_custom.cancel,
    .poll = &async_backend_custom.poll,
    .shutdown = &async_backend_custom.shutdown,
    .data = backend_state,
};
```

# extending to other i/o

to add file async or timers:

- extend `AsyncJobKind` in `src/runtime/async_backend.zig`
- extend `AsyncJob` with new fields
- handle new job types in your backend
- extend socket layer to submit for new ops

see `src/std/net.zig`:

```zig
if (vm.runtime.async_backend) |backend| {
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
    _ = try backend.submit(backend, @ptrCast(vm), job);
}
```

# performance

poll runs with zero timeout per scheduler cycle. if you need more throughput, replace the one-thread-per-job default with a thread pool

recv buffers in `stream.pending` to handle partial reads. watch your allocation overhead. fibers allocate stack, so memory bounds your fiber count, not file descriptors

# gotchas

- allocate tokens yourself if you submit jobs directly
  when you submit a job directly to the backend without going thru the socket layer, the job is yours to manage, so allocate the token & free it when done
- don't store buffer pointers
  once you pass a buffer to the backend, it owns it. don't free it yourself later
- check fiber IDs before waking
  a fiber might have died, so validate the id
- completions aren't ordered
  backend completions may arrive out-of-order. don't assume fifo
