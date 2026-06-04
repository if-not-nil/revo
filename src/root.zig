pub const async_backend_impl = if (builtin.target.os.tag == .windows)
    @import("./runtime/async_backend_none.zig")
else
    @import("./runtime/async_backend_posix.zig");
pub const has_async_backend = builtin.target.os.tag != .windows;

pub const Runtime = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    argv: []const [:0]const u8 = &.{},
    stdin: ?std.Io.File = null,
    // SAFETY: set by init() before use
    stdout: std.Io.File = undefined,
    // SAFETY: set by init() before use
    stderr: std.Io.File = undefined,
    vm: ?*VM = null,
    async_backend: async_backend_impl.BackendState = .{},

    /// allocator for diagnostic reports (usually an arena)
    diag_alloc: std.mem.Allocator = undefined,
    /// arena backing diag_alloc; null when not arena-backed
    diag_arena: ?*std.heap.ArenaAllocator = null,

    /// ret: a new runtime with its own vm
    pub fn init(alloc: std.mem.Allocator, io: std.Io, argv: []const [:0]const u8) !Runtime {
        var rt: Runtime = .{
            .alloc = alloc,
            .io = io,
            .argv = argv,
            .diag_alloc = undefined,
            .diag_arena = null,
        };

        const vm_ptr = try alloc.create(VM);
        errdefer alloc.destroy(vm_ptr);
        vm_ptr.* = try VM.init(.{
            .alloc = alloc,
            .io = io,
            .argv = argv,
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

pub const path_utils = struct {
    pub const Error = error{ OutOfMemory, IoError };

    pub fn resolve(raw_path: []const u8, base_dir: ?[]const u8, io: std.Io, alloc: std.mem.Allocator) Error![]u8 {
        if (std.fs.path.isAbsolute(raw_path)) return alloc.dupe(u8, raw_path) catch return error.OutOfMemory;

        const cwd_path = std.Io.Dir.cwd().realPathFileAlloc(io, ".", alloc) catch return error.IoError;
        defer alloc.free(cwd_path);
        const root_dir = base_dir orelse cwd_path;
        return std.fs.path.resolve(alloc, &.{ root_dir, raw_path }) catch return error.OutOfMemory;
    }

    pub fn withDefaultExtension(path: []const u8, ext: []const u8, alloc: std.mem.Allocator) Error![]u8 {
        if (std.fs.path.extension(path).len != 0) return alloc.dupe(u8, path) catch return error.OutOfMemory;
        return std.fmt.allocPrint(alloc, "{s}.{s}", .{ path, ext }) catch return error.OutOfMemory;
    }
};

/// guaranteed IDs
pub const core_atoms = enum(AtomID) {
    nil,
    missing,
    undef,
    none,
    no_result,
    false,
    // false atoms all above to check faster
    true,
    range,
    ok,
    err,
    some,
    __index,
    __newindex,
    __tostring,
    __debug,
    __call,
    SocketClosed,
    InvalidAddress,
    ConnectionFailed,
    SocketSetupFailed,
    NotServerSocket,
    AcceptFailed,
    CannotSendOnServer,
    SendFailed,
    CannotRecvOnServer,
    RecvFailed,
    int,
    bool,
    integer,
    float,
    number,
    num,

    pub const lastFalse = @intFromEnum(@This().false);

    pub inline fn data(comptime a: @This()) Data {
        return Data.new.atom(@intFromEnum(a));
    }

    pub inline fn atom_id(comptime a: @This()) AtomID {
        return @intFromEnum(a);
    }

    pub inline fn str(comptime a: @This()) []const u8 {
        return @tagName(a);
    }
};

/// (:f or :false or :nil or 0 or 0.0 or :undef or :missing) == :false
pub inline fn isFalse(val: Data) bool {
    if (val.asNum()) |n| return n == 0;
    if (val.asAtom()) |id| return id <= core_atoms.lastFalse;
    return false;
}

pub fn renderFailureAt(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    source_name: []const u8,
    source: []const u8,
    span: ?lang.Span,
    message: []const u8,
) !void {
    try diagnostic.renderAt(alloc, writer, source_name, source, span, message, &.{}, &.{});
}

pub fn printBuildError(gpa: std.mem.Allocator, source_info: lang.Source, err: lang.Error) void {
    var buf = std.Io.Writer.Allocating.init(gpa);
    defer buf.deinit();
    lang.renderError(gpa, &buf.writer, source_info, err) catch {};
    std.debug.print("{s}", .{buf.written()});
    lang.deinitError(gpa, err);
}

pub fn printEvalError(gpa: std.mem.Allocator, source: []const u8, failure: EvalFailure) void {
    var buf = std.Io.Writer.Allocating.init(gpa);
    defer buf.deinit();
    failure.render(gpa, &buf.writer, source) catch {};
    std.debug.print("{s}", .{buf.written()});
}

test {
    _ = @import("./lang/tests.zig");
}

const std = @import("std");
const builtin = @import("builtin");

pub const vm = @import("vm");
pub const memory = vm.memory;
pub const ffi = vm.ffi;
pub const table = vm.table;
pub const tuple = vm.tuple;
pub const functions = vm.functions;
pub const module = vm.module;
pub const opcode = vm.opcode;
pub const bytecode = vm.bytecode;
pub const Data = memory.Data;
pub const StringID = memory.StringID;
pub const AtomID = memory.AtomID;
pub const FunctionID = memory.FunctionID;
pub const TableID = memory.TableID;
pub const TupleID = memory.TupleID;
pub const StructTypeID = memory.StructTypeID;
pub const StructInstanceID = memory.StructInstanceID;
pub const Entry = memory.Entry;
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

const diagnostic = @import("./lang/diagnostic.zig");
pub const lang = @import("./lang/root.zig");
pub const pretty = @import("./pretty.zig");
pub const async_backend = @import("./runtime/async_backend.zig");
pub const std_net = @import("./std/net.zig");
pub const std_lib = @import("./std/root.zig");
