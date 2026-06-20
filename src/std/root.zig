const std = @import("std");

const revo = @import("../root.zig");
const mem = revo.memory;
const vm_path = revo.path_utils;
const meta = @import("meta.zig");

const Data = mem.Data;
const VM = revo.VM;
const testing = revo.lang.testing;

pub const api = @import("api.zig");

pub const root_specs: []const api.FnSpec = &.{
    .{
        .name = "fmt",
        .placements = &.{api.g},
        .params = &.{
            .{ "format", "string" },
            .{ "args", "any..." },
        },
        .ret = "string",
        .doc = "format string with %v, %d, %? specifiers",
        .variadic = true,
        .f = defineVariadic(&[_]TypeSpec{.string}, fmt),
    },
    .{
        .name = "len",
        .placements = &.{api.g},
        .params = &.{
            .{ "value", "any" },
        },
        .ret = "number|:nil",
        .doc = "returns length of string or table",
        .f = define(&[_]TypeSpec{.any}, len_),
    },
    .{
        .name = "inspect",
        .placements = &.{api.g},
        .params = &.{
            .{ "value", "any" },
        },
        .ret = "any",
        .doc = "prints one value and returns it back",
        .f = define(&[_]TypeSpec{.any}, inspect),
    },
    .{
        .name = "get_metatable",
        .placements = &.{api.g},
        .params = &.{
            .{ "value", "any" },
        },
        .ret = "table|atom",
        .doc = "returns metatable of value or :missing",
        .f = define(&[_]TypeSpec{.any}, meta.get_metatable_),
    },
    .{
        .name = "set_metatable",
        .placements = &.{api.g},
        .params = &.{
            .{ "value", "any" },
            .{ "meta", "table|:nil" },
        },
        .ret = "any",
        .doc = "sets metatable of value",
        .f = define(&[_]TypeSpec{ .any, .any }, meta.set_metatable_),
    },
    .{
        .name = "type",
        .placements = &.{api.g},
        .params = &.{
            .{ "value", "any" },
        },
        .ret = "atom",
        .doc = "returns type of value as atom",
        .f = define(&[_]TypeSpec{.any}, typeof_),
    },
    .{
        .name = "typeof",
        .placements = &.{api.g},
        .params = &.{
            .{ "value", "any" },
        },
        .ret = "atom",
        .doc = "returns type of value as atom",
        .f = define(&[_]TypeSpec{.any}, typeof_),
    },
    .{
        .name = "tostring",
        .placements = &.{api.g},
        .params = &.{
            .{ "value", "any" },
        },
        .ret = "string",
        .doc = "converts value to string",
        .f = define(&[_]TypeSpec{.any}, tostring),
    },
    .{
        .name = "tonumber",
        .placements = &.{api.g},
        .params = &.{
            .{ "value", "string" },
        },
        .ret = "(:ok, number) | (:err, string)",
        .doc = "converts string to number",
        .f = define(&[_]TypeSpec{.any}, tonumber),
    },
    .{
        .name = "expect",
        .placements = &.{api.g},
        .params = &.{
            .{ "value", "any" },
        },
        .ret = "(:ok, any) | (:err, :ExpectFailed)",
        .doc = "used in tests, returns value or :err",
        .f = define(&[_]TypeSpec{.any}, expect),
    },
    .{
        .name = "expect_eq",
        .placements = &.{api.g},
        .params = &.{
            .{ "a", "any" },
            .{ "b", "any" },
        },
        .ret = "(:ok, any) | (:err, :NotEqual)",
        .doc = "panics if values are not equal",
        .f = define(&[_]TypeSpec{ .any, .any }, expect_eq),
    },
    .{
        .name = "assert",
        .placements = &.{api.g},
        .params = &.{
            .{ "value", "any" },
        },
        .ret = "any",
        .doc = "panics if value is falsy",
        .f = define(&[_]TypeSpec{.any}, assert_),
    },
    .{
        .name = "assert_eq",
        .placements = &.{api.g},
        .params = &.{
            .{ "a", "any" },
            .{ "b", "any" },
        },
        .ret = "any",
        .doc = "panics if values are not equal",
        .f = define(&[_]TypeSpec{ .any, .any }, assert_eq),
    },
    .{
        .name = "set_debug",
        .placements = &.{api.g},
        .params = &.{
            .{ "flags", "table" },
        },
        .ret = ":ok",
        .doc = "sets debug flags from a table",
        .f = define(&[_]TypeSpec{.table}, meta.set_debug),
    },
    .{ .name = "debug", .placements = &.{api.g}, .params = &.{}, .ret = "table", .doc = "returns debug info as a table", .f = define(&[_]TypeSpec{}, debug_) },
    .{
        .name = "@range",
        .placements = &.{api.g},
        .params = &.{
            .{ "start", "number" },
            .{ "step", "number" },
            .{ "stop", "number" },
        },
        .ret = "tuple",
        .doc = "creates a range tuple (start, step, stop)",
        .f = define(&[_]TypeSpec{ .number, .number, .number }, range_),
    },
    .{
        .name = "@range_from",
        .placements = &.{api.g},
        .params = &.{
            .{ "start", "number" },
            .{ "step", "number" },
        },
        .ret = "tuple",
        .doc = "creates a range tuple (start, step) without stop",
        .f = define(&[_]TypeSpec{ .number, .number }, range_from_),
    },
    .{
        .name = "unwrap",
        .placements = &.{api.g},
        .params = &.{
            .{ "result", "tuple" },
        },
        .ret = "any",
        .doc = "unwraps result tuple, panics if not :ok",
        .f = define(&[_]TypeSpec{.tuple}, try_),
    },
    .{
        .name = "@dotest",
        .placements = &.{api.g},
        .params = &.{
            .{ "name", "string" },
            .{ "body", "function" },
        },
        .ret = ":ok",
        .doc = "internal, do not use unless you know what you're doing. runs a test",
        .f = define(&[_]TypeSpec{ .string, .function }, dotest),
    },
    .{
        .name = "@dosuite",
        .placements = &.{api.g},
        .params = &.{
            .{ "name", "string" },
            .{ "body", "function" },
        },
        .ret = ":ok",
        .doc = "internal, pls dont use. runs a test suite",
        .f = define(&[_]TypeSpec{ .string, .function }, dosuite),
    },
    .{
        .name = "chan",
        .placements = &.{api.g},
        .params = &.{
            .{ "capacity", "number?" },
        },
        .ret = "tuple",
        .doc = "creates a new channel with optional buffer size",
        .variadic = true,
        .f = defineVariadic(&[_]TypeSpec{}, chan_new),
    },
    .{
        .name = "send",
        .placements = &.{api.g},
        .params = &.{
            .{ "chan", "tuple" },
            .{ "value", "any" },
        },
        .ret = ":ok",
        .doc = "sends value to channel",
        .f = define(&[_]TypeSpec{ .tuple, .any }, chan_send),
    },
    .{
        .name = "recv",
        .placements = &.{api.g},
        .params = &.{
            .{ "chan", "tuple" },
        },
        .ret = "any",
        .doc = "receives value from channel, parks if empty",
        .f = define(&[_]TypeSpec{.tuple}, chan_recv),
    },
    .{
        .name = "sleep",
        .placements = &.{api.g},
        .params = &.{
            .{ "ms", "number" },
        },
        .ret = "parked",
        .doc = "sleeps current fiber for given milliseconds",
        .f = define(&[_]TypeSpec{.number}, sleep),
    },
    .{
        .name = "print",
        .placements = &.{api.g},
        .params = &.{
            .{ "args", "any..." },
        },
        .ret = ":ok",
        .doc = "prints values to stdout with space separator",
        .variadic = true,
        .f = defineVariadic(&[_]TypeSpec{}, print),
    },
    .{
        .name = "panic",
        .placements = &.{api.g},
        .params = &.{
            .{ "args", "any..." },
        },
        .ret = "never",
        .doc = "panics with given message",
        .variadic = true,
        .f = defineVariadic(&[_]TypeSpec{}, panic_),
    },
    .{
        .name = "c_use",
        .placements = &.{api.g},
        .params = &.{
            .{ "path", "string" },
        },
        .ret = ":nil",
        .doc = "loads a C extension lib and registers its functions",
        .f = define(&[_]TypeSpec{.string}, cload),
    },
    .{
        .name = "read",
        .placements = &.{api.g},
        .params = &.{
            .{ "opts", "table?" },
        },
        .ret = "(:ok, string) | (:err, string)",
        .doc =
        \\ reads from stdin or a path 
        \\ opts:
        \\  - delimiter: string, :eof or nothing
        \\  - path:      string or nothing
        ,
        .variadic = true,
        .f = defineVariadic(&[_]TypeSpec{}, read),
    },
    .{
        .name = "cwd",
        .placements = &.{api.g},
        .params = &.{},
        .ret = "string",
        .doc = "returns current working directory path",
        .f = define(&[_]TypeSpec{}, cwd),
    },
    .{
        .name = "gensym",
        .placements = &.{api.g},
        .params = &.{},
        .ret = "string",
        .doc =
        \\ returns a unique interned string for use as an identifier
        \\
        \\   # in a proc macro: generate a fresh identifier to avoid name capture
        \\   proc swap!(iter) do
        \\     let tmp = gensym()
        \\     let a = iter:next()
        \\     let b = iter:next()
        \\     `((do
        \\         let %tmp = %a
        \\         %a = %b
        \\         %b = %tmp
        \\       end))
        \\   end
        \\
        \\   let x = 1
        \\   let y = 2
        \\   swap!(x, y)
        ,
        .f = define(&[_]TypeSpec{}, gensym),
    },
    .{
        .name = "system",
        .placements = &.{api.g},
        .params = &.{
            .{ "args", "table" },
        },
        .ret = "(:stdout, :stderr)",
        .doc = "runs a subprocess and returns (stdout, stderr)",
        .f = define(&[_]TypeSpec{.table}, system_),
    },
    .{
        .name = "import",
        .placements = &.{api.g},
        .params = &.{
            .{ "path", "string" },
        },
        .ret = "any",
        .doc = "imports a revo module by path",
        .f = define(&[_]TypeSpec{.string}, import),
    },
};

pub fn register_stdlib(vm: *revo.VM) !void {
    const argv_id = try vm.tables.create();
    const argv = try vm.tables.get(argv_id);
    for (vm.runtime.argv) |arg| {
        try argv.push(try vm.ownDataString(arg));
    }
    const argv_val = Data.new.table(argv_id);
    try vm.globals.put(try vm.internAtom("argv"), argv_val);
    try vm.stdlib_globals.put(try vm.internAtom("argv"), argv_val);

    // later specs merge into earlier metatables, not overwrite
    const all = [_][]const api.FnSpec{
        root_specs,
        @import("string.zig").specs,
        @import("table.zig").specs,
        @import("tuple.zig").specs,
        @import("iter.zig").specs,
        @import("math.zig").specs,
        @import("json.zig").specs,
        @import("time.zig").specs,
        @import("net.zig").specs,
        @import("fs.zig").specs,
        @import("revo.zig").specs,
    };
    try api.registerAll(vm, &all, mtPrototype);

    try attachMathPi(vm);
    try typeUtils(vm);
}

fn attachMathPi(vm: *revo.VM) !void {
    if (vm.globals.get(try vm.internAtom("math"))) |t| {
        if (t.asTable()) |table_id| {
            const table = try vm.tables.get(table_id);
            try table.putRawAtom(try vm.internAtom("pi"), Data.new.num(std.math.pi));
        }
    }
}

fn mtPrototype(target: TypeSpec, vm: *revo.VM) !Data {
    return switch (target) {
        .string => try vm.ownDataString(""),
        .tuple => Data.new.tuple(std.math.maxInt(usize)),
        .table => Data.new.table(std.math.maxInt(usize)),
        else => return error.UnsupportedTarget,
    };
}

pub const NativeFn = *const fn (args: []const Data, vm: *VM) anyerror!NativeResult;
pub const NativeFunc = struct {
    name: []const u8 = "",
    arity: usize,
    variadic: bool = false,
    param_types: []const TypeSpec,
    ret_type: TypeSpec = .any,
    func: NativeFn,
};

pub fn define(
    comptime types: []const TypeSpec,
    impl: NativeFn,
) NativeFunc {
    return .{
        .arity = types.len,
        .param_types = types,
        .func = impl,
    };
}

pub fn defineVariadic(
    comptime types: []const TypeSpec,
    impl: NativeFn,
) NativeFunc {
    return .{
        .arity = types.len,
        .variadic = true,
        .param_types = types,
        .func = impl,
    };
}

pub const ResultTag = enum { ok, err };

pub const TypeSpec = union(enum) {
    integer,
    float,
    number,
    string,
    atom,
    function,
    table,
    tuple,
    bool,
    any,

    pub fn matches(self: TypeSpec, data: Data) bool {
        return switch (self) {
            .any => true,
            .number, .integer, .float => data.isNumber(),
            .bool => if (data.asAtom()) |a| isBoolAtom(a) else false,
            .string => data.isString(),
            .atom => data.isAtom(),
            .function => data.isFunction(),
            .table => data.isTable(),
            .tuple => data.isTuple(),
        };
    }
};

fn isBoolAtom(atom: mem.AtomID) bool {
    const true_id = revo.core_atoms.atom_id(.true);
    const false_id = revo.core_atoms.atom_id(.false);
    return atom == true_id or atom == false_id;
}

pub fn dataToString(data: Data) []const u8 {
    return typeof(data);
}

pub fn resultTuple(vm: *VM, comptime tag: ResultTag, value: Data) !NativeResult {
    const tag_atom = try resultTag(vm, tag);
    const items = [_]Data{
        Data.new.atom(tag_atom),
        value,
    };
    return .okData(Data.new.tuple(try vm.tuples.create(&items)));
}

pub fn okAtom(vm: *VM) NativeResult {
    _ = vm;
    return .{ .ok = revo.core_atoms.data(.ok) };
}

pub fn resultTag(vm: *VM, comptime tag: ResultTag) !mem.AtomID {
    _ = vm;
    return switch (tag) {
        .ok => revo.core_atoms.atom_id(.ok),
        .err => revo.core_atoms.atom_id(.err),
    };
}

pub inline fn boolData(value: bool) Data {
    return if (value) revo.core_atoms.true.data() else revo.core_atoms.false.data();
}

pub fn tupleTag(value: Data, vm: *VM) ?mem.AtomID {
    const id = value.asTuple() orelse return null;
    const tuple = vm.tuples.get(id) catch return null;
    if (tuple.items.len == 0) return null;
    return tuple.items[0].asAtom();
}

/// > fmt(format: string, args: any...) -> string
/// format string with %v, %d, %? specifiers
/// %v: display value, %d: as number, %?: debug repr
///     fmt("hello %v", "world")
///     fmt("val: %v, num: %d", "x", 42)
pub fn fmt(args: []const Data, vm: *VM) !NativeResult {
    if (args.len == 0) return .errArity(0, 1);
    const format = vm.stringValue(args[0].asString().?);

    var result = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer result.deinit();

    var arg_idx: usize = 1;
    var i: usize = 0;

    while (i < format.len) {
        if (i + 1 < format.len and format[i] == '%') {
            switch (format[i + 1]) {
                'v' => {
                    if (arg_idx >= args.len) return .errArity(args.len, arg_idx + 1);
                    try append_data(&result.writer, args[arg_idx], vm, .display);
                    arg_idx += 1;
                    i += 2;
                },
                's' => {
                    if (arg_idx >= args.len) return .errArity(args.len, arg_idx + 1);
                    try append_data(&result.writer, args[arg_idx], vm, .display);
                    arg_idx += 1;
                    i += 2;
                },
                'd' => {
                    if (arg_idx >= args.len) return .errArity(args.len, arg_idx + 1);
                    const v = if (args[arg_idx].isNumber())
                        args[arg_idx]
                    else if (args[arg_idx].asString()) |id|
                        Data.new.num(try std.fmt.parseFloat(f64, vm.stringValue(id)))
                    else if (args[arg_idx].isAtom())
                        try vm.ownDataString("<un-tonumber-able>")
                    else
                        Data.new.num(0);
                    try append_data(&result.writer, v, vm, .display);
                    arg_idx += 1;
                    i += 2;
                },
                '?' => {
                    if (arg_idx >= args.len) return .errArity(args.len, arg_idx + 1);
                    try append_data(&result.writer, args[arg_idx], vm, .debug);
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
    return .{ .ok = try vm.adoptDataString(str) };
}

test "fmt %d formats numbers" {
    try testing.top_string(
        \\ fmt("%d", 42)
    , "42");
    try testing.top_string(
        \\ fmt("%d", 1.5)
    , "1.5");
    try testing.top_string(
        \\ fmt("%d", "10.5")
    , "10.5");
    try testing.top_string(
        \\ fmt("%d", :hello)
    , "<un-tonumber-able>");
}

test "fmt %? uses debug rendering" {
    try testing.top_string(
        \\ const mt = {__debug = fn(self) "custom-debug"}
        \\ const t = set_metatable({}, mt)
        \\ fmt("%?", t)
    , "custom-debug");
}

/// internal, do not use pls
pub fn dotest(args: []const Data, vm: *VM) !NativeResult {
    const name = args[0].asString().?;
    const body = args[1].asFunction().?;
    var buf: [128]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(vm.runtime.io, &buf);
    defer w.flush() catch {};

    w.interface.print("* test \"{s}\"...\n", .{try vm.strings.get(name)}) catch {};
    w.flush() catch {};
    const res = vm.callFunction(Data.new.function(body), &[0]Data{}) catch |err| {
        const failure = vm.evalFailure(err);
        failure.render(vm.runtime.alloc, &w.interface, vm.currentDebugSource() orelse "") catch {
            try revo.pretty.printError(
                vm.runtime.alloc,
                &w.interface,
                "hard-fail - {s}",
                .{@errorName(err)},
            );
            return .{ .ok = Data.new.nil() };
        };
        return .{ .ok = Data.new.nil() };
    };
    // only react to err tuple
    // everything else is pass
    if (res.asTuple()) |tid| {
        const tpl = try vm.tuples.get(tid);
        if (tpl.items.len != 2)
            return .{ .ok = Data.new.nil() };
        const tag = tpl.items[0].asAtom() orelse return .{ .ok = Data.new.nil() };
        if (tag != revo.core_atoms.atom_id(.err))
            return .{ .ok = Data.new.nil() };

        var obuf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
        defer obuf.deinit();
        try append_data(&obuf.writer, tpl.items[1], vm, .debug);

        try revo.pretty.printError(
            vm.runtime.alloc,
            &w.interface,
            "fail - {s}",
            .{obuf.written()},
        );
    }
    return .{ .ok = Data.new.nil() };
}

/// internal, pls dont use. runs a test suite
pub fn dosuite(args: []const Data, vm: *VM) !NativeResult {
    const body = args[1].asFunction().?;
    var sbuf: [128]u8 = undefined;
    var sw = std.Io.File.stdout().writerStreaming(vm.runtime.io, &sbuf);
    defer sw.flush() catch {};
    _ = vm.callFunction(Data.new.function(body), &[0]Data{}) catch |err| {
        const failure = vm.evalFailure(err);
        var buf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
        defer buf.deinit();
        failure.render(vm.runtime.alloc, &buf.writer, vm.currentDebugSource() orelse "") catch {
            sw.interface.print("* suite hard-failed: \"{s}\"\n", .{@errorName(err)}) catch {};
            return .okCa(.nil);
        };
        sw.interface.print("{s}\n", .{buf.written()}) catch {};
    };

    return .okCa(.nil);
}

pub fn debug_(args: []const Data, vm: *VM) !NativeResult {
    _ = args;

    const out_id = try vm.tables.create();
    const out = try vm.tables.get(out_id);

    const flags_id = try vm.tables.create();
    const flags = try vm.tables.get(flags_id);
    try flags.putRawAtom(try vm.internAtom("dump"), Data.new.boolean(vm.debug.dump));
    try flags.putRawAtom(try vm.internAtom("trace"), Data.new.boolean(vm.debug.trace));
    try flags.putRawAtom(try vm.internAtom("instr"), Data.new.boolean(vm.debug.each_instr));
    try flags.putRawAtom(try vm.internAtom("stack"), Data.new.boolean(vm.debug.each_stack));
    try out.putRawAtom(try vm.internAtom("flags"), Data.new.table(flags_id));

    const fiber = vm.currentFiber();
    try out.putRawAtom(try vm.internAtom("fiber_id"), Data.new.num(fiber.id));
    try out.putRawAtom(try vm.internAtom("pc"), Data.new.num(fiber.pc));
    try out.putRawAtom(try vm.internAtom("stack_depth"), Data.new.num(fiber.registers_len));
    try out.putRawAtom(try vm.internAtom("frame_depth"), Data.new.num(fiber.frames_hot.items.len));
    try out.putRawAtom(try vm.internAtom("program_len"), Data.new.num(fiber.program.len));

    if (vm.currentDebugInfo()) |info| {
        try out.putRawAtom(try vm.internAtom("has_debug_info"), Data.new.boolean(true));
        try out.putRawAtom(try vm.internAtom("source_name"), try vm.ownDataString(info.source_name));
        try out.putRawAtom(try vm.internAtom("source"), try vm.ownDataString(info.source));
        try out.putRawAtom(try vm.internAtom("span_count"), Data.new.num(info.spans.len));
    } else {
        try out.putRawAtom(try vm.internAtom("has_debug_info"), Data.new.boolean(false));
        try out.putRawAtom(try vm.internAtom("source_name"), Data.new.nil());
        try out.putRawAtom(try vm.internAtom("source"), Data.new.nil());
        try out.putRawAtom(try vm.internAtom("span_count"), Data.new.num(0));
    }

    try out.putRaw(
        Data.new.atom(try vm.internAtom("panic_message")),
        if (vm.panic_message) |msg| try vm.ownDataString(msg) else Data.new.nil(),
    );
    try out.putRaw(
        Data.new.atom(try vm.internAtom("runtime_message")),
        if (vm.runtime_message) |msg| try vm.ownDataString(msg) else Data.new.nil(),
    );

    return .okData(Data.new.table(out_id));
}

/// > len(arg0: any) -> number|nil
/// returns length of string or table
/// for strings: byte length, for tables: array part length
pub fn len_(args: []const Data, vm: *VM) !NativeResult {
    return switch (args[0].tag()) {
        .string => .okData(Data.new.num(vm.stringValue(args[0].asString().?).len)),
        .table => .okData(Data.new.num((try vm.tables.get(args[0].asTable().?)).array.items.len)),
        .tuple => .okData(Data.new.num((try vm.tuples.get(args[0].asTuple().?)).items.len)),
        else => .errType(1, "string, table, or tuple", typeof(args[0])),
    };
}

/// > inspect(any) -> any
/// prints one value and returns it back
pub fn inspect(args: []const Data, vm: *VM) !NativeResult {
    _ = try print(args, vm);
    return .okData(args[0]);
}

pub fn typeof(d: Data) []const u8 {
    return switch (d.tag()) {
        .atom => if (d.asAtom().? == revo.core_atoms.atom_id(.nil)) "nil" else "atom",
        .number => "number",
        .string => "string",
        .function => "function",
        .table => "table",
        .tuple => "tuple",
        .struct_val => "struct",
        .struct_type => "type",
    };
}

/// > typeof(arg0: any) -> string
/// returns type of arg0 as string
/// possible values: nil, number, string, atom, function, table, tuple
pub fn typeof_(args: []const Data, vm: *VM) !NativeResult {
    return .okData(Data.new.atom(try vm.internAtom(typeof(args[0]))));
}

/// > tostring(arg0: any) -> string
/// converts value to string representation
/// uses __tostring or __display metamethod if available
pub fn tostring(args: []const Data, vm: *VM) !NativeResult {
    const mm = try vm.getMetamethod(args[0], "__tostring");
    if (mm) |m| return callUnaryMetamethod(m, args[0], vm);
    var buf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer buf.deinit();
    try args[0].write(&buf.writer, vm, .display);
    const str = try buf.toOwnedSlice();
    return .{ .ok = try vm.adoptDataString(str) };
}

/// > @range_from(start: number, step: number) -> tuple
/// creates a range tuple (start, step) without stop
fn range_from_(args: []const Data, vm: *VM) !NativeResult {
    const start = expect_number(args[0]) orelse return .errType(0, "number", dataToString(args[0]));
    const step = expect_number(args[1]) orelse return .errType(1, "number", dataToString(args[1]));
    const tag = try vm.internAtom("range_from");
    const id = try vm.tuples.create(&.{ Data.new.atom(tag), Data.new.num(start), Data.new.num(step) });
    return .okData(Data.new.tuple(id));
}

/// > unwrap(result: tuple) -> any
/// unwraps result tuple, panics if not :ok
pub fn try_(args: []const Data, vm: *VM) !NativeResult {
    const t_id = args[0].asTuple() orelse return .errType(0, "tuple", dataToString(args[0]));
    const tuple = try vm.tuples.get(t_id);
    if (tuple.len() < 2) return .errType(0, "tuple with at least 2 elements", "tuple with less than 2 elements");
    const tag = tuple.items[0];
    const atom = tag.asAtom() orelse return .errType(0, "tuple starting with atom", "tuple starting with non-atom");
    const ok_id = revo.core_atoms.atom_id(.ok);
    if (atom != ok_id) return panic_(&[1]Data{tuple.items[1]}, vm);
    return .{ .ok = tuple.items[1] };
}

/// > tuple:unwrap_err() -> any
/// extracts error from result tuple, panics if not :err
pub fn unwrap_err_(args: []const Data, vm: *VM) !NativeResult {
    const result = args[0];
    const result_tid = result.asTuple() orelse return .errType(0, "tuple", dataToString(result));
    const tuple = try vm.tuples.get(result_tid);
    if (tuple.items.len < 2) return .errType(0, "tuple with at least 2 elements", "empty tuple");

    const tag = tuple.items[0];
    if (tag.asAtom() == null) return .errType(0, "tuple starting with atom", "tuple starting with non-atom");

    const err_tag = revo.core_atoms.atom_id(.err);
    if (tag.asAtom().? == err_tag) {
        return .{ .ok = tuple.items[1] };
    }

    return panic_(&[1]Data{revo.core_atoms.data(.err)}, vm);
}

/// > @range(start: number, step: number, stop: number) -> tuple
/// creates a range tuple (start, step, stop)
pub fn range_(args: []const Data, vm: *VM) !NativeResult {
    const start = expect_number(args[0]) orelse return .errType(0, "number", dataToString(args[0]));
    const step = expect_number(args[1]) orelse return .errType(1, "number", dataToString(args[1]));
    const stop = expect_number(args[2]) orelse return .errType(2, "number", dataToString(args[2]));
    const tag = revo.core_atoms.atom_id(.range);
    const id = try vm.tuples.create(&.{ Data.new.atom(tag), Data.new.num(start), Data.new.num(step), Data.new.num(stop) });
    return .okData(Data.new.tuple(id));
}

fn expect_number(data: Data) ?f64 {
    return data.asNum();
}

fn as_stack_index(value: Data) ?usize {
    const num = value.asNum() orelse return null;
    // SAFETY: asIndex returns null for non-integer/out-of-range numbers
    return revo.asIndex(num) catch null;
}

/// > chan(capacity?: number) -> tuple
/// creates a new channel with optional buffer size
///     chan()        # unbuffered
///     chan(5)       # buffer of 5
pub fn chan_new(args: []const Data, vm: *VM) !NativeResult {
    const cap: usize = if (args.len == 0)
        0
    else if (args.len == 1)
        as_stack_index(args[0]) orelse return .errType(0, "number", dataToString(args[0]))
    else
        return .errArity(args.len, 0);

    const channel_id = try vm.sched.channelCreate(&vm.tables, cap);
    const res = try vm.tuples.create(&[2]Data{
        Data.new.atom(revo.core_atoms.chan.atom_id()),
        Data.new.num(channel_id),
    });
    return .okData(Data.new.tuple(res));
}

/// > send(chan: tuple, value: any) -> atom
/// sends value to channel
pub fn chan_send(args: []const Data, vm: *VM) !NativeResult {
    const tuple_id = args[0].asTuple() orelse return .errType(0, "tuple", dataToString(args[0]));
    const t = try vm.tuples.get(tuple_id);
    if (t.items.len < 2) return .errType(0, "chan tuple", "tuple");
    const chan_atom = revo.core_atoms.chan.atom_id();
    if (t.items[0].asAtom() != chan_atom)
        return .errType(0, "chan tuple", "tuple");
    const chan_id = t.items[1].asNum() orelse return .errType(0, "chan tuple", "tuple");
    const cid: revo.vm.ChannelID = @intFromFloat(chan_id);
    try vm.sched.channelSend(cid, args[1]);
    return okAtom(vm);
}

/// > recv(chan: tuple) -> any
/// receives value from channel, parks if empty
pub fn chan_recv(args: []const Data, vm: *VM) !NativeResult {
    const tuple_id = args[0].asTuple() orelse return .errType(0, "tuple", dataToString(args[0]));
    const t = try vm.tuples.get(tuple_id);
    if (t.items.len < 2) return .errType(0, "chan tuple", "tuple");
    const chan_atom = revo.core_atoms.chan.atom_id();
    if (t.items[0].asAtom() != chan_atom)
        return .errType(0, "chan tuple", "tuple");
    const chan_id = t.items[1].asNum() orelse return .errType(0, "chan tuple", "tuple");
    const cid: revo.vm.ChannelID = @intFromFloat(chan_id);
    const recv_result = try vm.sched.channelRecv(cid);
    if (recv_result) |value| return .{ .ok = value };
    return .parked();
}

/// converts value to number
/// accepts number (passthrough) or string (parsed)
/// errors on other types
pub fn tonumber(args: []const Data, vm: *VM) !NativeResult {
    if (args[0].isNumber()) return .Ok(vm, args[0]);
    if (args[0].asString()) |id| {
        const parsed = try std.fmt.parseFloat(f64, vm.stringValue(id));
        return .Ok(vm, Data.new.num(parsed));
    }
    return .errType(0, "number, string", dataToString(args[0]));
}

/// > expect(what: any) -> !what
/// used in tests
///
/// return the value back if truthy, otherwise (:err, :AssertionFailed)
pub fn expect(args: []const Data, vm: *VM) !NativeResult {
    if (revo.isFalse(args[0])) return .Err(vm, "ExpectFailed");
    return .Ok(vm, args[0]);
}

/// > expect_eq(what: any) -> !:ok
/// panics if the value is falsy
pub fn expect_eq(args: []const Data, vm: *VM) !NativeResult {
    if (vm.compare(args[0], args[1]) != .eq) {
        return .Err(vm, "NotEqual");
    }
    return .Ok(vm, args[0]);
}

/// > assert(what: any) -> what
/// panics if the value is falsy
pub fn assert_(args: []const Data, vm: *VM) !NativeResult {
    if (revo.isFalse(args[0])) return panic_(&[1]Data{args[0]}, vm);
    return .okData(args[0]);
}

/// > assert(what: any) -> what
/// panics if the value is falsy
pub fn assert_eq(args: []const Data, vm: *VM) !NativeResult {
    if (vm.compare(args[0], args[1]) != .eq) {
        return .other("neq");
    }
    return .okData(args[0]);
}

/// > print(args: any...) -> atom
/// prints values to stdout with space separator
///     print("hello", 42, "world")
pub fn print(args: []const Data, vm: *VM) !NativeResult {
    var pbuf: [256]u8 = undefined;
    var pw = std.Io.File.stdout().writerStreaming(vm.runtime.io, &pbuf);
    defer _ = pw.flush() catch {};
    if (args.len == 0) {
        _ = try pw.interface.writeAll("\n");
        try pw.flush();
        return okAtom(vm);
    }
    for (args, 0..) |a, idx| {
        if (idx != 0) _ = try pw.interface.writeAll(" ");
        try append_data(&pw.interface, a, vm, .display);
    }
    try pw.interface.print("\n", .{});
    try pw.flush();
    return .{ .ok = revo.core_atoms.data(.ok) };
}

/// > panic(args: any...) -> error
/// panics with given message
///     panic("something went wrong")
pub fn panic_(args: []const Data, vm: *VM) !NativeResult {
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

/// > cload(path: string) -> nil
///
/// you should use import() instead. likely going to remove this
/// loads a C extension lib and registers its functions as globals
pub fn cload(args: []const Data, vm: *VM) !NativeResult {
    const string_id = args[0].asString().?;
    const path = vm.stringValue(string_id);

    const resolved_path = try revo.path_utils.resolve(path, vm.module_dir, vm.runtime.io, vm.runtime.alloc);
    defer vm.runtime.alloc.free(resolved_path);

    const mods = try revo.ffi.loadC(vm, resolved_path);
    defer vm.runtime.alloc.free(mods);
    const t_id = try vm.tables.create();

    for (mods) |c_fn| {
        const fn_id = try vm.functions.create(.{ .c_function = c_fn });
        try vm.setGlobal(c_fn.name, Data.new.function(fn_id));
    }

    return .okData(mem.Data.new.table(t_id));
}

pub fn system_(tbl: []const Data, vm: *VM) !NativeResult {
    const args = tbl[0].asTable().?;
    const table = try vm.tables.get(args);

    var argv = try vm.runtime.alloc.alloc([]const u8, table.array.items.len);
    defer vm.runtime.alloc.free(argv);
    defer for (argv) |arg| vm.runtime.alloc.free(arg);

    for (table.array.items, 0..) |arg, i|
        argv[i] = try vm.runtime.alloc.dupe(u8, vm.stringValue(arg.asString().?));

    var proc = try std.process.spawn(vm.runtime.io, .{
        .argv = argv,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer _ = proc.wait(vm.runtime.io) catch {};

    var stderr_buf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer stderr_buf.deinit();
    var stdout_buf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer stdout_buf.deinit();

    var read_buf: [1024]u8 = undefined;
    var stdout_reader = (proc.stdout orelse unreachable).reader(vm.runtime.io, &read_buf);
    _ = try stdout_reader.interface.streamRemaining(&stdout_buf.writer);

    var read_buf2: [1024]u8 = undefined;
    var stderr_reader = (proc.stderr orelse unreachable).reader(vm.runtime.io, &read_buf2);
    _ = try stderr_reader.interface.streamRemaining(&stderr_buf.writer);

    const so = try vm.adoptDataString(try stdout_buf.toOwnedSlice());
    const se = try vm.adoptDataString(try stderr_buf.toOwnedSlice());
    return .Ok(vm, Data.new.tuple(try vm.tuples.create(&[2]Data{ so, se })));
}

pub fn read(args: []const Data, vm: *VM) !NativeResult {
    var path: []const u8 = "/dev/stdin";
    var read_eof = false;
    var delim: u8 = '\n';

    if (args.len > 1) return .errArity(args.len, 1);
    if (args.len == 1) {
        const t = args[0].asTable() orelse return .errType(0, "table", typeof(args[0]));
        const table = try vm.tables.get(t);
        if (try table.get(Data.new.atom(revo.core_atoms.path.atom_id()), vm)) |v| {
            path = if (v.asString()) |id|
                vm.stringValue(id)
            else if (v.asAtom()) |atom|
                if (atom == revo.core_atoms.atom_id(.undef) or atom == revo.core_atoms.atom_id(.nil))
                    path
                else
                    return .errType(0, "string", typeof(v))
            else
                return .errType(0, "string", typeof(v));
        }
        if (try table.get(Data.new.atom(revo.core_atoms.delimiter.atom_id()), vm)) |v| {
            if (v.asAtom()) |atom| {
                const eof_id = revo.core_atoms.eof.atom_id();
                if (atom == revo.core_atoms.nil.atom_id() or atom == eof_id)
                    read_eof = true
                else
                    return .errType(0, "string, :nil, or :eof", typeof(v));
            } else if (v.asString()) |id| {
                const s = vm.stringValue(id);
                if (s.len == 1) {
                    delim = s[0];
                } else {
                    return .errType(0, "single char string", "string");
                }
            } else {
                return .errType(0, "string, :nil, or :eof", typeof(v));
            }
        }
    }

    const rp = try resolveOsPath(path, vm.module_dir, vm);
    defer if (!std.mem.eql(u8, rp, "/dev/stdin")) vm.runtime.alloc.free(rp);

    const file, const close =
        if (std.mem.eql(u8, rp, "/dev/stdin"))
            .{ std.Io.File.stdin(), false }
        else
            .{ try std.Io.Dir.openFile(std.Io.Dir.cwd(), vm.runtime.io, rp, .{}), true };
    defer if (close) file.close(vm.runtime.io);

    var result = try std.ArrayList(u8).initCapacity(vm.runtime.alloc, 128);
    defer result.deinit(vm.runtime.alloc);

    var buf: [1]u8 = undefined;
    while (true) {
        _ = file.readStreaming(vm.runtime.io, &.{buf[0..]}) catch |err| switch (err) {
            error.EndOfStream => {
                if (result.items.len > 0)
                    return resultTuple(vm, .ok, try vm.adoptDataString(try result.toOwnedSlice(vm.runtime.alloc)));
                return .Err(vm, "EndOfStream");
            },
            else => |e| return e,
        };
        if (!read_eof and buf[0] == delim)
            return resultTuple(vm, .ok, try vm.adoptDataString(try result.toOwnedSlice(vm.runtime.alloc)));
        try result.append(vm.runtime.alloc, buf[0]);
    }
}

var gensym_counter: u64 = 0;

pub fn gensym(args: []const Data, vm: *VM) !NativeResult {
    _ = args;
    const n = gensym_counter;
    gensym_counter += 1;
    const name = try std.fmt.allocPrint(vm.runtime.alloc, "__gensym_{d}", .{n});
    defer vm.runtime.alloc.free(name);
    return .{ .ok = try vm.ownDataStringNoDedup(name) };
}

test "gensym produces different values on each call" {
    try revo.lang.testing.top_atom(
        \\ const a = gensym()
        \\ const b = gensym()
        \\ a != b
    , "true");
}

pub fn cwd(args: []const Data, vm: *VM) !NativeResult {
    _ = args;
    const cwd_path = try std.Io.Dir.cwd().realPathFileAlloc(vm.runtime.io, ".", vm.runtime.alloc);
    defer vm.runtime.alloc.free(cwd_path);
    return .{ .ok = try vm.ownDataString(cwd_path) };
}

pub fn import(args: []const Data, vm: *VM) !NativeResult {
    if (args.len != 1) return .{ .err = .{ .wrong_arity = .{ .got = args.len, .expected = 1 } } };

    const raw_path = args[0].asString() orelse return .{ .err = .{ .type_error = .{
        .arg = 0,
        .expected = "string",
        .got = dataToString(args[0]),
    } } };
    const raw_path_s = vm.stringValue(raw_path);

    const resolved_path = resolveImportPath(raw_path_s, vm.module_dir, vm) catch |err| switch (err) {
        error.FileNotFound => return NativeResult.other("module not found"),
        error.OutOfMemory => |e| return e,
        else => return NativeResult.other("module not found"),
    };
    defer vm.runtime.alloc.free(resolved_path);
    if (std.mem.endsWith(u8, resolved_path, ".so") or std.mem.endsWith(u8, resolved_path, ".dylib")) {
        const mods = try revo.ffi.loadC(vm, resolved_path);
        defer vm.runtime.alloc.free(mods);
        const t_id = try vm.tables.create();
        const tbl = try vm.tables.get(t_id);

        for (mods) |c_fn| {
            const fn_id = try vm.functions.create(.{ .c_function = c_fn });
            try tbl.putRaw(
                Data.new.atom(try vm.internAtom(c_fn.name)),
                Data.new.function(fn_id),
            );
        }
        return .okData(Data.new.table(t_id));
    }

    const current_stamp = try vm.moduleStamp(resolved_path);
    if (vm.module_cache.get(resolved_path)) |cached| {
        if (std.meta.eql(cached.stamp, current_stamp)) {
            return .{ .ok = cached.result };
        }
        _ = vm.invalidateModuleCache(resolved_path);
    }
    for (vm.loading_stack.items) |loading| {
        if (std.mem.eql(u8, loading, resolved_path)) return NativeResult.other("cyclic import detected");
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
            else => NativeResult.other("module error"),
        };
    };
    _ = vm.loading_stack.pop();

    try vm.module_cache.put(cache_key, .{ .result = result, .stamp = current_stamp });
    return .{ .ok = result };
}

fn resolveOsPath(raw_path: []const u8, base_dir: ?[]const u8, vm: *VM) ![]const u8 {
    if (std.mem.eql(u8, raw_path, "/dev/stdin")) return "/dev/stdin";
    return vm_path.resolve(raw_path, base_dir, vm.runtime.io, vm.runtime.alloc);
}

fn resolveImportPath(raw_path: []const u8, base_dir: ?[]const u8, vm: *VM) ![]const u8 {
    const alloc = vm.runtime.alloc;
    const io = vm.runtime.io;

    const is_relative = raw_path.len > 0 and raw_path[0] == '.';

    // relative paths (./ or ../): only base_dir
    if (is_relative) {
        if (base_dir) |dir| {
            if (try tryRealPath(raw_path, dir, io, alloc)) |p| return p;
            const with_ext = try std.fmt.allocPrint(alloc, "{s}.rv", .{raw_path});
            defer alloc.free(with_ext);
            if (try tryRealPath(with_ext, dir, io, alloc)) |p| return p;
            const init_path = try std.fmt.allocPrint(alloc, "{s}/init.rv", .{raw_path});
            defer alloc.free(init_path);
            if (try tryRealPath(init_path, dir, io, alloc)) |p| return p;
        }
        return error.FileNotFound;
    }

    // absolute paths
    if (std.fs.path.isAbsolute(raw_path)) {
        if (try tryRealPath(raw_path, null, io, alloc)) |p| return p;
        return error.FileNotFound;
    }

    if (vm.project_root.len > 0) {
        if (try tryRealPath(raw_path, vm.project_root, io, alloc)) |p| return p;
        const pr_ext = try std.fmt.allocPrint(alloc, "{s}.rv", .{raw_path});
        defer alloc.free(pr_ext);
        if (try tryRealPath(pr_ext, vm.project_root, io, alloc)) |p| return p;
        const pr_init = try std.fmt.allocPrint(alloc, "{s}/init.rv", .{raw_path});
        defer alloc.free(pr_init);
        if (try tryRealPath(pr_init, vm.project_root, io, alloc)) |p| return p;
    }

    for (vm.package_path.items) |tmpl| {
        const sub = if (std.mem.indexOfScalar(u8, tmpl, '?')) |pos|
            try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ tmpl[0..pos], raw_path, tmpl[pos + 1 ..] })
        else
            try alloc.dupe(u8, tmpl);
        defer alloc.free(sub);
        if (try tryRealPath(sub, null, io, alloc)) |p| return p;
        const sub_ext = try std.fmt.allocPrint(alloc, "{s}.rv", .{sub});
        defer alloc.free(sub_ext);
        if (try tryRealPath(sub_ext, null, io, alloc)) |p| return p;
        const sub_init = try std.fmt.allocPrint(alloc, "{s}/init.rv", .{sub});
        defer alloc.free(sub_init);
        if (try tryRealPath(sub_init, null, io, alloc)) |p| return p;
    }

    return error.FileNotFound;
}

fn tryRealPath(raw_path: []const u8, base_dir: ?[]const u8, io: std.Io, alloc: std.mem.Allocator) !?[]u8 {
    const resolved = try vm_path.resolve(raw_path, base_dir, io, alloc);
    defer alloc.free(resolved);
    var buf: [4096]u8 = undefined;
    const n = std.Io.Dir.cwd().realPathFile(io, resolved, &buf) catch |err| switch (err) {
        error.FileNotFound, error.IsDir => return null,
        else => |e| return e,
    };
    const stat = std.Io.Dir.cwd().statFile(io, buf[0..n], .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    if (stat.kind == .directory) return null;
    return try alloc.dupe(u8, buf[0..n]);
}

const RenderMode = enum { display, debug };

fn append_data(writer: *std.Io.Writer, val: Data, vm: *VM, mode: RenderMode) !void {
    switch (mode) {
        .display => {
            const mm = try vm.getMetamethod(val, "__display");
            if (mm) |m| {
                const rendered = callUnaryMetamethod(m, val, vm);
                const str = switch (rendered) {
                    .ok => |r| if (r.asString()) |id| vm.stringValue(id) else "",
                    .err => "",
                };
                try writer.writeAll(str);
                return;
            }
            const mm2 = try vm.getMetamethod(val, "__tostring");
            if (mm2) |m| {
                const rendered = callUnaryMetamethod(m, val, vm);
                const str = switch (rendered) {
                    .ok => |r| if (r.asString()) |id| vm.stringValue(id) else "",
                    .err => "",
                };
                try writer.writeAll(str);
                return;
            }
            try val.write(writer, vm, .display);
        },
        .debug => try val.write(writer, vm, .debug),
    }
}

pub fn callUnaryMetamethod(mm: Data, val: Data, vm: *VM) NativeResult {
    if (!mm.isFunction()) return .errType(0, "function", dataToString(mm));
    const result = vm.callFunction(mm, &.{val}) catch |err| {
        return .other(@errorName(err));
    };
    return .{ .ok = result };
}

/// > sleep(ms: number) -> parked
/// sleeps current fiber for given milliseconds
/// parks fiber instead of blocking
pub fn sleep(args: []const Data, vm: *VM) !NativeResult {
    const n = args[0].asNum() orelse return .errType(0, "number", dataToString(args[0]));
    const ms: u64 = blk: {
        if (!std.math.isFinite(n) or n < 0 or @floor(n) != n) return .errType(0, "non-negative integer", dataToString(args[0]));
        break :blk @as(u64, @intFromFloat(n));
    };
    try vm.schedParkCurrentForSleepMS(ms);
    return .parked();
}

pub const NativeErrPayload = union(enum) {
    wrong_arity: struct { got: usize, expected: usize },
    type_error: struct { arg: ?usize, expected: []const u8, got: []const u8 },
    native_error: revo.vm.NativeError,
    parked: void,
    other: []const u8,
};

pub const NativeResult = union(enum) {
    ok: Data,
    err: NativeErrPayload,

    pub fn parked() NativeResult {
        return .{ .err = .{ .parked = {} } };
    }
    pub fn okBool(b: bool) NativeResult {
        return .{ .ok = Data.new.boolean(b) };
    }
    pub fn errArity(got: usize, expected: usize) NativeResult {
        return .{ .err = .{ .wrong_arity = .{ .got = got, .expected = expected } } };
    }
    pub fn errType(arg: usize, expected: []const u8, got: []const u8) NativeResult {
        return .{ .err = .{ .type_error = .{ .arg = arg, .expected = expected, .got = got } } };
    }
    pub fn okData(d: Data) NativeResult {
        return .{ .ok = d };
    }
    pub fn okCa(a: revo.core_atoms) NativeResult {
        return .{ .ok = Data.new.atom(a.atom_id()) };
    }
    pub fn other(message: []const u8) NativeResult {
        return .{ .err = .{ .other = message } };
    }
    pub fn panic() NativeResult {
        return .{ .err = .{ .other = "panic" } };
    }

    pub fn Ok(vm: *VM, value: Data) !NativeResult {
        return resultTuple(vm, .ok, value);
    }

    pub fn Err(vm: *VM, err_atom: []const u8) !NativeResult {
        const tag = try vm.internAtom(err_atom);
        return resultTuple(vm, .err, Data.new.atom(tag));
    }
};

// type utils
pub fn typeUtils(vm: *VM) !void {
    inline for (@typeInfo(revo.memory.Type).@"enum".fields) |field| {
        const func = struct {
            fn is_of(args: []const Data, _: *VM) !NativeResult {
                for (args) |arg| {
                    if (arg.tag() != @field(revo.memory.Type, field.name)) {
                        return .okBool(false);
                    }
                }
                return .okBool(true);
            }
        }.is_of;
        const id = try vm.functions.create(.{ .native = define(
            &[1]TypeSpec{.any},
            func,
        ) });
        const atom = try vm.internAtom(field.name ++ "?");
        const val = Data.new.function(id);
        try vm.globals.put(atom, val);
        try vm.stdlib_globals.put(atom, val);
    }
    const is_number = struct {
        fn num(args: []const Data, _: *VM) !NativeResult {
            for (args) |arg| {
                if (!arg.isNumber()) return .okBool(false);
            }
            return .okBool(true);
        }
    }.num;
    const id = try vm.functions.create(.{ .native = define(&[_]TypeSpec{.any}, is_number) });
    const atom = try vm.internAtom("number?");
    const val = Data.new.function(id);
    try vm.globals.put(atom, val);
    try vm.stdlib_globals.put(atom, val);
}

test "type predicates" {
    try testing.top_true("number?(42)");
    try testing.top_true("string?(\"hello\")");
    try testing.top_true("table?({})");
    try testing.top_true("atom?(:ok)");
    try testing.top_true("function?(fn() 42)");
}

test "array methods" {
    try testing.top_number("{1, 2, 3}:first()", 1);
    try testing.top_number("{1, 2, 3}:last()", 3);
    try testing.top_true("{1, 2, 3}:contains?(2)");
    try testing.top_false("{1, 2, 3}:contains?(5)");
    try testing.top_number("{1, 2, 3}:index_of(2)", 1);
    try testing.top_number("{1, 2, 3}:sum()", 6);
}

test "array sort" {
    try testing.top_number("{3, 1, 2}:sort():first()", 1);
    try testing.top_number("{3, 1, 2}:sort():last()", 3);
    try testing.top_number("{1, 5, 3}:sort_by(fn(a, b) a > b):first()", 5);
}

test "array transform" {
    try testing.top_number("{1, 2, 3}:reverse():first()", 3);
    try testing.top_number("{1, 2, 3}:unique():sum()", 6);
    try testing.top_number("{1, 2, 1, 3, 2}:unique():sum()", 6);
}

test "string creation" {
    try testing.top_string("string_of(97)", "a");
    try testing.top_string("string_of((72, 105))", "Hi");
    try testing.top_string("string_of((82, 101, 118, 111))", "Revo");
}

test "string table conversion" {
    try testing.top_number("len(\"abc\":table())", 3);
    try testing.top_number("\"a\":ascii()", 97);
    try testing.top_number("\"Hello\":ascii()", 72);
}

test "array flatten" {
    try testing.top_number("{{1, 2}, {3, 4}}:flatten():sum()", 10);
    try testing.top_number("{{1}, {2, 3}, {4}}:flatten():sum()", 10);
}

test "stdlib json time and string modules are exposed" {
    try testing.top_string("json.encode((\"a\", \"b\", \"c\")):unwrap()", "[\"a\",\"b\",\"c\"]");
    try testing.top_number("json.decode(\"{\\\"a\\\":1}\"):unwrap().a", 1);
    try testing.top_true("time.now() > 0");
    try testing.top_number("len(string.split(\"a,b\", \",\"))", 2);
}
