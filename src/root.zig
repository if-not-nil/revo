const std = @import("std");
const builtin = @import("builtin");
pub const pretty = @import("./pretty.zig");
fn asdf() void {}

pub const Runtime = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    argv: []const [:0]const u8 = &.{},
    stdin: ?std.Io.File = null,
    stdout: std.Io.File = undefined,
    stderr: std.Io.File = undefined,
    vm: ?*VM = null,

    /// ret: a new runtime with its own vm
    pub fn init(alloc: std.mem.Allocator, io: std.Io, argv: []const [:0]const u8) !Runtime {
        const vm_ptr = try alloc.create(VM);
        vm_ptr.* = try VM.init(.{ .alloc = alloc, .io = io, .argv = argv });
        return .{
            .alloc = alloc,
            .io = io,
            .vm = vm_ptr,
        };
    }

    /// deinit runtime and free vm
    pub fn deinit(self: *Runtime) void {
        if (self.vm) |vm_ptr| {
            vm_ptr.deinit();
            self.alloc.destroy(vm_ptr);
        }
    }

    /// compile source code to a bytecode artifact
    pub fn compile(
        self: *Runtime,
        name: []const u8,
        source: []const u8,
    ) anyerror!lang.Artifact {
        const vm_ptr = self.vm orelse return error.NoVM;
        const build_result = try lang.build(vm_ptr, .{ .name = name, .text = source }, .{});
        return switch (build_result) {
            .ok => |art| art,
            .err => |err| {
                var buf = std.Io.Writer.Allocating.init(self.alloc);
                defer buf.deinit();
                try lang.renderError(self.alloc, &buf.writer, .{ .name = name, .text = source }, err);
                std.debug.print("{s}", .{buf.written()});
                return error.CompilationError;
            },
        };
    }

    /// execute a compiled artifact, also see eval()
    pub fn run(
        self: *Runtime,
        name: []const u8,
        artifact: lang.Artifact,
    ) anyerror!module.EvalResult {
        const vm_ptr = self.vm orelse return error.NoVM;
        try vm_ptr.setProgramDebugInfo(artifact.spans, "", name);
        return try module.runCompiledModuleReport(vm_ptr, name, artifact.instructions);
    }

    /// compile and execute source code in one call, also see run()
    pub fn eval(
        self: *Runtime,
        name: []const u8,
        source: []const u8,
    ) anyerror!module.EvalResult {
        const artifact = try self.compile(name, source);
        defer self.alloc.free(artifact.instructions);
        defer self.alloc.free(artifact.spans);
        return try self.run(name, artifact);
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

pub fn allocSlot(
    comptime Slot: type,
    comptime Id: type,
    alloc: std.mem.Allocator,
    slots: *std.ArrayList(Slot),
    free_head: *?Id,
    value: Slot,
) !Id {
    if (free_head.*) |id| {
        const slot = &slots.items[id];
        free_head.* = slot.next_free;
        slot.* = value;
        return id;
    }

    const id: Id = @intCast(slots.items.len);
    try slots.append(alloc, value);
    return id;
}

pub fn sweepSlots(
    comptime Slot: type,
    comptime Id: type,
    slots: *std.ArrayList(Slot),
    free_head: *?Id,
    ctx: anytype,
    comptime finalize: fn (*Slot, @TypeOf(ctx)) void,
) void {
    for (slots.items, 0..) |*slot, idx| {
        if (slot.value == null) continue;

        if (slot.marked) {
            slot.marked = false;
        } else {
            finalize(slot, ctx);
            slot.value = null;
            slot.next_free = free_head.*;
            free_head.* = @as(Id, @intCast(idx));
        }
    }
}

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
    __add,
    __sub,
    __mul,
    __div,
    __mod,
    __eq,
    __ne,
    __lt,
    __gt,
    __lte,
    __gte,
    __len,
    __tostring,
    __debug,
    __call,

    pub const lastFalse = @intFromEnum(@This().false);

    pub inline fn data(comptime a: @This()) Data {
        return Data{ .atom = @intFromEnum(a) };
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
    return switch (val) {
        .number => |n| n == 0,
        .atom => |id| id <= core_atoms.lastFalse,
        else => false,
    };
}

pub fn renderFailureAt(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    source_name: []const u8,
    source: []const u8,
    span: ?lang.Span,
    message: []const u8,
) !void {
    try pretty.printError(alloc, writer, "{s}", .{message});

    const location = span orelse return;

    var line: usize = 1;
    var column: usize = 1;
    var i: usize = 0;
    while (i < @min(location.start, source.len)) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }

    const line_start_pos = std.mem.lastIndexOfScalar(u8, source[0..@min(location.start, source.len)], '\n') orelse 0;
    const line_start = if (line_start_pos == 0) 0 else line_start_pos + 1;
    const end_rel = std.mem.indexOfScalar(u8, source[line_start..], '\n') orelse source.len - line_start;
    const line_text = source[line_start .. line_start + end_rel];
    const caret_col = if (column == 0) @as(usize, 1) else column;
    const span_len = @min(location.end -| location.start, line_text.len -| (caret_col - 1));
    const highlight_len = @max(span_len, 1);

    try writer.print(" --> {s}:{d}:{d}\n", .{ source_name, line, column });
    try writer.writeAll("   |\n");
    try writer.print("{d: >2} | {s}\n", .{ line, line_text });
    try writer.writeAll("   | ");
    for (1..caret_col) |_| try writer.writeByte(' ');
    try writer.writeByte('^');
    if (highlight_len > 1) {
        for (0..highlight_len - 2) |_| try writer.writeByte('~');
        try writer.writeByte('^');
    }
    try writer.writeByte('\n');
}

pub const lang = @import("./lang/root.zig");
pub const vm = @import("vm");
pub const std_lib = @import("./std/root.zig");

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

test {
    _ = @import("./lang/tests.zig");
    _ = std.testing.refAllDecls(@import("./std/root.zig"));
}
