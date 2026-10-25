const std = @import("std");
const alloc = std.testing.allocator;

const revo = @import("revo");
const lang = revo.lang;
const VM = revo.VM;

const t = revo.lang.test_helpers;

test "baselib sigs: method return types reach the compiler" {
    var vm = try VM.init(t.runtime());
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

test "baselib sigs: global return types reach the compiler" {
    // semantic knows cwd/read from the os iface; misuse that compiled
    // against .any now errors before codegen
    try t.expectSemanticError(
        \\ let x = cwd()
        \\ let n: number = x
    );
    try t.expectSemanticError(
        \\ let x = read({delimiter = :eof})
        \\ let n: number = x?
    );
}

test "baselib sigs source fn shadows baselib global" {
    try t.topNumber(
        \\ const cwd = fn(x: number) x + 1
        \\ cwd(41)
    , 42);
    try t.expectSemanticError(
        \\ const cwd = fn(x: number) x + 1
        \\ cwd("nope")
    );
}

test "baselib sigs variadic global keeps accepting extra args" {
    try t.topString("fmt(\"%v\", 1, 2, 3)", "1");
    try t.expectSemanticError(
        \\ fmt()
    );
}

test "baselib sigs untyped call still validates arg count" {
    try t.expectSemanticError(
        \\ cwd("nope", "more")
    );
}

test "baselib sigs: module field calls resolve to spec sigs" {
    try t.topAtom("fs.exists?(\"/definitely/not/a/real/path_xyz\")", "false");
    try t.topNumber(
        \\ table.len({1, 2}) + 1
    , 3);
    try t.topTrue("let b: bool = fs.exists?(\"/tmp\")");
}

test "baselib sigs: a module table is its own self" {
    try t.topNumber("table.alen(table)", 0);

    try t.topAtom("table.klen(table) == table.len(table)", "true");
    try t.topAtom("table:klen() == table.len(table)", "true");
    try t.topAtom("table.len(table) > 0 and table.alen(table) == 0", "true");
}

test "baselib sigs: module result flows through match" {
    try t.topAtom(
        \\ let r = fs.open("/definitely/not/a/real/path_xyz")
        \\ match r | {:ok, f} => :found | {:err, e} => e
    , "FileNotFound");
}

test "baselib sigs: iter surface names what the impl takes" {
    // `zip` opens its tail after naming two, so one is a build error and not
    // a runtime one. `count` takes one optional pred, it is not a variadic
    try t.expectSemanticError("iter.zip({1, 2})");
    try t.expectSemanticError("iter.count({1, 2, 3}, fn(x) x > 1, 9)");
    try t.expectSemanticError("iter.count({1, 2, 3}, 5)");
    // `to_iter` is a global, the compiler bakes that name into `|> to_iter`.
    // module fields are not typed, so the dead member is a runtime miss
    try t.expectRuntimeError("iter.to_iter({1, 2})", .NotAFunction);
    try t.topAtom("iter.collect(iter.zip({1, 2}, {3, 4})) == { {1, 3}, {2, 4} }", "true");
    try t.topNumber("iter.count({1, 2, 3, 4}, fn(x) x > 2)", 2);
    try t.topAtom("iter.collect(to_iter({1, 2})) == {1, 2}", "true");
}

test "baselib sigs: local binding shadows baselib module" {
    // `fs` here is a local table, not the module
    // no baselib sig is applied, and the missing field fails at compile time
    // (it can never work, so no point waiting for runtime)
    // so this is EXACTLY what we want. it gets erased
    try t.expectSemanticError(
        \\ let fs = {}
        \\ fs.exists?("/tmp")
    );
}
test "baselib sigs: orelse unwraps results" {
    try t.topTrue("fs.exists?(\"/tmp\")");
    try t.topNumber("{:err, \"boom\"} orelse 5", 5);
}

test "baselib sigs: try rejects non-result unions" {
    // `?` on it is a lie
    try t.expectSemanticError(
        \\ "abc":index_of("b")?
    );
}

test "baselib sigs: match narrows call-subject payloads" {
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
        \\ declare MAX_ITEMS = number
        \\ const x: MAX_ITEMS = 5
        \\ x
    , 5);
}

test "declare fn calls typecheck and run into undefined variable" {
    try t.expectRuntimeError(
        \\ declare lamp = fn(volume: number, label: string) -> bool
        \\ lamp(1, "x")
    , .UndefinedVariable);
}

test "declare fn return type reaches the compiler" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ declare add = fn(a: number, b: number) -> number
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
        \\ declare MAX_ITEMS = number
        \\ declare MAX_ITEMS = number
    );
}

test "duplicate parameter is an error" {
    try t.expectErrorCode(
        \\ const f = fn(x, x) do x end
        \\ f(1, 2)
    , "duplicate-parameter");
    // the fn shorthand goes through the same param loop
    try t.expectErrorCode(
        \\ fn g(a, a) a
        \\ g(1, 2)
    , "duplicate-parameter");
    try t.expectNoWarning(
        \\ const f = fn(_, _) do 1 end
        \\ f(1, 2)
    );
}

test "duplicate name in one pattern is an error" {
    try t.expectErrorCode(
        \\ let {a, a} = {1, 2}
        \\ a
    , "duplicate-pattern-name");
    try t.expectErrorCode(
        \\ let v = {x = 1}
        \\ match v
        \\ | {x, x} => x
    , "duplicate-pattern-name");
}

test "one name bound by sibling matchers is fine" {
    // per-matcher binds, the arm body sees the union, so the same name
    // across matchers is the point and not a duplicate
    try t.topNumber(
        \\ match {:ok, 4}
        \\ | {:ok, n} => n
        \\ | {:err, n} => n
    , 4);
}

test "declare rejects non-top-level placement" {
    try t.expectSemanticError(
        \\ fn f() do
        \\     declare y = number
        \\ end
    );
}

test "dotted pub type resolves bare in the same file" {
    try t.topNumber(
        \\ pub type geo.Port = number
        \\ const p: Port = 8080
        \\ p
    , 8080);
}

test "baselib dotted type resolves qualified, unknown qualified errors" {
    try t.topNumber(
        \\ const u: uri.Uri = { scheme = "https", host = "example.com", path = "/hi/there", query = { "search", "page" = 3 } }
        \\ 1
    , 1);
    try t.expectSemanticError(
        \\ const u: uri.Hi = 2
    );
    try t.expectSemanticError(
        \\ const u: uri.Bogus = 1
    );
}

test "a module returning one ascribed table types its members" {
    var m = try t.TmpMod.init(&.{
        .{
            .path = "iface.rv",
            .data =
            \\const iface: {
            \\  add: fn(a: number, b: number) -> number,
            \\  greet: fn(name: string) -> string,
            \\} = { add = fn(a, b) a + b, greet = fn(n) "hi #{n}" }
            \\iface
            ,
        },
    });
    defer m.deinit();

    // the table is the module, so members carry their declared sigs
    try t.topNumberInDir(
        m.dir,
        "const iface = import \"./iface.rv\"\niface.add(3, 4)\n",
        7,
    );
    try t.topStringInDir(
        m.dir,
        "const iface = import \"./iface.rv\"\niface.greet(\"you\")\n",
        "hi you",
    );
    // wrong arg type and wrong arity both come from the ascription
    try t.expectCompileErrorInDir(
        m.dir,
        "const iface = import \"./iface.rv\"\niface.add(\"x\", 4)\n",
    );
    try t.expectCompileErrorInDir(
        m.dir,
        "const iface = import \"./iface.rv\"\niface.add(1)\n",
    );
}

test ".so imports are untyped on their own" {
    var m = try t.TmpMod.init(&.{
        .{ .path = "fake.so", .data = "" },
    });
    defer m.deinit();
    const source_name = try std.Io.Dir.path.join(std.testing.allocator, &.{ m.dir, "<source>" });
    defer std.testing.allocator.free(source_name);

    const source = "import \"fake.so\"\nfake.open(5)\n";

    {
        var vm = try VM.init(t.runtime());
        defer vm.deinit();
        vm.import_dir = m.dir;
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

test "repl_mode leaves a function-local let as a local" {
    try t.topTrueOpts(.{ .repl_mode = true },
        \\fn find(haystack, needle) do
        \\    const n = needle:len()
        \\    let at = -1
        \\    for i in 0..haystack:len() do
        \\        if haystack:sub(i, n) == needle do
        \\            at = i
        \\            break(:nil)
        \\        end
        \\    end
        \\    return at
        \\end
        \\find("hello", "ell") == 1
    );
}

const module_with_loop_local =
    \\pub fn find(haystack, needle) do
    \\    const n = needle:len()
    \\    let at = -1
    \\    for i in 0..haystack:len() do
    \\        if haystack:sub(i, n) == needle do
    \\            at = i
    \\            break(:nil)
    \\        end
    \\    end
    \\    return at
    \\end
;

test "a module imported on a repl line parses as a module" {
    var m = try t.TmpMod.init(&.{.{
        .path = "mod.rv",
        .data = module_with_loop_local,
    }});
    defer m.deinit();

    try t.topTrueOptsInDir(m.dir, .{ .repl_mode = true },
        \\import {
        \\    mod = "mod"
        \\}
        \\mod.find("hello", "ell") == 1
    );
}

test "repl_mode still promotes a top-level binding to a global" {
    try t.topTrueOpts(.{ .repl_mode = true },
        \\let kept = 7
        \\kept == 7
    );
}

test "repl_mode does not leak into a module compiled with default options" {
    const src =
        \\import {
        \\    mod = "stdmod"
        \\}
        \\mod.find("hello", "ell") == 1
    ;
    var m = try t.TmpMod.init(&.{.{ .path = "stdmod.rv", .data = module_with_loop_local }});
    defer m.deinit();

    var repl = try t.topResultOpts(src, m.dir, .{ .repl_mode = true });
    repl.deinit();
    var plain = try t.topResultOpts(src, m.dir, .{});
    defer plain.deinit();
    try std.testing.expect(!revo.isFalse(plain.value));
}

test "fmt %p does not leak escapes into a non-color host" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();
    vm.runtime.supports_color = false;

    const src = "const s = fmt(\"%p\", 42)\ns";
    _ = revo.run.runModule(&vm, "<test>", src, false) catch return error.LangFailure;
    const out = vm.mainResult();
    try std.testing.expect(out.isString());
    try std.testing.expect(std.mem.find(u8, vm.stringValue(out.asString().?), "\x1b[") == null);
}

test "fmt %p still colorizes when the host wants color" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();
    vm.runtime.supports_color = true;

    const src = "const s = fmt(\"%p\", 42)\ns";
    _ = revo.run.runModule(&vm, "<test>", src, false) catch return error.LangFailure;
    const out = vm.mainResult();
    try std.testing.expect(out.isString());
    try std.testing.expect(std.mem.find(u8, vm.stringValue(out.asString().?), "\x1b[") != null);
}

test "two vms can disagree about color" {
    var a = try VM.init(t.runtime());
    defer a.deinit();
    var b = try VM.init(t.runtime());
    defer b.deinit();

    try std.testing.expectEqual(a.runtime.supports_color, b.runtime.supports_color);
    a.runtime.supports_color = false;
    try std.testing.expectEqual(false, a.runtime.supports_color);
    try std.testing.expect(b.runtime.supports_color != false or a.runtime.supports_color == b.runtime.supports_color);
}

test "two vms have independent stdin buffers" {
    var a = try VM.init(t.runtime());
    defer a.deinit();
    var b = try VM.init(t.runtime());
    defer b.deinit();

    a.runtime.input_buf[0] = 'x';
    a.runtime.input_buf_len = 1;
    try std.testing.expectEqual(@as(usize, 0), b.runtime.input_buf_len);
    try std.testing.expectEqual(@as(u8, 'x'), a.runtime.input_buf[0]);
}

test "destructuring assignment" {
    // rebinds existing locals
    try t.topTrue(
        \\let a = 1
        \\let b = 2
        \\{a, b} = {3, 4}
        \\a == 3 and b == 4
    );
    // swaps
    try t.topTrue(
        \\let a = 5
        \\let b = 10
        \\{a, b} = {b, a}
        \\a == 10 and b == 5
    );
    // works inside a function
    try t.topTrue(
        \\fn swap() do
        \\    let a = 1
        \\    let b = 2
        \\    {a, b} = {b, a}
        \\    return a * 10 + b
        \\end
        \\swap() == 21
    );
    // discards
    try t.topTrue(
        \\let a = 1
        \\{_, a} = {9, 7}
        \\a == 7
    );
    // shape is checked
    try t.expectCompileFailure(
        \\let a = 1
        \\let b = 2
        \\{a, b} = {3, 4, 5}
    ,
        .ParseError,
        3,
        10,
        "table assignment expects 2 items, got 3",
    );
    // holds the target type"
    try t.expectSemanticError(
        \\let src: {number, number} = {3, 4}
        \\let a: string = ""
        \\let b: number = 0
        \\{a, b} = src
    );
    // accepts a matching target type
    try t.topTrue(
        \\let src: {number, number} = {3, 4}
        \\let a: number = 0
        \\let b: number = 0
        \\{a, b} = src
        \\a == 3 and b == 4
    );
}
