const std = @import("std");
const alloc = std.testing.allocator;

const revo = @import("revo");
const lang = revo.lang;
const VM = revo.VM;

const t = revo.lang.test_helpers;

const types = lang.compiler.types;

test "type alias gets unaliased" {
    try t.topTrue(
        \\ type Als =
        \\       {:aa, number}
        \\     | {:bb, number}
        \\
        \\ let x: Als = {:aa, 55}
        \\ let y: Als = {:bb, 100.1}
        \\
        \\ x[1] + y[1] == 155.1
    );
}
test "comp block infers number from literal" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let x = comp 42
        \\ x + 1
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_imm = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_imm) saw_add_imm = true;
    }
    try std.testing.expect(saw_add_imm);
}

test "never collapses in if and orelse inference" {
    // `panic` is `never`: a branch that diverges contributes no type
    try std.testing.expectEqual(types.TypeInfo{ .tag = .number }, types.inferIfType(.{ .tag = .never }, .{ .tag = .number }));
    try std.testing.expectEqual(types.TypeInfo{ .tag = .number }, types.inferIfType(.{ .tag = .number }, .{ .tag = .never }));
    try std.testing.expectEqual(types.TypeInfo{ .tag = .never }, types.inferIfType(.{ .tag = .never }, .{ .tag = .never }));
    try std.testing.expectEqual(types.TypeInfo{ .tag = .number }, types.inferOrelseType(.{ .tag = .never }, .{ .tag = .number }));
    try std.testing.expectEqual(types.TypeInfo{ .tag = .number }, types.inferOrelseType(.{ .tag = .number }, .{ .tag = .never }));
    // unknown left stays unknown: the value may be anything or diverge
    try std.testing.expectEqual(types.TypeInfo{ .tag = .any }, types.inferOrelseType(.{ .tag = .any }, .{ .tag = .never }));
}

test "never arms don't poison match result type" {
    // the panic arm is `never`: the match result is the `:ok` payload (number),
    // so `?` on it is rejected as a non-result (it would pass as `.any`)
    try t.expectSemanticError(
        \\ type Res = {:ok, number} | {:err, string}
        \\ let x: Res = {:ok, 42}
        \\ let r = match x
        \\ | {:ok, v} => v
        \\ | {:err, e} => panic(e)
        \\ r?
    );
}

test "match narrowing works for call subjects" {
    // the subject is a call, not an ident: `v` still narrows to the payload
    // type (from the fn's declared return) and `v + 1` emits add_imm
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ type Res = {:ok, number} | {:err, string}
        \\ fn g() -> Res do {:ok, 42} end
        \\ match g()
        \\ | {:ok, v} => v + 1
        \\ | {:err, _} => 0
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_imm = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_imm) saw_add_imm = true;
    }
    try std.testing.expect(saw_add_imm);
}

test "match narrowing enables specialized add_imm from table union payload" {
    // `v` narrows to number so `v + 1` emits add_imm
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ type Res = {:ok, number} | {:err, string}
        \\ let x: Res = {:ok, 42}
        \\ match x
        \\ | {:ok, v} => v + 1
        \\ | {:err, _} => 0
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_imm = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_imm) saw_add_imm = true;
    }
    try std.testing.expect(saw_add_imm);
}

test "match ascriptions narrow to the annotated type" {
    // `v: number` narrows even with an `any` subject
    //   ; so `v + 1` emits add_imm
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let x: any = {41}
        \\ match x
        \\ | {v: number} => v + 1
        \\ | _ => 0
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_imm = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_imm) saw_add_imm = true;
    }
    try std.testing.expect(saw_add_imm);
}
