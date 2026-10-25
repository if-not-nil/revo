const std = @import("std");
const alloc = std.testing.allocator;
const io = std.testing.io;

const diagnostic = @import("diagnostic.zig");
const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");
const pipeline = @import("pipeline.zig");
const revo = @import("revo");

pub fn runtime() revo.Runtime {
    return .{
        .alloc = alloc,
        .io = io,
        .diag_alloc = alloc,
        .diag_arena = null,
    };
}

pub fn expectTypes(source: []const u8, expected: []const Lexer.TokenType) !void {
    try Lexer.testing.expectTypes(source, expected);
}

pub fn expectTokens(source: []const u8, expected: []const Lexer.testing.ExpectedToken) !void {
    try Lexer.testing.expectTokens(source, expected);
}

const TopResult = struct {
    vm: revo.VM,
    value: revo.Value,

    pub fn deinit(self: *TopResult) void {
        self.vm.deinit();
    }
};

/// a miss means the compiler fell back to `any` without semantic saying so
pub fn expectNoAnnotationMisses(stats: revo.lang.compiler.CompileStats, source: []const u8) !void {
    if (stats.annotation_misses == 0) return;
    if (stats.first_annotation_miss) |miss| {
        std.debug.print(
            "annotation miss: {s} at {d}:{d} in:\n{s}\n",
            .{ miss.kind, miss.span.line, miss.span.column, source },
        );
    }
    return error.AnnotationMiss;
}

fn compileChecked(vm: *revo.VM, source: []const u8) ![]revo.Instruction {
    var stats = revo.lang.compiler.CompileStats{};
    const result = try pipeline.build(vm, .{ .text = source }, .{
        .install_debug_info = true,
        .annotation_stats = &stats,
    });
    try expectNoAnnotationMisses(stats, source);
    return switch (result) {
        .ok => |bytecode| blk: {
            alloc.free(bytecode.spans);
            break :blk bytecode.instructions;
        },
        .err => |lang_err| {
            defer pipeline.deinitError(lang_err);
            revo.printBuildError(alloc, .{ .text = source }, lang_err, vm.runtime.supports_color);
            vm.runtime.resetDiagArena();
            return error.LangFailure;
        },
    };
}

/// compile without running and return compiler annotation coverage
pub fn compileStats(source: []const u8) !revo.lang.compiler.CompileStats {
    var vm = try revo.VM.init(runtime());
    defer vm.deinit();

    var stats = revo.lang.compiler.CompileStats{};
    const result = try pipeline.build(&vm, .{ .text = source }, .{
        .annotation_stats = &stats,
    });
    switch (result) {
        .ok => |bytecode| {
            alloc.free(bytecode.instructions);
            alloc.free(bytecode.spans);
        },
        .err => |lang_err| {
            defer pipeline.deinitError(lang_err);
            revo.printBuildError(alloc, .{ .text = source }, lang_err, vm.runtime.supports_color);
            vm.runtime.resetDiagArena();
            return error.LangFailure;
        },
    }
    return stats;
}

fn runTopModuleChecked(vm: *revo.VM, source: []const u8, source_name: []const u8) !void {
    const result = try revo.run.runModule(vm, source_name, source, false);
    switch (result) {
        .ok => {},
        .err => |failure| {
            revo.printRunError(alloc, source, failure, vm.runtime.supports_color);
            vm.runtime.resetDiagArena();
            return error.RuntimeFailure;
        },
    }
}

pub fn topResult(source: []const u8, import_dir: ?[]const u8) !TopResult {
    return topResultOpts(source, import_dir, .{});
}

pub fn topResultOpts(
    source: []const u8,
    import_dir: ?[]const u8,
    opts: pipeline.BuildOptions,
) !TopResult {
    var vm = try revo.VM.init(runtime());
    errdefer vm.deinit();
    const src_name: []const u8 = if (import_dir) |dir| blk: {
        vm.import_dir = dir;
        const joined = try std.Io.Dir.path.join(alloc, &.{ dir, "<source>" });
        break :blk joined;
    } else "<source>";
    defer if (import_dir != null) alloc.free(src_name);

    var stats = revo.lang.compiler.CompileStats{};
    var build_opts = opts;
    build_opts.annotation_stats = &stats;

    const built = try pipeline.build(&vm, .{ .name = src_name, .text = source }, build_opts);
    try expectNoAnnotationMisses(stats, source);

    switch (built) {
        .ok => |bytecode| {
            alloc.free(bytecode.instructions);
            alloc.free(bytecode.spans);
        },
        .err => |lang_err| {
            defer pipeline.deinitError(lang_err);
            revo.printBuildError(alloc, .{ .name = src_name, .text = source }, lang_err, vm.runtime.supports_color);
            vm.runtime.resetDiagArena();
            return error.LangFailure;
        },
    }
    try runTopModuleChecked(&vm, source, src_name);
    return .{
        .vm = vm,
        .value = vm.mainResult(),
    };
}

pub fn topTrueOpts(opts: pipeline.BuildOptions, source: []const u8) !void {
    try topTrueOptsInDir(null, opts, source);
}

pub fn topTrueOptsInDir(
    import_dir: ?[]const u8,
    opts: pipeline.BuildOptions,
    source: []const u8,
) !void {
    var result = try topResultOpts(source, import_dir, opts);
    defer result.deinit();
    try std.testing.expect(!revo.isFalse(result.value));
}

fn expectTopNumber(result: *TopResult, expected: f64) !void {
    const actual = result.value.asNum() catch {
        std.debug.print("result was not a number, it was {s}\n", .{revo.baselib.typeof(result.value, &result.vm)});
        return error.TypeMismatch;
    };
    if (@abs(expected - actual) > 0.000000001) {
        std.debug.print("wanted {}, got {}\n", .{ expected, actual });
        return error.NumbersDontMatch;
    }
}

fn expectTopAtom(result: *TopResult, expected: []const u8) !void {
    const s = result.value.asAtom() orelse {
        std.debug.print("result was not a atom, it was {s}\n", .{revo.baselib.typeof(result.value, &result.vm)});
        return error.TypeMismatch;
    };
    std.testing.expectEqualStrings(expected, result.vm.stringValue(s)) catch {
        std.debug.print("wanted :{s}, got :{s}\n", .{ expected, result.vm.stringValue(s) });
        return error.AtomsDontMatch;
    };
}

fn expectTopString(result: *TopResult, expected: []const u8) !void {
    try std.testing.expect(result.value.isString());
    try std.testing.expectEqualStrings(expected, result.vm.stringValue(result.value.asString().?));
}

fn expectTopTypeValue(result: *TopResult, expected: revo.memory.ValueTag) !void {
    try std.testing.expect(result.value.tag() == expected);
}

pub fn topNumber(source: []const u8, expected: f64) !void {
    var result = try topResult(source, null);
    defer result.deinit();
    try expectTopNumber(&result, expected);
}

pub fn topNumberInDir(import_dir: []const u8, source: []const u8, expected: f64) !void {
    var result = try topResult(source, import_dir);
    defer result.deinit();
    try expectTopNumber(&result, expected);
}

pub fn topAtom(source: []const u8, expected: []const u8) !void {
    var result = try topResult(source, null);
    defer result.deinit();
    try expectTopAtom(&result, expected);
}

pub fn topString(source: []const u8, expected: []const u8) !void {
    var result = try topResult(source, null);
    defer result.deinit();
    try expectTopString(&result, expected);
}

pub fn topStringInDir(import_dir: []const u8, source: []const u8, expected: []const u8) !void {
    var result = try topResult(source, import_dir);
    defer result.deinit();
    try expectTopString(&result, expected);
}

pub fn topType(source: []const u8, expected: revo.memory.ValueTag) !void {
    var result = try topResult(source, null);
    defer result.deinit();
    try expectTopTypeValue(&result, expected);
}

pub fn topNil(source: []const u8) !void {
    var result = try topResult(source, null);
    defer result.deinit();
    try std.testing.expectEqual(revo.Value.new.nil(), result.value);
}

pub fn topTrue(source: []const u8) !void {
    var result = try topResult(source, null);
    defer result.deinit();
    try std.testing.expect(!revo.isFalse(result.value));
}

pub fn topFalse(source: []const u8) !void {
    var result = try topResult(source, null);
    defer result.deinit();
    try std.testing.expect(revo.isFalse(result.value));
}

fn buildOkWithWarnings(source: []const u8, vm: *revo.VM, w: *?diagnostic.Report) !void {
    var stats = revo.lang.compiler.CompileStats{};

    const result = try pipeline.buildWithWarnings(vm, .{ .text = source }, .{
        .install_debug_info = false,
        .annotation_stats = &stats,
    }, w);

    try expectNoAnnotationMisses(stats, source);
    switch (result) {
        .ok => |bytecode| {
            defer alloc.free(bytecode.instructions);
            defer alloc.free(bytecode.spans);
        },
        .err => |lang_err| {
            revo.printBuildError(alloc, .{ .text = source }, lang_err, vm.runtime.supports_color);
            vm.runtime.resetDiagArena();
            return error.ExpectedCompileSuccess;
        },
    }
}

/// shared warning build, wrappers assert on the report
fn warningReport(source: []const u8, vm: *revo.VM, w: *?diagnostic.Report) !diagnostic.Report {
    try buildOkWithWarnings(source, vm, w);

    return w.* orelse return error.ExpectedWarning;
}

pub const TmpMod = struct {
    tmp: std.testing.TmpDir,
    dir: [:0]const u8,

    pub fn init(files: []const struct { path: []const u8, data: []const u8 }) !TmpMod {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        for (files) |f| try tmp.dir.writeFile(io, .{ .sub_path = f.path, .data = f.data });
        const dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
        return .{ .tmp = tmp, .dir = dir };
    }

    pub fn deinit(self: *TmpMod) void {
        alloc.free(self.dir);
        self.tmp.cleanup();
    }
};

pub fn expectWarning(source: []const u8, snippet: []const u8) !void {
    var vm = try revo.VM.init(runtime());
    defer vm.deinit();

    var w: ?diagnostic.Report = null;
    defer if (w) |*wr| wr.deinit();
    const wr = try warningReport(source, &vm, &w);
    const msg = diagnostic.firstWarn(wr) orelse return error.ExpectedWarning;
    try std.testing.expect(std.mem.find(u8, msg, snippet) != null);
}

pub fn expectWarningCode(source: []const u8, code: []const u8) !void {
    var vm = try revo.VM.init(runtime());
    defer vm.deinit();

    var w: ?diagnostic.Report = null;
    defer if (w) |*wr| wr.deinit();
    const wr = try warningReport(source, &vm, &w);
    const got = wr.code orelse return error.ExpectedCode;
    try std.testing.expectEqualStrings(code, got);
}

pub fn expectSuggestion(source: []const u8, snippet: []const u8) !void {
    var vm = try revo.VM.init(runtime());
    defer vm.deinit();

    var w: ?diagnostic.Report = null;
    defer if (w) |*wr| wr.deinit();
    const wr = try warningReport(source, &vm, &w);
    for (wr.parts) |part| {
        if (part == .suggestion and std.mem.find(u8, part.suggestion.replacement, snippet) != null) return;
    }
    return error.ExpectedSuggestion;
}

pub fn expectNoWarning(source: []const u8) !void {
    var vm = try revo.VM.init(runtime());
    defer vm.deinit();

    var w: ?diagnostic.Report = null;
    defer if (w) |*wr| wr.deinit();
    try buildOkWithWarnings(source, &vm, &w);
    try std.testing.expect(w == null);
}

fn buildExpectingFailure(source: []const u8, vm: *revo.VM) !pipeline.Error {
    const result = try pipeline.build(vm, .{ .text = source }, .{
        .install_debug_info = false,
    });
    switch (result) {
        .ok => |bytecode| {
            defer alloc.free(bytecode.instructions);
            defer alloc.free(bytecode.spans);
            return error.ExpectedCompileFailure;
        },
        .err => |failure| return failure,
    }
}

pub fn expectErrorCode(source: []const u8, code: []const u8) !void {
    var vm = try revo.VM.init(runtime());
    defer vm.deinit();

    const err = try buildExpectingFailure(source, &vm);
    defer pipeline.deinitError(err);
    defer vm.runtime.resetDiagArena();
    const got = switch (err) {
        inline else => |f| f.report.code orelse return error.ExpectedCode,
    };
    try std.testing.expectEqualStrings(code, got);
}

pub fn expectCompileError(source: []const u8, expected: pipeline.CompileErrorKind) !void {
    var vm = try revo.VM.init(runtime());
    defer vm.deinit();

    const err = try buildExpectingFailure(source, &vm);
    defer pipeline.deinitError(err);
    defer vm.runtime.resetDiagArena();
    switch (err) {
        .compile => |failure| try std.testing.expectEqual(expected, failure.kind),
        else => return error.ExpectedCompileFailure,
    }
}

/// semantic failures carry their own kind; this asserts the stage.
/// use expectSemanticFailure for line and message precision.
pub fn expectSemanticError(source: []const u8) !void {
    var vm = try revo.VM.init(runtime());
    defer vm.deinit();

    const err = try buildExpectingFailure(source, &vm);
    defer pipeline.deinitError(err);
    defer vm.runtime.resetDiagArena();
    switch (err) {
        .semantic => {},
        else => return error.ExpectedSemanticFailure,
    }
}

pub fn expectCompileErrorInDir(import_dir: []const u8, source: []const u8) !void {
    var vm = try revo.VM.init(runtime());
    defer vm.deinit();
    vm.import_dir = import_dir;

    const source_name = try std.Io.Dir.path.join(alloc, &.{ import_dir, "<source>" });
    defer alloc.free(source_name);

    const result = try pipeline.build(&vm, .{ .name = source_name, .text = source }, .{
        .install_debug_info = false,
    });
    switch (result) {
        .ok => |bytecode| {
            defer alloc.free(bytecode.instructions);
            defer alloc.free(bytecode.spans);
            return error.ExpectedCompileFailure;
        },
        .err => |failure| {
            defer pipeline.deinitError(failure);
            vm.runtime.resetDiagArena();
            switch (failure) {
                .semantic, .compile => {},
                else => return error.ExpectedCompileFailure,
            }
        },
    }
}

/// one table entry per pinned failure: stage + kind + span + message
///   wrappers below keep their names so call sites never change
pub const FailureKind = union(enum) {
    compile: pipeline.CompileErrorKind,
    semantic: void,
    runtime: revo.RunErrorKind,
};

/// shared span + message pins, every stage reports the same pair shape
fn checkFailurePins(report: diagnostic.Report, expected_line: u32, expected_column: u32, expected_message: []const u8) !void {
    const span = diagnostic.primarySpan(report).?;
    const msg = diagnostic.firstError(report).?;
    try std.testing.expectEqual(expected_line, span.span.line);
    try std.testing.expectEqual(expected_column, span.span.column);
    try std.testing.expectEqualStrings(expected_message, msg);
}

pub fn expectFailure(source: []const u8, kind: FailureKind, expected_line: u32, expected_column: u32, expected_message: []const u8) !void {
    var vm = try revo.VM.init(runtime());
    defer vm.deinit();

    switch (kind) {
        .compile => |k| {
            const err = try buildExpectingFailure(source, &vm);
            defer pipeline.deinitError(err);
            defer vm.runtime.resetDiagArena();
            const diag = switch (err) {
                .compile => |d| d,
                else => return error.ExpectedCompileFailure,
            };
            try std.testing.expectEqual(k, diag.kind);
            try checkFailurePins(diag.report, expected_line, expected_column, expected_message);
        },
        .semantic => {
            const err = try buildExpectingFailure(source, &vm);
            defer pipeline.deinitError(err);
            defer vm.runtime.resetDiagArena();
            const diag = switch (err) {
                .semantic => |d| d,
                else => return error.ExpectedSemanticFailure,
            };
            try checkFailurePins(diag.report, expected_line, expected_column, expected_message);
        },
        .runtime => |k| {
            const program = try compileChecked(&vm, source);
            defer alloc.free(program);
            vm.mainFiber().program = program;
            const result = try revo.vm.dispatch.runReport(&vm);
            switch (result) {
                .ok => return error.ExpectedRuntimeFailure,
                .err => |failure| {
                    try std.testing.expectEqual(k, failure.kind);
                    try checkFailurePins(failure.report, expected_line, expected_column, expected_message);
                },
            }
        },
    }
}

pub fn expectCompileFailure(
    source: []const u8,
    expected_kind: pipeline.CompileErrorKind,
    expected_line: u32,
    expected_column: u32,
    expected_message: []const u8,
) !void {
    return expectFailure(source, .{ .compile = expected_kind }, expected_line, expected_column, expected_message);
}

pub fn expectSemanticFailure(
    source: []const u8,
    expected_line: u32,
    expected_column: u32,
    expected_message: []const u8,
) !void {
    return expectFailure(source, .semantic, expected_line, expected_column, expected_message);
}

pub fn expectRuntimeError(source: []const u8, expected: revo.RunErrorKind) !void {
    var vm = try revo.VM.init(runtime());
    defer vm.deinit();

    const program = try compileChecked(&vm, source);
    defer alloc.free(program);

    vm.mainFiber().program = program;
    const result = try revo.vm.dispatch.runReport(&vm);
    switch (result) {
        .ok => return error.ExpectedRuntimeFailure,
        .err => |failure| try std.testing.expectEqual(expected, failure.kind),
    }
}

pub fn expectRuntimeErrorInDir(import_dir: []const u8, source: []const u8, expected: revo.RunErrorKind) !void {
    var vm = try revo.VM.init(runtime());
    defer vm.deinit();
    vm.import_dir = import_dir;

    const source_name = try std.Io.Dir.path.join(alloc, &.{ import_dir, "<source>" });
    defer alloc.free(source_name);

    const result = try revo.run.runModule(&vm, source_name, source, false);
    switch (result) {
        .ok => return error.ExpectedRuntimeFailure,
        .err => |failure| try std.testing.expectEqual(expected, failure.kind),
    }
}

pub fn expectRuntimeFailure(
    source: []const u8,
    expected_kind: revo.RunErrorKind,
    expected_line: u32,
    expected_column: u32,
    expected_message: []const u8,
) !void {
    return expectFailure(source, .{ .runtime = expected_kind }, expected_line, expected_column, expected_message);
}

pub fn expectRuntimeFailureWithMessage(
    source: []const u8,
    expected_kind: revo.RunErrorKind,
    expected_message: []const u8,
) !void {
    var vm = try revo.VM.init(runtime());
    defer vm.deinit();

    const program = try compileChecked(&vm, source);
    defer alloc.free(program);

    vm.mainFiber().program = program;
    const result = try revo.vm.dispatch.runReport(&vm);
    switch (result) {
        .ok => return error.ExpectedRuntimeFailure,
        .err => |failure| {
            try std.testing.expectEqual(expected_kind, failure.kind);
            try std.testing.expectEqualStrings(
                expected_message,
                diagnostic.firstError(failure.report).?,
            );
        },
    }
}
