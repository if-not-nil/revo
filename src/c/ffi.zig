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

pub export fn revo_intern(vm_ptr: *anyopaque, ptr_val: u64, len: usize) callconv(.c) u64 {
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

    if (v.getGlobal(name_slice)) |value| {
        const tag = value.tag();
        const c_value: u64 = switch (tag) {
            .number => @bitCast(value.asNum().?),
            .string => value.asString().?,
            .atom => value.asAtom().?,
            .function => value.asFunction().?,
            .table => value.asTable().?,
            .tuple => value.asTuple().?,
            .struct_val => value.asStructVal().?,
            .struct_type => value.asStructType().?,
        };
        return .{ .tag = @intFromEnum(tag), .value = c_value };
    }

    return CRevoData{ .tag = @intFromEnum(memory.Type.atom), .value = 0 }; // nil sentinel
}

pub export fn revo_setglobal(vm_ptr: *anyopaque, name_ptr: u64, name_len: usize, value: CRevoData) callconv(.c) void {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const ptr: [*]u8 = @ptrFromInt(name_ptr);
    const name_slice = ptr[0..name_len];

    const data = value.toData(v) catch return;
    v.setGlobal(name_slice, data) catch {};
}

pub export fn revo_table_get(vm_ptr: *anyopaque, table_id: u64, key: CRevoData) callconv(.c) CRevoData {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));

    const tid: memory.TableID = @intCast(table_id);
    const key_data = key.toData(v) catch return CRevoData{ .tag = @intFromEnum(memory.Type.atom), .value = 0 };

    const tbl = v.tables.get(tid) catch return CRevoData{ .tag = @intFromEnum(memory.Type.atom), .value = 0 };

    if (tbl.get(key_data, v) catch return CRevoData{ .tag = @intFromEnum(memory.Type.atom), .value = 0 }) |value| {
        const tag = value.tag();
        const c_value: u64 = switch (tag) {
            .number => @bitCast(value.asNum().?),
            .string => value.asString().?,
            .atom => value.asAtom().?,
            .function => value.asFunction().?,
            .table => value.asTable().?,
            .tuple => value.asTuple().?,
            .struct_val => value.asStructVal().?,
            .struct_type => value.asStructType().?,
        };
        return .{ .tag = @intFromEnum(tag), .value = c_value };
    }

    return CRevoData{
        .tag = @intFromEnum(memory.Type.atom),
        .value = revo.core_atoms.atom_id(.nil),
    };
}

pub export fn revo_table_set(vm_ptr: *anyopaque, table_id: u64, key: CRevoData, value: CRevoData) callconv(.c) void {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));

    const tid: memory.TableID = @intCast(table_id);
    const key_data = key.toData(v) catch return;
    const value_data = value.toData(v) catch return;

    const tbl = v.tables.get(tid) catch return;
    tbl.put(tid, v, key_data, value_data) catch {};
}

pub export fn revo_string_data(vm_ptr: *anyopaque, id: u64) callconv(.c) ?[*]const u8 {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const slice = v.strings.get(@intCast(id)) catch return null;
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

    var registered = try std.ArrayList(functions.CFunction).initCapacity(vm_ptr.runtime.alloc, 2);
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
