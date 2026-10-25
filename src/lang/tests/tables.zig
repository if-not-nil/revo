const std = @import("std");
const alloc = std.testing.allocator;

const revo = @import("revo");
const lang = revo.lang;
const VM = revo.VM;

const t = revo.lang.test_helpers;

test "builtin table methods prebind through baselib tables" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ const t = {1, 2, 3}
        \\ t:len()
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_baselib_load = false;
    var saw_call_field = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .load_builtin_global) saw_baselib_load = true;
        if (inst.op == .call_field) saw_call_field = true;
    }

    try std.testing.expect(saw_baselib_load);
    try std.testing.expect(!saw_call_field);
}

//
// table method shadowing
//

test "table literal field shadows baselib method" {
    try t.topNumber(
        \\ const t = { len = fn(self) 42 }
        \\ t:len()
    , 42);
}

test "table entries can declare bindings" {
    // keyless binding entries land in the array part, storing their value
    try t.topNumber(
        \\ const t = { let x = let y = fn(v) v * 2 }
        \\ t[0](21)
    , 42);

    // keyed entry whose value declares
    try t.topNumber(
        \\ const t = { k = let q = 7 }
        \\ t.k
    , 7);

    // declaring entries must not desync the table as a call argument
    try t.topNumber(
        \\ const f = fn(t) t[0](9) + t[5] + t[1]
        \\ f({
        \\   let a = let b = fn(v) v + 1,
        \\   [5] = do/b break/b 10 end,
        \\   (fn() 20)(),
        \\ })
    , 40);

    // named fn entries keep storing under their name
    try t.topNumber(
        \\ const t = { fn f() 42 }
        \\ t.f()
    , 42);
}

test "dynamic field assignment shadows baselib method" {
    try t.topNumber(
        \\ const t = {}
        \\ t.len = fn(self) 42
        \\ t:len()
    , 42);
}

test "atom-key index assignment shadows baselib method" {
    try t.topNumber(
        \\ const t = {}
        \\ t[:len] = fn(self) 42
        \\ t:len()
    , 42);
}

test "plain table uses baselib method" {
    try t.topNumber(
        \\ const t = {1, 2, 3}
        \\ t:len()
    , 3);
}

//
// merge-method pinning: colon calls resolve through the type's module table
//

test "colon calls resolve string members with self prepended" {
    try t.topNumber("\"abc\":len()", 3);
    try t.topString(
        \\ "abc":upper()
    , "ABC");
}

test "colon calls resolve number members" {
    try t.topNumber("(5):floor()", 5);
}

test "colon calls resolve generic table members" {
    try t.topNumber("{1, 2}:at(0)", 1);
}

test "colon calls enforce arity at compile time" {
    try t.expectSemanticError("\"abc\":split()");
    try t.expectSemanticError("\"abc\":len(\"x\")");
}

test "colon calls enforce arg types at compile time" {
    try t.expectSemanticError("\"abc\":split(42)");
}

test "string-key index does not shadow baselib method" {
    try t.topNumber(
        \\ const t = {1, 2, 3}
        \\ t["len"] = fn(self) 42
        \\ t:len()
    , 4);
}

test "computed key does not invalidate table field tracking" {
    try t.topNumber(
        \\ const t = { len = fn(self) 42 }
        \\ const key = "foo"
        \\ t[key] = 7
        \\ t:len()
    , 42);
}

//
// known limitation: hint widening is per-variable, not per-table
// when two variables share the same underlying table, only the variable
// that received the direct assignment has its hint widened
//

test "shared alias mutation shadows baselib method" {
    // known limitation: hint widening is per-variable, not per-table
    // x gets tracking for len but t doesnt, so t:len() binds to baselib
    return error.SkipZigTest;
}

test "recursive typed calls stay specialized" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn fib(n: number) -> number
        \\   if n < 2 n
        \\   else fib(n - 1) + fib(n - 2)
        \\ print(fib(5))
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_lt = false;
    var saw_sub = false;
    var saw_add = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .lt or inst.op == .lt_int or inst.op == .lt_int_imm) saw_lt = true;
        if (inst.op == .sub or inst.op == .sub_imm) saw_sub = true;
        if (inst.op == .add or inst.op == .add_imm) saw_add = true;
    }

    try std.testing.expect(saw_lt);
    try std.testing.expect(saw_sub);
    try std.testing.expect(saw_add);
}

//
// basic
//
