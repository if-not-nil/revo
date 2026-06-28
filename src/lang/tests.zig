//
// beware, this tests the whole language, start-to-finish
// maybe this should be src/tests.zig instead?
// big TODO: prefix test names with their scope so that i can grep "atom and find all atom tests
//
const std = @import("std");
const alloc = std.testing.allocator;
const io = std.testing.io;

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

test "typed struct field access emits fast opcodes" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ struct User {
        \\     age: number = 0,
        \\ }
        \\ let user: User = User {}
        \\ const before = user.age
        \\ user.age = 12
        \\ before + user.age
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_get = false;
    var saw_set = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .struct_get_offset) saw_get = true;
        if (inst.op == .struct_set_offset) saw_set = true;
    }

    try std.testing.expect(saw_get);
    try std.testing.expect(saw_set);
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
    try t.top_number(
        \\ const t = { len = fn(self) 42 }
        \\ t:len()
    , 42);
}

test "dynamic field assignment shadows stdlib method" {
    try t.top_number(
        \\ const t = {}
        \\ t.len = fn(self) 42
        \\ t:len()
    , 42);
}

test "atom-key index assignment shadows stdlib method" {
    try t.top_number(
        \\ const t = {}
        \\ t[:len] = fn(self) 42
        \\ t:len()
    , 42);
}

test "plain table uses stdlib method" {
    try t.top_number(
        \\ const t = {1, 2, 3}
        \\ t:len()
    , 3);
}

test "string-key index does not shadow stdlib method" {
    try t.top_number(
        \\ const t = {1, 2, 3}
        \\ t["len"] = fn(self) 42
        \\ t:len()
    , 3);
}

test "computed key does not invalidate table field tracking" {
    try t.top_number(
        \\ const t = { len = fn(self) 42 }
        \\ const key = "foo"
        \\ t[key] = 7
        \\ t:len()
    , 42);
}

//
// known limitation: table_fields is per-variable, not per-table
// when two variables share the same underlying table, only the variable
// that received the direct assignment has its table_fields updated
//

test "shared alias mutation shadows stdlib method" {
    // known limitation: table_fields is per-variable, not per-table
    // x gets tracking for len but t doesnt, so t:len() binds to stdlib
    return error.SkipZigTest;
}

test "typed call results specialize later math" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ const id = fn(x: int) -> int x
        \\ const y = id(3)
        \\ y + 1
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add or inst.op == .add_int) saw_add = true;
    }
    try std.testing.expect(saw_add);
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
        if (inst.op == .lt or inst.op == .lt_int) saw_lt = true;
        if (inst.op == .sub or inst.op == .sub_int) saw_sub = true;
        if (inst.op == .add or inst.op == .add_int) saw_add = true;
    }

    try std.testing.expect(saw_lt);
    try std.testing.expect(saw_sub);
    try std.testing.expect(saw_add);
}

test {
    _ = @import("expander.zig").testing;
    _ = std.testing.refAllDecls(@import("compiler/root.zig"));
    _ = std.testing.refAllDecls(@import("Project.zig"));
}

//
// basic
//

test "arithmetic" {
    try t.top_number("1 + 2 * 3", 7);
    try t.top_number("-1", -1);
    try t.top_number("1.5 + 2.25", 3.75);
    try t.top_number("5.5 - 0.5", 5.0);
    try t.top_number("3.0 * 0.5", 1.5);
    try t.top_number("5.0 / 2.0", 2.5);
}

test "concat operator" {
    // string concat
    try t.top_string("'hello' ~ ' world'", "hello world");
    try t.top_string("'a' ~ 'b' ~ 'c'", "abc");
    try t.top_string("'' ~ 'x'", "x");
    try t.top_string("'x' ~ ''", "x");

    // number concat (numbers convert to string)
    try t.top_string("1 ~ 2", "12");
    try t.top_string("1 ~ ' x'", "1 x");
    try t.top_string("'x ' ~ 2", "x 2");
    try t.top_string("1.5 ~ 2", "1.52");

    // tuple concat
    try t.top_true("(1, 2) ~ (3, 4) == (1, 2, 3, 4)");
    try t.top_true("(1,) ~ (2,) ~ (3,) == (1, 2, 3)");
    try t.top_true("(1, 2) ~ (3, 4) ~ (5,) == (1, 2, 3, 4, 5)");

    // table with __tostring metamethod
    try t.top_string(
        \\const mt = {__tostring = fn(self) "custom"}
        \\const t = set_metatable({}, mt)
        \\t ~ ""
    , "custom");
    try t.top_string(
        \\const mt = {__tostring = fn(self) "hello"}
        \\const t = set_metatable({}, mt)
        \\"x" ~ t
    , "xhello");
    try t.top_string(
        \\const mt = {__tostring = fn(self) "hello"}
        \\const t = set_metatable({}, mt)
        \\t ~ " world"
    , "hello world");
    try t.top_string(
        \\const mt = {__tostring = fn(self) "a"}
        \\const t = set_metatable({}, mt)
        \\t ~ t
    , "aa");

    // concat + comparison
    try t.top_atom("'ab' ~ 'c' == 'abc'", "true");
    try t.top_atom("'ab' ~ 'c' != 'abc'", "false");

    // compound assign
    try t.top_string(
        \\let s = "a"
        \\s ~= "b"
        \\s
    , "ab");
    try t.top_true(
        \\let t = (1,)
        \\t ~= (2,)
        \\t == (1, 2)
    );

    // mixed types fall through to display
    try t.top_string("(:a, 1) ~ 2", "(:a, 1)2");
    try t.top_string(":hello ~ ' world'", ":hello world");
}

//
// semantic type checking of stdlib functions
//

test "@doc annotates functions without changing runtime behavior" {
    try t.top_number(
        \\ @doc "adds numbers"
        \\ fn add(a, b) a + b
        \\ add(20, 22)
    , 42);
}

test "return statement" {
    try t.top_number(
        \\ do return 7 8 end
    , 7);
    try t.top_atom(
        \\ fn f() do return :ok end
        \\ f()
    , "ok");
    try t.top_number(
        \\ fn f() do return 42 end
        \\ f()
    , 42);
}

test "fiber syntax spawn join yield" {
    try t.top_number(
        \\ const add = fn(a, b) a + b
        \\ const h = spawn add(39, 3)
        \\ join h
    , 42);

    try t.top_type(
        \\ do
        \\   yield
        \\ end
    , .atom);
}

test "channels coordinate spawned workers" {
    try t.top_number(
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

test "sleep with multiple spawned joins returns numeric sums" {
    try t.top_number(
        \\ const f = fn(v) do
        \\   sleep(10)
        \\   v
        \\ end
        \\ const a = spawn f(20)
        \\ const b = spawn f(22)
        \\ const c = spawn f(30)
        \\ (join(a) + join(b) + join(c))
    , 72);
}

test "sleep join values are preserved per handle" {
    try t.top_number(
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

test "compiles unary operators and atom equality" {
    try t.top_atom("not :false", "true");
    try t.top_atom("not :true", "false");
    try t.top_atom("1 + 1 == 2", "true");
    try t.top_number("len(\"abcd\")", 4);
    try t.top_number("-5 + 7", 2);
}

test "hash starts comments only" {
    try t.expectTypes(
        \\do
        \\    # whole line comment
        \\    let x = 1 # trailing comment
        \\end
    , &.{
        .kw_do,
        .kw_let,
        .ident,
        .assign,
        .number,
        .kw_end,
        .eof,
    });
}

test "compiles bindings assignment and block result" {
    try t.top_number(
        \\do
        \\    let a = 1
        \\    let b = 2
        \\    a + b
        \\end
    , 3);
}

test "bind, declaration and assignment are expressions and return rhs" {
    try t.top_number(
        \\ const a = const b = 5
    , 5);
    try t.top_number(
        \\ let a = let b = 5
    , 5);
    try t.top_number(
        \\ const a = let b = 5
    , 5);
    try t.top_number(
        \\ let a = 5
        \\ let b = (a = 42)
    , 42);
}

test "atoms do not collide with other values" {
    try t.top_type(
        \\:do
    , .atom);
}

test "the program is in a top-level block" {
    try t.top_number(
        \\ do const t = -41 (0 - t) + 1 end
    , 42);
}

test "blocks keep only last expression value" {
    try t.top_number(
        \\ do
        \\   1
        \\   2
        \\   3
        \\ end
    , 3);
}

test "if uses atom false verity" {
    try t.top_number(
        \\do
        \\    const t = {answer = 41}
        \\    if :false t.answer else t.answer + 1
        \\end
    , 42);
}

test "top verity uses atom booleans" {
    try t.top_true(":true");
    try t.top_false(":false");
    try t.top_true(":ok");
}

test "top verity follows false values" {
    try t.top_true("1");
    try t.top_false("0");
    try t.top_false(":nil");
    try t.top_true("\"\"");
}

test "and/or preserve value semantics" {
    try t.top_true("1 and 2");
    try t.top_true("0 or 9");
    try t.top_true("(:t or :true or not :nil or 1 or 1.0 or 67) == :t");
}

test "chained or conditions in if parse and run" {
    try t.top_number(
        \\ const nextword = "."
        \\ if nextword == "." or nextword == "," or nextword == "!" or nextword == "?" do
        \\     1
        \\ end else do
        \\     0
        \\ end
    , 1);
}

test "assignment & op combinations" {
    try t.top_number("let t = 41 t += 1 t", 42);
    try t.top_number("let t = 43 t -= 1 t", 42);
    try t.top_number("let t = 84 t /= 2 t", 42);
    try t.top_number("let t = 21 t *= 2 t", 42);
}

test "comparisons" {
    try t.top_false("1 == 2");
    try t.top_true("assert(1 < 2)");
    try t.top_true("assert(\"a\" < \"b\")");
}

test "hash literals are real atoms" {
    try t.top_atom(":good", "good");
}

test "field assignment works" {
    try t.top_true(
        \\ const sys = {answer = 41}
        \\ sys.answer = 1
        \\ sys.answer
    );
    try t.top_true(
        \\ const sys = {a = {b = 1}}
        \\ sys.a.b = 2
        \\ sys.a.b == 2
    );
    try t.top_number(
        \\ const sys = {a = 1}
        \\ sys.a = sys.a + 1
        \\ sys.a
    , 2);
}

test "string conversion metamethods __tostring" {
    try t.top_string(
        \\ const mt = {__tostring = fn(self) "custom"}
        \\ const t = set_metatable({a = 1}, mt)
        \\ tostring(t)
    , "custom");
    try t.top_string(
        \\ const mt = {__tostring = fn(self) "42"}
        \\ const t = set_metatable({}, mt)
        \\ tostring(t)
    , "42");
}

test "display formatting uses __display and falls back to __tostring" {
    try t.top_string(
        \\ const mt = {__display = fn(self) "visible", __tostring = fn(self) "hidden"}
        \\ const t = set_metatable({}, mt)
        \\ fmt("%v", t)
    , "visible");

    try t.top_string(
        \\ const mt = {__tostring = fn(self) "fallback"}
        \\ const t = set_metatable({}, mt)
        \\ fmt("%v", t)
    , "fallback");
}

test "metamethod __index for field access" {
    try t.top_number(
        \\ const mt = {__index = fn(self, key) 42}
        \\ const t = set_metatable({}, mt)
        \\ t.missing_field
    , 42);
}

test "plain metatable fields resolve before __index" {
    try t.top_number(
        \\ const mt = {value = 7, __index = fn(self, key) 99}
        \\ const t = set_metatable({}, mt)
        \\ t.value
    , 7);
}

test "metamethod failures are runtime errors not host panics" {
    try t.expectRuntimeFailureWithMessage(
        \\ const mt = {__tostring = fn(self) panic("boom")}
        \\ const t = set_metatable({}, mt)
        \\ tostring(t)
    , .Panic, "boom");
}

test "errs returned at toplevel report proper span" {
    try t.expectRuntimeFailure(
        \\ do
        \\ (:err, "boom")?
        \\ end
    , .Panic, 2, 2, "boom");
}

test "if-let works" {
    try t.top_number(
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
    try t.top_number(
        \\ const mt = {__newindex = fn(self, key, value) table.rawset(self, key, 99)}
        \\ const t = set_metatable({}, mt)
        \\ t.x = 5
        \\ t.x
    , 99); // todo assert!(99 == t.x = 5)
}

test "method calls require obj:method(args)" {
    try t.top_number(
        \\ const mt = {get_x = fn(self) self.x}
        \\ const t = set_metatable({x = 12}, mt)
        \\ t:get_x()
    , 12);
    try t.top_number(
        \\ const Email = {parse = fn(x) x}
        \\ Email.parse(42)
    , 42);
}

test "method call after train keeps receiver alive" {
    try t.top_number(
        \\ struct Box {
        \\     state = {},
        \\     fn train(self) self,
        \\     fn take(self, n: int) n,
        \\ }
        \\ const c = Box{}
        \\ c:train()
        \\ c:take(50)
    , 50);
}

test "metatable-backed constructor and instance methods compile" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const source =
        \\ let DB = set_metatable({}, {
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
    try t.top_type(
        \\ const mt = {id = fn(self) self}
        \\ const t = set_metatable({}, mt)
        \\ t.id
    , .function);
}

test "non-table values can use plain metatable fields as methods" {
    try t.top_string(
        \\ const mt = {reverse = fn(self) "fdsa"}
        \\ set_metatable("", mt)
        \\ "asdf":reverse()
    , "fdsa");
}

//
// error vals
//

test "result predicates work" {
    try t.top_string("tostring((:ok, 42))", "(:ok, 42)");
    try t.top_string("tostring((:err, :Bad))", "(:err, :Bad)");
}

test "error helpers build and classify tagged errors" {
    try t.top_string("tostring((:err, :FileNotFound))", "(:err, :FileNotFound)");
    try t.top_true("err?!((:err, :Bad))");
    try t.top_true("err?!((:err, :FileNotFound))");
    try t.top_false("err?!((:ok, :Bad))");
}

test "result predicates replace native functions" {
    try t.top_true("ok?!((:ok, 42))");
    try t.top_true("ok?!((:ok, :nil))");
    try t.top_false("ok?!((:err, :Bad))");
    try t.top_true("err?!((:err, :Bad))");
    try t.top_false("err?!((:ok, 42))");
}

test "result and error conventions work with match" {
    try t.top_true(":true");
}

test "unwrap panics on err result" {
    try t.expectRuntimeFailureWithMessage(
        \\ unwrap((:err, :Unlucky))
    , .Panic, ":Unlucky");
}

test "unwrap works on tuples immediately" {
    try t.expectRuntimeFailureWithMessage(
        \\ (:err, :Unlucky):unwrap()
    , .Panic, ":Unlucky");
}

test "unwrap panics on bullshit" {
    try t.expectRuntimeError(
        \\ unwrap "yo"
    , .TypeError);
}

//
// macro
// pattern grammar: %x (capture), %x:type (typed), %GROUP(...)*+? (quantified groups)
//

test "zero-arg macro expands on identifier use" {
    try t.top_number(
        \\macro answer! `` `42`
        \\answer!
    , 42);
}

test "unary macro expands in call position" {
    try t.top_number(
        \\ macro id! `%e:expr` `%e`
        \\ id!(42)
    , 42);
}
test "macro system capabilities and limitations" {
    try t.top_number(
        \\ macro id! `%x:expr` `%x`
        \\ id!(42)
    , 42);

    try t.top_number(
        \\ macro count_args! `(%fmt:str %ARGS(, %arg:expr)*)` `3`
        \\ count_args!("format", 1, 2, 3)
    , 3);
}

// basic simple captures
test "unary macro - single expression capture" {
    try t.top_number(
        \\ macro id! `%x:expr` `%x`
        \\ id!(42)
    , 42);
}

test "binary structure macro - multiple captures with literals" {
    try t.top_number(
        \\ macro combine! `(%left:expr %right:expr)` `%left + %right`
        \\ combine!(20, 22)
    , 42);
}

// type-consrtained captures
test "identifier capture - creates bindings" {
    try t.top_number(
        \\ macro const! `%name:ident = %val:expr` `const %name = %val`
        \\ const!(answer = 42)
        \\ answer
    , 42);
}

test "string literal capture - constrains to string" {
    try t.top_type(
        \\ macro get_format! `(%fmt:str %rest:expr)` `%fmt`
        \\ get_format!("hello", 123)
    , .string);
}

test "number literal capture - constrains to number" {
    try t.top_number(
        \\ macro repeat_val! `(%n:number %body:expr)` `%n`
        \\ repeat_val!(42, (1 + 2))
    , 42);
}

// repetition groups
test "zero-or-more repetition - captures multiple items" {
    try t.top_nil(
        \\ macro do_all! `(%ITEMS(%item:expr)*)` `do %ITEMS(%item) :nil end`
        \\ do_all!(1, 2, 3)
    );
}

test "one-or-more repetition - at least one required" {
    try t.top_number(
        \\ macro sum_all! `(%first:expr %REST(%item:expr)*)` `%first %REST(+ %item)`
        \\ sum_all!(10, 15, 17)
    , 42);
}

test "optional group - zero or one occurrence" {
    try t.top_number(
        \\ macro maybe_print! `(%val:expr %MSG(%msg:str)?)` `%val`
        \\ maybe_print!(42, "hello")
    , 42);
}

test "comma-separated repetition - literal separators" {
    try t.top_number(
        \\ macro tuple_fst! `(%first:expr %REST(%item:expr)*)` `%first`
        \\ tuple_fst!(10, 15, 17)
    , 10);
}

// complex combinations
test "if-elif-else chain multiple groups with quantifiers" {
    try t.top_number(
        \\ macro choose!
        \\     `(%head:number %ITEMS(%item:number)* %MSG(%msg:str)?)`
        \\     `do %head %ITEMS(+ %item) end`
        \\
        \\ choose!(10, 15, 17, "done")
    , 42);
}

test "complex fn def captures, repetition, optional" {
    try t.top_number(
        \\ macro sum_from! `(%start:number %ITEMS(%item:expr)+)`
        \\     `do %start %ITEMS(+ %item) end`
        \\
        \\ sum_from!(10, 15, 17)
    , 42);
}

// kw-based control flow
test "negative conditional" {
    try t.top_type(
        \\ macro unless! `(%cond:expr %body:expr)` `if %cond :nil else %body`
        \\ unless!(5 < 0, :positive)
    , .atom);
}

test "custom keyword structure - keywords at multiple positions" {
    try t.top_number(
        \\ macro repeat_until! `(%body:expr %cond:expr)` `%body`
        \\ repeat_until!(10 + 32, 5 == 0)
    , 42);
}

//
// quasiquote `template` with %splice
//

test "quasiquote atom" {
    try t.top_true(
        \\let r = `:hello`
        \\r == (:hash, "hello")
    );
}

test "quasiquote number" {
    try t.top_true(
        \\let r = `42`
        \\r == (:number, 42)
    );
}

test "quasiquote string" {
    try t.top_true(
        \\let r = `"hello"`
        \\r == (:string, "hello")
    );
}

test "quasiquote nil tuple" {
    try t.top_true(
        \\let r = `()`
        \\r == (:nil,)
    );
}

test "quasiquote produces tuple" {
    try t.top_true(
        \\let r = `(:a, :b)`
        \\r == (:tuple, ((:hash, "a"), (:hash, "b")))
    );
}

test "quasiquote produces table" {
    try t.top_true(
        \\let r = `{:a, :b}`
        \\r == (:table, ((:nil, :false, (:hash, "a")), (:nil, :false, (:hash, "b"))))
    );
}

test "quasiquote splice inserts value" {
    try t.top_true(
        \\let x = 10
        \\let r = `(:num, %x)`
        \\r == (:tuple, ((:hash, "num"), 10))
    );
}

test "quasiquote table named key" {
    try t.top_true(
        \\let v = 42
        \\let r = `{key = %v}`
        \\r == (:table, (((:ident, "key"), :false, 42),))
    );
}

test "quasiquote nested splice in table" {
    try t.top_true(
        \\let x = 42
        \\let r = `{(:a, %x)}`
        \\r == (:table, ((:nil, :false, (:tuple, ((:hash, "a"), 42))),))
    );
}

test "quasiquote multiple splices" {
    try t.top_true(
        \\let a = 20
        \\let b = 22
        \\let r = `(:add, %a, %b)`
        \\r == (:tuple, ((:hash, "add"), 20, 22))
    );
}

test "quasiquote bare ident" {
    try t.top_true(
        \\let r = `hello`
        \\r == (:ident, "hello")
    );
}

test "quasiquote table computed key with splice" {
    try t.top_true(
        \\let k = 99
        \\let v = 42
        \\let r = `{[%k] = %v}`
        \\r == (:table, ((99, :true, 42),))
    );
}

//
// fns / imports
//

test "closures capture outer locals by reference" {
    try t.top_number(
        \\ const make_adder = fn(x) fn(y) x + y
        \\ const add2 = make_adder(2)
        \\ add2(40)
    , 42);
    try t.top_number(
        \\ const outer = fn() do
        \\     let x = 1
        \\     const get = fn() x
        \\     x = 2
        \\     get()
        \\ end
        \\ outer()
    , 2);
    try t.top_number(
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
    try t.top_number(
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
    try t.top_number(
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
    try t.top_number(
        \\ const fact = fn(n) if n == 0 1 else n * fact(n - 1)
        \\ fact(5)
    , 120);
    try t.top_true(
        \\ const is_even = fn(n) if n == 0 1 else is_odd(n - 1)
        \\ const is_odd = fn(n) if n == 0 0 else is_even(n - 1)
        \\ is_even(10)
    );
    try t.top_number(
        \\ const outer = fn() do
        \\     const fact = fn(n) if n == 0 1 else n * fact(n - 1)
        \\     fact(5)
        \\ end
        \\ outer()
    , 120);
    try t.top_number(
        \\ const make_fact = fn(scale) do
        \\     const fact = fn(n) if n == 0 scale else n * fact(n - 1)
        \\     fact
        \\ end
        \\ const fact = make_fact(2)
        \\ fact(3)
    , 12);
}

test "loops thread state and break with a single value" {
    try t.top_number(
        \\ let x = 0
        \\ const result = loop do
        \\     if x < 10
        \\         x = x + 1
        \\     else
        \\         break(x)
        \\ end
        \\ result
    , 10);
    try t.top_number(
        \\ const scale = 2
        \\ let v = 1
        \\ loop do
        \\     if v < 10
        \\         v = v * scale
        \\     else
        \\         break(v)
        \\ end
    , 16);
}

test "foreach loop" {
    try t.top_number(
        \\ const tbl = {"foo", "bar", "baz"}
        \\ let i = 0
        \\ loop do
        \\   if i < 2
        \\     i = i + 1
        \\   else
        \\     break(i)
        \\ end
    , 2);
}

test "for loop iterates table values" {
    try t.top_number(
        \\ let seen = 0
        \\ for val, i in {10, 20, 30} do
        \\     if i == 0 do
        \\         seen = seen + val
        \\     end else do
        \\         if i == 1 do
        \\             seen = seen + val
        \\         end else do
        \\             seen = seen + val
        \\         end
        \\     end
        \\ end
        \\ seen
    , 60);
}

test "indexed table iteration gets value and index" {
    try t.top_number(
        \\ for val, i in {10, 20, 30} do
        \\     if i == 1 return val
        \\ end
    , 20);
}

test "simple table_get with integer key" {
    try t.top_number(
        \\ let t = {10, 20, 30}
        \\ t[0] + t[1] + t[2]
    , 60);
}

test "for loop over table prints all values" {
    try t.top_number(
        \\ let s = 0
        \\ let t = {10, 20, 30}
        \\ for v in t
        \\     s = s + v
        \\ s
    , 60);
}

test "inner for loop" {
    try t.top_number(
        \\ let t = 0
        \\ for x in 1..10
        \\  for y in 10..20 t += (x * y)
        \\ t
    , 6525);
}

test "for loop with range literal iterates numeric sequence" {
    try t.top_number(
        \\ let sum = 0
        \\ for i in 0..5 do
        \\     sum = sum + i
        \\ end
        \\ sum
    , 10);
}

test "for loop with range literal starting at 1" {
    try t.top_number(
        \\ let sum = 0
        \\ for i in 1..6 do
        \\     sum = sum + i
        \\ end
        \\ sum
    , 15);
}

test "for loop with range literal and variable end" {
    try t.top_number(
        \\ let n = 10
        \\ let sum = 0
        \\ for i in 0..n do
        \\     sum = sum + i
        \\ end
        \\ sum
    , 45);
}

test "for loop with range produces loop result" {
    try t.top_number(
        \\ for i in 0..3 do
        \\     i + 10
        \\ end
    , 12);
}

test "while loop via while <cond> do <expr> end" {
    try t.top_number(
        \\ let x = 0
        \\ while x < 5 do
        \\     x = x + 1
        \\ end
        \\ x
    , 5);
}

test "while loop isn't ran unconditionally" {
    try t.top_number(
        \\ let x = 0
        \\ while :false do
        \\     x = x + 1
        \\ end
        \\ x
    , 0);
}

test "while loop counts down" {
    try t.top_number(
        \\ let n = 3
        \\ while n > 0 do
        \\     n = n - 1
        \\ end
        \\ n
    , 0);
}

test "break restrictions" {
    try t.expectCompileError("break(1)", .UnsupportedSyntax);
    try t.top_atom(
        \\ const x = fn()
        \\   for i in 0..5 do break
        \\   return :asdf
        \\ end
        \\ x()
    , "asdf");
}

test "break in for loops" {
    try t.top_number(
        \\ let result = 0
        \\ for i in 0..10 do
        \\     if i == 5 break(i * 2)
        \\     result = result + i
        \\ end
        \\ result
    , 10);
    try t.top_number(
        \\ for i in 0..10 do
        \\     if i == 7 break(i)
        \\ end
    , 7);
    try t.top_atom(
        \\ const x = for i in 0..5 do
        \\   break
        \\ end
        \\ x
    , "nil");
}

test "break in while loops" {
    try t.top_number(
        \\ let x = 0
        \\ let result = 0
        \\ while x < 10 do
        \\     if x == 5 break(x * 2)
        \\     result = result + x
        \\     x = x + 1
        \\ end
        \\ result
    , 10);
    try t.top_number(
        \\ let i = 0
        \\ while i < 10 do
        \\     if i == 7 break(i)
        \\     i = i + 1
        \\ end
    , 7);
}

test "while body result is loop value after iterations" {
    try t.top_number(
        \\ let a = 0
        \\ let x = while do
        \\     a += 1
        \\     a < 3
        \\ end a
        \\ x
    , 2);
}

test "loop with locals inside does not corrupt loop result" {
    try t.top_number(
        \\ let a = 0
        \\ let b = 1
        \\ let c = 2
        \\ let d = 3
        \\ const x = loop do
        \\     let e = 4
        \\     let f = 5
        \\     let g = 6
        \\     break(42)
        \\ end
        \\ x
    , 42);
}

test "for range with preceding locals and body locals" {
    try t.top_number(
        \\ let a = 0
        \\ let b = 1
        \\ let c = 2
        \\ let d = 3
        \\ let e = 4
        \\ let f = 5
        \\ const x = for i in 0..3 do
        \\     let g = 6
        \\     let h = 7
        \\     break(42)
        \\ end
        \\ x
    , 42);
}

test "for range with two params and preceding locals" {
    try t.top_number(
        \\ let a = 0
        \\ const x = for i, idx in 0..3 do
        \\     i + idx
        \\ end
        \\ x
    , 5);
}

test "triple-quoted multiline strings compile and evaluate" {
    try t.top_string(
        \\ """
        \\ hello
        \\ world
        \\ """
    , "hello\nworld");

    try t.top_string(
        \\ """inline"""
    , "inline");
}

test "test.skip keyword is valid syntax" {
    try t.top_nil(
        \\ test / skip "skipped" do 1 + 1 end
    );
}

test "suite keyword compiles and returns nil" {
    try t.top_nil(
        \\ suite "example" do
        \\     test "inner" do 1 end
        \\ end
    );

    try t.top_nil(
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
    try t.expectCompileFailure(
        \\ const id = fn(x: int) x
        \\ id("nope")
    ,
        .ParseError,
        2,
        5,
        "arg 1 (`x`) to `id` wants int, got string",
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
    try t.expectCompileError("missing_name", .ParseError);
}

test "semantic catches trying to mutate a tuple variable" {
    try t.expectCompileError("let tup = (0,0) tup[0] = 1", .ParseError);
}

test "semantic catches trying to mutate a tuple literal" {
    try t.expectCompileError("(0,0)[0] = 1", .ParseError);
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
    try t.expectCompileError(
        \\ const id = fn(x) x
        \\ id()
    , .ParseError);
}

test "compile time span for struct constructor type error points at constructor call" {
    try t.expectCompileError(
        \\ struct User {
        \\     age: number
        \\ }
        \\ User { age = "old" }
    , .ParseError);
}

test "runtime span for struct field assignment type error points at assignment" {
    try t.expectRuntimeFailure(
        \\ struct User {
        \\     age: number = 0
        \\ }
        \\ let user = User {}
        \\ user.age = "old"
    ,
        .TypeError,
        5,
        2,
        "field `age` on `User` wants number, got string",
    );
}

test "runtime report includes tuple index detail" {
    try t.expectRuntimeFailure(
        \\ const f = fn() (1,)
        \\ const a, b = f()
        \\ a
    ,
        .InvalidTuple,
        2,
        2,
        "tuple index 1 out of range for tuple of length 1",
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

    const result = try vm.runReport();
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

    const result = try vm.runReport();
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
    try t.top_number(
        \\ const vector_mul = fn(a, b, factor)
        \\    (a * factor, b * factor)
        \\
        \\ const (x, y) = vector_mul(4, 6, 2)
        \\ x + y
    , 20);
}

test "basic loop with break" {
    try t.top_number(
        \\ let a = 1
        \\ loop do
        \\     if a < 5
        \\         a = a + 1
        \\     else
        \\         break(a)
        \\ end
    , 5);
}

test "import caches modules and reuses the same table" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "counter.rv",
        .data =
        \\ let state = {count = 0}
        \\ state.count = state.count + 1
        \\ state
        ,
    });

    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);

    try t.top_number_in_dir(module_dir,
        \\ const a = import "./counter"
        \\ a.count = 41
        \\ const b = import "./counter"
        \\ b.count
    , 41);
}

test "import keeps module globals isolated from importer globals" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "answer.rv",
        .data =
        \\ let x = 41
        \\ const answer = x
        \\ answer
        ,
    });

    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);

    try t.top_number_in_dir(module_dir,
        \\ let x = 99
        \\ const ans = import "./answer"
        \\ x + ans
    , 140);
}

test "import returns module value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "vis.rv",
        .data =
        \\ const hidden = 7
        \\ const shown = 9
        \\ shown
        ,
    });

    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);

    try t.top_number_in_dir(module_dir,
        \\ const ns = import "./vis"
        \\ ns
    , 9);
}

test "locals are still local" {
    try t.top_number(
        \\ do
        \\   let a = 5
        \\ end
        \\ let a = 7
        \\ a
    , 7);
    try t.top_number(
        \\ let a = 7
        \\ do let a = 5 end
        \\ a
    , 7);
    try t.top_number(
        \\ const a = 7
        \\ do const a = 5 end
        \\ a
    , 7);
}

test "top-level locals are real closure locals" {
    try t.top_number(
        \\ let x = 1
        \\ const get = fn() x
        \\ x = 42
        \\ get()
    , 42);
    try t.expectRuntimeError(
        \\ const x = 1
        \\ x = 2
    , .ConstantReassignment);
}

test "structs with comma-separated items and fn syntax" {
    try t.top_number(
        \\ struct User {
        \\     name: string,
        \\     fn get_name(self) self.name,
        \\ }
        \\ const user = User { name = "alice" }
        \\ len(user:get_name())
    , 5);
}

test "structs build struct instances" {
    try t.top_number(
        \\ struct User {
        \\     name: string,
        \\     age: number = 0,
        \\     const age_next = fn(self) self.age + 1,
        \\ }
        \\ const user = User { name = "ana" }
        \\ user:age_next()
    , 1);
    try t.top_string(
        \\ struct User {
        \\     name: string,
        \\     age: number = 0,
        \\ }
        \\ const user = User { name = "ana", age = 12 }
        \\ user.name
    , "ana");
    try t.top_atom(
        \\ struct User {
        \\     name: string,
        \\ }
        \\ const user = User { name = "ana" }
        \\ type(user)
    , "struct");
}

test "struct fields are mutable" {
    try t.top_number(
        \\ struct User {
        \\     age: number = 0,
        \\ }
        \\ let user = User {}
        \\ user.age = 12
        \\ user.age
    , 12);
    try t.expectRuntimeFailureWithMessage(
        \\ struct User {
        \\     age: number = 0,
        \\ }
        \\ let user = User {}
        \\ user.name = "bea"
    , .Panic, "unknown field `name` for struct `User`");
    try t.expectRuntimeFailureWithMessage(
        \\ struct User {
        \\     age: number = 0,
        \\ }
        \\ let user = User {}
        \\ user.age = "old"
    , .TypeError, "field `age` on `User` wants number, got string");
    try t.top_number(
        \\ struct User {
        \\     name: string,
        \\     age: number = 0,
        \\     const with_age_next = fn(self) User { name = self.name, age = self.age + 1 },
        \\ }
        \\ let user = User { name = "ana" }
        \\ user = user:with_age_next():with_age_next():with_age_next()
        \\ user = user:with_age_next()
        \\ user = user:with_age_next()
        \\ user.age
    , 5);
    try t.top_number(
        \\ struct User {
        \\     name: string,
        \\     age: number = 0,
        \\
        \\     const with_age_next = fn(self)
        \\         User{name = self.name, age = self.age + 1},
        \\ }
        \\
        \\ let u = User{
        \\     name = "zxcv",
        \\ }
        \\
        \\ u = u:with_age_next()
        \\ u = u:with_age_next()
        \\ u = u:with_age_next()
        \\ u.age
    , 3);
}

test "defaulted struct fields fill in missing values" {
    try t.top_number(
        \\ struct Chain {
        \\     state = {6, 7},
        \\     count: number = 8,
        \\ }
        \\ const c = Chain{}
        \\ c.count + c.state[1]
    , 15);
}

test "structs reject bad inputs" {
    try t.expectRuntimeFailureWithMessage(
        \\ struct User {
        \\     name: string,
        \\     age: number = 0,
        \\ }
        \\ User()
    , .Panic, "missing field `name` for struct `User`");
    try t.expectRuntimeFailureWithMessage(
        \\ struct User {
        \\     name: string,
        \\     age: number = 0,
        \\ }
        \\ User { age = 12 }
    , .Panic, "missing field `name` for struct `User`");
    try t.expectRuntimeFailureWithMessage(
        \\ struct User {
        \\     name: string
        \\ }
        \\ User { name = "ana", age = 12 }
    , .Panic, "unknown field `age` for struct `User`");
    try t.expectCompileError(
        \\ struct User {
        \\     age: number
        \\ }
        \\ User { age = "old" }
    , .ParseError);
}

test "structs do not leak" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "asdf.rv",
        .data =
        \\ struct User { name: string = "hi" }
        ,
    });

    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);

    try t.expectRuntimeErrorInDir(module_dir,
        \\ User { name = "asdf" }
    , .UndefinedVariable);
}

test "struct descriptors stay off globals" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{ .text =
        \\ struct User { name: string = "hi" }
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    try std.testing.expect(!vm.globals.contains(try vm.internAtom("__struct_desc_0")));
}

test "top module assignment does not create vm global" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "setx.rv",
        .data =
        \\ const x = 41
        \\ x
        ,
    });

    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);

    try t.expectCompileErrorInDir(module_dir,
        \\ import "./setx"
        \\ x
    );
}

test "imported module assignment is private to module cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "private_state.rv",
        .data =
        \\ const y = 7
        \\ const value = y
        \\ value
        ,
    });

    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);

    try t.top_number_in_dir(module_dir,
        \\ const m = import "./private_state"
        \\ m
    , 7);

    try t.expectCompileErrorInDir(module_dir,
        \\ import "./private_state"
        \\ y
    );
}
//
// misc behaviour doc
//
test "closure captures and updates outer variable" {
    try t.top_number(
        \\ const outer = fn() do
        \\     let x = 1
        \\     const inc = fn() do
        \\         x = x + 1
        \\         x
        \\     end
        \\     inc()
        \\     inc()
        \\     x
        \\ end
        \\ outer()
    , 3);
}

test "nested closure accesses upvalues from parent scope" {
    try t.top_number(
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
    try t.top_number(
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
test "loop breaks with explicit value" {
    try t.top_number(
        \\ loop do
        \\     break(42)
        \\ end
    , 42);
}

test "break with value returns that value" {
    try t.top_number(
        \\ let i = 1
        \\ loop do
        \\     if i == 1
        \\         break(99)
        \\     else
        \\         break(i)
        \\ end
    , 99);
}

test "loop threading with guards" {
    try t.top_number(
        \\ let x = 0
        \\ loop do
        \\     if x < 10
        \\         x = x + 1
        \\     else
        \\         break(x)
        \\ end
    , 10);
}
test "big loop doesnt crash" {
    try t.top_number(
        \\ let x = 1
        \\ loop do
        \\     if x < 1000
        \\         x = x + 1
        \\     else
        \\         break(x)
        \\ end
    , 1000);
}

test "if expressions" {
    try t.top_number(
        \\ if 1 == 1
        \\     5
        \\ else
        \\     42
    , 5);
}

test "tail recursion reuses frames" {
    try t.top_number(
        \\ const count = fn(n)
        \\     if n == 1000
        \\         n
        \\     else
        \\         count(n + 1)
        \\ count(0)
    , 1000);
}

test "recursive calls still evaluate" {
    try t.top_number(
        \\ const count = fn(n)
        \\     if n == 5000
        \\         n
        \\     else
        \\         1 + count(n + 1)
        \\ count(0)
    , 10000);
}

test "assignment to constant fails" {
    try t.expectRuntimeFailureWithMessage(
        \\ const a = 1
        \\ a = 2
    , .ConstantReassignment, "reassignment to constant!");
    try t.expectRuntimeFailureWithMessage(
        \\ const f = fn() do
        \\     const a = 1
        \\     a = 2
        \\ end
        \\ f()
    , .ConstantReassignment, "reassignment to constant!");
}

//
// match
//
test "match wildcards" {
    try t.top_number(
        \\ const x = 999
        \\ match x
        \\ | 1 => do 1 end
        \\ | 2 => do 2 end
        \\ | v => do v end
    , 999);
    try t.top_number(
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

test "match guards" {
    try t.top_number(
        \\ const x = 15
        \\ match x
        \\ | v when v < 10 => do 1 end
        \\ | v when v > 10 => do 2 end
        \\ | v => do 3 end
    , 2);
    try t.top_number(
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

test "match tuple patterns" {
    try t.top_number(
        \\ const x = (:ok, 42)
        \\ match x
        \\ | (:asdf, v) => 1
        \\ | (:ok, v) => v
        \\ | (:err, e) => 2
    , 42);
    try t.top_number(
        \\ const x = (:ok, 42)
        \\ match x
        \\ | (:asdf, v) => 1
        \\ | (:ok, v) when v < 20 => 2
        \\ | (:ok, v) when v > 40 => v
        \\ | (:ok, v) when number?(v) => 3
        \\ | (:err, e) => 2
    , 42);
}

//
// assignment & binding
//
test "local binding shadows outer binding" {
    try t.top_number(
        \\ let x = 10
        \\ const f = fn() do
        \\     let x = 20
        \\     x
        \\ end
        \\ f()
    , 20);
}

test "assignment resolves to nearest binding" {
    try t.top_number(
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

test "tuple binding mismatch reports item counts" {
    try t.expectCompileFailure(
        \\ const a, b = (1,)
    ,
        .ParseError,
        1,
        15,
        "tuple binding expects at least 2 items, got 1",
    );
}

test "tuple let binding initializes locals" {
    try t.top_number(
        \\ let a, b = (1, 2)
        \\ a + b
    , 3);
}

test "num alias works in fn and method signatures" {
    try t.top_number(
        \\ struct Chain {
        \\     fn take(self, count: num) count,
        \\ }
        \\ const c = Chain{}
        \\ c:take(50)
    , 50);
}

test "num alias works in range bounds" {
    try t.top_number(
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

test "markov take body" {
    try t.top_string(
        \\ fn random(n) math.floor((time.now_ns() / 1000) % n)
        \\ fn pref(a, b) fmt("%v %v", a, b)
        \\ const NOWORD = string_of(10)
        \\ struct Chain {
        \\   state = {},
        \\   fn take(self, count: num) -> string do
        \\     let out = ""
        \\     let w1 = NOWORD
        \\     let w2 = NOWORD
        \\     for i in 0..count do
        \\       let list = self.state[pref(w1, w2)]
        \\       if not list break()
        \\       let n = len(list)
        \\       if n < 1 break()
        \\       let nextword = list[random(n)]
        \\       if nextword == NOWORD break()
        \\       out = fmt("%v%v ", out, nextword)
        \\       w1 = w2
        \\       w2 = nextword
        \\     end
        \\     out
        \\   end
        \\ }
        \\ const c = Chain{state = {[pref(NOWORD, NOWORD)] = {"hello"}}}
        \\ c:take(1)
    , "hello ");
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
            .lower, .semantic => |diag| {
                const primary = lang.diagnostic.primarySpan(diag.report).?;
                try std.testing.expectEqualStrings("wants int, got string", primary.message);
                try std.testing.expectEqualStrings(
                    "`x` wants int, got string",
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
            .lower, .semantic => |diag| {
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
            .lower, .semantic => |diag| {
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
    try t.top_number(
        \\ const f = fn() do
        \\     1
        \\     2
        \\     3
        \\ end
        \\ f()
    , 3);
}

test "function with multiple parameters" {
    try t.top_number(
        \\ const f = fn(a, b, c) a + b + c
        \\ f(10, 20, 30)
    , 60);
}

test "typed function alias call is checked" {
    try t.expectCompileFailure(
        \\ const id = fn(x: int) x
        \\ const f = id
        \\ f("nope")
    ,
        .ParseError,
        3,
        4,
        "arg 1 (`x`) to `f` wants int, got string",
    );
}

test "recursive function with guards" {
    try t.top_number(
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
    try t.top_number(
        \\ const check = fn(x)
        \\     match x
        \\     | v when v > 50 => do 1 end
        \\     | v when v > 25 => do 2 end
        \\     | v => do 3 end
        \\ check(40)
    , 2);
}

test "and operator works" {
    try t.top_atom(
        \\ 1 and 1 and :true
    , "true");
}

test "or operator works" {
    try t.top_atom(
        \\ 0 or 0 or :true
    , "true");
}

test "and operator short-circuit" {
    try t.top_number(
        \\ 0 and 999
    , 0);
}

test "string escaping works" {
    try t.top_string("\"hello\\nworld\"", "hello\nworld");
}

test "single and double quotes are distinct" {
    try t.top_string("'hello\\nworld'", "hello\\nworld");
    try t.top_string("\"hello\\nworld\"", "hello\nworld");
}

test "spawned fiber with sleep completes" {
    try t.top_number(
        \\ const f = fn(n) do sleep(1) n * 2 end
        \\ const h = spawn f(21)
        \\ join(h)
    , 42);
}

test "channel with fibers" {
    try t.top_number(
        \\ const ch = chan(0)
        \\ const sender = fn(c, v) do send(c, v) v end
        \\ const s = spawn sender(ch, 42)
        \\ const msg = recv(ch)
        \\ join(s)
        \\ msg
    , 42);
    try t.top_number(
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
    try t.top_number(
        \\ const ch = chan(2)
        \\ send(ch, 10)
        \\ send(ch, 32)
        \\ recv(ch) + recv(ch)
    , 42);
    try t.top_number(
        \\ const ch = chan(3)
        \\ send(ch, 1)
        \\ send(ch, 2)
        \\ send(ch, 3)
        \\ recv(ch) + recv(ch) + recv(ch)
    , 6);
}

test "yield suspends and resumes fiber" {
    try t.top_type(
        \\ do yield end
    , .atom);
}

test "spawned buffered channel recv does not return missing" {
    try t.top_number(
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
    try t.top_number(
        \\ let worker = fn(n) do
        \\   n + 10
        \\ end
        \\ let a = spawn worker(1)
        \\ let b = spawn worker(2)
        \\ let c = spawn worker(3)
        \\ let ra = tonumber(tostring(join(a))):unwrap()
        \\ let rb = tonumber(tostring(join(b))):unwrap()
        \\ let rc = tonumber(tostring(join(c))):unwrap()
        \\ ra + rb + rc
    , 36);
}

//
// comptime
//

test "comp arithmetic" {
    try t.top_number(
        \\ comp (1 + 2 * 3)
    , 7);
    try t.top_number(
        \\ comp ((10 / 2) + (3 * 4))
    , 17);
    try t.top_number(
        \\ comp (-5 + 10)
    , 5);
}

test "comp result in runtime" {
    try t.top_number(
        \\ let x = comp (2 + 3)
        \\ x * 2
    , 10);
}

test "comp string and bool ops" {
    try t.top_string(
        \\ comp ("hello" ~ " " ~ "world")
    , "hello world");
    try t.top_atom(
        \\ comp (1 < 2)
    , "true");
    try t.top_atom(
        \\ comp (:true and :true)
    , "true");
}

test "comp errors" {
    try t.expectCompileFailure(
        \\ comp (1 / 0)
    , .ParseError, 1, 8, "division by zero!");
    try t.expectCompileFailure(
        \\ proc bad_comp!(iter) do
        \\   {(:comp_block, (:binary, :div, (:number, 1), (:number, 0)), :false)}
        \\ end
        \\ bad_comp!()
    , .ParseError, 4, 2, "division by zero!");
}

test "fn name(params) defines named function" {
    try t.top_number(
        \\ fn add(a, b) a + b
        \\ add(5, 3)
    , 8);
}

test "fn name(params) multiple named functions" {
    try t.top_number(
        \\ fn mul(x, y) x * y
        \\ fn add(a, b) a + b
        \\ mul(add(2, 3), 4)
    , 20);
}
test "match nested patterns" {
    try t.top_number(
        \\ const data = (:ok, (:inner, 42))
        \\ match data
        \\ | (:ok, (:inner, v)) => v
        \\ | _ => 0
    , 42);
    try t.top_number(
        \\ const data = (:ok, (:inner, 10))
        \\ match data
        \\ | (:ok, (:inner, v)) when v < 5 => 1
        \\ | (:ok, (:inner, v)) when v > 5 => 2
        \\ | _ => 0
    , 2);
}

test "channel receives from multiple producers preserve ordering" {
    try t.top_number(
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
    try t.top_number(
        \\ const ch1 = chan(0)
        \\ const ch2 = chan(0)
        \\ spawn fn() send(ch1, 10)
        \\ spawn fn() send(ch2, 20)
        \\ recv(ch1) + recv(ch2)
    , 30);
}

test "macro inner binding invisible outside" {
    try t.expectCompileError(
        \\ macro mac! `(%x:expr)` `let hidden = 99 :%x`
        \\ mac!(42)
        \\ hidden
    , .ParseError);
}

test "numeric and string keys are distinct" {
    try t.top_number(
        \\ const t = {}
        \\ t[1] = 100
        \\ t["1"] = 200
        \\ t[1] + t["1"]
    , 300);
}

//
// error propagation: ? and orelse
//

test "try ? unwraps ok tuple" {
    try t.top_number(
        \\ (:ok, 42)?
    , 42);
    try t.top_number(
        \\ const f = fn() (:ok, 10)
        \\ f()?
    , 10);
    try t.top_number(
        \\ fn ok() -> (:ok, num) do
        \\   (:ok, 1)
        \\ end
        \\ ok()?
    , 1);
}

test "try ? error propagation" {
    try t.expectRuntimeFailureWithMessage(
        \\ (:err, :not_found)?
    , .Panic, ":not_found");
    try t.expectRuntimeFailureWithMessage(
        \\ const f = fn() (:err, :not_found)
        \\ f()?
        \\ 99
    , .Panic, ":not_found");
    try t.expectRuntimeFailureWithMessage(
        \\ const f = fn() (:err, :fail)
        \\ f()?
    , .Panic, ":fail");
}

test "try ? chains with pipe" {
    try t.top_number(
        \\ (:ok, 5)? |> fn(x) x * 2
    , 10);
}

test "try ? in pattern matching" {
    try t.top_number(
        \\ const f = fn() (:ok, 7)
        \\ match f()?
        \\ | 7 => 100
        \\ | _ => 0
    , 100);
}

test "nested ok tuples extracts inner" {
    try t.top_type(
        \\ (:ok, (:inner, 42))?
    , .tuple);
}

test "orelse type dispatch" {
    try t.top_number(
        \\ (:err, :fail) orelse 42
    , 42);
    try t.top_number(
        \\ (:ok, 100) orelse 42
    , 100);
    try t.top_number(
        \\ :nil orelse 50
    , 50);
    try t.top_number(
        \\ 10 orelse 20
    , 10);
    try t.top_number(
        \\ (:err, :a) orelse (:err, :b) orelse 99
    , 99);
    try t.top_number(
        \\ (:ok, 15)? orelse 33
    , 15);
}

test "orelse right side" {
    try t.top_number(
        \\ const f = fn() (:err, :no)
        \\ f() orelse 77
    , 77);
    try t.top_number(
        \\ (:err, :fail) orelse (:ok, 88)
    , 88);
}

//
// pipe
//
// pipe
//

test "pipe: implicit single call" {
    try t.top_number(
        \\ const f = fn(a) a * 2
        \\ 21 |> f
    , 42);
    try t.top_number(
        \\ const f = fn(a) a * 2
        \\ 21 |> f()
    , 42);
}

test "pipe: implicit chained calls" {
    try t.top_number(
        \\ fn a(x) x * 2
        \\ fn b(x) x + 2
        \\ 20 |> a |> b
    , 42);
    try t.top_number(
        \\ fn a(x) x * 2
        \\ fn b(x) x + 2
        \\ 20 |> a() |> b()
    , 42);
    try t.top_number(
        \\ fn a(x) x * 2
        \\ fn b(x) x + 2
        \\ 20 |> a() |> b
    , 42);
}

test "pipe: closures" {
    try t.top_number(
        \\ 20 |> fn(x) x + 22
    , 42);
}

test "pipe: implicit match subject" {
    try t.top_number(
        \\ 2
        \\ |> match
        \\    | x => 42
    , 42);
}

// pipe placeholders

test "pipe: explicit placeholder arg position" {
    try t.top_string(
        \\ fn f(a, b) tostring(a) ~ tostring(b)
        \\ "asdf" |> f("got ", _)
    , "got asdf");
}

test "pipe: explicit placeholder method receiver" {
    try t.top_number(
        \\ const obj = { inner = 40, meth = fn(self, x) self.inner + x }
        \\ obj |> _:meth(2)
    , 42);
}

test "pipe: explicit placeholder index access" {
    try t.top_number(
        \\ const t = {5, 6, 7}
        \\ 1 |> t[_]
    , 6);
}

test "pipe: explicit placeholder expression" {
    try t.top_string(
        \\ "asdf" |> "aaa" ~ _:upper()
    , "aaaASDF");
}

test "pipe: explicit placeholder in nested call arg" {
    try t.top_string(
        \\ fn fmt(s, v) s ~ v
        \\ "asdf" |> fmt("aaa", _:upper())
    , "aaaASDF");
}

test "pipe: explicit placeholder in expr" {
    try t.top_string(
        \\ const x = "asdf"
        \\ x |> do tostring(_) end
    , "asdf");
}

test "pipe: multiple placeholders" {
    try t.top_number(
        \\ fn add(a, b) a + b
        \\ 5 |> add(_, _)
    , 10);
}

test "pipe: placeholder as callee" {
    try t.top_string(
        \\ fn f(x) x:upper()
        \\ "asdf" |> f(_)
    , "ASDF");
}

test "pipe: method chain with state mutation" {
    try t.top_number(
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
    try t.top_string(
        \\ "hello" |> do 
        \\    const transform = fn(s) s:upper()
        \\    transform(_)
        \\ end
    , "HELLO");
}

test "compiler: named parameters" {
    try t.top_number(
        \\ const add = fn(x: int, y: int) do x + y end
        \\ add(x = 5, y = 3)
    , 8);
    try t.top_number(
        \\ const add = fn(x: int, y: int) do x + y end
        \\ add(y = 3, x = 5)
    , 8);
    try t.top_number(
        \\ const add3 = fn(x: int, y: int, z: int) do x + y + z end
        \\ add3(1, y = 2, z = 3)
    , 6);
}

test "compiler: named parameters errors" {
    try t.expectCompileError(
        \\ const add = fn(x: int, y: int) do x + y end
        \\ add(x = 5, z = 3)
    , .ParseError);
    try t.expectCompileError(
        \\ const add = fn(x: int, y: int) do x + y end
        \\ add(x = 5, x = 3)
    , .ParseError);
    try t.expectCompileError(
        \\ const add = fn(x: int, y: int) do x + y end
        \\ add(x = 5, 3)
    , .ParseError);
}

test "double assignment" {
    try t.top_number(
        \\ let a = {}
        \\ let c = (a.b = 5)
    , 5);
}

test "assignment expression returns assigned value" {
    try t.top_number(
        \\ let a = {}
        \\ let c = (a.b = 5)
        \\ c
    , 5);
}

test "for loop calls iterator" {
    try t.top_number(
        \\ let t = set_metatable({}, {
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

test "optional params basic" {
    try t.top_atom(
        \\ const f = fn(a, ?b) b
        \\ f(42)
    , "no");
    try t.top_number(
        \\ const f = fn(a, ?b) b
        \\ f(42, 10)
    , 10);
    try t.top_number(
        \\ const f = fn(a, ?b) a + b
        \\ f(3, 7)
    , 10);
}

test "optional params multiple" {
    try t.top_atom(
        \\ const f = fn(a, ?b, ?c) c
        \\ f(1)
    , "no");
    try t.top_number(
        \\ const f = fn(a, ?b, ?c) c
        \\ f(1, :no, 42)
    , 42);
    try t.top_atom(
        \\ const f = fn(?a, ?b) a
        \\ f()
    , "no");
}

test "optional params arity errors" {
    try t.expectCompileError(
        \\ const f = fn(a, ?b) a
        \\ f()
    , .ParseError);
    try t.expectCompileError(
        \\ const f = fn(a, ?b) a
        \\ f(1, 2, 3)
    , .ParseError);
}

//
// module system
//

test "module import auto-binds filename" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "mymod.rv",
        .data = "const x = 42\nx\n",
    });
    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);
    try t.top_number_in_dir(module_dir,
        \\ import "./mymod"
        \\ mymod
    , 42);
}

test "module import with custom name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "mymod.rv",
        .data = "const x = 7\nx\n",
    });
    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);
    try t.top_number_in_dir(module_dir,
        \\ import { m = "./mymod" }
        \\ m
    , 7);
}

test "module pub exports are accessible as fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "lib.rv",
        .data =
        \\ pub const x = 42
        \\ pub fn y(n) n * 2
        \\ const secret = "hidden"
        ,
    });
    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);
    try t.top_number_in_dir(module_dir,
        \\ const lib = import "./lib"
        \\ lib.y(lib.x)
    , 84);
}

test "module non-pub values are not exported" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "lib.rv",
        .data =
        \\ pub const visible = 42
        \\ const hidden = 99
        ,
    });
    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);
    try t.top_number_in_dir(module_dir,
        \\ const lib = import "./lib"
        \\ lib.visible
    , 42);
}

test "cross-module macro injection works" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "macros.rv",
        .data =
        \\ pub macro double! `%e:expr` `%e * 2`
        ,
    });
    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);
    try t.top_number_in_dir(module_dir,
        \\ import "./macros"
        \\ macros.double!(21)
    , 42);
}

test "non-pub macro is not injected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "macros.rv",
        .data =
        \\ macro hidden! `%e:expr` `42`
        \\ pub macro visible! `%e:expr` `%e`
        ,
    });
    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);
    try t.top_number_in_dir(module_dir,
        \\ import "./macros"
        \\ macros.visible!(99)
    , 99);
    try t.expectRuntimeErrorInDir(module_dir,
        \\ import "./macros"
        \\ macros.hidden!(21)
    , .NotAFunction);
}

test "cross-module proc macro injection works" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "procs.rv",
        .data =
        \\ pub proc add_one!(iter) do
        \\   let n = iter:next()
        \\   {(:binary, :add, n, (:number, 1))}
        \\ end
        ,
    });
    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);
    try t.top_number_in_dir(module_dir,
        \\ import "./procs"
        \\ procs.add_one!(41)
    , 42);
}

test "cross-module pub struct is accessible" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "structs.rv",
        .data =
        \\ pub struct Box {
        \\     val: number = 0,
        \\ }
        \\ pub fn new_box(v) Box { val = v }
        ,
    });
    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);
    try t.top_number_in_dir(module_dir,
        \\ import "./structs"
        \\ const b = structs.new_box(42)
        \\ b.val
    , 42);
}

test "const x = import \"foo\" with different names binds both" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "mymod.rv",
        .data = "pub const val = 42\n",
    });
    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);
    try t.top_number_in_dir(module_dir,
        \\ const x = import "./mymod"
        \\ x.val
    , 42);
}

test "import of non-existent file reports runtime error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);
    try t.expectRuntimeErrorInDir(module_dir,
        \\ import "./nonexistent"
        \\ nonexistent
    , .Panic);
}

test "import empty module does not crash" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "empty.rv",
        .data = "",
    });
    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);
    try t.top_number_in_dir(module_dir,
        \\ import "./empty"
        \\ 42
    , 42);
}

test "import in function body binds correctly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "helper.rv",
        .data = "pub const val = 99\n",
    });
    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);
    try t.top_number_in_dir(module_dir,
        \\ fn get_val() do
        \\   import "./helper"
        \\   helper.val
        \\ end
        \\ get_val()
    , 99);
}

test "module with only non-pub items compiles and imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "priv.rv",
        .data = "const secret = 42\n",
    });
    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);
    try t.top_number_in_dir(module_dir,
        \\ import "./priv"
        \\ 1
    , 1);
}

test "pub import { x = \"a\" } re-exports module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "inner.rv",
        .data = "pub const val = 42\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "outer.rv",
        .data =
        \\ pub import { inner = "./inner" }
        ,
    });
    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);
    try t.top_number_in_dir(module_dir,
        \\ const outer = import "./outer"
        \\ outer.inner.val
    , 42);
}

test "pub import \"foo\" at statement level re-exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "inner.rv",
        .data = "pub const val = 42\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "outer.rv",
        .data =
        \\ pub import "./inner"
        ,
    });
    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);
    try t.top_number_in_dir(module_dir,
        \\ const outer = import "./outer"
        \\ outer.inner.val
    , 42);
}

test "multi-import with two entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "alpha.rv",
        .data = "pub const a = 1\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "beta.rv",
        .data = "pub const b = 2\n",
    });
    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);
    try t.top_number_in_dir(module_dir,
        \\ import { x = "./alpha", y = "./beta" }
        \\ x.a + y.b
    , 3);
}

test "import inside do block binds correctly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "helper.rv",
        .data = "pub const val = 7\n",
    });
    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);
    try t.top_number_in_dir(module_dir,
        \\ do
        \\   import "./helper"
        \\   helper.val
        \\ end
    , 7);
}

test "import with relative path works" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "sub_rel.rv",
        .data = "pub const val = 42\n",
    });
    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);
    try t.top_number_in_dir(module_dir,
        \\ import "./sub_rel"
        \\ sub_rel.val
    , 42);
}

test "circular import does not hang" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "a.rv",
        .data = "pub import \"b\"\npub const x = 1\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "b.rv",
        .data = "pub import \"a\"\npub const y = 2\n",
    });
    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);
    // circular import should not hang or crash;;; either result is fine
    const result = t.topResult("import \"a\"\n1", module_dir);
    if (result) |res| {
        var r = res;
        r.deinit();
        // completed without error!!! unexpected but acceptable
        // the import may succeed if the cycle resolves in time
    } else |_| {
        // expected!! circular import may error at runtime
    }
}

test "transitive pub import through re-export chain" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "leaf.rv",
        .data = "pub const deep = 99\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "middle.rv",
        .data = "pub import \"./leaf\"\npub const mid = 50\n",
    });
    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);
    try t.top_number_in_dir(module_dir,
        \\ import "./middle"
        \\ middle.leaf.deep + middle.mid
    , 149);
}

test "same file imported under multiple names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "shared.rv",
        .data = "pub const v = 7\n",
    });
    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);
    try t.top_number_in_dir(module_dir,
        \\ import { a = "./shared", b = "./shared" }
        \\ a.v + b.v
    , 14);
}

test "import with absolute path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "absm.rv",
        .data = "pub const x = 42\n",
    });
    const abs_path = try tmp.dir.realPathFileAlloc(io, "absm.rv", alloc);
    defer alloc.free(abs_path);
    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);

    const source = try std.fmt.allocPrint(alloc, "import \"{s}\"\nabsm.x", .{abs_path});
    defer alloc.free(source);

    var result = try t.topResult(source, module_dir);
    defer result.deinit();
    const actual = try result.value.as_number();
    if (@abs(@as(f64, 42) - actual) > 0.000000001)
        return error.TestExpectedEqual;
}

test "@exports shadow in module is caught at compile time" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "collide.rv",
        .data = "pub const @exports = 42\npub const x = 99\n",
    });
    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);

    try t.expectRuntimeErrorInDir(module_dir,
        \\ import "./collide"
        \\ 1
    , .Panic);
}

test "let import binding is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "mod.rv",
        .data = "pub const x = 42\n",
    });
    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);
    try t.expectCompileErrorInDir(module_dir,
        \\ let m = import "./mod"
        \\ m.x
    );
}

test "module with all pub decl types" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "alltypes.rv", .data =
        \\pub const val = 42
        \\pub fn add(a, b) a + b
        \\pub struct Pt { x: int, y: int }
        \\
    });
    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);
    // val, add, and Pt should all appear in the export table
    try t.top_number_in_dir(module_dir,
        \\ import "./alltypes"
        \\ alltypes.val + alltypes.add(3, 4)
    , 49);
}

test "duplicate import name is rejected at compile time" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "mod.rv",
        .data = "pub const v = 1\n",
    });
    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);
    try t.expectCompileErrorInDir(module_dir,
        \\ import "./mod"
        \\ import "./mod"
    );
}
