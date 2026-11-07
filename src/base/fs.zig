const Args = root.host.ArgTypes;

const OpenMode = enum { r, w, a };

const open_modes = std.StaticStringMap(OpenMode).initComptime(.{
    .{ "r", .r },
    .{ "w", .w },
    .{ "a", .a },
});

const dir_default: f64 = if (builtin.target.os.tag == .windows) 0 else 0o777;
const file_default: f64 = if (builtin.target.os.tag == .windows) 0 else 0o666;

pub const Impl = struct {
    pub const @"fs.readdir" = readdirImpl(Args.string);

    pub const @"file.readdir" = readdirImpl(Args.table);

    pub fn @"fs.chdir"(vm: *VM, path: Args.string) !HostResult {
        _ = vm;
        _ = path;

        return .{ .ok = Value.new.core(.ok) };
    }

    // TODO(gusic): add support for patterns with ".." in them
    // TODO(gusic): add support for recursive matching
    // TODO(gusic): make use of depth limit
    pub fn @"fs.glob"(vm: *VM, pattern: Args.string, recursive: Args.Optional(.bool, false), depth_limit: Args.Optional(.number, 100)) !HostResult {
        _ = recursive;
        _ = depth_limit;

        const extracted_pattern = vm.stringValue(@backingInt(pattern));

        const pattern_ = try vm.runtime.alloc.alloc(u8, extracted_pattern.len);
        defer vm.runtime.alloc.free(pattern_);

        _ = std.mem.replace(u8, extracted_pattern, "\\", "/", pattern_);

        var real_pattern = std.mem.splitScalar(u8, pattern_, '/');

        var paths: std.ArrayList([]const u8) = try .initCapacity(vm.runtime.alloc, 10);
        defer {
            for (paths.items) |path| vm.runtime.alloc.free(path);

            paths.deinit(vm.runtime.alloc);
        }

        try paths.append(vm.runtime.alloc, try vm.runtime.alloc.dupe(u8, "."));

        while (real_pattern.next()) |pat| {
            // gusic: I did this because paths needs to be mutated while it is being iterated on
            var old_paths = paths;
            defer {
                for (old_paths.items) |path| vm.runtime.alloc.free(path);

                old_paths.deinit(vm.runtime.alloc);
            }

            paths = try .initCapacity(vm.runtime.alloc, old_paths.capacity);

            for (old_paths.items) |path| {
                var cwd = Dir.cwd().openDir(vm.runtime.io, path, .{ .iterate = true }) catch |err| switch (err) {
                    error.NotDir => continue,

                    else => @panic(@errorName(err)),
                };

                defer cwd.close(vm.runtime.io);

                var it = cwd.iterate();

                while (try it.next(vm.runtime.io)) |entry| {
                    if (entry.name[0] == '.') continue; // gusic: skip any hidden files

                    if (glob.match(pat, entry.name)) {
                        const joined_path = try Dir.path.join(vm.runtime.alloc, &.{ path, entry.name });
                        try paths.append(vm.runtime.alloc, joined_path);
                    }
                }
            }
        }

        const table_id = try vm.tables.create();
        var table = try vm.tables.get(table_id);

        for (paths.items) |path| {
            const path_value = try vm.ownValueStringNoDedup(path);
            try table.push(vm.runtime.alloc, path_value);
        }

        return .data(Value.new.table(table_id));
    }

    pub fn @"fs.exists?"(vm: *VM, path: Args.string) !HostResult {
        const expanded = expandPath(vm, vm.stringValue(@backingInt(path))) catch |err| return progErr(err);
        defer vm.runtime.alloc.free(expanded);

        probe(vm, expanded) catch |err| switch (err) {
            error.FileNotFound => return .{ .ok = Value.new.boolean(false) },
            else => return .errIo(@errorName(err)),
        };

        return .{ .ok = Value.new.boolean(true) };
    }

    pub fn @"fs.remove"(vm: *VM, path: Args.string, recursive: Args.Optional(.bool, false)) !HostResult {
        const expanded = expandPath(vm, vm.stringValue(@backingInt(path))) catch |err| return progErr(err);
        defer vm.runtime.alloc.free(expanded);

        if (recursive.value) {
            try Dir.cwd().deleteTree(vm.runtime.io, expanded);
            return .Ok(vm, revo.Value.new.core(.ok));
        }

        Dir.cwd().deleteFile(vm.runtime.io, expanded) catch |err| switch (err) {
            error.IsDir => {
                try Dir.cwd().deleteDir(vm.runtime.io, expanded);
                return .Ok(vm, revo.Value.new.core(.ok));
            },
            else => return err,
        };

        return .Ok(vm, revo.Value.new.core(.ok));
    }

    pub fn @"fs.mkdir"(vm: *VM, path: Args.string, parents: Args.Optional(.bool, false), permissions: Args.Optional(.number, dir_default)) !HostResult {
        const expanded = expandPath(vm, vm.stringValue(@backingInt(path))) catch |err| return progErr(err);
        defer vm.runtime.alloc.free(expanded);

        const perms = numPermissions(permissions.value) catch return .errType(1, "integer permissions", "number");

        if (parents.value) {
            _ = try Dir.cwd().createDirPathStatus(vm.runtime.io, expanded, perms);
        } else {
            try Dir.cwd().createDir(vm.runtime.io, expanded, perms);
        }

        return .Ok(vm, revo.Value.new.core(.ok));
    }

    pub fn @"fs.touch"(vm: *VM, path: Args.string) !HostResult {
        const expanded = expandPath(vm, vm.stringValue(@backingInt(path))) catch |err| return progErr(err);
        defer vm.runtime.alloc.free(expanded);

        if (probe(vm, expanded)) {
            return .Ok(vm, revo.Value.new.core(.ok));
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        const file = if (std.Io.Dir.path.isAbsolute(expanded))
            Dir.createFileAbsolute(vm.runtime.io, expanded, .{ .truncate = false })
        else
            Dir.cwd().createFile(vm.runtime.io, expanded, .{ .truncate = false });

        const f = try file;
        defer f.close(vm.runtime.io);

        return .Ok(vm, revo.Value.new.core(.ok));
    }

    pub fn @"fs.copy"(vm: *VM, src: Args.string, dst: Args.string) !HostResult {
        const from = expandPath(vm, vm.stringValue(@backingInt(src))) catch |err| return progErr(err);
        defer vm.runtime.alloc.free(from);
        const to = expandPath(vm, vm.stringValue(@backingInt(dst))) catch |err| return progErr(err);
        defer vm.runtime.alloc.free(to);

        const st = try Dir.cwd().statFile(vm.runtime.io, from, .{});
        if (st.kind == .directory) return error.IsDir;

        try Dir.cwd().copyFile(from, Dir.cwd(), to, vm.runtime.io, .{});

        return .Ok(vm, revo.Value.new.core(.ok));
    }

    pub fn @"fs.rename"(vm: *VM, old_path: Args.string, new_path: Args.string) !HostResult {
        const old = expandPath(vm, vm.stringValue(@backingInt(old_path))) catch |err| return progErr(err);
        defer vm.runtime.alloc.free(old);
        const new = expandPath(vm, vm.stringValue(@backingInt(new_path))) catch |err| return progErr(err);
        defer vm.runtime.alloc.free(new);

        try Dir.cwd().rename(old, Dir.cwd(), new, vm.runtime.io);

        return .Ok(vm, revo.Value.new.core(.ok));
    }

    pub fn @"file.read"(vm: *VM, self: Args.table) !HostResult {
        const this = Value.new.table(@backingInt(self));
        const handle = parseFileHandle(this, vm) catch |err| return progErr(err);

        const path = try vm.runtime.alloc.dupe(u8, handle.path);
        defer vm.runtime.alloc.free(path);

        const depth = revo.vm.dispatch.gilDropForBlocking(vm);
        errdefer revo.vm.dispatch.gilTakeAfterBlocking(vm, depth);

        const st = try Dir.cwd().statFile(vm.runtime.io, path, .{});
        if (st.size > max_read_size) return error.FileTooLarge;

        const data = try Dir.cwd().readFileAlloc(
            vm.runtime.io,
            path,
            vm.runtime.alloc,
            .limited(max_read_size),
        );

        revo.vm.dispatch.gilTakeAfterBlocking(vm, depth);

        return .Ok(vm, try vm.adoptValueString(data));
    }

    pub fn @"file.write"(vm: *VM, self: Args.table, data: Args.string, append: Args.Optional(.bool, false), permissions: Args.Optional(.number, file_default)) !HostResult {
        const this = Value.new.table(@backingInt(self));
        const handle = parseFileHandle(this, vm) catch |err| return progErr(err);
        const perms = numPermissions(permissions.value) catch return .errType(2, "integer permissions", "number");

        const path = try vm.runtime.alloc.dupe(u8, handle.path);
        defer vm.runtime.alloc.free(path);
        const text = try vm.runtime.alloc.dupe(u8, vm.stringValue(@backingInt(data)));
        defer vm.runtime.alloc.free(text);

        const depth = revo.vm.dispatch.gilDropForBlocking(vm);
        errdefer revo.vm.dispatch.gilTakeAfterBlocking(vm, depth);

        if (append.value) {
            const file = Dir.cwd().openFile(vm.runtime.io, path, .{ .mode = .read_write }) catch |err| switch (err) {
                error.FileNotFound => try Dir.cwd().createFile(vm.runtime.io, path, .{
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
                .sub_path = path,
                .data = text,
                .flags = .{ .permissions = perms },
            });
        }

        revo.vm.dispatch.gilTakeAfterBlocking(vm, depth);

        return .Ok(vm, Value.new.num(text.len));
    }

    pub const @"file.stat" = statImpl(Args.table);

    pub fn @"file.close"(vm: *VM, self: Args.table) !HostResult {
        const this = Value.new.table(@backingInt(self));
        _ = parseFileHandle(this, vm) catch |err| return progErr(err);
        return .Ok(vm, revo.Value.new.core(.ok));
    }

    pub const @"fs.stat" = statImpl(Args.string);
};

pub const impls: []const specs.Impl = if (!revo.default_caps.io)
    &[_]specs.Impl{}
else
    root.host.impls(Impl).val ++ &[_]specs.Impl{
        // takes optional mode string, parsed by hand
        .{ .name = "fs.open", .f = root.host.defineVariadic(&.{.string}, open_fn) },
    };

fn openMode(args: []const Value, vm: *VM) !OpenMode {
    if (args.len < 2) return .r;

    if (args[1].asAtom()) |a| {
        if (a == revo.CoreAtoms.atomId(.nil) or a == revo.CoreAtoms.atomId(.none)) return .r;
        return error.InvalidMode;
    }

    const name = if (args[1].asString()) |id| vm.stringValue(id) else return error.InvalidMode;

    return open_modes.get(name) orelse error.InvalidMode;
}

fn open_fn(args: []const Value, vm: *VM) !HostResult {
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
    if (comptime T != Args.string and T != Args.table) @compileError("fs path or handle expected");
    if (T == Args.string) {
        return vm.stringValue(@backingInt(self));
    } else {
        return (try parseFileHandle(Value.new.table(@backingInt(self)), vm)).path;
    }
}

fn statImpl(comptime Self: type) fn (*VM, Self, Args.Optional(.bool, true)) anyerror!HostResult {
    return struct {
        fn f(vm: *VM, self: Self, follow: Args.Optional(.bool, true)) anyerror!HostResult {
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

// Anything that isn't a pattern

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
    return @as(File.Permissions, @fromBackingInt(@intCast(raw)));
}

fn probe(vm: *VM, path: []const u8) !void {
    const file = if (std.Io.Dir.path.isAbsolute(path))
        Dir.openFileAbsolute(vm.runtime.io, path, .{ .allow_directory = true, .path_only = true })
    else
        Dir.cwd().openFile(vm.runtime.io, path, .{ .allow_directory = true, .path_only = true });

    const f = try file;
    defer f.close(vm.runtime.io);
}

fn listDir(vm: *VM, path: []const u8) !Value {
    const open_dir = try Dir.cwd().openDir(vm.runtime.io, path, .{ .iterate = true });
    defer open_dir.close(vm.runtime.io);
    var iter = open_dir.iterate();

    var entries = try std.ArrayList(Value).initCapacity(vm.runtime.alloc, 16);
    defer entries.deinit(vm.runtime.alloc);

    while (try iter.next(vm.runtime.io)) |ent| {
        const entry_table = try vm.tables.create();
        try vm.putField(entry_table, "name", try vm.ownValueString(ent.name));
        try vm.putField(entry_table, "kind", try vm.atomValue(kindName(ent.kind)));
        try entries.append(vm.runtime.alloc, Value.new.table(entry_table));
    }

    return try vm.tableOfSlice(entries.items);
}

fn statPath(vm: *VM, path: []const u8, follow: bool) !Value {
    const st = try Dir.cwd().statFile(vm.runtime.io, path, .{ .follow_symlinks = follow });
    return makeStatTable(vm, st);
}

const path_key = "__path";
pub const max_read_size = 1024 * 1024 * 1024;
const PermTag = @typeInfo(File.Permissions).@"enum".tag_type;

const FileHandle = struct {
    path: []const u8,
};

fn wrapFile(vm: *VM, path: []const u8) !Value {
    const file_table = try vm.tables.create();
    try vm.putField(file_table, path_key, try vm.ownValueString(path));

    const metatable = try vm.tables.create();
    const file_module = vm.user_globals.get(revo.CoreAtoms.file.atomId()) orelse return error.FileModuleNotFound;
    try vm.putField(metatable, "__index", file_module);

    const set_result = try metatable_mod.set_meta(&.{ Value.new.table(file_table), Value.new.table(metatable) }, vm);
    if (set_result != .ok) return error.SetMetatableFailed;
    return Value.new.table(file_table);
}

fn parseFileHandle(value: Value, vm: *VM) !FileHandle {
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

fn makeStatTable(vm: *VM, stat: File.Stat) !Value {
    const table = try vm.tables.create();

    try vm.putField(table, "size", Value.new.num(stat.size));
    try vm.putField(table, "kind", try vm.atomValue(@tagName(stat.kind)));
    try vm.putField(table, "permissions", Value.new.num(@backingInt(stat.permissions)));
    try vm.putField(table, "mtime", Value.new.num(stat.mtime.toSeconds()));
    try vm.putField(table, "atime", Value.new.num((stat.atime orelse stat.mtime).toSeconds()));
    try vm.putField(table, "ctime", Value.new.num(stat.ctime.toSeconds()));

    return Value.new.table(table);
}

fn sourceForPath(comptime template: []const u8, path: []const u8) ![]u8 {
    return alloc.print(template, .{path});
}

test "fs.glob returning empty table on bogus path" {
    try testing.topString(
        \\ let path = fs.glob "oughhhhhhhh"
        \\ "#{path}"
    , "{}");
}

test "fs.glob wildcards" {
    const source =
        \\ let paths = fs.glob "*.txt"
        \\ "#{paths}"
    ;

    // gusic: i'm not sure this one will work on linux
    // lung: it won't
    // try testing.topString(source, "{ .\\LICENSE.txt }");

    var result = try testing.topResult(source, null);
    defer result.deinit();
    try std.testing.expect(std.mem.find(u8, result.vm.stringValue(result.value.asString().?), "LICENSE.txt") != null);
}

test "fs.open/read reads file contents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello from fs" });

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);
    const file_path = try std.Io.Dir.path.join(alloc, &.{ dir_path, "a.txt" });
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
    const file_path = try std.Io.Dir.path.join(alloc, &.{ dir_path, "w.txt" });
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
    const file_path = try std.Io.Dir.path.join(alloc, &.{ dir_path, "app.txt" });
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
        \\ typeof(fs.readdir('{s}')?) == :table
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
        \\ typeof(entries) == :table
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
        \\ typeof(entries) == :table
    , dir_path);
    defer alloc.free(source);
    try testing.topTrue(source);
}

test "fs.open w creates missing file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);
    const file_path = try std.Io.Dir.path.join(alloc, &.{ dir_path, "new.txt" });
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
    const file_path = try std.Io.Dir.path.join(alloc, &.{ dir_path, "t.txt" });
    defer alloc.free(file_path);

    const source = try alloc.print(
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
    const kept = try std.Io.Dir.path.join(alloc, &.{ dir_path, "k.txt" });
    defer alloc.free(kept);
    const made = try std.Io.Dir.path.join(alloc, &.{ dir_path, "made.txt" });
    defer alloc.free(made);

    const source = try alloc.print(
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
    try testing.expectSemanticFailure(
        \\ fs.open(42)
    , 1, 10, "arg 1 (`path`) to `open` wants string, got number");
}

test "fs.touch creates missing file and leaves existing content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "e.txt", .data = "stay" });

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);
    const kept = try std.Io.Dir.path.join(alloc, &.{ dir_path, "e.txt" });
    defer alloc.free(kept);
    const made = try std.Io.Dir.path.join(alloc, &.{ dir_path, "touched.txt" });
    defer alloc.free(made);

    const source = try alloc.print(
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
    const nested = try std.Io.Dir.path.join(alloc, &.{ dir_path, "a", "b", "c" });
    defer alloc.free(nested);

    const source = try alloc.print(
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
    const src = try std.Io.Dir.path.join(alloc, &.{ dir_path, "src.txt" });
    defer alloc.free(src);
    const dst = try std.Io.Dir.path.join(alloc, &.{ dir_path, "dst.txt" });
    defer alloc.free(dst);

    const source = try alloc.print(
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
    const tree = try std.Io.Dir.path.join(alloc, &.{ dir_path, "tree" });
    defer alloc.free(tree);
    const deep = try std.Io.Dir.path.join(alloc, &.{ dir_path, "tree", "sub", "deep.txt" });
    defer alloc.free(deep);

    const source = try alloc.print(
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
    const file_path = try std.Io.Dir.path.join(alloc, &.{ dir_path, "s.txt" });
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
    const link_path = try std.Io.Dir.path.join(alloc, &.{ dir_path, "link.txt" });
    defer alloc.free(link_path);

    const source = try alloc.print(
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
    const file_path = try std.Io.Dir.path.join(alloc, &.{ dir_path, "h.txt" });
    defer alloc.free(file_path);

    const source = try alloc.print(
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
const Value = revo.Value;
const VM = revo.VM;
const testing = revo.lang.test_helpers;
const metatable_mod = @import("metatable.zig");
const root = @import("root.zig");
const specs = @import("specs.zig");
const HostResult = root.host.HostResult;

const glob = @import("vendor/glob.zig");
