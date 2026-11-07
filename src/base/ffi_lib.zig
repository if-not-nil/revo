//
// ffi: dynamic c calls behind a posix-only flag
//
// declare-by-api, no parser :(
//
// `ffi.func` builds a libffi cif from revo atoms
// , the handle calls through `__call`
// . cdata is `resource` handles
// ; strings copy, never borrow
//

const builtin = @import("builtin");
const std = @import("std");

const c = @import("c_ffi");
const revo = @import("../root.zig");
const Value = revo.Value;
const VM = revo.VM;
const root = @import("root.zig");
const HostResult = root.host.HostResult;
const Args = root.host.ArgTypes;
const fdesc = @import("ffi.zig");

extern "c" fn __errno_location() *c_int;
extern "c" fn __error() *c_int;
extern "c" fn __errno() *c_int;

const max_args = 16;
const type_names = "i32|u32|i64|u64|f32|f64|bool|ptr|void|string";

const Kind = enum(u8) { lib, func, ptr };

const Box = struct {
    kind: Kind,
    lib_index: usize = 0,
    sym: ?*anyopaque = null,
    ptr: ?*anyopaque = null,

    ret: fdesc.FfiType = .void,
    nargs: usize = 0,
    fixed: usize = 0,

    arg_t: [max_args]*c.ffi_type = undefined,
    types: [max_args]fdesc.FfiType = @splat(.void),
    cif: c.ffi_cif = std.mem.zeroes(c.ffi_cif),
};

fn boxOf(vm: *VM, val: Value, want: Kind) ?*Box {
    const id = val.asResource() orelse return null;
    const cell = vm.resources.get(id) catch return null;
    const box: *Box = @ptrCast(@alignCast(cell.ptr orelse return null));
    if (box.kind != want) return null;
    return box;
}

fn toFfiType(t: fdesc.FfiType) *c.ffi_type {
    return @constCast(switch (t) {
        .i32 => &c.ffi_type_sint32,
        .u32 => &c.ffi_type_uint32,
        .i64 => &c.ffi_type_sint64,
        .u64 => &c.ffi_type_uint64,
        .f32 => &c.ffi_type_float,
        .f64 => &c.ffi_type_double,
        .boolean => &c.ffi_type_uint8,
        .ptr, .string => &c.ffi_type_pointer,
        .void => &c.ffi_type_void,
    });
}

fn parseType(vm: *VM, val: Value) ?fdesc.FfiType {
    const aid = val.asAtom() orelse return null;
    return fdesc.FfiType.fromAtom(vm, aid);
}

fn prepCif(box: *Box) !void {
    for (box.types[0..box.nargs], 0..) |t, i| box.arg_t[i] = toFfiType(t);

    const status = if (box.fixed == box.nargs)
        c.ffi_prep_cif(
            &box.cif,
            c.FFI_DEFAULT_ABI,
            @intCast(box.nargs),
            toFfiType(box.ret),
            @ptrCast(&box.arg_t),
        )
    else
        c.ffi_prep_cif_var(
            &box.cif,
            c.FFI_DEFAULT_ABI,
            @intCast(box.fixed),
            @intCast(box.nargs),
            toFfiType(box.ret),
            @ptrCast(&box.arg_t),
        );
    if (status != c.FFI_OK) return error.FfiPrepFailed;
}

/// shared `__call`:
///
///   args[0] is the handle, the rest marshal by decl
///
/// surplus varargs infer from values
/// (same as luajit: numbers go as doubles, box explicitly to pass anything else)
fn ffiCallFn(args: []const Value, vm: *VM) !HostResult {
    const box = boxOf(vm, args[0], .func) orelse
        return .errType(0, "ffi func handle", root.typeof(args[0], vm));
    if (args.len - 1 != box.nargs) return .errArity(args.len - 1, box.nargs);

    var vtypes: [max_args]fdesc.FfiType = box.types;
    var varg_t: [max_args]*c.ffi_type = undefined;
    var use_cif = &box.cif;
    var stack_cif: c.ffi_cif = undefined;
    if (box.nargs > box.fixed) {
        for (box.fixed..box.nargs) |i| {
            const a = args[i + 1];
            vtypes[i] = if (a.isNumber())
                .f64
            else if (a.asAtom()) |id| blk: {
                if (id == revo.CoreAtoms.atomId(.true) or
                    id == revo.CoreAtoms.atomId(.false)) break :blk .boolean;
                if (id == revo.CoreAtoms.atomId(.nil)) break :blk .ptr;
                return .errType(i + 1, "vararg value", root.typeof(a, vm));
            } else if (a.isString() or a.isOpaque() or a.isResource())
                .ptr
            else
                return .errType(i + 1, "vararg value", root.typeof(a, vm));
        }
        for (vtypes[0..box.nargs], 0..) |t, i| varg_t[i] = toFfiType(t);
        const status = c.ffi_prep_cif_var(
            &stack_cif,
            c.FFI_DEFAULT_ABI,
            @intCast(box.fixed),
            @intCast(box.nargs),
            toFfiType(box.ret),
            @ptrCast(&varg_t),
        );
        if (status != c.FFI_OK) return .other("ffi_prep_cif failed");
        use_cif = &stack_cif;
    }

    var slots: [max_args]u64 = @splat(0);
    var ptrs: [max_args]?*anyopaque = @splat(null);
    var strbufs: [max_args][]u8 = undefined;
    var nstr: usize = 0;
    defer for (strbufs[0..nstr]) |s| vm.runtime.alloc.free(s);

    for (vtypes[0..box.nargs], 0..) |t, i| {
        const a = args[i + 1];

        // surplus strings go as copied NUL, like luajit varargs
        const tt = if (i >= box.fixed and t == .ptr and a.isString()) .string else t;
        switch (tt) {
            .i32 => slots[i] = @as(u64, @bitCast(@as(
                i64,
                fdesc.valueToInt(i32, a) orelse return .errType(i + 1, "i32", root.typeof(a, vm)),
            ))),
            .u32 => slots[i] = fdesc.valueToInt(u32, a) orelse return .errType(
                i + 1,
                "u32",
                root.typeof(a, vm),
            ),
            .i64 => slots[i] = @as(u64, @bitCast(
                fdesc.valueToInt(i64, a) orelse return .errType(i + 1, "i64", root.typeof(a, vm)),
            )),
            .u64 => slots[i] = fdesc.valueToInt(u64, a) orelse return .errType(
                i + 1,
                "u64",
                root.typeof(a, vm),
            ),
            .f32 => slots[i] = @as(u64, @as(u32, @bitCast(@as(
                f32,
                @floatCast(a.asNumOpt() orelse return .errType(i + 1, "f32", root.typeof(a, vm))),
            )))),
            .f64 => slots[i] = @bitCast(a.asNumOpt() orelse return .errType(
                i + 1,
                "f64",
                root.typeof(a, vm),
            )),
            .boolean => slots[i] = if (fdesc.valueToBool(a) orelse return .errType(
                i + 1,
                "bool",
                root.typeof(a, vm),
            )) 1 else 0,
            .ptr => slots[i] = ptrArg(vm, a) catch |e| return switch (e) {
                error.NotAPointer => .errType(i + 1, "pointer", root.typeof(a, vm)),
                error.DeadHandle => .errType(i + 1, "live handle", root.typeof(a, vm)),
                error.WrongKind => .errType(
                    i + 1,
                    "pointer (lib/func handles don't cross)",
                    root.typeof(a, vm),
                ),
            },
            .string => {
                const sid = a.asString() orelse
                    return .errType(i + 1, "string", root.typeof(a, vm));
                const bytes = vm.stringValue(sid);
                const z = try vm.runtime.alloc.dupeSentinel(u8, bytes, 0);
                strbufs[nstr] = z.ptr[0 .. z.len + 1];
                nstr += 1;
                slots[i] = @intFromPtr(z.ptr);
            },
            .void => return .errType(i + 1, "value", "void"),
        }
        ptrs[i] = @ptrCast(&slots[i]);
    }

    // gc stays suppressed under host_call_depth; borrowed slots get died here
    var retbuf: u64 = 0;
    c.ffi_call(use_cif, @ptrCast(@alignCast(box.sym.?)), &retbuf, &ptrs);
    vm.ffi_errno = switch (builtin.target.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos, .freebsd => __error().*,
        .openbsd, .netbsd => __errno().*,
        else => __errno_location().*,
    };

    return switch (box.ret) {
        .void => .data(Value.new.nil()),
        .i32 => .data(
            Value.new.num(@as(f64, @floatFromInt(@as(*const i32, @ptrCast(&retbuf)).*))),
        ),
        .u32 => .data(
            Value.new.num(@as(f64, @floatFromInt(@as(*const u32, @ptrCast(&retbuf)).*))),
        ),
        .u64 => .data(
            fdesc.valueFromInt(@as(*const u64, @ptrCast(&retbuf)).*) orelse
                return .other("u64 result exceeds f64 range"),
        ),
        .i64 => .data(
            fdesc.valueFromInt(@as(*const i64, @ptrCast(&retbuf)).*) orelse
                return .other("i64 result exceeds f64 range"),
        ),
        .f32 => .data(Value.new.num(@as(f64, @as(*const f32, @ptrCast(&retbuf)).*))),
        .f64 => .data(Value.new.num(@as(*const f64, @ptrCast(&retbuf)).*)),
        .boolean => .data(Value.new.boolean(@as(*const u8, @ptrCast(&retbuf)).* != 0)),
        .ptr => .data(try ptrReturn(vm, @as(*const ?*anyopaque, @ptrCast(&retbuf)).*)),
        .string => .data(Value.new.str(try vm.strings.own(
            std.mem.span(@as(*const [*:0]const u8, @ptrCast(&retbuf)).*),
        ))),
    };
}

/// nil -> NULL, opaque bits + ptr-kind cells unwrap
/// ; stale ids + lib/func boxes die loud
/// : the handle was collectable, so the caller pinned nothing
const PtrErr = error{ NotAPointer, DeadHandle, WrongKind };

fn ptrArg(vm: *VM, a: Value) PtrErr!u64 {
    if (a.asAtom()) |id| {
        if (id == revo.CoreAtoms.atomId(.nil)) return 0;
    }
    if (a.asOpaque()) |p| return @intFromPtr(p);
    const id = a.asResource() orelse return error.NotAPointer;
    const cell = vm.resources.get(id) catch return error.DeadHandle;
    const box: *const Box = @ptrCast(@alignCast(cell.ptr orelse return error.DeadHandle));
    if (box.kind == .ptr) return @intFromPtr(box.ptr orelse return 0);
    return error.WrongKind;
}

fn ptrReturn(vm: *VM, p: ?*anyopaque) !Value {
    const box = try vm.runtime.alloc.create(Box);
    errdefer vm.runtime.alloc.destroy(box);
    box.* = .{ .kind = .ptr, .ptr = p };
    const id = try vm.resources.create(box);
    return Value.new.resource(id);
}

/// frees the box; libs stay open til destroy via loaded_extensions
fn ffiFreeFn(args: []const Value, vm: *VM) !HostResult {
    const id = args[0].asResource() orelse return .data(Value.new.nil());
    const cell = vm.resources.get(id) catch return .data(Value.new.nil());
    if (cell.ptr) |p| {
        const box: *Box = @ptrCast(@alignCast(p));
        vm.runtime.alloc.destroy(box);
        cell.ptr = null;
    }
    return .data(Value.new.nil());
}

fn installMt(vm: *VM, id: revo.memory.ResourceID, call: bool) !Value {
    const mt = try vm.tables.create();
    const tbl = try vm.tables.get(mt);
    if (call) {
        const call_id = try vm.installHost("__ffi_call", .{
            .arity = 1,
            .param_types = &.{.any},
            .func = ffiCallFn,
            .variadic = true,
            .ret_type = .any,
        });
        try tbl.putRawAtom(revo.CoreAtoms.atomId(.__call), Value.new.function(call_id), vm);
    }

    const free_id = try vm.installHost("__ffi_free", .{
        .arity = 1,
        .param_types = &.{.any},
        .func = ffiFreeFn,
        .variadic = false,
        .ret_type = .any,
    });
    try tbl.putRawAtom(revo.CoreAtoms.atomId(.__gc), Value.new.function(free_id), vm);

    try vm.setResourceMetatable(id, mt);
    return Value.new.table(mt);
}

/// DlDynLib backend check, mocks std's InnerType selection
const self_dlopen_ok = switch (builtin.os.tag) {
    .linux => builtin.link_libc and !(builtin.abi == .musl and builtin.link_mode == .static),
    .driverkit,
    .ios,
    .maccatalyst,
    .macos,
    .tvos,
    .visionos,
    .watchos,
    .freebsd,
    .netbsd,
    .openbsd,
    .dragonfly,
    .illumos,
    => true,
    else => false,
};

fn finishLoad(vm: *VM, lib: std.DynLib) !HostResult {
    var owned = lib;
    errdefer owned.close();

    const box = try vm.runtime.alloc.create(Box);
    var live = false;
    errdefer if (!live) vm.runtime.alloc.destroy(box);
    box.* = .{ .kind = .lib, .lib_index = vm.loaded_extensions.items.len };
    const id = try vm.resources.create(box);
    live = true;
    try vm.loaded_extensions.append(vm.runtime.alloc, owned);

    _ = try installMt(vm, id, false);
    return .data(Value.new.resource(id));
}

pub const Impl = struct {
    pub fn load(vm: *VM, path: Args.string) !HostResult {
        const bytes = vm.stringValue(@backingInt(path));

        // empty path opens the process itself
        //   (libc is here on every posix target, no paths to guess)
        if (bytes.len == 0) {
            if (!self_dlopen_ok) return .errImportFailed("self unsupported here");
            const handle = std.c.dlopen(null, .{ .NOW = true }) orelse
                return .errImportFailed("dlopen self");
            return finishLoad(vm, .{ .inner = .{ .handle = handle } });
        }

        const zpath = try vm.runtime.alloc.dupeSentinel(u8, bytes, 0);
        defer vm.runtime.alloc.free(zpath);
        var lib = std.DynLib.open(zpath) catch |err| return .errImportFailed(@errorName(err));
        errdefer lib.close();
        return finishLoad(vm, lib);
    }

    pub fn func(
        vm: *VM,
        lib: Args.any,
        name: Args.string,
        ret: Args.atom,
        args: Args.table,
    ) !HostResult {
        return declare(vm, lib, name, ret, args, null);
    }

    pub fn varfunc(
        vm: *VM,
        lib: Args.any,
        name: Args.string,
        ret: Args.atom,
        fixed: Args.table,
        total: Args.number,
    ) !HostResult {
        const n = fdesc.valueToInt(usize, Value.new.num(total)) orelse
            return .errType(4, "arg count", root.typeof(Value.new.num(total), vm));
        return declare(vm, lib, name, ret, fixed, n);
    }

    pub fn errno(vm: *VM) !HostResult {
        return .data(Value.new.num(vm.ffi_errno));
    }
};

fn declare(
    vm: *VM,
    lib_v: Value,
    name_v: Args.string,
    ret_v: Args.atom,
    args_v: Args.table,
    total: ?usize,
) !HostResult {
    const lib_id = lib_v.asResource() orelse
        return .errType(0, "ffi lib handle", root.typeof(lib_v, vm));
    const lib_cell = vm.resources.get(lib_id) catch
        return .errType(0, "ffi lib handle", root.typeof(lib_v, vm));
    const lib_box: *const Box = @ptrCast(@alignCast(
        lib_cell.ptr orelse return .errType(0, "ffi lib handle", root.typeof(lib_v, vm)),
    ));

    if (lib_box.kind != .lib) return .errType(0, "ffi lib handle", root.typeof(lib_v, vm));
    const lib = &vm.loaded_extensions.items[lib_box.lib_index];

    const name = vm.stringValue(@backingInt(name_v));
    const zname = try vm.runtime.alloc.dupeSentinel(u8, name, 0);
    defer vm.runtime.alloc.free(zname);
    const sym = lib.lookup(*anyopaque, zname) orelse return .errImportFailed("symbol not found");

    const ret_atom = Value.new.atom(@backingInt(ret_v));
    const ret = parseType(vm, ret_atom) orelse
        return .errType(2, type_names, root.typeof(ret_atom, vm));

    const arg_tid = @backingInt(args_v);
    const arg_tbl = try vm.tables.get(arg_tid);
    const nargs = arg_tbl.array.items.len;
    const total_n = total orelse nargs;
    if (total_n < nargs) return .errType(
        4,
        "total >= fixed",
        root.typeof(Value.new.num(@as(f64, @floatFromInt(total_n))), vm),
    );
    if (total_n > max_args) return .other("ffi: max 16 args");

    const box = try vm.runtime.alloc.create(Box);
    var live = false;
    errdefer if (!live) vm.runtime.alloc.destroy(box);
    box.* = .{ .kind = .func, .sym = sym, .ret = ret, .nargs = total_n, .fixed = nargs };
    for (0..nargs) |i| {
        const a = vm.arrayGet(arg_tid, i) orelse return .errType(3, "type atoms", "short table");
        box.types[i] = parseType(vm, a) orelse return .errType(3, type_names, root.typeof(a, vm));
    }

    // variadic surplus infers from values per call
    // ; fixed decls prep now
    if (box.fixed == box.nargs) prepCif(box) catch return .other("ffi_prep_cif failed");
    const id = try vm.resources.create(box);
    live = true;

    _ = try installMt(vm, id, true);
    return .data(Value.new.resource(id));
}

pub const impls: []const root.specs.Impl = &.{
    .{ .name = "load", .f = root.host.def(Impl.load) },
    .{ .name = "func", .f = root.host.def(Impl.func) },
    .{ .name = "varfunc", .f = root.host.def(Impl.varfunc) },
    .{ .name = "errno", .f = root.host.def(Impl.errno) },
};
