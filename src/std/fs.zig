const Ts = root.T;

const OpenMode = enum { r, w, a };

const open_modes = std.StaticStringMap(OpenMode).initComptime(.{
    .{ "r", .r },
    .{ "w", .w },
    .{ "a", .a },
});

const dir_default: f64 = if (builtin.target.os.tag == .windows) 0 else 0o777;
const file_default: f64 = if (builtin.target.os.tag == .windows) 0 else 0o666;

pub const Impl = struct {
    pub const @"fs.readdir" = readdirImpl(Ts.string);

    pub const @"file.readdir" = readdirImpl(Ts.table);

    pub fn @"fs.exists?"(vm: *VM, path: Ts.string) !HostResult {
        const expanded = expandPath(vm, vm.stringValue(@intFromEnum(path))) catch |err| return progErr(err);
        defer vm.runtime.alloc.free(expanded);

        probe(vm, expanded) catch |err| switch (err) {
            error.FileNotFound => return .{ .ok = Data.new.boolean(false) },
            else => return .errIo(@errorName(err)),
        };

        return .{ .ok = Data.new.boolean(true) };
    }

    pub fn @"fs.remove"(vm: *VM, path: Ts.string, recursive: Ts.Optional(.bool, false)) !HostResult {
        const expanded = expandPath(vm, vm.stringValue(@intFromEnum(path))) catch |err| return progErr(err);
        defer vm.runtime.alloc.free(expanded);

        if (recursive.value) {
            try Dir.cwd().deleteTree(vm.runtime.io, expanded);
            return .Ok(vm, revo.Data.new.core(.ok));
        }

        Dir.cwd().deleteFile(vm.runtime.io, expanded) catch |err| switch (err) {
            error.IsDir => {
                try Dir.cwd().deleteDir(vm.runtime.io, expanded);
                return .Ok(vm, revo.Data.new.core(.ok));
            },
            else => return err,
        };

        return .Ok(vm, revo.Data.new.core(.ok));
    }

    pub fn @"fs.mkdir"(vm: *VM, path: Ts.string, parents: Ts.Optional(.bool, false), permissions: Ts.Optional(.number, dir_default)) !HostResult {
        const expanded = expandPath(vm, vm.stringValue(@intFromEnum(path))) catch |err| return progErr(err);
        defer vm.runtime.alloc.free(expanded);

        const perms = numPermissions(permissions.value) catch return .errType(1, "integer permissions", "number");

        if (parents.value) {
            _ = try Dir.cwd().createDirPathStatus(vm.runtime.io, expanded, perms);
        } else {
            try Dir.cwd().createDir(vm.runtime.io, expanded, perms);
        }

        return .Ok(vm, revo.Data.new.core(.ok));
    }

    pub fn @"fs.touch"(vm: *VM, path: Ts.string) !HostResult {
        const expanded = expandPath(vm, vm.stringValue(@intFromEnum(path))) catch |err| return progErr(err);
        defer vm.runtime.alloc.free(expanded);

        if (probe(vm, expanded)) {
            return .Ok(vm, revo.Data.new.core(.ok));
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        const file = if (std.fs.path.isAbsolute(expanded))
            Dir.createFileAbsolute(vm.runtime.io, expanded, .{ .truncate = false })
        else
            Dir.cwd().createFile(vm.runtime.io, expanded, .{ .truncate = false });

        const f = try file;
        defer f.close(vm.runtime.io);

        return .Ok(vm, revo.Data.new.core(.ok));
    }

    pub fn @"fs.copy"(vm: *VM, src: Ts.string, dst: Ts.string) !HostResult {
        const from = expandPath(vm, vm.stringValue(@intFromEnum(src))) catch |err| return progErr(err);
        defer vm.runtime.alloc.free(from);
        const to = expandPath(vm, vm.stringValue(@intFromEnum(dst))) catch |err| return progErr(err);
        defer vm.runtime.alloc.free(to);

        const st = try Dir.cwd().statFile(vm.runtime.io, from, .{});
        if (st.kind == .directory) return error.IsDir;

        try Dir.cwd().copyFile(from, Dir.cwd(), to, vm.runtime.io, .{});

        return .Ok(vm, revo.Data.new.core(.ok));
    }

    pub fn @"fs.rename"(vm: *VM, old_path: Ts.string, new_path: Ts.string) !HostResult {
        const old = expandPath(vm, vm.stringValue(@intFromEnum(old_path))) catch |err| return progErr(err);
        defer vm.runtime.alloc.free(old);
        const new = expandPath(vm, vm.stringValue(@intFromEnum(new_path))) catch |err| return progErr(err);
        defer vm.runtime.alloc.free(new);

        try Dir.cwd().rename(old, Dir.cwd(), new, vm.runtime.io);

        return .Ok(vm, revo.Data.new.core(.ok));
    }

    pub fn @"file.read"(vm: *VM, self: Ts.table) !HostResult {
        const this = Data.new.table(@intFromEnum(self));
        const handle = parseFileHandle(this, vm) catch |err| return progErr(err);

        const st = try Dir.cwd().statFile(vm.runtime.io, handle.path, .{});
        if (st.size > max_read_size) return error.FileTooLarge;

        const data = try Dir.cwd().readFileAlloc(
            vm.runtime.io,
            handle.path,
            vm.runtime.alloc,
            .limited(max_read_size),
        );

        return .Ok(vm, try vm.adoptDataString(data));
    }

    pub fn @"file.write"(vm: *VM, self: Ts.table, data: Ts.string, append: Ts.Optional(.bool, false), permissions: Ts.Optional(.number, file_default)) !HostResult {
        const this = Data.new.table(@intFromEnum(self));
        const handle = parseFileHandle(this, vm) catch |err| return progErr(err);
        const text = vm.stringValue(@intFromEnum(data));
        const perms = numPermissions(permissions.value) catch return .errType(2, "integer permissions", "number");

        if (append.value) {
            const file = Dir.cwd().openFile(vm.runtime.io, handle.path, .{ .mode = .read_write }) catch |err| switch (err) {
                error.FileNotFound => try Dir.cwd().createFile(vm.runtime.io, handle.path, .{
                    .truncate = false,
                    .permissions = perms,
                }),
                else => return err,
            };
            defer file.close(vm.runtime.io);

            const st = try file.stat(vm.runtime.io);
            try file.writePositionalAll(vm.runtime.io, text, st.size);
        } else {
            try Dir.cwd().writeFile(vm.runtime.io, .{
                .sub_path = handle.path,
                .data = text,
                .flags = .{ .permissions = perms },
            });
        }

        return .Ok(vm, Data.new.num(text.len));
    }

    pub const @"file.stat" = statImpl(Ts.table);

    pub fn @"file.close"(vm: *VM, self: Ts.table) !HostResult {
        const this = Data.new.table(@intFromEnum(self));
        _ = parseFileHandle(this, vm) catch |err| return progErr(err);
        return .Ok(vm, revo.Data.new.core(.ok));
    }

    pub const @"fs.stat" = statImpl(Ts.string);
};

pub const impls: []const api.Impl = if (@import("build_options").is_freestanding)
    &[_]api.Impl{}
else
    root.impls(Impl).val ++ &[_]api.Impl{
        // takes optional mode string, parsed by hand
        .{ .name = "fs.open", .f = root.defineVariadic(&.{.string}, open_fn) },
    };

fn openMode(args: []const Data, vm: *VM) !OpenMode {
    if (args.len < 2) return .r;

    if (args[1].asAtom()) |a| {
        if (a == revo.core_atoms.atomId(.nil) or a == revo.core_atoms.atomId(.none)) return .r;
        return error.InvalidMode;
    }

    const name = if (args[1].asString()) |id| vm.stringValue(id) else return error.InvalidMode;

    return open_modes.get(name) orelse error.InvalidMode;
}

fn open_fn(args: []const Data, vm: *VM) !HostResult {
    const raw = args[0].asString() orelse return .errType(0, "string", root.typeof(args[0], vm));
    const expanded = expandPath(vm, vm.stringValue(raw)) catch |err| return progErr(err);
    defer vm.runtime.alloc.free(expanded);

    const mode = openMode(args, vm) catch {
        const got = if (args[1].asString()) |id| vm.stringValue(id) else root.typeof(args[1], vm);
        return .errType(1, "\"r\", \"w\" or \"a\"", got);
    };

    switch (mode) {
        .r => {
            try probe(vm, expanded);
            return .Ok(vm, try wrapFile(vm, expanded));
        },
        .w => {
            const file = try Dir.cwd().createFile(vm.runtime.io, expanded, .{ .truncate = true });
            defer file.close(vm.runtime.io);
            return .Ok(vm, try wrapFile(vm, expanded));
        },
        .a => {
            const file = Dir.cwd().openFile(vm.runtime.io, expanded, .{ .mode = .read_write }) catch |err| switch (err) {
                error.FileNotFound => try Dir.cwd().createFile(vm.runtime.io, expanded, .{ .truncate = false }),
                else => return err,
            };
            defer file.close(vm.runtime.io);
            return .Ok(vm, try wrapFile(vm, expanded));
        },
    }
}

fn selfPath(vm: *VM, self: anytype) ![]const u8 {
    const T = @TypeOf(self);
    if (comptime T != Ts.string and T != Ts.table) @compileError("fs path or handle expected");
    if (T == Ts.string) {
        return vm.stringValue(@intFromEnum(self));
    } else {
        return (try parseFileHandle(Data.new.table(@intFromEnum(self)), vm)).path;
    }
}

fn statImpl(comptime Self: type) fn (*VM, Self, Ts.Optional(.bool, true)) anyerror!HostResult {
    return struct {
        fn f(vm: *VM, self: Self, follow: Ts.Optional(.bool, true)) anyerror!HostResult {
            const raw = selfPath(vm, self) catch |err| return progErr(err);
            const expanded = expandPath(vm, raw) catch |err| return progErr(err);
            defer vm.runtime.alloc.free(expanded);
            return .Ok(vm, try statPath(vm, expanded, follow.value));
        }
    }.f;
}

fn readdirImpl(comptime Self: type) fn (*VM, Self) anyerror!HostResult {
    return struct {
        fn f(vm: *VM, self: Self) anyerror!HostResult {
            const raw = selfPath(vm, self) catch |err| return progErr(err);
            const expanded = expandPath(vm, raw) catch |err| return progErr(err);
            defer vm.runtime.alloc.free(expanded);
            return .Ok(vm, try listDir(vm, expanded));
        }
    }.f;
}

fn progErr(err: anyerror) HostResult {
    return .other(@errorName(err));
}

// -- [helpers] ---------------------------------------------------------------

fn expandPath(vm: *VM, path: []const u8) ![]u8 {
    if (path.len == 0 or path[0] != '~') return vm.runtime.alloc.dupe(u8, path);

    if (path.len > 1 and path[1] != '/') return error.UnsupportedExpansion;

    const home_z = try vm.runtime.alloc.dupeSentinel(u8, "HOME", 0);
    defer vm.runtime.alloc.free(home_z);

    const home_ptr = std.c.getenv(home_z) orelse return error.NoHome;
    const home = std.mem.span(home_ptr);

    if (path.len == 1) return vm.runtime.alloc.dupe(u8, home);

    return std.mem.concat(vm.runtime.alloc, u8, &.{ home, path[1..] });
}

fn numPermissions(n: f64) !File.Permissions {
    if (!std.math.isFinite(n) or @floor(n) != n) return error.InvalidPermissions;
    const raw: PermTag = @intFromFloat(n);
    return @as(File.Permissions, @enumFromInt(raw));
}

fn probe(vm: *VM, path: []const u8) !void {
    const file = if (std.fs.path.isAbsolute(path))
        Dir.openFileAbsolute(vm.runtime.io, path, .{ .allow_directory = true, .path_only = true })
    else
        Dir.cwd().openFile(vm.runtime.io, path, .{ .allow_directory = true, .path_only = true });

    const f = try file;
    defer f.close(vm.runtime.io);
}

fn listDir(vm: *VM, path: []const u8) !Data {
    const open_dir = try Dir.cwd().openDir(vm.runtime.io, path, .{ .iterate = true });
    defer open_dir.close(vm.runtime.io);
    var iter = open_dir.iterate();

    var entries = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, 16);
    defer entries.deinit(vm.runtime.alloc);

    while (try iter.next(vm.runtime.io)) |ent| {
        const entry_table = try vm.tables.create();
        try vm.putField(entry_table, "name", try vm.ownDataString(ent.name));
        try vm.putField(entry_table, "kind", try vm.dataAtom(kindName(ent.kind)));
        try entries.append(vm.runtime.alloc, Data.new.table(entry_table));
    }

    return try vm.tableOfSlice(entries.items);
}

fn statPath(vm: *VM, path: []const u8, follow: bool) !Data {
    const st = try Dir.cwd().statFile(vm.runtime.io, path, .{ .follow_symlinks = follow });
    return makeStatTable(vm, st);
}

const path_key = "__path";
pub const max_read_size = 1024 * 1024 * 1024;
const PermTag = @typeInfo(File.Permissions).@"enum".tag_type;

const FileHandle = struct {
    path: []const u8,
};

fn wrapFile(vm: *VM, path: []const u8) !Data {
    const file_table = try vm.tables.create();
    try vm.putField(file_table, path_key, try vm.ownDataString(path));

    const metatable = try vm.tables.create();
    const file_module = vm.globals.get(revo.core_atoms.file.atomId()) orelse return error.FileModuleNotFound;
    try vm.putField(metatable, "__index", file_module);

    const set_result = try meta.set_meta(&.{ Data.new.table(file_table), Data.new.table(metatable) }, vm);
    if (set_result != .ok) return error.SetMetatableFailed;
    return Data.new.table(file_table);
}

fn parseFileHandle(value: Data, vm: *VM) !FileHandle {
    if (!value.isTable()) return error.InvalidFile;

    const path_data = vm.getField(value, path_key) orelse return error.InvalidFile;

    return .{
        .path = if (path_data.asString()) |id| vm.stringValue(id) else return error.InvalidFile,
    };
}

fn kindName(kind: File.Kind) []const u8 {
    return switch (kind) {
        .sym_link => "symlink",
        else => |e| @tagName(e),
    };
}

fn makeStatTable(vm: *VM, stat: File.Stat) !Data {
    const table = try vm.tables.create();

    try vm.putField(table, "size", Data.new.num(stat.size));
    try vm.putField(table, "kind", try vm.dataAtom(@tagName(stat.kind)));
    try vm.putField(table, "permissions", Data.new.num(@intFromEnum(stat.permissions)));
    try vm.putField(table, "mtime", Data.new.num(stat.mtime.toSeconds()));
    try vm.putField(table, "atime", Data.new.num((stat.atime orelse stat.mtime).toSeconds()));
    try vm.putField(table, "ctime", Data.new.num(stat.ctime.toSeconds()));

    return Data.new.table(table);
}

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
        \\ fs.open('{s}')?:read()?
    , file_path);
    defer alloc.free(source);

    try testing.topString(source, "hello from fs");
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
        \\ const f = fs.open('{s}')?
        \\ f:write("new value", :false)?
        \\ f:read()?
    , file_path);
    defer alloc.free(source);

    try testing.topString(source, "new value");
}

test "fs.write appends with flag" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "app.txt", .data = "hello" });

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);
    const file_path = try std.fs.path.join(alloc, &.{ dir_path, "app.txt" });
    defer alloc.free(file_path);

    const source = try sourceForPath(
        \\ const f = fs.open('{s}')?
        \\ f:write(" world", :true)?
        \\ f:read()?
    , file_path);
    defer alloc.free(source);

    try testing.topString(source, "hello world");
}

test "fs.readdir returns table of entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "b" });

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);

    const source = try sourceForPath(
        \\ type(fs.readdir('{s}')?) == :table
    , dir_path);
    defer alloc.free(source);
    try testing.topTrue(source);
}

test "fs.readdir returns entries with name and kind" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "x.txt", .data = "hello" });
    try tmp.dir.writeFile(io, .{ .sub_path = "y.txt", .data = "world" });

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);

    const source = try sourceForPath(
        \\ const entries = fs.readdir('{s}')?
        \\ const e1 = entries[1]
        \\ e1.name != :nil and e1.kind != :nil
    , dir_path);
    defer alloc.free(source);
    try testing.topTrue(source);
}

test "fs.dir:readdir() returns entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "z.txt", .data = "test" });

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);

    const source = try sourceForPath(
        \\ const dir = fs.open('{s}')?
        \\ const entries = dir:readdir()?
        \\ type(entries) == :table
    , dir_path);
    defer alloc.free(source);
    try testing.topTrue(source);
}

test "fs.readdir works with current directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "c.txt", .data = "data" });

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);

    const source = try sourceForPath(
        \\ const entries = fs.readdir('{s}')?
        \\ type(entries) == :table
    , dir_path);
    defer alloc.free(source);
    try testing.topTrue(source);
}

test "fs.open w creates missing file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);
    const file_path = try std.fs.path.join(alloc, &.{ dir_path, "new.txt" });
    defer alloc.free(file_path);

    const source = try sourceForPath(
        \\ const f = fs.open('{s}', "w")?
        \\ f:write("created")?
        \\ f:read()?
    , file_path);
    defer alloc.free(source);

    try testing.topString(source, "created");
}

test "fs.open w truncates existing file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "t.txt", .data = "old content here" });

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);
    const file_path = try std.fs.path.join(alloc, &.{ dir_path, "t.txt" });
    defer alloc.free(file_path);

    const source = try std.fmt.allocPrint(alloc,
        \\ fs.open('{s}', "w")?:close()
        \\ fs.open('{s}')?:read()?
    , .{ file_path, file_path });
    defer alloc.free(source);

    try testing.topString(source, "");
}

test "fs.open a creates missing file and keeps existing content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "k.txt", .data = "keep" });

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);
    const kept = try std.fs.path.join(alloc, &.{ dir_path, "k.txt" });
    defer alloc.free(kept);
    const made = try std.fs.path.join(alloc, &.{ dir_path, "made.txt" });
    defer alloc.free(made);

    const source = try std.fmt.allocPrint(alloc,
        \\ fs.open('{s}', "a")?:close()
        \\ fs.open('{s}', "a")?:close()
        \\ fs.open('{s}')?:read()?
    , .{ made, kept, kept });
    defer alloc.free(source);

    try testing.topString(source, "keep");
}

test "fs.open missing file in r mode is FileNotFound" {
    const source = try sourceForPath(
        \\ match fs.open('{s}/nope.txt') | {{:err, e}} => e | _ => :ok
    , "/tmp/revo-fs-test-missing-12345");
    defer alloc.free(source);

    try testing.topAtom(source, "FileNotFound");
}

test "fs.open unknown mode is a type error" {
    try testing.expectRuntimeError(
        \\ fs.open('/tmp/revo-fs-test-missing-12345', "x")
    , .TypeError);
}

test "fs.open non-string path is a compile error" {
    try testing.expectCompileFailure(
        \\ fs.open(42)
    , .ParseError, 1, 10, "arg 1 (`path`) to `open` wants string, got number");
}

test "fs.touch creates missing file and leaves existing content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "e.txt", .data = "stay" });

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);
    const kept = try std.fs.path.join(alloc, &.{ dir_path, "e.txt" });
    defer alloc.free(kept);
    const made = try std.fs.path.join(alloc, &.{ dir_path, "touched.txt" });
    defer alloc.free(made);

    const source = try std.fmt.allocPrint(alloc,
        \\ fs.touch('{s}')
        \\ fs.touch('{s}')
        \\ fs.open('{s}')?:read()?
    , .{ made, kept, kept });
    defer alloc.free(source);

    try testing.topString(source, "stay");
}

test "fs.mkdir parents flag creates nested parents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);
    const nested = try std.fs.path.join(alloc, &.{ dir_path, "a", "b", "c" });
    defer alloc.free(nested);

    const source = try std.fmt.allocPrint(alloc,
        \\ fs.mkdir('{s}', :true)
        \\ fs.exists?('{s}')
    , .{ nested, nested });
    defer alloc.free(source);

    try testing.topTrue(source);
}

test "fs.copy roundtrips contents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "src.txt", .data = "copied!" });

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);
    const src = try std.fs.path.join(alloc, &.{ dir_path, "src.txt" });
    defer alloc.free(src);
    const dst = try std.fs.path.join(alloc, &.{ dir_path, "dst.txt" });
    defer alloc.free(dst);

    const source = try std.fmt.allocPrint(alloc,
        \\ fs.copy('{s}', '{s}')
        \\ fs.open('{s}')?:read()?
    , .{ src, dst, dst });
    defer alloc.free(source);

    try testing.topString(source, "copied!");
}

test "fs.remove recursive deletes tree" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);
    const tree = try std.fs.path.join(alloc, &.{ dir_path, "tree" });
    defer alloc.free(tree);
    const deep = try std.fs.path.join(alloc, &.{ dir_path, "tree", "sub", "deep.txt" });
    defer alloc.free(deep);

    const source = try std.fmt.allocPrint(alloc,
        \\ fs.mkdir('{s}/sub', :true)
        \\ fs.touch('{s}')
        \\ fs.remove('{s}', :true)
        \\ fs.exists?('{s}') == :false
    , .{ tree, deep, tree, tree });
    defer alloc.free(source);

    try testing.topTrue(source);
}

test "fs.remove non-recursive on non-empty dir is DirNotEmpty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "full");
    try tmp.dir.writeFile(io, .{ .sub_path = "full/f.txt", .data = "x" });

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);

    const source = try sourceForPath(
        \\ match fs.remove('{s}/full') | {{:err, e}} => e | _ => :ok
    , dir_path);
    defer alloc.free(source);

    try testing.topAtom(source, "DirNotEmpty");
}

test "fs.remove explicit false is not recursive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "full");
    try tmp.dir.writeFile(io, .{ .sub_path = "full/f.txt", .data = "x" });

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);

    const source = try sourceForPath(
        \\ match fs.remove('{s}/full', :false) | {{:err, e}} => e | _ => :ok
    , dir_path);
    defer alloc.free(source);

    try testing.topAtom(source, "DirNotEmpty");
}

test "fs expands tilde to home" {
    const source =
        \\ fs.exists?("~/")
    ;
    try testing.topTrue(source);
}

test "fs rejects tilde user paths" {
    try testing.expectRuntimeError(
        \\ fs.exists?("~nosuchuser12345/x")
    , .Panic);
}

test "fs.read on non-handle raises" {
    try testing.expectRuntimeError(
        \\ file.read({})
    , .Panic);
}

test "fs.mkdir with fractional permissions is a type error" {
    try testing.expectRuntimeError(
        \\ fs.mkdir("/tmp/revo-fs-test-missing-12345", :false, 1.5)
    , .TypeError);
}

test "fs.stat reads size from path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "s.txt", .data = "12345" });

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);
    const file_path = try std.fs.path.join(alloc, &.{ dir_path, "s.txt" });
    defer alloc.free(file_path);

    const source = try sourceForPath(
        \\ fs.stat('{s}')?.size
    , file_path);
    defer alloc.free(source);

    try testing.topNumber(source, 5);
}

test "fs.stat follow flag sees through symlinks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "real.txt", .data = "12345" });
    try tmp.dir.symLink(io, "real.txt", "link.txt", .{});

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);
    const link_path = try std.fs.path.join(alloc, &.{ dir_path, "link.txt" });
    defer alloc.free(link_path);

    const source = try std.fmt.allocPrint(alloc,
        \\ string({{fs.stat('{s}')?.kind, fs.stat('{s}', :false)?.kind}})
    , .{ link_path, link_path });
    defer alloc.free(source);

    try testing.topString(source, "{ :file, :sym_link }");
}

test "file.stat follow flag reads metadata from handle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "h.txt", .data = "12345" });

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);
    const file_path = try std.fs.path.join(alloc, &.{ dir_path, "h.txt" });
    defer alloc.free(file_path);

    const source = try std.fmt.allocPrint(alloc,
        \\ const f = fs.open('{s}')?
        \\ string({{f:stat()?.size, f:stat(:false)?.size}})
    , .{file_path});
    defer alloc.free(source);

    try testing.topString(source, "{ 5, 5 }");
}

const std = @import("std");
const Dir = std.Io.Dir;
const File = std.Io.File;
const io = std.testing.io;
const alloc = std.testing.allocator;
const builtin = @import("builtin");

const revo = @import("../root.zig");
const Data = revo.Data;
const VM = revo.VM;
const testing = revo.lang.testing;
const api = @import("api.zig");
const meta = @import("meta.zig");
const root = @import("root.zig");
const HostResult = root.HostResult;
