const std = @import("std");

const revo = @import("../root.zig");
const mem = revo.memory;
const specs = @import("specs.zig");

const Value = mem.Value;
const VM = revo.VM;

pub const HostFn = *const fn (args: []const Value, vm: *VM) anyerror!HostResult;
pub const HostFunc = struct {
    name: []const u8 = "",
    arity: usize,
    total_arity: usize = 0,
    variadic: bool = false,
    param_types: []const ParamType,
    ret_type: ParamType = .any,
    func: HostFn,
};

pub fn define(
    comptime types: []const ParamType,
    impl: HostFn,
) HostFunc {
    return .{
        .arity = types.len,
        .param_types = types,
        .func = impl,
    };
}

pub fn defineVariadic(
    comptime types: []const ParamType,
    impl: HostFn,
) HostFunc {
    return .{
        .arity = types.len,
        .variadic = true,
        .param_types = types,
        .func = impl,
    };
}

pub fn Args(comptime params: []const ParamType) type {
    const types: [params.len]type = comptime blk: {
        var result: [params.len]type = undefined;
        for (params, 0..) |spec, i| {
            result[i] = paramToType(spec);
        }
        break :blk result;
    };
    return @Tuple(&types);
}

pub fn paramToType(comptime spec: ParamType) type {
    return switch (spec) {
        .number => ArgTypes.number,
        .string => ArgTypes.string,
        .atom => ArgTypes.atom,
        .function => ArgTypes.function,
        .table => ArgTypes.table,
        .resource => ArgTypes.resource,
        .bool => bool,
        .any => Value,
    };
}

pub fn unwrapArgs(comptime params: []const ParamType, args: []const Value) Args(params) {
    var result: Args(params) = undefined;
    inline for (params, 0..) |spec, i| {
        result[i] = switch (spec) {
            .number => args[i].asNumOpt().?,
            .string => args[i].asString().?,
            .atom => args[i].asAtom().?,
            .function => args[i].asFunction().?,
            .table => args[i].asTable().?,
            .resource => args[i].asResource().?,
            .bool => args[i].asAtom().?,
            .any => args[i],
        };
    }
    return result;
}
pub const Outcome = enum { ok, err };

/// the typed parameter vocab; `ArgTypes` maps zig types onto these
pub const ParamType = union(enum) {
    number,
    string,
    atom,
    function,
    table,
    resource,
    bool,
    any,

    pub fn matches(self: ParamType, data: Value) bool {
        return switch (self) {
            .any => true,
            .number => data.isNumber(),
            .bool => if (data.asAtom()) |a| isBoolAtom(a) else false,
            .string => data.isString(),
            .atom => data.isAtom(),
            .function => data.isFunction(),
            .table => data.isTable(),
            .resource => data.isResource(),
        };
    }

    /// module table name for primitive method targets (`string:len` goes
    /// in `string`); null for the rest. single source for this mapping.
    pub fn moduleName(self: ParamType) ?[]const u8 {
        return switch (self) {
            .number => "number",
            .string => "string",
            .table => "table",
            else => null,
        };
    }

    /// stable tag for crossing the extension boundary in
    /// `HostBinding.param_types` (low 7 bits; the high bit and `end`
    /// live on `HostBinding`)
    pub fn toTag(self: ParamType) u8 {
        return switch (self) {
            .number => 0,
            .string => 1,
            .atom => 2,
            .function => 3,
            .table => 4,
            .resource => 7,
            .bool => 5,
            .any => 6,
        };
    }

    /// inverse of `toTag` over the low 7 bits
    ///
    /// unknown tags map to `.any`
    /// so a newer extension never hard-fails an older host
    /// , it just type-checks looser
    pub fn fromTag(t: u8) ParamType {
        return switch (t) {
            0 => .number,
            1 => .string,
            2 => .atom,
            3 => .function,
            4 => .table,
            5 => .bool,
            7 => .resource,
            else => .any,
        };
    }
};

/// lookup `key` in the module table named `name`; null when the module
/// or key is absent. untyped method receivers fall back here via the
/// type metatable's `__index` chain
fn isBoolAtom(atom: mem.AtomID) bool {
    const true_id = revo.CoreAtoms.atomId(.true);
    const false_id = revo.CoreAtoms.atomId(.false);
    return atom == true_id or atom == false_id;
}

/// converts a number to an integer of type ArgTypes; null when the value is not a
/// finite integral number representable in ArgTypes
pub const numToInt = revo.vm.memory.numToInt;

fn makeResult(vm: *VM, comptime tag: Outcome, value: Value) !HostResult {
    const atom: revo.CoreAtoms = switch (tag) {
        .ok => .ok,
        .err => .err,
    };
    return .data(try vm.resultTable(atom, value));
}

pub inline fn boolValue(value: bool) Value {
    return if (value) revo.Value.new.core(.true) else revo.Value.new.core(.false);
}

pub const HostErrPayload = union(enum) {
    wrong_arity: struct { got: usize, expected: usize },
    type_error: struct { arg: ?usize, expected: []const u8, got: []const u8 },
    host_error: revo.vm.RunError,
    parked: void,
    module_not_found: void,
    cyclic_import: void,
    import_failed: []const u8,
    assertion_failed: []const u8,
    io_error: []const u8,
    other: []const u8,
};

/// the return convention: `.ok` carries a value, `.err` carries a shape
/// , `parked` suspends the fiber instead of returning
pub const HostResult = union(enum) {
    ok: Value,
    err: HostErrPayload,

    pub fn _bool(b: bool) HostResult {
        return .{ .ok = Value.new.boolean(b) };
    }

    pub fn data(d: Value) HostResult {
        return .{ .ok = d };
    }

    pub fn coreAtom(a: revo.CoreAtoms) HostResult {
        return .{ .ok = Value.new.atom(@backingInt(a)) };
    }

    pub fn Ok(vm: *VM, value: Value) !HostResult {
        return makeResult(vm, .ok, value);
    }

    pub fn Err(vm: *VM, err_name: []const u8) !HostResult {
        const tag = try vm.internAtom(err_name);
        return makeResult(vm, .err, Value.new.atom(tag));
    }

    pub fn errValue(vm: *VM, value: Value) !HostResult {
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

pub fn wasm_stub(_: []const Value, _: *VM) anyerror!HostResult {
    return .other("function unavailable on this platform");
}

pub fn defineStub(comptime types: []const ParamType) HostFunc {
    return .{
        .arity = types.len,
        .variadic = false,
        .param_types = types,
        .func = wasm_stub,
    };
}

pub fn defineStubVariadic(comptime types: []const ParamType) HostFunc {
    return .{
        .arity = types.len,
        .variadic = true,
        .param_types = types,
        .func = wasm_stub,
    };
}
//
// module wrappers
//

/// for use in impl fn signatures: `fn foo(vm: *VM, self: Args.string) !HostResult`
/// made nominal
pub const ArgTypes = struct {
    pub const string = enum(mem.StringID) { _ };
    pub const number = f64;
    pub const atom = enum(mem.AtomID) { _ };
    pub const function = enum(mem.FunctionID) { _ };
    pub const table = enum(mem.TableID) { _ };
    pub const resource = enum(mem.ResourceID) { _ };
    pub const any = Value;

    /// optional table parameter
    pub const table_sentinel = Optional(.table, @as(ArgTypes.table, @fromBackingInt(@intCast(0))));

    /// usage: `ArgTypes.Optional(.bool, false)`, `ArgTypes.Optional(.number, 10.0)`
    pub fn Optional(comptime spec: ParamType, comptime default_val: anytype) type {
        const VT = switch (spec) {
            .bool => bool,
            else => paramToType(spec),
        };
        return extern struct {
            pub const inner_spec = spec;
            pub const default_value: VT = default_val;
            value: VT,
        };
    }
};

/// reverse mapping
/// distinct ArgTypes type -> ParamType variant
pub fn typeToParam(comptime P: type) ParamType {
    if (isOptional(P)) return P.inner_spec; // unwrap Optional
    if (P == ArgTypes.string) return .string;
    if (P == ArgTypes.number) return .number;
    if (P == ArgTypes.atom) return .atom;
    if (P == ArgTypes.function) return .function;
    if (P == ArgTypes.table) return .table;
    if (P == ArgTypes.resource) return .resource;
    if (P == bool) return .bool;
    if (P == Value) return .any;
    @compileError("unsupported type in def: " ++ @typeName(P));
}

/// unwrap one Value arg into the typed value the impl fn expects
pub fn unwrapArg(comptime spec: ParamType, data: Value) paramToType(spec) {
    return switch (spec) {
        .number => data.asNumOpt().?,
        .string => @fromBackingInt(@intCast(data.asString().?)),
        .atom => @fromBackingInt(@intCast(data.asAtom().?)),
        .function => @fromBackingInt(@intCast(data.asFunction().?)),
        .table => @fromBackingInt(@intCast(data.asTable().?)),
        .resource => @fromBackingInt(@intCast(data.asResource().?)),
        .bool => data.asAtom().? == revo.CoreAtoms.atomId(.true),
        .any => data,
    };
}

/// inspects fn signature at comptime, derives ParamType array, generates unwrapping wrapper
pub fn def(comptime impl: anytype) HostFunc {
    const fn_info = @typeInfo(@TypeOf(impl)).@"fn";
    comptime {
        if (fn_info.param_types.len < 1) @compileError("def requires (vm, ...) signature");
        if (fn_info.param_types[0].? != *VM) @compileError("first param must be *VM");
    }
    const count = fn_info.param_types.len - 1;
    const Storage = struct {
        pub const specs: [count]ParamType = blk: {
            var result: [count]ParamType = undefined;
            for (fn_info.param_types[1..], 0..) |param, i| {
                result[i] = typeToParam(param.?);
            }
            break :blk result;
        };
        pub const required_count: usize = blk: {
            var n: usize = 0;
            for (fn_info.param_types[1..]) |param| {
                if (!isOptional(param.?)) n += 1;
            }
            break :blk n;
        };
        pub const all_types: [count + 1]type = blk: {
            var result: [count + 1]type = undefined;
            result[0] = *VM;
            for (fn_info.param_types[1..], 0..) |param, i| {
                result[i + 1] = param.?;
            }
            break :blk result;
        };
        pub const FullArgs = @Tuple(&all_types);
    };

    const has_optionals = Storage.required_count < count;
    return .{
        .arity = Storage.required_count,
        .total_arity = if (has_optionals) count else 0,
        .param_types = &Storage.specs,
        .func = struct {
            fn call(raw: []const Value, vm: *VM) anyerror!HostResult {
                var args: Storage.FullArgs = undefined;
                args[0] = vm;
                inline for (Storage.specs, 0..) |spec, i| {
                    const P = fn_info.param_types[i + 1].?;
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
            fn getDefault(comptime i: usize, vm: *VM) !fn_info.param_types[i + 1].? {
                const OptionalType = fn_info.param_types[i + 1].?;
                const default = OptionalType.default_value;
                const spec = Storage.specs[i];
                const inner = switch (spec) {
                    .string => @as(ArgTypes.string, @fromBackingInt(@intCast(try vm.strings.own(default)))),
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
        for (@typeInfo(S).@"struct".decl_names) |decl_name| {
            if (@typeInfo(@TypeOf(@field(S, decl_name))) == .@"fn") c += 1;
        }
        return c;
    }
}

/// generic struct -> impls array
/// iterates pub fn decls in the struct,
/// derives ParamTypes from each fn's parameter types, wraps with def()
///
/// the registered name is the full decl name, so `@"fs.stat"` pairs
/// with the `fs.stat` spec by head instead of by position
pub fn impls(comptime ImplType: type) type {
    const decl_names = @typeInfo(ImplType).@"struct".decl_names;
    const count = countFn(ImplType);
    return struct {
        pub const impls_list: [count]specs.Impl = blk: {
            var result: [count]specs.Impl = undefined;
            var i: usize = 0;
            for (decl_names) |decl_name| {
                const f = @field(ImplType, decl_name);
                if (@typeInfo(@TypeOf(f)) == .@"fn") {
                    result[i] = .{ .name = decl_name, .f = def(f) };
                    i += 1;
                }
            }
            break :blk result;
        };
        pub const val: *const [count]specs.Impl = &impls_list;
    };
}

test "resource param type" {
    const t = std.testing;
    const r: ParamType = .resource;
    try t.expect(ParamType.fromTag(@as(u8, 7)) == .resource);
    try t.expect(r.toTag() == 7);
    const r_param = comptime typeToParam(ArgTypes.resource);
    try t.expect(r_param == .resource);
    try t.expect(r.matches(Value.new.resource(0)));
    try t.expect(!r.matches(Value.new.num(1)));
}
