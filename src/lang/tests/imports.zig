const revo = @import("revo");
const lang = revo.lang;

const t = revo.lang.test_helpers;

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
        \\ pub fn double(n: number) n * 2
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
        \\ pub fn double(n: number) n * 2
        \\ pub const version = 3
        },
    });
    defer m.deinit();

    try t.expectCompileErrorInDir(m.dir,
        \\ const m = import "./calc"
        \\ m.typo()
    );

    // baselib method dispatch still works on known-shape tables
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
