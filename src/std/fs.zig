const std = @import("std");
const revo = @import("../root.zig");
const root = @import("root.zig");
const meta = @import("meta.zig");

const Data = revo.Data;
const VM = revo.VM;
const NativeResult = root.NativeResult;
const Dir = std.Io.Dir;
const File = std.Io.File;

const path_key = "__path";
const is_dir_key = "__is_dir";

const FileHandle = struct {
    path: []const u8,
    is_dir: bool,
};

pub fn register(vm: *VM) !void {
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

fn wrapFile(vm: *VM, path: []const u8, is_dir: bool) !Data {
    const file_table = try vm.tables.create();
    var table = try vm.tables.get(file_table);
    try table.putRaw(try vm.dataAtom(path_key), try vm.ownDataString(path));
    try table.putRaw(try vm.dataAtom(is_dir_key), Data.new.boolean(is_dir));

    const metatable = try vm.tables.create();
    var mt = try vm.tables.get(metatable);
    const file_module = vm.globals.get(try vm.internAtom("file")) orelse return error.FileModuleNotFound;
    try mt.putRaw(try vm.dataAtom("__index"), file_module);

    const set_result = try meta.set_metatable_(&.{ Data{ .table = file_table }, Data{ .table = metatable } }, vm);
    if (set_result != .ok) return error.SetMetatableFailed;
    return Data{ .table = file_table };
}

fn parseFileHandle(value: Data, vm: *VM) !FileHandle {
    if (value != .table) return error.InvalidFile;
    const table = try vm.tables.get(value.table);

    const path_data = table.getRaw(try vm.dataAtom(path_key)) orelse return error.InvalidFile;
    const is_dir_data = table.getRaw(try vm.dataAtom(is_dir_key)) orelse return error.InvalidFile;
    const is_dir = switch (is_dir_data) {
        .atom => |atom| switch (atom) {
            revo.core_atoms.atom_id(.true) => true,
            revo.core_atoms.atom_id(.false) => false,
            else => return error.InvalidFile,
        },
        .number => |number| number != 0,
        else => return error.InvalidFile,
    };

    return .{
        .path = switch (path_data) {
            .string => |id| vm.stringValue(id),
            else => return error.InvalidFile,
        },
        .is_dir = is_dir,
    };
}

fn kindName(kind: File.Kind) []const u8 {
    return switch (kind) {
        .file => "file",
        .directory => "directory",
        .sym_link => "symlink",
        else => "unknown",
    };
}

fn makeStatTable(vm: *VM, stat: File.Stat) !Data {
    const table = try vm.tables.create();
    var t = try vm.tables.get(table);

    try t.putRaw(try vm.dataAtom("size"), Data.new.num(stat.size));
    try t.putRaw(try vm.dataAtom("kind"), try vm.ownDataString(@tagName(stat.kind)));
    try t.putRaw(try vm.dataAtom("mtime"), Data.new.num(stat.mtime.toSeconds()));
    try t.putRaw(try vm.dataAtom("atime"), Data.new.num((stat.atime orelse stat.mtime).toSeconds()));
    try t.putRaw(try vm.dataAtom("ctime"), Data.new.num(stat.ctime.toSeconds()));

    return Data{ .table = table };
}

fn open_fn(args: []const Data, vm: *VM) !NativeResult {
    const path = vm.stringValue(args[0].string);
    const stat = Dir.cwd().statFile(vm.runtime.io, path, .{}) catch return .Err(vm, "file_not_found");
    return .Ok(vm, try wrapFile(vm, path, stat.kind == .directory));
}

fn read_fn(args: []const Data, vm: *VM) !NativeResult {
    const handle = parseFileHandle(args[0], vm) catch return .Err(vm, "invalid_file");

    if (!handle.is_dir) {
        const data = Dir.cwd().readFileAlloc(
            vm.runtime.io,
            handle.path,
            vm.runtime.alloc,
            std.Io.Limit.unlimited,
        ) catch return .Err(vm, "cannot_read_file");
        return .Ok(vm, try vm.adoptDataString(data));
    }

    const open_dir = Dir.cwd().openDir(vm.runtime.io, handle.path, .{}) catch return .Err(vm, "cannot_read_directory");
    var iter = open_dir.iterate();

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(vm.runtime.alloc);

    var first = true;
    while (try iter.next(vm.runtime.io)) |ent| {
        if (!first) try buf.append(vm.runtime.alloc, '\n');
        first = false;
        try buf.appendSlice(vm.runtime.alloc, ent.name);
    }

    return .Ok(vm, try vm.adoptDataString(try buf.toOwnedSlice(vm.runtime.alloc)));
}

fn write_fn(args: []const Data, vm: *VM) !NativeResult {
    const handle = parseFileHandle(args[0], vm) catch return .Err(vm, "invalid_file");
    if (args[1] != .string) return .Err(vm, "invalid_arguments");
    if (handle.is_dir) return .Err(vm, "cannot_write_to_directory");

    const data = vm.stringValue(args[1].string);
    Dir.cwd().writeFile(vm.runtime.io, .{
        .sub_path = handle.path,
        .data = data,
    }) catch return .Err(vm, "cannot_open_file");

    return .Ok(vm, Data.new.num(data.len));
}

fn stat_fn(args: []const Data, vm: *VM) !NativeResult {
    const handle = parseFileHandle(args[0], vm) catch return .Err(vm, "invalid_file");
    const stat = Dir.cwd().statFile(vm.runtime.io, handle.path, .{}) catch return .Err(vm, "stat_error");
    return .Ok(vm, try makeStatTable(vm, stat));
}

fn close_fn(args: []const Data, vm: *VM) !NativeResult {
    _ = parseFileHandle(args[0], vm) catch return .Err(vm, "invalid_file");
    return .Ok(vm, revo.core_atoms.data(.ok));
}

fn readdir_fn(args: []const Data, vm: *VM) !NativeResult {
    const handle = parseFileHandle(args[0], vm) catch return .Err(vm, "invalid_file");
    if (!handle.is_dir) return .Err(vm, "not_a_directory");

    const open_dir = Dir.cwd().openDir(vm.runtime.io, handle.path, .{}) catch return .Err(vm, "cannot_read_directory");
    var iter = open_dir.iterate();

    var entries = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, 16);
    defer entries.deinit(vm.runtime.alloc);

    while (try iter.next(vm.runtime.io)) |ent| {
        const entry_table = try vm.tables.create();
        var t = try vm.tables.get(entry_table);
        try t.putRaw(try vm.dataAtom("name"), try vm.ownDataString(ent.name));
        try t.putRaw(try vm.dataAtom("kind"), try vm.ownDataString(kindName(ent.kind)));
        try entries.append(vm.runtime.alloc, Data{ .table = entry_table });
    }

    return .Ok(vm, Data{ .tuple = try vm.tuples.create(entries.items) });
}

const testing = revo.lang.testing;
const io = std.testing.io;
const alloc = std.testing.allocator;

fn sourceForPath(comptime template: []const u8, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, template, .{path});
}

test "fs.open/read reads file contents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello from fs" });

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);
    const file_path = try std.fs.path.join(alloc, &.{ dir_path, "a.txt" });
    defer alloc.free(file_path);

    const source = try sourceForPath(
        \\ fs.open("{s}"):unwrap():read():unwrap()
    , file_path);
    defer alloc.free(source);

    try testing.top_string(source, "hello from fs");
}

test "fs.write overwrites file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "w.txt", .data = "old" });

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);
    const file_path = try std.fs.path.join(alloc, &.{ dir_path, "w.txt" });
    defer alloc.free(file_path);

    const source = try sourceForPath(
        \\ const f = fs.open("{s}"):unwrap()
        \\ f:write("new value"):unwrap()
        \\ f:read():unwrap()
    , file_path);
    defer alloc.free(source);

    try testing.top_string(source, "new value");
}

test "fs.stat returns file metadata table" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "kind.txt", .data = "x" });

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);
    const file_path = try std.fs.path.join(alloc, &.{ dir_path, "kind.txt" });
    defer alloc.free(file_path);

    const source = try sourceForPath(
        \\ fs.open("{s}"):unwrap():stat():unwrap().kind
    , file_path);
    defer alloc.free(source);

    try testing.top_string(source, "file");
}

test "fs.read and readdir work for directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "b" });

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);

    const source_read = try sourceForPath(
        \\ fs.open("{s}"):unwrap():read():unwrap():contains("a.txt")
    , dir_path);
    defer alloc.free(source_read);
    try testing.top_true(source_read);

    const source_readdir = try sourceForPath(
        \\ type(fs.open("{s}"):unwrap():readdir():unwrap()) == :tuple
    , dir_path);
    defer alloc.free(source_readdir);
    try testing.top_true(source_readdir);
}
