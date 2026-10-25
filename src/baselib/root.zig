//!
//! welcome to std root
//!
//! this is the one public interface and the collection of top-level globals
//!
//! ~ host functions are plain zig fns with a `(vm, typed-args...)` signature
//!   , `def` derives their arity and `ParamType`s at comptime
//!   , `impls` collects them into `specs.Impl` arrays
//!   , and the dispatcher in `VM.zig` checks arity and types before calling
//!

const builtin = @import("builtin");
const std = @import("std");

const revo = @import("../root.zig");
const mem = revo.memory;
const metatable = @import("metatable.zig");

const Value = mem.Value;
const VM = revo.VM;
const testing = revo.lang.test_helpers;

pub const ffi = @import("ffi.zig");
pub const host = @import("host.zig");
pub const specs = @import("specs.zig");

pub const Impl = struct {
    pub fn len(vm: *VM, val: host.ArgTypes.any) !host.HostResult {
        const mm = try vm.getMetamethodByAtom(val, revo.CoreAtoms.atomId(.__len));
        if (mm) |m| return callUnaryMetamethod(m, val, vm);
        return switch (val.tag()) {
            .string => .data(Value.new.num(vm.stringValue(val.asString().?).len)),
            .table => .data(Value.new.num((try vm.tables.get(val.asTable().?)).count())),
            else => .errType(1, "string or table", @import("root.zig").typeof(val, vm)),
        };
    }

    pub fn inspect(vm: *VM, val: host.ArgTypes.any) !host.HostResult {
        if (comptime !revo.is_freestanding)
            _ = try print(&[_]Value{val}, vm);
        return .data(val);
    }

    pub fn typeof(vm: *VM, val: host.ArgTypes.any) !host.HostResult {
        return .data(Value.new.atom(try vm.internAtom(@import("root.zig").typeof(val, vm))));
    }

    pub fn expect(vm: *VM, val: host.ArgTypes.any) !host.HostResult {
        if (revo.isFalse(val)) return host.HostResult.Err(vm, "ExpectFailed");
        return host.HostResult.Ok(vm, val);
    }

    pub fn expect_eq(vm: *VM, a: host.ArgTypes.any, b: host.ArgTypes.any) !host.HostResult {
        if (vm.compare(a, b) != .eq) {
            return host.HostResult.Err(vm, "NotEqual");
        }
        return host.HostResult.Ok(vm, a);
    }

    pub fn sleep(vm: *VM, ms: host.ArgTypes.number) !host.HostResult {
        const n: u64 = host.numToInt(u64, ms) orelse return .errType(0, "non-negative integer", @import("root.zig").typeof(Value.new.num(ms), vm));
        try vm.schedParkCurrentForSleepMS(n);
        return .parked();
    }

    pub fn hash(vm: *VM, val: host.ArgTypes.any) !host.HostResult {
        return .data(Value.new.num(val.hash(vm)));
    }
};

pub const root_impls: []const specs.Impl = host.impls(Impl).val ++ &[_]specs.Impl{
    .{ .name = "fmt", .f = host.defineVariadic(&[_]host.ParamType{.string}, fmt) },
    .{ .name = "get_meta", .f = host.define(&[_]host.ParamType{.any}, metatable.get_meta) },
    .{ .name = "set_meta", .f = host.define(&[_]host.ParamType{ .any, .any }, metatable.set_meta) },
    .{ .name = "set_debug", .f = host.define(&[_]host.ParamType{.table}, metatable.set_debug) },
    .{ .name = "debug_info", .f = host.define(&[_]host.ParamType{}, debug_info_) },
    .{ .name = "chan", .f = host.defineVariadic(&[_]host.ParamType{}, chan_new) },
    .{ .name = "send", .f = host.define(&[_]host.ParamType{ .table, .any }, chan_send) },
    .{ .name = "recv", .f = host.define(&[_]host.ParamType{.table}, chan_recv) },
    .{ .name = "join", .f = host.define(&[_]host.ParamType{.table}, join) },
    .{ .name = "assert", .f = host.define(&[_]host.ParamType{.any}, assert_) },
    .{ .name = "assert_eq", .f = host.define(&[_]host.ParamType{ .any, .any }, assert_eq) },
    .{ .name = "panic", .f = host.defineVariadic(&[_]host.ParamType{}, panic_) },
    .{ .name = "print", .f = host.defineVariadic(&[_]host.ParamType{}, print) },
};

pub const os_impls: []const specs.Impl = &.{
    .{ .name = "input", .f = if (revo.is_freestanding) host.defineStubVariadic(&[_]host.ParamType{}) else host.defineVariadic(&[_]host.ParamType{}, input) },
    .{ .name = "cwd", .f = if (revo.is_freestanding) host.defineStub(&[_]host.ParamType{}) else host.define(&[_]host.ParamType{}, cwd) },
    .{ .name = "exit", .f = if (revo.is_freestanding) host.defineStub(&[_]host.ParamType{.number}) else host.define(&[_]host.ParamType{.number}, exit) },
    .{ .name = "system", .f = if (revo.is_freestanding) host.defineStub(&[_]host.ParamType{.table}) else host.define(&[_]host.ParamType{.table}, system_) },
    .{ .name = "import", .f = if (revo.is_freestanding) host.defineStub(&[_]host.ParamType{.string}) else host.define(&[_]host.ParamType{.string}, import) },
    .{ .name = "__internal_dotest", .f = if (revo.is_freestanding) host.defineStub(&[_]host.ParamType{ .string, .function }) else host.define(&[_]host.ParamType{ .string, .function }, dotest) },
    .{ .name = "__internal_dosuite", .f = if (revo.is_freestanding) host.defineStub(&[_]host.ParamType{ .string, .function }) else host.define(&[_]host.ParamType{ .string, .function }, dosuite) },
    .{ .name = "getenv", .f = if (revo.is_freestanding) host.defineStub(&[_]host.ParamType{.string}) else host.define(&[_]host.ParamType{.string}, getenv_) },
    .{ .name = "setenv", .f = if (revo.is_freestanding or builtin.os.tag == .windows) host.defineStub(&[_]host.ParamType{ .string, .string }) else host.define(&[_]host.ParamType{ .string, .string }, setenv_) },
};

pub fn register_baselib(vm: *revo.VM) !void {
    vm.loaded_specs = try specs.loadAllSpecs(vm.runtime.alloc);

    const argv_atom = try vm.internAtom("argv");
    const all = specs.full_specs;
    try specs.registerAll(vm, all, mtPrototype);
    try attachMathPi(vm);
    try registerTypePredicates(vm);

    const argv_id = try vm.tables.create();
    const argv_val = Value.new.table(argv_id);
    try vm.user_globals.put(argv_atom, argv_val);
    try vm.builtin_globals.put(argv_atom, argv_val);
}

/// argv has to be populated after compilation
/// get rid of this one at some point
pub fn populateArgv(vm: *revo.VM) !void {
    const argv_atom = try vm.internAtom("argv");
    const argv_val = vm.user_globals.get(argv_atom) orelse return;
    const argv_id = argv_val.asTable() orelse return;
    const argv = try vm.tables.get(argv_id);
    for (vm.runtime.argv) |arg| {
        try argv.push(vm.runtime.alloc, try vm.ownValueString(arg));
    }
}

fn attachMathPi(vm: *revo.VM) !void {
    if (vm.user_globals.get(try vm.internAtom("math"))) |t| {
        if (t.asTable()) |table_id| {
            try vm.putField(table_id, "pi", Value.new.num(std.math.pi));
        }
    }
}

fn mtPrototype(target: host.ParamType, vm: *revo.VM) !Value {
    return switch (target) {
        .number => Value.new.num(0),
        .string => try vm.ownValueString(""),
        .table => Value.new.table(std.math.maxInt(usize)),
        else => return error.UnsupportedTarget,
    };
}

/// > fmt(format: string, args: any...) -> string
/// format string with %v, %?, %p specifiers
/// %v: value (plain, strings without quotes), %?: debug (strings with quotes, tables multilined), %p: pretty (debug with colors)
///     fmt("hello %v", "world")
///     fmt("val: %v, dbg: %?", "x", "y")
pub fn fmt(args: []const Value, vm: *VM) !host.HostResult {
    if (args.len == 0) return .errArity(0, 1);
    const format = vm.stringValue(args[0].asString().?);

    var result = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer result.deinit();

    const color = vm.runtime.supports_color;

    var arg_idx: usize = 1;
    var i: usize = 0;

    while (i < format.len) {
        if (i + 1 < format.len and format[i] == '%') {
            switch (format[i + 1]) {
                '%' => {
                    try result.writer.writeByte('%');
                    i += 2;
                },
                'v' => {
                    if (arg_idx >= args.len) return .errArity(args.len, arg_idx + 1);
                    try append_data(&result.writer, args[arg_idx], vm, .plain, color);
                    arg_idx += 1;
                    i += 2;
                },
                '?' => {
                    if (arg_idx >= args.len) return .errArity(args.len, arg_idx + 1);
                    try append_data(&result.writer, args[arg_idx], vm, .debug, color);
                    arg_idx += 1;
                    i += 2;
                },
                'p' => {
                    if (arg_idx >= args.len) return .errArity(args.len, arg_idx + 1);
                    try append_data(&result.writer, args[arg_idx], vm, .pretty, color);
                    arg_idx += 1;
                    i += 2;
                },
                else => {
                    try result.writer.writeByte('%');
                    try result.writer.writeByte(format[i + 1]);
                    i += 2;
                },
            }
        } else {
            try result.writer.writeByte(format[i]);
            i += 1;
        }
    }

    const str = try result.toOwnedSlice();
    return .data(try vm.adoptValueString(str));
}

test "fmt %v formats plain" {
    try testing.topString(
        \\ fmt("%v", 42)
    , "42");
    try testing.topString(
        \\ fmt("%v", 1.5)
    , "1.5");
    try testing.topString(
        \\ fmt("%v", "10.5")
    , "10.5");
    try testing.topString(
        \\ fmt("%v", :hello)
    , ":hello");
}

test "fmt escapes literal percent" {
    try testing.topString(
        \\ fmt("100%%")
    , "100%");
}

test "fmt %? uses debug rendering" {
    try testing.topString(
        \\ const mt = {__debug = fn(self) "custom-debug"}
        \\ const t = set_meta({}, mt)
        \\ fmt("%?", t)
    , "\"custom-debug\"");
}

test "fmt rendering is recursive" {
    try testing.topString(
        \\ const mt = {__display = fn(self) "shown", __debug = fn(self) "debug"}
        \\ const t = set_meta({}, mt)
        \\ fmt("%v|%?", {x = t}, {x = t})
    , "{ x = shown }|{ x = \"debug\" }");
}

/// internal, do not use pls
pub fn dotest(args: []const Value, vm: *VM) !host.HostResult {
    const name = args[0].asString().?;
    const body = args[1].asFunction().?;

    var buf: [128]u8 = undefined;
    var w = revo.stdout().writerStreaming(vm.runtime.io, &buf);
    defer w.flush() catch {};

    w.interface.print("* test \"{s}\"...\n", .{try vm.strings.get(name)}) catch {};
    w.flush() catch {};

    const res = vm.callFunctionParts(Value.new.function(body), null, &[0]Value{}, null) catch |err| {
        const failure = vm.runFailure(err);
        failure.render(&w.interface, vm.currentDebugSource() orelse "", vm.runtime.supports_color) catch {
            try revo.term.printError(&w.interface, vm.runtime.supports_color, "hard fail! {s}", .{@errorName(err)});
            return .data(Value.new.nil());
        };
        return .data(Value.new.nil());
    };
    // only react to err results
    // everything else is pass
    if (vm.resultParts(res)) |parts| {
        if (parts.len != 2)
            return .data(Value.new.nil());
        const tag = parts.tag.asAtom() orelse return .data(Value.new.nil());
        if (tag != revo.CoreAtoms.atomId(.err))
            return .data(Value.new.nil());

        var obuf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
        defer obuf.deinit();
        try append_data(&obuf.writer, parts.payload.?, vm, .debug, vm.runtime.supports_color);

        try revo.term.printError(&w.interface, vm.runtime.supports_color, "fail - {s}", .{obuf.written()});
    }
    return .data(Value.new.nil());
}

/// internal, pls dont use. runs a test suite
pub fn dosuite(args: []const Value, vm: *VM) !host.HostResult {
    const body = args[1].asFunction().?;
    var sbuf: [128]u8 = undefined;
    var sw = revo.stdout().writerStreaming(vm.runtime.io, &sbuf);
    defer sw.flush() catch {};

    _ = vm.callFunctionParts(Value.new.function(body), null, &[0]Value{}, null) catch |err| {
        const failure = vm.runFailure(err);
        var buf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
        defer buf.deinit();

        failure.render(&buf.writer, vm.currentDebugSource() orelse "", vm.runtime.supports_color) catch {
            sw.interface.print("* suite hard-failed: \"{s}\"\n", .{@errorName(err)}) catch {};
            return .coreAtom(.nil);
        };
        sw.interface.print("{s}\n", .{buf.written()}) catch {};
    };

    return .coreAtom(.nil);
}

pub fn debug_info_(args: []const Value, vm: *VM) !host.HostResult {
    _ = args;

    // putField re-fetches the table per write, so no pointer goes stale
    // across the creates below
    const flags_id = try vm.tables.create();
    try vm.putField(flags_id, "dump", Value.new.boolean(vm.debug.dump));
    try vm.putField(flags_id, "trace", Value.new.boolean(vm.debug.trace));
    try vm.putField(flags_id, "instr", Value.new.boolean(vm.debug.each_instr));
    try vm.putField(flags_id, "stack", Value.new.boolean(vm.debug.each_stack));

    const out_id = try vm.tables.create();
    try vm.putField(out_id, "flags", Value.new.table(flags_id));

    const fiber = vm.currentFiber();
    try vm.putField(out_id, "fiber_id", Value.new.num(fiber.id));
    try vm.putField(out_id, "pc", Value.new.num(fiber.pc));
    try vm.putField(out_id, "stack_depth", Value.new.num(fiber.registers_len));
    try vm.putField(out_id, "frame_depth", Value.new.num(fiber.frames.items.len));
    try vm.putField(out_id, "program_len", Value.new.num(fiber.program.len));

    if (vm.currentDebugInfo()) |info| {
        try vm.putField(out_id, "has_debug_info", Value.new.boolean(true));
        try vm.putField(out_id, "source_name", try vm.ownValueString(info.source_name));
        try vm.putField(out_id, "source", try vm.ownValueString(info.source));
        try vm.putField(out_id, "span_count", Value.new.num(info.spans.len));
    } else {
        try vm.putField(out_id, "has_debug_info", Value.new.boolean(false));
        try vm.putField(out_id, "source_name", Value.new.nil());
        try vm.putField(out_id, "source", Value.new.nil());
        try vm.putField(out_id, "span_count", Value.new.num(0));
    }

    try vm.putField(
        out_id,
        "panic_message",
        if (vm.panic_message) |msg| try vm.ownValueString(msg) else Value.new.nil(),
    );
    try vm.putField(
        out_id,
        "runtime_message",
        if (vm.runtime_message) |msg| try vm.ownValueString(msg) else Value.new.nil(),
    );

    return .data(Value.new.table(out_id));
}

pub fn typeof(d: Value, vm: *VM) []const u8 {
    _ = vm;
    return switch (d.tag()) {
        .atom => if (d.asAtom().? == revo.CoreAtoms.atomId(.nil)) "nil" else "atom",
        else => |e| @tagName(e),
    };
}

/// > string(arg0: any) -> string
/// converts value to string representation
/// uses __tostring or __display metamethod if available
pub fn string_(args: []const Value, vm: *VM) !host.HostResult {
    const mm = try vm.getMetamethodByAtom(args[0], revo.CoreAtoms.__tostring.atomId());
    if (mm) |m| return callUnaryMetamethod(m, args[0], vm);
    var buf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer buf.deinit();
    try args[0].write(&buf.writer, vm, .plain, vm.runtime.supports_color);
    const str = try buf.toOwnedSlice();
    return .data(try vm.adoptValueString(str));
}

fn asStackIndex(value: Value) ?usize {
    const num = value.asNumOpt() orelse return null;
    // SAFETY: asIndex returns null for non-integer/out-of-range numbers
    return revo.asIndex(num) catch null;
}

/// > chan(capacity?: number) -> table
/// creates a new channel with optional buffer size
///     chan()        # unbuffered
///     chan(5)       # buffer of 5
pub fn chan_new(args: []const Value, vm: *VM) !host.HostResult {
    const cap: usize = if (args.len == 0)
        0
    else if (args.len == 1)
        asStackIndex(args[0]) orelse return .errType(0, "number", typeof(args[0], vm))
    else
        return .errArity(args.len, 0);

    const channel_id = try vm.sched.channelCreate(&vm.tables, cap);
    return .data(try vm.tableOfSlice(&[2]Value{
        Value.new.atom(revo.CoreAtoms.chan.atomId()),
        Value.new.num(channel_id),
    }));
}

/// validate `args[0]` as a `:chan, id` table and extract the channel id
fn chanIdOf(args: []const Value, vm: *VM) host.HostResult {
    const table_id = args[0].asTable() orelse return .errType(0, "table", typeof(args[0], vm));
    const t = vm.tables.get(table_id) catch return .errType(0, "chan table", "table");
    if (t.array.items.len < 2) return .errType(0, "chan table", "table");
    const chan_atom = revo.CoreAtoms.chan.atomId();
    if (t.array.items[0].asAtom() != chan_atom)
        return .errType(0, "chan table", "table");
    const chan_id = t.array.items[1].asNumOpt() orelse return .errType(0, "chan table", "table");
    return .data(Value.new.num(@as(revo.vm.ChannelID, @intFromFloat(chan_id))));
}

/// > send(chan: table, value: any) -> atom
/// sends value to channel
pub fn chan_send(args: []const Value, vm: *VM) !host.HostResult {
    const cid = switch (chanIdOf(args, vm)) {
        .ok => |d| @as(revo.vm.ChannelID, @intFromFloat(d.asNumOpt().?)),
        else => |r| return r,
    };
    try vm.sched.channelSend(cid, args[1]);
    return host.HostResult.coreAtom(.ok);
}

/// > recv(chan: table) -> any
/// receives value from channel, parks if empty
pub fn chan_recv(args: []const Value, vm: *VM) !host.HostResult {
    const cid = switch (chanIdOf(args, vm)) {
        .ok => |d| @as(revo.vm.ChannelID, @intFromFloat(d.asNumOpt().?)),
        else => |r| return r,
    };
    const recv_result = try vm.sched.channelRecv(cid);
    if (recv_result) |value| return .data(value);
    return .parked();
}

/// validate `args[0]` as a `:fiber, id` table and extract the fiber id
/// , well-formed but unknown ids report separately so the message
/// doesn't blame the shape
const FidParse = union(enum) { ok: usize, bad_shape, bad_id };

// TODO: this must return a real zig error union
fn fiberIdOf(args: []const Value, vm: *VM) FidParse {
    const table_id = args[0].asTable() orelse return .bad_shape;
    const t = vm.tables.get(table_id) catch return .bad_shape;
    if (t.array.items.len < 2) return .bad_shape;

    const fiber_atom = revo.CoreAtoms.fiber.atomId();
    if (t.array.items[0].asAtom() != fiber_atom) return .bad_shape;

    const fid_num = t.array.items[1].asNumOpt() orelse return .bad_shape;
    const fid_int = revo.memory.numToI64(fid_num) orelse return .bad_id;
    if (fid_int < 0) return .bad_id;

    const fid: usize = @intCast(fid_int);
    if (fid >= vm.sched.fibers.items.len) return .bad_id;

    return .{ .ok = fid };
}

/// > join(handle: table) -> any
/// blocks until the fiber completes and returns its result
pub fn join(args: []const Value, vm: *VM) !host.HostResult {
    const target_id: usize = switch (fiberIdOf(args, vm)) {
        .ok => |id| id,
        .bad_shape => return .errType(0, "fiber handle", typeof(args[0], vm)),
        .bad_id => return .{ .err = .{ .type_error = .{
            .arg = 0,
            .expected = "live fiber handle",
            .got = typeof(args[0], vm),
        } } },
    };
    if (target_id == vm.sched.currentID())
        return host.HostResult.errAssertionFailed("cannot join self");

    const target = vm.sched.fibers.items[target_id];
    if (target.state == .dead) return .data(target.result);

    if (vm.host_call_depth > 0) {
        if (try revo.vm.dispatch.pumpUntilDone(vm, target_id)) |failure| {
            if (revo.lang.diagnostic.primarySpan(failure.report)) |span| {
                vm.panic_span = span.span;
            }
            return host.HostResult.errAssertionFailed(failure.report.message);
        }
        return .data(vm.sched.fibers.items[target_id].result);
    }

    try target.waiters.append(vm.runtime.alloc, vm.sched.currentID());
    vm.sched.parkCurrent(.{ .join = target_id });
    return .parked();
}

/// converts value to number
/// accepts number (passthrough) or string (parsed)
/// errors on other types
pub fn number_(args: []const Value, vm: *VM) !host.HostResult {
    if (args[0].isNumber()) return host.HostResult.Ok(vm, args[0]);
    if (args[0].asString()) |id| {
        const parsed = try std.fmt.parseFloat(f64, vm.stringValue(id));
        return host.HostResult.Ok(vm, Value.new.num(parsed));
    }
    return .errType(0, "number, string", typeof(args[0], vm));
}

/// > assert(what: any) -> what
/// panics if the value is falsy
pub fn assert_(args: []const Value, vm: *VM) !host.HostResult {
    if (revo.isFalse(args[0])) return panic_(&[1]Value{args[0]}, vm);
    return .data(args[0]);
}

/// > assert(what: any) -> what
/// panics if the value is falsy
pub fn assert_eq(args: []const Value, vm: *VM) !host.HostResult {
    if (vm.compare(args[0], args[1]) != .eq) {
        var buf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
        defer buf.deinit();
        try buf.writer.writeAll("assert_eq failed: ");
        try append_data(&buf.writer, args[0], vm, .plain, vm.runtime.supports_color);
        try buf.writer.writeAll(" (");
        try buf.writer.writeAll(typeof(args[0], vm));
        try buf.writer.writeAll(") != ");
        try append_data(&buf.writer, args[1], vm, .plain, vm.runtime.supports_color);
        try buf.writer.writeAll(" (");
        try buf.writer.writeAll(typeof(args[1], vm));
        try buf.writer.writeAll(")");
        try vm.setPanicMessage(buf.written());
        return .other("panic");
    }
    return .data(args[0]);
}

/// > print(args: any...) -> atom
/// prints values to stdout with space separator
///     print("hello", 42, "world")
pub fn print(args: []const Value, vm: *VM) !host.HostResult {
    var pbuf: [256]u8 = undefined;
    var pw = revo.stdout().writerStreaming(vm.runtime.io, &pbuf);
    defer _ = pw.flush() catch {};
    if (args.len == 0) {
        _ = try pw.interface.writeAll("\n");
        try pw.flush();
        return host.HostResult.coreAtom(.ok);
    }
    for (args, 0..) |a, idx| {
        if (idx != 0) _ = try pw.interface.writeAll(" ");
        try append_data(&pw.interface, a, vm, .plain, vm.runtime.supports_color);
    }
    try pw.interface.print("\n", .{});
    try pw.flush();
    return .data(revo.Value.new.core(.ok));
}

/// > panic(args: any...) -> error
/// panics with given message
///     panic("something went wrong")
pub fn panic_(args: []const Value, vm: *VM) !host.HostResult {
    var buf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer buf.deinit();
    if (args.len == 0) {
        try buf.writer.writeAll("panic");
    } else {
        for (args, 0..) |arg, idx| {
            if (idx != 0) try buf.writer.writeAll(" ");
            try append_data(&buf.writer, arg, vm, .plain, vm.runtime.supports_color);
        }
    }
    try vm.setPanicMessage(buf.written());
    return .other("panic");
}

/// abnormal `system` exit as `{:err, {:NonZeroExit, code}}`
/// , keeps the numeric status so scripts can match on it
fn exitStatusErr(vm: *VM, code: u8) !host.HostResult {
    const tag = try vm.internAtom("NonZeroExit");
    const detail = try vm.tableOfSlice(&[_]Value{ Value.new.atom(tag), Value.new.num(code) });
    return host.HostResult.errValue(vm, detail);
}

pub fn system_(tbl: []const Value, vm: *VM) !host.HostResult {
    const args = tbl[0].asTable().?;
    const table = try vm.tables.get(args);

    if (table.array.items.len == 0) return host.HostResult.Err(vm, "EmptyArgs");

    var argv = try vm.runtime.alloc.alloc([]const u8, table.array.items.len);
    defer vm.runtime.alloc.free(argv);

    var n: usize = 0;
    defer for (argv[0..n]) |arg| vm.runtime.alloc.free(arg);

    for (table.array.items, 0..) |arg, i| {
        const sid = arg.asString() orelse return .errType(0, "table of strings", typeof(arg, vm));
        argv[i] = try vm.runtime.alloc.dupe(u8, vm.stringValue(sid));
        n += 1;
    }

    var proc = try std.process.spawn(vm.runtime.io, .{
        .argv = argv,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer proc.kill(vm.runtime.io);

    // drain stdout and stderr concurrently: reading one pipe to EOF while the
    // child blocks writing the other (full pipe buffer) would deadlock
    var mr_buf: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(vm.runtime.alloc, vm.runtime.io, mr_buf.toStreams(), &.{ proc.stdout.?, proc.stderr.? });
    defer multi_reader.deinit();

    const depth = revo.vm.dispatch.gilDropForBlocking(vm);
    errdefer revo.vm.dispatch.gilTakeAfterBlocking(vm, depth);

    try multi_reader.fillRemaining(.none);

    const term = try proc.wait(vm.runtime.io);

    revo.vm.dispatch.gilTakeAfterBlocking(vm, depth);

    const so = try vm.adoptValueString(try multi_reader.toOwnedSlice(0));
    const se = try vm.adoptValueString(try multi_reader.toOwnedSlice(1));
    switch (term) {
        .exited => |code| if (code == 0) {
            const res = try vm.tableOfSlice(&[_]Value{ so, se });
            return .Ok(vm, res);
        } else {
            return exitStatusErr(vm, code);
        },
        // no numeric status to report here, the atoms say what happened
        .signal, .stopped => return host.HostResult.Err(vm, "Signaled"),
        .unknown => return host.HostResult.Err(vm, "UnknownExit"),
    }
}

pub fn input(args: []const Value, vm: *VM) !host.HostResult {
    const rt = &vm.runtime;

    var read_eof = false;
    var delim: u8 = '\n';

    if (args.len > 1) return .errArity(args.len, 1);
    if (args.len == 1) {
        const t = args[0].asTable() orelse return .errType(0, "table", typeof(args[0], vm));
        const table = try vm.tables.get(t);

        if (try table.get(Value.new.atom(revo.CoreAtoms.delimiter.atomId()), vm)) |v| {
            if (v.asAtom()) |atom| {
                const eof_id = revo.CoreAtoms.eof.atomId();
                if (atom == revo.CoreAtoms.nil.atomId() or atom == eof_id)
                    read_eof = true
                else
                    return .errType(0, "string, :nil, or :eof", typeof(v, vm));
            } else if (v.asString()) |id| {
                const s = vm.stringValue(id);
                if (s.len == 1) {
                    delim = s[0];
                } else {
                    return .errType(0, "single char string", "string");
                }
            } else {
                return .errType(0, "string, :nil, or :eof", typeof(v, vm));
            }
        }
    }

    const file = revo.stdin();
    var result = try std.ArrayList(u8).initCapacity(vm.runtime.alloc, 128);
    defer result.deinit(vm.runtime.alloc);

    // drain leftover from previous call first
    if (rt.input_buf_len > 0 and !read_eof) {
        if (std.mem.findScalar(u8, rt.input_buf[0..rt.input_buf_len], delim)) |di| {
            try result.appendSlice(vm.runtime.alloc, rt.input_buf[0..di]);
            const rest = rt.input_buf[di + 1 .. rt.input_buf_len];
            std.mem.copyForwards(u8, rt.input_buf[0..rest.len], rest);
            rt.input_buf_len = rest.len;
            return host.HostResult.Ok(vm, try vm.adoptValueString(try result.toOwnedSlice(vm.runtime.alloc)));
        }

        try result.appendSlice(vm.runtime.alloc, rt.input_buf[0..rt.input_buf_len]);
        rt.input_buf_len = 0;
    }

    while (true) {
        const n = file.readStreaming(vm.runtime.io, &.{rt.input_buf[rt.input_buf_len..]}) catch |err| switch (err) {
            error.EndOfStream => {
                if (result.items.len > 0)
                    return host.HostResult.Ok(vm, try vm.adoptValueString(try result.toOwnedSlice(vm.runtime.alloc)));
                return host.HostResult.Err(vm, "EndOfStream");
            },
            else => |e| return e,
        };
        const total = rt.input_buf_len + n;
        if (!read_eof) {
            if (std.mem.findScalar(u8, rt.input_buf[0..total], delim)) |di| {
                try result.appendSlice(vm.runtime.alloc, rt.input_buf[0..di]);
                const rest = rt.input_buf[di + 1 .. total];
                std.mem.copyForwards(u8, rt.input_buf[0..rest.len], rest);
                rt.input_buf_len = rest.len;
                return host.HostResult.Ok(vm, try vm.adoptValueString(try result.toOwnedSlice(vm.runtime.alloc)));
            }
        }
        try result.appendSlice(vm.runtime.alloc, rt.input_buf[0..total]);
        rt.input_buf_len = 0;
    }
}

pub fn cwd(args: []const Value, vm: *VM) !host.HostResult {
    _ = args;
    const cwd_path = try std.Io.Dir.cwd().realPathFileAlloc(vm.runtime.io, ".", vm.runtime.alloc);
    defer vm.runtime.alloc.free(cwd_path);
    return .data(try vm.ownValueString(cwd_path));
}

pub fn exit(args: []const Value, vm: *VM) !host.HostResult {
    if (args.len != 1) return .errArity(args.len, 1);
    const n = args[0].asNumOpt() orelse return .errType(0, "number", typeof(args[0], vm));
    const status: u8 = host.numToInt(u8, n) orelse 255;
    std.process.exit(status);
}

pub fn getenv_(args: []const Value, vm: *VM) !host.HostResult {
    const name = args[0].asString() orelse return .errType(0, "string", typeof(args[0], vm));

    const name_s = vm.stringValue(name);
    const name_z = try vm.runtime.alloc.dupeSentinel(u8, name_s, 0);
    defer vm.runtime.alloc.free(name_z);
    // really dont feel like threading environ_map down from main, sorry
    if (std.c.getenv(name_z)) |val| {
        const slice = std.mem.span(val);
        return .data(try vm.ownValueString(slice));
    }
    return .data(Value.new.nil());
}

pub fn setenv_(args: []const Value, vm: *VM) !host.HostResult {
    const name = args[0].asString() orelse return .errType(0, "string", typeof(args[0], vm));
    const value = args[1].asString() orelse return .errType(1, "string", typeof(args[1], vm));

    const name_s = vm.stringValue(name);
    const value_s = vm.stringValue(value);
    const name_z = try vm.runtime.alloc.dupeSentinel(u8, name_s, 0);
    defer vm.runtime.alloc.free(name_z);
    const value_z = try vm.runtime.alloc.dupeSentinel(u8, value_s, 0);
    defer vm.runtime.alloc.free(value_z);

    // really dont feel like threading environ_map down from main, sorry
    _ = libc_setenv(name_z.ptr, value_z.ptr, 1);
    return .data(Value.new.core(.ok));
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
const libc_setenv = setenv;

/// resolve + cache + run; `.so` loads native
pub fn import(args: []const Value, vm: *VM) !host.HostResult {
    if (args.len != 1) return .errArity(args.len, 1);

    const raw_path = args[0].asString() orelse return .errType(0, "string", typeof(args[0], vm));
    const raw_path_s = vm.stringValue(raw_path);

    const resolved_path = try revo.resolveImportFile(
        vm.runtime.io,
        vm.runtime.alloc,
        raw_path_s,
        vm.import_dir,
        vm.project_root,
        vm.package_path.items,
    ) orelse return .errModuleNotFound();

    defer vm.runtime.alloc.free(resolved_path);
    if (std.mem.endsWith(u8, resolved_path, ".so") or std.mem.endsWith(u8, resolved_path, ".dylib")) {
        const can_dlopen = switch (builtin.target.os.tag) {
            .wasi, .freestanding, .windows => false,
            else => true,
        };
        if (!can_dlopen) {
            return .errImportFailed("dynamic library loading not supported on this platform");
        }
        // `revo.extension` path first
        // get full arity/type checking
        if (revo.ffi.loadHost(vm, resolved_path)) |native_mods| {
            defer vm.runtime.alloc.free(native_mods);
            const t_id = try vm.tables.create();
            for (native_mods) |host_fn| {
                const fn_id = try vm.callable.create(.{ .host = host_fn });
                try vm.putField(t_id, host_fn.name, Value.new.function(fn_id));
            }
            return .data(Value.new.table(t_id));
        } else |err| switch (err) {
            error.NoBindings => {},
            else => return .errImportFailed(@errorName(err)),
        }

        const mods = revo.ffi.loadC(vm, resolved_path) catch |err| switch (err) {
            error.NoBindings => {
                return .errImportFailed("extension has no revo_native_bindings_ex or revo_bindings export");
            },
            else => return .errImportFailed(@errorName(err)),
        };
        defer vm.runtime.alloc.free(mods);
        const t_id = try vm.tables.create();

        for (mods) |c_fn| {
            const fn_id = try vm.callable.create(.{ .c_function = c_fn });
            try vm.putField(t_id, c_fn.name, Value.new.function(fn_id));
        }
        return .data(Value.new.table(t_id));
    }

    const current_stamp = try vm.importStamp(resolved_path);
    if (vm.import_cache.get(resolved_path)) |cached| {
        if (std.meta.eql(cached.stamp, current_stamp)) {
            return .data(cached.result);
        }
        _ = vm.invalidateImportCache(resolved_path);
    }
    for (vm.loading_stack.items) |loading| {
        if (std.mem.eql(u8, loading, resolved_path)) return .errCyclicImport();
    }

    const source = try std.Io.Dir.cwd().readFileAlloc(
        vm.runtime.io,
        resolved_path,
        vm.runtime.alloc,
        std.Io.Limit.unlimited,
    );
    defer vm.runtime.alloc.free(source);

    const cache_key = try vm.runtime.alloc.dupe(u8, resolved_path);
    errdefer vm.runtime.alloc.free(cache_key);

    try vm.loading_stack.append(vm.runtime.alloc, cache_key);
    const result = vm.runImportedModule(resolved_path, source) catch |err| {
        _ = vm.loading_stack.pop();
        if (err != error.OutOfMemory) vm.runtime.alloc.free(cache_key);
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => host.HostResult.errImportFailed(@errorName(err)),
        };
    };
    _ = vm.loading_stack.pop();

    try vm.import_cache.put(cache_key, .{ .result = result, .stamp = current_stamp });
    return .data(result);
}

fn append_data(writer: *std.Io.Writer, val: Value, vm: *VM, mode: Value.PrintMode, color: bool) !void {
    try val.write(writer, vm, mode, color);
}

pub fn callUnaryMetamethod(mm: Value, val: Value, vm: *VM) host.HostResult {
    if (!mm.isFunction()) return .errType(0, "function", typeof(mm, vm));
    const result = vm.callFunctionParts(mm, null, &.{val}, null) catch |err| {
        return .other(@errorName(err));
    };
    return .data(result);
}

// type utils
pub fn registerTypePredicates(vm: *VM) !void {
    inline for (@typeInfo(revo.memory.ValueTag).@"enum".field_names) |field_name| {
        const func = struct {
            fn is_of(args: []const Value, _: *VM) !host.HostResult {
                for (args) |arg| {
                    if (arg.tag() != @field(revo.memory.ValueTag, field_name)) {
                        return ._bool(false);
                    }
                }
                return ._bool(true);
            }
        }.is_of;
        const id = try vm.callable.create(.{ .host = host.define(
            &[1]host.ParamType{.any},
            func,
        ) });
        const atom = try vm.internAtom(field_name ++ "?");
        const val = Value.new.function(id);
        try vm.user_globals.put(atom, val);
        try vm.builtin_globals.put(atom, val);
    }
}

test "type predicates" {
    try testing.topTrue("number?(42)");
    try testing.topTrue("string?(\"hello\")");
    try testing.topTrue("table?({})");
    try testing.topTrue("atom?(:ok)");
    try testing.topTrue("function?(fn() 42)");
}

test "debug_info() links its nested flags table without a stale pointer" {
    // debug_info() creates the `out` table, then creates a second `flags` table.
    // the second create can reallocate the table pool, so `out` must be
    // fetched after it. these checks fail (or trip the allocator) if `out`
    // is written through a dangling pointer.
    try testing.topTrue("table?(debug_info().flags)");
    try testing.topFalse("debug_info().flags.dump");
    try testing.topTrue("number?(debug_info().stack_depth)");
}

test "array sort" {
    try testing.topNumber("{3, 1, 2}:sort():at(0)", 1);
    try testing.topNumber("{3, 1, 2}:sort():at(2)", 3);
    try testing.topNumber("{1, 5, 3}:sort_by(fn(a, b) a > b):at(0)", 5);
}

test "array transform" {
    try testing.topNumber("{1, 2, 3}:reverse():at(0)", 3);
    try testing.topNumber("iter.sum({1, 2, 3}:unique())", 6);
    try testing.topNumber("iter.sum({1, 2, 1, 3, 2}:unique())", 6);
}

test "string table conversion" {
    try testing.topNumber("len(\"abc\":table())", 3);
    try testing.topNumber("\"a\":ascii()", 97);
    try testing.topNumber("\"Hello\":ascii()", 72);
}

test "array flatten" {
    try testing.topNumber("iter.sum({{1, 2}, {3, 4}}:flatten())", 10);
    try testing.topNumber("iter.sum({{1}, {2, 3}, {4}}:flatten())", 10);
}

test "baselib json time and string modules are exposed" {
    try testing.topString("json.encode({\"a\", \"b\", \"c\"}):unwrap()", "[\"a\",\"b\",\"c\"]");
    try testing.topNumber("json.decode(\"{{ \\\"a\\\" : 1}}\"):unwrap().a", 1);
    try testing.topTrue("time.now() > 0");
    try testing.topNumber("len(string.split(\"a,b\", \",\"))", 2);
}

test "len" {
    try testing.topNumber("len(\"hi\")", 2);
    try testing.topNumber("len(\"\")", 0);
    try testing.topNumber("len(\"abcde\")", 5);
    try testing.topNumber("len({1, 2, 3})", 3);
    try testing.topNumber("len({1})", 1);
    try testing.topNumber("len({})", 0);
}

test "meatballs are distinct" {
    try testing.topString(
        \\ const a = set_meta({}, {__tostring = fn(self) "foo"})
        \\ const b = set_meta({}, {__tostring = fn(self) "bar"})
        \\ string(a)
    , "foo");

    try testing.topString(
        \\ const a = set_meta(:true, {__tostring = fn(self) "foo"})
        \\ string(1 == 1)
    , "foo");
}

test "bullshit: metatable constructors closures and method chaining" {
    try testing.topNumber(
        \\ let Counter = set_meta({}, {
        \\   new = fn(start) do
        \\     const state = {n = start}
        \\     set_meta(state, {
        \\       inc = fn(s, step) do s.n = s.n + step s end,
        \\       value = fn(s) s.n
        \\     })
        \\   end
        \\ })
        \\ let a = Counter.new(10)
        \\ let b = Counter.new(1)
        \\ a:inc(5):inc(7)
        \\ b:inc(2)
        \\ a:value() * 10 + b:value()
    , 223);
}

test "Hosts register as functions" {
    try testing.topType("len", .function);
    try testing.topType("number", .table);
    try testing.topType("assert", .function);
    try testing.topTrue("assert(typeof(len) == :function)");
}

test "expect" {
    try testing.topAtom(
        \\ let r = expect(1 == 2)
        \\ r[0]
    , "err");

    try testing.topNumber(
        \\ expect(42)?
    , 42);
}
