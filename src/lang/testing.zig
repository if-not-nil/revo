const std = @import("std");
const alloc = std.testing.allocator;
const io = std.testing.io;

const lang = @import("./root.zig");
const revo = @import("revo");

pub fn runtime() revo.Runtime {
    return .{
        .alloc = alloc,
        .io = io,
        .diag_alloc = undefined,
        .diag_arena = null,
    };
}

pub fn expectPrinted(source: []const u8, expected: []const u8) !void {
    try lang.parser.testing.expectPrinted(source, expected);
}

pub fn expectTypes(source: []const u8, expected: []const lang.TokenType) !void {
    try lang.Lexer.testing.expectTypes(source, expected);
}

pub fn expectTokens(source: []const u8, expected: []const lang.Lexer.testing.ExpectedToken) !void {
    try lang.Lexer.testing.expectTokens(source, expected);
}

const TopResult = struct {
    vm: revo.VM,
    value: revo.Data,

    pub fn deinit(self: *TopResult) void {
        self.vm.deinit();
    }
};

fn compileChecked(vm: *revo.VM, source: []const u8) ![]revo.Instruction {
    const result = try lang.build(vm, .{ .text = source }, .{
        .install_debug_info = true,
    });
    return switch (result) {
        .ok => |artifact| blk: {
            alloc.free(artifact.spans);
            break :blk artifact.instructions;
        },
        .err => |lang_err| {
            printLangError(source, lang_err);
            vm.runtime.resetDiagArena();
            return error.LangFailure;
        },
    };
}

fn compileCheckedMode(vm: *revo.VM, source: []const u8, test_mode: bool) ![]revo.Instruction {
    const result = try lang.build(vm, .{ .text = source }, .{
        .install_debug_info = true,
        .test_mode = test_mode,
    });
    return switch (result) {
        .ok => |artifact| blk: {
            alloc.free(artifact.spans);
            break :blk artifact.instructions;
        },
        .err => |lang_err| {
            printLangError(source, lang_err);
            vm.runtime.resetDiagArena();
            return error.LangFailure;
        },
    };
}

fn runTopModuleChecked(vm: *revo.VM, source: []const u8, source_name: []const u8) !void {
    const result = try revo.module.runModuleReport(vm, source_name, source);
    switch (result) {
        .ok => {},
        .err => |failure| {
            printRuntimeFailure(source, failure);
            vm.runtime.resetDiagArena();
            return error.RuntimeFailure;
        },
    }
}

fn printLangError(source: []const u8, failure: lang.Error) void {
    revo.printBuildError(alloc, .{ .text = source }, failure);
}

fn printRuntimeFailure(source: []const u8, failure: revo.EvalFailure) void {
    revo.printEvalError(alloc, source, failure);
}

pub fn topResult(source: []const u8, module_dir: ?[]const u8) !TopResult {
    var vm = try revo.VM.init(runtime());
    errdefer vm.deinit();
    const src_name: []const u8 = if (module_dir) |dir| blk: {
        vm.module_dir = dir;
        const joined = try std.fs.path.join(alloc, &.{ dir, "<source>" });
        break :blk joined;
    } else "<source>";
    defer if (module_dir != null) alloc.free(src_name);
    try runTopModuleChecked(&vm, source, src_name);
    return .{
        .vm = vm,
        .value = vm.mainResult(),
    };
}

// TODO: clean this up
pub fn topResultMode(source: []const u8, module_dir: ?[]const u8, test_mode: bool) !TopResult {
    var vm = try revo.VM.init(runtime());
    errdefer vm.deinit();
    const src_name: []const u8 = if (module_dir) |dir| blk: {
        vm.module_dir = dir;
        const joined = try std.fs.path.join(alloc, &.{ dir, "<source>" });
        break :blk joined;
    } else "<source>";
    defer if (module_dir != null) alloc.free(src_name);

    const program = try compileCheckedMode(&vm, source, test_mode);
    defer alloc.free(program);
    const result = try revo.module.runCompiledModuleReport(&vm, src_name, program);
    switch (result) {
        .ok => {},
        .err => return error.RuntimeFailure,
    }

    return .{
        .vm = vm,
        .value = vm.mainResult(),
    };
}

fn expectTopNumber(result: *TopResult, expected: f64) !void {
    const actual = result.value.as_number() catch {
        std.debug.print("result was not a number, it was {s}\n", .{revo.std_lib.typeof(result.value)});
        return error.TypeMismatch;
    };
    if (@abs(expected - actual) > 0.000000001) {
        std.debug.print("wanted {}, got {}\n", .{ expected, actual });
        return error.NumbersDontMatch;
    }
}

fn expectTopAtom(result: *TopResult, expected: []const u8) !void {
    const s = result.value.asAtom() orelse {
        std.debug.print("result was not a atom, it was {s}\n", .{revo.std_lib.typeof(result.value)});
        return error.TypeMismatch;
    };
    std.testing.expectEqualStrings(expected, result.vm.atomName(s)) catch {
        std.debug.print("wanted :{s}, got :{s}\n", .{ expected, result.vm.atomName(s) });
        return error.AtomsDontMatch;
    };
}

fn expectTopString(result: *TopResult, expected: []const u8) !void {
    try std.testing.expect(result.value.isString());
    try std.testing.expectEqualStrings(expected, result.vm.stringValue(result.value.asString().?));
}

fn expectTopTypeValue(result: *TopResult, expected: revo.memory.Type) !void {
    try std.testing.expect(result.value.tag() == expected);
}

pub fn top_number(source: []const u8, expected: f64) !void {
    var result = try topResult(source, null);
    defer result.deinit();
    try expectTopNumber(&result, expected);
}

pub fn top_number_in_dir(module_dir: []const u8, source: []const u8, expected: f64) !void {
    var result = try topResult(source, module_dir);
    defer result.deinit();
    try expectTopNumber(&result, expected);
}

pub fn top_atom(source: []const u8, expected: []const u8) !void {
    var result = try topResult(source, null);
    defer result.deinit();
    try expectTopAtom(&result, expected);
}

pub fn top_string(source: []const u8, expected: []const u8) !void {
    var result = try topResult(source, null);
    defer result.deinit();
    try expectTopString(&result, expected);
}

pub fn top_string_in_dir(module_dir: []const u8, source: []const u8, expected: []const u8) !void {
    var result = try topResult(source, module_dir);
    defer result.deinit();
    try expectTopString(&result, expected);
}

pub fn top_type(source: []const u8, expected: revo.memory.Type) !void {
    var result = try topResult(source, null);
    defer result.deinit();
    try expectTopTypeValue(&result, expected);
}

pub fn top_nil(source: []const u8) !void {
    var result = try topResult(source, null);
    defer result.deinit();
    try std.testing.expectEqual(revo.Data.new.nil(), result.value);
}

pub fn top_true(source: []const u8) !void {
    var result = try topResult(source, null);
    defer result.deinit();
    try std.testing.expect(!revo.isFalse(result.value));
}

pub fn top_false(source: []const u8) !void {
    var result = try topResult(source, null);
    defer result.deinit();
    try std.testing.expect(revo.isFalse(result.value));
}

pub fn expectCompileError(source: []const u8, expected: lang.LowerErrorKind) !void {
    var vm = try revo.VM.init(runtime());
    defer vm.deinit();

    const result = try lang.build(&vm, .{ .text = source }, .{
        .install_debug_info = false,
    });
    switch (result) {
        .ok => |artifact| {
            defer alloc.free(artifact.instructions);
            defer alloc.free(artifact.spans);
            return error.ExpectedCompileFailure;
        },
        .err => |failure| switch (failure) {
            .lower => |lower| {
                try std.testing.expectEqual(expected, lower.kind);
                vm.runtime.resetDiagArena();
            },
            .expand => return error.ExpectedLowerFailure,
            .parse => return error.ExpectedLowerFailure,
            .semantic => {
                vm.runtime.resetDiagArena();
            },
        },
    }
}

pub fn expectCompileErrorInDir(module_dir: []const u8, source: []const u8) !void {
    var vm = try revo.VM.init(runtime());
    defer vm.deinit();
    vm.module_dir = module_dir;

    const source_name = try std.fs.path.join(alloc, &.{ module_dir, "<source>" });
    defer alloc.free(source_name);

    const result = try lang.build(&vm, .{ .name = source_name, .text = source }, .{
        .install_debug_info = false,
    });
    switch (result) {
        .ok => |artifact| {
            defer alloc.free(artifact.instructions);
            defer alloc.free(artifact.spans);
            return error.ExpectedCompileFailure;
        },
        .err => |failure| switch (failure) {
            .semantic, .lower => {
                vm.runtime.resetDiagArena();
            },
            .expand, .parse => {
                vm.runtime.resetDiagArena();
                return error.ExpectedCompileFailure;
            },
        },
    }
}

pub fn expectCompileFailure(
    source: []const u8,
    expected_kind: lang.LowerErrorKind,
    expected_line: u32,
    expected_column: u32,
    expected_message: []const u8,
) !void {
    var vm = try revo.VM.init(runtime());
    defer vm.deinit();

    const result = try lang.build(&vm, .{ .text = source }, .{
        .install_debug_info = false,
    });
    switch (result) {
        .ok => |artifact| {
            defer alloc.free(artifact.instructions);
            defer alloc.free(artifact.spans);
            return error.ExpectedCompileFailure;
        },
        .err => |failure| switch (failure) {
            .parse => return error.ExpectedLowerFailure,
            .expand => return error.ExpectedLowerFailure,
            .lower, .semantic => |diag| {
                try std.testing.expectEqual(expected_kind, diag.kind);
                const span = lang.diagnostic.primarySpan(diag.report).?;
                const msg = lang.diagnostic.firstError(diag.report).?;
                try std.testing.expectEqual(expected_line, span.span.line);
                try std.testing.expectEqual(expected_column, span.span.column);
                try std.testing.expectEqualStrings(expected_message, msg);
                vm.runtime.resetDiagArena();
            },
        },
    }
}

pub fn expectRuntimeError(source: []const u8, expected: revo.EvalErrorKind) !void {
    var vm = try revo.VM.init(runtime());
    defer vm.deinit();

    const program = try compileChecked(&vm, source);
    defer alloc.free(program);

    vm.mainFiber().program = program;
    const result = try vm.runReport();
    switch (result) {
        .ok => return error.ExpectedRuntimeFailure,
        .err => |failure| try std.testing.expectEqual(expected, failure.kind),
    }
}

pub fn expectRuntimeErrorInDir(module_dir: []const u8, source: []const u8, expected: revo.EvalErrorKind) !void {
    var vm = try revo.VM.init(runtime());
    defer vm.deinit();
    vm.module_dir = module_dir;

    const source_name = try std.fs.path.join(alloc, &.{ module_dir, "<source>" });
    defer alloc.free(source_name);

    const result = try revo.module.runModuleReport(&vm, source_name, source);
    switch (result) {
        .ok => return error.ExpectedRuntimeFailure,
        .err => |failure| try std.testing.expectEqual(expected, failure.kind),
    }
}

pub fn expectRuntimeFailure(
    source: []const u8,
    expected_kind: revo.EvalErrorKind,
    expected_line: u32,
    expected_column: u32,
    expected_message: []const u8,
) !void {
    var vm = try revo.VM.init(runtime());
    defer vm.deinit();

    const program = try compileChecked(&vm, source);
    defer alloc.free(program);

    vm.mainFiber().program = program;
    const result = try vm.runReport();
    switch (result) {
        .ok => return error.ExpectedRuntimeFailure,
        .err => |failure| {
            try std.testing.expectEqual(expected_kind, failure.kind);
            const span = lang.diagnostic.primarySpan(failure.report).?;
            const msg = lang.diagnostic.firstError(failure.report).?;
            try std.testing.expectEqual(expected_line, span.span.line);
            try std.testing.expectEqual(expected_column, span.span.column);
            try std.testing.expectEqualStrings(expected_message, msg);
        },
    }
}

pub fn expectRuntimeFailureWithMessage(
    source: []const u8,
    expected_kind: revo.EvalErrorKind,
    expected_message: []const u8,
) !void {
    var vm = try revo.VM.init(runtime());
    defer vm.deinit();

    const program = try compileChecked(&vm, source);
    defer alloc.free(program);

    vm.mainFiber().program = program;
    const result = try vm.runReport();
    switch (result) {
        .ok => return error.ExpectedRuntimeFailure,
        .err => |failure| {
            try std.testing.expectEqual(expected_kind, failure.kind);
            try std.testing.expectEqualStrings(
                expected_message,
                lang.diagnostic.firstError(failure.report).?,
            );
        },
    }
}
