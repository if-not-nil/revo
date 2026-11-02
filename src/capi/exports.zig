//
// callable functions for revo runtime interop
//
const builtin = @import("builtin");
const std = @import("std");

const revo = @import("revo");
const vm = @import("vm");
const VM = vm.VM;
const memory = vm.memory;
const Value = memory.Value;
const functions = vm.callable;
const RevoBinding = functions.RevoBinding;
const HostBinding = functions.HostBinding;
const HostFunc = revo.baselib.host.HostFunc;
const ParamType = revo.baselib.host.ParamType;

// for error/missing returns
const nil_val = Value.new.nil();

/// intern a byte slice, returns stable string id (0 on failure)
/// `ptr` is borrowed for the call only (not null-terminated)
/// , `len` is the byte count
pub export fn revo_intern(vm_ptr: *anyopaque, ptr: ?[*]const u8, len: usize) callconv(.c) u64 {
    // returns 0 on failure but safe because vm assigns ids starting at 1
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const slice = if (len == 0) "" else (ptr orelse return 0)[0..len];
    const id = v.strings.own(slice) catch return 0;
    return @intCast(id);
}

/// intern a byte slice as an atom, returns stable atom id (0 on failure)
pub export fn revo_intern_atom(vm_ptr: *anyopaque, ptr: ?[*]const u8, len: usize) callconv(.c) u64 {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const slice = if (len == 0) "" else (ptr orelse return 0)[0..len];
    const id = v.internAtom(slice) catch return 0;
    return @intCast(id);
}

/// look up a global variable by name, returns nil if missing
pub export fn revo_getglobal(vm_ptr: *anyopaque, name: ?[*]const u8, name_len: usize) callconv(.c) Value {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const name_slice = if (name_len == 0) "" else (name orelse return nil_val)[0..name_len];

    const value = v.getGlobal(name_slice) orelse
        return nil_val;

    // getGlobal returns :undef for missing names instead of null
    if (value.tag() == .atom and value.asAtom().? == @backingInt(revo.CoreAtoms.undef))
        return nil_val;

    return value;
}

/// set a global variable by name
pub export fn revo_setglobal(vm_ptr: *anyopaque, name: ?[*]const u8, name_len: usize, value: Value) callconv(.c) void {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const name_slice = if (name_len == 0) "" else (name orelse return)[0..name_len];

    v.setGlobal(name_slice, value) catch {};
}

/// create a new empty table, returns nil on failure
pub export fn revo_table_create(vm_ptr: *anyopaque) callconv(.c) Value {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tid = v.tables.create() catch
        return nil_val;
    return Value.new.table(tid);
}

/// total entries (array part + keyed entries), 0 for non-tables
pub export fn revo_table_len(vm_ptr: *anyopaque, table: Value) callconv(.c) u64 {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tid = table.asTable() orelse return 0;
    const tbl = v.tables.get(tid) catch return 0;
    return @intCast(tbl.count());
}

/// array-part length, 0 for non-tables
pub export fn revo_table_alen(vm_ptr: *anyopaque, table: Value) callconv(.c) u64 {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tid = table.asTable() orelse return 0;
    const tbl = v.tables.get(tid) catch return 0;
    return @intCast(tbl.array.items.len);
}

/// keyed entries length, 0 for non-tables
pub export fn revo_table_klen(vm_ptr: *anyopaque, table: Value) callconv(.c) u64 {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tid = table.asTable() orelse return 0;
    const tbl = v.tables.get(tid) catch return 0;
    return @intCast(tbl.hash.count);
}

/// metatable-aware read; true and `out` set when present
pub export fn revo_table_get(vm_ptr: *anyopaque, table: Value, key: Value, out: *Value) callconv(.c) bool {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tid = table.asTable() orelse return false;
    const tbl = v.tables.get(tid) catch return false;
    out.* = (tbl.get(key, v) catch return false) orelse return false;
    return true;
}

/// metatable-aware write; false on bad table or allocation failure
pub export fn revo_table_set(vm_ptr: *anyopaque, table: Value, key: Value, value: Value) callconv(.c) bool {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tid = table.asTable() orelse return false;
    const tbl = v.tables.get(tid) catch return false;
    tbl.put(tid, v, key, value) catch return false;
    return true;
}

/// delete a table entry, returns true if the key existed
pub export fn revo_table_remove(vm_ptr: *anyopaque, table: Value, key: Value) callconv(.c) bool {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tid = table.asTable() orelse return false;
    const tbl = v.tables.get(tid) catch return false;
    return tbl.remove(key, v);
}

/// array-part read by index; false when out of range
pub export fn revo_table_get_idx(vm_ptr: *anyopaque, table: Value, idx: u64, out: *Value) callconv(.c) bool {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tid = table.asTable() orelse return false;
    out.* = v.arrayGet(tid, @intCast(idx)) orelse return false;
    return true;
}

/// append to the array part; false on bad table or allocation failure
pub export fn revo_table_push(vm_ptr: *anyopaque, table: Value, value: Value) callconv(.c) bool {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tid = table.asTable() orelse return false;
    const tbl = v.tables.get(tid) catch return false;
    tbl.push(v.runtime.alloc, value) catch return false;
    return true;
}

/// construct an array table from items, nil on failure
pub export fn revo_table_from_items(vm_ptr: *anyopaque, count: u64, items: [*]const Value) callconv(.c) Value {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    return v.tableOfSlice(items[0..@as(usize, @intCast(count))]) catch nil_val;
}

/// name-keyed write (interns the name); false on bad table or failure
pub export fn revo_table_set_name(vm_ptr: *anyopaque, table: Value, name: ?[*]const u8, name_len: usize, value: Value) callconv(.c) bool {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tid = table.asTable() orelse return false;
    const name_slice = if (name_len == 0) "" else (name orelse return false)[0..name_len];
    v.putField(tid, name_slice, value) catch return false;
    return true;
}

/// name-keyed raw read; true and `out` set when present
pub export fn revo_table_get_name(vm_ptr: *anyopaque, table: Value, name: ?[*]const u8, name_len: usize, out: *Value) callconv(.c) bool {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const name_slice = if (name_len == 0) "" else (name orelse return false)[0..name_len];
    out.* = v.getField(table, name_slice) orelse return false;
    return true;
}

/// `{:ok, payload}` constructor for host results, nil on failure
pub export fn revo_ok(vm_ptr: *anyopaque, payload: Value) callconv(.c) Value {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    return v.resultTable(.ok, payload) catch nil_val;
}

/// `{:err, payload}` constructor for host results, nil on failure
pub export fn revo_err(vm_ptr: *anyopaque, payload: Value) callconv(.c) Value {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    return v.resultTable(.err, payload) catch nil_val;
}

/// whether the value is an `{:ok, ...}` table
pub export fn revo_is_ok(vm_ptr: *anyopaque, val: Value) callconv(.c) bool {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    return v.isOkTable(val);
}

/// whether the value is an `{:err, ...}` table
pub export fn revo_is_err(vm_ptr: *anyopaque, val: Value) callconv(.c) bool {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    return v.isErrTable(val);
}

/// payload of an `{:ok, ...}` table; false otherwise
pub export fn revo_ok_value(vm_ptr: *anyopaque, val: Value, out: *Value) callconv(.c) bool {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const parts = v.resultParts(val) orelse return false;
    if (parts.tag.asAtom() != revo.CoreAtoms.atomId(.ok)) return false;
    out.* = parts.payload orelse return false;
    return true;
}

/// call a revo function from c, returns false on type/resource error (max 16 args)
pub export fn revo_call(
    vm_ptr: *anyopaque,
    func: Value,
    argc: u64,
    argv: [*]const Value,
    out: *Value,
) callconv(.c) bool {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const callee = func;
    if (v.c_last_error) |m| {
        v.runtime.alloc.free(m);
        v.c_last_error = null;
    }

    // stack buffer avoids GC-triggering heap alloc, most revo functions have few args
    var buf: [16]Value = undefined;
    if (argc > 16) {
        v.c_last_error = v.runtime.alloc.dupeSentinel(u8, "max 16 args", 0) catch null;
        return false;
    }
    for (0..@as(usize, @intCast(argc))) |i|
        buf[i] = argv[i];

    const result = v.callFunctionParts(callee, null, buf[0..@as(usize, @intCast(argc))], null) catch |err| {
        const msg = v.runtime_message orelse v.panic_message orelse @errorName(err);
        v.c_last_error = v.runtime.alloc.dupeSentinel(u8, msg, 0) catch null;
        return false;
    };
    out.* = result;
    return true;
}

/// last failed `revo_call` message; empty when the last call worked
/// , valid until the next `revo_call` on the same vm
pub export fn revo_call_last_error(vm_ptr: *anyopaque) callconv(.c) [*:0]const u8 {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    return if (v.c_last_error) |m| m.ptr else "";
}

/// the name is borrowed, keep it static
/// empty name when len is 0 (name may be null then)
/// nil on null fn or allocation failure
pub export fn revo_cfunc_new(vm_ptr: *anyopaque, fn_ptr: ?*anyopaque, name: ?[*]const u8, name_len: usize) callconv(.c) Value {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const fp = fn_ptr orelse return nil_val;

    const cname: []const u8 = if (name_len == 0) "" else cname_blk: {
        // null name with nonzero len is a caller bug
        // fail as allocation failure
        const p = name orelse return nil_val;
        break :cname_blk p[0..name_len];
    };

    const id = v.callable.create(.{ .c_function = .{
        .name = cname,
        .fn_ptr = @ptrCast(@alignCast(fp)),
    } }) catch return nil_val;

    return Value.new.function(id);
}

/// return pointer to interned string data (null on failure, valid until next GC sweep)
pub export fn revo_string_data(vm_ptr: *anyopaque, id: u64) callconv(.c) ?[*]const u8 {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const slice = v.strings.get(@intCast(id)) catch return null;
    // pointer valid only until next GC sweep; caller must not hold across allocs
    return slice.ptr;
}

/// return byte length of an interned string (0 on failure)
pub export fn revo_string_length(vm_ptr: *anyopaque, id: u64) callconv(.c) usize {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const slice = v.strings.get(@intCast(id)) catch return 0;
    return slice.len;
}

/// wrap a raw ptr; caller owns it, gc ignores it
/// , low 48 bits only. null in, null out: `revo_is_opaque` first
pub export fn revo_opaque_new(ptr: ?*anyopaque) callconv(.c) Value {
    return Value.new.@"opaque"(ptr);
}

/// unwrap; null when not opaque and when wrapping null
pub export fn revo_opaque_ptr(val: Value) callconv(.c) ?*anyopaque {
    return val.asOpaque();
}

/// owned handles! caller ptr in a gc cell + a per-handle metatable
/// , cell frees at sweep, pointee never. nil on failure
pub export fn revo_resource_new(vm_ptr: *anyopaque, ptr: ?*anyopaque) callconv(.c) Value {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const id = v.resources.create(ptr) catch return nil_val;
    return Value.new.resource(id);
}

/// unwrap through the vm; null unless resource. null-ptr cells
/// unwrap null too, so `revo_is_resource` first when it matters
pub export fn revo_resource_ptr(vm_ptr: *anyopaque, val: Value) callconv(.c) ?*anyopaque {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const id = val.asResource() orelse return null;
    const cell = v.resources.get(id) catch return null;
    return cell.ptr;
}

/// stick a metatable on a handle, nil clears; false otherwise
/// , share one table per kind & you have named types
pub export fn revo_resource_setmetatable(vm_ptr: *anyopaque, ud: Value, mt: Value) callconv(.c) bool {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const id = ud.asResource() orelse return false;
    if (!v.resources.isValid(id)) return false;
    const mt_id: ?memory.TableID = if (mt.asTable()) |t| t else blk: {
        if (mt.asAtom()) |a| {
            if (a == revo.CoreAtoms.atomId(.nil)) break :blk null;
        }
        return false;
    };
    v.setResourceMetatable(id, mt_id) catch return false;
    return true;
}

/// read the metatable back; false unless one attached. same
/// table means same kind: that is your type check
pub export fn revo_resource_getmetatable(vm_ptr: *anyopaque, ud: Value, out: *Value) callconv(.c) bool {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const id = ud.asResource() orelse return false;
    const cell = v.resources.get(id) catch return false;
    const mt = cell.metatable orelse return false;
    out.* = Value.new.table(mt);
    return true;
}

/// pin a value past gc; registry id, 0 on failure
/// , nil pins to 0, 0 never valid, ids never reused
pub export fn revo_ref(vm_ptr: *anyopaque, val: Value) callconv(.c) u64 {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    if (val.asAtom()) |aid| {
        if (aid == revo.CoreAtoms.atomId(.nil)) return 0;
    }
    const id = v.c_ref_next;
    v.c_refs.put(id, val) catch return 0;
    v.c_ref_next +%= 1;
    if (v.c_ref_next == 0) v.c_ref_next = 1;
    return id;
}

/// release a pin once; noop on 0/unknown
pub export fn revo_unref(vm_ptr: *anyopaque, ref_id: u64) callconv(.c) void {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    _ = v.c_refs.remove(ref_id);
}

/// read back a pin; nil on 0/unknown/released
pub export fn revo_getref(vm_ptr: *anyopaque, ref_id: u64) callconv(.c) Value {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    return v.c_refs.get(ref_id) orelse nil_val;
}

/// reads like host arity errors: `wants N args, got M`
pub export fn revo_c_err_arity(vm_ptr: *anyopaque, got: u64, expected: u64) callconv(.c) c_int {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    v.setRuntimeMessageFmt("wants {d} args, got {d}", .{ expected, got }) catch {};
    return functions.c_err_arity;
}

/// `expected` is a c string, `got` renders through typeof
pub export fn revo_c_err_type(vm_ptr: *anyopaque, arg: u64, expected: [*:0]const u8, got: Value) callconv(.c) c_int {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    v.setRuntimeMessageFmt("arg {d}: wants {s}, got {s}", .{ arg, std.mem.span(expected), revo.baselib.typeof(got, v) }) catch {};
    return functions.c_err_type;
}

/// `msg` borrowed for the call only, copied before return
pub export fn revo_c_err_other(vm_ptr: *anyopaque, msg: [*:0]const u8) callconv(.c) c_int {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    v.setRuntimeMessage(std.mem.span(msg)) catch {};
    return functions.c_err_other;
}

/// run `func(table)` once when swept, errors swallowed
/// , leftovers at destroy; false unless table + function
/// , keep `func` reachable; explicit free unregisters
pub export fn revo_table_set_finalizer(vm_ptr: *anyopaque, table: Value, func: Value) callconv(.c) bool {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tid = table.asTable() orelse return false;
    if (func.asFunction() == null) return false;
    v.registerFinalizer(tid, func) catch return false;
    return true;
}

/// drop a pending finalizer; true only when one was there
pub export fn revo_table_remove_finalizer(vm_ptr: *anyopaque, table: Value) callconv(.c) bool {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tid = table.asTable() orelse return false;
    if (!v.hasFinalizer(tid)) return false;
    v.unregisterFinalizer(tid);
    return true;
}

/// register a shared lib's revo_bindings into the module table
pub fn loadC(vm_ptr: *VM, lib_path: []const u8) ![]functions.CFunction {
    if (builtin.target.os.tag == .wasi or builtin.target.os.tag == .freestanding) {
        std.debug.print("error: dynamic library loading is not supported on this platform\n", .{});
        return error.OsNotSupported;
    }

    var lib = try std.DynLib.open(lib_path);

    const bindings_ptr: [*]const RevoBinding = lib.lookup([*]const RevoBinding, "revo_bindings") orelse {
        // callers report this themselves (import names both symbols)
        return error.NoBindings;
    };

    var registered = try std.ArrayList(functions.CFunction).initCapacity(vm_ptr.runtime.alloc, 16);
    defer registered.deinit(vm_ptr.runtime.alloc);

    var i: usize = 0;
    while (i < 4096) : (i += 1) {
        const b = bindings_ptr[i];
        const name_ptr: ?[*:0]const u8 = @ptrCast(b.name);
        if (name_ptr == null) break;
        const fn_ptr: ?*const anyopaque = @ptrCast(b.fn_ptr);
        if (fn_ptr == null) return error.InvalidBinding;
        try registered.append(vm_ptr.runtime.alloc, .{
            .name = std.mem.span(name_ptr.?),
            .fn_ptr = @ptrCast(@alignCast(fn_ptr.?)),
        });
    }

    try vm_ptr.loaded_extensions.append(vm_ptr.runtime.alloc, lib);
    return try registered.toOwnedSlice(vm_ptr.runtime.alloc);
}

/// load a shared lib's `revo_bindings` as host functions
pub fn loadHost(vm_ptr: *VM, lib_path: []const u8) ![]HostFunc {
    if (builtin.target.os.tag == .wasi or builtin.target.os.tag == .freestanding) {
        return error.OsNotSupported;
    }

    var lib = try std.DynLib.open(lib_path);

    const bindings_ptr: [*]const HostBinding =
        lib.lookup([*]const HostBinding, "revo_native_bindings_ex") orelse {
            return error.NoBindings;
        };

    // process-lifetime, untracked by debug allocators (like the spec cache):
    // valid as long as the lib is loaded, which is forever
    const pa = std.heap.page_allocator;

    var registered = try std.ArrayList(HostFunc).initCapacity(vm_ptr.runtime.alloc, 16);
    defer registered.deinit(vm_ptr.runtime.alloc);

    var i: usize = 0;
    while (i < 4096) : (i += 1) {
        const b = bindings_ptr[i];
        const name_ptr: ?[*:0]const u8 = @ptrCast(b.name);
        if (name_ptr == null) break;
        const fn_ptr: ?*const anyopaque = @ptrCast(b.fn_ptr);
        if (fn_ptr == null) return error.InvalidBinding;
        const name = std.mem.span(name_ptr.?);

        // low 7 bits are the spec, high bit marks omittable trailing args, end terminates
        //
        // required count is the first marked slot
        var decoded: [16]ParamType = undefined;
        var count: usize = 0;
        var required: ?usize = null;

        for (b.param_types) |tag| {
            if (tag == HostBinding.end) break;
            if (required == null and tag & HostBinding.optional != 0) required = count;
            decoded[count] = ParamType.fromTag(tag & 0x7F);
            count += 1;
        }

        const min: usize = required orelse count;
        const unbounded = b.total_arity == HostBinding.unbounded;
        if (!unbounded and b.total_arity < count) return error.InvalidBinding;
        const max: usize = if (unbounded) min else b.total_arity;

        try registered.append(vm_ptr.runtime.alloc, .{
            .name = name,
            .arity = min,
            .total_arity = if (max == min) 0 else max,
            .variadic = unbounded,
            .param_types = try pa.dupe(ParamType, decoded[0..count]),
            .func = @ptrCast(@alignCast(fn_ptr.?)),
        });
    }

    try vm_ptr.loaded_extensions.append(vm_ptr.runtime.alloc, lib);
    return try registered.toOwnedSlice(vm_ptr.runtime.alloc);
}
