//
// embedding api for embedding revo from c
//
const build_opts = @import("build_options");
const revo = @import("revo");
const std = @import("std");
const Value = revo.Value;

/// opaque handle to a vm instance
pub const ErevoVM = opaque {};
/// opaque handle to a compiled program
pub const ErevoProgram = opaque {};

/// c-level type tags matching revo's runtime type system
/// (values mirror the nanbox stored tags: number is never boxed)
pub const ErevoType = enum(u64) {
    number = 0,
    string = 8,
    atom = 9,
    function = 10,
    table = 11,
    resource = 12,
    @"opaque" = 13,
};

/// a revo value passed across the c boundary, nanboxed in a single u64
pub const ErevoValue = Value;

const VM = struct {
    alloc: std.mem.Allocator,
    io: std.Io.Threaded,
    last_error: ?[:0]u8 = null,
};

const Program = struct {
    alloc: std.mem.Allocator,
    name: [:0]u8,
    source: [:0]u8,
    bytecode: revo.lang.Bytecode,
};

fn compileProgram(inner: *revo.VM, name: []const u8, source: []const u8) ?*Program {
    const self: *VM = @ptrCast(@alignCast(inner.c_data.?));
    if (self.last_error) |msg| self.alloc.free(msg);
    self.last_error = null;

    const result = revo.lang.build(inner, .{ .name = name, .text = source }, .{}) catch |err| {
        const msg = self.alloc.print("{}", .{err}) catch return null;
        defer self.alloc.free(msg);

        self.last_error = self.alloc.dupeSentinel(u8, msg, 0) catch null;
        return null;
    };

    return switch (result) {
        .ok => |bytecode| blk: {
            const program = self.alloc.create(Program) catch return null;
            const name_z = self.alloc.dupeSentinel(u8, name, 0) catch return null;
            const source_z = self.alloc.dupeSentinel(u8, source, 0) catch return null;

            program.* = .{
                .alloc = self.alloc,
                .name = name_z,
                .source = source_z,
                .bytecode = bytecode,
            };

            break :blk program;
        },
        .err => |failure| blk: {
            var buf = std.Io.Writer.Allocating.init(self.alloc);
            defer buf.deinit();

            revo.lang.renderError(&buf.writer, .{ .name = name, .text = source }, failure, .{}) catch {
                self.last_error = self.alloc.dupeSentinel(u8, "compile error (todo put it here)", 0) catch null;
                inner.runtime.resetDiagArena();
                break :blk null;
            };

            self.last_error = self.alloc.dupeSentinel(u8, buf.written(), 0) catch null;
            inner.runtime.resetDiagArena();
            break :blk null;
        },
    };
}

fn runProgram(inner: *revo.VM, program: *Program, out_value: ?*ErevoValue) bool {
    const self: *VM = @ptrCast(@alignCast(inner.c_data.?));
    if (self.last_error) |msg| self.alloc.free(msg);
    self.last_error = null;

    inner.setProgramDebugInfo(program.bytecode.spans, program.source, program.name) catch |err| {
        const msg = self.alloc.print("{}", .{err}) catch return false;
        defer self.alloc.free(msg);
        self.last_error = self.alloc.dupeSentinel(u8, msg, 0) catch null;
        return false;
    };

    const result = revo.run.runBytecodeReport(inner, program.name, program.bytecode.instructions) catch |err| {
        const msg = self.alloc.print("{}", .{err}) catch return false;
        defer self.alloc.free(msg);
        self.last_error = self.alloc.dupeSentinel(u8, msg, 0) catch null;
        return false;
    };

    return switch (result) {
        .ok => blk: {
            if (out_value) |out| {
                out.* = inner.currentResult();
            }
            break :blk true;
        },
        .err => |failure| blk: {
            var buf = std.Io.Writer.Allocating.init(self.alloc);
            defer buf.deinit();
            failure.render(&buf.writer, program.source, false) catch {
                self.last_error = self.alloc.dupeSentinel(u8, "runtime error", 0) catch null;
                inner.runtime.resetDiagArena();
                break :blk false;
            };
            self.last_error = self.alloc.dupeSentinel(u8, buf.written(), 0) catch null;
            inner.runtime.resetDiagArena();
            break :blk false;
        },
    };
}

/// create a new vm instance, returns null on failure
pub export fn erevo_vm_create() callconv(.c) ?*ErevoVM {
    const alloc = if (build_opts.mimalloc)
        @import("mimalloc").mim_allocator
    else
        std.heap.page_allocator; // TODO: switch to c_allocator once GC gets triggered less
    var io = std.Io.Threaded.init(alloc, .{});
    errdefer io.deinit();

    const runtime = revo.Runtime.init(alloc, io.io(), &.{}) catch return null;
    errdefer runtime.deinit();

    const inner = runtime.vm orelse return null;
    const wrap = alloc.create(VM) catch return null;

    wrap.* = .{ .alloc = alloc, .io = io };
    inner.c_data = @ptrCast(wrap);
    return @ptrCast(inner);
}

/// destroy a vm instance (null-safe)
pub export fn erevo_vm_destroy(vm: ?*ErevoVM) callconv(.c) void {
    const inner = if (vm) |p| @as(*revo.VM, @ptrCast(@alignCast(p))) else return;
    const self: *VM = @ptrCast(@alignCast(inner.c_data.?));
    if (self.last_error) |msg| self.alloc.free(msg);

    inner.runtime.deinit();
    self.io.deinit();
    self.alloc.destroy(self);
}

/// return last error message, empty string if none (null-safe)
pub export fn erevo_vm_last_error(vm: ?*ErevoVM) callconv(.c) [*:0]const u8 {
    const inner = if (vm) |p| @as(*revo.VM, @ptrCast(@alignCast(p))) else return "";
    const self: *VM = @ptrCast(@alignCast(inner.c_data.?));

    return if (self.last_error) |msg| msg.ptr else "";
}

/// compile source code into a program, returns null on error (null-safe)
pub export fn erevo_compile(vm: ?*ErevoVM, name: [*:0]const u8, source: [*:0]const u8) callconv(.c) ?*ErevoProgram {
    const inner = if (vm) |p| @as(*revo.VM, @ptrCast(@alignCast(p))) else return null;
    return @ptrCast(compileProgram(inner, std.mem.span(name), std.mem.span(source)) orelse return null);
}

/// destroy a compiled program (null-safe)
pub export fn erevo_program_destroy(program: ?*ErevoProgram) callconv(.c) void {
    const self = if (program) |p| @as(*Program, @ptrCast(@alignCast(p))) else return;

    self.alloc.free(self.bytecode.instructions);
    self.alloc.free(self.bytecode.spans);
    self.alloc.free(self.name);
    self.alloc.free(self.source);
    self.alloc.destroy(self);
}

/// execute a compiled program, writes result through out_value (both pointers optional)
pub export fn erevo_run(vm: ?*ErevoVM, program: ?*ErevoProgram, out_value: ?*ErevoValue) callconv(.c) bool {
    const inner = if (vm) |p| @as(*revo.VM, @ptrCast(@alignCast(p))) else return false;
    const compiled = if (program) |p| @as(*Program, @ptrCast(@alignCast(p))) else return false;

    return runProgram(inner, compiled, out_value);
}

/// compile, run, and free a program in one step (null-safe, out_value optional)
pub export fn erevo_eval(vm: ?*ErevoVM, name: [*:0]const u8, source: [*:0]const u8, out_value: ?*ErevoValue) callconv(.c) bool {
    const inner = if (vm) |p|
        @as(*revo.VM, @ptrCast(@alignCast(p)))
    else
        return false;
    const program = compileProgram(inner, std.mem.span(name), std.mem.span(source)) orelse return false;

    defer {
        program.alloc.free(program.bytecode.instructions);
        program.alloc.free(program.bytecode.spans);
        program.alloc.free(program.name);
        program.alloc.free(program.source);
        program.alloc.destroy(program);
    }
    return runProgram(inner, program, out_value);
}
