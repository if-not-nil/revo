const std = @import("std");
const revo = @import("revo");
const root = @import("root.zig");
const meta = @import("meta.zig");

const Data = revo.Data;
const VM = revo.VM;
const NativeResult = root.NativeResult;
const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;

const FileEntry = struct {
    path: []const u8,
    file: ?File = null,
    is_dir: bool,
};

var fs_table_id: revo.TableID = undefined;
var is_initialized = false;

fn ensureInit(vm: *VM) !void {
    if (!is_initialized) {
        fs_table_id = try vm.tables.create();
        var fs_tbl = try vm.tables.get(fs_table_id);
        try fs_tbl.putRaw(
            Data.new.atom(try vm.internAtom("__id_counter")),
            Data.new.num(1000),
        );
        const open_files_table = try vm.tables.create();
        try fs_tbl.putRaw(
            Data.new.atom(try vm.internAtom("__open_files")),
            Data{ .table = open_files_table },
        );
        is_initialized = true;
    }
}

pub fn register(vm: *VM) !void {
    try ensureInit(vm);
    try root.registerTableFunctions(vm, "fs", &[_]root.FuncDef{
        .{ .name = "open", .f = root.define(&.{.string}, open_fn) },
    });
    try root.registerTableFunctions(vm, "file", &[_]root.FuncDef{
        .{ .name = "read", .f = root.define(&.{.any}, read_fn) },
        .{ .name = "write", .f = root.define(&.{ .any, .any }, write_fn) },
        .{ .name = "stat", .f = root.define(&.{.any}, stat_fn) },
        .{ .name = "close", .f = root.define(&.{.any}, close_fn) },
        .{ .name = "readdir", .f = root.define(&.{.any}, readdir_fn) },
    });
}

fn nextId(vm: *VM) !u32 {
    var fs_tbl = try vm.tables.get(fs_table_id);
    const counter_data = fs_tbl.getRaw(Data.new.atom(try vm.internAtom("__id_counter"))) orelse
        return error.NoCounter;
    const next_val = @as(u32, @intFromFloat(counter_data.number)) + 1;
    try fs_tbl.putRaw(
        Data.new.atom(try vm.internAtom("__id_counter")),
        Data.new.num(next_val),
    );
    return next_val;
}

fn wrapFile(vm: *VM, entry: FileEntry) !Data {
    const id = try nextId(vm);

    const file_table = try vm.tables.create();
    var table = try vm.tables.get(file_table);
    try table.putRaw(
        Data.new.atom(try vm.internAtom("__file_id")),
        Data.new.num(id),
    );
    try table.putRaw(
        Data.new.atom(try vm.internAtom("__path")),
        try vm.ownDataString(entry.path),
    );
    try table.putRaw(
        Data.new.atom(try vm.internAtom("__is_dir")),
        Data.new.num(if (entry.is_dir) @as(f64, 1.0) else @as(f64, 0.0)),
    );

    const metatable = try vm.tables.create();
    var mt = try vm.tables.get(metatable);

    const file_module_data = vm.globals.get(try vm.internAtom("file")) orelse
        return error.FileModuleNotFound;

    try mt.putRaw(
        Data.new.atom(try vm.internAtom("__index")),
        file_module_data,
    );

    const mt_data = Data{ .table = metatable };
    const mt_array = [_]Data{ Data{ .table = file_table }, mt_data };
    const mt_call_args = &mt_array;
    const set_result = try meta.set_metatable_(mt_call_args, vm);
    if (set_result != .ok) return error.SetMetatableFailed;

    return Data{ .table = file_table };
}


fn makeStatTable(vm: *VM, stat: File.Stat) !Data {
    const table = try vm.tables.create();
    var t = try vm.tables.get(table);

    const kind_str = @tagName(stat.kind);

    try t.putRaw(
        .{ .atom = try vm.internAtom("size") },
        Data.new.num(stat.size),
    );
    try t.putRaw(.{ .atom = try vm.internAtom("kind") }, try vm.ownDataString(kind_str));
    try t.putRaw(
        .{ .atom = try vm.internAtom("mtime") },
        Data.new.num(stat.mtime.toSeconds()),
    );
    try t.putRaw(
        .{ .atom = try vm.internAtom("atime") },
        Data.new.num((stat.atime orelse stat.mtime).toSeconds()),
    );
    try t.putRaw(
        .{ .atom = try vm.internAtom("ctime") },
        Data.new.num(stat.ctime.toSeconds()),
    );

    return Data{ .table = table };
}

/// > fs:open(path: string) -> file_handle
/// opens a file or directory at the given path
fn open_fn(args: []const Data, vm: *VM) !NativeResult {
    const path = vm.stringValue(args[0].string);
    const io = vm.runtime.io;
    const dir = Dir.cwd();

    const stat = dir.statFile(io, path, .{}) catch {
        return try .Err(vm, "file_not_found");
    };

    if (stat.kind == .directory) {
        const entry = FileEntry{
            .path = path,
            .file = null,
            .is_dir = true,
        };
        const wrapped = try wrapFile(vm, entry);
        return try .Ok(vm, wrapped);
    }

    const file = dir.openFile(io, path, .{}) catch {
        return try .Err(vm, "cannot_open_file");
    };

    const entry = FileEntry{
        .path = path,
        .file = file,
        .is_dir = false,
    };
    const wrapped = try wrapFile(vm, entry);
    return try .Ok(vm, wrapped);
}

/// > file:read() -> string
/// reads file contents as string, or directory entries separated by newlines
fn read_fn(args: []const Data, vm: *VM) !NativeResult {
    const file_data = args[0];
    if (file_data != .table) {
        return try .Err(vm, "invalid_file");
    }
    
    const table = try vm.tables.get(file_data.table);
    const path_data = table.getRaw(Data.new.atom(try vm.internAtom("__path"))) orelse
        return try .Err(vm, "invalid_file");
    const path = vm.stringValue(path_data.string);
    
    const is_dir_data = table.getRaw(Data.new.atom(try vm.internAtom("__is_dir"))) orelse
        return try .Err(vm, "invalid_file");
    const is_dir = is_dir_data.number != 0;

    if (is_dir) {
        const io = vm.runtime.io;
        const dir = Dir.cwd();
        var iter = dir.iterate();

        var names = try std.ArrayList([]const u8).initCapacity(vm.runtime.alloc, 32);
        defer names.deinit(vm.runtime.alloc);

        while (try iter.next(io)) |ent| {
            names.appendAssumeCapacity(ent.name);
        }

        const result = std.mem.join(vm.runtime.alloc, "\n", names.items) catch "";
        const result_data = try vm.ownDataString(result);
        return try .Ok(vm, result_data);
    }

    const io = vm.runtime.io;
    const dir = Dir.cwd();
    const file = dir.openFile(io, path, .{}) catch {
        return try .Err(vm, "cannot_read_file");
    };
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    const bytes = try reader.interface.readSliceShort(&buf);

    const result_data = try vm.ownDataString(buf[0..bytes]);
    return try .Ok(vm, result_data);
}

/// > file:write(data: string) -> number
/// writes data to file, returns number of bytes written
fn write_fn(args: []const Data, vm: *VM) !NativeResult {
    const file_data = args[0];
    if (file_data != .table or args[1] != .string) {
        return try .Err(vm, "invalid_arguments");
    }
    
    const table = try vm.tables.get(file_data.table);
    const path_data = table.getRaw(Data.new.atom(try vm.internAtom("__path"))) orelse
        return try .Err(vm, "invalid_file");
    const path = vm.stringValue(path_data.string);
    
    const is_dir_data = table.getRaw(Data.new.atom(try vm.internAtom("__is_dir"))) orelse
        return try .Err(vm, "invalid_file");
    const is_dir = is_dir_data.number != 0;

    if (is_dir) {
        return try .Err(vm, "cannot_write_to_directory");
    }

    const data = vm.stringValue(args[1].string);
    const io = vm.runtime.io;
    const dir = Dir.cwd();
    const file = dir.openFile(io, path, .{}) catch {
        return try .Err(vm, "cannot_open_file");
    };
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(data);
    try writer.interface.flush();

    return try .Ok(vm, Data.new.num(data.len));
}

/// > file:stat() -> table
/// returns table with file statistics (size, kind, mtime, ctime, atime)
fn stat_fn(args: []const Data, vm: *VM) !NativeResult {
    const file_data = args[0];
    if (file_data != .table) {
        return try .Err(vm, "invalid_file");
    }
    
    const table = try vm.tables.get(file_data.table);
    const path_data = table.getRaw(Data.new.atom(try vm.internAtom("__path"))) orelse
        return try .Err(vm, "invalid_file");
    const path = vm.stringValue(path_data.string);

    const io = vm.runtime.io;
    const dir = Dir.cwd();
    const file_stat = dir.statFile(io, path, .{}) catch {
        return try .Err(vm, "stat_error");
    };

    const stat_table = try makeStatTable(vm, file_stat);
    return try .Ok(vm, stat_table);
}

/// > file:close() -> atom
/// closes the file handle, returns :ok
fn close_fn(args: []const Data, vm: *VM) !NativeResult {
    const file_data = args[0];
    if (file_data != .table) {
        return try .Err(vm, "invalid_file");
    }

    _ = try vm.tables.get(file_data.table);
    
    return try .Ok(vm, Data.new.atom(try vm.internAtom("ok")));
}

/// > file:readdir() -> table
/// reads directory entries, returns table of {name, kind} pairs
fn readdir_fn(args: []const Data, vm: *VM) !NativeResult {
    const file_data = args[0];
    if (file_data != .table) {
        return try .Err(vm, "invalid_file");
    }
    
    const table = try vm.tables.get(file_data.table);
    const path_data = table.getRaw(Data.new.atom(try vm.internAtom("__path"))) orelse
        return try .Err(vm, "invalid_file");
    const path = vm.stringValue(path_data.string);
    
    const is_dir_data = table.getRaw(Data.new.atom(try vm.internAtom("__is_dir"))) orelse
        return try .Err(vm, "invalid_file");
    const is_dir = is_dir_data.number != 0;

    if (!is_dir) {
        return try .Err(vm, "not_a_directory");
    }

    const io = vm.runtime.io;
    const cwd = Dir.cwd();
    const open_dir = try cwd.openDir(io, path, .{});
    var iter = open_dir.iterate();

    var entries = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, 32);
    defer entries.deinit(vm.runtime.alloc);

    while (try iter.next(io)) |ent| {
        const entry_table = try vm.tables.create();
        var t = try vm.tables.get(entry_table);

        try t.putRaw(.{ .atom = try vm.internAtom("name") }, try vm.ownDataString(ent.name));

        const kind_str = switch (ent.kind) {
            .file => "file",
            .directory => "directory",
            .sym_link => "symlink",
            else => "unknown",
        };
        try t.putRaw(.{ .atom = try vm.internAtom("kind") }, try vm.ownDataString(kind_str));

        try entries.append(vm.runtime.alloc, Data{ .table = entry_table });
    }

    const result_tuple = try vm.tuples.create(entries.items);
    return try .Ok(vm, Data{ .tuple = result_tuple });
}

