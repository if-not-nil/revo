const std = @import("std");

const revo = @import("../root.zig");
const mem = revo.memory;
const vm_path = revo.path_utils;

const Data = mem.Data;
const VM = revo.VM;
const testing = revo.lang.testing;

pub fn register_stdlib(vm: *revo.VM) !void {
    const meta = @import("meta.zig");
    try registerFunctions(vm, &[_]FuncDef{
        .{ .name = "fmt", .f = defineVariadic(&[_]TypeSpec{.string}, fmt) },
        .{ .name = "len", .f = define(&[_]TypeSpec{.any}, len_) },
        .{ .name = "inspect", .f = define(&[_]TypeSpec{.any}, inspect) },
        .{ .name = "get_metatable", .f = define(&[_]TypeSpec{.any}, meta.get_metatable_) },
        .{ .name = "set_metatable", .f = define(&[_]TypeSpec{ .any, .any }, meta.set_metatable_) },
        .{ .name = "type", .f = define(&[_]TypeSpec{.any}, typeof_) },
        .{ .name = "typeof", .f = define(&[_]TypeSpec{.any}, typeof_) },
        .{ .name = "tostring", .f = define(&[_]TypeSpec{.any}, tostring) },
        .{ .name = "tonumber", .f = define(&[_]TypeSpec{.any}, tonumber) },
        .{ .name = "expect", .f = define(&[_]TypeSpec{.any}, expect) },
        .{ .name = "expect_eq", .f = define(&[_]TypeSpec{ .any, .any }, expect_eq) },
        .{ .name = "assert", .f = define(&[_]TypeSpec{.any}, assert_) },
        .{ .name = "assert_eq", .f = define(&[_]TypeSpec{ .any, .any }, assert_eq) },
        .{ .name = "set_debug", .f = define(&[_]TypeSpec{.table}, meta.set_debug) },
        .{ .name = "debug", .f = define(&[_]TypeSpec{}, debug_) },
        .{ .name = "@range", .f = define(&[_]TypeSpec{ .number, .number, .number }, range_) },
        .{ .name = "@range_from", .f = define(&[_]TypeSpec{ .number, .number }, range_from_) },
        .{ .name = "@struct_new", .f = define(&[_]TypeSpec{ .table, .table }, struct_new) },
        .{ .name = "@try", .f = define(&[_]TypeSpec{.tuple}, try_) },
        .{ .name = "@dotest", .f = define(&[_]TypeSpec{ .string, .function }, dotest) },
        .{ .name = "@dosuite", .f = define(&[_]TypeSpec{ .string, .function }, dosuite) },
        .{ .name = "@eval", .f = define(&[_]TypeSpec{.string}, @import("stupid.zig").eval) },
        .{ .name = "chan", .f = defineVariadic(&[_]TypeSpec{}, chan_new) },
        .{ .name = "send", .f = define(&[_]TypeSpec{ .tuple, .any }, chan_send) },
        .{ .name = "recv", .f = define(&[_]TypeSpec{.tuple}, chan_recv) },
        .{ .name = "sleep", .f = define(&[_]TypeSpec{.number}, sleep) },
        .{ .name = "print", .f = defineVariadic(&[_]TypeSpec{}, print) },
        .{ .name = "panic", .f = defineVariadic(&[_]TypeSpec{}, panic_) },
        .{ .name = "c_use", .f = define(&[_]TypeSpec{.string}, cload) },
        .{ .name = "read", .f = defineVariadic(&[_]TypeSpec{}, read_) },
        .{ .name = "cwd", .f = define(&[_]TypeSpec{}, cwd_) },
        .{ .name = "system", .f = define(&[_]TypeSpec{.table}, system_) },
        .{ .name = "import", .f = define(&[_]TypeSpec{.string}, import_) },
    });
    const argv_id = try vm.tables.create();
    const argv = try vm.tables.get(argv_id);
    for (vm.runtime.argv) |arg| {
        try argv.push(try vm.ownDataString(arg));
    }
    try vm.setGlobal("argv", .{ .table = argv_id });
    // math
    try @import("math.zig").register(vm);
    try @import("string.zig").register(vm);
    try @import("table.zig").register(vm);
    try @import("net.zig").register(vm);
    try @import("json.zig").register(vm);
    try @import("time.zig").register(vm);
    try @import("meta.zig").comparison_mt.register(vm);
    try @import("tuple.zig").register(vm);
    try @import("iter.zig").register(vm);
    try @import("fs.zig").register(vm);
    try typeUtils(vm);
    try @import("../lang/proc.zig").register(vm);
}

pub const NativeFn = *const fn (args: []const Data, vm: *VM) anyerror!NativeResult;
pub const NativeFunc = struct {
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

pub const FuncDef = struct { f: NativeFunc, name: []const u8 };

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
            .number, .integer, .float => data == .number,
            .bool => data == .atom and isBoolAtom(data.atom),
            .string => data == .string,
            .atom => data == .atom,
            .function => data == .function,
            .table => data == .table,
            .tuple => data == .tuple,
        };
    }
};

fn isBoolAtom(atom: mem.AtomID) bool {
    const true_id = revo.core_atoms.atom_id(.true);
    const false_id = revo.core_atoms.atom_id(.false);
    return atom == true_id or atom == false_id;
}

pub fn dataToString(data: Data) []const u8 {
    return @tagName(data);
}

pub fn resultTuple(vm: *VM, comptime tag: ResultTag, value: Data) !NativeResult {
    const tag_atom = try resultTag(vm, tag);
    const items = [_]Data{
        .{ .atom = tag_atom },
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
    const id = switch (value) {
        .tuple => |tuple_id| tuple_id,
        else => return null,
    };
    const tuple = vm.tuples.get(id) catch return null;
    if (tuple.items.len == 0) return null;
    return switch (tuple.items[0]) {
        .atom => |tag| tag,
        else => null,
    };
}

pub fn isResultTag(value: Data, expected: mem.AtomID, vm: *VM) bool {
    return tupleTag(value, vm) == expected;
}

pub fn registerFunctions(vm: *VM, funcs: []const FuncDef) !void {
    for (funcs) |f| {
        const id = try vm.functions.create(.{ .native = f.f });
        const atom = try vm.internAtom(f.name);
        try vm.globals.put(atom, .{ .function = id });
    }
}

pub fn registerTableFunctions(vm: *VM, table_name: []const u8, funcs: []const FuncDef) !void {
    const t_id = try vm.tables.create();
    const atom = try vm.internAtom(table_name);
    try vm.globals.put(atom, Data{ .table = t_id });
    const t = try vm.tables.get(t_id);
    for (funcs) |f| {
        const fn_id = try vm.functions.create(.{ .native = f.f });
        try t.putRaw(.{ .atom = try vm.internAtom(f.name) }, Data{ .function = fn_id });
    }
}

/// > fmt(format: string, args: any...) -> string
/// format string with %v, %d, %? specifiers
/// %v: display value, %d: as number, %?: debug repr
///     fmt("hello %v", "world")
///     fmt("val: %v, num: %d", "x", 42)
pub fn fmt(args: []const Data, vm: *VM) !NativeResult {
    if (args.len == 0) return .errArity(0, 1);
    const format = switch (args[0]) {
        .string => |id| vm.stringValue(id),
        else => unreachable,
    };

    var result = try std.ArrayList(u8).initCapacity(vm.runtime.alloc, 4);
    defer result.deinit(vm.runtime.alloc);

    var arg_idx: usize = 1;
    var i: usize = 0;

    while (i < format.len) {
        if (i + 1 < format.len and format[i] == '%') {
            switch (format[i + 1]) {
                'v' => {
                    if (arg_idx >= args.len) return .errArity(args.len, arg_idx + 1);
                    try append_data(&result, args[arg_idx], vm, .display);
                    arg_idx += 1;
                    i += 2;
                },
                'd' => {
                    if (arg_idx >= args.len) return .errArity(args.len, arg_idx + 1);
                    const v = switch (args[arg_idx]) {
                        .number => args[arg_idx],
                        .string => |id| Data.new.num(try std.fmt.parseFloat(f64, vm.stringValue(id))),
                        .atom => try vm.ownDataString("<un-tonumber-able>"),
                        else => Data.new.num(0),
                    };
                    try append_data(&result, v, vm, .display);
                    arg_idx += 1;
                    i += 2;
                },
                '?' => {
                    if (arg_idx >= args.len) return .errArity(args.len, arg_idx + 1);
                    try append_data(&result, args[arg_idx], vm, .debug);
                    arg_idx += 1;
                    i += 2;
                },
                else => {},
            }
        } else {
            try result.append(vm.runtime.alloc, format[i]);
            i += 1;
        }
    }

    const str = try result.toOwnedSlice(vm.runtime.alloc);
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
    const name = args[0].string;
    const body = args[1].function;
    var buf: [128]u8 = undefined;
    var w = vm.runtime.stdout.writer(vm.runtime.io, &buf);
    defer w.flush() catch {};

    std.debug.print("* test \"{s}\"...\n", .{try vm.strings.get(name)});
    const res = vm.callFunction(.{ .function = body }, &[0]Data{}) catch |err| {
        const failure = vm.evalFailure(err);
        failure.render(vm.runtime.alloc, &w.interface, vm.currentDebugSource() orelse "") catch {
            try revo.pretty.printError(
                vm.runtime.alloc,
                &w.interface,
                "hard-fail - {s}",
                .{@errorName(err)},
            );
            // std.debug.print("!! hard-failed: \"{s}\"\n", .{@errorName(err)});
            return .{ .ok = Data.new.nil() };
        };
        return .{ .ok = Data.new.nil() };
    };
    // only react to err tuple
    // everything else is pass
    if (res == .tuple) {
        const tpl = try vm.tuples.get(res.tuple);
        if (tpl.items.len != 2)
            return .{ .ok = Data.new.nil() };
        if (tpl.items[0] != .atom or tpl.items[0].atom != revo.core_atoms.atom_id(.err))
            return .{ .ok = Data.new.nil() };

        var obuf = try std.ArrayList(u8).initCapacity(vm.runtime.alloc, 4);
        defer obuf.deinit(vm.runtime.alloc);
        try append_data(&obuf, tpl.items[1], vm, .debug);

        try revo.pretty.printError(
            vm.runtime.alloc,
            &w.interface,
            "fail - {s}",
            .{obuf.items},
        );
        // std.debug.print("* failed: {s}\n", .{buf.items});
    }
    return .{ .ok = Data.new.nil() };
}

/// internal, pls dont use. runs a test suite
pub fn dosuite(args: []const Data, vm: *VM) !NativeResult {
    const body = args[1].function;
    _ = vm.callFunction(.{ .function = body }, &[0]Data{}) catch |err| {
        const failure = vm.evalFailure(err);
        var buf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
        defer buf.deinit();
        failure.render(vm.runtime.alloc, &buf.writer, vm.currentDebugSource() orelse "") catch {
            std.debug.print("* suite hard-failed: \"{s}\"\n", .{@errorName(err)});
            return .okCa(.nil);
        };
        std.debug.print("{s}\n", .{buf.written()});
    };

    return .okCa(.nil);
}

pub fn debug_(args: []const Data, vm: *VM) !NativeResult {
    _ = args;

    const out_id = try vm.tables.create();
    const out = try vm.tables.get(out_id);

    const flags_id = try vm.tables.create();
    const flags = try vm.tables.get(flags_id);
    try flags.putRaw(.{ .atom = try vm.internAtom("dump") }, Data.new.boolean(vm.debug.dump));
    try flags.putRaw(.{ .atom = try vm.internAtom("trace") }, Data.new.boolean(vm.debug.trace));
    try flags.putRaw(.{ .atom = try vm.internAtom("instr") }, Data.new.boolean(vm.debug.each_instr));
    try flags.putRaw(.{ .atom = try vm.internAtom("stack") }, Data.new.boolean(vm.debug.each_stack));
    try out.putRaw(.{ .atom = try vm.internAtom("flags") }, Data.new.table(flags_id));

    const fiber = vm.currentFiber();
    try out.putRaw(.{ .atom = try vm.internAtom("fiber_id") }, Data.new.num(fiber.id));
    try out.putRaw(.{ .atom = try vm.internAtom("pc") }, Data.new.num(fiber.pc));
    try out.putRaw(.{ .atom = try vm.internAtom("stack_depth") }, Data.new.num(fiber.slots.items.len));
    try out.putRaw(.{ .atom = try vm.internAtom("frame_depth") }, Data.new.num(fiber.frames.items.len));
    try out.putRaw(.{ .atom = try vm.internAtom("program_len") }, Data.new.num(fiber.program.len));

    if (vm.currentDebugInfo()) |info| {
        try out.putRaw(.{ .atom = try vm.internAtom("has_debug_info") }, Data.new.boolean(true));
        try out.putRaw(.{ .atom = try vm.internAtom("source_name") }, try vm.ownDataString(info.source_name));
        try out.putRaw(.{ .atom = try vm.internAtom("source") }, try vm.ownDataString(info.source));
        try out.putRaw(.{ .atom = try vm.internAtom("span_count") }, Data.new.num(info.spans.len));
    } else {
        try out.putRaw(.{ .atom = try vm.internAtom("has_debug_info") }, Data.new.boolean(false));
        try out.putRaw(.{ .atom = try vm.internAtom("source_name") }, Data.new.nil());
        try out.putRaw(.{ .atom = try vm.internAtom("source") }, Data.new.nil());
        try out.putRaw(.{ .atom = try vm.internAtom("span_count") }, Data.new.num(0));
    }

    try out.putRaw(
        .{ .atom = try vm.internAtom("panic_message") },
        if (vm.panic_message) |msg| try vm.ownDataString(msg) else Data.new.nil(),
    );
    try out.putRaw(
        .{ .atom = try vm.internAtom("runtime_message") },
        if (vm.runtime_message) |msg| try vm.ownDataString(msg) else Data.new.nil(),
    );

    return .okData(Data.new.table(out_id));
}

/// > len(arg0: any) -> number|nil
/// returns length of string or table
/// for strings: byte length, for tables: array part length
/// uses __len metamethod if available
pub fn len_(args: []const Data, vm: *VM) !NativeResult {
    const mm = try vm.getMetamethod(args[0], "__len");
    if (mm) |m| return call_unary_metamethod(m, args[0], vm);

    return switch (args[0]) {
        .string => |id| .okData(Data.new.num(vm.stringValue(id).len)),
        .table => |id| .okData(Data.new.num((try vm.tables.get(id)).array.items.len)),
        else => .errType(0, "string or table", typeof(args[0])),
    };
}

/// > inspect(any) -> any
/// prints one value and returns it back
pub fn inspect(args: []const Data, vm: *VM) !NativeResult {
    _ = try print(args, vm);
    return .okData(args[0]);
}

pub fn typeof(d: Data) []const u8 {
    return switch (d) {
        .atom => |a| if (a == revo.core_atoms.atom_id(.nil)) "nil" else "atom",
        .number => "number",
        .string => "string",
        .function => "function",
        .table => "table",
        .tuple => "tuple",
    };
}

/// > typeof(arg0: any) -> string
/// returns type of arg0 as string
/// possible values: nil, number, string, atom, function, table, tuple
pub fn typeof_(args: []const Data, vm: *VM) !NativeResult {
    const str = switch (args[0]) {
        .atom => |a| if (a == revo.core_atoms.atom_id(.nil)) "nil" else "atom",
        .number => "number",
        .string => "string",
        .function => "function",
        .table => "table",
        .tuple => "tuple",
    };

    return .okData(Data.new.atom(try vm.internAtom(str)));
}

fn typeMatchesStructField(expected: Data, value: Data, vm: *VM) bool {
    const expected_atom = switch (expected) {
        .atom => |atom| atom,
        else => return true,
    };
    const expected_name = vm.atomName(expected_atom);

    if (std.mem.eql(u8, expected_name, "bool")) {
        return value == .atom and isBoolAtom(value.atom);
    }
    if (std.mem.eql(u8, expected_name, "integer")) return value == .number;
    if (std.mem.eql(u8, expected_name, "float")) return value == .number;
    return std.mem.eql(u8, expected_name, typeof(value));
}

fn panicFmt(vm: *VM, comptime fmt_str: []const u8, args: anytype) !NativeResult {
    const message = try std.fmt.allocPrint(vm.runtime.alloc, fmt_str, args);
    defer vm.runtime.alloc.free(message);
    try vm.setPanicMessage(message);
    return .panic();
}

fn struct_new(args: []const Data, vm: *VM) !NativeResult {
    const descriptor_id = args[0].table;
    const init_id = args[1].table;

    const descriptor = try vm.tables.get(descriptor_id);

    const fields_id = switch (descriptor.getRaw(.{ .atom = try vm.internAtom("__fields") }) orelse return .other("invalid struct descriptor")) {
        .table => |id| id,
        else => return .other("invalid struct descriptor, fields has to be a table!"),
    };

    const defaults_id = switch (descriptor.getRaw(.{ .atom = try vm.internAtom("__defaults") }) orelse
        return .other("invalid struct descriptor, no defaults!")) {
        .table => |id| id,
        else => return .other("invalid struct descriptor"),
    };

    const types_id = switch (descriptor.getRaw(.{ .atom = try vm.internAtom("__types") }) orelse
        return .other("invalid struct descriptor, no types!")) {
        .table => |id| id,
        else => return .other("invalid struct descriptor"),
    };

    const name = switch (descriptor.getRaw(.{ .atom = try vm.internAtom("__name") }) orelse
        return .other("invalid struct descriptor")) {
        .string => |id| vm.stringValue(id),
        else => "<struct>",
    };

    // allocate first, then refetch pointers,,,, pool growth can invalidate table refs
    const instance_id = try vm.tables.create();
    const instance = try vm.tables.get(instance_id);
    const init = try vm.tables.get(init_id);
    const fields = try vm.tables.get(fields_id);
    const defaults = try vm.tables.get(defaults_id);
    const types = try vm.tables.get(types_id);

    for (fields.hash_order.items) |field_data| {
        const field_key = field_data;
        const field_atom = field_key.atom;
        const field_name = vm.atomName(field_atom);
        _ = fields.getRaw(field_key) orelse return .other("invalid struct descriptor");

        const value = init.getRaw(field_key) orelse defaults.getRaw(field_key) orelse {
            return panicFmt(vm, "missing field `{s}` for struct `{s}`", .{ field_name, name });
        };

        if (types.getRaw(field_key)) |expected| {
            if (!typeMatchesStructField(expected, value, vm)) {
                return panicFmt(vm, "field `{s}` on `{s}` expected {s}, got {s}", .{
                    field_name,
                    name,
                    switch (expected) {
                        .atom => |atom| vm.atomName(atom),
                        else => dataToString(expected),
                    },
                    typeof(value),
                });
            }
        }

        try instance.putRaw(field_key, value);
    }

    for (init.hash_order.items) |field_data| {
        if (fields.getRaw(field_data) == null) {
            return panicFmt(vm, "unknown field `{s}` for struct `{s}`", .{
                vm.atomName(field_data.atom),
                name,
            });
        }
    }

    try vm.setStructInstanceTable(instance_id, descriptor_id);
    return .{ .ok = .{ .table = instance_id } };
}

/// > tostring(arg0: any) -> string
/// converts value to string representation
/// uses __tostring or __display metamethod if available
pub fn tostring(args: []const Data, vm: *VM) !NativeResult {
    const mm = try vm.getMetamethod(args[0], "__tostring");
    if (mm) |m| return call_unary_metamethod(m, args[0], vm);
    var buf = try std.ArrayList(u8).initCapacity(vm.runtime.alloc, 8);
    defer buf.deinit(vm.runtime.alloc);
    try args[0].write(&buf, vm, .display);
    const str = try buf.toOwnedSlice(vm.runtime.alloc);
    return .{ .ok = try vm.adoptDataString(str) };
}

/// > @range_from(start: number, step: number) -> tuple
/// creates a range tuple (start, step) without stop
fn range_from_(args: []const Data, vm: *VM) !NativeResult {
    const start = expect_number(args[0]) orelse return .errType(0, "number", @tagName(args[0]));
    const step = expect_number(args[1]) orelse return .errType(1, "number", @tagName(args[1]));
    const tag = try vm.internAtom("range_from");
    const id = try vm.tuples.create(&.{ .{ .atom = tag }, Data.new.num(start), Data.new.num(step) });
    return .okData(Data.new.tuple(id));
}

/// > @try(result: tuple) -> any
/// unwraps result tuple, panics if not :ok
pub fn try_(args: []const Data, vm: *VM) !NativeResult {
    const t_id = switch (args[0]) {
        .tuple => |t| t,
        else => return .errType(0, "tuple", @tagName(args[0])),
    };
    const tuple = try vm.tuples.get(t_id);
    if (tuple.len() < 2) return .errType(0, "tuple with at least 2 elements", "tuple with less than 2 elements");
    const tag = tuple.items[0];
    switch (tag) {
        .atom => |atom| {
            const ok_id = revo.core_atoms.atom_id(.ok);
            if (atom != ok_id) return panic_(&[1]Data{tuple.items[1]}, vm);
            return .{ .ok = tuple.items[1] };
        },
        else => return .errType(0, "tuple starting with atom", "tuple starting with non-atom"),
    }
}

/// > tuple:unwrap_err() -> any
/// extracts error from result tuple, panics if not :err
pub fn unwrap_err_(args: []const Data, vm: *VM) !NativeResult {
    const result = args[0];
    if (result != .tuple) return .errType(0, "tuple", @tagName(result));

    const tuple = try vm.tuples.get(result.tuple);
    if (tuple.items.len < 2) return .errType(0, "tuple with at least 2 elements", "empty tuple");

    const tag = tuple.items[0];
    if (tag != .atom) return .errType(0, "tuple starting with atom", "tuple starting with non-atom");

    const err_tag = revo.core_atoms.atom_id(.err);
    if (tag.atom == err_tag) {
        return .{ .ok = tuple.items[1] };
    }

    return panic_(&[1]Data{revo.core_atoms.data(.err)}, vm);
}

/// > @range(start: number, step: number, stop: number) -> tuple
/// creates a range tuple (start, step, stop)
pub fn range_(args: []const Data, vm: *VM) !NativeResult {
    const start = expect_number(args[0]) orelse return .errType(0, "number", @tagName(args[0]));
    const step = expect_number(args[1]) orelse return .errType(1, "number", @tagName(args[1]));
    const stop = expect_number(args[2]) orelse return .errType(2, "number", @tagName(args[2]));
    const tag = revo.core_atoms.atom_id(.range);
    const id = try vm.tuples.create(&.{ .{ .atom = tag }, Data.new.num(start), Data.new.num(step), Data.new.num(stop) });
    return .okData(Data.new.tuple(id));
}

fn expect_number(data: Data) ?f64 {
    return switch (data) {
        .number => |n| n,
        else => null,
    };
}

fn as_stack_index(value: Data) ?usize {
    const num = switch (value) {
        .number => |n| n,
        else => return null,
    };
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
        as_stack_index(args[0]) orelse return .errType(0, "number", @tagName(args[0]))
    else
        return .errArity(args.len, 0);

    const channel_id = try vm.sched.channelCreate(vm.runtime.alloc, &vm.tables, cap);
    const res = try vm.tuples.create(&[2]Data{
        .{ .atom = try vm.internAtom("chan") },
        Data.new.num(channel_id),
    });
    return .okData(Data.new.tuple(res));
}

/// > send(chan: tuple, value: any) -> atom
/// sends value to channel
pub fn chan_send(args: []const Data, vm: *VM) !NativeResult {
    const tuple_id = switch (args[0]) {
        .tuple => |id| id,
        else => return .errType(0, "tuple", @tagName(args[0])),
    };
    const t = try vm.tuples.get(tuple_id);
    if (t.items.len < 2) return .errType(0, "chan tuple", "tuple");
    const chan_atom = try vm.internAtom("chan");
    if (t.items[0] != .atom or t.items[0].atom != chan_atom)
        return .errType(0, "chan tuple", "tuple");
    const chan_id = t.items[1].number;
    const cid: revo.vm.ChannelID = @intFromFloat(chan_id);
    try vm.sched.channelSend(vm.runtime.alloc, cid, args[1]);
    return okAtom(vm);
}

/// > recv(chan: tuple) -> any
/// receives value from channel, parks if empty
pub fn chan_recv(args: []const Data, vm: *VM) !NativeResult {
    const tuple_id = switch (args[0]) {
        .tuple => |id| id,
        else => return .errType(0, "tuple", @tagName(args[0])),
    };
    const t = try vm.tuples.get(tuple_id);
    if (t.items.len < 2) return .errType(0, "chan tuple", "tuple");
    const chan_atom = try vm.internAtom("chan");
    if (t.items[0] != .atom or t.items[0].atom != chan_atom)
        return .errType(0, "chan tuple", "tuple");
    const chan_id = t.items[1].number;
    const cid: revo.vm.ChannelID = @intFromFloat(chan_id);
    const recv_result = try vm.sched.channelRecv(vm.runtime.alloc, cid);
    if (recv_result) |value| return .{ .ok = value };
    return .parked();
}

/// converts value to number
/// accepts number (passthrough) or string (parsed)
/// errors on other types
pub fn tonumber(args: []const Data, vm: *VM) !NativeResult {
    return switch (args[0]) {
        .number => .Ok(vm, args[0]),
        .string => |id| {
            const parsed = std.fmt.parseFloat(f64, vm.stringValue(id)) catch |err| {
                return .Err(vm, @errorName(err));
            };
            return .Ok(vm, Data.new.num(parsed));
        },
        else => .errType(0, "number, string", @tagName(args[0])),
    };
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
    if (args.len == 0) {
        std.debug.print("\n", .{});
        return okAtom(vm);
    }
    for (args, 0..) |a, idx| {
        var buf = try std.ArrayList(u8).initCapacity(vm.runtime.alloc, 4);
        defer buf.deinit(vm.runtime.alloc);
        try append_data(&buf, a, vm, .display);
        std.debug.print("{s}", .{buf.items});
        if (idx < args.len - 1) std.debug.print(" ", .{});
    }
    std.debug.print("\n", .{});
    return .{ .ok = revo.core_atoms.data(.ok) };
}

/// > panic(args: any...) -> error
/// panics with given message
///     panic("something went wrong")
pub fn panic_(args: []const Data, vm: *VM) !NativeResult {
    var buf = try std.ArrayList(u8).initCapacity(vm.runtime.alloc, 16);
    defer buf.deinit(vm.runtime.alloc);
    if (args.len == 0) {
        try buf.appendSlice(vm.runtime.alloc, "panic");
    } else {
        for (args, 0..) |arg, idx| {
            if (idx != 0) try buf.appendSlice(vm.runtime.alloc, " ");
            try append_data(&buf, arg, vm, .display);
        }
    }
    try vm.setPanicMessage(buf.items);
    return .other("panic");
}

/// > cload(path: string) -> nil
///
/// you should use import() instead. likely going to remove this
/// loads a C extension lib and registers its functions as globals
pub fn cload(args: []const Data, vm: *VM) !NativeResult {
    const string_id = args[0].string;
    const path = vm.stringValue(string_id);

    const resolved_path = try revo.path_utils.resolve(path, vm.module_dir, vm.runtime.io, vm.runtime.alloc);
    defer vm.runtime.alloc.free(resolved_path);

    const mods = try revo.ffi.loadC(vm, resolved_path);
    defer vm.runtime.alloc.free(mods);
    const t_id = try vm.tables.create();

    for (mods) |c_fn| {
        const fn_id = try vm.functions.create(.{ .c_function = c_fn });
        try vm.setGlobal(c_fn.name, .{ .function = fn_id });
    }

    return .okData(mem.Data{ .table = t_id });
}

pub fn system_(tbl: []const Data, vm: *VM) !NativeResult {
    const args = tbl[0].table;
    const table = try vm.tables.get(args);

    var argv = try vm.runtime.alloc.alloc([]const u8, table.array.items.len);
    defer vm.runtime.alloc.free(argv);
    defer for (argv) |arg| vm.runtime.alloc.free(arg);

    for (table.array.items, 0..) |arg, i|
        argv[i] = try vm.runtime.alloc.dupe(u8, vm.stringValue(arg.string));

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
    var stdout_reader = proc.stdout.?.reader(vm.runtime.io, &read_buf);
    _ = try stdout_reader.interface.streamRemaining(&stdout_buf.writer);

    var read_buf2: [1024]u8 = undefined;
    var stderr_reader = proc.stderr.?.reader(vm.runtime.io, &read_buf2);
    _ = try stderr_reader.interface.streamRemaining(&stderr_buf.writer);

    const so = try vm.adoptDataString(try stdout_buf.toOwnedSlice());
    const se = try vm.adoptDataString(try stderr_buf.toOwnedSlice());
    return .Ok(vm, .{ .tuple = try vm.tuples.create(&[2]Data{ so, se }) });
}

pub fn read_(args: []const Data, vm: *VM) !NativeResult {
    if (args.len > 1) return .errArity(args.len, 1);

    var delimiter: u8 = '\n';
    var read_path: []const u8 = "/dev/stdin";

    if (args.len == 1) {
        const table_id = switch (args[0]) {
            .table => |id| id,
            else => return .errType(0, "table", typeof(args[0])),
        };
        const table = try vm.tables.get(table_id);

        const path_key = Data.new.atom(try vm.internAtom("path"));
        const rpath_in = try table.get(path_key, vm) orelse Data.new.nil();
        read_path = switch (rpath_in) {
            .string => |id| vm.stringValue(id),
            .atom => |atom| if (atom == revo.core_atoms.atom_id(.nil))
                read_path
            else
                return .errType(0, "string", typeof(rpath_in)),
            else => return .errType(0, "string", typeof(rpath_in)),
        };

        const delim_key = Data.new.atom(try vm.internAtom("delimiter"));
        const delim_in = try table.get(delim_key, vm) orelse Data.new.nil();
        delimiter = switch (delim_in) {
            .string => |id| blk: {
                const s = vm.stringValue(id);
                break :blk if (s.len == 1) s[0] else return .errType(0, "single char string", "string");
            },
            .atom => |atom| if (atom == revo.core_atoms.atom_id(.nil))
                delimiter
            else
                return .errType(0, "string", typeof(delim_in)),
            else => return .errType(0, "string", typeof(delim_in)),
        };
    }

    const resolved_path = try resolveOsPath(read_path, vm.module_dir, vm);
    defer if (!std.mem.eql(u8, resolved_path, "/dev/stdin")) vm.runtime.alloc.free(resolved_path);

    const file, const should_close =
        if (std.mem.eql(u8, resolved_path, "/dev/stdin"))
            .{ std.Io.File.stdin(), false }
        else
            .{
                std.Io.Dir.openFileAbsolute(vm.runtime.io, resolved_path, .{}) catch
                    return resultTuple(vm, .err, try vm.ownDataString("ReadError")),
                true,
            };

    defer if (should_close) file.close(vm.runtime.io);

    var buf: [512]u8 = undefined;
    var r = file.reader(vm.runtime.io, &buf);
    var w = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer w.deinit();

    _ = try r.interface.streamDelimiter(&w.writer, delimiter);
    const result_str = try w.toOwnedSlice();
    return resultTuple(vm, .ok, try vm.adoptDataString(result_str));
}

pub fn cwd_(args: []const Data, vm: *VM) !NativeResult {
    _ = args;
    const cwd_path = try std.Io.Dir.cwd().realPathFileAlloc(vm.runtime.io, ".", vm.runtime.alloc);
    defer vm.runtime.alloc.free(cwd_path);
    return .{ .ok = try vm.ownDataString(cwd_path) };
}

pub fn import_(args: []const Data, vm: *VM) !NativeResult {
    if (args.len != 1) return .{ .err = .{ .wrong_arity = .{ .got = args.len, .expected = 1 } } };

    const raw_path = switch (args[0]) {
        .string => |id| vm.stringValue(id),
        else => return .{ .err = .{ .type_error = .{
            .arg = 0,
            .expected = "string",
            .got = dataToString(args[0]),
        } } },
    };

    const resolved_path = try resolveImportPath(raw_path, vm.module_dir, vm);
    defer vm.runtime.alloc.free(resolved_path);
    if (std.mem.endsWith(u8, resolved_path, ".so")) {
        const mods = try revo.ffi.loadC(vm, resolved_path);
        defer vm.runtime.alloc.free(mods);
        const t_id = try vm.tables.create();
        const tbl = try vm.tables.get(t_id);

        for (mods) |c_fn| {
            const fn_id = try vm.functions.create(.{ .c_function = c_fn });
            try tbl.putRaw(
                .{ .atom = try vm.internAtom(c_fn.name) },
                .{ .function = fn_id },
            );
        }
        return .okData(.{ .table = t_id });
    }

    if (vm.module_cache.get(resolved_path)) |cached| return .{ .ok = cached };
    if (vm.loading_modules.contains(resolved_path)) return error.CyclicImport;

    const source = try std.Io.Dir.cwd().readFileAlloc(
        vm.runtime.io,
        resolved_path,
        vm.runtime.alloc,
        std.Io.Limit.unlimited,
    );
    defer vm.runtime.alloc.free(source);

    const loading_key = try vm.runtime.alloc.dupe(u8, resolved_path);
    var loading_key_added = false;
    defer {
        if (loading_key_added) _ = vm.loading_modules.remove(loading_key);
        vm.runtime.alloc.free(loading_key);
    }
    try vm.loading_modules.put(loading_key, {});
    loading_key_added = true;

    const cache_key = try vm.runtime.alloc.dupe(u8, resolved_path);
    errdefer vm.runtime.alloc.free(cache_key);

    const result = vm.runModule(resolved_path, source) catch |err| {
        return if (err == error.OutOfMemory) error.OutOfMemory else err;
    };

    try vm.module_cache.put(cache_key, result);
    return .{ .ok = result };
}

fn resolveOsPath(raw_path: []const u8, base_dir: ?[]const u8, vm: *VM) ![]const u8 {
    if (std.mem.eql(u8, raw_path, "/dev/stdin")) return "/dev/stdin";
    return vm_path.resolve(raw_path, base_dir, vm.runtime.io, vm.runtime.alloc);
}

fn resolveImportPath(raw_path: []const u8, base_dir: ?[]const u8, vm: *VM) ![]const u8 {
    const resolved = try vm_path.resolve(raw_path, base_dir, vm.runtime.io, vm.runtime.alloc);
    errdefer vm.runtime.alloc.free(resolved);

    if (std.fs.path.extension(resolved).len != 0) return resolved;

    const with_ext = try vm_path.withDefaultExtension(resolved, "rv", vm.runtime.alloc);
    vm.runtime.alloc.free(resolved);
    return with_ext;
}

const RenderMode = enum { display, debug };

fn append_data(buf: *std.ArrayList(u8), val: Data, vm: *VM, mode: RenderMode) !void {
    switch (mode) {
        .display => {
            const mm = try vm.getMetamethod(val, "__display");
            if (mm) |m| {
                const rendered = call_unary_metamethod(m, val, vm);
                const str = switch (rendered) {
                    .ok => |r| switch (r) {
                        .string => |id| vm.stringValue(id),
                        else => "",
                    },
                    .err => "",
                };
                try buf.appendSlice(vm.runtime.alloc, str);
                return;
            }
            const mm2 = try vm.getMetamethod(val, "__tostring");
            if (mm2) |m| {
                const rendered = call_unary_metamethod(m, val, vm);
                const str = switch (rendered) {
                    .ok => |r| switch (r) {
                        .string => |id| vm.stringValue(id),
                        else => "",
                    },
                    .err => "",
                };
                try buf.appendSlice(vm.runtime.alloc, str);
                return;
            }
            try val.write(buf, vm, .display);
        },
        .debug => try val.write(buf, vm, .debug),
    }
}

pub fn call_unary_metamethod(mm: Data, val: Data, vm: *VM) NativeResult {
    return switch (mm) {
        .function => {
            const result = vm.callFunction(mm, &.{val}) catch |err| {
                // never crash host process on user-level metamethod failures
                return .other(@errorName(err));
            };
            return .{ .ok = result };
        },
        else => .errType(0, "function", @tagName(mm)),
    };
}

/// > sleep(ms: number) -> parked
/// sleeps current fiber for given milliseconds
/// parks fiber instead of blocking
pub fn sleep(args: []const Data, vm: *VM) !NativeResult {
    const ms: u64 = switch (args[0]) {
        .number => |n| blk: {
            if (!std.math.isFinite(n) or n < 0 or @floor(n) != n) return .errType(0, "non-negative integer", @tagName(args[0]));
            break :blk @as(u64, @intFromFloat(n));
        },
        else => return .errType(0, "number", @tagName(args[0])),
    };
    try vm.schedParkCurrentForSleepMS(ms);
    return .parked();
}

// metatable registration
pub const MethodKey = union(enum) {
    named: []const u8,
    core: revo.core_atoms,
};

pub const MethodDef = struct {
    key: MethodKey,
    func: NativeFunc,
};

pub fn registerMetatable(
    vm: *VM,
    comptime methods: []const MethodDef,
    prototype: Data,
) !void {
    const mt_id = try vm.tables.create();
    const mt = try vm.tables.get(mt_id);
    inline for (methods) |method| {
        const fn_id = try vm.functions.create(.{ .native = method.func });
        const key_atom = switch (method.key) {
            .named => |name| try vm.internAtom(name),
            .core => |atom| revo.core_atoms.atom_id(atom),
        };
        try mt.putRaw(.{ .atom = key_atom }, .{ .function = fn_id });
    }
    try vm.setMetatable(prototype, mt_id);
}

pub const NativeError = error{
    StackUnderflow,
    KeyDNE,
    StackOverflow,
    InvalidConstant,
    InvalidLocal,
    ConstantReassignment,
    WrongArity,
    TypeError,
    IncompatibleTypes,
    DivisionByZero,
    UndefinedVariable,
    NotAFunction,
    FrameUnderflow,
    PickedFromVoid,
    FunctionDNE,
    InvalidTable,
    InvalidTuple,
    ProgramEnd,
    Panic,
    AssertionFailed,
    OutOfMemory,
    mystery,
    ModuleNotFound,
    IoError,
    CyclicImport,
    ImportFailed,
    InvalidChannel,
    Parked,
    InvalidBytecode,
};

pub const NativeErrPayload = union(enum) {
    wrong_arity: struct { got: usize, expected: usize },
    type_error: struct { arg: ?usize, expected: []const u8, got: []const u8 },
    native_error: NativeError,
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
        return .{ .ok = .{ .atom = a.atom_id() } };
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
    inline for (@typeInfo(Data).@"union".fields) |field| {
        const func = struct {
            fn is_of(args: []const Data, _: *VM) !NativeResult {
                for (args) |arg| {
                    if (arg != @field(revo.memory.Type, field.name)) {
                        return .okBool(false);
                    }
                }
                return .okBool(true);
            }
        }.is_of;
        const id = try vm.functions.create(.{ .native = define(
            &[1]TypeSpec{@field(TypeSpec, field.name)},
            func,
        ) });
        const atom = try vm.internAtom(field.name ++ "?");
        try vm.globals.put(atom, .{ .function = id });
    }
    const is_number = struct {
        fn num(args: []const Data, _: *VM) !NativeResult {
            for (args) |arg| {
                if (arg != .number) return .okBool(false);
            }
            return .okBool(true);
        }
    }.num;
    const id = try vm.functions.create(.{ .native = define(&[_]TypeSpec{.number}, is_number) });
    const atom = try vm.internAtom("number?");
    try vm.globals.put(atom, .{ .function = id });
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
