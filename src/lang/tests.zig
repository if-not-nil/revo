//
// beware, this tests the whole language, start-to-finish
// maybe this should be src/tests.zig instead?
// big TODO: prefix test names with their scope so that i can grep "atom and find all atom tests
//
const std = @import("std");
const alloc = std.testing.allocator;

const revo = @import("revo");
const lang = revo.lang;
const VM = revo.VM;

const t = @import("testing.zig");

test "lang surface exports parse and build pipeline entrypoints" {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const parsed = try lang.parse(arena.allocator(), .{ .text = "sys.print \"hello\"" }, .{});
    try std.testing.expect(parsed == .ok);
    try std.testing.expect(parsed.ok.root.expr == .call);

    var vm = try VM.init(t.runtime());
    defer vm.deinit();
    const built = try lang.build(&vm, .{ .text = "1 + 1" }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);
    try std.testing.expect(built.ok.instructions.len != 0);
}

test "parser treats semicolons as whitespace characters" {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const source =
        \\ const langs = {
        \\   "C", "C++",
        \\   "Java", "C#",
        \\   "Perl", "PHP",
        \\ };
        \\ fn fellow_heart_attacker(lang) do
        \\   "An old {lang} programmer won't have a heart attack " ~
        \\   "over a habitually placed closing semicolon.";
        \\ end
        \\ for lang in langs do
        \\   const statement = fellow_heart_attacker(lang);
        \\   print(statement);
        \\ end
    ;
    const parsed = try lang.parse(arena.allocator(), .{ .text = source }, .{});
    try std.testing.expect(parsed == .ok);
}

test "parser reports multiple syntax errors in one pass" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const source =
        \\ let x = )
        \\ let y = )
    ;
    const built = try lang.build(&vm, .{ .text = source }, .{});
    try std.testing.expect(built == .err);
    switch (built.err) {
        .parse => |failure| {
            var error_count: usize = 0;
            for (failure.report.parts) |part| {
                if (part == .@"error") error_count += 1;
            }
            try std.testing.expect(error_count >= 2);

            var buf = std.Io.Writer.Allocating.init(alloc);
            defer buf.deinit();
            try lang.renderError(alloc, &buf.writer, .{ .text = source }, .{ .parse = failure });
            try std.testing.expect(buf.written().len != 0);
        },
        else => return error.ExpectedCompileFailure,
    }
}

test "builtin table methods prebind through stdlib tables" {
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

    var saw_stdlib_load = false;
    var saw_call_field = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .load_stdlib_global) saw_stdlib_load = true;
        if (inst.op == .call_field) saw_call_field = true;
    }

    try std.testing.expect(saw_stdlib_load);
    try std.testing.expect(!saw_call_field);
}

//
// table method shadowing
//

test "table literal field shadows stdlib method" {
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

test "dynamic field assignment shadows stdlib method" {
    try t.topNumber(
        \\ const t = {}
        \\ t.len = fn(self) 42
        \\ t:len()
    , 42);
}

test "atom-key index assignment shadows stdlib method" {
    try t.topNumber(
        \\ const t = {}
        \\ t[:len] = fn(self) 42
        \\ t:len()
    , 42);
}

test "plain table uses stdlib method" {
    try t.topNumber(
        \\ const t = {1, 2, 3}
        \\ t:len()
    , 3);
}

test "string-key index does not shadow stdlib method" {
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

test "shared alias mutation shadows stdlib method" {
    // known limitation: hint widening is per-variable, not per-table
    // x gets tracking for len but t doesnt, so t:len() binds to stdlib
    return error.SkipZigTest;
}

test "recursive typed calls stay specialized" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn fib(n: int) -> int
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

test {
    _ = @import("expander.zig").testing;
}

//
// basic
//

test "arithmetic" {
    try t.topNumber("1 + 2 * 3", 7);
    try t.topNumber("-1", -1);
    try t.topNumber("1.5 + 2.25", 3.75);
    try t.topNumber("5.5 - 0.5", 5.0);
    try t.topNumber("3.0 * 0.5", 1.5);
    try t.topNumber("5.0 / 2.0", 2.5);
}

test "bitwise and floor division" {
    try t.topNumber("5 // 2", 2);
    try t.topNumber("-5 // 2", -3);
    try t.topNumber("-17 // 5", -4);
    try t.topNumber("17 // 5", 3);
    try t.topNumber("5 // -2", -3);

    // python semantics: `//` floors on floats too, result stays float
    try t.topNumber("5.5 // 2", 2);
    try t.topNumber("-5.5 // 2", -3);
    try t.topNumber("5.0 // 2.5", 2);
    try t.topNumber("-17.5 // 5", -4);
    try t.topNumber("7 // 2.0", 3);
    try t.topNumber("-7.25 // 2", -4);

    try t.topNumber("2 band 3", 2);
    try t.topNumber("2 bor 3", 3);
    try t.topNumber("2 bxor 3", 1);
    try t.topNumber("0 bxor 255", 255);
    try t.topNumber("12 band 10", 8);

    try t.topNumber("1 shl 4", 16);
    try t.topNumber("1 shl 63", -9223372036854775808);
    try t.topNumber("-16 shr 2", -4);
    try t.topNumber("16 shr 2", 4);
    try t.topNumber("255 shr 4", 15);

    // precedence: bitwise binds tighter than addition, looser than multiplication
    try t.topNumber("1 + 2 band 3", 3);
    try t.topNumber("1 + 2 shl 2", 9);
    try t.topNumber("1 shl 2 * 2", 16);

    // constant folding path must agree
    try t.topNumber("let a = 6 let b = 3 a band b", 2);
    try t.topNumber("let a = 6 let b = 3 a shl b", 48);
    try t.topNumber("let a = 9 let b = 2 a // b", 4);
    try t.topNumber("let a = 9.5 let b = 2 a // b", 4);
}

test "exponent" {
    try t.topNumber("2 ^ 3", 8);
    try t.topNumber("2 ^ 0", 1);
    try t.topNumber("0 ^ 0", 1);
    try t.topNumber("2 ^ 10", 1024);
    try t.topNumber("-2 ^ 3", -8);
    try t.topNumber("(-2) ^ 2", 4);

    // right-associative, binds tighter than multiplication and unary minus
    try t.topNumber("2 ^ 3 ^ 2", 512);
    try t.topNumber("2 ^ 3 * 4", 32);
    try t.topNumber("-2 ^ 2", -4);

    // negative exponent gives a float, like python
    try t.topNumber("2 ^ -1", 0.5);
    try t.topNumber("2.0 ^ 3", 8);
    try t.topNumber("2 ^ 0.5", 1.4142135623730951);
    try t.topNumber("2 ^ 63", -9223372036854775808);

    // constant folding path must agree
    try t.topNumber("let a = 3 let b = 2 a ^ b", 9);

    // compound assign
    try t.topNumber("let x = 2 x ^= 3 x", 8);
}

test "exponent errors" {
    try t.expectSemanticError("'a' ^ 2");
    try t.expectRuntimeError("fn f(a, b) do a ^ b end f(2, 'x')", .IncompatibleTypes);
    try t.expectRuntimeError("(-2) ^ 0.5", .IncompatibleTypes);
    try t.expectRuntimeError("fn f(a, b) do a ^ b end f(-2.0, 0.5)", .IncompatibleTypes);
}

test "bitwise and floor division errors" {
    // python semantics: non-integral operands fail at runtime, not compile time
    try t.expectRuntimeError("2 band 3.5", .IncompatibleTypes);
    try t.expectRuntimeError("1 shl 2.5", .IncompatibleTypes);
    try t.expectRuntimeError("2.0 bor 3.5", .IncompatibleTypes);
    try t.expectRuntimeError("1.5 shr 2.0", .IncompatibleTypes);
    try t.expectRuntimeError("2.5 bxor 1", .IncompatibleTypes);

    // dynamic operands that turn out non-integral fail at runtime
    try t.expectRuntimeError("fn f(a, b) do a band b end f(2.5, 1)", .IncompatibleTypes);
    try t.expectRuntimeError("fn f(a, b) do a // b end f('a', 2)", .IncompatibleTypes);

    // shift amount out of range
    try t.expectRuntimeError("fn f(a, b) do a shl b end f(1, 64)", .ShiftAmountOutOfRange);
    try t.expectRuntimeError("fn f(a, b) do a shl b end f(1, -1)", .ShiftAmountOutOfRange);
    try t.expectRuntimeError("fn f(a, b) do a shr b end f(1, 70)", .ShiftAmountOutOfRange);

    // division by zero
    try t.expectRuntimeError("fn f(a, b) do a // b end f(1, 0)", .DivisionByZero);
    try t.expectRuntimeError("fn f(a, b) do a // b end f(5.5, 0)", .DivisionByZero);
}

test "concat operator" {
    // string concat
    try t.topString("'hello' ~ ' world'", "hello world");
    try t.topString("'a' ~ 'b' ~ 'c'", "abc");
    try t.topString("'' ~ 'x'", "x");
    try t.topString("'x' ~ ''", "x");

    // number concat (numbers convert to string)
    try t.topString("1 ~ 2", "12");
    try t.topString("1 ~ ' x'", "1 x");
    try t.topString("'x ' ~ 2", "x 2");
    try t.topString("1.5 ~ 2", "1.52");

    // table with __tostring metamethod
    try t.topString(
        \\const mt = {__tostring = fn(self) "custom"}
        \\const t = set_meta({}, mt)
        \\t ~ ""
    , "custom");
    try t.topString(
        \\const mt = {__tostring = fn(self) "hello"}
        \\const t = set_meta({}, mt)
        \\"x" ~ t
    , "xhello");

    // concat + comparison
    try t.topAtom("'ab' ~ 'c' == 'abc'", "true");
    try t.topAtom("'ab' ~ 'c' != 'abc'", "false");

    // compound assign
    try t.topString(
        \\let s = "a"
        \\s ~= "b"
        \\s
    , "ab");

    // mixed types fall through to display
    try t.topString(":hello ~ ' world'", ":hello world");
}

//
// semantic type checking of stdlib functions
//

test "doc comments annotate functions without changing runtime behavior" {
    try t.topNumber(
        \\ #* adds numbers *#
        \\ fn add(a, b) a + b
        \\ add(20, 22)
    , 42);
}

test "return statement" {
    try t.topNumber(
        \\ do return 7 8 end
    , 7);
    try t.topAtom(
        \\ fn f() do return :ok end
        \\ f()
    , "ok");
    try t.topNumber(
        \\ fn f() do return 42 end
        \\ f()
    , 42);
}

test "fiber syntax spawn join yield" {
    try t.topNumber(
        \\ const add = fn(a, b) a + b
        \\ const h = spawn add(39, 3)
        \\ join h
    , 42);

    try t.topType(
        \\ do
        \\   yield
        \\ end
    , .atom);
}

test "channels coordinate spawned workers" {
    try t.topNumber(
        \\ const ch = chan(0)
        \\ const worker = fn(v) do
        \\   send(ch, v)
        \\   0
        \\ end
        \\ const a = spawn worker(20)
        \\ const b = spawn worker(22)
        \\ const x = recv(ch)
        \\ const y = recv(ch)
        \\ join a
        \\ join b
        \\ x + y
    , 42);
}

test "sleep join values are preserved per handle" {
    try t.topNumber(
        \\ const f = fn(v) do
        \\   sleep(10)
        \\   v
        \\ end
        \\ const a = spawn f(20)
        \\ const b = spawn f(22)
        \\ const c = spawn f(30)
        \\ join(a) + join(b) + join(c)
    , 72);
    try t.topNumber(
        \\ const f = fn(v) do
        \\   sleep(10)
        \\   v
        \\ end
        \\ const a = spawn f(20)
        \\ const b = spawn f(22)
        \\ const c = spawn f(30)
        \\ const x = join(a)
        \\ const y = join(b)
        \\ const z = join(c)
        \\ x
    , 20);
}

test "spawn and join nest inside iterator maps" {
    try t.topNumber(
        \\ const pmap = fn(collection, func)
        \\   (collection |> to_iter)
        \\   :map(fn(x) spawn fn() func(x))
        \\   :map(fn(x) join x):collect()
        \\ const r = pmap({10, 20, 30}, fn(x) x * 2)
        \\ r[0] + r[1] + r[2]
    , 120);
}

test "spawn snapshots loop iteration values" {
    try t.topNumber(
        \\ let hs = {}
        \\ for i in 0..5 do hs:push(spawn fn() i) end
        \\ const r = (hs |> to_iter):map(fn(h) join h):collect()
        \\ r[0] + r[1] + r[2] + r[3] + r[4]
    , 10);
}

test "compiles unary operators and atom equality" {
    try t.topAtom("not :false", "true");
    try t.topAtom("not :true", "false");
    try t.topAtom("1 + 1 == 2", "true");
    try t.topNumber("len(\"abcd\")", 4);
    try t.topNumber("-5 + 7", 2);
}

test "hash starts comments only" {
    try t.expectTypes(
        \\do
        \\    # whole line comment
        \\    let x = ## block comment ## 1
        \\end
    , &.{
        .kw_do,
        .comment,
        .kw_let,
        .ident,
        .assign,
        .comment,
        .number,
        .kw_end,
        .eof,
    });
}

test "compiles bindings assignment and block result" {
    try t.topNumber(
        \\do
        \\    let a = 1
        \\    let b = 2
        \\    a + b
        \\end
    , 3);
}

test "bind, declaration and assignment are expressions and return rhs" {
    try t.topNumber(
        \\ const a = const b = 5
    , 5);
    try t.topNumber(
        \\ let a = let b = 5
    , 5);
    try t.topNumber(
        \\ const a = let b = 5
    , 5);
    try t.topNumber(
        \\ let a = 5
        \\ let b = (a = 42)
    , 42);
}

test "atoms do not collide with other values" {
    try t.topType(
        \\:do
    , .atom);
}

test "the program is in a top-level block" {
    try t.topNumber(
        \\ do const t = -41 (0 - t) + 1 end
    , 42);
}

test "blocks keep only last expression value" {
    try t.topNumber(
        \\ do
        \\   1
        \\   2
        \\   3
        \\ end
    , 3);
}

test "if uses atom false verity" {
    try t.topNumber(
        \\do
        \\    const t = {answer = 41}
        \\    if :false t.answer else t.answer + 1
        \\end
    , 42);
}

test "top verity uses atom booleans" {
    try t.topTrue(":true");
    try t.topFalse(":false");
    try t.topTrue(":ok");
}

test "top verity follows false values" {
    try t.topTrue("1");
    try t.topFalse("0");
    try t.topFalse(":nil");
    try t.topTrue("\"\"");
}

test "and/or preserve value semantics" {
    try t.topTrue("1 and 2");
    try t.topTrue("0 or 9");
    try t.topTrue("(:t or :true or not :nil or 1 or 1.0 or 67) == :t");
}

test "chained or conditions in if parse and run" {
    try t.topNumber(
        \\ const nextword = "."
        \\ if nextword == "." or nextword == "," or nextword == "!" or nextword == "?" do
        \\     1
        \\ end else do
        \\     0
        \\ end
    , 1);
}

test "assignment & op combinations" {
    try t.topNumber("let t = 41 t += 1 t", 42);
    try t.topNumber("let t = 43 t -= 1 t", 42);
    try t.topNumber("let t = 84 t /= 2 t", 42);
    try t.topNumber("let t = 21 t *= 2 t", 42);
}

test "compound assign evaluates object and key once" {
    try t.topNumber(
        \\ let n = 0
        \\ fn key() do n += 1 0 end
        \\ let t = {100}
        \\ t[key()] += 5
        \\ t[0] + n
    , 106);
    try t.topNumber(
        \\ let n = 0
        \\ let t = {v = 10}
        \\ fn obj() do n += 1 t end
        \\ obj().v += 5
        \\ t.v + n
    , 16);
}

test "comparisons" {
    try t.topFalse("1 == 2");
    try t.topTrue("assert(1 < 2)");
    try t.topTrue("assert(\"a\" < \"b\")");
}

test "hash literals are real atoms" {
    try t.topAtom(":good", "good");
}

test "field assignment works" {
    try t.topTrue(
        \\ const sys = {answer = 41}
        \\ sys.answer = 1
        \\ sys.answer
    );
    try t.topTrue(
        \\ const sys = {a = {b = 1}}
        \\ sys.a.b = 2
        \\ sys.a.b == 2
    );
    try t.topNumber(
        \\ const sys = {a = 1}
        \\ sys.a = sys.a + 1
        \\ sys.a
    , 2);
}

test "string conversion metamethods __tostring" {
    try t.topString(
        \\ const mt = {__tostring = fn(self) "custom"}
        \\ const t = set_meta({a = 1}, mt)
        \\ string(t)
    , "custom");
    try t.topString(
        \\ const mt = {__tostring = fn(self) "42"}
        \\ const t = set_meta({}, mt)
        \\ string(t)
    , "42");
}

test "display formatting uses __display and falls back to __tostring" {
    try t.topString(
        \\ const mt = {__display = fn(self) "visible", __tostring = fn(self) "hidden"}
        \\ const t = set_meta({}, mt)
        \\ fmt("%v", t)
    , "visible");

    try t.topString(
        \\ const mt = {__tostring = fn(self) "fallback"}
        \\ const t = set_meta({}, mt)
        \\ fmt("%v", t)
    , "fallback");
}

test "string interpolation uses formatting modes" {
    try t.topString(
        \\ const mt = {__display = fn(self) "visible", __debug = fn(self) "debug"}
        \\ const value = set_meta({}, mt)
        \\ "value = #{value}"
    , "value = visible");
    try t.topString(
        \\ const mt = {__display = fn(self) "visible", __debug = fn(self) "debug"}
        \\ const value = set_meta({}, mt)
        \\ "value = #{value:?}"
    , "value = \"debug\"");
    try t.topString(
        \\ "100% complete: #{42:p}"
    , "100% complete: \x1b[33m42\x1b[0m");
}

test "metamethod __index for field access" {
    try t.topNumber(
        \\ const mt = {__index = fn(self, key) 42}
        \\ const t = set_meta({}, mt)
        \\ t.missing_field
    , 42);
}

test "plain metatable fields resolve before __index" {
    try t.topNumber(
        \\ const mt = {value = 7, __index = fn(self, key) 99}
        \\ const t = set_meta({}, mt)
        \\ t.value
    , 7);
}

test "metamethod failures are runtime errors not host panics" {
    try t.expectRuntimeFailureWithMessage(
        \\ const mt = {__tostring = fn(self) panic("boom")}
        \\ const t = set_meta({}, mt)
        \\ string(t)
    , .Panic, "boom");
}

test "errs returned at toplevel report proper span" {
    try t.expectRuntimeFailure(
        \\ do
        \\ {:err, "boom"}?
        \\ end
    , .Panic, 2, 2, "\x1b[32m\"boom\"\x1b[0m");
}

test "if-let works" {
    try t.topNumber(
        \\ let t = {count = 100}
        \\ 
        \\ if not (let cnt = t.count)
        \\   return :false
        \\ 
        \\ expect_eq(cnt, 100)
        \\ 
        \\ let acc = 0
        \\ 
        \\ for i in 0..cnt do
        \\   acc += 1
        \\ end
        \\ 
        \\ acc
    , 100);
}

test "metamethod __newindex for field assignment" {
    try t.topNumber(
        \\ const mt = {__newindex = fn(self, key, value) table.rawset(self, key, 99)}
        \\ const t = set_meta({}, mt)
        \\ t.x = 5
        \\ t.x
    , 99); // todo assert!(99 == t.x = 5)
}

test "method calls require obj:method(args)" {
    try t.topNumber(
        \\ const mt = {get_x = fn(self) self.x}
        \\ const t = set_meta({x = 12}, mt)
        \\ t:get_x()
    , 12);
    try t.topNumber(
        \\ const Email = {parse = fn(x) x}
        \\ Email.parse(42)
    , 42);
}

test "metatable-backed constructor and instance methods compile" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const source =
        \\ let DB = set_meta({}, {
        \\     open = fn(self) print("opened"),
        \\     close = fn(self) print("closed"),
        \\     new = fn(self, filename) do self["filename"] = filename end
        \\ })
        \\ 
        \\ let first_db = DB:new("./first.db")
        \\ let second_db = DB:new("./second.db")
        \\ 
        \\ first_db:open()
        \\ second_db:open()
        \\ second_db:close()
        \\ first_db:close()
    ;

    const built = try lang.build(&vm, .{ .text = source }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);
    try std.testing.expect(built.ok.instructions.len != 0);
}

test "plain field access returns the raw resolved value" {
    try t.topType(
        \\ const mt = {id = fn(self) self}
        \\ const t = set_meta({}, mt)
        \\ t.id
    , .function);
}

test "non-table values can use plain metatable fields as methods" {
    try t.topString(
        \\ const mt = {reverse = fn(self) "fdsa"}
        \\ set_meta("", mt)
        \\ "asdf":reverse()
    , "fdsa");
}

//
// error vals
//

test "error helpers build and classify tagged errors" {
    try t.topString("string({:ok, 42})", "{ :ok, 42 }");
    try t.topString("string({:err, :FileNotFound})", "{ :err, :FileNotFound }");
    try t.topTrue("err?!({:err, :Bad})");
    try t.topTrue("err?!({:err, :FileNotFound})");
    try t.topFalse("err?!({:ok, :Bad})");
}

test "result predicates replace native functions" {
    try t.topTrue("ok?!({:ok, 42})");
    try t.topTrue("ok?!({:ok, :nil})");
    try t.topFalse("ok?!({:err, :Bad})");
    try t.topTrue("err?!({:err, :Bad})");
    try t.topFalse("err?!({:ok, 42})");
}

test "unwrap panics on err result" {
    try t.expectRuntimeFailureWithMessage(
        \\ unwrap({:err, :Unlucky})
    , .Panic, ":Unlucky");
}
test "unwrap rejects non-results at runtime" {
    try t.expectRuntimeError(
        \\ unwrap "yo"
    , .TypeError);
}

//
// macro
// pattern grammar: %x (capture), %x:type (typed), %GROUP(...)*+? (quantified groups)
//

test "zero-arg macro expands on identifier use" {
    try t.topNumber(
        \\macro answer! `` `42`
        \\answer!
    , 42);
}

test "macro system capabilities and limitations" {
    try t.topNumber(
        \\ macro id! `%x:expr` `%x`
        \\ id!(42)
    , 42);

    try t.topNumber(
        \\ macro count_args! `(%fmt:str %ARGS(, %arg:expr)*)` `3`
        \\ count_args!("format", 1, 2, 3)
    , 3);
}

// basic simple captures
test "binary structure macro - multiple captures with literals" {
    try t.topNumber(
        \\ macro combine! `(%left:expr %right:expr)` `%left + %right`
        \\ combine!(20, 22)
    , 42);
}

// type-consrtained captures
test "identifier capture - creates bindings" {
    try t.topNumber(
        \\ macro const! `%name:ident = %val:expr` `const %name = %val`
        \\ const!(answer = 42)
        \\ answer
    , 42);
}

test "string literal capture - constrains to string" {
    try t.topType(
        \\ macro get_format! `(%fmt:str %rest:expr)` `%fmt`
        \\ get_format!("hello", 123)
    , .string);
}

test "number literal capture - constrains to number" {
    try t.topNumber(
        \\ macro repeat_val! `(%n:number %body:expr)` `%n`
        \\ repeat_val!(42, (1 + 2))
    , 42);
}

// repetition groups
test "zero-or-more repetition - captures multiple items" {
    try t.topNil(
        \\ macro do_all! `(%ITEMS(%item:expr)*)` `do %ITEMS(%item) :nil end`
        \\ do_all!(1, 2, 3)
    );
}

test "one-or-more repetition - at least one required" {
    try t.topNumber(
        \\ macro sum_all! `(%first:expr %REST(%item:expr)*)` `%first %REST(+ %item)`
        \\ sum_all!(10, 15, 17)
    , 42);
}

test "optional group - zero or one occurrence" {
    try t.topNumber(
        \\ macro maybe_print! `(%val:expr %MSG(%msg:str)?)` `%val`
        \\ maybe_print!(42, "hello")
    , 42);
}

test "comma-separated repetition - literal separators" {
    try t.topNumber(
        \\ macro list_fst! `(%first:expr %REST(%item:expr)*)` `%first`
        \\ list_fst!(10, 15, 17)
    , 10);
}

// complex combinations
test "if-elif-else chain multiple groups with quantifiers" {
    try t.topNumber(
        \\ macro choose!
        \\     `(%head:number %ITEMS(%item:number)* %MSG(%msg:str)?)`
        \\     `do %head %ITEMS(+ %item) end`
        \\
        \\ choose!(10, 15, 17, "done")
    , 42);
}

test "complex fn def captures, repetition, optional" {
    try t.topNumber(
        \\ macro sum_from! `(%start:number %ITEMS(%item:expr)+)`
        \\     `do %start %ITEMS(+ %item) end`
        \\
        \\ sum_from!(10, 15, 17)
    , 42);
}

// kw-based control flow
test "negative conditional" {
    try t.topType(
        \\ macro unless! `(%cond:expr %body:expr)` `if %cond :nil else %body`
        \\ unless!(5 < 0, :positive)
    , .atom);
}

test "custom keyword structure - keywords at multiple positions" {
    try t.topNumber(
        \\ macro repeat_until! `(%body:expr %cond:expr)` `%body`
        \\ repeat_until!(10 + 32, 5 == 0)
    , 42);
}

//
// quasiquote `template` with %splice
//

test "quasiquote encodes literals as tables" {
    try t.topTrue(
        \\let r = `:hello`
        \\r == {:hash, "hello"}
    );
    try t.topTrue(
        \\let r = `42`
        \\r == {:number, 42}
    );
    try t.topTrue(
        \\let r = `"hello"`
        \\r == {:string, "hello"}
    );
    try t.topTrue(
        \\let r = `hello`
        \\r == {:ident, "hello"}
    );
    try t.topTrue(
        \\let r = `{:a, :b}`
        \\r == {:table, {{:nil, :false, {:hash, "a"}}, {:nil, :false, {:hash, "b"}}}}
    );
}

test "quasiquote splices insert values" {
    try t.topTrue(
        \\let x = 10
        \\let r = `(%x + 1)`
        \\r == {:binary, :add, 10, {:number, 1}}
    );
    try t.topTrue(
        \\let v = 42
        \\let r = `{key = %v}`
        \\r == {:table, {{{:ident, "key"}, :false, 42}}}
    );
    try t.topTrue(
        \\let x = 42
        \\let r = `{{:a, %x}}`
        \\r == {:table, {{:nil, :false, {:table, {{:nil, :false, {:hash, "a"}}, {:nil, :false, 42}}}}}}
    );
    try t.topTrue(
        \\let a = 20
        \\let b = 22
        \\let r = `(f(%a, %b))`
        \\r == {:call, {:ident, "f"}, {20, 22}, :false, {}}
    );
    try t.topTrue(
        \\let k = 99
        \\let v = 42
        \\let r = `{[%k] = %v}`
        \\r == {:table, {{99, :true, 42}}}
    );
}

//
// fns / imports
//

test "closures capture outer locals by reference" {
    try t.topNumber(
        \\ const make_adder = fn(x) fn(y) x + y
        \\ const add2 = make_adder(2)
        \\ add2(40)
    , 42);
    try t.topNumber(
        \\ const outer = fn() do
        \\     let x = 1
        \\     const get = fn() x
        \\     x = 2
        \\     get()
        \\ end
        \\ outer()
    , 2);
    try t.topNumber(
        \\ const make_counter = fn() do
        \\     let x = 0
        \\     const inc = fn() do
        \\         x = x + 1
        \\         x
        \\     end
        \\     inc
        \\ end
        \\ const inc = make_counter()
        \\ inc()
        \\ inc()
    , 2);
}

test "nested assignment updates nearest lexical binding before globals" {
    try t.topNumber(
        \\ const outer = fn() do
        \\     let x = 1
        \\     const set = fn() do
        \\         x = 42
        \\         :nil
        \\     end
        \\     set()
        \\     x
        \\ end
        \\ outer()
    , 42);
    try t.topNumber(
        \\ let x = 1
        \\ const set = fn() do
        \\     x = 42
        \\     :nil
        \\ end
        \\ set()
        \\ x
    , 42);
}

test "recursion works across top-level local and capturing closures" {
    try t.topNumber(
        \\ const fact = fn(n) if n == 0 1 else n * fact(n - 1)
        \\ fact(5)
    , 120);
    try t.topTrue(
        \\ const is_even = fn(n) if n == 0 1 else is_odd(n - 1)
        \\ const is_odd = fn(n) if n == 0 0 else is_even(n - 1)
        \\ is_even(10)
    );
    try t.topNumber(
        \\ const outer = fn() do
        \\     const fact = fn(n) if n == 0 1 else n * fact(n - 1)
        \\     fact(5)
        \\ end
        \\ outer()
    , 120);
    try t.topNumber(
        \\ const make_fact = fn(scale) do
        \\     const fact = fn(n) if n == 0 scale else n * fact(n - 1)
        \\     fact
        \\ end
        \\ const fact = make_fact(2)
        \\ fact(3)
    , 12);
}

test "loops thread state and break with a single value" {
    try t.topNumber(
        \\ let x = 0
        \\ const result = loop/l do
        \\     if x < 10
        \\         x = x + 1
        \\     else
        \\         break/l(x)
        \\ end
        \\ result
    , 10);
    try t.topNumber(
        \\ const scale = 2
        \\ let v = 1
        \\ loop/l do
        \\     if v < 10
        \\         v = v * scale
        \\     else
        \\         break/l(v)
        \\ end
    , 16);
    try t.topAtom(
        \\ loop do
        \\     break(:nil)
        \\ end
    , "loop");
    try t.topNumber(
        \\ loop/l do
        \\     break/l(42)
        \\ end
    , 42);
    try t.topNumber(
        \\ let i = 1
        \\ loop/l do
        \\     if i == 1
        \\         break/l(99)
        \\     else
        \\         break/l(i)
        \\ end
    , 99);
}

test "indexed table iteration gets value and index" {
    try t.topNumber(
        \\ for val, i in {10, 20, 30} do
        \\     if i == 1 return val
        \\ end
    , 20);
}

test "simple table_get with integer key" {
    try t.topNumber(
        \\ let t = {10, 20, 30}
        \\ t[0] + t[1] + t[2]
    , 60);
}

test "for loop over table prints all values" {
    try t.topNumber(
        \\ let s = 0
        \\ let t = {10, 20, 30}
        \\ for v in t
        \\     s = s + v
        \\ s
    , 60);
}

test "inner for loop" {
    try t.topNumber(
        \\ let t = 0
        \\ for x in 1..10
        \\  for y in 10..20 t += (x * y)
        \\ t
    , 6525);
}

test "for loop with range literal iterates numeric sequence" {
    try t.topNumber(
        \\ let sum = 0
        \\ for i in 0..5 do
        \\     sum = sum + i
        \\ end
        \\ sum
    , 10);
}

test "for loop with range literal and variable end" {
    try t.topNumber(
        \\ let n = 10
        \\ let sum = 0
        \\ for i in 0..n do
        \\     sum = sum + i
        \\ end
        \\ sum
    , 45);
}

test "for loop with range produces loop result" {
    try t.topAtom(
        \\ for i in 0..3 do
        \\     i + 10
        \\ end
    , "loop");
    try t.topNumber(
        \\ for/l i in 0..3 do
        \\     if i == 1 break/l(i + 10)
        \\ end
    , 11);
}

test "while loop runs while cond holds" {
    try t.topNumber(
        \\ let x = 0
        \\ while x < 5 do
        \\     x = x + 1
        \\ end
        \\ x
    , 5);
    try t.topNumber(
        \\ let x = 0
        \\ while :false do
        \\     x = x + 1
        \\ end
        \\ x
    , 0);
}

test "continue doesnt doesnt work outside of loop" {
    try t.expectCompileError("continue", .UnsupportedSyntax);
}

test "continue skips to next iteration" {
    try t.topNumber(
        \\ let i = 0
        \\ let result = 0
        \\ loop/l do
        \\   i += 1
        \\   if i > 5 break/l(result)
        \\   if i % 2 == 0 continue
        \\   result += i
        \\ end
    , 9);
    try t.topAtom(
        \\ let i = 0
        \\ loop do
        \\   i += 1
        \\   if i > 5 break(i)
        \\ end
    , "loop");
    try t.topNumber(
        \\ let i = 0
        \\ let result = 0
        \\ while i < 5 do
        \\   i += 1
        \\   if i % 2 == 0 continue
        \\   result += i
        \\ end
        \\ result
    , 9);
    try t.topNumber(
        \\ let result = 0
        \\ for i in 1..6 do
        \\   if i % 2 == 0 continue
        \\   result += i
        \\ end
        \\ result
    , 9);
    try t.topNumber(
        \\ let result = 0
        \\ for i in 1..3 do
        \\   for j in 1..5 do
        \\     if j == 2 continue
        \\     result += 1
        \\   end
        \\ end
        \\ result
    , 6);
}

test "break in for loops" {
    try t.topNumber(
        \\ let result = 0
        \\ for i in 0..10 do
        \\     if i == 5 break(i * 2)
        \\     result = result + i
        \\ end
        \\ result
    , 10);

    try t.topNumber(
        \\ for/l i in 0..10 do
        \\     if i == 7 break/l(i)
        \\ end
    , 7);
    try t.topAtom(
        \\ for i in 0..10 do
        \\     if i == 7 break(i)
        \\ end
    , "loop");
    try t.topAtom(
        \\ const x = for i in 0..5 do
        \\   break :nil
        \\ end
        \\ x
    , "loop");
    try t.topAtom(
        \\ const y = for/l i in 0..5 do
        \\   break/l :nil
        \\ end
        \\ y
    , "nil");
}

test "break in while loops" {
    try t.topNumber(
        \\ let x = 0
        \\ let result = 0
        \\ while x < 10 do
        \\     if x == 5 break(x * 2)
        \\     result = result + x
        \\     x = x + 1
        \\ end
        \\ result
    , 10);
    try t.topNumber(
        \\ let i = 0
        \\ while/l i < 10 do
        \\     if i == 7 break/l(i)
        \\     i = i + 1
        \\ end
    , 7);
    try t.topAtom(
        \\ let i = 0
        \\ while i < 10 do
        \\     if i == 7 break(i)
        \\     i = i + 1
        \\ end
    , "loop");
}

test "while body result is loop value after iterations" {
    try t.topAtom(
        \\ let a = 0
        \\ while a < 3 do
        \\     a += 1
        \\ end
    , "loop");
}

test "loop with locals inside does not corrupt loop result" {
    try t.topNumber(
        \\ let a = 0
        \\ let b = 1
        \\ let c = 2
        \\ let d = 3
        \\ const x = loop/l do
        \\     let e = 4
        \\     let f = 5
        \\     let g = 6
        \\     break/l(42)
        \\ end
        \\ x
    , 42);
    try t.topAtom(
        \\ const y = loop do
        \\     let e = 4
        \\     break(42)
        \\ end
        \\ y
    , "loop");
}

test "for range with preceding locals and body locals" {
    try t.topNumber(
        \\ let a = 0
        \\ let b = 1
        \\ let c = 2
        \\ let d = 3
        \\ let e = 4
        \\ let f = 5
        \\ const x = for/l i in 0..3 do
        \\     let g = 6
        \\     let h = 7
        \\     break/l(42)
        \\ end
        \\ x
    , 42);
}

test "for range with two params and preceding locals" {
    try t.topAtom(
        \\ let a = 0
        \\ const x = for i, idx in 0..3 do
        \\     i + idx
        \\ end
        \\ x
    , "loop");
}

test "triple-quoted multiline strings compile and evaluate" {
    try t.topString(
        \\ """
        \\ hello
        \\ world
        \\ """
    , "hello\nworld");

    try t.topString(
        \\ """inline"""
    , "inline");
}

test "test.skip keyword is valid syntax" {
    try t.topNil(
        \\ test / skip "skipped" do 1 + 1 end
    );
}

test "suite keyword compiles and returns nil" {
    try t.topNil(
        \\ suite "example" do
        \\     test "inner" do 1 end
        \\ end
    );

    try t.topNil(
        \\ suite "empty" do end
    );
}

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
        \\ const id = fn(x: int) x
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

    const result = try revo.vm.exec.runReport(&vm);
    switch (result) {
        .ok => return error.ExpectedRuntimeFailure,
        .err => |failure| {
            var buf = std.Io.Writer.Allocating.init(alloc);
            defer buf.deinit();
            try failure.renderAt(
                alloc,
                &buf.writer,
                failure.report.source_name orelse "<source>",
                source,
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

    const result = try revo.vm.exec.runReport(&vm);
    switch (result) {
        .ok => return error.ExpectedRuntimeFailure,
        .err => |failure| {
            var buf = std.Io.Writer.Allocating.init(alloc);
            defer buf.deinit();
            try failure.render(alloc, &buf.writer, source);

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

test "import caches modules and reuses the same table" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "counter.rv", .data =
        \\ let state = {count = 0}
        \\ state.count = state.count + 1
        \\ state
        },
    });
    defer m.deinit();

    try t.topNumberInDir(m.dir,
        \\ const a = import "./counter"
        \\ a.count = 41
        \\ const b = import "./counter"
        \\ b.count
    , 41);
}

test "import keeps module globals isolated from importer globals" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "answer.rv", .data =
        \\ let x = 41
        \\ const answer = x
        \\ answer
        },
    });
    defer m.deinit();

    try t.topNumberInDir(m.dir,
        \\ let x = 99
        \\ const ans = import "./answer"
        \\ x + ans
    , 140);
}

test "import returns module value" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "vis.rv", .data =
        \\ const hidden = 7
        \\ const shown = 9
        \\ shown
        },
    });
    defer m.deinit();

    try t.topNumberInDir(m.dir,
        \\ const ns = import "./vis"
        \\ ns
    , 9);
}

test "locals are still local" {
    try t.topNumber(
        \\ do
        \\   let a = 5
        \\ end
        \\ let a = 7
        \\ a
    , 7);
    try t.topNumber(
        \\ let a = 7
        \\ do let a = 5 end
        \\ a
    , 7);
    try t.topNumber(
        \\ const a = 7
        \\ do const a = 5 end
        \\ a
    , 7);
}

test "top-level locals are real closure locals" {
    try t.topNumber(
        \\ let x = 1
        \\ const get = fn() x
        \\ x = 42
        \\ get()
    , 42);
    try t.expectCompileError(
        \\ const x = 1
        \\ x = 2
    , .CompileError);
}

test "top module assignment does not create vm global" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "setx.rv", .data =
        \\ const x = 41
        \\ x
        },
    });
    defer m.deinit();

    try t.expectCompileErrorInDir(m.dir,
        \\ import "./setx"
        \\ x
    );
}

test "imported module assignment is private to module cache" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "private_state.rv", .data =
        \\ const y = 7
        \\ const value = y
        \\ value
        },
    });
    defer m.deinit();

    try t.topNumberInDir(m.dir,
        \\ const m = import "./private_state"
        \\ m
    , 7);

    try t.expectCompileErrorInDir(m.dir,
        \\ import "./private_state"
        \\ y
    );
}

test "imported module members work  and are typed" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "calc.rv", .data =
        \\ pub fn double(n: num) n * 2
        \\ pub const version = 3
        \\ const hidden = 99
        },
    });
    defer m.deinit();

    try t.topNumberInDir(m.dir,
        \\ const m = import "./calc"
        \\ m.double(21)
    , 42);

    try t.topNumberInDir(m.dir,
        \\ const m = import "./calc"
        \\ m.version
    , 3);

    try t.expectCompileErrorInDir(m.dir,
        \\ const m = import "./calc"
        \\ m.double("x")
    );

    try t.expectCompileErrorInDir(m.dir,
        \\ const m = import "./calc"
        \\ m.typo
    );

    // non-pub names are not runtime exports either
    try t.expectCompileErrorInDir(m.dir,
        \\ const m = import "./calc"
        \\ m.hidden
    );
}

test "imported proc macros expand, unknown ones error" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "macs.rv", .data =
        \\ pub proc answer!(iter) do
        \\   {{:number, 42}}
        \\ end
        },
    });
    defer m.deinit();

    try t.topNumberInDir(m.dir,
        \\ const m = import "./macs"
        \\ m.answer!()
    , 42);

    try t.expectExpandErrorInDir(m.dir,
        \\ const m = import "./macs"
        \\ m.nope!(1)
    , "unknown macro `m.nope!`");
}

test "unknown macro calls are compile errors" {
    // yes this happens sometimes and its REALLY unfun
    try t.expectExpandError(
        \\ nosuchmacro!(1)
    , "unknown macro `nosuchmacro!`");
}

test "imported qualified types check values" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "shapes.rv", .data =
        \\ pub type T = {:ok, string}
        \\ pub fn f() 10
        \\ pub let v = 5
        },
    });
    defer m.deinit();

    try t.topNumberInDir(m.dir,
        \\ import "shapes"
        \\ let x: shapes.T = {:ok, "hi"}
        \\ 1
    , 1);

    try t.expectCompileErrorInDir(m.dir,
        \\ import "shapes"
        \\ let x: shapes.T = {:err, 5}
    );

    try t.expectCompileErrorInDir(m.dir,
        \\ import "shapes"
        \\ let x: shapes.U = {:ok, "hi"}
    );

    try t.expectCompileErrorInDir(m.dir,
        \\ import "shapes"
        \\ type B = shapes.T
        \\ let y: B = {:err, 5}
    );

    try t.topNumberInDir(m.dir,
        \\ import "shapes"
        \\ fn get() -> shapes.T {:ok, "hi"}
        \\ 1
    , 1);
}

test "imported unknown member calls are errors" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "calc.rv", .data =
        \\ pub fn double(n: num) n * 2
        \\ pub const version = 3
        },
    });
    defer m.deinit();

    try t.expectCompileErrorInDir(m.dir,
        \\ const m = import "./calc"
        \\ m.typo()
    );

    // stdlib method dispatch still works on known-shape tables
    try t.topNumberInDir(m.dir,
        \\ const m = import "./calc"
        \\ m.double(21)
    , 42);
}
//
// misc behaviour doc
//
test "nested closure accesses upvalues from parent scope" {
    try t.topNumber(
        \\ const outer = fn(a) do
        \\     const middle = fn(b) do
        \\         const inner = fn() a + b
        \\         inner
        \\     end
        \\     middle(10)
        \\ end
        \\ const f = outer(5)
        \\ f()
    , 15);
}

test "multiple closures share same upvalue cell" {
    try t.topNumber(
        \\ const make_pair = fn() do
        \\     let x = 0
        \\     const set = fn(v) do x = v x end
        \\     const get = fn() x
        \\     set(42)
        \\     get()
        \\ end
        \\ make_pair()
    , 42);
}

//
// loop & control flow
//
test "big loop doesnt crash" {
    try t.topNumber(
        \\ let x = 1
        \\ loop/l do
        \\     if x < 1000
        \\         x = x + 1
        \\     else
        \\         break/l(x)
        \\ end
    , 1000);
    try t.topAtom(
        \\ let x = 1
        \\ loop do
        \\     if x < 1000
        \\         x = x + 1
        \\     else
        \\         break(x)
        \\ end
    , "loop");
}

test "if expressions" {
    try t.topNumber(
        \\ if 1 == 1
        \\     5
        \\ else
        \\     42
    , 5);
}

test "tail recursion reuses frames" {
    try t.topNumber(
        \\ const count = fn(n)
        \\     if n == 1000
        \\         n
        \\     else
        \\         count(n + 1)
        \\ count(0)
    , 1000);
}

test "recursive calls still evaluate" {
    try t.topNumber(
        \\ const count = fn(n)
        \\     if n == 5000
        \\         n
        \\     else
        \\         1 + count(n + 1)
        \\ count(0)
    , 10000);
}

test "assignment to constant fails" {
    try t.expectCompileError(
        \\ const a = 1
        \\ a = 2
    , .CompileError);
    try t.expectCompileError(
        \\ const f = fn() do
        \\     const a = 1
        \\     a = 2
        \\ end
        \\ f()
    , .CompileError);
}

//
// match
//
test "match wildcards" {
    try t.topNumber(
        \\ const x = 999
        \\ match x
        \\ | 1 => do 1 end
        \\ | 2 => do 2 end
        \\ | v => do v end
    , 999);
    try t.topNumber(
        \\ const nextword = "."
        \\ let a = match nextword
        \\ | "." => 6
        \\ | _ => 2
        \\ let b = match nextword
        \\ | "," => 1
        \\ | _ => 7
        \\ a + b
    , 13);
}

test "match locals dont clobber enclosing call temps" {
    // binder used inside a call in the arm body must see the subject,
    // not callee (slots n registers share frame storage)
    try t.topString(
        \\ fn id(x) x
        \\ id(match "hi" | v => id(v))
    , "hi");
    // match used as a call argument must leave its result contiguous with the callee ([callee, arg])
    // , not stranded above a dead subject slot
    try t.topNumber(
        \\ fn id(x) x
        \\ id(match 1 | 1 => 42 | _ => 0)
    , 42);
    try t.topString(
        \\ fn id(x) x
        \\ id(match "why is it a function" | :nil => :oops | v => id(v))
    , "why is it a function");
}

test "match guards" {
    try t.topNumber(
        \\ const x = 15
        \\ match x
        \\ | v when v < 10 => do 1 end
        \\ | v when v > 10 => do 2 end
        \\ | v => do 3 end
    , 2);
    try t.topNumber(
        \\ let n = 0
        \\ for i in 0..7 do
        \\   let status: any = if i == 5
        \\     :done
        \\   else i
        \\ 
        \\   match status
        \\   | v when v == :done => n += 1
        \\ end
        \\ 
        \\ n
    , 1);
}
test "match table array patterns" {
    try t.topNumber(
        \\ const x = {:ok, 42}
        \\ match x
        \\ | {:asdf, v} => 1
        \\ | {:ok, v} => v
        \\ | {:err, e} => 2
    , 42);
    try t.topNumber(
        \\ const x = {:ok, 42}
        \\ match x
        \\ | {:asdf, v} => 1
        \\ | {:ok, v} when v < 20 => 2
        \\ | {:ok, v} when v > 40 => v
        \\ | {:ok, v} when number?(v) => 3
        \\ | {:err, e} => 2
    , 42);
}

test "match table patterns fall through on shape mismatch" {
    try t.topNumber(
        \\ match 99
        \\ | {:ok, v} => 1
        \\ | _ => 3
    , 3);
    try t.topNumber(
        \\ match {:ok}
        \\ | {:ok, v} => 1
        \\ | _ => 4
    , 4);
    try t.topNumber(
        \\ match {:ok, 1, 2}
        \\ | {:ok, v} => 1
        \\ | _ => 5
    , 5);
    try t.topNumber(
        \\ match {1, 2, x = 9}
        \\ | {a, b} => a + b
        \\ | _ => 6
    , 3);
}

test "match table nested patterns" {
    try t.topNumber(
        \\ match {:a, {:b, 7}}
        \\ | {:a, {:b, v}} => v
        \\ | _ => 0
    , 7);
    try t.topNumber(
        \\ match {{:ok, 1}, 2}
        \\ | {{:ok, v}, _} => v
        \\ | _ => 0
    , 1);
    try t.topNumber(
        \\ match {:ok, {:x, 5}}
        \\ | {:ok, {_, v}} => v
        \\ | _ => 0
    , 5);
    try t.topNumber(
        \\ const data = {:ok, {:inner, 10}}
        \\ match data
        \\ | {:ok, {:inner, v}} when v < 5 => 1
        \\ | {:ok, {:inner, v}} when v > 5 => 2
        \\ | _ => 0
    , 2);
}

test "match ascriptions" {
    try t.topNumber(
        \\ let a = 123
        \\ match a
        \\ | x: num => x
        \\ | x: string => 0
    , 123);
    try t.topNumber(
        \\ let a = "hi"
        \\ match a
        \\ | x: num => 0
        \\ | x: string => 7
        \\ | _ => 8
    , 7);
    try t.topNumber(
        \\ let a = 123
        \\ match a
        \\ | x: string => 0
        \\ | _ => 9
    , 9);

    try t.topNumber(
        \\ match {1, 2}
        \\ | {x, y: number} => x + y
        \\ | _ => 0
    , 3);
    try t.topNumber(
        \\ match {1, "two"}
        \\ | {x, y: number} => 1
        \\ | {x, y} => 2
        \\ | _ => 3
    , 2);
    try t.topNumber(
        \\ match {:ok, 1}
        \\ | {t: :ok | :err, v} => v
        \\ | _ => 0
    , 1);
    try t.topNumber(
        \\ match {{5}, 1}
        \\ | {{n: number}, _} => n
        \\ | _ => 0
    , 5);
    try t.topNumber(
        \\ let a = {1, 2}
        \\ match a
        \\ | {x} => 10
        \\ | {x, y: number, z} => 7
        \\ | {x, y} => 5
    , 5);
}

test "ascriptions in value position are rejected" {
    try t.expectSemanticFailure(
        \\ const t = {x: number}
        \\ t
    ,
        1,
        13,
        "type ascriptions only go in match patterns",
    );
}

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

test "num alias works in range bounds" {
    try t.topNumber(
        \\ fn f(count: num) do
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
        \\ const x: int = "nope"
        ,
    }, .{ .install_debug_info = false });

    switch (result) {
        .ok => return error.ExpectedCompileFailure,
        .err => |failure| switch (failure) {
            .lower => |diag| {
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
            else => return error.ExpectedLowerFailure,
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
            .lower => |diag| {
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
            else => return error.ExpectedLowerFailure,
        },
    }
}

test "typed call reports multiple bad arguments" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const result = try lang.build(&vm, .{
        .text =
        \\ const f = fn(a: int, b: string) a
        \\ f("nope", 2)
        ,
    }, .{
        .install_debug_info = false,
    });

    switch (result) {
        .ok => return error.ExpectedCompileFailure,
        .err => |failure| switch (failure) {
            .lower => |diag| {
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
            else => return error.ExpectedLowerFailure,
        },
    }
}

test "named call reports multiple bad parameters" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const result = try lang.build(&vm, .{
        .text =
        \\ const f = fn(a: int, b: int) a + b
        \\ f(x = 1, y = 2)
        ,
    }, .{
        .install_debug_info = false,
    });

    switch (result) {
        .ok => return error.ExpectedCompileFailure,
        .err => |failure| switch (failure) {
            .lower => |lower| {
                var error_count: usize = 0;
                for (lower.report.parts) |part| {
                    if (part == .@"error") error_count += 1;
                }
                try std.testing.expect(error_count >= 2);
                vm.runtime.resetDiagArena();
            },
            else => return error.ExpectedLowerFailure,
        },
    }
}

//
// fn semantics
//
test "function returns single value (last expression)" {
    try t.topNumber(
        \\ const f = fn() do
        \\     1
        \\     2
        \\     3
        \\ end
        \\ f()
    , 3);
}

test "function with multiple parameters" {
    try t.topNumber(
        \\ const f = fn(a, b, c) a + b + c
        \\ f(10, 20, 30)
    , 60);
}

test "typed function alias call is checked" {
    try t.expectSemanticFailure(
        \\ const id = fn(x: int) x
        \\ const f = id
        \\ f("nope")
    ,
        3,
        4,
        "arg 1 (`x`) to `f` wants number, got string",
    );
}

test "recursive function with guards" {
    try t.topNumber(
        \\ const sum = fn(n)
        \\     match n
        \\     | 0 => do 0 end
        \\     | x => do x + sum(x - 1) end
        \\
        \\ sum(5)
    , 15);
}

//
// operator behaviour
//
test "comparison with guard in match" {
    try t.topNumber(
        \\ const check = fn(x)
        \\     match x
        \\     | v when v > 50 => do 1 end
        \\     | v when v > 25 => do 2 end
        \\     | v => do 3 end
        \\ check(40)
    , 2);
}

test "and/or operators" {
    try t.topAtom(
        \\ 1 and 1 and :true
    , "true");
    try t.topAtom(
        \\ 0 or 0 or :true
    , "true");
    try t.topNumber(
        \\ 0 and 999
    , 0);
}

test "string escaping works" {
    try t.topString("\"hello\\nworld\"", "hello\nworld");
    try t.topString("'hello\\nworld'", "hello\\nworld");
}

test "spawned fiber with sleep completes" {
    try t.topNumber(
        \\ const f = fn(n) do sleep(1) n * 2 end
        \\ const h = spawn f(21)
        \\ join(h)
    , 42);
}

test "channel with fibers" {
    try t.topNumber(
        \\ const ch = chan(0)
        \\ const sender = fn(c, v) do send(c, v) v end
        \\ const s = spawn sender(ch, 42)
        \\ const msg = recv(ch)
        \\ join(s)
        \\ msg
    , 42);
    try t.topNumber(
        \\ const ch = chan(0)
        \\ const worker = fn(id) do send(ch, id * 10) id end
        \\ const a = spawn worker(1)
        \\ const b = spawn worker(2)
        \\ const x = recv(ch)
        \\ const y = recv(ch)
        \\ join(a)
        \\ join(b)
        \\ x + y
    , 30);
}

test "buffered channels" {
    try t.topNumber(
        \\ const ch = chan(2)
        \\ send(ch, 10)
        \\ send(ch, 32)
        \\ recv(ch) + recv(ch)
    , 42);
    try t.topNumber(
        \\ const ch = chan(3)
        \\ send(ch, 1)
        \\ send(ch, 2)
        \\ send(ch, 3)
        \\ recv(ch) + recv(ch) + recv(ch)
    , 6);
}

test "yield suspends and resumes fiber" {
    try t.topType(
        \\ do yield end
    , .atom);
}

test "spawned buffered channel recv does not return missing" {
    try t.topNumber(
        \\ let ch = chan(2)
        \\ let worker = fn(n) do
        \\   send(ch, n + 10)
        \\ end
        \\ spawn worker(1)
        \\ spawn worker(2)
        \\ recv(ch) + recv(ch)
    , 23);
}

test "multiple spawned joins survive nested calls" {
    try t.topNumber(
        \\ let worker = fn(n) do
        \\   n + 10
        \\ end
        \\ let a = spawn worker(1)
        \\ let b = spawn worker(2)
        \\ let c = spawn worker(3)
        \\ let ra = number(string(join(a))):unwrap()
        \\ let rb = number(string(join(b))):unwrap()
        \\ let rc = number(string(join(c))):unwrap()
        \\ ra + rb + rc
    , 36);
}

//
// comptime
//

test "comp arithmetic" {
    try t.topNumber(
        \\ comp (1 + 2 * 3)
    , 7);
    try t.topNumber(
        \\ comp ((10 / 2) + (3 * 4))
    , 17);
    try t.topNumber(
        \\ comp (-5 + 10)
    , 5);
}

test "comp result in runtime" {
    try t.topNumber(
        \\ let x = comp (2 + 3)
        \\ x * 2
    , 10);
}

test "comp string and bool ops" {
    try t.topString(
        \\ comp ("hello" ~ " " ~ "world")
    , "hello world");
    try t.topAtom(
        \\ comp (1 < 2)
    , "true");
    try t.topAtom(
        \\ comp (:true and :true)
    , "true");
}

test "comp errors" {
    try t.expectCompileFailure(
        \\ comp (1 / 0)
    , .ParseError, 1, 8, "division by zero!");
    try t.expectCompileFailure(
        \\ proc bad_comp!(iter) do
        \\   {{:comp_block, {:binary, :div, {:number, 1}, {:number, 0}}, :false}}
        \\ end
        \\ bad_comp!()
    , .ParseError, 4, 2, "division by zero!");
}

test "fn name(params) defines named function" {
    try t.topNumber(
        \\ fn add(a, b) a + b
        \\ add(5, 3)
    , 8);
}

test "fn name(params) multiple named functions" {
    try t.topNumber(
        \\ fn mul(x, y) x * y
        \\ fn add(a, b) a + b
        \\ mul(add(2, 3), 4)
    , 20);
}
test "channel receives from multiple producers preserve ordering" {
    try t.topNumber(
        \\ const ch = chan(0)
        \\ const work = fn(id, v) do send(ch, v) id end
        \\ const a = spawn work(1, 100)
        \\ const b = spawn work(2, 200)
        \\ const v1 = recv(ch)
        \\ const v2 = recv(ch)
        \\ join(a) + join(b) + v1 + v2
    , 303);
}

test "channel select w/ multiple waiters" {
    try t.topNumber(
        \\ const ch1 = chan(0)
        \\ const ch2 = chan(0)
        \\ spawn fn() send(ch1, 10)
        \\ spawn fn() send(ch2, 20)
        \\ recv(ch1) + recv(ch2)
    , 30);
}

test "macro inner binding invisible outside" {
    try t.expectSemanticError(
        \\ macro mac! `(%x:expr)` `let hidden = 99 :%x`
        \\ mac!(42)
        \\ hidden
    );
}

test "proc macro call with multiple args does not analyze arguments" {
    // arguments to proc macros are raw syntax, not real revo expressions
    // (e.g. method names passed to a doto!-style macro); the semantic
    // checker must not report false "unknown name" errors inside them
    try t.topNumber(
        \\ proc pick!(iter) do
        \\   let _first = iter:next()
        \\   let second = iter:next()
        \\   {second}
        \\ end
        \\ pick!(ignored, 45)
    , 45);
}

test "numeric and string keys are distinct" {
    try t.topNumber(
        \\ const t = {}
        \\ t[1] = 100
        \\ t["1"] = 200
        \\ t[1] + t["1"]
    , 300);
}

//
// error propagation: ? and orelse
//
test "table try/?/orelse/prop" {
    try t.topNumber(
        \\ {:ok, 42}?
    , 42);
    try t.topNumber(
        \\ const f = fn() {:ok, 10}
        \\ f()?
    , 10);
    try t.topNumber(
        \\ match {:ok, {:inner, 42}}?
        \\ | {:inner, v} => v
        \\ | _ => 0
    , 42);
    // TODO: make testing it not as painful as this
    try t.expectRuntimeFailureWithMessage(
        \\ {:err, :not_found}?
    , .Panic, "\x1b[33m:not_found\x1b[0m");
    try t.expectRuntimeFailureWithMessage(
        \\ const f = fn() {:err, :not_found}
        \\ f()?
        \\ 99
    , .Panic, "\x1b[33m:not_found\x1b[0m");
    try t.topNumber(
        \\ {:err, :fail} orelse 42
    , 42);
    try t.topNumber(
        \\ {:ok, 100} orelse 42
    , 100);
    try t.topNumber(
        \\ {:err, :a} orelse {:err, :b} orelse 99
    , 99);
    try t.topNumber(
        \\ {:err, :fail} orelse {:ok, 88}
    , 88);
    try t.topNumber(
        \\ {:ok, 15}? orelse 33
    , 15);
}

//
// pipe
//
// pipe
//

test "pipe: implicit single call" {
    try t.topNumber(
        \\ const f = fn(a) a * 2
        \\ 21 |> f
    , 42);
    try t.topNumber(
        \\ const f = fn(a) a * 2
        \\ 21 |> f()
    , 42);
}

test "pipe: implicit chained calls" {
    try t.topNumber(
        \\ fn a(x) x * 2
        \\ fn b(x) x + 2
        \\ 20 |> a |> b
    , 42);
    try t.topNumber(
        \\ fn a(x) x * 2
        \\ fn b(x) x + 2
        \\ 20 |> a() |> b()
    , 42);
    try t.topNumber(
        \\ fn a(x) x * 2
        \\ fn b(x) x + 2
        \\ 20 |> a() |> b
    , 42);
}

test "pipe: closures" {
    try t.topNumber(
        \\ 20 |> fn(x) x + 22
    , 42);
}

test "pipe: implicit match subject" {
    try t.topNumber(
        \\ 2
        \\ |> match
        \\    | x => 42
    , 42);
}

test "pipe: match with explicit subject acts like parens" {
    try t.topNumber(
        \\ :ok |> match "hi"
        \\   | "hi" => 3
    , 3);
}

// pipe placeholders

test "pipe: placeholders fill call slots" {
    try t.topString(
        \\ fn f(a, b) string(a) ~ string(b)
        \\ "asdf" |> f("got ", _)
    , "got asdf");
    try t.topString(
        \\ fn fmt(s, v) s ~ v
        \\ "asdf" |> fmt("aaa", _:upper())
    , "aaaASDF");
    try t.topNumber(
        \\ fn add(a, b) a + b
        \\ 5 |> add(_, _)
    , 10);
    try t.topString(
        \\ fn f(x) x:upper()
        \\ "asdf" |> f(_)
    , "ASDF");
}

test "pipe: placeholders in receiver and blocks" {
    try t.topNumber(
        \\ const obj = { inner = 40, meth = fn(self, x) self.inner + x }
        \\ obj |> _:meth(2)
    , 42);
    try t.topNumber(
        \\ const t = {5, 6, 7}
        \\ 1 |> t[_]
    , 6);
    try t.topString(
        \\ "asdf" |> "aaa" ~ _:upper()
    , "aaaASDF");
    try t.topString(
        \\ const x = "asdf"
        \\ x |> do string(_) end
    , "asdf");
}

test "pipe: method chain with state mutation" {
    try t.topNumber(
        \\ let counter = 40
        \\ const obj = { 
        \\   val = 20, 
        \\   add = fn(self) 
        \\     do 
        \\       counter = counter + self.val 
        \\       self 
        \\     end 
        \\ }
        \\ obj |> _:add() |> _:add()
        \\ counter
    , 80);
}

test "pipe: nested scope capture" {
    try t.topString(
        \\ "hello" |> do 
        \\    const transform = fn(s) s:upper()
        \\    transform(_)
        \\ end
    , "HELLO");
}

test "compiler: named parameters" {
    try t.topNumber(
        \\ const add = fn(x: int, y: int) do x + y end
        \\ add(x = 5, y = 3)
    , 8);
    try t.topNumber(
        \\ const add = fn(x: int, y: int) do x + y end
        \\ add(y = 3, x = 5)
    , 8);
    try t.topNumber(
        \\ const add3 = fn(x: int, y: int, z: int) do x + y + z end
        \\ add3(1, y = 2, z = 3)
    , 6);
}

test "compiler: named parameters errors" {
    // unknown names surface at lowering, duplicates and mixing at semantic
    try t.expectCompileError(
        \\ const add = fn(x: int, y: int) do x + y end
        \\ add(x = 5, z = 3)
    , .ParseError);
    try t.expectSemanticError(
        \\ const add = fn(x: int, y: int) do x + y end
        \\ add(x = 5, x = 3)
    );
    try t.expectSemanticError(
        \\ const add = fn(x: int, y: int) do x + y end
        \\ add(x = 5, 3)
    );
}

test "named parameters with generics" {
    try t.topNumber(
        \\ fn identity<T>(x: T) x
        \\ identity(x = 42)
    , 42);
    try t.topString(
        \\ fn identity<T>(x: T) x
        \\ identity(x = "hi")
    , "hi");
}

test "assignment expression returns assigned value" {
    try t.topNumber(
        \\ let a = {}
        \\ let c = (a.b = 5)
        \\ c
    , 5);
}

test "for loop calls iterator" {
    try t.topNumber(
        \\ let t = set_meta({}, {
        \\   __iter = fn(self) do
        \\     let i = 0
        \\     fn() do
        \\       i += 1
        \\       if i > 2 :done else 42
        \\     end
        \\   end,
        \\ })
        \\ let sum = 0
        \\ for x in t do
        \\   sum = sum + x
        \\ end
        \\ sum
    , 84);
}

//
// optional param
//

test "optional params multiple" {
    try t.topAtom(
        \\ const f = fn(a, ?b, ?c) c
        \\ f(1)
    , "none");
    try t.topNumber(
        \\ const f = fn(a, ?b, ?c) c
        \\ f(1, :no, 42)
    , 42);
    try t.topAtom(
        \\ const f = fn(?a, ?b) a
        \\ f()
    , "none");
}

test "optional params arity errors" {
    try t.expectSemanticError(
        \\ const f = fn(a, ?b) a
        \\ f()
    );
    try t.expectSemanticError(
        \\ const f = fn(a, ?b) a
        \\ f(1, 2, 3)
    );
}

test "optional params with typed function" {
    try t.topAtom(
        \\ const f = fn(a: number, ?b) b
        \\ f(42)
    , "none");
    try t.topNumber(
        \\ const f = fn(a: number, ?b) a + (b orelse 0)
        \\ f(3, 7)
    , 10);
}

//
// module system
//

test "module import auto-binds filename" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "mymod.rv", .data = "const x = 42\nx\n" },
    });
    defer m.deinit();
    try t.topNumberInDir(m.dir,
        \\ import "./mymod"
        \\ mymod
    , 42);
}

test "module import with custom name" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "mymod.rv", .data = "const x = 7\nx\n" },
    });
    defer m.deinit();
    try t.topNumberInDir(m.dir,
        \\ import { m = "./mymod" }
        \\ m
    , 7);
}

test "module pub exports are accessible as fields" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "lib.rv", .data =
        \\ pub const x = 42
        \\ pub fn y(n) n * 2
        \\ const secret = "hidden"
        },
    });
    defer m.deinit();
    try t.topNumberInDir(m.dir,
        \\ const lib = import "./lib"
        \\ lib.y(lib.x)
    , 84);
}

test "module non-pub values are not exported" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "lib.rv", .data =
        \\ pub const visible = 42
        \\ const hidden = 99
        },
    });
    defer m.deinit();
    try t.topNumberInDir(m.dir,
        \\ const lib = import "./lib"
        \\ lib.visible
    , 42);
}

test "cross-module macro injection works" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "macros.rv", .data =
        \\ pub macro double! `%e:expr` `%e * 2`
        },
    });
    defer m.deinit();
    try t.topNumberInDir(m.dir,
        \\ import "./macros"
        \\ macros.double!(21)
    , 42);
}

test "non-pub macro is not injected" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "macros.rv", .data =
        \\ macro hidden! `%e:expr` `42`
        \\ pub macro visible! `%e:expr` `%e`
        },
    });
    defer m.deinit();
    try t.topNumberInDir(m.dir,
        \\ import "./macros"
        \\ macros.visible!(99)
    , 99);
    // non-pub macros are not injected, so the call never expands:
    // unknown macro is a compile error, not a runtime one
    try t.expectExpandErrorInDir(m.dir,
        \\ import "./macros"
        \\ macros.hidden!(21)
    , "unknown macro `macros.hidden!`");
}

test "cross-module proc macro injection works" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "procs.rv", .data =
        \\ pub proc add_one!(iter) do
        \\   let n = iter:next()
        \\   {{:binary, :add, n, {:number, 1}}}
        \\ end
        },
    });
    defer m.deinit();
    try t.topNumberInDir(m.dir,
        \\ import "./procs"
        \\ procs.add_one!(41)
    , 42);
}

test "const x = import \"foo\" with different names binds both" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "mymod.rv", .data = "pub const val = 42\n" },
    });
    defer m.deinit();
    try t.topNumberInDir(m.dir,
        \\ const x = import "./mymod"
        \\ x.val
    , 42);
}

test "import of non-existent file reports runtime error" {
    var m = try t.TmpMod.init(&.{});
    defer m.deinit();
    try t.expectRuntimeErrorInDir(m.dir,
        \\ import "./nonexistent"
        \\ nonexistent
    , .ModuleNotFound);
}

test "import empty module does not crash" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "empty.rv", .data = "" },
    });
    defer m.deinit();
    try t.topNumberInDir(m.dir,
        \\ import "./empty"
        \\ 42
    , 42);
}

test "import in function body binds correctly" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "helper.rv", .data = "pub const val = 99\n" },
    });
    defer m.deinit();
    try t.topNumberInDir(m.dir,
        \\ fn get_val() do
        \\   import "./helper"
        \\   helper.val
        \\ end
        \\ get_val()
    , 99);
}

test "pub type alias from imported module is available" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "types.rv", .data =
        \\ pub type UserId = int
        \\ pub fn greet(id: UserId) id
        },
    });
    defer m.deinit();
    try t.topNumberInDir(m.dir,
        \\ import "./types"
        \\ const x: UserId = 42
        \\ types.greet(x)
    , 42);
}

test "non-pub type alias in imported module does not pollute importer" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "priv_types.rv", .data =
        \\ type Hidden = int
        \\ pub const val = 42
        },
    });
    defer m.deinit();
    try t.topNumberInDir(m.dir,
        \\ import "./priv_types"
        \\ priv_types.val
    , 42);
}

test "pub type alias referencing another type alias from same module" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "chain.rv", .data =
        \\ pub type Id = int
        \\ pub type Alias = Id
        \\ pub fn take(n: Alias) n
        },
    });
    defer m.deinit();
    try t.topNumberInDir(m.dir,
        \\ import "./chain"
        \\ chain.take(42)
    , 42);
}

test "pub type alias works in type annotation after import" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "alias_mod.rv", .data =
        \\ pub type Code = int
        \\ pub fn lookup(c: Code) c
        },
    });
    defer m.deinit();
    try t.topNumberInDir(m.dir,
        \\ import "./alias_mod"
        \\ const x: Code = 99
        \\ alias_mod.lookup(x)
    , 99);
}

test "module with only non-pub items compiles and imports" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "priv.rv", .data = "const secret = 42\n" },
    });
    defer m.deinit();
    try t.topNumberInDir(m.dir,
        \\ import "./priv"
        \\ 1
    , 1);
}

test "pub import { x = \"a\" } re-exports module" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "inner.rv", .data = "pub const val = 42\n" },
        .{ .path = "outer.rv", .data =
        \\ pub import { inner = "./inner" }
        },
    });
    defer m.deinit();
    try t.topNumberInDir(m.dir,
        \\ const outer = import "./outer"
        \\ outer.inner.val
    , 42);
}

test "pub import \"foo\" at statement level re-exports" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "inner.rv", .data = "pub const val = 42\n" },
        .{ .path = "outer.rv", .data =
        \\ pub import "./inner"
        },
    });
    defer m.deinit();
    try t.topNumberInDir(m.dir,
        \\ const outer = import "./outer"
        \\ outer.inner.val
    , 42);
}

test "multi-import with two entries" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "alpha.rv", .data = "pub const a = 1\n" },
        .{ .path = "beta.rv", .data = "pub const b = 2\n" },
    });
    defer m.deinit();
    try t.topNumberInDir(m.dir,
        \\ import { x = "./alpha", y = "./beta" }
        \\ x.a + y.b
    , 3);
}

test "import inside do block binds correctly" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "helper.rv", .data = "pub const val = 7\n" },
    });
    defer m.deinit();
    try t.topNumberInDir(m.dir,
        \\ do
        \\   import "./helper"
        \\   helper.val
        \\ end
    , 7);
}

test "import with relative path works" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "sub_rel.rv", .data = "pub const val = 42\n" },
    });
    defer m.deinit();
    try t.topNumberInDir(m.dir,
        \\ import "./sub_rel"
        \\ sub_rel.val
    , 42);
}

test "circular import does not hang" {
    return error.SkipZigTest; // noisy
}

test "transitive pub import through re-export chain" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "leaf.rv", .data = "pub const deep = 99\n" },
        .{ .path = "middle.rv", .data = "pub import \"./leaf\"\npub const mid = 50\n" },
    });
    defer m.deinit();
    try t.topNumberInDir(m.dir,
        \\ import "./middle"
        \\ middle.leaf.deep + middle.mid
    , 149);
}

test "same file imported under multiple names" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "shared.rv", .data = "pub const v = 7\n" },
    });
    defer m.deinit();
    try t.topNumberInDir(m.dir,
        \\ import { a = "./shared", b = "./shared" }
        \\ a.v + b.v
    , 14);
}

test "import with absolute path" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "absm.rv", .data = "pub const x = 42\n" },
    });
    defer m.deinit();
    const abs_path = try std.fmt.allocPrint(alloc, "{s}/absm.rv", .{m.dir});
    defer alloc.free(abs_path);

    const source = try std.fmt.allocPrint(alloc, "import '{s}'\nabsm.x", .{abs_path});
    defer alloc.free(source);

    var result = try t.topResult(source, m.dir);
    defer result.deinit();
    const actual = try result.value.asNumber();
    if (@abs(@as(f64, 42) - actual) > 0.000000001)
        return error.TestExpectedEqual;
}

test "@exports shadow in module is caught at compile time" {
    return error.SkipZigTest; // noisy
}

test "let import binding is rejected" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "mod.rv", .data = "pub const x = 42\n" },
    });
    defer m.deinit();
    try t.expectCompileErrorInDir(m.dir,
        \\ let m = import "./mod"
        \\ m.x
    );
}

test "duplicate import name is rejected at compile time" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "mod.rv", .data = "pub const v = 1\n" },
    });
    defer m.deinit();
    try t.expectCompileErrorInDir(m.dir,
        \\ import "./mod"
        \\ import "./mod"
    );
}

test "labeled loops break from outer loop via label" {
    try t.topNumber(
        \\ let r = 0
        \\ loop/a do
        \\   for i in 0..5 do
        \\     if i == 3 break/a(99)
        \\     r += 1
        \\   end
        \\ end
        \\ r
    , 3);
    try t.topNumber(
        \\ let r = 0
        \\ while/a 1 == 1 do
        \\   r += 1
        \\   if r == 5 break/a(r)
        \\ end
    , 5);
    try t.topNumber(
        \\ for/a i in 0..10 do
        \\   if i == 4 break/a(i * 10)
        \\ end
    , 40);
}

test "labeled continue targets outer while loop" {
    try t.topNumber(
        \\ let r = 0
        \\ let i = 0
        \\ while/a i < 5 do
        \\   i += 1
        \\   if i == 3 continue/a
        \\   r += i
        \\ end
        \\ r
    , 12);
}

test "labeled do block" {
    try t.topNumber(
        \\ do/a
        \\   break/a(42)
        \\   0
        \\ end
    , 42);
    try t.topAtom(
        \\ do/a
        \\   let x = 10
        \\   if x > 5 break/a(:ok)
        \\   :never
        \\ end
    , "ok");
    try t.topNumber(
        \\ let x = do/a
        \\   let y = 2
        \\   break/a(y * 21)
        \\ end
        \\ x
    , 42);
}

test "labeled loop: unlabeled break targets innermost" {
    try t.topNumber(
        \\ let r = 0
        \\ loop/a do
        \\   for i in 0..3 do
        \\     if i == 2 break :nil
        \\     r += 1
        \\   end
        \\   break :nil
        \\ end
        \\ r
    , 2);
}

test "labeled break/continue label not found errors" {
    try t.expectCompileError("break/no_such :nil", .UnsupportedSyntax);
    try t.expectCompileError("continue/no_such", .UnsupportedSyntax);
}

test "labeled goto unlabeled break outside loop" {
    try t.expectCompileError("break :nil", .UnsupportedSyntax);
    try t.expectCompileError("continue", .UnsupportedSyntax);
}

test "labeled break with unknown label is rejected" {
    try t.expectCompileError(
        \\ loop do
        \\   break/no_such :nil
        \\ end
    , .UnsupportedSyntax);
}

test "import typed function reports arg type mismatch" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "adder.rv", .data =
        \\ pub fn add(a: int, b: int) a + b
        },
    });
    defer m.deinit();
    // correct types work
    try t.topNumberInDir(m.dir,
        \\ import "./adder"
        \\ adder.add(1, 2)
    , 3);
    // wrong type should fail at compile time
    try t.expectCompileErrorInDir(m.dir,
        \\ import "./adder"
        \\ adder.add("hi", 2)
    );
}

test "import typed function with string param passes type check" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "echo.rv", .data =
        \\ pub fn echo(s: string) s
        },
    });
    defer m.deinit();
    try t.topStringInDir(m.dir,
        \\ import "./echo"
        \\ echo.echo("ok")
    , "ok");
}

test "import typed function with no type annotations falls through" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "plain.rv", .data =
        \\ pub fn double(n) n * 2
        },
    });
    defer m.deinit();
    try t.topNumberInDir(m.dir,
        \\ import "./plain"
        \\ plain.double(21)
    , 42);
}

//
// typed lowering through the vm; integration coverage for the
// type universe, kept with the language suite instead of types.zig
//
const types = lang.compiler.types;

//
// type system
//

test "typed num/string bindings accept and reject" {
    try t.topNumber(
        \\ let x: num = 42
        \\ x
    , 42);
    try t.expectSemanticError(
        \\ let x: num = "hello"
    );
    try t.expectSemanticError(
        \\ let x: string = 42
    );
}

test "typed binding table<num> accepts positional table literal" {
    try t.topNumber(
        \\ let nums: table<num> = { 1, 2, 3 }
        \\ 1
    , 1);
}

test "typed binding table<string, num> accepts keyed table literal" {
    try t.topNumber(
        \\ let pairs: table<string, num> = { a = 1, b = 2 }
        \\ 1
    , 1);
}

test "records accept matching shapes" {
    try t.topNumber(
        \\ let u: { name: string, age: num } = { name = "alice", age = 30 }
        \\ u.age
    , 30);
    try t.topString(
        \\ let u: { name: string } = { name = "alice", age = 30 }
        \\ u.name
    , "alice");
    try t.topNumber(
        \\ let u: { name: string, age: num } = { name = "alice", age = 30 }
        \\ u.age + 12
    , 42);
    try t.topString(
        \\ fn greet(u: { name: string }) u.name
        \\ greet({ name = "bob", age = 40 })
    , "bob");
    try t.topNumber(
        \\ type User = { name: string, age: num }
        \\ let u: User = { name = "alice", age = 30 }
        \\ u.age
    , 30);
    try t.topString(
        \\ let t: { user: { name: string } } = { user = { name = "alice" } }
        \\ t.user.name
    , "alice");
    try t.topNumber(
        \\ let u: {} = { a = 1 }
        \\ 1
    , 1);
    try t.topNumber(
        \\ let t0: {number, number} = {1, 2}
        \\ 1
    , 1);
    try t.topString(
        \\ let t1: {number, number, name: string} = {1, 2, name = "me"}
        \\ t1.name
    , "me");
    try t.topAtom(
        \\ let tb: {number, number, :err, atom} = {1, 2, :err, :NotFound}
        \\ :NotFound
    , "NotFound");
}

test "records reject mismatched shapes" {
    try t.expectSemanticError(
        \\ let u: { name: string, age: num } = { name = "alice" }
    );
    try t.expectSemanticError(
        \\ let u: { name: string } = { name = 42 }
    );
    try t.expectSemanticError(
        \\ let u: { name: string } = { name = "alice" }
        \\ let x: num = u.name
    );
    try t.expectSemanticError(
        \\ fn greet(u: { name: string, age: num }) u.name
        \\ greet({ name = "bob" })
    );
    try t.expectSemanticError(
        \\ let t: { user: { name: string } } = { user = { name = 42 } }
    );
    try t.expectSemanticError(
        \\ let a: { name: num } = {}
    );
    try t.expectSemanticError(
        \\ let a: { name: num } = { 1, 2, 3 }
    );
    try t.expectSemanticError(
        \\ let a: {number, string} = {1, 2}
    );
    try t.expectSemanticError(
        \\ let t1: {number, number, name: string} = {1, 2}
    );
}

test "fn alias enforces arity at call sites" {
    try t.expectSemanticError(
        \\ type F = fn(num, num) -> num
        \\ fn apply(f: F) f(1)
    );
}

test "unknown table field reads are errors" {
    try t.expectSemanticError(
        \\ let t = { name = "me" }
        \\ t.a
    );
    try t.expectSemanticError(
        \\ let t = { name = "me" }
        \\ t[:a]
    );
    try t.expectSemanticError(
        \\ let t = { name = "me" }
        \\ t["a"]
    );
}

test "assigned and dynamic fields are not flagged" {
    // static assign extends the known shape
    try t.topNumber(
        \\ let t = {}
        \\ t.a = 41
        \\ t.a
    , 41);
    // dynamic keys make the shape unknown: optimistic, no error
    try t.topNumber(
        \\ const k = "a"
        \\ const t = {}
        \\ t[k] = 41
        \\ t[k]
    , 41);
    // mutations through closures escape analysis: optimistic, no error
    try t.topNumber(
        \\ const out = {}
        \\ const f = fn(k) out[k] = 1
        \\ f("a")
        \\ out["a"]
    , 1);
    // foreign tables have unknown shapes: optimistic, no error
    try t.topNumber(
        \\ fn f(t: table) t.a
        \\ f({a = 41})
    , 41);
}

test "typed function params accept correct types" {
    try t.topNumber(
        \\ const add = fn(a: num, b: num) a + b
        \\ add(3, 4)
    , 7);
}

test "typed function rejects wrong arg types" {
    try t.expectSemanticError(
        \\ const add = fn(a: num, b: num) a + b
        \\ add(3, "wrong")
    );
    try t.expectSemanticError(
        \\ const add = fn(a: num, b: num) a + b
        \\ add("wrong", 4)
    );
}

test "atom union alias accepts literal and alias value in calls" {
    try t.topAtom(
        \\ type A = :one | :two
        \\ fn pick(how: A) -> any do
        \\   how
        \\ end
        \\ let pred: A = :one
        \\ pick(pred)
    , "one");

    try t.topAtom(
        \\ type A = :one | :two
        \\ fn pick(how: A) -> any do
        \\   how
        \\ end
        \\ let pred: A = :one
        \\ pick(:two)
    , "two");
}

test "binary num + num emits add" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let a: num = 5
        \\ let b: num = 3
        \\ a + b
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add) saw_add = true;
    }
    try std.testing.expect(saw_add);
}

test "negate num emits negate" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let x: num = 5
        \\ let y = -x
        \\ y
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_neg = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .negate) saw_neg = true;
    }
    try std.testing.expect(saw_neg);
}

test "comparison num == num emits eq_int" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let a: num = 5
        \\ let b: num = 5
        \\ a == b
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_eq = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .eq_int) saw_eq = true;
    }
    try std.testing.expect(saw_eq);
}

test "untyped code still works" {
    try t.topNumber("1 + 2 * 3", 7);
    try t.topNumber(
        \\ let x = 10
        \\ x + 5
    , 15);
    try t.topString(
        \\ let s = "hello"
        \\ s
    , "hello");
}

test "nested function with typed params" {
    try t.topNumber(
        \\ const outer = fn(x: num) do
        \\     const inner = fn(y: num) y * 2
        \\     inner(x) + 1
        \\ end
        \\ outer(5)
    , 11);
}

test "function call with multiple typed params" {
    try t.topNumber(
        \\ const calc = fn(a: num, b: num, c: num) do
        \\     a + b + c
        \\ end
        \\ calc(1, 2.5, 3)
    , 6.5);
}

test "return type validation accepts correct type" {
    try t.topNumber(
        \\ const get_num = fn() -> num do
        \\     return 42
        \\ end
        \\ get_num()
    , 42);
}

//
// typed const bindings
//
test "typed const and global bindings accept and reject" {
    try t.topNumber(
        \\ const x: num = 42
        \\ x
    , 42);
    try t.topString(
        \\ const s: string = "hello"
        \\ s
    , "hello");
    try t.expectSemanticError(
        \\ const x: num = "hello"
    );
    try t.topNumber(
        \\ global x: num = 42
        \\ x
    , 42);
}

//
// type alias at call sites
//
test "type aliases work in function params" {
    try t.topNumber(
        \\ type MyInt = num
        \\ const double = fn(x: MyInt) -> MyInt x * 2
        \\ double(21)
    , 42);
    try t.topNumber(
        \\ type Num = num
        \\ const add = fn(a: Num, b: Num) -> num a + b
        \\ add(3, 4)
    , 7);
}

test "type alias used in binding" {
    try t.topString(
        \\ type Name = string
        \\ let s: Name = "alice"
        \\ s
    , "alice");
}

test "type alias rejects type not in union" {
    try t.expectSemanticError(
        \\ type MyInt = num
        \\ const x: MyInt = "string"
    );
}

//
// named union variants with payloads
//
test "named union variants match to ok and err" {
    try t.topAtom(
        \\ type Result = :ok | :err
        \\ match 0
        \\ | 0 => :ok
        \\ | _ => :err
    , "ok");
    try t.topAtom(
        \\ type Result = :ok | :err
        \\ match 1
        \\ | 0 => :ok
        \\ | _ => :err
    , "err");
}

//
// return type validation
//
test "return type mismatch detects wrong explicit return" {
    try t.expectSemanticError(
        \\ fn get() -> num do
        \\     return "hello"
        \\ end
    );
}

test "explicit returns match the return type" {
    try t.topNumber(
        \\ fn get() -> num do
        \\     return 42
        \\ end
        \\ get()
    , 42);
}

//
// if/else branch type unification
//
test "if/else typed branches unify" {
    try t.topNumber(
        \\ let x: num = 5
        \\ let y = if x > 0 10 else 20
        \\ y
    , 10);
    try t.topString(
        \\ let x: num = 0
        \\ let y = if x > 0 "pos" else "non-pos"
        \\ y
    , "non-pos");
    try t.topNumber(
        \\ let x: num = 5
        \\ let y = unless x > 0 10 else 20
        \\ y
    , 20);
    try t.topString(
        \\ let x: num = 0
        \\ let y = unless x > 0 "pos" else "non-pos"
        \\ y
    , "pos");
}

//
// string indexing
//
test "string indexing and slicing" {
    try t.topString(
        \\ let s: string = "hello"
        \\ s[0]
    , "h");
    try t.topString(
        \\ let s: string = "hello"
        \\ s[1..4]
    , "ell");
    try t.topString(
        \\ let s: string = "abcdef"
        \\ s[5..-1..1]
    , "fedc");
    try t.topString(
        \\ let s: string = "hello"
        \\ s[..4]
    , "hell");
    try t.topString(
        \\ let s: string = "hello"
        \\ s[2..]
    , "llo");
    try t.topString(
        \\ let s: string = "hello"
        \\ s[..]
    , "hello");
    try t.topString(
        \\ let s: string = "abcdef"
        \\ s[0..2..5]
    , "ace");
    try t.topString(
        \\ let s: string = "abc"
        \\ s[2..2]
    , "");
}

test "string index out of range errors" {
    try t.expectRuntimeError(
        \\ let s: string = "hello"
        \\ s[5]
    , .TypeError);
    try t.expectRuntimeError(
        \\ let s: string = "hello"
        \\ s[100]
    , .TypeError);
    try t.expectRuntimeError(
        \\ let s: string = ""
        \\ s[0]
    , .TypeError);
    try t.expectRuntimeFailureWithMessage(
        \\ let s: string = "hello"
        \\ s[5]
    , .TypeError, "string index 5 out of range (len 5)");
}

test "string negative index accesses last character" {
    try t.topString(
        \\ let s: string = "hello"
        \\ s[-1]
    , "o");
    try t.topString(
        \\ let s: string = "x"
        \\ s[-1]
    , "x");
}
//
// any type accepts everything
//
test "any accepts num, table, and bindings" {
    try t.topNumber(
        \\ const id = fn(x: any) x
        \\ id(42)
    , 42);
    try t.topNumber(
        \\ const get = fn(t: any, k: any) t[k]
        \\ get({x = 99}, :x)
    , 99);
    try t.topNumber(
        \\ let x: any = 42
        \\ let y: any = "str"
        \\ let z: any = {a = 1}
        \\ x
    , 42);
}

//
// block type propagation
//
test "block types propagate last expr and reject mismatch" {
    try t.topNumber(
        \\ let x: num = do
        \\     let a = 1
        \\     let b = 2
        \\     a + b
        \\ end
        \\ x
    , 3);
    try t.expectSemanticError(
        \\ let x: num = do
        \\     "hello"
        \\ end
    );
}

//
// chained typed ops preserve specialization
//
test "chained typed math emits add and mul" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let a: num = 1
        \\ let b: num = 2
        \\ let c: num = 3
        \\ a + b * c
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add = false;
    var saw_mul = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add) saw_add = true;
        if (inst.op == .mul) saw_mul = true;
    }
    try std.testing.expect(saw_add);
    try std.testing.expect(saw_mul);
}

//
// type alias union with multiple atom variants
//
test "multi-atom union alias in match" {
    try t.topAtom(
        \\ type Color = :red | :green | :blue
        \\ match :red
        \\ | :red => :green
        \\ | :green => :red
        \\ | _ => :blue
    , "green");
}

test "multi-atom union fn param accepts valid atom" {
    try t.topAtom(
        \\ type Color = :red | :green
        \\ fn pick(c: Color) c
        \\ pick(:green)
    , "green");
}

//
// void / nil type
//
test "nil and void bindings return nil" {
    try t.topNil(
        \\ fn nothing() do :nil end
        \\ nothing()
    );
    try t.topNil(
        \\ let x: any = :nil
        \\ x
    );
}

test "assignments respect annotations" {
    try t.expectSemanticError(
        \\ let x: num = 5
        \\ x = "hello"
    );
    try t.topString(
        \\ let x = 5
        \\ x = "hello"
        \\ x
    , "hello");
}

//
// bool type
//
test "bool bindings accept bool and stay bool" {
    try t.topTrue(
        \\ let b: bool = 1 == 1
        \\ b
    );
    try t.expectSemanticError(
        \\ let b: bool = 42
    );
    try t.topFalse(
        \\ let b: bool = not (1 == 1)
        \\ b
    );
}

test "implicit return validates block-local variable type" {
    try t.expectSemanticError(
        \\ fn f() -> num do
        \\   let x = "hello"
        \\   x
        \\ end
    );
}

test "loop expression infers correct return type" {
    try t.expectSemanticError(
        \\ fn f() -> string do
        \\   for i in 0..10 do i end
        \\ end
    );
}

test "upvalue assignment respects type annotation" {
    try t.expectSemanticError(
        \\ const outer = fn() do
        \\     let x: num = 5
        \\     const inner = fn() do x = "hello" end
        \\ end
    );
}

test "dynamic callee validates argument types" {
    try t.expectCompileError(
        \\ const f: function = fn(x: num) x
        \\ f("hello")
    , .ParseError);
}
test "for loop expression produces loop atom" {
    try t.topAtom(
        \\ fn f() do
        \\   for i in 0..5 do i end
        \\ end
        \\ f()
    , "loop");
    try t.topNumber(
        \\ fn f() -> num do
        \\   for/l i in 0..5 do
        \\     if i == 4 break/l(i)
        \\   end
        \\ end
        \\ f()
    , 4);
}

test "type alias gets unaliased" {
    try t.topTrue(
        \\ type Als =
        \\       {:aa, num}
        \\     | {:bb, num}
        \\
        \\ let x: Als = {:aa, 55}
        \\ let y: Als = {:bb, 100.1}
        \\
        \\ x[1] + y[1] == 155.1
    );
}
test "comp block infers num from literal" {
    var vm = try VM.init(testRuntime());
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
    // the panic arm is `never`: the match result is the `:ok` payload (num),
    // so `?` on it is rejected as a non-result (it would pass as `.any`)
    try t.expectSemanticError(
        \\ type Res = {:ok, num} | {:err, string}
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
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ type Res = {:ok, num} | {:err, string}
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
    // `v` narrows to num so `v + 1` emits add_imm
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ type Res = {:ok, num} | {:err, string}
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
    // `v: num` narrows even with an `any` subject
    //   ; so `v + 1` emits add_imm
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let x: any = {41}
        \\ match x
        \\ | {v: num} => v + 1
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

test "non-exhaustive match" {
    try t.expectSemanticError(
        \\ let n: num = 1
        \\ let x: num = match n
        \\ | 1 => 2
        \\ | 2 => 3
    );

    // partial result match carries :nil in its type
    try t.expectSemanticError(
        \\ type Res = {:ok, num} | {:err, string}
        \\ let x: Res = {:ok, 42}
        \\ let y: num = match x
        \\ | {:ok, v} => v
    );

    // wildcard match has no :nil
    try t.topNumber(
        \\ let n: num = 5
        \\ let x: num = match n
        \\ | 1 => 10
        \\ | _ => 20
        \\ x
    , 20);

    // exhaustive bool match has no :nil
    try t.topNumber(
        \\ let b = 1 == 1
        \\ let x: num = match b
        \\ | :true => 10
        \\ | :false => 20
        \\ x
    , 10);

    // exhaustive result match has no :nil
    try t.topNumber(
        \\ type Res = {:ok, num} | {:err, string}
        \\ let x: Res = {:ok, 42}
        \\ let y: num = match x
        \\ | {:ok, v} => v
        \\ | {:err, _} => 0
        \\ y
    , 42);

    // ascribed arm can cover the subject
    try t.topNumber(
        \\ let n: num = 5
        \\ let x: num = match n
        \\ | v: num => v
        \\ x
    , 5);

    // exhaustive bool match is precise, not any
    // `let s: string` only fails when x is exactly num; any would compile
    try t.expectSemanticError(
        \\ let b = 1 == 1
        \\ let x: num = match b
        \\ | :true => 10
        \\ | :false => 20
        \\ let s: string = x
    );

    // exhaustive result match is precise, not any
    try t.expectSemanticError(
        \\ type Res = {:ok, num} | {:err, string}
        \\ let x: Res = {:ok, 42}
        \\ let y = match x
        \\ | {:ok, v} => v
        \\ | {:err, _} => 0
        \\ let s: string = y
    );

    // never arm does not widen match to any
    try t.expectSemanticError(
        \\ type R = {:ok, num} | {:err, string}
        \\ let x: R = {:ok, 1}
        \\ let a = match x
        \\ | {:ok, v} => v
        \\ | {:err, e} => panic()
        \\ let s: string = a
    );

    // any payload propagates through match
    // annotation wins over the literal:
    // x may later hold {:ok, "str"},
    //   so v is any and the match is any
    //
    // narrowing to num would be unsound
    try t.topNumber(
        \\ type R = {:ok, any} | {:err, string}
        \\ let x: R = {:ok, 1}
        \\ let a = match x
        \\ | {:ok, v} => v
        \\ | {:err, e} => panic()
        \\ a
    , 1);

    // non-exhaustive match still yields :nil at runtime
    try t.topNil(
        \\ match 99
        \\ | 1 => 2
        \\ | 2 => 3
    );
}

test "non exhaustiveness warnings" {
    // non-exhaustive match warns w uncovered tag
    try t.expectWarning(
        \\ type Res = {:ok, num} | {:err, string}
        \\ let x: Res = {:ok, 42}
        \\ match x
        \\ | {:ok, v} => v
    , ":err");

    // partial literal match warns for subject type
    try t.expectWarning(
        \\ let n: num = 1
        \\ match n
        \\ | 1 => 2
    , "number");

    // exhaustive match warns nothing
    try t.expectNoWarning(
        \\ type Res = {:ok, num} | {:err, string}
        \\ let x: Res = {:ok, 42}
        \\ match x
        \\ | {:ok, v} => v
        \\ | {:err, _} => 0
    );

    // wildcard match warns nothing"
    try t.expectNoWarning(
        \\ let n: num = 1
        \\ match n
        \\ | 1 => 2
        \\ | _ => 3
    );
}

test "dead match arms" {
    // wildcard first cuts later arms off
    try t.expectWarning(
        \\ let n: num = 1
        \\ match n
        \\ | _ => 1
        \\ | 1 => 2
    , "unreachable");

    // duplicate literal
    try t.expectWarning(
        \\ let n: num = 1
        \\ match n
        \\ | 1 => 10
        \\ | 1 => 20
        \\ | _ => 0
    , "unreachable");

    // covered tag
    try t.expectWarning(
        \\ type Res = {:ok, num} | {:err, string}
        \\ let x: Res = {:ok, 42}
        \\ match x
        \\ | {:ok, _} => 1
        \\ | {:ok, v} => v
        \\ | {:err, _} => 0
    , "unreachable");

    // bool-exhaustive arms kill the wildcard
    try t.expectWarning(
        \\ let b = 1 == 1
        \\ match b
        \\ | :true => 1
        \\ | :false => 2
        \\ | _ => 3
    , "unreachable");

    // disjoint pattern never fires
    try t.expectWarning(
        \\ let n: num = 1
        \\ match n
        \\ | :ok => 1
        \\ | _ => 2
    , "never matches");
}

test "comma arms" {
    try t.topString(
        \\ match 2
        \\ | 1, 2 => "hit"
        \\ | _ => "miss"
    , "hit");
    try t.topString(
        \\ match 3
        \\ | 1, 2 => "hit"
        \\ | _ => "miss"
    , "miss");
    // share bindings
    try t.topString(
        \\ type R = {:ok, string} | {:err, string}
        \\ let x: R = {:err, "boom"}
        \\ match x
        \\ | {:ok, v}, {:err, v} => v
        \\ | _ => "none"
    , "boom");
    // comma arm with guard
    try t.topString(
        \\ match 7
        \\ | 1, 2 => "low"
        \\ | v when v > 5 => "high"
        \\ | _ => "mid"
    , "high");
}

test "match warning codes" {
    try t.expectWarningCode(
        \\ let n: num = 1
        \\ match n
        \\ | _ => 1
        \\ | 1 => 2
    , "unreachable-match-arm");

    try t.expectWarningCode(
        \\ let n: num = 1
        \\ match n
        \\ | :ok => 1
        \\ | _ => 2
    , "impossible-match-arm");

    try t.expectWarningCode(
        \\ type Res = {:ok, num} | {:err, string}
        \\ let x: Res = {:ok, 42}
        \\ match x
        \\ | {:ok, v} => v
    , "non-exhaustive-match");
}

test "match suggestion" {
    // uncovered tag becomes a named arm, not a wildcard
    try t.expectSuggestion(
        \\ type Res = {:ok, num} | {:err, string}
        \\ let x: Res = {:ok, 42}
        \\ match x
        \\ | {:ok, v} => v
    , "| {:err, _} => :nil");

    // the suggested arm closes the warning
    try t.expectNoWarning(
        \\ type Res = {:ok, num} | {:err, string}
        \\ let x: Res = {:ok, 42}
        \\ match x
        \\ | {:ok, v} => v
        \\ | {:err, _} => :nil
    );

    // infinite domains fall back to a wildcard arm
    try t.expectSuggestion(
        \\ let n: num = 1
        \\ match n
        \\ | 1 => 2
    , "| _ => :nil");

    try t.expectNoWarning(
        \\ type Res = {:ok, num} | {:err, string}
        \\ let x: Res = {:ok, 42}
        \\ match x
        \\ | {:ok, v} => v
        \\ | {:err, _} => 0
    );
}

test "error codes" {
    // type mismatch carries its code
    try t.expectErrorCode(
        \\ let x: num = "hi"
    , "type-mismatch");

    // unknown name carries its code
    try t.expectErrorCode("aaa\n", "unknown-name");
}

test "return type propagation: const binding with annotated fn" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ const add = fn(a: num, b: num) a + b
        \\ let x = add(3, 4)
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

test "return type propagation: fn five() 5" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn five() 5
        \\ let x = five()
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

test "annotated function return type propagates to caller via pointer" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn add(a: num, b: num) a + b
        \\ let x = add(3, 4)
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

//
// generics / type_var tests
//

fn testRuntime() revo.Runtime {
    return .{
        .alloc = std.testing.allocator,
        .io = std.testing.io,
        .diag_alloc = std.testing.allocator,
        .diag_arena = null,
    };
}

test "types: type_var equality" {
    const TI = lang.compiler.types.TypeInfo;
    const a = TI{ .tag = .{ .type_var = "T" } };
    const b = TI{ .tag = .{ .type_var = "T" } };
    const c = TI{ .tag = .{ .type_var = "U" } };
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
    try std.testing.expect(!a.eql(.{ .tag = .number }));
}

test "types: type_var coercion" {
    const tv = types.TypeInfo{ .tag = .{ .type_var = "T" } };
    try std.testing.expect(types.canCoerce(tv, .{ .tag = .number }));
    try std.testing.expect(types.canCoerce(.{ .tag = .number }, tv));
    try std.testing.expect(types.canCoerce(tv, .{ .tag = .any }));
    try std.testing.expect(types.canCoerce(.{ .tag = .any }, tv));
    try std.testing.expect(types.canCoerce(tv, tv));
}

test "substituteTypeParams resolves vars and sigs" {
    var subst = std.StringHashMap(types.TypeInfo).init(alloc);
    defer subst.deinit();

    const unbound = try types.substituteTypeParams(alloc, types.TypeInfo{ .tag = .{ .type_var = "T" } }, subst);
    try std.testing.expect(unbound.eql(.{ .tag = .any }));

    try subst.put("T", .{ .tag = .number });
    const bound = try types.substituteTypeParams(alloc, types.TypeInfo{ .tag = .{ .type_var = "T" } }, subst);
    try std.testing.expect(bound.eql(.{ .tag = .number }));

    const sig = try alloc.create(types.FunctionSignature);
    sig.* = .{
        .params = &.{types.TypeInfo{ .tag = .{ .type_var = "T" } }},
        .return_type = types.TypeInfo{ .tag = .{ .type_var = "T" } },
        .param_names = &.{"x"},
    };
    const input = types.TypeInfo{ .tag = .{ .function = sig } };
    const result = try types.substituteTypeParams(alloc, input, subst);
    try std.testing.expect(result.tag == .function);
    try std.testing.expect(result.tag.function.params.len == 1);
    try std.testing.expect(result.tag.function.params[0].eql(.{ .tag = .number }));
    try std.testing.expect(result.tag.function.return_type.eql(.{ .tag = .number }));
    alloc.destroy(sig);
    alloc.free(result.tag.function.params);
    alloc.destroy(result.tag.function);
}

test "generics identity fn enables add_imm" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn id<T>(x: T) x
        \\ let y = id(42)
        \\ y + 1
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

test "generics identity fn with string compiles and runs" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn id<T>(x: T) x
        \\ id("hello")
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);
}

test "generics compound return type {:ok, T} propagates inner type" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn wrap<T>(x: T) -> {:ok, T} {:ok, x}
        \\ let r = wrap(42)
        \\ r[1] + 1
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);
}

test "generics multiple type params with table return compile" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn pair<T, U>(a: T, b: U) -> {T, U}
        \\ pair(1, "hi")
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);
}

test "generics non-inferrable type param (return-only) compiles" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn make<T>() 5
        \\ make()
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);
}

test "generics repeated type param works" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn same<T>(a: T, b: T) a
        \\ let x = same(42, 99)
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

test "explicit call-site type args resolve return types" {
    try t.topNumber(
        \\ fn make<T>() -> T 5
        \\ make<num>()
    , 5);
    try t.topNumber(
        \\ fn id<T>(x: T) -> T x
        \\ id<num>(42)
    , 42);
}

test "explicit type args work on dotted receivers" {
    try t.topNumber(
        \\ fn id<T>(x: T) -> T x
        \\ const m = {id = id}
        \\ m.id<num>(42)
    , 42);
}

test "unhugged brackets parse as comparison" {
    // `id <num>(42)` is `(id < num) > (42)`, not a generic call:
    // `num` is unbound either way, so this must be a semantic error
    // rather than evaluating to 42
    try t.expectSemanticError(
        \\ fn id<T>(x: T) -> T x
        \\ id <num>(42)
    );
}

test "return-only type param stays any without explicit args" {
    // T appears only in the return, so a bare call leaves it unbound (any)
    // and a string binding compiles; it still runs fine
    try t.topNumber(
        \\ fn make<T>(x) -> T return x
        \\ let y = make(1)
        \\ let s: string = y
        \\ y
    , 1);
    // shape-bound params still infer without any explicit args
    try t.expectSemanticError(
        \\ fn id<T>(x: T) x
        \\ let y = id(42)
        \\ let s: string = y
    );
}

test "implicit generics" {
    try t.topNumber(
        \\ fn v2_new(x, y) { x = x, y = y }
        \\ let t = v2_new(1, 2)
        \\ t.x + t.y
    , 3);
    try t.expectSemanticError(
        \\ fn v2_new(x, y) { x = x, y = y }
        \\ let t = v2_new(1, 2)
        \\ let s: string = t.x
    );
    try t.expectSemanticError(
        \\ fn v2_new(x, y) { x = x, y = y }
        \\ let u: { x: string } = v2_new(1, 2)
    );
    //
    // atom and string args keep precise types
    try t.topString(
        \\ fn v2_new(x, y) { x = x, y = y }
        \\ let t = v2_new(:hi, "str here")
        \\ t.y
    , "str here");
    try t.expectSemanticError(
        \\ fn v2_new(x, y) { x = x, y = y }
        \\ let t = v2_new(:hi, "str here")
        \\ let n: num = t.x
    );
    //
    // unannotated identity specializes return
    try t.topNumber(
        \\ fn id(x) x
        \\ let y = id(42)
        \\ y + 1
    , 43);
    try t.expectSemanticError(
        \\ fn id(x) x
        \\ let y = id(42)
        \\ let s: string = y
    );
    //
    // constructor field specializes"
    try t.topString(
        \\ fn Hi(field) { field = field, get_field = fn(self) self.field }
        \\ const t = Hi("hi")
        \\ t.field
    , "hi");
    try t.expectSemanticError(
        \\ fn Hi(field) { field = field, get_field = fn(self) self.field }
        \\ const t = Hi("hi")
        \\ let n: num = t.field
    );
}

//
// stdlib signatures flow from the semantic checker through the
// annotation bridge into the compiler
//

test "stdlib sigs: method return types reach the compiler" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ "abc":len() + 1
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

test "stdlib sigs: global return types reach the compiler" {
    // semantic knows cwd/read from the os iface; misuse that compiled
    // against .any now errors before codegen
    try t.expectSemanticError(
        \\ let x = cwd()
        \\ let n: num = x
    );
    try t.expectSemanticError(
        \\ let x = read({delimiter = :eof})
        \\ let n: num = x?
    );
}

test "stdlib sigs source fn shadows stdlib global" {
    try t.topNumber(
        \\ const cwd = fn(x: num) x + 1
        \\ cwd(41)
    , 42);
    try t.expectSemanticError(
        \\ const cwd = fn(x: num) x + 1
        \\ cwd("nope")
    );
}

test "stdlib sigs variadic global keeps accepting extra args" {
    try t.topString("fmt(\"%v\", 1, 2, 3)", "1");
    try t.expectSemanticError(
        \\ fmt()
    );
}

test "stdlib sigs untyped call still validates arg count" {
    try t.expectSemanticError(
        \\ cwd("nope", "more")
    );
}

test "stdlib sigs: module field calls resolve to spec sigs" {
    try t.topAtom("fs.exists?(\"/definitely/not/a/real/path_xyz\")", "false");
    try t.topNumber(
        \\ table.len({1, 2}) + 1
    , 3);
    try t.topTrue("let b: bool = fs.exists?(\"/tmp\")");
}

test "stdlib sigs: module result flows through match" {
    try t.topAtom(
        \\ let r = fs.open("/definitely/not/a/real/path_xyz")
        \\ match r | {:ok, f} => :found | {:err, e} => e
    , "FileNotFound");
}

test "stdlib sigs: local binding shadows stdlib module" {
    // `fs` here is a local table, not the module
    // no stdlib sig is applied, and the missing field fails at compile time
    // (it can never work, so no point waiting for runtime)
    // so this is EXACTLY what we want. it gets erased
    try t.expectSemanticError(
        \\ let fs = {}
        \\ fs.exists?("/tmp")
    );
}
test "stdlib sigs: orelse unwraps results" {
    try t.topTrue("fs.exists?(\"/tmp\")");
    try t.topNumber("{:err, \"boom\"} orelse 5", 5);
}

test "stdlib sigs: try rejects non-result unions" {
    // `?` on it is a lie
    try t.expectSemanticError(
        \\ "abc":find("b")?
    );
}

test "stdlib sigs: match narrows call-subject payloads" {
    // the subject is a call, not an ident: the payload still narrows to
    // bool, so the match result is bool (not a result) and `?` is rejected
    try t.expectSemanticError(
        \\ (match fs.open("/tmp")
        \\ | {:ok, v} => v
        \\ | {:err, e} => panic(e))?
    );
}

test "eu.rv: result types flow end to end" {
    // the predicate binds as bool, while result calls still bind as !T
    // and flow through match on both arms
    try t.topTrue(
        \\ let x: bool = fs.exists?("/tmp")
        \\ x
    );
    try t.topAtom(
        \\ let r = fs.open("/definitely/not/a/real/path_xyz")
        \\ match r | {:err, e} => e | _ => :found
    , "FileNotFound");
    try t.topAtom(
        \\ let x: {:ok, table} | {:err, any} = fs.open("/tmp")
        \\ match x | {:ok, t} => :found | {:err, e} => e
    , "found");
}

test "error-union sugar and the literal form are the same union" {
    // `!table` and `{:ok, table} | {:err, any}` are structurally identical, so
    // a value typed with one can be bound to a slot typed with the other
    try t.topAtom(
        \\ let x: {:ok, table} | {:err, any} = {:ok, {}}
        \\ let y: !table = x
        \\ match y | {:ok, t} => :found | {:err, e} => e
    , "found");
}

//
// ambient declares
//

test "declare typed const is usable in type positions" {
    try t.topNumber(
        \\ declare MAX_ITEMS = num
        \\ const x: MAX_ITEMS = 5
        \\ x
    , 5);
}

test "declare fn calls typecheck and run into undefined variable" {
    try t.expectRuntimeError(
        \\ declare lamp = fn(volume: num, label: string) -> bool
        \\ lamp(1, "x")
    , .UndefinedVariable);
}

test "declare fn return type reaches the compiler" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ declare add = fn(a: num, b: num) -> num
        \\ add(1, 2) + 1
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

test "declare rejects duplicate names" {
    try t.expectSemanticError(
        \\ declare MAX_ITEMS = num
        \\ declare MAX_ITEMS = num
    );
}

test "declare rejects non-top-level placement" {
    try t.expectSemanticError(
        \\ fn f() do
        \\     declare y = num
        \\ end
    );
}

test "dotted pub type resolves bare in the same file" {
    try t.topNumber(
        \\ pub type geo.Port = num
        \\ const p: Port = 8080
        \\ p
    , 8080);
}

test "dotted pub type in .d.rv resolves qualified by import" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "shapes.d.rv", .data = "pub type geo.Point = num\n" },
    });
    defer m.deinit();
    try t.topNumberInDir(
        m.dir,
        "import \"shapes.d.rv\"\nconst p: shapes.Point = 7\np\n",
        7,
    );
    try t.expectCompileErrorInDir(
        m.dir,
        "import \"shapes.d.rv\"\nconst p: shapes.Point = \"x\"\n",
    );
}

test "manifest dotted macros rescope under the import name" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "m.d.rv", .data =
        \\pub macro q.shout! `(%w:expr)` `%w`
        \\pub proc q.add3!(iter) do
        \\  let a = iter:next()
        \\  let b = iter:next()
        \\  let c = iter:next()
        \\  {{:binary, :add, {:binary, :add, a, b}, c}}
        \\end
        },
    });
    defer m.deinit();
    try t.topNumberInDir(
        m.dir,
        "import \"m.d.rv\"\nm.shout!(40) + m.add3!(10, 20, 10)\n",
        80,
    );
}

test "stdlib dotted type resolves qualified, unknown qualified errors" {
    try t.topNumber(
        \\ const u: uri.Uri = { scheme = "https", user = :nil, host = "example.com", path = "/hi/there", query = { "search", "page" = 3 }, fragment = :nil }
        \\ 1
    , 1);
    try t.expectSemanticError(
        \\ const u: uri.Hi = 2
    );
    try t.expectSemanticError(
        \\ const u: uri.Bogus = 1
    );
}

test ".d.rv import typechecks calls and never executes the file" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "audio.d.rv", .data = "pub declare ring = fn(volume: num, label: string) -> bool\nundefined_poison()\n" },
    });
    defer m.deinit();
    // build succeeds (semantic extracted the sig); runtime only fails on the
    // empty module table - the poison call inside the file never ran
    try t.expectRuntimeErrorInDir(
        m.dir,
        "import \"audio.d.rv\"\naudio.ring(1, \"x\")\n",
        .NotAFunction,
    );
}

test "manifest .d.rv types .so imports, sig fallback without one" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "fake.so", .data = "" },
        .{ .path = "fake.d.rv", .data = "pub declare open = fn(path: string) -> string\n" },
    });
    defer m.deinit();
    const source_name = try std.Io.Dir.path.join(std.testing.allocator, &.{ m.dir, "<source>" });
    defer std.testing.allocator.free(source_name);

    const source = "import \"fake.so\"\nfake.open(5)\n";

    // manifest present: the wrong-arg call is a compile error
    {
        var vm = try VM.init(t.runtime());
        defer vm.deinit();
        vm.module_dir = m.dir;
        const result = try lang.build(&vm, .{ .name = source_name, .text = source }, .{ .install_debug_info = false });
        switch (result) {
            .ok => return error.ExpectedCompileFailure,
            .err => |f| switch (f) {
                .semantic, .lower => vm.runtime.resetDiagArena(),
                .expand, .parse => return error.ExpectedCompileFailure,
            },
        }
    }

    // manifest gone: no sigs to synthesize from, the call compiles untyped
    try m.tmp.dir.deleteFile(std.testing.io, "fake.d.rv");
    {
        var vm = try VM.init(t.runtime());
        defer vm.deinit();
        vm.module_dir = m.dir;
        const result = try lang.build(&vm, .{ .name = source_name, .text = source }, .{ .install_debug_info = false });
        switch (result) {
            .ok => |artifact| {
                std.testing.allocator.free(artifact.instructions);
                std.testing.allocator.free(artifact.spans);
            },
            .err => return error.ExpectedCompileSuccess,
        }
    }
}
