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
const CRevoData = functions.CRevoData;
const RevoBinding = functions.RevoBinding;
const CFnPtr = functions.CFnPtr;

// for error/missing returns
const nil_val = CRevoData{
    .tag = @intFromEnum(memory.Type.atom),
    .value = @intFromEnum(revo.core_atoms.nil),
};

pub export fn revo_intern(vm_ptr: *anyopaque, ptr_val: u64, len: usize) callconv(.c) u64 {
    // returns 0 on failure but safe because vm assigns ids starting at 1
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const ptr: [*]u8 = @ptrFromInt(ptr_val);
    const slice = ptr[0..len];
    const id = v.strings.own(slice) catch return 0;
    return @intCast(id);
}

pub export fn revo_intern_atom(vm_ptr: *anyopaque, ptr_val: u64, len: usize) callconv(.c) u64 {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const ptr: [*]u8 = @ptrFromInt(ptr_val);
    const slice = ptr[0..len];
    const id = v.internAtom(slice) catch return 0;
    return @intCast(id);
}

pub export fn revo_getglobal(vm_ptr: *anyopaque, name_ptr: u64, name_len: usize) callconv(.c) CRevoData {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const ptr: [*]u8 = @ptrFromInt(name_ptr);
    const name_slice = ptr[0..name_len];

    const value = v.getGlobal(name_slice) orelse
        return nil_val;

    // getGlobal returns :undef for missing names instead of null
    if (value.tag() == .atom and value.asAtom().? == @intFromEnum(revo.core_atoms.undef))
        return nil_val;

    return CRevoData.fromData(value);
}

pub export fn revo_setglobal(vm_ptr: *anyopaque, name_ptr: u64, name_len: usize, value: CRevoData) callconv(.c) void {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const ptr: [*]u8 = @ptrFromInt(name_ptr);
    const name_slice = ptr[0..name_len];

    const data = value.toData(v) catch return;
    v.setGlobal(name_slice, data) catch {};
}

pub export fn revo_table_create(vm_ptr: *anyopaque) callconv(.c) CRevoData {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tid = v.tables.create() catch
        return nil_val;
    return .{ .tag = @intFromEnum(memory.Type.table), .value = @intCast(tid) };
}

pub export fn revo_table_len(vm_ptr: *anyopaque, table_id: u64) callconv(.c) u64 {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tbl = v.tables.get(@intCast(table_id)) catch return 0;
    return @intCast(tbl.count());
}

pub export fn revo_table_get(vm_ptr: *anyopaque, table_id: u64, key: CRevoData) callconv(.c) CRevoData {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));

    const tid: memory.TableID = @intCast(table_id);
    const key_data = key.toData(v) catch return nil_val;

    const tbl = v.tables.get(tid) catch return nil_val;

    if (tbl.get(key_data, v) catch return nil_val) |value|
        return CRevoData.fromData(value);

    return nil_val;
}

pub export fn revo_table_set(vm_ptr: *anyopaque, table_id: u64, key: CRevoData, value: CRevoData) callconv(.c) void {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));

    const tid: memory.TableID = @intCast(table_id);
    const key_data = key.toData(v) catch return;
    const value_data = value.toData(v) catch return;

    const tbl = v.tables.get(tid) catch return;
    tbl.put(tid, v, key_data, value_data) catch {};
}

pub export fn revo_tuple_create(vm_ptr: *anyopaque, count: u64, items: [*]const CRevoData) callconv(.c) CRevoData {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const src = items[0..count];
    var data_list = std.ArrayList(Data).initCapacity(v.runtime.alloc, count) catch
        return nil_val;
    defer data_list.deinit(v.runtime.alloc);
    for (src) |*c_item| {
        const item_data = c_item.toData(v) catch
            return nil_val;
        data_list.appendAssumeCapacity(item_data);
    }
    const tid = v.tuples.create(data_list.items) catch
        return nil_val;
    return .{ .tag = @intFromEnum(memory.Type.tuple), .value = @intCast(tid) };
}

pub export fn revo_tuple_get(vm_ptr: *anyopaque, tuple_id: u64, index: u64) callconv(.c) CRevoData {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tup = v.tuples.get(@intCast(tuple_id)) catch
        return nil_val;
    if (index >= tup.items.len)
        return nil_val;
    return CRevoData.fromData(tup.items[@intCast(index)]);
}

pub export fn revo_tuple_len(vm_ptr: *anyopaque, tuple_id: u64) callconv(.c) u64 {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tup = v.tuples.get(@intCast(tuple_id)) catch return 0;
    return @intCast(tup.items.len);
}

pub export fn revo_string_data(vm_ptr: *anyopaque, id: u64) callconv(.c) ?[*]const u8 {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const slice = v.strings.get(@intCast(id)) catch return null;
    // pointer valid only until next GC sweep; caller must not hold across allocs
    return slice.ptr;
}

pub export fn revo_string_length(vm_ptr: *anyopaque, id: u64) callconv(.c) usize {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const slice = v.strings.get(@intCast(id)) catch return 0;
    return slice.len;
}

/// load a shared library and register its revo_bindings as c functions
pub fn loadC(vm_ptr: *VM, lib_path: []const u8) ![]functions.CFunction {
    if (builtin.target.os.tag == .windows) {
        std.debug.print("error: dynamic library loading is not supported on windows\n", .{});
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
    while (@as(?[*:0]const u8, bindings_ptr[i].name) != null) : (i += 1) {
        const b = bindings_ptr[i];
        const name = std.mem.span(b.name);
        const fn_ptr: CFnPtr = @ptrCast(@alignCast(b.fn_ptr));

        try registered.append(vm_ptr.runtime.alloc, .{
            .name = name,
            .fn_ptr = fn_ptr,
        });
    }

    try vm_ptr.loaded_extensions.append(vm_ptr.runtime.alloc, lib);
    return try registered.toOwnedSlice(vm_ptr.runtime.alloc);
}
