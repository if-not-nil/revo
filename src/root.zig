pub const is_freestanding = @import("build_options").is_freestanding;

// threads + nbio is only available on posix with libc
// wasi is single-threaded, and windows has no backend yet
pub const can_async = switch (builtin.target.os.tag) {
    .windows, .wasi, .freestanding => false,
    else => builtin.link_libc,
};

pub const Runtime = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    argv: []const [:0]const u8 = &.{},
    stdin: ?std.Io.File = null,
    vm: ?*VM = null,
    threads: usize = 1,

    /// allocator for diagnostic reports (usually an arena)
    diag_alloc: std.mem.Allocator,
    /// arena backing diag_alloc; null when not arena-backed
    diag_arena: ?*std.heap.ArenaAllocator = null,

    /// baseline ns captured at first time.now_ns()/monotonic_ns() call: the
    /// returned counts stay small enough to be exact f64 integers (deltas are
    /// then nanosecond-precise; absolute epoch ns would lose the low bits)
    time_wall_base: i96 = 0,
    time_mono_base: i96 = 0,
    /// lazily time-seeded prng for the rng baselib; per-vm so equal-ns calls
    /// advance one stream instead of re-seeding identical generators
    prng: ?std.Random.DefaultPrng = null,

    input_buf: [4096]u8 = undefined,
    input_buf_len: usize = 0,

    supports_color: bool = term.defaultSupportsColor(),

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

    /// compile source code to bytecode
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

    /// execute compiled bytecode, also see eval()
    /// returns RunResult so callers can inspect runtime errors programmatically
    pub fn run(
        self: *Runtime,
        name: []const u8,
        compiled: lang.Bytecode,
    ) !vm.run.RunResult {
        const vm_ptr = self.vm orelse return error.NoVM;
        try vm_ptr.setProgramDebugInfo(compiled.spans, "", name);
        return try vm.run.runBytecodeReport(vm_ptr, name, compiled.instructions);
    }

    /// compile and execute source code in one call, also see run()
    pub fn evalSource(
        self: *Runtime,
        name: []const u8,
        source: []const u8,
    ) !vm.run.RunResult {
        const vm_ptr = self.vm orelse return error.NoVM;
        const build_result = lang.build(vm_ptr, .{ .name = name, .text = source }, .{}) catch {
            return error.CompilationError;
        };
        const compiled = switch (build_result) {
            .ok => |art| art,
            .err => |err| {
                printBuildError(self.alloc, .{ .name = name, .text = source }, err);
                self.resetDiagArena();
                return error.CompilationError;
            },
        };
        defer self.alloc.free(compiled.instructions);
        defer self.alloc.free(compiled.spans);
        try vm_ptr.setProgramDebugInfo(compiled.spans, "", name);
        return try vm.run.runBytecodeReport(vm_ptr, name, compiled.instructions);
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
    if (std.Io.Dir.path.isAbsolute(raw_path)) return alloc.dupe(u8, raw_path) catch return error.OutOfMemory;

    const root_dir = std.Io.Dir.cwd().realPathFileAlloc(io, base_dir orelse ".", alloc) catch return error.IoError;
    defer alloc.free(root_dir);
    return std.Io.Dir.path.resolveAlloc(alloc, &.{ root_dir, raw_path }) catch return error.OutOfMemory;
}

/// resolve an import path the same way compile-time preload and the runtime
/// `import` native agree on the canonical file; null when nothing matches
pub fn resolveImportFile(
    io: std.Io,
    alloc: std.mem.Allocator,
    raw_path: []const u8,
    import_dir: ?[]const u8,
    project_root: []const u8,
    package_path: []const []const u8,
) !?[]const u8 {
    // relative paths (./ or ../): only the importing module's directory
    if (raw_path.len > 0 and raw_path[0] == '.') {
        if (import_dir) |dir| {
            if (try probeImportFile(io, alloc, dir, raw_path)) |p| return p;
            const with_ext = try alloc.print("{s}.rv", .{raw_path});
            defer alloc.free(with_ext);
            if (try probeImportFile(io, alloc, dir, with_ext)) |p| return p;
            const init = try alloc.print("{s}/init.rv", .{raw_path});
            defer alloc.free(init);
            if (try probeImportFile(io, alloc, dir, init)) |p| return p;
        }
        return null;
    }

    // absolute paths
    if (std.Io.Dir.path.isAbsolute(raw_path)) {
        return probeImportFile(io, alloc, null, raw_path);
    }

    // bare module names resolve adjacent to the importing module, then the
    // project root, then package paths
    if (import_dir) |dir| {
        if (try probeImportFile(io, alloc, dir, raw_path)) |p| return p;
        const with_ext = try alloc.print("{s}.rv", .{raw_path});
        defer alloc.free(with_ext);
        if (try probeImportFile(io, alloc, dir, with_ext)) |p| return p;
        const init = try alloc.print("{s}/init.rv", .{raw_path});
        defer alloc.free(init);
        if (try probeImportFile(io, alloc, dir, init)) |p| return p;
    }

    if (project_root.len > 0) {
        if (try probeImportFile(io, alloc, project_root, raw_path)) |p| return p;
        const pr_ext = try alloc.print("{s}.rv", .{raw_path});
        defer alloc.free(pr_ext);
        if (try probeImportFile(io, alloc, project_root, pr_ext)) |p| return p;
        const pr_init = try alloc.print("{s}/init.rv", .{raw_path});
        defer alloc.free(pr_init);
        if (try probeImportFile(io, alloc, project_root, pr_init)) |p| return p;
    }

    for (package_path) |tmpl| {
        const sub = if (std.mem.findScalar(u8, tmpl, '?')) |pos|
            try alloc.print("{s}{s}{s}", .{ tmpl[0..pos], raw_path, tmpl[pos + 1 ..] })
        else
            try alloc.dupe(u8, tmpl);
        defer alloc.free(sub);
        if (try probeImportFile(io, alloc, null, sub)) |p| return p;
        const sub_ext = try alloc.print("{s}.rv", .{sub});
        defer alloc.free(sub_ext);
        if (try probeImportFile(io, alloc, null, sub_ext)) |p| return p;
        const sub_init = try alloc.print("{s}/init.rv", .{sub});
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
        std.Io.Dir.path.resolveAlloc(alloc, &.{ d, name }) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
        }
    else
        std.Io.Dir.path.resolveAlloc(alloc, &.{name}) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
        };
    defer alloc.free(joined);
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
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

/// guaranteed IDs
pub const CoreAtoms = vm.CoreAtoms;

/// (:f or :false or :nil or 0 or 0.0 or :undef or :missing) == :false
pub const isFalse = vm.isFalse;

pub fn printBuildError(gpa: std.mem.Allocator, source_info: lang.Source, err: lang.Error, color: bool) void {
    // todo
    if (comptime is_freestanding) return;
    var buf = std.Io.Writer.Allocating.init(gpa);
    defer buf.deinit();
    lang.renderError(&buf.writer, source_info, err, .{ .color = color }) catch {};
    std.debug.print("{s}", .{buf.written()});
}

pub fn printBuildWarning(gpa: std.mem.Allocator, source_info: lang.Source, report: lang.diagnostic.Report, color: bool) void {
    // todo
    if (comptime is_freestanding) return;
    var buf = std.Io.Writer.Allocating.init(gpa);
    defer buf.deinit();
    lang.renderWarnings(&buf.writer, source_info, report, .{ .color = color }) catch {};
    std.debug.print("{s}", .{buf.written()});
}

pub fn printRunError(gpa: std.mem.Allocator, source: []const u8, failure: RunFailure, color: bool) void {
    // todo
    if (comptime is_freestanding) return;
    var buf = std.Io.Writer.Allocating.init(gpa);
    defer buf.deinit();
    failure.render(&buf.writer, source, color) catch {};
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
    // lang suite runs split under test-lang instead, one binary per area
    _ = @import("./extension.zig");
    _ = @import("./baselib/ffi.zig");
    _ = @import("./baselib/host.zig");
    _ = @import("./baselib/specs.zig");
}

const builtin = @import("builtin");
const std = @import("std");

pub const vm = @import("vm");
pub const memory = vm.memory;
pub const ffi = @import("capi").ffi;
pub const table = vm.table;
pub const callable = vm.callable;
pub const HostBinding = callable.HostBinding;
pub const host_binding_size = @sizeOf(callable.HostBinding);
pub const parseSourceReport = lang.parseSourceReport;
pub const run = vm.run;
pub const opcode = vm.opcode;
pub const bytecode = vm.bytecode;
pub const Value = memory.Value;
pub const StringID = memory.StringID;
pub const AtomID = memory.AtomID;
pub const FunctionID = memory.FunctionID;
pub const TableID = memory.TableID;
pub const ProgramCounter = vm.ProgramCounter;
pub const ConstantID = vm.ConstantID;
pub const GlobalID = vm.GlobalID;
pub const LocalSlot = callable.LocalSlot;
pub const TemplateID = callable.TemplateID;
pub const UpvalueID = callable.UpvalueID;
pub const Operand = opcode.Operand;
pub const Instruction = opcode.Instruction;
pub const VM = vm.VM;
pub const RunErrorKind = vm.RunErrorKind;
pub const RunFailure = vm.RunFailure;
pub const RunResult = vm.RunResult;

pub const argparse = @import("./argparse.zig");
pub const diff = @import("./diff.zig");
pub const baselib = @import("./baselib/root.zig");
pub const baselib_net = @import("./baselib/net.zig");
pub const extension = @import("./extension.zig");
pub const lang = @import("./lang/root.zig");
pub const term = @import("./term.zig");
