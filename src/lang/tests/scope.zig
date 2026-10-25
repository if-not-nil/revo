const std = @import("std");

const revo = @import("revo");
const lang = revo.lang;
const VM = revo.VM;

const t = revo.lang.test_helpers;

test "global destructure binds ascribed items" {
    try t.topNumber(
        \\ global {a, b: number} = {1, 2}
        \\ a + b
    , 3);
    try t.topNumber(
        \\ global {{x: number}, y} = {{1}, 2}
        \\ x + y
    , 3);
}

//
// assignment & binding
//
test "local binding shadows outer binding" {
    try t.topNumber(
        \\ let x = 10
        \\ const f = fn() do
        \\     let x = 20
        \\     x
        \\ end
        \\ f()
    , 20);
    try t.expectWarningCode(
        \\ let x = 10
        \\ const f = fn() do
        \\     let x = 20
        \\     x
        \\ end
        \\ f()
    , "shadowed-binding");
}

test "redeclaration in one scope warns" {
    // newest still wins at runtime
    try t.topNumber(
        \\ let x = 1
        \\ let x = 2
        \\ x
    , 2);

    try t.expectWarningCode(
        \\ let x = 1
        \\ let x = 2
        \\ x
    , "duplicate-declaration");
}

test "shadow warnings" {
    // a binding landing on a param it hides
    try t.expectWarningCode(
        \\ const f = fn(x) do
        \\   let x = 5
        \\   x
        \\ end
        \\
        \\ f(1)
    , "shadowed-binding");

    // shadowing a baselib global is ok
    try t.expectNoWarning(
        \\ const sum = fn(a, b) do
        \\   a + b
        \\ end
        \\ sum(1, 2)
    );

    // reassignment is not redeclaration
    try t.expectNoWarning(
        \\ let x = 1
        \\ x = 2
        \\ x
    );
}

test "assignment resolves to nearest binding" {
    try t.topNumber(
        \\ let x = 10
        \\ const f = fn() do
        \\     let x = 20
        \\     x = 30
        \\     x
        \\ end
        \\ f()
    , 30);
}

test "assignment to undefined name is rejected" {
    try t.expectCompileFailure(
        \\ const f = fn() do
        \\     y = 42
        \\     y
        \\ end
        \\ f()
    , .InvalidAssignmentTarget, 2, 6, "assignment target `y` is not declared");
}
test "table binding mismatch reports item counts" {
    try t.expectCompileFailure(
        \\ const {a, b} = {1}
    ,
        .ParseError,
        1,
        17,
        "table binding expects 2 items, got 1",
    );
    try t.expectCompileFailure(
        \\ const {a, b} = {1, 2, 3}
    ,
        .ParseError,
        1,
        17,
        "table binding expects 2 items, got 3",
    );
}

test "table let binding initializes locals" {
    try t.topNumber(
        \\ let {a, b} = {1, 2}
        \\ a + b
    , 3);
    try t.topNumber(
        \\ const {x, y} = {10, 20}
        \\ x + y
    , 30);
    try t.topNumber(
        \\ let {_, b} = {1, 2}
        \\ b
    , 2);
    try t.topNumber(
        \\ let {{x}, y} = {{5}, 6}
        \\ x + y
    , 11);
    try t.topNumber(
        \\ let {a, b} = {1, 2, x = 9}
        \\ a + b
    , 3);
}

test "table let binding with ascriptions binds inner" {
    try t.topNumber(
        \\ let {a: number} = {41}
        \\ a + 1
    , 42);
    try t.topNumber(
        \\ let {{x: number}, y} = {{5}, 6}
        \\ x + y
    , 11);
}

test "table binding ascription mismatch is a compile error" {
    try t.expectSemanticFailure(
        \\ let {x: number, y} = {:ok, 2}
    ,
        1,
        7,
        "`x` wants number, got :ok",
    );
    try t.expectSemanticFailure(
        \\ let {x, y: string} = {:ok, 2}
    ,
        1,
        10,
        "`y` wants string, got number",
    );
    try t.expectSemanticFailure(
        \\ let {{x: number}, y} = {{:ok}, 2}
    ,
        1,
        8,
        "`x` wants number, got :ok",
    );
}

test "keyed tables do not destructure" {
    try t.expectCompileFailure(
        \\ let {a = 1} = {1}
    ,
        .UnsupportedSyntax,
        1,
        6,
        "keyed tables do not destructure yet :( use keyless `{a, b}`",
    );
}

test "number alias works in range bounds" {
    try t.topNumber(
        \\ fn f(count: number) do
        \\     let out = 0
        \\     for i in 0..count do
        \\         out = out + 1
        \\     end
        \\     out
        \\ end
        \\ f(50)
    , 50);
}

test "typed binding label names the expected type" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const result = try lang.build(&vm, .{
        .text =
        \\ const x: number = "nope"
        ,
    }, .{ .install_debug_info = false });

    switch (result) {
        .ok => return error.ExpectedCompileFailure,
        .err => |failure| switch (failure) {
            .compile => |diag| {
                const primary = lang.diagnostic.primarySpan(diag.report).?;
                try std.testing.expectEqualStrings("wants number, got string", primary.message);
                try std.testing.expectEqualStrings(
                    "`x` wants number, got string",
                    lang.diagnostic.firstError(diag.report).?,
                );
                vm.runtime.resetDiagArena();
            },
            .semantic => |diag| {
                const primary = lang.diagnostic.primarySpan(diag.report).?;
                try std.testing.expectEqualStrings("wants number, got string", primary.message);
                try std.testing.expectEqualStrings(
                    "`x` wants number, got string",
                    lang.diagnostic.firstError(diag.report).?,
                );
                vm.runtime.resetDiagArena();
            },
            else => return error.ExpectedCompileFailure,
        },
    }
}

test "compiler reports multiple semantic errors in one pass" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const result = try lang.build(&vm, .{
        .text =
        \\ const a: string = 1
        \\ const b: string = 2
        ,
    }, .{
        .install_debug_info = false,
    });

    switch (result) {
        .ok => return error.ExpectedCompileFailure,
        .err => |failure| switch (failure) {
            .compile => |diag| {
                var error_count: usize = 0;
                for (diag.report.parts) |part| {
                    if (part == .@"error") error_count += 1;
                }
                try std.testing.expect(error_count >= 2);
                vm.runtime.resetDiagArena();
            },
            .semantic => |diag| {
                var error_count: usize = 0;
                for (diag.report.parts) |part| {
                    if (part == .@"error") error_count += 1;
                }
                try std.testing.expect(error_count >= 2);
                vm.runtime.resetDiagArena();
            },
            else => return error.ExpectedCompileFailure,
        },
    }
}

test "typed call reports multiple bad arguments" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const result = try lang.build(&vm, .{
        .text =
        \\ const f = fn(a: number, b: string) a
        \\ f("nope", 2)
        ,
    }, .{
        .install_debug_info = false,
    });

    switch (result) {
        .ok => return error.ExpectedCompileFailure,
        .err => |failure| switch (failure) {
            .compile => |diag| {
                var error_count: usize = 0;
                for (diag.report.parts) |part| {
                    if (part == .@"error") error_count += 1;
                }
                try std.testing.expect(error_count >= 2);
                vm.runtime.resetDiagArena();
            },
            .semantic => |diag| {
                var error_count: usize = 0;
                for (diag.report.parts) |part| {
                    if (part == .@"error") error_count += 1;
                }
                try std.testing.expect(error_count >= 2);
                vm.runtime.resetDiagArena();
            },
            else => return error.ExpectedCompileFailure,
        },
    }
}

test "named call reports multiple bad parameters" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const result = try lang.build(&vm, .{
        .text =
        \\ const f = fn(a: number, b: number) a + b
        \\ f(x = 1, y = 2)
        ,
    }, .{
        .install_debug_info = false,
    });

    switch (result) {
        .ok => return error.ExpectedCompileFailure,
        .err => |failure| switch (failure) {
            .compile => |failed| {
                var error_count: usize = 0;
                for (failed.report.parts) |part| {
                    if (part == .@"error") error_count += 1;
                }
                try std.testing.expect(error_count >= 2);
                vm.runtime.resetDiagArena();
            },
            else => return error.ExpectedCompileFailure,
        },
    }
}
