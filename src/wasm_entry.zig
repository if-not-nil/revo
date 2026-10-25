const revo = @import("revo");
const std = @import("std");

const VM = revo.VM;
const print = revo.vm.print;

pub const std_options_debug_io: std.Io = stub_io;

var wasm_alloc_state: std.heap.WasmAllocator = .{};
const wasm_alloc: std.mem.Allocator = .{
    .ptr = &wasm_alloc_state,
    .vtable = &std.heap.WasmAllocator.vtable,
};

// host-provided io, imported by the js runtime as wasm env functions
extern "env" fn js_write_stdout(ptr: [*]const u8, len: usize) void;
extern "env" fn js_write_stderr(ptr: [*]const u8, len: usize) void;

/// write a multi-slice payload to the host-provided stdout function
/// everything goes thru js_write_stdout during eval
fn writeToHost(
    comptime writeFn: *const fn ([*]const u8, usize) callconv(.c) void,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
) std.Io.Operation.FileWriteStreaming.Result {
    if (header.len > 0) writeFn(header.ptr, header.len);
    for (data[0..data.len -| 1]) |slice| {
        if (slice.len > 0) writeFn(slice.ptr, slice.len);
    }
    const last = data[data.len -| 1];
    var i: usize = 0;
    while (i < splat) : (i += 1) {
        if (last.len > 0) writeFn(last.ptr, last.len);
    }

    var total: usize = header.len;
    for (data[0..data.len -| 1]) |slice| total += slice.len;
    total += last.len * splat;
    return total;
}

//
// wasm-safe io vtable
//
fn wasmIoNow(_: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
    const clock_id: std.os.wasi.clockid_t = switch (clock) {
        .real => .REALTIME,
        .awake, .boot, .cpu_process, .cpu_thread => .MONOTONIC,
    };
    var ts: u64 = undefined;
    _ = std.os.wasi.clock_time_get(clock_id, 0, &ts);
    return .{ .nanoseconds = @intCast(ts) };
}

fn wasmIoClockResolution(_: ?*anyopaque, clock: std.Io.Clock) std.Io.Clock.ResolutionError!std.Io.Duration {
    _ = clock;
    return .{ .nanoseconds = 1_000_000 };
}

fn wasmIoSleep(_: ?*anyopaque, _: std.Io.Timeout) std.Io.Cancelable!void {
    // sleep is handled by the scheduler's fiber parking not by blocking
}

fn wasmIoCrashHandler(_: ?*anyopaque) void {}
fn wasmIoOperate(_: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
    return switch (operation) {
        .file_write_streaming => |req| blk: {
            // freestanding posix fd_t is void, all file values are identical
            // so everything routes to stdout; the host redirects by context (lol)
            const result = if (comptime @sizeOf(@TypeOf(req.file.handle)) == 0)
                writeToHost(js_write_stdout, req.header, req.data, req.splat)
            else if (req.file.handle == 2)
                writeToHost(js_write_stderr, req.header, req.data, req.splat)
            else
                writeToHost(js_write_stdout, req.header, req.data, req.splat);
            break :blk .{ .file_write_streaming = result };
        },
        .file_read_streaming => .{ .file_read_streaming = error.InputOutput },
        .device_io_control => .{ .device_io_control = -1 },
        .net_receive => .{ .net_receive = .{ error.NetworkDown, 0 } },
        .net_send => .{ .net_send = .{ error.NetworkDown, 0 } },
        .net_read => .{ .net_read = error.NetworkDown },
        .net_write => .{ .net_write = error.NetworkDown },
    };
}
fn wasmIoRecancel(_: ?*anyopaque) void {}

fn wasmIoSwapCancelProtection(_: ?*anyopaque, _: std.Io.CancelProtection) std.Io.CancelProtection {
    return .blocked;
}

fn wasmIoCheckCancel(_: ?*anyopaque) std.Io.Cancelable!void {}

var stderr_buf: [1024]u8 = undefined;
var stderr_writer: std.Io.File.Writer = undefined;

fn wasmIoLockStderr(_: ?*anyopaque, _: ?std.Io.Terminal.Mode) std.Io.Cancelable!std.Io.LockedStderr {
    stderr_writer = .{
        .io = stub_io,
        .file = revo.stderr(),
        .interface = std.Io.File.Writer.initInterface(&stderr_buf),
        .mode = .streaming,
    };
    return .{ .file_writer = &stderr_writer, .terminal_mode = .no_color };
}

fn wasmIoTryLockStderr(_: ?*anyopaque, _: ?std.Io.Terminal.Mode) std.Io.Cancelable!?std.Io.LockedStderr {
    stderr_writer = .{
        .io = stub_io,
        .file = revo.stderr(),
        .interface = std.Io.File.Writer.initInterface(&stderr_buf),
        .mode = .streaming,
    };
    return .{ .file_writer = &stderr_writer, .terminal_mode = .no_color };
}

fn wasmIoUnlockStderr(_: ?*anyopaque) void {
    if (stderr_writer.err == null) stderr_writer.interface.flush() catch {};
    stderr_writer.err = null;
    stderr_writer.interface.end = 0;
    stderr_writer.interface.buffer = &.{};
}

const wasm_io_vtable: std.Io.VTable = blk: {
    var v = std.Io.failing.vtable.*;
    v.crashHandler = wasmIoCrashHandler;
    v.recancel = wasmIoRecancel;
    v.swapCancelProtection = wasmIoSwapCancelProtection;
    v.checkCancel = wasmIoCheckCancel;
    v.operate = wasmIoOperate;
    v.lockStderr = wasmIoLockStderr;
    v.tryLockStderr = wasmIoTryLockStderr;
    v.unlockStderr = wasmIoUnlockStderr;
    v.now = wasmIoNow;
    v.clockResolution = wasmIoClockResolution;
    v.sleep = wasmIoSleep;
    break :blk v;
};

const stub_io: std.Io = .{ .userdata = null, .vtable = &wasm_io_vtable };

var global_vm: ?*VM = null;

/// tracks whether the most recent exported call completed successfully
///
/// * ok=true  & return > 0  successful eval, output is the result
/// * ok=true  & return = 0  successful eval, empty output
/// * ok=false & return > 0  revo-level error (compile/runtime), output is the error message
/// * ok=false & return = 0  internal error (oom, null vm, alloc failure, etc)
var wasm_last_call_ok: bool = true;

export fn revo_wasm_ok() bool {
    return wasm_last_call_ok;
}

export fn revo_wasm_alloc(len: usize) ?[*]u8 {
    if (len == 0) return null;
    return (wasm_alloc.alloc(u8, len) catch return null).ptr;
}

export fn revo_wasm_free(ptr: [*]u8, len: usize) void {
    if (len == 0) return;
    wasm_alloc.free(ptr[0..len]);
}

export fn revo_wasm_init() bool {
    if (global_vm != null) return false;

    const vm = wasm_alloc.create(VM) catch return false;
    vm.* = VM.init(.{
        .alloc = wasm_alloc,
        .io = stub_io,
        .argv = &.{},
        .diag_alloc = wasm_alloc,
    }) catch {
        wasm_alloc.destroy(vm);
        return false;
    };
    global_vm = vm;
    wasm_last_call_ok = true;
    return true;
}

/// writes directly into a fixed caller-provided buffer
/// tracks the untruncated count so the host can detect truncation
/// avoids the alloc+copy that Allocating would incur
const DirectWriter = struct {
    buf: []u8,
    pos: usize,
    writer: std.Io.Writer,

    fn init(buf: []u8) DirectWriter {
        return .{
            .buf = buf,
            .pos = 0,
            .writer = .{
                .buffer = &.{},
                .vtable = &vtable,
                .end = 0,
            },
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *DirectWriter = @fieldParentPtr("writer", w);
        var total: usize = 0;

        // all elements except the last are written once
        for (data[0..data.len -| 1]) |slice| {
            total += slice.len;
            if (self.pos < self.buf.len) {
                const n = @min(slice.len, self.buf.len - self.pos);
                @memcpy(self.buf[self.pos..][0..n], slice[0..n]);
                self.pos += n;
            }
        }

        // the last element is written `splat` times
        const last = data[data.len - 1];
        total += last.len * splat;
        var i: usize = 0;
        while (i < splat and self.pos < self.buf.len) : (i += 1) {
            const n = @min(last.len, self.buf.len - self.pos);
            @memcpy(self.buf[self.pos..][0..n], last[0..n]);
            self.pos += n;
        }

        return total;
    }

    fn flush(_: *std.Io.Writer) std.Io.Writer.Error!void {}

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
        .flush = flush,
    };
};

/// render a compile-error to a caller-provided buffer
///
/// returns the *untruncated* output length
/// sets wasm_last_call_ok = false so the host can tell error from result output
///
/// resets the diag arena after rendering (retains up to 4k for reuse)
/// do NOT call lang.deinitError !!! arena reset is the correct teardown
fn renderErrorToBuf(source: []const u8, out: []u8, failure: revo.lang.Error) usize {
    const vm = global_vm orelse {
        wasm_last_call_ok = false;
        return 0;
    };
    defer vm.runtime.resetDiagArena();
    var dw = DirectWriter.init(out);
    revo.lang.renderError(&dw.writer, .{ .name = "(wasm)", .text = source }, failure, .{ .color = vm.runtime.supports_color }) catch {
        wasm_last_call_ok = false;
        return 0;
    };
    wasm_last_call_ok = false;
    return dw.pos;
}

/// render a runtime-error to a caller-provided buffer
///
/// returns the untruncated output len
/// sets wasm_last_call_ok = false so the host can tell error from result output
///
/// resets the diag arena after rendering, same reasoning as renderErrorToBuf
fn renderRunFailureToBuf(source: []const u8, out: []u8, failure: revo.RunFailure) usize {
    const vm = global_vm orelse {
        wasm_last_call_ok = false;
        return 0;
    };
    defer vm.runtime.resetDiagArena();
    var dw = DirectWriter.init(out);
    failure.render(&dw.writer, source, vm.runtime.supports_color) catch {
        wasm_last_call_ok = false;
        return 0;
    };
    wasm_last_call_ok = false;
    return dw.pos;
}

/// evaluate revo source and write output into out_ptr[0..out_cap]
///
/// returns the *untruncated* output length (host compares > out_cap for truncation)
/// call revo_wasm_ok() to tell results from errors:
/// * ok=true  & return > 0  successful eval, output is the result
/// * ok=true  & return = 0  successful eval, empty output
/// * ok=false & return > 0  revo-level error (compile/runtime), output is the error message
/// * ok=false & return = 0  internal error (oom, null vm, alloc failure, etc)
export fn revo_wasm_eval(source_ptr: [*]const u8, source_len: usize, out_ptr: [*]u8, out_cap: usize) usize {
    wasm_last_call_ok = true;

    const vm = global_vm orelse {
        wasm_last_call_ok = false;
        return 0;
    };
    defer vm.runtime.resetDiagArena();
    const source = source_ptr[0..source_len];
    const out = out_ptr[0..out_cap];

    const build_result = revo.lang.build(vm, .{ .name = "(wasm)", .text = source }, .{}) catch {
        wasm_last_call_ok = false;
        return 0;
    };

    const bytecode = switch (build_result) {
        .ok => |art| art,
        .err => |failure| return renderErrorToBuf(source, out, failure),
    };
    defer vm.runtime.alloc.free(bytecode.instructions);
    defer vm.runtime.alloc.free(bytecode.spans);

    vm.setProgramDebugInfo(bytecode.spans, "", "(wasm)") catch {
        wasm_last_call_ok = false;
        return 0;
    };

    const eval_result = revo.run.runBytecodeReport(vm, "(wasm)", bytecode.instructions) catch {
        wasm_last_call_ok = false;
        return 0;
    };

    switch (eval_result) {
        .ok => {
            const data = vm.currentResult();
            var dw = DirectWriter.init(out);
            print.writeValue(data, &dw.writer, vm, .plain, vm.runtime.supports_color) catch {
                wasm_last_call_ok = false;
                return 0;
            };
            return dw.pos;
        },
        .err => |failure| return renderRunFailureToBuf(source, out, failure),
    }
}

export fn revo_wasm_check(source_ptr: [*]const u8, source_len: usize, out_ptr: [*]u8, out_cap: usize) usize {
    wasm_last_call_ok = true;
    const vm = global_vm orelse {
        wasm_last_call_ok = false;
        return 0;
    };
    defer vm.runtime.resetDiagArena();
    const source = source_ptr[0..source_len];
    const out = out_ptr[0..out_cap];
    const build_result = revo.lang.build(vm, .{ .name = "(wasm)", .text = source }, .{}) catch {
        wasm_last_call_ok = false;
        return 0;
    };
    switch (build_result) {
        .ok => |art| {
            vm.runtime.alloc.free(art.instructions);
            vm.runtime.alloc.free(art.spans);
            wasm_last_call_ok = true;
            return 0;
        },
        .err => |failure| return renderErrorToBuf(source, out, failure),
    }
}

export fn revo_wasm_deinit() void {
    if (global_vm) |vm| {
        vm.deinit();
        wasm_alloc.destroy(vm);
        global_vm = null;
    }
}
