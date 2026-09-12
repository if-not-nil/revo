//
// callable functions for revo runtime interop
//
const std = @import("std");
const builtin = @import("builtin");

const revo = @import("revo");
const vm = @import("vm");
const VM = vm.VM;
const memory = vm.memory;
const Data = memory.Data;
const functions = vm.functions;
const RevoBinding = functions.RevoBinding;
const HostBinding = functions.HostBinding;
const CFnPtr = functions.CFnPtr;
const HostFn = functions.HostFn;
const HostFunc = revo.std_lib.HostFunc;

// for error/missing returns
const nil_val = Data.new.nil();

/// intern a byte slice, returns stable string id (0 on failure)
pub export fn revo_intern(vm_ptr: *anyopaque, ptr_val: u64, len: usize) callconv(.c) u64 {
    // returns 0 on failure but safe because vm assigns ids starting at 1
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const ptr: [*]u8 = @ptrFromInt(@as(usize, @intCast(ptr_val)));
    const slice = ptr[0..len];
    const id = v.strings.own(slice) catch return 0;
    return @intCast(id);
}

/// intern a byte slice as an atom, returns stable atom id (0 on failure)
pub export fn revo_intern_atom(vm_ptr: *anyopaque, ptr_val: u64, len: usize) callconv(.c) u64 {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const ptr: [*]u8 = @ptrFromInt(@as(usize, @intCast(ptr_val)));
    const slice = ptr[0..len];
    const id = v.internAtom(slice) catch return 0;
    return @intCast(id);
}

/// look up a global variable by name, returns nil if missing
pub export fn revo_getglobal(vm_ptr: *anyopaque, name_ptr: u64, name_len: usize) callconv(.c) Data {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const ptr: [*]u8 = @ptrFromInt(@as(usize, @intCast(name_ptr)));
    const name_slice = ptr[0..name_len];

    const value = v.getGlobal(name_slice) orelse
        return nil_val;

    // getGlobal returns :undef for missing names instead of null
    if (value.tag() == .atom and value.asAtom().? == @intFromEnum(revo.core_atoms.undef))
        return nil_val;

    return value;
}

/// set a global variable by name
pub export fn revo_setglobal(vm_ptr: *anyopaque, name_ptr: u64, name_len: usize, value: Data) callconv(.c) void {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const ptr: [*]u8 = @ptrFromInt(@as(usize, @intCast(name_ptr)));
    const name_slice = ptr[0..name_len];

    v.setGlobal(name_slice, value) catch {};
}

/// create a new empty table, returns nil on failure
pub export fn revo_table_create(vm_ptr: *anyopaque) callconv(.c) Data {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tid = v.tables.create() catch
        return nil_val;
    return Data.new.table(tid);
}

/// total entries (array part + keyed entries), 0 for non-tables
pub export fn revo_table_len(vm_ptr: *anyopaque, table: Data) callconv(.c) u64 {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tid = table.asTable() orelse return 0;
    const tbl = v.tables.get(tid) catch return 0;
    return @intCast(tbl.count());
}

/// array-part length, 0 for non-tables
pub export fn revo_table_alen(vm_ptr: *anyopaque, table: Data) callconv(.c) u64 {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tid = table.asTable() orelse return 0;
    const tbl = v.tables.get(tid) catch return 0;
    return @intCast(tbl.array.items.len);
}

/// metatable-aware read; true and `out` set when present
pub export fn revo_table_get(vm_ptr: *anyopaque, table: Data, key: Data, out: *Data) callconv(.c) bool {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tid = table.asTable() orelse return false;
    const tbl = v.tables.get(tid) catch return false;
    out.* = (tbl.get(key, v) catch return false) orelse return false;
    return true;
}

/// metatable-aware write; false on bad table or allocation failure
pub export fn revo_table_set(vm_ptr: *anyopaque, table: Data, key: Data, value: Data) callconv(.c) bool {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tid = table.asTable() orelse return false;
    const tbl = v.tables.get(tid) catch return false;
    tbl.put(tid, v, key, value) catch return false;
    return true;
}

/// delete a table entry, returns true if the key existed
pub export fn revo_table_remove(vm_ptr: *anyopaque, table: Data, key: Data) callconv(.c) bool {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tid = table.asTable() orelse return false;
    const tbl = v.tables.get(tid) catch return false;
    return tbl.remove(key, v);
}

/// array-part read by index; false when out of range
pub export fn revo_table_get_idx(vm_ptr: *anyopaque, table: Data, idx: u64, out: *Data) callconv(.c) bool {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tid = table.asTable() orelse return false;
    out.* = v.arrayGet(tid, @intCast(idx)) orelse return false;
    return true;
}

/// append to the array part; false on bad table or allocation failure
pub export fn revo_table_push(vm_ptr: *anyopaque, table: Data, value: Data) callconv(.c) bool {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tid = table.asTable() orelse return false;
    const tbl = v.tables.get(tid) catch return false;
    tbl.push(v.runtime.alloc, value) catch return false;
    return true;
}

/// construct an array table from items, nil on failure
pub export fn revo_table_from_items(vm_ptr: *anyopaque, count: u64, items: [*]const Data) callconv(.c) Data {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    return v.tableOfSlice(items[0..@as(usize, @intCast(count))]) catch nil_val;
}

/// name-keyed write (interns the name); false on bad table or failure
pub export fn revo_table_set_name(vm_ptr: *anyopaque, table: Data, name_ptr: u64, name_len: usize, value: Data) callconv(.c) bool {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tid = table.asTable() orelse return false;
    const ptr: [*]u8 = @ptrFromInt(@as(usize, @intCast(name_ptr)));
    v.putField(tid, ptr[0..name_len], value) catch return false;
    return true;
}

/// name-keyed raw read; true and `out` set when present
pub export fn revo_table_get_name(vm_ptr: *anyopaque, table: Data, name_ptr: u64, name_len: usize, out: *Data) callconv(.c) bool {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const ptr: [*]u8 = @ptrFromInt(@as(usize, @intCast(name_ptr)));
    out.* = v.getField(table, ptr[0..name_len]) orelse return false;
    return true;
}

/// `{:ok, payload}` constructor for host results, nil on failure
pub export fn revo_ok(vm_ptr: *anyopaque, payload: Data) callconv(.c) Data {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    return v.resultTable(.ok, payload) catch nil_val;
}

/// `{:err, payload}` constructor for host results, nil on failure
pub export fn revo_err(vm_ptr: *anyopaque, payload: Data) callconv(.c) Data {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    return v.resultTable(.err, payload) catch nil_val;
}

/// whether the value is an `{:ok, ...}` table
pub export fn revo_is_ok(vm_ptr: *anyopaque, val: Data) callconv(.c) bool {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    return v.isOkTable(val);
}

/// whether the value is an `{:err, ...}` table
pub export fn revo_is_err(vm_ptr: *anyopaque, val: Data) callconv(.c) bool {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    return v.isErrTable(val);
}

/// payload of an `{:ok, ...}` table; false otherwise
pub export fn revo_ok_value(vm_ptr: *anyopaque, val: Data, out: *Data) callconv(.c) bool {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const parts = v.resultParts(val) orelse return false;
    if (parts.tag.asAtom() != revo.core_atoms.atomId(.ok)) return false;
    out.* = parts.payload orelse return false;
    return true;
}

/// call a revo function from c, returns false on type/resource error (max 16 args)
pub export fn revo_call(
    vm_ptr: *anyopaque,
    func: Data,
    argc: u64,
    argv: [*]const Data,
    out: *Data,
) callconv(.c) bool {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const callee = func;

    // stack buffer avoids GC-triggering heap alloc, most revo functions have few args
    var buf: [16]Data = undefined;
    if (argc > 16) return false;
    for (0..@as(usize, @intCast(argc))) |i|
        buf[i] = argv[i];

    const result = v.callFunctionParts(callee, null, buf[0..@as(usize, @intCast(argc))], null) catch return false;
    out.* = result;
    return true;
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

/// wrap a raw pointer as a foreign value, caller manages lifetime
pub export fn revo_foreign_new(ptr: ?*anyopaque) callconv(.c) Data {
    return Data.new.foreign(ptr);
}

/// extract the raw pointer from a foreign value (null if not foreign)
pub export fn revo_foreign_ptr(val: Data) callconv(.c) ?*anyopaque {
    return val.asForeign();
}

/// register a shared lib's revo_bindings into the module table; types come
/// from the sibling `<stem>.d.rv` manifest (`extensionManifestFor`)
pub fn loadC(vm_ptr: *VM, lib_path: []const u8) ![]functions.CFunction {
    if (builtin.target.os.tag == .wasi or builtin.target.os.tag == .freestanding) {
        std.debug.print("error: dynamic library loading is not supported on this platform\n", .{});
        return error.OsNotSupported;
    }

    var lib = try std.DynLib.open(lib_path);

    const bindings_ptr: [*]const RevoBinding = lib.lookup([*]const RevoBinding, "revo_bindings") orelse {
        std.debug.print("error: extension '{s}' has no revo_bindings export\n", .{lib_path});
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

const WinDynLib = struct {
    const windows = std.os.windows;
    dll: windows.HMODULE,

    pub fn open(path: []const u8) !WinDynLib {
        // maybe windows.PATH_MAX_WIDE here
        var buf: [1024:0]u16 = undefined;
        const path_w = try std.unicode.utf8ToUtf16LeArrayPtr(&buf, path);
        const handle = try windows.LoadLibraryW(path_w);
        return .{ .dll = handle };
    }

    pub fn lookup(self: *WinDynLib, comptime T: type, name: [:0]const u8) ?T {
        const addr = windows.kernel32.GetProcAddress(self.dll, name.ptr) orelse return null;
        return @as(T, @ptrCast(@alignCast(addr)));
    }

    pub fn close(self: *WinDynLib) void {
        windows.FreeLibrary(self.dll);
        self.* = undefined;
    }
};

const DynLib = if (builtin.target.os.tag == .windows) WinDynLib else std.DynLib;

///
/// load a shared lib's `revo_native_bindings` as host functions
///
/// each binding's fn_ptr is a HostFn (*const fn ([]const Data, *VM) HostResult)
/// so the vm does arity n type checking on call
pub fn loadNative(vm_ptr: *VM, lib_path: []const u8) ![]HostFunc {
    if (builtin.target.os.tag == .wasi or builtin.target.os.tag == .freestanding) {
        return error.OsNotSupported;
    }

    var lib = try std.DynLib.open(lib_path);

    const bindings_ptr: [*]const HostBinding = lib.lookup([*]const HostBinding, "revo_native_bindings") orelse {
        return error.NoBindings;
    };

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

        try registered.append(vm_ptr.runtime.alloc, .{
            .name = name,
            .arity = b.arity,
            .variadic = b.variadic,
            .param_types = &.{},
            .func = @ptrCast(@alignCast(fn_ptr.?)),
        });
    }

    try vm_ptr.loaded_extensions.append(vm_ptr.runtime.alloc, lib);
    return try registered.toOwnedSlice(vm_ptr.runtime.alloc);
}
