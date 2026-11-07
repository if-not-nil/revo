const std = @import("std");

const revo = @import("revo");

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
        \\ const setx = import("./setx")
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
        \\ const private_state = import("./private_state")
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

test "import takes only a literal path" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "calc.rv", .data =
        \\ pub fn double(n: number) n * 2
        },
    });
    defer m.deinit();

    try t.expectParseError(
        \\ let p = "./calc"
        \\ import(p).double(2)
    );
    try t.expectParseError(
        \\ let imp = import
        \\ imp("./calc")
    );
    try t.expectParseError("let x = \"calc\" import(\"./#{x}\")");
    try t.expectParseError("import \"./#{1}\"");

    // no parens is the same import
    try t.topNumberInDir(m.dir, "(import \"./calc\").double(4)", 8);

    // a chained call types without a binding
    try t.topNumberInDir(m.dir, "import(\"./calc\").double(21)", 42);
    try t.expectCompileErrorInDir(m.dir, "import(\"./calc\").typo");
}

test "imported qualified types check values" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "shapes.rv", .data =
        \\ pub type T = {:ok, string}
        \\ pub fn f() 10
        \\ pub const v = 5
        },
    });
    defer m.deinit();

    try t.topNumberInDir(m.dir,
        \\ const shapes = import("./shapes")
        \\ let x: shapes.T = {:ok, "hi"}
        \\ 1
    , 1);

    try t.expectCompileErrorInDir(m.dir,
        \\ const shapes = import("./shapes")
        \\ let x: shapes.T = {:err, 5}
    );

    try t.expectCompileErrorInDir(m.dir,
        \\ const shapes = import("./shapes")
        \\ let x: shapes.U = {:ok, "hi"}
    );

    try t.expectCompileErrorInDir(m.dir,
        \\ const shapes = import("./shapes")
        \\ type B = shapes.T
        \\ let y: B = {:err, 5}
    );

    try t.topNumberInDir(m.dir,
        \\ const shapes = import("./shapes")
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

test "collection prefixes resolve from the vm's collections, typed" {
    var lib = try t.TmpMod.init(&.{
        .{ .path = "calc.rv", .data = "pub const version = 3\n" },
    });
    defer lib.deinit();
    var app = try t.TmpMod.init(&.{});
    defer app.deinit();

    var vm = try revo.VM.init(t.runtime());
    defer vm.deinit();
    try vm.addCollection("mine", lib.dir);
    vm.import_dir = app.dir;
    const name = try std.Io.Dir.path.join(std.testing.allocator, &.{ app.dir, "<source>" });
    defer std.testing.allocator.free(name);

    const bad = try revo.lang.build(&vm, .{ .name = name, .text = "import(\"mine:calc\").typo" }, .{});
    switch (bad) {
        .ok => |b| {
            std.testing.allocator.free(b.instructions);
            std.testing.allocator.free(b.spans);
            return error.ExpectedCompileError;
        },
        .err => |e| revo.lang.pipeline.deinitError(e),
    }

    const res = try revo.run.runModule(&vm, name, "import(\"mine:calc\").version", false);
    try std.testing.expect(res == .ok);
    try std.testing.expectEqual(@as(f64, 3), try vm.mainResult().asNum());
}

test "bare, absolute and dll import paths are compile errors" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "calc.rv", .data = "pub const version = 3\n" },
    });
    defer m.deinit();

    try t.topNumberInDir(m.dir, "import(\"./calc\").version", 3);
    try t.expectCompileErrorInDir(m.dir, "import(\"calc\").version");
    try t.expectCompileErrorInDir(m.dir, "import(\"/calc\").version");
    try t.expectCompileErrorInDir(m.dir, "import(\"./calc.so\")");
}

test "use binds a module by its stem, typed" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "geo.rv", .data =
        \\ pub const pi = 3
        \\ pub fn area(r: number) pi * r * r
        \\ pub type P = number
        },
        .{ .path = "calc.rv", .data = "pub const version = 4\n" },
    });
    defer m.deinit();

    try t.topNumberInDir(m.dir,
        \\ use("./geo")
        \\ geo.area(2)
    , 12);
    try t.topNumberInDir(m.dir,
        \\ use "./calc.rv"
        \\ calc.version
    , 4);
    try t.topNumberInDir(m.dir,
        \\ fn f() do
        \\   use("./geo")
        \\   geo.pi
        \\ end
        \\ f()
    , 3);

    try t.expectCompileErrorInDir(m.dir,
        \\ use("./geo")
        \\ geo.typo
    );
    try t.expectCompileErrorInDir(m.dir,
        \\ use("./geo")
        \\ let x: geo.P = "s"
    );
}

test "use outside a statement or without a name is an error" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "geo.rv", .data = "pub const pi = 3\n" },
        .{ .path = "my-lib.rv", .data = "pub const v = 1\n" },
    });
    defer m.deinit();

    try t.expectCompileErrorInDir(m.dir, "use(\"./geo\").pi");
    try t.expectParseError("use(\"./my-lib\")");
    try t.expectParseError("use(\"./if\")");
    try t.expectParseError(
        \\ const p = "./geo"
        \\ use(p)
    );
    try t.expectParseError("use \"./#{1}\"");
}

test "a lazy import resolves from the file that wrote it" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "sub/b.rv", .data = "pub fn load() import(\"./y\")\n" },
        .{ .path = "sub/y.rv", .data = "pub const v = 7\n" },
    });
    defer m.deinit();

    try t.topNumberInDir(m.dir,
        \\ const b = import("./sub/b")
        \\ b.load().v
    , 7);
}

test "a module's first load from a spawned fiber finishes" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "slow.rv", .data =
        \\ sleep(5)
        \\ pub const v = 7
        },
    });
    defer m.deinit();

    // notes/issues/fiber_bug.rv: this used to hang
    try t.topNumberInDir(m.dir,
        \\ fn get() import("./slow").v
        \\ join(spawn get())
    , 7);
    // both fibers join the one load
    try t.topNumberInDir(m.dir,
        \\ fn get() import("./slow").v
        \\ const a = spawn get()
        \\ const b = spawn get()
        \\ join(a) + join(b)
    , 14);
}

test "pub is const-only, top-level only, and destructures" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "plet.rv", .data = "pub let n = 0\n" },
        .{ .path = "destr.rv", .data = "pub const {c, d} = {3, 4}\n" },
        .{ .path = "nested.rv", .data =
        \\ do
        \\   pub const x = 1
        \\ end
        },
    });
    defer m.deinit();

    try t.expectCompileErrorInDir(m.dir, "import(\"./plet\")");
    try t.expectCompileErrorInDir(m.dir, "import(\"./nested\")");
    try t.topNumberInDir(m.dir,
        \\ const m = import("./destr")
        \\ m.c + m.d
    , 7);
}

test "pub records are read-only, an explicit return wins" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "geo.rv", .data = "pub const pi = 3\n" },
        .{ .path = "odd.rv", .data =
        \\ pub fn f() 1
        \\ return 42
        },
        .{ .path = "plain.rv", .data = "{n = 1}\n" },
    });
    defer m.deinit();

    try t.expectCompileErrorInDir(m.dir,
        \\ const g = import("./geo")
        \\ g.pi = 4
    );
    // untyped, so it gets past the checker and the vm refuses
    try t.expectRuntimeErrorInDir(m.dir,
        \\ fn poke(t) do t.pi = 4 end
        \\ poke(import("./geo"))
    , .TypeError);
    try t.expectRuntimeErrorInDir(m.dir,
        \\ fn poke(t) table.push(t, 4)
        \\ poke(import("./geo"))
    , .Panic);
    try t.topNumberInDir(m.dir, "import(\"./odd\")", 42);
    // a tail table isn't a pub record
    try t.topNumberInDir(m.dir,
        \\ const p = import("./plain")
        \\ p.n = 2
        \\ p.n
    , 2);
}

test "a cycle of top-level imports is a compile error, a lazy one loads" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "ca.rv", .data =
        \\ const b = import("./cb")
        \\ pub const a = 1
        },
        .{ .path = "cb.rv", .data =
        \\ const a = import("./ca")
        \\ pub const b = 2
        },
        .{ .path = "la.rv", .data =
        \\ pub fn get() import("./lb").b
        \\ pub const a = 1
        },
        .{ .path = "lb.rv", .data =
        \\ const a = import("./la")
        \\ pub const b = a.a + 1
        },
    });
    defer m.deinit();

    try t.expectCompileErrorInDir(m.dir, "import(\"./ca\")");
    try t.topNumberInDir(m.dir, "import(\"./la\").get()", 2);
}

test "x.rv and x/init.rv both existing is an error" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "x.rv", .data = "1\n" },
        .{ .path = "x/init.rv", .data = "2\n" },
        .{ .path = "y/init.rv", .data = "3\n" },
    });
    defer m.deinit();

    try t.expectCompileErrorInDir(m.dir, "import(\"./x\")");
    try t.topNumberInDir(m.dir, "import(\"./x.rv\")", 1);
    try t.topNumberInDir(m.dir, "import(\"./y\")", 3);
}

test "a lazy import that runs mid-load is a runtime cycle" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "a.rv", .data =
        \\ const b = import("./b")
        \\ pub const x = b.get()
        },
        .{ .path = "b.rv", .data = "pub fn get() import(\"./a\").x\n" },
    });
    defer m.deinit();

    try t.expectRuntimeErrorInDir(m.dir, "import(\"./a\").x", .CyclicImport);
}
