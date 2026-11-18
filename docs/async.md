---
title: 'the async runtime'
---

## async runtime

revo runs fibers cooperatively. when a fiber hits i/o, it goes on to do more important things than waiting,
on other fibers. the scheduler picks another ready fiber. when i/o completes, the fiber wakes up

it's important to me that your async code looks blocking but isn't, because it makes simple scripts faster for free

this lets you spawn hundreds of fibers without threads, callbacks or other nasty things

### fibers

a fiber is just a lightweight task the scheduler manages. you spawn them like this:

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

## concurrent networking for dummies

run it, open another terminal, type `nc localhost 6767` and you'll have yourself a shell
you can then open infinity more terminals and run the same command and have them be handled at once

```revo
const server = (net.listen(6767))?
print(fmt("serving on localhost:%d...", server.port))

fn serve(peer) do
  let counter = 0
  let iterations = 0
  print(fmt("new peer %v", peer))

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
      print(fmt("recv failed: %s \n", string(reason)))
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

### the scheduler

the coolest thing here is that async ops operate on generic tokens

the scehduler, `src/vm/scheduler.zig`,

- tracks fiber state (ready, waiting, running)
- maintains the runqueue
- tracks which fibers are waiting on i/o

the key type is `WaitEntry`:

```text
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

### i/o polling

`pollIoWaiters()` in `src/baselib/net.zig` uses `std.posix.poll()` on posix. when a file descriptor is ready:

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

### the io driver

all socket io is readiness-driven, we dont do worker threads anymore

`pollIoWaiters()` in `src/baselib/net.zig` snapshots the waiter list under lock
(each waiter carries a generation stamp),
`poll()`s the snapshot with no locks held,
then revalidates every ready fd against the live list before dispatching.

ready entries are claimed (removed) before their callback runs,
so later appends, removals, or array growth can't invalidate them;
still-pending entries go back with a fresh generation.

completions and callbacks run with the vm gil held

### socket:send(data)

```revo
const socket = (net.connect("example.com", 80))?
const result = socket:send("hello")?
```

- `send_fn` called
- `SendWaitToken` allocated with message ID and offset
- fast nonblocking send first; on `AGAIN` the fiber parks with `onSendReady`
- socket becomes writable, `onSendReady` fires
- sends bytes, updates offset if needed
- when all sent, wakes fiber with `(:ok, bytes_sent)`

### socket:recv(opts)

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

### socket:accept()

```revo
const listener = (net.listen(8080))?
const client = listener:accept()?
```

- `accept_fn` checks socket is a server
- nonblocking `accept` once; on `AGAIN` the fiber parks with `onAcceptReady`
- connection arrives, `onAcceptReady` calls `std.c.accept()`
- wraps socket in `SocketEntry`
- wakes fiber with `(:ok, new_socket_table)`

## extending to other i/o

to wait on a new fd source, park with a `WaitEntry` and handle it in a readiness callback:

- `vm.sched.parkCurrentForIo(wait_id, intent, token, on_ready, on_deinit)`
  appends the waiter (stamped with a fresh generation) and parks the fiber

- `pollIoWaiters` claims ready entries before dispatch;
  return `.{ .completed = true }` to drop yours,
  or `.{}` to be re-queued with a fresh generation

- tokens are yours: allocate on park, free in `on_deinit` or on completion

  the driver calls `on_deinit` exactly once per claimed entry that leaves
  the list with a nonzero token, so zero it after freeing it yourself

- match new completions by `(wait_id, fiber_id, intent, generation)`;
  anything else is stale (closed, recycled fd) and must be skipped

see `onRecvReady` above and `src/baselib/net.zig`

## performance

poll runs with zero timeout per scheduler cycle

recv buffers in `stream.pending` to handle partial reads. watch your allocation overhead. fibers allocate stack, so memory bounds your fiber count, not file descriptors

## gotchas

- don't store buffer pointers
  once you hand a buffer to a pending entry or token, it owns it. don't free it yourself later
- check fiber IDs before waking
  a fiber might have died, so validate the id
- completions aren't ordered
  readiness may fire out-of-order. don't assume fifo
