const revo = @import("revo");
const lang = revo.lang;

const t = revo.lang.test_helpers;

test "channel select w/ multiple waiters" {
    try t.topNumber(
        \\ const ch1 = chan(0)
        \\ const ch2 = chan(0)
        \\ spawn (fn() send(ch1, 10))()
        \\ spawn (fn() send(ch2, 20))()
        \\ recv(ch1) + recv(ch2)
    , 30);
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
        \\ const add = fn(x: number, y: number) do x + y end
        \\ add(x = 5, y = 3)
    , 8);
    try t.topNumber(
        \\ const add = fn(x: number, y: number) do x + y end
        \\ add(y = 3, x = 5)
    , 8);
    try t.topNumber(
        \\ const add3 = fn(x: number, y: number, z: number) do x + y + z end
        \\ add3(1, y = 2, z = 3)
    , 6);
}

test "compiler: named parameters errors" {
    // unknown names surface at compilation, duplicates and mixing at semantic
    try t.expectCompileError(
        \\ const add = fn(x: number, y: number) do x + y end
        \\ add(x = 5, z = 3)
    , .ParseError);
    try t.expectSemanticError(
        \\ const add = fn(x: number, y: number) do x + y end
        \\ add(x = 5, x = 3)
    );
    try t.expectSemanticError(
        \\ const add = fn(x: number, y: number) do x + y end
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

test "default args fill through nested calls" {
    try t.topFalse(
        \\ const x = fn(a, b = :false) b
        \\ const y = fn(a) x(a)
        \\ y(1)
    );
    try t.topAtom(
        \\ const x = fn(a, b = :outer) b
        \\ const y = fn(a) x(a)
        \\ y(1)
    , "outer");
    try t.topTrue(
        \\ const x = fn(a, b = :false) b
        \\ const y = fn(a) x(a, :true)
        \\ y(1)
    );
}

//
// module system
//
