const std = @import("std");
const revo = @import("../root.zig");
const root = @import("root.zig");
const meta = @import("meta.zig");

const Data = revo.Data;
const VM = revo.VM;
const NativeResult = root.NativeResult;

const SocketEntry = union(enum) {
    stream: std.Io.net.Stream,
    server: std.Io.net.Server,
};

pub fn register(vm: *VM) !void {
    try root.registerTableFunctions(vm, "net", &[_]root.FuncDef{
        .{ .name = "connect", .f = root.define(&.{ .string, .number }, connect_fn) },
        .{ .name = "listen", .f = root.defineVariadic(&.{.number}, listen_fn) },
    });
    try root.registerTableFunctions(vm, "socket", &[_]root.FuncDef{
        .{ .name = "accept", .f = root.define(&.{.table}, accept_fn) },
        .{ .name = "send", .f = root.define(&.{ .table, .string }, send_fn) },
        .{ .name = "recv", .f = root.defineVariadic(&.{.table}, recv_fn) },
        .{ .name = "close", .f = root.define(&.{.table}, socket_close_fn) },
    });
}

// ret table wraps heap alloced SocketEntry gc probably doesnt nuke it
fn wrapSocket(vm: *VM, entry_ptr: *SocketEntry, is_server: bool) !Data {
    const sock_table = try vm.tables.create();
    var table = try vm.tables.get(sock_table);

    try table.putRaw(
        Data.new.atom(try vm.internAtom("__is_server")),
        Data.new.boolean(is_server),
    );

    try table.putRaw(
        Data.new.atom(try vm.internAtom("__entry_ptr")),
        Data.new.num(@intFromPtr(entry_ptr)),
    );

    // the socket module as mt __index so methods resolve
    const metatable = try vm.tables.create();
    var mt = try vm.tables.get(metatable);
    const socket_module_data = vm.globals.get(try vm.internAtom("socket")) orelse
        return error.SocketModuleNotFound;
    try mt.putRaw(
        Data.new.atom(try vm.internAtom("__index")),
        socket_module_data,
    );

    const mt_array = [_]Data{ Data{ .table = sock_table }, Data{ .table = metatable } };
    const set_result = try meta.set_metatable_(&mt_array, vm);
    if (set_result != .ok) return error.SetMetatableFailed;

    return Data{ .table = sock_table };
}

fn isServer(socket_data: Data, vm: *VM) !bool {
    const table = try vm.tables.get(socket_data.table);
    const d = table.getRaw(Data.new.atom(try vm.internAtom("__is_server"))) orelse
        return error.InvalidSocket;
    return !revo.isFalse(d);
}

/// ret always live ptr or SocketClosed
fn getEntryPtr(socket_data: Data, vm: *VM) !*SocketEntry {
    const table = try vm.tables.get(socket_data.table);
    const d = table.getRaw(Data.new.atom(try vm.internAtom("__entry_ptr"))) orelse
        return error.InvalidSocket;
    const addr = @as(usize, @intFromFloat(d.number));
    if (addr == 0) return error.SocketClosed;
    return @as(*SocketEntry, @ptrFromInt(addr));
}

/// poison the pointer slot and free the entry,,, idempotent
fn closeEntry(socket_data: Data, vm: *VM) !void {
    const entry_ptr = getEntryPtr(socket_data, vm) catch |e| switch (e) {
        error.SocketClosed => return,
        else => return e,
    };

    const io = vm.runtime.io;
    switch (entry_ptr.*) {
        .stream => |s| s.close(io),
        .server => |s| std.Io.net.Server.deinit(@constCast(&s), io),
    }
    vm.runtime.alloc.destroy(entry_ptr);

    // zeroise so double close is nop rather than use-after-free
    var tbl = try vm.tables.get(socket_data.table);
    try tbl.putRaw(
        Data.new.atom(try vm.internAtom("__entry_ptr")),
        Data.new.num(0),
    );
}

/// > net:connect(host: string, port: number) -> socket
/// connects to a remote host and port, returns a socket handle
fn connect_fn(args: []const Data, vm: *VM) !NativeResult {
    const host = vm.stringValue(args[0].string);
    const port: u16 = @as(u16, @intFromFloat(args[1].number));

    const host_to_use = if (std.mem.eql(u8, host, "localhost")) "127.0.0.1" else host;
    const addr = std.Io.net.IpAddress.parseIp4(host_to_use, port) catch {
        return .other("invalid address");
    };

    const stream = addr.connect(vm.runtime.io, .{
        .mode = std.Io.net.Socket.Mode.stream,
        .protocol = std.Io.net.Protocol.tcp,
    }) catch {
        return .other("connection failed");
    };

    const entry_ptr = try vm.runtime.alloc.create(SocketEntry);
    entry_ptr.* = .{ .stream = stream };

    return try .Ok(vm, try wrapSocket(vm, entry_ptr, false));
}

/// > net:listen(port: number [, backlog: number]) -> socket
/// listens for incoming connections on the given port, returns server socket
fn listen_fn(args: []const Data, vm: *VM) !NativeResult {
    const port: u16 = @as(u16, @intFromFloat(args[0].number));
    const backlog: u31 = if (args.len > 1) @as(u31, @intFromFloat(args[1].number)) else 128;

    const addr = std.Io.net.IpAddress.parseIp4("0.0.0.0", port) catch {
        return .other("invalid address");
    };

    const server = addr.listen(vm.runtime.io, .{
        .mode = std.Io.net.Socket.Mode.stream,
        .protocol = std.Io.net.Protocol.tcp,
        .kernel_backlog = backlog,
    }) catch {
        return .other("listen failed");
    };

    const entry_ptr = try vm.runtime.alloc.create(SocketEntry);
    entry_ptr.* = .{ .server = server };

    return try .Ok(vm, try wrapSocket(vm, entry_ptr, true));
}

/// > socket:accept() -> socket
/// accepts an incoming client connection on a server socket
fn accept_fn(args: []const Data, vm: *VM) !NativeResult {
    const socket_data = Data{ .table = args[0].table };

    if (!try isServer(socket_data, vm)) return .other("not a server socket");

    const entry_ptr = try getEntryPtr(socket_data, vm);
    const server = switch (entry_ptr.*) {
        .server => |*s| s,
        .stream => return .other("not a server socket"),
    };

    const conn = server.accept(vm.runtime.io) catch {
        return .other("accept failed");
    };

    const new_entry_ptr = try vm.runtime.alloc.create(SocketEntry);
    new_entry_ptr.* = .{ .stream = conn };

    return try .Ok(vm, try wrapSocket(vm, new_entry_ptr, false));
}

/// > socket:send(data: string) -> number
/// sends data over the socket, returns number of bytes sent
fn send_fn(args: []const Data, vm: *VM) !NativeResult {
    const socket_data = Data{ .table = args[0].table };
    const message = vm.stringValue(args[1].string);

    if (try isServer(socket_data, vm)) return .other("cannot send on server socket");

    const entry_ptr = try getEntryPtr(socket_data, vm);
    const stream = switch (entry_ptr.*) {
        .stream => |*s| s,
        .server => return .other("cannot send on server socket"),
    };

    const write_buf = try vm.runtime.alloc.alloc(u8, message.len);
    defer vm.runtime.alloc.free(write_buf);

    var writer = stream.writer(vm.runtime.io, write_buf);
    writer.interface.writeAll(message) catch return .other("send failed");
    writer.interface.flush() catch return .other("send flush failed");

    return try .Ok(vm, Data.new.num(message.len));
}

/// > socket:recv([max_bytes: number]) -> string
/// receives data from the socket, returns data as string
fn recv_fn(args: []const Data, vm: *VM) !NativeResult {
    const socket_data = Data{ .table = args[0].table };
    const max_bytes: usize = if (args.len > 1) @as(usize, @intFromFloat(args[1].number)) else 4096;

    if (try isServer(socket_data, vm)) return .other("cannot recv on server socket");

    const entry_ptr = try getEntryPtr(socket_data, vm);
    const stream = switch (entry_ptr.*) {
        .stream => |*s| s,
        .server => return .other("cannot recv on server socket"),
    };

    const recv_buf = try vm.runtime.alloc.alloc(u8, max_bytes);
    defer vm.runtime.alloc.free(recv_buf);

    const read_buf = try vm.runtime.alloc.alloc(u8, 4096);
    defer vm.runtime.alloc.free(read_buf);

    var reader = stream.reader(vm.runtime.io, read_buf);
    const n = reader.interface.readSliceShort(recv_buf) catch return .other("recv failed");

    return try .Ok(vm, try vm.ownDataString(recv_buf[0..n]));
}

/// > socket:close() -> atom
/// closes the socket
fn socket_close_fn(args: []const Data, vm: *VM) !NativeResult {
    const socket_data = Data{ .table = args[0].table };
    try closeEntry(socket_data, vm);
    return try .Ok(vm, revo.core_atoms.data(.nil));
}
