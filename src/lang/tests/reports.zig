const std = @import("std");
const alloc = std.testing.allocator;

const revo = @import("revo");
const lang = revo.lang;
const VM = revo.VM;

const t = revo.lang.test_helpers;

test "compile report carries span and message" {
    try t.expectCompileFailure(
        "break(1)",
        .UnsupportedSyntax,
        1,
        1,
        "break is only valid inside loop",
    );
}

test "compile report includes function call argument detail" {
    try t.expectSemanticFailure(
        \\ const id = fn(x: number) x
        \\ id("nope")
    ,
        2,
        5,
        "arg 1 (`x`) to `id` wants number, got string",
    );
}

test "runtime report carries span and message" {
    try t.expectRuntimeFailure(
        "1 / 0",
        .DivisionByZero,
        1,
        1,
        "division by zero!",
    );
}

test "semantic catches undefined variable" {
    try t.expectSemanticError("missing_name");
}

test "semantic catches undefined function call" {
    try t.expectSemanticError("pritn(\"hi\")");
}

test "forward reference to a value is rejected at compile time" {
    try t.expectErrorCode(
        \\ const read = fn() do
        \\     value
        \\ end
        \\ const value = 42
        \\ read()
    , "unknown-name");
}

test "forward sibling fn resolves" {
    try t.topNumber(
        \\ const g = fn() do f() end
        \\ const f = fn() 42
        \\ g()
    , 42);
}

test "runtime report includes not-a-function detail" {
    try t.expectRuntimeFailure(
        "1(2)",
        .NotAFunction,
        1,
        1,
        "cannot call number value",
    );
}

test "method call on missing field reports field name and object" {
    try t.expectRuntimeFailure(
        "1:missing()",
        .NotAFunction,
        1,
        1,
        "field `missing` does not exist on number",
    );
}

test "runtime report includes wrong arity detail" {
    try t.expectSemanticError(
        \\ const id = fn(x) x
        \\ id()
    );
}
test "runtime renderer includes source path" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const source = "1 / 0";
    const built = try lang.build(&vm, .{ .text = source }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    try vm.setProgramSourceName("examples/fail.rv");
    vm.mainFiber().program = built.ok.instructions;

    const result = try revo.vm.dispatch.runReport(&vm);
    switch (result) {
        .ok => return error.ExpectedRuntimeFailure,
        .err => |failure| {
            var buf = std.Io.Writer.Allocating.init(alloc);
            defer buf.deinit();
            try failure.renderAt(
                &buf.writer,
                failure.report.source_name orelse "<source>",
                source,
                false,
            );
            try std.testing.expect(std.mem.find(u8, buf.written(), "examples/fail.rv:1:1") != null);
        },
    }
}

test "runtime renderer includes stack trace call chain" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const source =
        \\ const c = fn() :err 1
        \\ const b = fn() 1 + c()
        \\ const a = fn() 1 + b()
        \\ a()
    ;
    const built = try lang.build(&vm, .{ .text = source }, .{
        .install_debug_info = true,
    });
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    vm.mainFiber().program = built.ok.instructions;

    const result = try revo.vm.dispatch.runReport(&vm);
    switch (result) {
        .ok => return error.ExpectedRuntimeFailure,
        .err => |failure| {
            var buf = std.Io.Writer.Allocating.init(alloc);
            defer buf.deinit();
            try failure.render(&buf.writer, source, false);

            try std.testing.expect(std.mem.find(u8, buf.written(), "stack trace:") != null);
            try std.testing.expect(std.mem.find(u8, buf.written(), "0: b at <source>:2:") != null);
            try std.testing.expect(std.mem.find(u8, buf.written(), "1: a at <source>:4:") != null);
        },
    }
}

test "function return value destructuring" {
    try t.topNumber(
        \\ const vector_mul = fn(a, b, factor)
        \\    {a * factor, b * factor}
        \\
        \\ const {x, y} = vector_mul(4, 6, 2)
        \\ x + y
    , 20);
}
