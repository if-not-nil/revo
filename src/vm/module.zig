const std = @import("std");

const revo = @import("revo");
const lang = revo.lang;
const testing = revo.lang.testing;
const Data = revo.Data;

fn buildAndRun(vm: *revo.VM, source_path: []const u8, source: []const u8, module_scope: bool) !revo.EvalResult {
    const opts: lang.BuildOptions = if (module_scope) .{ .module_scope = true } else .{};
    const artifact = switch (try lang.build(vm, .{ .name = source_path, .text = source }, opts)) {
        .ok => |ok| ok,
        .err => |lang_err| {
            revo.printBuildError(vm.runtime.diagAlloc(), .{ .name = source_path, .text = source }, lang_err);
            vm.runtime.resetDiagArena();
            return error.ParseError;
        },
    };
    defer vm.runtime.alloc.free(artifact.instructions);
    defer vm.runtime.alloc.free(artifact.spans);
    return runCompiledModuleReport(vm, source_path, artifact.instructions);
}

pub fn runModule(vm: *revo.VM, source_path: []const u8, source: []const u8) !revo.Data {
    const result = try buildAndRun(vm, source_path, source, false);
    if (result == .err) return error.RuntimeFailure;
    return vm.currentFiber().result;
}

pub fn runModuleReport(vm: *revo.VM, source_path: []const u8, source: []const u8) !revo.EvalResult {
    return buildAndRun(vm, source_path, source, false);
}

pub fn runImportedModule(vm: *revo.VM, source_path: []const u8, source: []const u8) !revo.Data {
    const result = try buildAndRun(vm, source_path, source, true);
    if (result == .err) return error.RuntimeFailure;
    return vm.currentFiber().result;
}

fn swapFiberAndRun(vm: *revo.VM, source_path: []const u8, program: []const revo.Instruction) !struct { result: revo.EvalResult, prev: revo.VM.Fiber } {
    try vm.setProgramSourceName(source_path);

    // clear icache between independent program runs to prevent stale
    // hits when two different compilations reuse the same pc positions
    for (&vm.icache) |*entry|
        entry.* = .{ .pc = std.math.maxInt(revo.ProgramCounter), .table_id = 0, .version = 0, .value = undefined };

    const module_dir = std.fs.path.dirname(source_path) orelse ".";
    const prev_module_dir = vm.module_dir;
    vm.module_dir = module_dir;
    defer vm.module_dir = prev_module_dir;

    const fiber = try revo.VM.Fiber.init(vm.runtime.alloc, vm.currentFiber().id, program, revo.VM.INIT_REG_COUNT);
    var fiber_wd = fiber;
    fiber_wd.debug_info_id = vm.pending_debug_info_id;

    const prev = vm.swapFiber(fiber_wd);
    const result = try vm.runReport();
    return .{ .result = result, .prev = prev };
}

pub fn runCompiledModuleReport(
    vm: *revo.VM,
    source_path: []const u8,
    program: []const revo.Instruction,
) !revo.EvalResult {
    try vm.setProgramSourceName(source_path);

    var r = try swapFiberAndRun(vm, source_path, program);
    defer {
        var finished = vm.swapFiber(r.prev);
        revo.VM.Fiber.deinit(&finished, vm.runtime.alloc);
    }
    if (r.result == .ok) r.prev.result = vm.currentResult();
    return r.result;
}

test "module message setters clear previous values" {
    var vm = try revo.VM.init(testing.runtime());
    defer vm.deinit();

    try vm.setProgramDebugInfo(&.{}, "", "one.rv");
    try vm.setProgramSourceName("one.rv");
    try std.testing.expectEqualStrings("one.rv", vm.currentDebugSourceName().?);
    try vm.setProgramSourceName("two.rv");
    try std.testing.expectEqualStrings("two.rv", vm.currentDebugSourceName().?);

    try vm.setPanicMessage("panic-a");
    try std.testing.expectEqualStrings("panic-a", vm.panic_message.?);
    try vm.setPanicMessage("panic-b");
    try std.testing.expectEqualStrings("panic-b", vm.panic_message.?);
    vm.clearPanicMessage();
    try std.testing.expect(vm.panic_message == null);

    try vm.setRuntimeMessage("runtime-a");
    try std.testing.expectEqualStrings("runtime-a", vm.runtime_message.?);
    try vm.setRuntimeMessageFmt("runtime-{d}", .{7});
    try std.testing.expectEqualStrings("runtime-7", vm.runtime_message.?);
    vm.clearRuntimeMessage();
    try std.testing.expect(vm.runtime_message == null);
}

test "module hot reload cache" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "hot.rv",
        .data =
        \\ 1
        ,
    });

    const module_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(module_dir);

    const source_name = try std.fmt.allocPrint(alloc, "{s}/script.rv", .{module_dir});
    defer alloc.free(source_name);

    const code =
        \\ const ns = import "./hot"
        \\ ns
    ;

    var vm = try revo.VM.init(testing.runtime());
    defer vm.deinit();
    vm.module_dir = module_dir;

    const artifact = switch (try lang.build(&vm, .{ .name = source_name, .text = code }, .{})) {
        .ok => |ok| ok,
        .err => return error.ParseError,
    };
    defer vm.runtime.alloc.free(artifact.instructions);
    defer vm.runtime.alloc.free(artifact.spans);

    _ = try runCompiledModuleReport(&vm, source_name, artifact.instructions);
    try std.testing.expectEqual(Data.new.num(1), vm.mainResult());

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "hot.rv",
        .data =
        \\ 2
        ,
    });

    _ = try runCompiledModuleReport(&vm, source_name, artifact.instructions);
    try std.testing.expectEqual(Data.new.num(2), vm.mainResult());
}
