const std = @import("std");
const revo = @import("../root.zig");
const root = @import("root.zig");
const vm_path = revo.path_utils;

const VM = revo.VM;
const Data = revo.Data;
const NativeResult = revo.std_lib.NativeResult;
const NativeErrPayload = revo.std_lib.NativeErrPayload;

pub fn register(vm: *VM) !void {
    try root.registerTableFunctions(vm, "io", &[_]root.FuncDef{
        .{ .name = "read", .f = root.define(&.{.table}, read) },
        .{ .name = "cwd", .f = root.define(&.{}, cwd) },
        .{ .name = "system", .f = root.define(&.{.table}, system) },
    });
}

pub fn system(tbl: []const Data, vm: *VM) !NativeResult {
    const args = tbl[0].table;

    const table = try vm.tables.get(args);

    var argv = try vm.runtime.alloc.alloc([]const u8, table.array.items.len);

    defer vm.runtime.alloc.free(argv);
    defer for (argv) |arg| vm.runtime.alloc.free(arg);

    for (table.array.items, 0..) |arg, i|
        argv[i] = try vm.runtime.alloc.dupe(u8, vm.stringValue(arg.string));

    var proc = try std.process.spawn(vm.runtime.io, .{
        .argv = argv,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer _ = proc.wait(vm.runtime.io) catch {};

    var stderr_buf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer stderr_buf.deinit();

    var stdout_buf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer stdout_buf.deinit();

    var read_buf: [1024]u8 = undefined;
    var stdout_reader = proc.stdout.?.reader(vm.runtime.io, &read_buf);
    _ = try stdout_reader.interface.streamRemaining(&stdout_buf.writer);

    var read_buf2: [1024]u8 = undefined;
    var stderr_reader = proc.stderr.?.reader(vm.runtime.io, &read_buf2);
    _ = try stderr_reader.interface.streamRemaining(&stderr_buf.writer);

    const so = try vm.adoptDataString(try stdout_buf.toOwnedSlice());
    const se = try vm.adoptDataString(try stderr_buf.toOwnedSlice());

    // _ = try proc.wait(vm.runtime.io);

    return .Ok(vm, .{ .tuple = try vm.tuples.create(&[2]Data{ so, se }) });
}

pub fn read(args: []const Data, vm: *VM) !NativeResult {
    if (args.len > 1) return .errArity(args.len, 1);

    var delimiter: u8 = '\n';
    var read_path: []const u8 = "/dev/stdin";

    if (args.len == 1) {
        const table_id = switch (args[0]) {
            .table => |id| id,
            else => return .errType(0, "table", revo.std_lib.typeof(args[0])),
        };
        const table = try vm.tables.get(table_id);

        const path_key = Data.new.atom(try vm.internAtom("path"));
        const rpath_in = try table.get(path_key, vm) orelse Data.new.nil();
        read_path = switch (rpath_in) {
            .string => |id| vm.stringValue(id),
            .atom => |atom| if (atom == revo.core_atoms.atom_id(.nil))
                read_path
            else
                return .errType(0, "string", revo.std_lib.typeof(rpath_in)),
            else => return .errType(
                0,
                "string",
                revo.std_lib.typeof(rpath_in),
            ),
        };

        const delim_key = Data.new.atom(try vm.internAtom("delimiter"));
        const delim_in = try table.get(delim_key, vm) orelse Data.new.nil();
        delimiter = switch (delim_in) {
            .string => |id| blk: {
                const s = vm.stringValue(id);
                break :blk if (s.len == 1)
                    s[0]
                else
                    return .errType(0, "single char string", "string");
            },
            .atom => |atom| if (atom == revo.core_atoms.atom_id(.nil))
                delimiter
            else
                return .errType(0, "string", revo.std_lib.typeof(delim_in)),
            else => return .errType(0, "string", revo.std_lib.typeof(delim_in)),
        };
    }

    const resolved_path = try resolveOsPath(read_path, vm.module_dir, vm);
    defer if (!std.mem.eql(u8, resolved_path, "/dev/stdin")) vm.runtime.alloc.free(resolved_path);

    const file, const should_close =
        if (std.mem.eql(u8, resolved_path, "/dev/stdin"))
            .{ std.Io.File.stdin(), false }
        else
            .{
                std.Io.Dir.openFileAbsolute(vm.runtime.io, resolved_path, .{}) catch
                    return revo.std_lib.resultTuple(vm, .err, try vm.ownDataString("ReadError")),
                true,
            };

    defer if (should_close) file.close(vm.runtime.io);

    var buf: [512]u8 = undefined;
    var r = file.reader(vm.runtime.io, &buf);
    var w = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer w.deinit();

    _ = try r.interface.streamDelimiter(&w.writer, delimiter);
    const result_str = try w.toOwnedSlice();

    return revo.std_lib.resultTuple(vm, .ok, try vm.adoptDataString(result_str));
}

pub fn cwd(args: []const Data, vm: *VM) !NativeResult {
    _ = args;
    const cwd_path = try std.Io.Dir.cwd().realPathFileAlloc(vm.runtime.io, ".", vm.runtime.alloc);
    defer vm.runtime.alloc.free(cwd_path);
    return .{ .ok = try vm.ownDataString(cwd_path) };
}

pub fn import_(args: []const Data, vm: *VM) !NativeResult {
    if (args.len != 1) return .{ .err = .{ .wrong_arity = .{ .got = args.len, .expected = 1 } } };

    const raw_path = switch (args[0]) {
        .string => |id| vm.stringValue(id),
        else => return .{ .err = .{ .type_error = .{
            .arg = 0,
            .expected = "string",
            .got = revo.std_lib.dataToString(args[0]),
        } } },
    };

    const resolved_path = try resolveImportPath(raw_path, vm.module_dir, vm);
    defer vm.runtime.alloc.free(resolved_path);

    if (vm.module_cache.get(resolved_path)) |cached| return .{ .ok = cached };
    if (vm.loading_modules.contains(resolved_path)) return error.CyclicImport;

    const source = try std.Io.Dir.cwd().readFileAlloc(
        vm.runtime.io,
        resolved_path,
        vm.runtime.alloc,
        std.Io.Limit.unlimited,
    );
    defer vm.runtime.alloc.free(source);

    const loading_key = try vm.runtime.alloc.dupe(u8, resolved_path);
    var loading_key_added = false;
    defer {
        if (loading_key_added) _ = vm.loading_modules.remove(loading_key);
        vm.runtime.alloc.free(loading_key);
    }
    try vm.loading_modules.put(loading_key, {});
    loading_key_added = true;

    const cache_key = try vm.runtime.alloc.dupe(u8, resolved_path);
    errdefer vm.runtime.alloc.free(cache_key);

    const result = vm.runModule(resolved_path, source) catch |err| {
        return if (err == error.OutOfMemory) error.OutOfMemory else err;
    };

    try vm.module_cache.put(cache_key, result);
    return .{ .ok = result };
}

fn resolveOsPath(raw_path: []const u8, base_dir: ?[]const u8, vm: *VM) ![]const u8 {
    if (std.mem.eql(u8, raw_path, "/dev/stdin")) return "/dev/stdin";
    return vm_path.resolve(raw_path, base_dir, vm.runtime.io, vm.runtime.alloc);
}

fn resolveImportPath(raw_path: []const u8, base_dir: ?[]const u8, vm: *VM) ![]const u8 {
    const resolved = try vm_path.resolve(raw_path, base_dir, vm.runtime.io, vm.runtime.alloc);
    errdefer vm.runtime.alloc.free(resolved);

    if (std.fs.path.extension(resolved).len != 0) return resolved;

    const with_ext = try vm_path.withDefaultExtension(resolved, "rv", vm.runtime.alloc);
    vm.runtime.alloc.free(resolved);
    return with_ext;
}

const testing = revo.lang.testing;
test "import native rejects wrong arity" {
    var vm = try VM.init(testing.runtime());
    defer vm.deinit();
    const result = try import_(&.{}, &vm);
    try std.testing.expectEqual(true, result == .err);
}
