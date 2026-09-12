//!
//! welcome to std's root
//!
//! this is the public interface and the collection of top-level globals
//!

const std = @import("std");
const builtin = @import("builtin");

const revo = @import("../root.zig");
const mem = revo.memory;
const meta = @import("meta.zig");

const Data = mem.Data;
const VM = revo.VM;
const testing = revo.lang.testing;

pub const api = @import("api.zig");

pub const Impl = struct {
    pub fn len(vm: *VM, val: T.any) !HostResult {
        const mm = try vm.getMetamethodByAtom(val, revo.core_atoms.atomId(.__len));
        if (mm) |m| return callUnaryMetamethod(m, val, vm);
        return switch (val.tag()) {
            .string => .data(Data.new.num(vm.stringValue(val.asString().?).len)),
            .table => .data(Data.new.num((try vm.tables.get(val.asTable().?)).count())),
            else => .errType(1, "string or table", @import("root.zig").typeof(val, vm)),
        };
    }

    pub fn inspect(vm: *VM, val: T.any) !HostResult {
        if (comptime !revo.is_freestanding)
            _ = try print(&[_]Data{val}, vm);
        return .data(val);
    }

    pub fn @"type"(vm: *VM, val: T.any) !HostResult {
        return .data(Data.new.atom(try vm.internAtom(@import("root.zig").typeof(val, vm))));
    }

    pub fn typeof(vm: *VM, val: T.any) !HostResult {
        return @"type"(vm, val);
    }

    pub fn expect(vm: *VM, val: T.any) !HostResult {
        if (revo.isFalse(val)) return HostResult.Err(vm, "ExpectFailed");
        return HostResult.Ok(vm, val);
    }

    pub fn expect_eq(vm: *VM, a: T.any, b: T.any) !HostResult {
        if (vm.compare(a, b) != .eq) {
            return HostResult.Err(vm, "NotEqual");
        }
        return HostResult.Ok(vm, a);
    }

    pub fn sleep(vm: *VM, ms: T.number) !HostResult {
        const n: u64 = numToInt(u64, ms) orelse return .errType(0, "non-negative integer", @import("root.zig").typeof(Data.new.num(ms), vm));
        try vm.schedParkCurrentForSleepMS(n);
        return .parked();
    }

    pub fn gensym(vm: *VM) !HostResult {
        const n = gensym_counter;
        gensym_counter += 1;
        const name = try std.fmt.allocPrint(vm.runtime.alloc, "__gensym_{d}", .{n});
        defer vm.runtime.alloc.free(name);
        return .data(try vm.ownDataStringNoDedup(name));
    }

    pub fn hash(vm: *VM, val: T.any) !HostResult {
        return .data(Data.new.num(val.hash(vm)));
    }
};

pub const root_impls: []const api.Impl = impls(Impl).val ++ &[_]api.Impl{
    .{ .name = "fmt", .f = defineVariadic(&[_]TypeSpec{.string}, fmt) },
    .{ .name = "get_meta", .f = define(&[_]TypeSpec{.any}, meta.get_meta) },
    .{ .name = "set_meta", .f = define(&[_]TypeSpec{ .any, .any }, meta.set_meta) },
    .{ .name = "set_debug", .f = define(&[_]TypeSpec{.table}, meta.set_debug) },
    .{ .name = "debug", .f = define(&[_]TypeSpec{}, debug_) },
    .{ .name = "unwrap", .f = define(&[_]TypeSpec{.any}, try_) },
    .{ .name = "chan", .f = defineVariadic(&[_]TypeSpec{}, chan_new) },
    .{ .name = "send", .f = define(&[_]TypeSpec{ .table, .any }, chan_send) },
    .{ .name = "recv", .f = define(&[_]TypeSpec{.table}, chan_recv) },
    .{ .name = "assert", .f = define(&[_]TypeSpec{.any}, assert_) },
    .{ .name = "assert_eq", .f = define(&[_]TypeSpec{ .any, .any }, assert_eq) },
    .{ .name = "panic", .f = defineVariadic(&[_]TypeSpec{}, panic_) },
    .{ .name = "print", .f = defineVariadic(&[_]TypeSpec{}, print) },
};

pub const os_impls: []const api.Impl = &.{
    .{ .name = "input", .f = if (revo.is_freestanding) defineStubVariadic(&[_]TypeSpec{}) else defineVariadic(&[_]TypeSpec{}, input) },
    .{ .name = "cwd", .f = if (revo.is_freestanding) defineStub(&[_]TypeSpec{}) else define(&[_]TypeSpec{}, cwd) },
    .{ .name = "exit", .f = if (revo.is_freestanding) defineStub(&[_]TypeSpec{.number}) else define(&[_]TypeSpec{.number}, exit) },
    .{ .name = "system", .f = if (revo.is_freestanding) defineStub(&[_]TypeSpec{.table}) else define(&[_]TypeSpec{.table}, system_) },
    .{ .name = "import", .f = if (revo.is_freestanding) defineStub(&[_]TypeSpec{.string}) else define(&[_]TypeSpec{.string}, import) },
    .{ .name = "__internal_dotest", .f = if (revo.is_freestanding) defineStub(&[_]TypeSpec{ .string, .function }) else define(&[_]TypeSpec{ .string, .function }, dotest) },
    .{ .name = "__internal_dosuite", .f = if (revo.is_freestanding) defineStub(&[_]TypeSpec{ .string, .function }) else define(&[_]TypeSpec{ .string, .function }, dosuite) },
    .{ .name = "getenv", .f = if (revo.is_freestanding) defineStub(&[_]TypeSpec{.string}) else define(&[_]TypeSpec{.string}, getenv_) },
    .{ .name = "setenv", .f = if (revo.is_freestanding or builtin.os.tag == .windows) defineStub(&[_]TypeSpec{ .string, .string }) else define(&[_]TypeSpec{ .string, .string }, setenv_) },
};

pub fn register_stdlib(vm: *revo.VM) !void {
    vm.loaded_specs = try api.loadAllSpecs(vm.runtime.alloc);

    const argv_atom = try vm.internAtom("argv");
    const all = api.full_specs;
    try api.registerAll(vm, all, mtPrototype);
    try attachMathPi(vm);
    try typeUtils(vm);

    const argv_id = try vm.tables.create();
    const argv_val = Data.new.table(argv_id);
    try vm.globals.put(argv_atom, argv_val);
    try vm.stdlib_globals.put(argv_atom, argv_val);
}

/// argv has to be populated after compilation
/// get rid of this one at some point
pub fn populateArgv(vm: *revo.VM) !void {
    const argv_atom = try vm.internAtom("argv");
    const argv_val = vm.globals.get(argv_atom) orelse return;
    const argv_id = argv_val.asTable() orelse return;
    const argv = try vm.tables.get(argv_id);
    for (vm.runtime.argv) |arg| {
        try argv.push(vm.runtime.alloc, try vm.ownDataString(arg));
    }
}

fn attachMathPi(vm: *revo.VM) !void {
    if (vm.globals.get(try vm.internAtom("math"))) |t| {
        if (t.asTable()) |table_id| {
            try vm.putField(table_id, "pi", Data.new.num(std.math.pi));
        }
    }
}

fn mtPrototype(target: TypeSpec, vm: *revo.VM) !Data {
    return switch (target) {
        .number => Data.new.num(0),
        .string => try vm.ownDataString(""),
        .table => Data.new.table(std.math.maxInt(usize)),
        else => return error.UnsupportedTarget,
    };
}

pub const HostFn = *const fn (args: []const Data, vm: *VM) anyerror!HostResult;
pub const HostFunc = struct {
    name: []const u8 = "",
    arity: usize,
    total_arity: usize = 0,
    variadic: bool = false,
    param_types: []const TypeSpec,
    ret_type: TypeSpec = .any,
    func: HostFn,
};

pub fn define(
    comptime types: []const TypeSpec,
    impl: HostFn,
) HostFunc {
    return .{
        .arity = types.len,
        .param_types = types,
        .func = impl,
    };
}

pub fn defineVariadic(
    comptime types: []const TypeSpec,
    impl: HostFn,
) HostFunc {
    return .{
        .arity = types.len,
        .variadic = true,
        .param_types = types,
        .func = impl,
    };
}

pub fn Args(comptime specs: []const TypeSpec) type {
    const types: [specs.len]type = comptime blk: {
        var result: [specs.len]type = undefined;
        for (specs, 0..) |spec, i| {
            result[i] = specToType(spec);
        }
        break :blk result;
    };
    return std.meta.Tuple(&types);
}

pub fn specToType(comptime spec: TypeSpec) type {
    return switch (spec) {
        .number => T.number,
        .string => T.string,
        .atom => T.atom,
        .function => T.function,
        .table => T.table,
        .bool => bool,
        .any => Data,
    };
}

pub fn unwrapArgs(comptime specs: []const TypeSpec, args: []const Data) Args(specs) {
    var result: Args(specs) = undefined;
    inline for (specs, 0..) |spec, i| {
        result[i] = switch (spec) {
            .number => args[i].asNum().?,
            .string => args[i].asString().?,
            .atom => args[i].asAtom().?,
            .function => args[i].asFunction().?,
            .table => args[i].asTable().?,
            .bool => args[i].asAtom().?,
            .any => args[i],
        };
    }
    return result;
}

pub const ResultTag = enum { ok, err };

pub const TypeSpec = union(enum) {
    number,
    string,
    atom,
    function,
    table,
    bool,
    any,

    pub fn matches(self: TypeSpec, data: Data) bool {
        return switch (self) {
            .any => true,
            .number => data.isNumber(),
            .bool => if (data.asAtom()) |a| isBoolAtom(a) else false,
            .string => data.isString(),
            .atom => data.isAtom(),
            .function => data.isFunction(),
            .table => data.isTable(),
        };
    }

    /// module table name for primitive method targets (`string:len` goes
    /// in `string`); null for the rest. single source for this mapping.
    pub fn moduleName(self: TypeSpec) ?[]const u8 {
        return switch (self) {
            .number => "number",
            .string => "string",
            .table => "table",
            else => null,
        };
    }
};

pub fn typeFromName(name: []const u8) ?TypeSpec {
    const tbl = std.StaticStringMap(TypeSpec).initComptime(.{
        .{ "number", .number },
        .{ "int", .number },
        .{ "string", .string },
        .{ "atom", .atom },
        .{ "function", .function },
        .{ "table", .table },
        .{ "bool", .bool },
        .{ "any", .any },
    });
    return tbl.get(name);
}

/// lookup `key` in the module table named `name`; null when the module
/// or key is absent. untyped method receivers fall back here via the
/// type metatable's `__index` chain
fn isBoolAtom(atom: mem.AtomID) bool {
    const true_id = revo.core_atoms.atomId(.true);
    const false_id = revo.core_atoms.atomId(.false);
    return atom == true_id or atom == false_id;
}

/// converts a num to an integer of type T; null when the value is not a
/// finite integral num representable in T
pub const numToInt = revo.vm.memory.numToInt;

fn makeResult(vm: *VM, comptime tag: ResultTag, value: Data) !HostResult {
    const atom: revo.core_atoms = switch (tag) {
        .ok => .ok,
        .err => .err,
    };
    return .data(try vm.resultTable(atom, value));
}

pub inline fn boolData(value: bool) Data {
    return if (value) revo.Data.new.core(.true) else revo.Data.new.core(.false);
}

/// > fmt(format: string, args: any...) -> string
/// format string with %v, %?, %p specifiers
/// %v: value (plain, strings without quotes), %?: debug (strings with quotes, tables multilined), %p: pretty (debug with colors)
///     fmt("hello %v", "world")
///     fmt("val: %v, dbg: %?", "x", "y")
pub fn fmt(args: []const Data, vm: *VM) !HostResult {
    if (args.len == 0) return .errArity(0, 1);
    const format = vm.stringValue(args[0].asString().?);

    var result = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer result.deinit();

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
                    try append_data(&result.writer, args[arg_idx], vm, .display);
                    arg_idx += 1;
                    i += 2;
                },
                '?' => {
                    if (arg_idx >= args.len) return .errArity(args.len, arg_idx + 1);
                    try append_data(&result.writer, args[arg_idx], vm, .debug);
                    arg_idx += 1;
                    i += 2;
                },
                'p' => {
                    if (arg_idx >= args.len) return .errArity(args.len, arg_idx + 1);
                    const old_supports = revo.pretty.supports_color;
                    revo.pretty.supports_color = true;
                    errdefer revo.pretty.supports_color = old_supports;
                    try append_data(&result.writer, args[arg_idx], vm, .pretty);
                    revo.pretty.supports_color = old_supports;
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
    return .data(try vm.adoptDataString(str));
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
pub fn dotest(args: []const Data, vm: *VM) !HostResult {
    const name = args[0].asString().?;
    const body = args[1].asFunction().?;
    var buf: [128]u8 = undefined;
    var w = revo.stdout().writerStreaming(vm.runtime.io, &buf);
    defer w.flush() catch {};

    w.interface.print("* test \"{s}\"...\n", .{try vm.strings.get(name)}) catch {};
    w.flush() catch {};
    const res = vm.callFunctionParts(Data.new.function(body), null, &[0]Data{}, null) catch |err| {
        const failure = vm.evalFailure(err);
        failure.render(vm.runtime.alloc, &w.interface, vm.currentDebugSource() orelse "") catch {
            try revo.pretty.printError(&w.interface, "hard-fail - {s}", .{@errorName(err)});
            return .data(Data.new.nil());
        };
        return .data(Data.new.nil());
    };
    // only react to err results
    // everything else is pass
    if (vm.resultParts(res)) |parts| {
        if (parts.len != 2)
            return .data(Data.new.nil());
        const tag = parts.tag.asAtom() orelse return .data(Data.new.nil());
        if (tag != revo.core_atoms.atomId(.err))
            return .data(Data.new.nil());

        var obuf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
        defer obuf.deinit();
        try append_data(&obuf.writer, parts.payload.?, vm, .debug);

        try revo.pretty.printError(&w.interface, "fail - {s}", .{obuf.written()});
    }
    return .data(Data.new.nil());
}

/// internal, pls dont use. runs a test suite
pub fn dosuite(args: []const Data, vm: *VM) !HostResult {
    const body = args[1].asFunction().?;
    var sbuf: [128]u8 = undefined;
    var sw = revo.stdout().writerStreaming(vm.runtime.io, &sbuf);
    defer sw.flush() catch {};
    _ = vm.callFunctionParts(Data.new.function(body), null, &[0]Data{}, null) catch |err| {
        const failure = vm.evalFailure(err);
        var buf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
        defer buf.deinit();
        failure.render(vm.runtime.alloc, &buf.writer, vm.currentDebugSource() orelse "") catch {
            sw.interface.print("* suite hard-failed: \"{s}\"\n", .{@errorName(err)}) catch {};
            return .coreAtom(.nil);
        };
        sw.interface.print("{s}\n", .{buf.written()}) catch {};
    };

    return .coreAtom(.nil);
}

pub fn debug_(args: []const Data, vm: *VM) !HostResult {
    _ = args;

    // putField re-fetches the table per write, so no pointer goes stale
    // across the creates below
    const flags_id = try vm.tables.create();
    try vm.putField(flags_id, "dump", Data.new.boolean(vm.debug.dump));
    try vm.putField(flags_id, "trace", Data.new.boolean(vm.debug.trace));
    try vm.putField(flags_id, "instr", Data.new.boolean(vm.debug.each_instr));
    try vm.putField(flags_id, "stack", Data.new.boolean(vm.debug.each_stack));

    const out_id = try vm.tables.create();
    try vm.putField(out_id, "flags", Data.new.table(flags_id));

    const fiber = vm.currentFiber();
    try vm.putField(out_id, "fiber_id", Data.new.num(fiber.id));
    try vm.putField(out_id, "pc", Data.new.num(fiber.pc));
    try vm.putField(out_id, "stack_depth", Data.new.num(fiber.registers_len));
    try vm.putField(out_id, "frame_depth", Data.new.num(fiber.frames.items.len));
    try vm.putField(out_id, "program_len", Data.new.num(fiber.program.len));

    if (vm.currentDebugInfo()) |info| {
        try vm.putField(out_id, "has_debug_info", Data.new.boolean(true));
        try vm.putField(out_id, "source_name", try vm.ownDataString(info.source_name));
        try vm.putField(out_id, "source", try vm.ownDataString(info.source));
        try vm.putField(out_id, "span_count", Data.new.num(info.spans.len));
    } else {
        try vm.putField(out_id, "has_debug_info", Data.new.boolean(false));
        try vm.putField(out_id, "source_name", Data.new.nil());
        try vm.putField(out_id, "source", Data.new.nil());
        try vm.putField(out_id, "span_count", Data.new.num(0));
    }

    try vm.putField(
        out_id,
        "panic_message",
        if (vm.panic_message) |msg| try vm.ownDataString(msg) else Data.new.nil(),
    );
    try vm.putField(
        out_id,
        "runtime_message",
        if (vm.runtime_message) |msg| try vm.ownDataString(msg) else Data.new.nil(),
    );

    return .data(Data.new.table(out_id));
}

pub fn typeof(d: Data, vm: *VM) []const u8 {
    _ = vm;
    return switch (d.tag()) {
        .atom => if (d.asAtom().? == revo.core_atoms.atomId(.nil)) "nil" else "atom",
        else => |e| @tagName(e),
    };
}

/// > string(arg0: any) -> string
/// converts value to string representation
/// uses __tostring or __display metamethod if available
pub fn string_(args: []const Data, vm: *VM) !HostResult {
    const mm = try vm.getMetamethodByAtom(args[0], revo.core_atoms.__tostring.atomId());
    if (mm) |m| return callUnaryMetamethod(m, args[0], vm);
    var buf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer buf.deinit();
    try args[0].write(&buf.writer, vm, .display);
    const str = try buf.toOwnedSlice();
    return .data(try vm.adoptDataString(str));
}

pub fn try_(args: []const Data, vm: *VM) !HostResult {
    const parts = vm.resultParts(args[0]) orelse return .errType(0, "result", typeof(args[0], vm));
    const atom = parts.tag.asAtom() orelse return .errType(0, "result starting with atom", "result starting with non-atom");
    const ok_id = revo.core_atoms.atomId(.ok);
    if (atom != ok_id) return panic_(&[1]Data{parts.payload orelse Data.new.nil()}, vm);
    return .data(parts.payload orelse Data.new.nil());
}

pub fn unwrap_err_(args: []const Data, vm: *VM) !HostResult {
    const result = args[0];
    const parts = vm.resultParts(result) orelse return .errType(0, "result", typeof(result, vm));

    const tag = parts.tag;
    if (tag.asAtom() == null) return .errType(0, "result starting with atom", "result starting with non-atom");

    const err_tag = revo.core_atoms.atomId(.err);
    if (tag.asAtom().? == err_tag) {
        return .data(parts.payload orelse Data.new.nil());
    }

    return panic_(&[1]Data{revo.Data.new.core(.err)}, vm);
}

fn as_stack_index(value: Data) ?usize {
    const num = value.asNum() orelse return null;
    // SAFETY: asIndex returns null for non-integer/out-of-range numbers
    return revo.asIndex(num) catch null;
}

/// > chan(capacity?: num) -> table
/// creates a new channel with optional buffer size
///     chan()        # unbuffered
///     chan(5)       # buffer of 5
pub fn chan_new(args: []const Data, vm: *VM) !HostResult {
    const cap: usize = if (args.len == 0)
        0
    else if (args.len == 1)
        as_stack_index(args[0]) orelse return .errType(0, "number", typeof(args[0], vm))
    else
        return .errArity(args.len, 0);

    const channel_id = try vm.sched.channelCreate(&vm.tables, cap);
    return .data(try vm.tableOfSlice(&[2]Data{
        Data.new.atom(revo.core_atoms.chan.atomId()),
        Data.new.num(channel_id),
    }));
}

/// validate `args[0]` as a `:chan, id` table and extract the channel id
fn chanIdOf(args: []const Data, vm: *VM) HostResult {
    const table_id = args[0].asTable() orelse return .errType(0, "table", typeof(args[0], vm));
    const t = vm.tables.get(table_id) catch return .errType(0, "chan table", "table");
    if (t.array.items.len < 2) return .errType(0, "chan table", "table");
    const chan_atom = revo.core_atoms.chan.atomId();
    if (t.array.items[0].asAtom() != chan_atom)
        return .errType(0, "chan table", "table");
    const chan_id = t.array.items[1].asNum() orelse return .errType(0, "chan table", "table");
    return .data(Data.new.num(@as(revo.vm.ChannelID, @intFromFloat(chan_id))));
}

/// > send(chan: table, value: any) -> atom
/// sends value to channel
pub fn chan_send(args: []const Data, vm: *VM) !HostResult {
    const cid = switch (chanIdOf(args, vm)) {
        .ok => |d| @as(revo.vm.ChannelID, @intFromFloat(d.asNum().?)),
        else => |r| return r,
    };
    try vm.sched.channelSend(cid, args[1]);
    return HostResult.coreAtom(.ok);
}

/// > recv(chan: table) -> any
/// receives value from channel, parks if empty
pub fn chan_recv(args: []const Data, vm: *VM) !HostResult {
    const cid = switch (chanIdOf(args, vm)) {
        .ok => |d| @as(revo.vm.ChannelID, @intFromFloat(d.asNum().?)),
        else => |r| return r,
    };
    const recv_result = try vm.sched.channelRecv(cid);
    if (recv_result) |value| return .data(value);
    return .parked();
}

/// converts value to number
/// accepts number (passthrough) or string (parsed)
/// errors on other types
pub fn number_(args: []const Data, vm: *VM) !HostResult {
    if (args[0].isNumber()) return HostResult.Ok(vm, args[0]);
    if (args[0].asString()) |id| {
        const parsed = try std.fmt.parseFloat(f64, vm.stringValue(id));
        return HostResult.Ok(vm, Data.new.num(parsed));
    }
    return .errType(0, "num, string", typeof(args[0], vm));
}

/// > assert(what: any) -> what
/// panics if the value is falsy
pub fn assert_(args: []const Data, vm: *VM) !HostResult {
    if (revo.isFalse(args[0])) return panic_(&[1]Data{args[0]}, vm);
    return .data(args[0]);
}

/// > assert(what: any) -> what
/// panics if the value is falsy
pub fn assert_eq(args: []const Data, vm: *VM) !HostResult {
    if (vm.compare(args[0], args[1]) != .eq) {
        var buf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
        defer buf.deinit();
        try buf.writer.writeAll("assert_eq failed: ");
        try append_data(&buf.writer, args[0], vm, .display);
        try buf.writer.writeAll(" (");
        try buf.writer.writeAll(typeof(args[0], vm));
        try buf.writer.writeAll(") != ");
        try append_data(&buf.writer, args[1], vm, .display);
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
pub fn print(args: []const Data, vm: *VM) !HostResult {
    var pbuf: [256]u8 = undefined;
    var pw = revo.stdout().writerStreaming(vm.runtime.io, &pbuf);
    defer _ = pw.flush() catch {};
    if (args.len == 0) {
        _ = try pw.interface.writeAll("\n");
        try pw.flush();
        return HostResult.coreAtom(.ok);
    }
    for (args, 0..) |a, idx| {
        if (idx != 0) _ = try pw.interface.writeAll(" ");
        try append_data(&pw.interface, a, vm, .display);
    }
    try pw.interface.print("\n", .{});
    try pw.flush();
    return .data(revo.Data.new.core(.ok));
}

/// > panic(args: any...) -> error
/// panics with given message
///     panic("something went wrong")
pub fn panic_(args: []const Data, vm: *VM) !HostResult {
    var buf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer buf.deinit();
    if (args.len == 0) {
        try buf.writer.writeAll("panic");
    } else {
        for (args, 0..) |arg, idx| {
            if (idx != 0) try buf.writer.writeAll(" ");
            try append_data(&buf.writer, arg, vm, .display);
        }
    }
    try vm.setPanicMessage(buf.written());
    return .other("panic");
}

pub fn system_(tbl: []const Data, vm: *VM) !HostResult {
    const args = tbl[0].asTable().?;
    const table = try vm.tables.get(args);

    if (table.array.items.len == 0) return HostResult.Err(vm, "EmptyArgs");

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

    try multi_reader.fillRemaining(.none);

    _ = try proc.wait(vm.runtime.io);

    const so = try vm.adoptDataString(try multi_reader.toOwnedSlice(0));
    const se = try vm.adoptDataString(try multi_reader.toOwnedSlice(1));
    const res = try vm.tableOfSlice(&[_]Data{ so, se });
    return .Ok(vm, res);
}

// for some reason leftover buffer persists between input() calls so multiline os reads
// just don't silently drop data after the first delimiter
// no idea if they should be threadlocal
var input_buf: [4096]u8 = undefined;
var input_buf_len: usize = 0;

pub fn input(args: []const Data, vm: *VM) !HostResult {
    var read_eof = false;
    var delim: u8 = '\n';

    if (args.len > 1) return .errArity(args.len, 1);
    if (args.len == 1) {
        const t = args[0].asTable() orelse return .errType(0, "table", typeof(args[0], vm));
        const table = try vm.tables.get(t);

        if (try table.get(Data.new.atom(revo.core_atoms.delimiter.atomId()), vm)) |v| {
            if (v.asAtom()) |atom| {
                const eof_id = revo.core_atoms.eof.atomId();
                if (atom == revo.core_atoms.nil.atomId() or atom == eof_id)
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
    if (input_buf_len > 0 and !read_eof) {
        if (std.mem.indexOfScalar(u8, input_buf[0..input_buf_len], delim)) |di| {
            try result.appendSlice(vm.runtime.alloc, input_buf[0..di]);
            const rest = input_buf[di + 1 .. input_buf_len];
            std.mem.copyForwards(u8, input_buf[0..rest.len], rest);
            input_buf_len = rest.len;
            return HostResult.Ok(vm, try vm.adoptDataString(try result.toOwnedSlice(vm.runtime.alloc)));
        }

        try result.appendSlice(vm.runtime.alloc, input_buf[0..input_buf_len]);
        input_buf_len = 0;
    }

    while (true) {
        const n = file.readStreaming(vm.runtime.io, &.{input_buf[input_buf_len..]}) catch |err| switch (err) {
            error.EndOfStream => {
                if (result.items.len > 0)
                    return HostResult.Ok(vm, try vm.adoptDataString(try result.toOwnedSlice(vm.runtime.alloc)));
                return HostResult.Err(vm, "EndOfStream");
            },
            else => |e| return e,
        };
        const total = input_buf_len + n;
        if (!read_eof) {
            if (std.mem.indexOfScalar(u8, input_buf[0..total], delim)) |di| {
                try result.appendSlice(vm.runtime.alloc, input_buf[0..di]);
                const rest = input_buf[di + 1 .. total];
                std.mem.copyForwards(u8, input_buf[0..rest.len], rest);
                input_buf_len = rest.len;
                return HostResult.Ok(vm, try vm.adoptDataString(try result.toOwnedSlice(vm.runtime.alloc)));
            }
        }
        try result.appendSlice(vm.runtime.alloc, input_buf[0..total]);
        input_buf_len = 0;
    }
}

var gensym_counter: u64 = 0;

test "gensym produces different values on each call" {
    try revo.lang.testing.topAtom(
        \\ const a = gensym()
        \\ const b = gensym()
        \\ a != b
    , "true");
}

pub fn cwd(args: []const Data, vm: *VM) !HostResult {
    _ = args;
    const cwd_path = try std.Io.Dir.cwd().realPathFileAlloc(vm.runtime.io, ".", vm.runtime.alloc);
    defer vm.runtime.alloc.free(cwd_path);
    return .data(try vm.ownDataString(cwd_path));
}

pub fn exit(args: []const Data, vm: *VM) noreturn {
    _ = vm;
    const n = args[0].asNum().?;
    const status: u8 = numToInt(u8, n) orelse 255;
    std.process.exit(status);
}

pub fn getenv_(args: []const Data, vm: *VM) !HostResult {
    const name = args[0].asString() orelse return .errType(0, "string", typeof(args[0], vm));

    const name_s = vm.stringValue(name);
    const name_z = try vm.runtime.alloc.dupeSentinel(u8, name_s, 0);
    defer vm.runtime.alloc.free(name_z);
    // really dont feel like threading environ_map down from main, sorry
    if (std.c.getenv(name_z)) |val| {
        const slice = std.mem.span(val);
        return .data(try vm.ownDataString(slice));
    }
    return .data(Data.new.nil());
}

pub fn setenv_(args: []const Data, vm: *VM) !HostResult {
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
    return .data(Data.new.core(.ok));
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
const libc_setenv = setenv;

pub fn import(args: []const Data, vm: *VM) !HostResult {
    if (args.len != 1) return .errArity(args.len, 1);

    const raw_path = args[0].asString() orelse return .errType(0, "string", typeof(args[0], vm));
    const raw_path_s = vm.stringValue(raw_path);

    const resolved_path = try revo.resolveImportFile(
        vm.runtime.io,
        vm.runtime.alloc,
        raw_path_s,
        vm.module_dir,
        vm.project_root,
        vm.package_path.items,
    ) orelse return .errModuleNotFound();

    defer vm.runtime.alloc.free(resolved_path);
    if (std.mem.endsWith(u8, resolved_path, ".d.rv")) {
        // ambient declaration file: compile-time only, no runtime side effects
        const t_id = try vm.tables.create();
        return .data(Data.new.table(t_id));
    }
    if (std.mem.endsWith(u8, resolved_path, ".so") or std.mem.endsWith(u8, resolved_path, ".dylib")) {
        const can_dlopen = switch (builtin.target.os.tag) {
            .wasi, .freestanding, .windows => false,
            else => true,
        };
        if (!can_dlopen) {
            return .errImportFailed("dynamic library loading not supported on this platform");
        }
        // try native (host function) path first; extensions that export
        // `revo_native_bindings` get full arity/type checking
        if (revo.ffi.loadNative(vm, resolved_path)) |native_mods| {
            defer vm.runtime.alloc.free(native_mods);
            const t_id = try vm.tables.create();
            for (native_mods) |host_fn| {
                const fn_id = try vm.functions.create(.{ .host = host_fn });
                try vm.putField(t_id, host_fn.name, Data.new.function(fn_id));
            }
            return .data(Data.new.table(t_id));
        } else |err| switch (err) {
            error.NoBindings => {},
            else => return .errImportFailed(@errorName(err)),
        }

        const mods = revo.ffi.loadC(vm, resolved_path) catch |err| switch (err) {
            error.NoBindings => return .errImportFailed("extension has no revo_native_bindings or revo_bindings export"),
            else => return .errImportFailed(@errorName(err)),
        };
        defer vm.runtime.alloc.free(mods);
        const t_id = try vm.tables.create();

        for (mods) |c_fn| {
            const fn_id = try vm.functions.create(.{ .c_function = c_fn });
            try vm.putField(t_id, c_fn.name, Data.new.function(fn_id));
        }
        return .data(Data.new.table(t_id));
    }

    const current_stamp = try vm.moduleStamp(resolved_path);
    if (vm.module_cache.get(resolved_path)) |cached| {
        if (std.meta.eql(cached.stamp, current_stamp)) {
            return .data(cached.result);
        }
        _ = vm.invalidateModuleCache(resolved_path);
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
            else => HostResult.errImportFailed(@errorName(err)),
        };
    };
    _ = vm.loading_stack.pop();

    try vm.module_cache.put(cache_key, .{ .result = result, .stamp = current_stamp });
    return .data(result);
}

fn append_data(writer: *std.Io.Writer, val: Data, vm: *VM, mode: Data.RenderMode) !void {
    try val.write(writer, vm, mode);
}

pub fn callUnaryMetamethod(mm: Data, val: Data, vm: *VM) HostResult {
    if (!mm.isFunction()) return .errType(0, "function", typeof(mm, vm));
    const result = vm.callFunctionParts(mm, null, &.{val}, null) catch |err| {
        return .other(@errorName(err));
    };
    return .data(result);
}

pub const HostErrPayload = union(enum) {
    wrong_arity: struct { got: usize, expected: usize },
    type_error: struct { arg: ?usize, expected: []const u8, got: []const u8 },
    host_error: revo.vm.HostError,
    parked: void,
    module_not_found: void,
    cyclic_import: void,
    import_failed: []const u8,
    assertion_failed: []const u8,
    io_error: []const u8,
    other: []const u8,
};

pub const HostResult = union(enum) {
    ok: Data,
    err: HostErrPayload,

    pub fn _bool(b: bool) HostResult {
        return .{ .ok = Data.new.boolean(b) };
    }

    pub fn data(d: Data) HostResult {
        return .{ .ok = d };
    }

    pub fn coreAtom(a: revo.core_atoms) HostResult {
        return .{ .ok = Data.new.atom(@intFromEnum(a)) };
    }

    pub fn Ok(vm: *VM, value: Data) !HostResult {
        return makeResult(vm, .ok, value);
    }

    pub fn Err(vm: *VM, err_name: []const u8) !HostResult {
        const tag = try vm.internAtom(err_name);
        return makeResult(vm, .err, Data.new.atom(tag));
    }

    pub fn errData(vm: *VM, value: Data) !HostResult {
        return makeResult(vm, .err, value);
    }
    // -- [errors] ------------------------------------------------------------
    pub fn errArity(got: usize, expected: usize) HostResult {
        return .{ .err = .{ .wrong_arity = .{ .got = got, .expected = expected } } };
    }

    pub fn errType(arg: usize, expected: []const u8, got: []const u8) HostResult {
        return .{ .err = .{ .type_error = .{ .arg = arg, .expected = expected, .got = got } } };
    }

    pub fn other(message: []const u8) HostResult {
        return .{ .err = .{ .other = message } };
    }

    pub fn panic() HostResult {
        return .{ .err = .{ .other = "panic" } };
    }

    pub fn errModuleNotFound() HostResult {
        return .{ .err = .{ .module_not_found = {} } };
    }

    pub fn errCyclicImport() HostResult {
        return .{ .err = .{ .cyclic_import = {} } };
    }

    pub fn errImportFailed(msg: []const u8) HostResult {
        return .{ .err = .{ .import_failed = msg } };
    }

    pub fn errAssertionFailed(msg: []const u8) HostResult {
        return .{ .err = .{ .assertion_failed = msg } };
    }

    pub fn errIo(msg: []const u8) HostResult {
        return .{ .err = .{ .io_error = msg } };
    }

    // not an error
    pub fn parked() HostResult {
        return .{ .err = .{ .parked = {} } };
    }
};

pub fn wasm_stub(_: []const Data, _: *VM) anyerror!HostResult {
    return .other("function unavailable on this platform");
}

pub fn defineStub(comptime types: []const TypeSpec) HostFunc {
    return .{
        .arity = types.len,
        .variadic = false,
        .param_types = types,
        .func = wasm_stub,
    };
}

pub fn defineStubVariadic(comptime types: []const TypeSpec) HostFunc {
    return .{
        .arity = types.len,
        .variadic = true,
        .param_types = types,
        .func = wasm_stub,
    };
}

// type utils
pub fn typeUtils(vm: *VM) !void {
    inline for (@typeInfo(revo.memory.Type).@"enum".fields) |field| {
        const func = struct {
            fn is_of(args: []const Data, _: *VM) !HostResult {
                for (args) |arg| {
                    if (arg.tag() != @field(revo.memory.Type, field.name)) {
                        return ._bool(false);
                    }
                }
                return ._bool(true);
            }
        }.is_of;
        const id = try vm.functions.create(.{ .host = define(
            &[1]TypeSpec{.any},
            func,
        ) });
        const atom = try vm.internAtom(field.name ++ "?");
        const val = Data.new.function(id);
        try vm.globals.put(atom, val);
        try vm.stdlib_globals.put(atom, val);
    }
    const is_number = struct {
        fn number(args: []const Data, _: *VM) !HostResult {
            for (args) |arg| {
                if (!arg.isNumber()) return ._bool(false);
            }
            return ._bool(true);
        }
    }.number;
    const id = try vm.functions.create(.{ .host = define(&[_]TypeSpec{.any}, is_number) });
    const atom = try vm.internAtom("num?");
    const val = Data.new.function(id);
    try vm.globals.put(atom, val);
    try vm.stdlib_globals.put(atom, val);
}

test "type predicates" {
    try testing.topTrue("num?(42)");
    try testing.topTrue("string?(\"hello\")");
    try testing.topTrue("table?({})");
    try testing.topTrue("atom?(:ok)");
    try testing.topTrue("function?(fn() 42)");
}

test "debug() links its nested flags table without a stale pointer" {
    // debug() creates the `out` table, then creates a second `flags` table.
    // the second create can reallocate the table pool, so `out` must be
    // fetched after it. these checks fail (or trip the allocator) if `out`
    // is written through a dangling pointer.
    try testing.topTrue("table?(debug().flags)");
    try testing.topFalse("debug().flags.dump");
    try testing.topTrue("num?(debug().stack_depth)");
}

test "array sort" {
    try testing.topNumber("{3, 1, 2}:sort():first()", 1);
    try testing.topNumber("{3, 1, 2}:sort():last()", 3);
    try testing.topNumber("{1, 5, 3}:sort_by(fn(a, b) a > b):first()", 5);
}

test "array transform" {
    try testing.topNumber("{1, 2, 3}:reverse():first()", 3);
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

test "stdlib json time and string modules are exposed" {
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
    try testing.topTrue("assert(type(len) == :function)");
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
//
// module wrappers
//

/// for use in impl fn signatures: `fn foo(vm: *VM, self: Ts.string) !HostResult`
/// made nominal
pub const T = struct {
    pub const string = enum(mem.StringID) { _ };
    pub const number = f64;
    pub const atom = enum(mem.AtomID) { _ };
    pub const function = enum(mem.FunctionID) { _ };
    pub const table = enum(mem.TableID) { _ };
    pub const any = Data;

    /// usage: `T.Optional(.bool, false)`, `T.Optional(.number, 10.0)`
    pub fn Optional(comptime spec: TypeSpec, comptime default_val: anytype) type {
        const VT = switch (spec) {
            .bool => bool,
            else => specToType(spec),
        };
        return extern struct {
            pub const inner_spec = spec;
            pub const default_value: VT = default_val;
            value: VT,
        };
    }
};

/// reverse mapping
/// distinct T type -> TypeSpec variant
pub fn typeToSpec(comptime P: type) TypeSpec {
    if (isOptional(P)) return P.inner_spec; // unwrap Optional
    if (P == T.string) return .string;
    if (P == T.number) return .number;
    if (P == T.atom) return .atom;
    if (P == T.function) return .function;
    if (P == T.table) return .table;
    if (P == bool) return .bool;
    if (P == Data) return .any;
    @compileError("unsupported type in def: " ++ @typeName(P));
}

/// unwrap one Data arg into the typed value the impl fn expects
pub fn unwrapArg(comptime spec: TypeSpec, data: Data) specToType(spec) {
    return switch (spec) {
        .number => data.asNum().?,
        .string => @enumFromInt(data.asString().?),
        .atom => @enumFromInt(data.asAtom().?),
        .function => @enumFromInt(data.asFunction().?),
        .table => @enumFromInt(data.asTable().?),
        .bool => data.asAtom().? == revo.core_atoms.atomId(.true),
        .any => data,
    };
}

/// inspects fn signature at comptime, derives TypeSpec array, generates unwrapping wrapper
pub fn def(comptime impl: anytype) HostFunc {
    const fn_info = @typeInfo(@TypeOf(impl)).@"fn";
    comptime {
        if (fn_info.params.len < 1) @compileError("def requires (vm, ...) signature");
        if (fn_info.params[0].type.? != *VM) @compileError("first param must be *VM");
    }
    const count = fn_info.params.len - 1;
    const Storage = struct {
        pub const specs: [count]TypeSpec = blk: {
            var result: [count]TypeSpec = undefined;
            for (fn_info.params[1..], 0..) |param, i| {
                result[i] = typeToSpec(param.type.?);
            }
            break :blk result;
        };
        pub const required_count: usize = blk: {
            var n: usize = 0;
            for (fn_info.params[1..]) |param| {
                if (!isOptional(param.type.?)) n += 1;
            }
            break :blk n;
        };
        pub const all_types: [count + 1]type = blk: {
            var result: [count + 1]type = undefined;
            result[0] = *VM;
            for (fn_info.params[1..], 0..) |param, i| {
                result[i + 1] = param.type.?;
            }
            break :blk result;
        };
        pub const FullArgs = std.meta.Tuple(&all_types);
    };

    const has_optionals = Storage.required_count < count;
    return .{
        .arity = Storage.required_count,
        .total_arity = if (has_optionals) count else 0,
        .param_types = &Storage.specs,
        .func = struct {
            fn call(raw: []const Data, vm: *VM) anyerror!HostResult {
                var args: Storage.FullArgs = undefined;
                args[0] = vm;
                inline for (Storage.specs, 0..) |spec, i| {
                    const P = fn_info.params[i + 1].type.?;
                    if (i < raw.len) {
                        const val = unwrapArg(spec, raw[i]);
                        args[i + 1] = if (comptime isOptional(P)) .{ .value = val } else val;
                    } else {
                        if (comptime isOptional(P)) {
                            args[i + 1] = getDefault(i, vm) catch |e| return e;
                        } else {
                            unreachable;
                        }
                    }
                }
                return @call(.auto, impl, args);
            }
            fn getDefault(comptime i: usize, vm: *VM) !fn_info.params[i + 1].type.? {
                const OptionalType = fn_info.params[i + 1].type.?;
                const default = OptionalType.default_value;
                const spec = Storage.specs[i];
                const inner = switch (spec) {
                    .string => @as(T.string, @enumFromInt(try vm.strings.own(default))),
                    else => default,
                };
                return .{ .value = inner };
            }
        }.call,
    };
}

fn isOptional(comptime P: type) bool {
    return switch (@typeInfo(P)) {
        // it's fine
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(P, "inner_spec"),
        else => false,
    };
}

fn countFn(comptime S: type) comptime_int {
    comptime {
        var c: usize = 0;
        for (@typeInfo(S).@"struct".decls) |decl| {
            if (@typeInfo(@TypeOf(@field(S, decl.name))) == .@"fn") c += 1;
        }
        return c;
    }
}

/// generic struct -> impls array
/// iterates pub fn decls in the struct,
/// derives TypeSpecs from each fn's parameter types, wraps with def()
///
/// the registered name is the full decl name, so `@"fs.stat"` pairs
/// with the `fs.stat` spec by head instead of by position
pub fn impls(comptime ImplType: type) type {
    const decls = @typeInfo(ImplType).@"struct".decls;
    const count = countFn(ImplType);
    return struct {
        pub const impls_list: [count]api.Impl = blk: {
            var result: [count]api.Impl = undefined;
            var i: usize = 0;
            for (decls) |decl| {
                const f = @field(ImplType, decl.name);
                if (@typeInfo(@TypeOf(f)) == .@"fn") {
                    result[i] = .{ .name = decl.name, .f = def(f) };
                    i += 1;
                }
            }
            break :blk result;
        };
        pub const val: *const [count]api.Impl = &impls_list;
    };
}
