const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const revo = @import("revo");
const VM_mod = @import("VM.zig");
const memory = @import("memory.zig");
const functions = @import("functions.zig");
const Data = memory.Data;

pub const CFnPtr = functions.CFnPtr;

pub const RevoBinding = extern struct {
    name: [*:0]const u8,
    /// actually a CFnPtr, but extern structs can't have fn pointers
    /// this is fine and zig std does it the same way
    fn_ptr: *const anyopaque,
};

pub const CRevoData = extern struct {
    tag: u64,
    value: u64,

    pub fn toData(self: *const CRevoData, _: *VM_mod.VM) !Data {
        const tag: memory.Type = @enumFromInt(
            @as(@typeInfo(memory.Type).@"enum".tag_type, @intCast(self.tag)),
        );
        return switch (tag) {
            .number => Data.numberRaw(@bitCast(self.value)),
            .string => Data.new.str(@intCast(self.value)),
            .atom => Data.new.atom(@intCast(self.value)),
            .function => Data.new.function(@intCast(self.value)),
            .table => Data.new.table(@intCast(self.value)),
            .tuple => Data.new.tuple(@intCast(self.value)),
            .struct_val, .struct_type, .module => unreachable,
        };
    }

    pub fn ofData(data: Data, vm_alloc: std.mem.Allocator, strings: *const root.VM.Interner, copies: *std.ArrayList([:0]u8)) !CRevoData {
        const tag = data.tag();
        const value: u64 = switch (tag) {
            .number => @bitCast(data.asNumber().?),
            .string => blk: {
                const str_slice = strings.getAssumeAlive(data.asString().?);
                const copy = try vm_alloc.dupeZ(u8, str_slice);
                try copies.append(vm_alloc, copy);
                break :blk @intFromPtr(copy.ptr);
            },
            .atom => data.asAtom().?,
            .function => data.asFunction().?,
            .table => data.asTable().?,
            .tuple => data.asTuple().?,
            .struct_val, .struct_type, .module => unreachable,
        };
        return .{ .tag = @intFromEnum(tag), .value = value };
    }
};

pub export fn revo_intern(vm: *anyopaque, ptr_val: u64, len: usize) callconv(.c) u64 {
    const vm_typed: *VM_mod.VM = @ptrCast(@alignCast(vm));
    const ptr: [*]u8 = @ptrFromInt(ptr_val);
    const slice = ptr[0..len];
    const id = vm_typed.strings.own(slice) catch return 0;
    return @intCast(id);
}

pub export fn revo_getglobal(vm: *anyopaque, name_ptr: u64, name_len: usize) callconv(.c) CRevoData {
    const vm_typed: *VM_mod.VM = @ptrCast(@alignCast(vm));
    const ptr: [*]u8 = @ptrFromInt(name_ptr);
    const name_slice = ptr[0..name_len];

    if (vm_typed.getGlobal(name_slice)) |value| {
        const tag = value.tag();
        const c_value: u64 = switch (tag) {
            .number => @bitCast(value.asNumber().?),
            .string => value.asString().?,
            .atom => value.asAtom().?,
            .function => value.asFunction().?,
            .table => value.asTable().?,
            .tuple => value.asTuple().?,
            .struct_val => value.asStructVal().?,
            .struct_type => value.asStructType().?,
            .module => value.asNamespace().?,
        };
        return .{ .tag = @intFromEnum(tag), .value = c_value };
    }

    return CRevoData{ .tag = @intFromEnum(memory.Type.atom), .value = 0 }; // nil
}

pub export fn revo_setglobal(vm: *anyopaque, name_ptr: u64, name_len: usize, value: CRevoData) callconv(.c) void {
    const vm_typed: *VM_mod.VM = @ptrCast(@alignCast(vm));
    const ptr: [*]u8 = @ptrFromInt(name_ptr);
    const name_slice = ptr[0..name_len];

    const data = value.toData(vm_typed) catch return;
    vm_typed.setGlobal(name_slice, data) catch {};
}

pub export fn revo_table_get(vm: *anyopaque, table_id: u64, key: CRevoData) callconv(.c) CRevoData {
    const vm_typed: *VM_mod.VM = @ptrCast(@alignCast(vm));

    const tid: memory.TableID = @intCast(table_id);
    const key_data = key.toData(vm_typed) catch return CRevoData{ .tag = @intFromEnum(memory.Type.atom), .value = 0 };

    const tbl = vm_typed.tables.get(tid) catch return CRevoData{ .tag = @intFromEnum(memory.Type.atom), .value = 0 };

    if (tbl.get(key_data, vm_typed) catch return CRevoData{ .tag = @intFromEnum(memory.Type.atom), .value = 0 }) |value| {
        const tag = value.tag();
        const c_value: u64 = switch (tag) {
            .number => @bitCast(value.asNumber().?),
            .string => value.asString().?,
            .atom => value.asAtom().?,
            .function => value.asFunction().?,
            .table => value.asTable().?,
            .tuple => value.asTuple().?,
            .struct_val => value.asStructVal().?,
            .struct_type => value.asStructType().?,
            .module => value.asNamespace().?,
        };
        return .{ .tag = @intFromEnum(tag), .value = c_value };
    }

    return CRevoData{
        .tag = @intFromEnum(memory.Type.atom),
        .value = revo.core_atoms.atom_id(.nil),
    };
}

pub export fn revo_table_set(vm: *anyopaque, table_id: u64, key: CRevoData, value: CRevoData) callconv(.c) void {
    const vm_typed: *VM_mod.VM = @ptrCast(@alignCast(vm));

    const tid: memory.TableID = @intCast(table_id);
    const key_data = key.toData(vm_typed) catch return;
    const value_data = value.toData(vm_typed) catch return;

    const tbl = vm_typed.tables.get(tid) catch return;
    tbl.put(tid, vm_typed, key_data, value_data) catch {};
}

pub fn loadC(vm: *VM_mod.VM, lib_path: []const u8) ![]functions.CFunction {
    if (builtin.target.os.tag == .windows) {
        std.debug.print("error: dynamic library loading is not supported on windows\n", .{});
        return error.OsNotSupported;
    }

    var lib = try std.DynLib.open(lib_path);
    // defer lib.close();

    const bindings_ptr: [*]const RevoBinding = lib.lookup([*]const RevoBinding, "revo_bindings") orelse {
        std.debug.print("error: extension '{s}' has no revo_bindings export\n", .{lib_path});
        return error.NoBindings;
    };

    var registered = try std.ArrayList(functions.CFunction).initCapacity(vm.runtime.alloc, 2);
    defer registered.deinit(vm.runtime.alloc);

    var i: usize = 0;
    while (@as(?[*:0]const u8, bindings_ptr[i].name) != null) : (i += 1) {
        const binding = bindings_ptr[i];
        const name = std.mem.span(binding.name);

        const fn_ptr: CFnPtr = @ptrCast(@alignCast(binding.fn_ptr));
        // std.debug.print("f: {}\n", .{fn_ptr});
        const c_fn = functions.CFunction{
            .name = name,
            .fn_ptr = fn_ptr,
        };
        try registered.append(vm.runtime.alloc, c_fn);
    }

    try vm.loaded_extensions.append(vm.runtime.alloc, lib);
    return try registered.toOwnedSlice(vm.runtime.alloc);
    // std.debug.print("loaded extension, {d} functions\n", .{i});
}
