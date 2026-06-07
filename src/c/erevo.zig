//
// embedding api for embedding revo from c
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
    last_error: ?[:0]u8 = null,
};

const Program = struct {
    alloc: std.mem.Allocator,
    name: [:0]u8,
    source: [:0]u8,
    artifact: revo.lang.Artifact,
};

fn compileProgram(inner: *revo.VM, name: []const u8, source: []const u8) ?*Program {
    const self: *VM = @ptrCast(@alignCast(inner.c_data.?));
    if (self.last_error) |msg| self.alloc.free(msg);
    self.last_error = null;

    const result = revo.lang.build(inner, .{ .name = name, .text = source }, .{}) catch |err| {
        const msg = std.fmt.allocPrint(self.alloc, "{}", .{err}) catch return null;
        defer self.alloc.free(msg);

        self.last_error = self.alloc.dupeZ(u8, msg) catch null;
        return null;
    };

    return switch (result) {
        .ok => |artifact| blk: {
            const program = self.alloc.create(Program) catch return null;
            const name_z = self.alloc.dupeZ(u8, name) catch return null;
            const source_z = self.alloc.dupeZ(u8, source) catch return null;
            program.* = .{
                .alloc = self.alloc,
                .name = name_z,
                .source = source_z,
                .artifact = artifact,
            };
            break :blk program;
        },
        .err => |failure| blk: {
            var buf = std.Io.Writer.Allocating.init(self.alloc);
            defer buf.deinit();
            revo.lang.renderError(self.alloc, &buf.writer, .{ .name = name, .text = source }, failure) catch {
                self.last_error = self.alloc.dupeZ(u8, "compile error") catch null;
                inner.runtime.resetDiagArena();
                break :blk null;
            };
            self.last_error = self.alloc.dupeZ(u8, buf.written()) catch null;
            inner.runtime.resetDiagArena();
            break :blk null;
        },
    };
}

fn runProgram(inner: *revo.VM, program: *Program, out_value: ?*ErevoData) bool {
    const self: *VM = @ptrCast(@alignCast(inner.c_data.?));
    if (self.last_error) |msg| self.alloc.free(msg);
    self.last_error = null;

    inner.setProgramDebugInfo(program.artifact.spans, program.source, program.name) catch |err| {
        const msg = std.fmt.allocPrint(self.alloc, "{}", .{err}) catch return false;
        defer self.alloc.free(msg);
        self.last_error = self.alloc.dupeZ(u8, msg) catch null;
        return false;
    };

    const result = revo.module.runCompiledModuleReport(inner, program.name, program.artifact.instructions) catch |err| {
        const msg = std.fmt.allocPrint(self.alloc, "{}", .{err}) catch return false;
        defer self.alloc.free(msg);
        self.last_error = self.alloc.dupeZ(u8, msg) catch null;
        return false;
    };

    return switch (result) {
        .ok => blk: {
            if (out_value) |out| {
                const crd = revo.functions.CRevoData.fromData(inner.currentResult());
                out.* = @bitCast(crd);
            }
            break :blk true;
        },
        .err => |failure| blk: {
            var buf = std.Io.Writer.Allocating.init(self.alloc);
            defer buf.deinit();
            failure.render(self.alloc, &buf.writer, program.source) catch {
                self.last_error = self.alloc.dupeZ(u8, "runtime error") catch null;
                inner.runtime.resetDiagArena();
                break :blk false;
            };
            self.last_error = self.alloc.dupeZ(u8, buf.written()) catch null;
            inner.runtime.resetDiagArena();
            break :blk false;
        },
    };
}

pub export fn erevo_vm_create() callconv(.c) ?*ErevoVM {
    const alloc = std.heap.page_allocator; // TODO: switch to c_allocator once GC gets triggered less
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

pub export fn erevo_vm_destroy(vm: ?*ErevoVM) callconv(.c) void {
    const inner = if (vm) |p| @as(*revo.VM, @ptrCast(@alignCast(p))) else return;
    const self: *VM = @ptrCast(@alignCast(inner.c_data.?));
    if (self.last_error) |msg| self.alloc.free(msg);

    inner.runtime.deinit();
    self.io.deinit();
    self.alloc.destroy(self);
}

pub export fn erevo_vm_last_error(vm: ?*ErevoVM) callconv(.c) [*:0]const u8 {
    const inner = if (vm) |p| @as(*revo.VM, @ptrCast(@alignCast(p))) else return "";
    const self: *VM = @ptrCast(@alignCast(inner.c_data.?));

    return if (self.last_error) |msg| msg.ptr else "";
}

pub export fn erevo_compile(vm: ?*ErevoVM, name: [*:0]const u8, source: [*:0]const u8) callconv(.c) ?*ErevoProgram {
    const inner = if (vm) |p| @as(*revo.VM, @ptrCast(@alignCast(p))) else return null;
    return @ptrCast(compileProgram(inner, std.mem.span(name), std.mem.span(source)) orelse return null);
}

pub export fn erevo_program_destroy(program: ?*ErevoProgram) callconv(.c) void {
    const self = if (program) |p| @as(*Program, @ptrCast(@alignCast(p))) else return;

    self.alloc.free(self.artifact.instructions);
    self.alloc.free(self.artifact.spans);
    self.alloc.free(self.name);
    self.alloc.free(self.source);
    self.alloc.destroy(self);
}

pub export fn erevo_run(vm: ?*ErevoVM, program: ?*ErevoProgram, out_value: ?*ErevoData) callconv(.c) bool {
    const inner = if (vm) |p| @as(*revo.VM, @ptrCast(@alignCast(p))) else return false;
    const compiled = if (program) |p| @as(*Program, @ptrCast(@alignCast(p))) else return false;

    return runProgram(inner, compiled, out_value);
}

pub export fn erevo_eval(vm: ?*ErevoVM, name: [*:0]const u8, source: [*:0]const u8, out_value: ?*ErevoData) callconv(.c) bool {
    const inner = if (vm) |p|
        @as(*revo.VM, @ptrCast(@alignCast(p)))
    else
        return false;
    const program = compileProgram(inner, std.mem.span(name), std.mem.span(source)) orelse return false;

    defer {
        program.alloc.free(program.artifact.instructions);
        program.alloc.free(program.artifact.spans);
        program.alloc.free(program.name);
        program.alloc.free(program.source);
        program.alloc.destroy(program);
    }
    return runProgram(inner, program, out_value);
}
