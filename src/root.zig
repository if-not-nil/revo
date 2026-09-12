pub const is_freestanding = @import("build_options").is_freestanding;

// wasi runs single-threaded, posix backend needs thread spawn
// nobody has windows to develop for it
pub const has_async_backend = switch (builtin.target.os.tag) {
    .windows, .wasi, .freestanding => false,
    else => builtin.link_libc,
};

pub const async_backend_impl = if (has_async_backend)
    @import("./runtime/async_backend_posix.zig")
else
    @import("./runtime/async_backend_none.zig");

pub const Runtime = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    argv: []const [:0]const u8 = &.{},
    stdin: ?std.Io.File = null,
    vm: ?*VM = null,
    async_backend: async_backend_impl.BackendState = .{},

    /// allocator for diagnostic reports (usually an arena)
    diag_alloc: std.mem.Allocator,
    /// arena backing diag_alloc; null when not arena-backed
    diag_arena: ?*std.heap.ArenaAllocator = null,

    /// baseline ns captured at first time.now_ns()/monotonic_ns() call: the
    /// returned counts stay small enough to be exact f64 integers (deltas are
    /// then nanosecond-precise; absolute epoch ns would lose the low bits)
    time_wall_base: i96 = 0,
    time_mono_base: i96 = 0,
    /// lazily time-seeded prng for the rng stdlib; per-vm so equal-ns calls
    /// advance one stream instead of re-seeding identical generators
    rng_prng: ?std.Random.DefaultPrng = null,

    /// ret: a new runtime with its own vm
    pub fn init(alloc: std.mem.Allocator, io: std.Io, argv: []const [:0]const u8) !Runtime {
        var rt: Runtime = .{
            .alloc = alloc,
            .io = io,
            .argv = argv,
            .diag_alloc = alloc,
            .diag_arena = null,
        };

        const vm_ptr = try alloc.create(VM);
        errdefer alloc.destroy(vm_ptr);
        vm_ptr.* = try VM.init(.{
            .alloc = alloc,
            .io = io,
            .argv = argv,
            .diag_alloc = alloc,
        });
        rt.diag_alloc = vm_ptr.runtime.diag_alloc;
        rt.vm = vm_ptr;
        return rt;
    }

    pub fn diagAlloc(self: *const Runtime) std.mem.Allocator {
        return self.diag_alloc;
    }

    pub fn ensureDiagArena(self: *Runtime) !void {
        if (self.diag_arena != null) return;
        const diag_arena = try self.alloc.create(std.heap.ArenaAllocator);
        errdefer {
            diag_arena.deinit();
            self.alloc.destroy(diag_arena);
        }
        diag_arena.* = std.heap.ArenaAllocator.init(self.alloc);
        self.diag_arena = diag_arena;
        self.diag_alloc = diag_arena.allocator();
    }

    pub fn deinitDiagArena(self: *Runtime) void {
        if (self.diag_arena) |arena| {
            arena.deinit();
            self.alloc.destroy(arena);
            self.diag_arena = null;
        }
    }

    /// deinit runtime and free vm
    pub fn deinit(self: *Runtime) void {
        if (self.vm) |vm_ptr| {
            vm_ptr.deinit();
            self.alloc.destroy(vm_ptr);
        }
        self.deinitDiagArena();
    }

    pub fn resetDiagArena(self: *Runtime) void {
        if (self.diag_arena) |arena| {
            _ = arena.reset(.{ .retain_with_limit = 4096 });
        }
    }

    /// compile source code to a bytecode artifact
    pub fn compile(
        self: *Runtime,
        name: []const u8,
        source: []const u8,
    ) lang.BuildResult {
        const vm_ptr = self.vm orelse return .{ .err = .{ .parse = .{
            .kind = .LexUnknown,
            .span = null,
            .message = "vm not initialized",
        } } };
        return lang.build(vm_ptr, .{ .name = name, .text = source }, .{}) catch |err| {
            return .{ .err = .{ .parse = .{
                .kind = .LexUnknown,
                .span = null,
                .message = @errorName(err),
            } } };
        };
    }

    /// execute a compiled artifact, also see eval()
    /// returns EvalResult so callers can inspect runtime errors programmatically
    pub fn run(
        self: *Runtime,
        name: []const u8,
        artifact: lang.Artifact,
    ) !module.EvalResult {
        const vm_ptr = self.vm orelse return error.NoVM;
        try vm_ptr.setProgramDebugInfo(artifact.spans, "", name);
        return try module.runCompiledModuleReport(vm_ptr, name, artifact.instructions);
    }

    /// compile and execute source code in one call, also see run()
    pub fn eval(
        self: *Runtime,
        name: []const u8,
        source: []const u8,
    ) !module.EvalResult {
        const vm_ptr = self.vm orelse return error.NoVM;
        const build_result = lang.build(vm_ptr, .{ .name = name, .text = source }, .{}) catch {
            return error.CompilationError;
        };
        const artifact = switch (build_result) {
            .ok => |art| art,
            .err => |err| {
                printBuildError(self.alloc, .{ .name = name, .text = source }, err);
                self.resetDiagArena();
                return error.CompilationError;
            },
        };
        defer self.alloc.free(artifact.instructions);
        defer self.alloc.free(artifact.spans);
        try vm_ptr.setProgramDebugInfo(artifact.spans, "", name);
        return try module.runCompiledModuleReport(vm_ptr, name, artifact.instructions);
    }
};

pub inline fn Result(comptime Ok: type, comptime Err: type) type {
    return union(enum) {
        ok: Ok,
        err: Err,
    };
}

pub fn asIndex(n: f64) error{TypeError}!usize {
    if (!std.math.isFinite(n) or n < 0 or @floor(n) != n) return error.TypeError;
    return @as(usize, @intFromFloat(n));
}

pub fn resolve(raw_path: []const u8, base_dir: ?[]const u8, io: std.Io, alloc: std.mem.Allocator) error{ OutOfMemory, IoError }![]u8 {
    if (std.fs.path.isAbsolute(raw_path)) return alloc.dupe(u8, raw_path) catch return error.OutOfMemory;

    const root_dir = std.Io.Dir.cwd().realPathFileAlloc(io, base_dir orelse ".", alloc) catch return error.IoError;
    defer alloc.free(root_dir);
    return std.fs.path.resolve(alloc, &.{ root_dir, raw_path }) catch return error.OutOfMemory;
}

/// resolve an import path the same way compile-time preload and the runtime
/// `import` native agree on the canonical file; null when nothing matches
pub fn resolveImportFile(
    io: std.Io,
    alloc: std.mem.Allocator,
    raw_path: []const u8,
    module_dir: ?[]const u8,
    project_root: []const u8,
    package_path: []const []const u8,
) !?[]const u8 {
    // relative paths (./ or ../): only the importing module's directory
    if (raw_path.len > 0 and raw_path[0] == '.') {
        if (module_dir) |dir| {
            if (try probeImportFile(io, alloc, dir, raw_path)) |p| return p;
            const with_ext = try std.fmt.allocPrint(alloc, "{s}.rv", .{raw_path});
            defer alloc.free(with_ext);
            if (try probeImportFile(io, alloc, dir, with_ext)) |p| return p;
            const init = try std.fmt.allocPrint(alloc, "{s}/init.rv", .{raw_path});
            defer alloc.free(init);
            if (try probeImportFile(io, alloc, dir, init)) |p| return p;
        }
        return null;
    }

    // absolute paths
    if (std.fs.path.isAbsolute(raw_path)) {
        return probeImportFile(io, alloc, null, raw_path);
    }

    // bare module names resolve adjacent to the importing module, then the
    // project root, then package paths
    if (module_dir) |dir| {
        if (try probeImportFile(io, alloc, dir, raw_path)) |p| return p;
        const with_ext = try std.fmt.allocPrint(alloc, "{s}.rv", .{raw_path});
        defer alloc.free(with_ext);
        if (try probeImportFile(io, alloc, dir, with_ext)) |p| return p;
        const init = try std.fmt.allocPrint(alloc, "{s}/init.rv", .{raw_path});
        defer alloc.free(init);
        if (try probeImportFile(io, alloc, dir, init)) |p| return p;
    }

    if (project_root.len > 0) {
        if (try probeImportFile(io, alloc, project_root, raw_path)) |p| return p;
        const pr_ext = try std.fmt.allocPrint(alloc, "{s}.rv", .{raw_path});
        defer alloc.free(pr_ext);
        if (try probeImportFile(io, alloc, project_root, pr_ext)) |p| return p;
        const pr_init = try std.fmt.allocPrint(alloc, "{s}/init.rv", .{raw_path});
        defer alloc.free(pr_init);
        if (try probeImportFile(io, alloc, project_root, pr_init)) |p| return p;
    }

    for (package_path) |tmpl| {
        const sub = if (std.mem.findScalar(u8, tmpl, '?')) |pos|
            try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ tmpl[0..pos], raw_path, tmpl[pos + 1 ..] })
        else
            try alloc.dupe(u8, tmpl);
        defer alloc.free(sub);
        if (try probeImportFile(io, alloc, null, sub)) |p| return p;
        const sub_ext = try std.fmt.allocPrint(alloc, "{s}.rv", .{sub});
        defer alloc.free(sub_ext);
        if (try probeImportFile(io, alloc, null, sub_ext)) |p| return p;
        const sub_init = try std.fmt.allocPrint(alloc, "{s}/init.rv", .{sub});
        defer alloc.free(sub_init);
        if (try probeImportFile(io, alloc, null, sub_init)) |p| return p;
    }

    return null;
}

/// does dir/name exist as a regular file? returns its canonical path if so
fn probeImportFile(
    io: std.Io,
    alloc: std.mem.Allocator,
    dir: ?[]const u8,
    name: []const u8,
) !?[]const u8 {
    const joined = if (dir) |d|
        std.fs.path.resolve(alloc, &.{ d, name }) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
        }
    else
        std.fs.path.resolve(alloc, &.{name}) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
        };
    defer alloc.free(joined);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.cwd().realPathFile(io, joined, &buf) catch |err| switch (err) {
        error.FileNotFound, error.IsDir => return null,
        else => |e| return e,
    };
    // realPathFile returns the dir path instead of IsDir on macos
    const stat = std.Io.Dir.cwd().statFile(io, buf[0..n], .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    if (stat.kind == .directory) return null;
    return try alloc.dupe(u8, buf[0..n]);
}

/// the `<stem>.d.rv` manifest path for an extension lib, caller checks
/// existence; shared by the pipeline resolver and the workspace (which has
/// no io to probe with)
pub fn extensionManifestPath(alloc: std.mem.Allocator, resolved_lib: []const u8) ![]const u8 {
    const dir = std.fs.path.dirname(resolved_lib) orelse return error.NoDirname;
    const stem = std.fs.path.stem(resolved_lib);
    const name = try std.fmt.allocPrint(alloc, "{s}.d.rv", .{stem});
    defer alloc.free(name);
    return try std.fs.path.join(alloc, &.{ dir, name });
}

/// if a `<stem>.d.rv` manifest sits next to a resolved extension lib,
/// return its path - the manifest is the type interface for the lib
pub fn extensionManifestFor(
    io: std.Io,
    alloc: std.mem.Allocator,
    resolved_lib: []const u8,
) !?[]const u8 {
    const manifest = try extensionManifestPath(alloc, resolved_lib);
    defer alloc.free(manifest);
    return probeImportFile(io, alloc, null, manifest);
}

test "extensionManifestFor finds a sibling manifest" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib.so", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib.d.rv", .data = "pub declare open = fn(p: string) -> string\n" });

    const lib = try tmp.dir.realPathFileAlloc(std.testing.io, "lib.so", a);
    defer a.free(lib);
    const manifest = (try extensionManifestFor(std.testing.io, a, lib)) orelse return error.TestUnexpectedResult;
    defer a.free(manifest);
    try std.testing.expect(std.mem.endsWith(u8, manifest, "lib.d.rv"));

    // no manifest -> null
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "other.so", .data = "" });
    const other = try tmp.dir.realPathFileAlloc(std.testing.io, "other.so", a);
    defer a.free(other);
    try std.testing.expect((try extensionManifestFor(std.testing.io, a, other)) == null);
}

/// guaranteed IDs
pub const core_atoms = vm.core_atoms;

/// (:f or :false or :nil or 0 or 0.0 or :undef or :missing) == :false
pub const isFalse = vm.isFalse;

pub fn printBuildError(gpa: std.mem.Allocator, source_info: lang.Source, err: lang.Error) void {
    // todo
    if (comptime is_freestanding) return;
    var buf = std.Io.Writer.Allocating.init(gpa);
    defer buf.deinit();
    lang.renderError(gpa, &buf.writer, source_info, err) catch {};
    std.debug.print("{s}", .{buf.written()});
}

pub fn printEvalError(gpa: std.mem.Allocator, source: []const u8, failure: EvalFailure) void {
    // todo
    if (comptime is_freestanding) return;
    var buf = std.Io.Writer.Allocating.init(gpa);
    defer buf.deinit();
    failure.render(gpa, &buf.writer, source) catch {};
    std.debug.print("{s}", .{buf.written()});
}

pub fn stdout() std.Io.File {
    if (comptime is_freestanding)
        return .{
            .handle = if (@import("builtin").target.os.tag == .freestanding)
                @as(void, {})
            else
                @as(std.posix.fd_t, 1),
            .flags = .{ .nonblocking = false },
        };
    return std.Io.File.stdout();
}

pub fn stdin() std.Io.File {
    if (comptime is_freestanding)
        return .{
            .handle = if (@import("builtin").target.os.tag == .freestanding)
                @as(void, {})
            else
                @as(std.posix.fd_t, 0),
            .flags = .{ .nonblocking = false },
        };
    return std.Io.File.stdin();
}

pub fn stderr() std.Io.File {
    if (comptime is_freestanding)
        return .{
            .handle = if (@import("builtin").target.os.tag == .freestanding)
                @as(void, {})
            else
                @as(std.posix.fd_t, 2),
            .flags = .{ .nonblocking = false },
        };
    return std.Io.File.stderr();
}

test {
    _ = @import("./lang/tests.zig");
}

const std = @import("std");
const builtin = @import("builtin");

pub const vm = @import("vm");
pub const memory = vm.memory;
pub const ffi = @import("c").ffi;
pub const table = vm.table;
pub const functions = vm.functions;
pub const HostBinding = functions.HostBinding;
pub const host_binding_size = @sizeOf(functions.HostBinding);
pub const module = vm.module;
pub const opcode = vm.opcode;
pub const bytecode = vm.bytecode;
pub const Data = memory.Data;
pub const StringID = memory.StringID;
pub const AtomID = memory.AtomID;
pub const FunctionID = memory.FunctionID;
pub const TableID = memory.TableID;
pub const ProgramCounter = vm.ProgramCounter;
pub const ConstantID = vm.ConstantID;
pub const GlobalID = vm.GlobalID;
pub const LocalSlot = functions.LocalSlot;
pub const PrototypeID = functions.PrototypeID;
pub const UpvalueID = functions.UpvalueID;
pub const Operand = opcode.Operand;
pub const Instruction = opcode.Instruction;
pub const VM = vm.VM;
pub const EvalErrorKind = vm.EvalErrorKind;
pub const EvalFailure = vm.EvalFailure;
pub const EvalResult = vm.EvalResult;

pub const lang = @import("./lang/root.zig");
pub const pretty = @import("./pretty.zig");
pub const async_backend = @import("./runtime/async_backend.zig");
pub const std_net = @import("./std/net.zig");
pub const std_lib = @import("./std/root.zig");
pub const argparse = @import("./argparse.zig");
