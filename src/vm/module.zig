const std = @import("std");

const revo = @import("revo");
const lang = revo.lang;
const testing = revo.lang.testing;
const Data = revo.Data;

pub fn runModule(vm: *revo.VM, source_path: []const u8, source: []const u8) !revo.Data {
    const result = try runModuleReport(vm, source_path, source);
    if (result == .err) return error.RuntimeFailure;
    return vm.currentFiber().result;
}

pub fn runModuleReport(vm: *revo.VM, source_path: []const u8, source: []const u8) !revo.EvalResult {
    const artifact = switch (try lang.build(vm, .{ .name = source_path, .text = source }, .{})) {
        .ok => |ok| ok,
        .err => |lang_err| {
            revo.printBuildError(vm.runtime.alloc, .{ .name = source_path, .text = source }, lang_err);
            return error.ParseError;
        },
    };
    defer vm.runtime.alloc.free(artifact.instructions);
    defer vm.runtime.alloc.free(artifact.spans);
    return runCompiledModuleReport(vm, source_path, artifact.instructions);
}

pub fn runImportedModule(vm: *revo.VM, source_path: []const u8, source: []const u8) !revo.Data {
    const result = try runImportedModuleReport(vm, source_path, source);
    if (result == .err) return error.RuntimeFailure;
    return vm.currentFiber().result;
}

pub fn runImportedModuleReport(vm: *revo.VM, source_path: []const u8, source: []const u8) !revo.EvalResult {
    const artifact = switch (try lang.build(vm, .{ .name = source_path, .text = source }, .{
        .module_mode = true,
    })) {
        .ok => |ok| ok,
        .err => |lang_err| {
            revo.printBuildError(vm.runtime.alloc, .{ .name = source_path, .text = source }, lang_err);
            return error.ParseError;
        },
    };
    defer vm.runtime.alloc.free(artifact.instructions);
    defer vm.runtime.alloc.free(artifact.spans);
    return runCompiledImportedModuleReport(vm, source_path, artifact.instructions);
}

fn swapFiberAndRun(vm: *revo.VM, source_path: []const u8, program: []const revo.Instruction) !struct { result: revo.EvalResult, prev: revo.VM.Fiber } {
    try vm.setProgramSourceName(source_path);

    const module_dir = std.fs.path.dirname(source_path) orelse ".";
    const prev_module_dir = vm.module_dir;
    vm.module_dir = module_dir;
    defer vm.module_dir = prev_module_dir;

    const fiber = try revo.VM.Fiber.init(vm.runtime.alloc, vm.currentFiber().id, program);
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
    const mg = revo.VM.Globals.init(vm.runtime.alloc);
    const mcg = @TypeOf(vm.const_globals).init(vm.runtime.alloc);

    const pg = vm.globals;
    const pcg = vm.const_globals;
    vm.globals = mg;
    vm.const_globals = mcg;
    defer {
        vm.globals.deinit();
        vm.const_globals.deinit();
        vm.globals = pg;
        vm.const_globals = pcg;
    }

    try vm.seedBootstrapGlobals(&vm.globals);

    var r = try swapFiberAndRun(vm, source_path, program);
    defer {
        var finished = vm.swapFiber(r.prev);
        revo.VM.Fiber.deinit(&finished, vm.runtime.alloc);
    }
    if (r.result == .ok) r.prev.result = vm.currentResult();
    return r.result;
}

pub fn runCompiledImportedModuleReport(
    vm: *revo.VM,
    source_path: []const u8,
    program: []const revo.Instruction,
) !revo.EvalResult {
    const mg = revo.VM.Globals.init(vm.runtime.alloc);
    const mcg = @TypeOf(vm.const_globals).init(vm.runtime.alloc);

    const pg = vm.globals;
    const pcg = vm.const_globals;
    vm.globals = mg;
    vm.const_globals = mcg;
    defer {
        vm.globals.deinit();
        vm.const_globals.deinit();
        vm.globals = pg;
        vm.const_globals = pcg;
    }

    try vm.seedBootstrapGlobals(&vm.globals);
    const exports_atom = try vm.internAtom("__module_pub_exports");
    const exports_table = try vm.tables.create();
    const ns = try vm.createNamespace(source_path, exports_table);
    try vm.globals.put(exports_atom, ns);

    var r = try swapFiberAndRun(vm, source_path, program);
    defer {
        var finished = vm.swapFiber(r.prev);
        revo.VM.Fiber.deinit(&finished, vm.runtime.alloc);
    }
    if (r.result == .ok) {
        const exports_value = vm.globals.get(exports_atom) orelse ns;
        r.prev.result = exports_value;
    }
    return r.result;
}

/// run compiled code in the current vm globals or constglobals context
/// intended for repl
pub fn runCompiledSessionReport(
    vm: *revo.VM,
    source_path: []const u8,
    program: []const revo.Instruction,
) !revo.EvalResult {
    try vm.seedBootstrapGlobals(&vm.globals);
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

test "module cache reloads changed files" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "hot.rv",
        .data =
        \\ pub const value = 1
        ,
    });

    const module_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(module_dir);

    const source_name = try std.fmt.allocPrint(alloc, "{s}/script.rv", .{module_dir});
    defer alloc.free(source_name);

    const code =
        \\ const ns = import "hot"
        \\ ns.value
    ;

    var vm = try revo.VM.init(testing.runtime());
    defer vm.deinit();
    vm.module_dir = module_dir;

    const artifact = switch (try lang.build(&vm, .{ .name = source_name, .text = code }, .{})) {
        .ok => |ok| ok,
        .err => |lang_err| {
            defer lang.deinitError(alloc, lang_err);
            return error.ParseError;
        },
    };
    defer vm.runtime.alloc.free(artifact.instructions);
    defer vm.runtime.alloc.free(artifact.spans);

    _ = try runCompiledSessionReport(&vm, source_name, artifact.instructions);
    try std.testing.expectEqual(Data.new.num(1), vm.mainResult());

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "hot.rv",
        .data =
        \\ pub const value = 2
        ,
    });

    _ = try runCompiledSessionReport(&vm, source_name, artifact.instructions);
    try std.testing.expectEqual(Data.new.num(2), vm.mainResult());
}

pub const NamespaceID = usize;

pub const Namespace = struct {
    path: []const u8,
    exports: revo.memory.TableID,
};

pub const NamespacePool = struct {
    alloc: std.mem.Allocator,
    modules: std.ArrayList(?Namespace),
    marks: std.DynamicBitSet,
    dead: std.ArrayList(NamespaceID),

    pub fn init(alloc: std.mem.Allocator) !NamespacePool {
        return .{
            .alloc = alloc,
            .modules = try std.ArrayList(?Namespace).initCapacity(alloc, 4),
            .marks = try std.DynamicBitSet.initEmpty(alloc, 64),
            .dead = try std.ArrayList(NamespaceID).initCapacity(alloc, 0),
        };
    }

    pub fn deinit(self: *NamespacePool) void {
        for (self.modules.items) |*maybe_ns| {
            if (maybe_ns.*) |*ns| self.alloc.free(ns.path);
        }
        self.modules.deinit(self.alloc);
        self.marks.deinit();
        self.dead.deinit(self.alloc);
    }

    pub fn create(self: *NamespacePool, path: []const u8, exports: revo.memory.TableID) !NamespaceID {
        const owned_path = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(owned_path);

        if (self.dead.pop()) |id| {
            self.modules.items[id] = .{
                .path = owned_path,
                .exports = exports,
            };
            return id;
        }

        const id: NamespaceID = @intCast(self.modules.items.len);
        try self.modules.append(self.alloc, .{
            .path = owned_path,
            .exports = exports,
        });
        if (id >= self.marks.capacity()) {
            try self.marks.resize(self.modules.items.len, false);
        }
        return id;
    }

    pub fn get(self: *NamespacePool, id: NamespaceID) !*Namespace {
        if (id >= self.modules.items.len) return error.InvalidNamespace;
        if (self.modules.items[id]) |*ns| return ns;
        return error.InvalidNamespace;
    }

    pub fn mark(self: *NamespacePool, id: NamespaceID, vm: *revo.VM) void {
        if (id >= self.modules.items.len) return;
        if (self.modules.items[id] == null) return;
        if (self.marks.isSet(id)) return;
        self.marks.set(id);
        vm.pushMarkNamespace(id);
    }

    pub fn sweep(self: *NamespacePool) void {
        const max_dead = self.modules.items.len;
        self.dead.ensureTotalCapacity(self.alloc, max_dead) catch return;
        self.dead.items.len = 0;
        for (self.modules.items, 0..) |*maybe_ns, idx| {
            if (maybe_ns.* == null) continue;
            if (self.marks.isSet(idx)) continue;
            self.alloc.free(maybe_ns.*.?.path);
            maybe_ns.* = null;
            self.dead.appendAssumeCapacity(@intCast(idx));
        }
        self.marks.unmanaged.unsetAll();
    }

    pub fn sweepStep(self: *NamespacePool, cursor: usize, limit: usize) usize {
        if (cursor >= self.modules.items.len) return 0;
        const end = @min(cursor + limit, self.modules.items.len);
        var processed: usize = 0;
        var i = cursor;
        while (i < end) : (i += 1) {
            processed += 1;
            const maybe_ns = self.modules.items[i];
            if (maybe_ns == null) continue;
            if (self.marks.isSet(i)) continue;
            self.alloc.free(maybe_ns.?.path);
            self.modules.items[i] = null;
            self.dead.append(self.alloc, @intCast(i)) catch {};
        }
        return processed;
    }

    pub fn clearMarks(self: *NamespacePool) void {
        self.marks.unmanaged.unsetAll();
    }

    pub fn capacity(self: *const NamespacePool) usize {
        return self.modules.items.len;
    }

    pub fn bytes(self: *const NamespacePool) usize {
        var total: usize = 0;
        for (self.modules.items) |maybe_ns| {
            if (maybe_ns) |ns| total += ns.path.len + @sizeOf(Namespace);
        }
        return total;
    }
};
