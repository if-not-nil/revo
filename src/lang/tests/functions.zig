const revo = @import("revo");
const lang = revo.lang;

const t = revo.lang.test_helpers;

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

test "bare calls" {
    // is a one-argument call
    try t.topString(
        \\ fn f(a) a
        \\ f "hello"
    , "hello");
    try t.topNumber(
        \\ fn f(t) t.a + t.b
        \\ f {a = 1, b = 2}
    , 3);

    // bare call fills defaults like a normal call
    try t.topString(
        \\ fn f(a, b = "d") b
        \\ f "x"
    , "d");
    try t.topString(
        \\ fn f(a, b = "d") b
        \\ f("x")
    , "d");

    // fills optional params with none
    try t.topAtom(
        \\ fn f(a, ?b) b
        \\ f "x"
    , "none");

    // postfix binds to the result
    try t.topString(
        \\ fn f(a) "a" ~ a
        \\ f "x":upper()
    , "AX");
    try t.topString(
        \\ fn f(a) "a" ~ a
        \\ f "x"[0]
    , "a");
    try t.topString(
        \\ fn f(a) fn(b) a ~ b
        \\ f "x"("y")
    , "xy");
    try t.topString(
        \\ fn f(a) {:ok, a}
        \\ f "x"?
    , "x");
}

test "typed function alias call is checked" {
    try t.expectSemanticFailure(
        \\ const id = fn(x: number) x
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
