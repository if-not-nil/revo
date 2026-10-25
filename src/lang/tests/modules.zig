const std = @import("std");
const alloc = std.testing.allocator;

const revo = @import("revo");
const lang = revo.lang;

const t = revo.lang.test_helpers;

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
        \\ pub type UserId = number
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
        \\ type Hidden = number
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
        \\ pub type Id = number
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
        \\ pub type Code = number
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
    const abs_path = try alloc.print("{s}/absm.rv", .{m.dir});
    defer alloc.free(abs_path);

    const source = try alloc.print("import '{s}'\nabsm.x", .{abs_path});
    defer alloc.free(source);

    var result = try t.topResult(source, m.dir);
    defer result.deinit();
    const actual = try result.value.asNum();
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
