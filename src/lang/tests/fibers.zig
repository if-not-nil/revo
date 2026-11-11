const revo = @import("revo");

const t = revo.lang.test_helpers;

test "fiber syntax spawn join yield" {
    try t.topNumber(
        \\ const add = fn(a, b) a + b
        \\ const h = spawn add(39, 3)
        \\ h:join()
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
        \\   ch:send(v)
        \\   0
        \\ end
        \\ const a = spawn worker(20)
        \\ const b = spawn worker(22)
        \\ const x = ch:recv()
        \\ const y = ch:recv()
        \\ a:join()
        \\ b:join()
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
        \\ a:join() + b:join() + c:join()
    , 72);
    try t.topNumber(
        \\ const f = fn(v) do
        \\   sleep(10)
        \\   v
        \\ end
        \\ const a = spawn f(20)
        \\ const b = spawn f(22)
        \\ const c = spawn f(30)
        \\ const x = a:join()
        \\ const y = b:join()
        \\ const z = c:join()
        \\ x
    , 20);
}

test "spawn and join nest inside iterator maps" {
    try t.topNumber(
        \\ const pmap = fn(collection, func)
        \\   (collection |> to_iter)
        \\   :map(fn(x) spawn func(x))
        \\   :map(fn(x) x:join()):collect()
        \\ const r = pmap({10, 20, 30}, fn(x) x * 2)
        \\ r[0] + r[1] + r[2]
    , 120);
}

test "spawn snapshots loop iteration values" {
    try t.topNumber(
        \\ let hs = {}
        \\ for i in 0..5 do hs:push(spawn (fn(x) x)(i)) end
        \\ const r = (hs |> to_iter):map(fn(h) h:join()):collect()
        \\ r[0] + r[1] + r[2] + r[3] + r[4]
    , 10);
}

test "spawn requires a call" {
    try t.expectCompileError("spawn fn() 42", .UnsupportedSyntax);
    try t.expectCompileError("spawn 42", .UnsupportedSyntax);
}
