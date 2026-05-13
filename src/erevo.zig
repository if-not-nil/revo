//
// exports for embedding revo from c
//
const std = @import("std");
const revo = @import("revo");

pub const ErevoVM = opaque {};
pub const ErevoProgram = opaque {};

pub const ErevoType = enum(u64) {
    number = 0,
    string,
    atom,
    function,
    table,
    tuple,
};

pub const ErevoData = extern struct {
    tag: u64,
    value: u64,
};

const VM = struct {
    alloc: std.mem.Allocator,
    io: std.Io.Threaded,
    runtime: revo.Runtime,
    last_error: ?[:0]u8 = null,
};

const Program = struct {
    alloc: std.mem.Allocator,
    name: [:0]u8,
    source: [:0]u8,
    artifact: revo.lang.Artifact,
};

fn vmOf(vm: ?*ErevoVM) ?*VM {
    return if (vm) |p| @ptrCast(@alignCast(p)) else null;
}

fn programOf(program: ?*ErevoProgram) ?*Program {
    return if (program) |p| @ptrCast(@alignCast(p)) else null;
}

fn clearError(vm: *VM) void {
    if (vm.last_error) |msg| vm.alloc.free(msg);
    vm.last_error = null;
}

fn setError(vm: *VM, message: []const u8) void {
    clearError(vm);
    vm.last_error = vm.alloc.dupeZ(u8, message) catch null;
}

fn setErrorFmt(vm: *VM, comptime fmt: []const u8, args: anytype) void {
    const message = std.fmt.allocPrint(vm.alloc, fmt, args) catch return;
    defer vm.alloc.free(message);
    setError(vm, message);
}

fn makeVm(alloc: std.mem.Allocator) !*VM {
    const vm = try alloc.create(VM);
    errdefer alloc.destroy(vm);

    var io = std.Io.Threaded.init(alloc, .{});
    errdefer io.deinit();

    const runtime = try revo.Runtime.init(alloc, io.io(), &.{});
    vm.* = .{
        .alloc = alloc,
        .io = io,
        .runtime = runtime,
    };
    return vm;
}

fn freeProgram(program: *Program) void {
    program.alloc.free(program.artifact.instructions);
    program.alloc.free(program.artifact.spans);
    program.alloc.free(program.name);
    program.alloc.free(program.source);
    program.alloc.destroy(program);
}

fn makeProgram(vm: *VM, name: []const u8, source: []const u8, artifact: revo.lang.Artifact) !*Program {
    const program = try vm.alloc.create(Program);
    errdefer vm.alloc.destroy(program);

    const name_z = try vm.alloc.dupeZ(u8, name);
    errdefer vm.alloc.free(name_z);

    const source_z = try vm.alloc.dupeZ(u8, source);
    errdefer vm.alloc.free(source_z);

    program.* = .{
        .alloc = vm.alloc,
        .name = name_z,
        .source = source_z,
        .artifact = artifact,
    };
    return program;
}

fn compileProgram(vm: *VM, name: []const u8, source: []const u8) ?*Program {
    clearError(vm);
    const runtime_vm = vm.runtime.vm orelse {
        setError(vm, "vm missing");
        return null;
    };

    const result = revo.lang.build(runtime_vm, .{ .name = name, .text = source }, .{}) catch |err| {
        setErrorFmt(vm, "{}", .{err});
        return null;
    };

    return switch (result) {
        .ok => |artifact| makeProgram(vm, name, source, artifact) catch |err| {
            setErrorFmt(vm, "{}", .{err});
            return null;
        },
        .err => |failure| blk: {
            var buf = std.Io.Writer.Allocating.init(vm.alloc);
            defer buf.deinit();
            revo.lang.renderError(vm.alloc, &buf.writer, .{ .name = name, .text = source }, failure) catch {
                setError(vm, "compile error");
                break :blk null;
            };
            setError(vm, buf.written());
            break :blk null;
        },
    };
}

fn runProgram(vm: *VM, program: *Program, out_value: ?*ErevoData) bool {
    clearError(vm);
    const runtime_vm = vm.runtime.vm orelse {
        setError(vm, "vm missing");
        return false;
    };

    runtime_vm.setProgramDebugInfo(program.artifact.spans, program.source, program.name) catch |err| {
        setErrorFmt(vm, "{}", .{err});
        return false;
    };

    const result = revo.module.runCompiledModuleReport(runtime_vm, program.name, program.artifact.instructions) catch |err| {
        setErrorFmt(vm, "{}", .{err});
        return false;
    };

    return switch (result) {
        .ok => blk: {
            if (out_value) |out| {
                const cr = runtime_vm.currentResult();
                const tag = @intFromEnum(std.meta.activeTag(cr));
                const value = switch (cr) {
                    .number => |n| @as(u64, @bitCast(n)),
                    .string => |v| @as(u64, @intCast(v)),
                    .atom => |v| @as(u64, @intCast(v)),
                    .function => |v| @as(u64, @intCast(v)),
                    .table => |v| @as(u64, @intCast(v)),
                    .tuple => |v| @as(u64, @intCast(v)),
                };
                out.* = .{ .tag = tag, .value = value };
            }
            break :blk true;
        },
        .err => |failure| blk: {
            var buf = std.Io.Writer.Allocating.init(vm.alloc);
            defer buf.deinit();
            failure.render(vm.alloc, &buf.writer, program.source) catch {
                setError(vm, "runtime error");
                break :blk false;
            };
            setError(vm, buf.written());
            break :blk false;
        },
    };
}

pub export fn erevo_vm_create() callconv(.c) ?*ErevoVM {
    return @ptrCast(makeVm(std.heap.page_allocator) catch return null);
}

pub export fn erevo_vm_destroy(vm: ?*ErevoVM) callconv(.c) void {
    const self = vmOf(vm) orelse return;
    clearError(self);
    self.runtime.deinit();
    self.io.deinit();
    self.alloc.destroy(self);
}

pub export fn erevo_vm_last_error(vm: ?*ErevoVM) callconv(.c) [*:0]const u8 {
    const self = vmOf(vm) orelse return "";
    return if (self.last_error) |msg| msg.ptr else "";
}

pub export fn erevo_compile(vm: ?*ErevoVM, name: [*:0]const u8, source: [*:0]const u8) callconv(.c) ?*ErevoProgram {
    const self = vmOf(vm) orelse return null;
    const name_slice = std.mem.span(name);
    const source_slice = std.mem.span(source);
    return @ptrCast(compileProgram(self, name_slice, source_slice) orelse return null);
}

pub export fn erevo_program_destroy(program: ?*ErevoProgram) callconv(.c) void {
    const self = programOf(program) orelse return;
    freeProgram(self);
}

pub export fn erevo_run(vm: ?*ErevoVM, program: ?*ErevoProgram, out_value: ?*ErevoData) callconv(.c) bool {
    const self = vmOf(vm) orelse return false;
    const compiled = programOf(program) orelse return false;
    return runProgram(self, compiled, out_value);
}

pub export fn erevo_eval(vm: ?*ErevoVM, name: [*:0]const u8, source: [*:0]const u8, out_value: ?*ErevoData) callconv(.c) bool {
    const self = vmOf(vm) orelse return false;
    const name_slice = std.mem.span(name);
    const source_slice = std.mem.span(source);
    const program = compileProgram(self, name_slice, source_slice) orelse return false;
    defer freeProgram(program);
    return runProgram(self, program, out_value);
}
