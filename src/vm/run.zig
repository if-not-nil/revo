const std = @import("std");

const revo = @import("revo");
const lang = revo.lang;
const testing = revo.lang.test_helpers;
const Value = revo.Value;

pub fn runModule(vm: *revo.VM, source_path: []const u8, source: []const u8, module_scope: bool) !revo.RunResult {
    const opts: lang.BuildOptions = if (module_scope) .{ .module_scope = true } else .{};
    const bytecode = switch (try lang.build(vm, .{ .name = source_path, .text = source }, opts)) {
        .ok => |ok| ok,
        .err => |lang_err| {
            revo.printBuildError(vm.runtime.diagAlloc(), .{ .name = source_path, .text = source }, lang_err, vm.runtime.supports_color);
            vm.runtime.resetDiagArena();
            return error.ParseError;
        },
    };
    defer vm.runtime.alloc.free(bytecode.instructions);
    defer vm.runtime.alloc.free(bytecode.spans);
    return runBytecodeReport(vm, source_path, bytecode.instructions);
}

pub const ModuleStart = union(enum) {
    loaded: Value,
    /// importers join this fiber
    loading: revo.VM.FiberID,
    failed: Failed,

    pub const Failed = struct {
        reason: []const u8,
        /// an `EvalError` table when asked for `.value`
        eval_error: ?Value = null,
    };
};

pub const StartOptions = struct {
    /// rerun a loaded module
    fresh: bool = false,
    /// `.print` reports a build failure on stderr, `.value` hands back an `EvalError`
    report: enum { print, value } = .print,
};

/// the module at realpath `path`. if it isn't loaded, its body starts on a fiber
pub fn startModule(vm: *revo.VM, path: []const u8, opts: StartOptions) !ModuleStart {
    const alloc = vm.runtime.alloc;

    if (vm.modules.get(path)) |m| switch (m) {
        .loaded => |v| if (!opts.fresh) return .{ .loaded = v },
        // a panic in the body killed its fiber, so the load starts over
        .loading => |fid| if (vm.module_fibers.get(fid) != null and vm.sched.fibers.items[fid].state != .dead)
            return .{ .loading = fid },
    };

    const bundled = if (vm.bundle) |b| b.files.get(path) else null;
    const source = if (bundled) |text| try alloc.dupe(u8, text) else std.Io.Dir.cwd().readFileAlloc(vm.runtime.io, path, alloc, .unlimited) catch |err| {
        const reason = revo.import_path.message(err);
        if (opts.report == .print) return .{ .failed = .{ .reason = reason } };
        const table = try lang.diagnostic.evalErrorTable(vm, .{ .message = reason }, path, "", "io", null, &.{});
        return .{ .failed = .{ .reason = reason, .eval_error = table } };
    };
    defer alloc.free(source);

    // the build swaps the pending debug info, the importer keeps its own
    const prev_debug = vm.pending_debug_info_id;
    defer vm.pending_debug_info_id = prev_debug;

    const bytecode = switch (try lang.build(vm, .{ .name = path, .text = source }, .{ .module_scope = true })) {
        .ok => |ok| ok,
        .err => |lang_err| {
            const reason = "module failed to build";
            if (opts.report == .print) {
                revo.printBuildError(vm.runtime.diagAlloc(), .{ .name = path, .text = source }, lang_err, vm.runtime.supports_color);
                vm.runtime.resetDiagArena();
                return .{ .failed = .{ .reason = reason } };
            }
            const rep = lang.pipeline.errorReport(lang_err);
            const table = try lang.diagnostic.evalErrorTable(vm, rep, path, source, @tagName(lang_err), null, &.{});
            vm.runtime.resetDiagArena();
            return .{ .failed = .{ .reason = reason, .eval_error = table } };
        },
    };
    defer alloc.free(bytecode.instructions);
    defer alloc.free(bytecode.spans);

    // the stub ends `make_closure __main, call, halt`
    // ; __main captures nothing, so it runs as its own fiber with no stub at all
    const ins = bytecode.instructions;
    std.debug.assert(ins.len >= 3 and ins[ins.len - 3].op == .make_closure and ins[ins.len - 1].op == .halt);
    const template = ins[ins.len - 3].bx;
    const fid = try vm.spawnClosure(try vm.callable.createClosure(template, &.{}));
    vm.sched.fibers.items[fid].debug_info_id = vm.pending_debug_info_id;

    const gop = try vm.modules.getOrPut(alloc, path);
    if (!gop.found_existing) {
        gop.key_ptr.* = alloc.dupe(u8, path) catch |err| {
            vm.modules.removeByPtr(gop.key_ptr);
            return err;
        };
    }

    gop.value_ptr.* = .{ .loading = fid };
    try vm.module_fibers.put(alloc, fid, gop.key_ptr.*);
    return .{ .loading = fid };
}

fn swapFiberAndRun(
    vm: *revo.VM,
    source_path: []const u8,
    program: []const revo.Instruction,
) !struct { result: revo.RunResult, prev: revo.VM.Fiber } {
    try vm.setProgramSourceName(source_path);

    vm.closeUpvalueList(vm.currentFiber(), 0) catch {};

    var fiber = try revo.VM.Fiber.init(vm.runtime.alloc, vm.currentFiber().id, program, revo.VM.INIT_REG_COUNT);
    fiber.debug_info_id = vm.pending_debug_info_id;

    const outer_idx = vm.sched.currentID();
    const prev = vm.swapFiber(fiber);
    errdefer {
        vm.sched.setCurrent(outer_idx);
        var finished = vm.swapFiber(prev);
        vm.closeUpvalueList(&finished, 0) catch {};
        revo.VM.Fiber.deinit(&finished, vm.runtime.alloc);
    }

    const result = try revo.vm.dispatch.runReport(vm);
    vm.sched.setCurrent(outer_idx);
    return .{ .result = result, .prev = prev };
}

pub fn runBytecodeReport(
    vm: *revo.VM,
    source_path: []const u8,
    program: []const revo.Instruction,
) !revo.RunResult {
    try vm.setProgramSourceName(source_path);

    var r = try swapFiberAndRun(vm, source_path, program);
    defer {
        var finished = vm.swapFiber(r.prev);
        // close upvalues captured by the old fiber before its registers are
        // freed: globals survive reloads and may hold closures that read them
        vm.closeUpvalueList(&finished, 0) catch {};
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

test "a module loads once per vm, `revo.load` with `fresh` reruns it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hot.rv", .data = "1" });

    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(dir);
    const source_name = try alloc.print("{s}/script.rv", .{dir});
    defer alloc.free(source_name);
    const hot = try alloc.print("{s}/hot.rv", .{dir});
    defer alloc.free(hot);

    var vm = try revo.VM.init(testing.runtime());
    defer vm.deinit();

    const res = try runModule(&vm, source_name, "import(\"./hot\")", false);
    try std.testing.expect(res == .ok);
    try std.testing.expectEqual(Value.new.num(1), vm.mainResult());

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hot.rv", .data = "2" });

    const again = try runModule(&vm, source_name, "import(\"./hot\")", false);
    try std.testing.expect(again == .ok);
    try std.testing.expectEqual(Value.new.num(1), vm.mainResult());

    const reload = try alloc.print("revo.load(\"{s}\", {{fresh = :true}})[1]", .{hot});
    defer alloc.free(reload);
    const fresh = try runModule(&vm, source_name, reload, false);
    try std.testing.expect(fresh == .ok);
    try std.testing.expectEqual(Value.new.num(2), vm.mainResult());
}

test "a bundled program runs with its sources gone" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "sub");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sub/geo.rv", .data = "pub const zz_pi = 3\npub fn zz_area(r) zz_pi * r * r\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sub/shapes.rv", .data = "const geo = import(\"./geo\")\npub fn zz_big() geo.zz_area(10)\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lazy.rv", .data = "pub const zz_lazy = 7\n" });

    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(dir);
    const name = try alloc.print("{s}/main.rv", .{dir});
    defer alloc.free(name);
    const code =
        \\ const shapes = import("./sub/shapes")
        \\ fn later() import("./lazy").zz_lazy
        \\ shapes.zz_big() + later()
    ;

    // compile with the graph, the way `revo compile` does
    const blob = blk: {
        var vm = try revo.VM.init(testing.runtime());
        defer vm.deinit();
        var graph = lang.import_graph.Graph.init(alloc);
        defer graph.deinit();
        const bytecode = switch (try lang.build(&vm, .{ .name = name, .text = code }, .{ .imports = &graph })) {
            .ok => |ok| ok,
            .err => return error.ParseError,
        };
        defer alloc.free(bytecode.instructions);
        defer alloc.free(bytecode.spans);

        try std.testing.expectEqual(@as(usize, 3), graph.files.count());
        break :blk try revo.bytecode.serialize(&vm, bytecode, alloc, &graph);
    };
    defer alloc.free(blob);

    try tmp.dir.deleteTree(std.testing.io, "sub");
    try tmp.dir.deleteFile(std.testing.io, "lazy.rv");

    var vm = try revo.VM.init(testing.runtime());
    defer vm.deinit();
    var loaded = try revo.bytecode.deserialize(&vm, blob, alloc);
    defer loaded.deinit();
    const res = try runBytecodeReport(&vm, name, loaded.instructions);
    try std.testing.expect(res == .ok);
    try std.testing.expectEqual(Value.new.num(307), vm.mainResult());
}

test "the import graph has every module, edge and binding the checker resolved" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.rv", .data = "const b = import(\"./b\")\npub const x = 1\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.rv", .data = "pub const y = 2\n" });

    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(dir);
    const name = try alloc.print("{s}/main.rv", .{dir});
    defer alloc.free(name);
    const a = try alloc.print("{s}/a.rv", .{dir});
    defer alloc.free(a);
    const b = try alloc.print("{s}/b.rv", .{dir});
    defer alloc.free(b);

    var vm = try revo.VM.init(testing.runtime());
    defer vm.deinit();
    var graph = lang.import_graph.Graph.init(alloc);
    defer graph.deinit();
    try lang.pipeline.importGraph(&vm, .{ .name = name, .text = "use(\"./a\")\na.x" }, &graph);

    // deps first
    try std.testing.expectEqualStrings(b, graph.files.keys()[0]);
    try std.testing.expectEqualStrings(a, graph.files.keys()[1]);
    try std.testing.expectEqualStrings(a, graph.bindings.get("a").?);
    try std.testing.expectEqualStrings(a, graph.edge(name, "./a").?);
    try std.testing.expectEqualStrings(b, graph.edge(a, "./b").?);
    try std.testing.expectEqual(@as(usize, 1), graph.sites.count());
}
