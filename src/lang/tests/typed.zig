const std = @import("std");
const alloc = std.testing.allocator;

const revo = @import("revo");
const lang = revo.lang;
const VM = revo.VM;

const t = revo.lang.test_helpers;

test "import typed function reports arg type mismatch" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "adder.rv", .data =
        \\ pub fn add(a: number, b: number) a + b
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

test "ascribed pub re-export types the import" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "native.rv", .data =
        \\ {
        \\   add = fn(a, b) do a + b end,
        \\ }
        },
        .{ .path = "wrapper.rv", .data =
        \\ const n = import "./native.rv"
        \\ pub const add: fn(a: number, b: number) -> number = n.add
        },
    });
    defer m.deinit();
    try t.topNumberInDir(m.dir,
        \\ const w = import "./wrapper.rv"
        \\ w.add(19, 23)
    , 42);
    try t.expectCompileErrorInDir(m.dir,
        \\ const w = import "./wrapper.rv"
        \\ w.add("x", 2)
    );
}

//
// typed compilation through the vm; integration coverage for the
// type universe, kept with the language suite instead of types.zig
//

//
// type system
//

test "typed number/string bindings accept and reject" {
    try t.topNumber(
        \\ let x: number = 42
        \\ x
    , 42);
    try t.expectSemanticError(
        \\ let x: number = "hello"
    );
    try t.expectSemanticError(
        \\ let x: string = 42
    );
}

test "typed binding table<number> accepts positional table literal" {
    try t.topNumber(
        \\ let nums: table<number> = { 1, 2, 3 }
        \\ 1
    , 1);
}

test "typed binding table<string, number> accepts keyed table literal" {
    try t.topNumber(
        \\ let pairs: table<string, number> = { a = 1, b = 2 }
        \\ 1
    , 1);
}

test "records accept matching shapes" {
    try t.topNumber(
        \\ let u: { name: string, age: number } = { name = "alice", age = 30 }
        \\ u.age
    , 30);
    try t.topString(
        \\ let u: { name: string } = { name = "alice", age = 30 }
        \\ u.name
    , "alice");
    try t.topNumber(
        \\ let u: { name: string, age: number } = { name = "alice", age = 30 }
        \\ u.age + 12
    , 42);
    try t.topString(
        \\ fn greet(u: { name: string }) u.name
        \\ greet({ name = "bob", age = 40 })
    , "bob");
    try t.topNumber(
        \\ type User = { name: string, age: number }
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

test "optional ?field: accepts absent keys" {
    try t.topNumber(
        \\ fn f(opts: {?max_bytes: number}) -> number do 0 end
        \\ f({})
    , 0);
    try t.topNumber(
        \\ fn f(opts: {?max_bytes: number}) -> number do 0 end
        \\ f({max_bytes = 5})
    , 0);
    try t.topNumber(
        \\ type Opts = {?a: number?, ?b: string}
        \\ let o: Opts = {a = :nil}
        \\ 1
    , 1);

    // present-but-wrong-typed still rejects
    try t.expectSemanticError(
        \\ fn f(opts: {?max_bytes: number}) -> number do 0 end
        \\ f({max_bytes = "lots"})
    );

    // required fields still reject absent keys
    try t.expectSemanticError(
        \\ fn f(opts: {max_bytes: number}) -> number do 0 end
        \\ f({})
    );
}

test "records reject mismatched shapes" {
    try t.expectSemanticError(
        \\ let u: { name: string, age: number } = { name = "alice" }
    );
    try t.expectSemanticError(
        \\ let u: { name: string } = { name = 42 }
    );
    try t.expectSemanticError(
        \\ let u: { name: string } = { name = "alice" }
        \\ let x: number = u.name
    );
    try t.expectSemanticError(
        \\ fn greet(u: { name: string, age: number }) u.name
        \\ greet({ name = "bob" })
    );
    try t.expectSemanticError(
        \\ let t: { user: { name: string } } = { user = { name = 42 } }
    );
    try t.expectSemanticError(
        \\ let a: { name: number } = {}
    );
    try t.expectSemanticError(
        \\ let a: { name: number } = { 1, 2, 3 }
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
        \\ type F = fn(number, number) -> number
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
    // opaque tables have unknown shapes: optimistic, no error
    try t.topNumber(
        \\ fn f(t: table) t.a
        \\ f({a = 41})
    , 41);
}

test "typed function params accept correct types" {
    try t.topNumber(
        \\ const add = fn(a: number, b: number) a + b
        \\ add(3, 4)
    , 7);
}

test "typed function rejects wrong arg types" {
    try t.expectSemanticError(
        \\ const add = fn(a: number, b: number) a + b
        \\ add(3, "wrong")
    );
    try t.expectSemanticError(
        \\ const add = fn(a: number, b: number) a + b
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

test "binary number + number emits add" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let a: number = 5
        \\ let b: number = 3
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

test "negate number emits negate" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let x: number = 5
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

test "comparison number == number emits eq_int" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let a: number = 5
        \\ let b: number = 5
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
        \\ const outer = fn(x: number) do
        \\     const inner = fn(y: number) y * 2
        \\     inner(x) + 1
        \\ end
        \\ outer(5)
    , 11);
}

test "function call with multiple typed params" {
    try t.topNumber(
        \\ const calc = fn(a: number, b: number, c: number) do
        \\     a + b + c
        \\ end
        \\ calc(1, 2.5, 3)
    , 6.5);
}

test "return type validation accepts correct type" {
    try t.topNumber(
        \\ const get_num = fn() -> number do
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
        \\ const x: number = 42
        \\ x
    , 42);
    try t.topString(
        \\ const s: string = "hello"
        \\ s
    , "hello");
    try t.expectSemanticError(
        \\ const x: number = "hello"
    );
    try t.topNumber(
        \\ global x: number = 42
        \\ x
    , 42);
}

//
// type alias at call sites
//
test "type aliases work in function params" {
    try t.topNumber(
        \\ type MyInt = number
        \\ const double = fn(x: MyInt) -> MyInt x * 2
        \\ double(21)
    , 42);
    try t.topNumber(
        \\ type Num = number
        \\ const add = fn(a: Num, b: Num) -> number a + b
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
        \\ type MyInt = number
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
        \\ fn get() -> number do
        \\     return "hello"
        \\ end
    );
}

test "explicit returns match the return type" {
    try t.topNumber(
        \\ fn get() -> number do
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
        \\ let x: number = 5
        \\ let y = if x > 0 10 else 20
        \\ y
    , 10);
    try t.topString(
        \\ let x: number = 0
        \\ let y = if x > 0 "pos" else "non-pos"
        \\ y
    , "non-pos");
    try t.topNumber(
        \\ let x: number = 5
        \\ let y = unless x > 0 10 else 20
        \\ y
    , 20);
    try t.topString(
        \\ let x: number = 0
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

test "string negative index accesses nth-last character" {
    try t.topString(
        \\ let s: string = "hello"
        \\ s[-1]
    , "o");
    try t.topString(
        \\ let s: string = "x"
        \\ s[-1]
    , "x");
    try t.topString(
        \\ let s: string = "abcd"
        \\ s[-2]
    , "c");
}
//
// any type accepts everything
//
test "any accepts number, table, and bindings" {
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
        \\ let x: number = do
        \\     let a = 1
        \\     let b = 2
        \\     a + b
        \\ end
        \\ x
    , 3);
    try t.expectSemanticError(
        \\ let x: number = do
        \\     "hello"
        \\ end
    );
}

//
// chained typed ops preserve specialization
//
test "chained typed math emits add and mul" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let a: number = 1
        \\ let b: number = 2
        \\ let c: number = 3
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
        \\ let x: number = 5
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
        \\ fn f() -> number do
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
        \\     let x: number = 5
        \\     const inner = fn() do x = "hello" end
        \\ end
    );
}

test "dynamic callee validates argument types" {
    try t.expectCompileError(
        \\ const f: function = fn(x: number) x
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
        \\ fn f() -> number do
        \\   for/l i in 0..5 do
        \\     if i == 4 break/l(i)
        \\   end
        \\ end
        \\ f()
    , 4);
}

test "compiler annotations cover analyzed constructs" {
    // sema is the only typer
    // every node the compiler reads a type from
    //   must already be annotated, including lowered sugar and patterns
    const cases = [_][]const u8{
        \\ const mk = fn(x: number) do
        \\   const rec = { value = x, next = :none }
        \\   rec.value + 1
        \\ end
        \\ let total = 0
        \\ for i in 0..3 do total = total + i end
        \\ match total | 3 => mk(total) | _ => 0
        ,
        \\ const f = fn(a: number, b: number = 2) a + b
        \\ f(1)
        ,
        \\ const f = fn(a: number, b: number) a + b
        \\ f(b = 2, a = 1)
        ,
        \\ fn id<T>(x: T) x
        \\ id<number>(4)
        ,
        \\ const inc = fn(x) x |> (fn(y) y + 1)
        \\ inc(1)
        ,
        \\ const t = { a = 1, b = "x" }
        \\ const {a, b} = t
        \\ a
        ,
        \\ comp 1 + 2
        ,
        \\ let x: number = 1
        \\ while x < 3 do x = x + 1 end
        \\ x
        ,
        \\ fn f(a) fn(b) a ~ b
        \\ f "x"("y")
        ,
        \\ 2
        \\ |> match
        \\    | x => 42
        ,
        \\ let a = 1
        \\ let b = 2
        \\ {a, b} = {3, 4}
        \\ a == 3 and b == 4
        ,
    };
    for (cases) |src| {
        const stats = try t.compileStats(src);
        try t.expectNoAnnotationMisses(stats, src);
    }
}
