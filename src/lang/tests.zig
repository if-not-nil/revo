//
// beware, this tests the whole language, start-to-finish
// maybe this should be src/tests.zig instead?
// big TODO: prefix test names with their scope so that i can grep "atom and find all atom tests
//
const std = @import("std");
const alloc = std.heap.page_allocator;
const io = std.testing.io;

const revo = @import("revo");
const lang = revo.lang;
const VM = revo.VM;
const Data = revo.Data;

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
    defer alloc.free(built.ok.instructions);
    defer alloc.free(built.ok.spans);
    try std.testing.expect(built.ok.instructions.len != 0);
}

test {
    _ = @import("expander.zig").testing;
    _ = std.testing.refAllDecls(@import("compiler.zig"));
}

//
// basic
//

test "arithmetic" {
    try t.top_number("1 + 2 * 3", 7);
}

test "negative and float arithmetic" {
    try t.top_number("-1", -1);
    try t.top_number("1.5 + 2.25", 3.75);
    try t.top_number("5.5 - 0.5", 5.0);
    try t.top_number("3.0 * 0.5", 1.5);
    try t.top_number("5.0 / 2.0", 2.5);
}

test "len" {
    try t.top_number("len(\"hi\")", 2);
}

test "stdlib json time and string modules are exposed" {
    try t.top_string("json.encode((\"a\", \"b\", \"c\")):unwrap()", "[\"a\",\"b\",\"c\"]");
    try t.top_number("json.decode(\"{\\\"a\\\":1}\"):unwrap().a", 1);
    try t.top_true("time.now() > 0");
    try t.top_number("len(string.split(\"a,b\", \",\"))", 2);
}

// talks too much
// test "weird metatable edge case" {
//     try t.top_nil(
//         \\ print("blah blah blah")
//         \\ "hello" |> print("yo", "hi")
//     );
// }

test "range sugar" {
    if (true) return error.SkipZigTest;
    // try t.top_string("tostring(0..)", "(:range_from, 0, 1)");
    try t.top_string("tostring(0..10)", "(range 0 1 10)");
    // try t.top_string("tostring(0.5..)", "(:range_from, 0.5, 1)");
    try t.top_string("tostring(0.5..2.5)", "(range 0.5 1 2.5)");
}

test "return statement" {
    try t.top_number(
        \\ do return 7 8 end
    , 7);
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

// test "atoms :t is :true and :f is :false" {
//     try t.top_true(":t == :true");
//     try t.top_true(":f == :false");
// }

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
    try t.top_true("(:t or :true or not nil or 1 or 1.0 or 67) == :t");
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

test "test blocks run in test mode" {
    try t.top_nil_test(
        \\test "smoke" do
        \\    expect(2 == 2)?
        \\end
    , true);
}

test "hash literals are real atoms" {
    try t.top_atom(":good", "good");
}

test "rejects unsupported forms for now" {}

test "field assignment works" {
    try t.top_true(
        \\ const sys = {answer = 41}
        \\ sys.answer = 1
        \\ sys.answer
    );
}

test "script metatable closures work through natives" {
    try t.top_number(
        \\ const mt = {__len = fn(self) 42}
        \\ const t = set_metatable({}, mt)
        \\ len(t)
    , 42);
    try t.top_string(
        \\ const mt = {__tostring = fn(self) "bag"}
        \\ const t = set_metatable({}, mt)
        \\ tostring(t)
    , "bag");
}

test "meatballs are distinct" {
    try t.top_string(
        \\ const a = set_metatable({}, {__tostring = fn(self) "foo"})
        \\ const b = set_metatable({}, {__tostring = fn(self) "bar"})
        \\ tostring(a)
    , "foo");

    try t.top_string(
        \\ const a = set_metatable(:true, {__tostring = fn(self) "foo"})
        \\ tostring(1 == 1)
    , "foo");
}

test "arithmetic metamethods __add __sub __mul __div" {
    try t.top_number(
        \\ const mt = {__add = fn(a, b) 100}
        \\ const t = set_metatable({}, mt)
        \\ t + 5
    , 100);
    try t.top_number(
        \\ const mt = {__sub = fn(a, b) 200}
        \\ const t = set_metatable({}, mt)
        \\ t - 3
    , 200);
    try t.top_number(
        \\ const mt = {__mul = fn(a, b) 300}
        \\ const t = set_metatable({}, mt)
        \\ t * 2
    , 300);
    try t.top_number(
        \\ const mt = {__div = fn(a, b) 400}
        \\ const t = set_metatable({}, mt)
        \\ t / 4
    , 400);
}

test "comparison metamethods __eq __ne __lt __gt __lte __gte" {
    try t.top_true(
        \\ const mt = {__eq = fn(a, b) 1}
        \\ const t = set_metatable({}, mt)
        \\ t == 5
    );
    try t.top_true(
        \\ const mt = {__ne = fn(a, b) 1}
        \\ const t = set_metatable({}, mt)
        \\ t != 5
    );
    try t.top_true(
        \\ const mt = {__lt = fn(a, b) 1}
        \\ const t = set_metatable({}, mt)
        \\ t < 5
    );
    try t.top_true(
        \\ const mt = {__gt = fn(a, b) 1}
        \\ const t = set_metatable({}, mt)
        \\ t > 5
    );
    try t.top_true(
        \\ const mt = {__lte = fn(a, b) 1}
        \\ const t = set_metatable({}, mt)
        \\ t <= 5
    );
    try t.top_true(
        \\ const mt = {__gte = fn(a, b) 1}
        \\ const t = set_metatable({}, mt)
        \\ t >= 5
    );
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

test "length metamethod __len" {
    try t.top_number(
        \\ const mt = {__len = fn(self) 99}
        \\ const t = set_metatable({}, mt)
        \\ len(t)
    , 99);
    try t.top_number(
        \\ const mt = {__len = fn(self) 5}
        \\ const t = set_metatable({x = 1, y = 2}, mt)
        \\ len(t)
    , 5);
}

test "metamethods receive correct arguments" {
    try t.top_number(
        \\ const mt = {__add = fn(a, b) if b == :second 123 else 0}
        \\ const t = set_metatable({}, mt)
        \\ t + :second
    , 123);
}

test "metatable on metatable works" {
    try t.top_number(
        \\ const meta_mt = {__len = fn(self) 9}
        \\ const mt = set_metatable({}, meta_mt)
        \\ len(mt)
    , 9);
}

test "get_metatable retrieves correct metatable" {
    try t.top_true(
        \\ const mt = {__len = fn(self) 50}
        \\ const t = set_metatable({}, mt)
        \\ const retrieved_mt = get_metatable(t)
        \\ retrieved_mt == mt
    );
}

test "metamethod with tuple self parameter" {
    try t.top_number(
        \\ const mt = {__len = fn(self) 10}
        \\ const t = set_metatable((1, 2, 3), mt)
        \\ len(t)
    , 10);
}

test "multiple tables can share same metatable" {
    try t.top_true(
        \\ const mt = {__len = fn(self) 77}
        \\ const t1 = set_metatable({}, mt)
        \\ const t2 = set_metatable({x = 1}, mt)
        \\ len(t1) == 77 and len(t2) == 77
    );
}

test "metatable metamethods don't shadow table operations" {
    try t.top_number(
        \\ const mt = {__len = fn(self) 100}
        \\ const t = set_metatable({a = 1, b = 2}, mt)
        \\ (t.a) + (t.b)
    , 3);
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
    defer alloc.free(built.ok.instructions);
    defer alloc.free(built.ok.spans);
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

test "table lookup order" {
    try t.top_string(
        \\ const mt = {metafield = "second-", __index = fn(self) "last"}
        \\ const t = set_metatable({normal = "first-"}, mt)
        \\ t.normal + t.metafield + t.something
    , "first-second-last");
}

test "computed table keys use runtime values" {
    try t.top_number(
        \\ const key = "answer"
        \\ const t = {[key] = 41}
        \\ t["answer"]
    , 41);

    try t.top_number(
        \\ const k = :x
        \\ const t = {[k] = 9}
        \\ t.x
    , 9);
}

test "builtin functions respect metamethods" {
    try t.top_true(
        \\ const mt = {__eq = fn(a, b) 1}
        \\ const t = set_metatable({}, mt)
        \\ t == :anything
    );
    try t.top_true(
        \\ const mt = {__lt = fn(a, b) 1}
        \\ const t = set_metatable({}, mt)
        \\ t < :anything
    );
}

test "metamethods work with mixed types" {
    try t.top_number(
        \\ const mt = {__add = fn(a, b) 500}
        \\ const t = set_metatable({}, mt)
        \\ t + "string"
    , 500);
    try t.top_number(
        \\ const mt = {__add = fn(a, b) 600}
        \\ const t = set_metatable({}, mt)
        \\ t + (1, 2, 3)
    , 600);
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
    try t.top_true("err?((:err, :Bad))");
    try t.top_true("err?((:err, :FileNotFound))");
    try t.top_false("err?((:ok, :Bad))");
}

test "result predicates replace native functions" {
    try t.top_true("ok?((:ok, 42))");
    try t.top_true("ok?((:ok, :nil))");
    try t.top_false("ok?((:err, :Bad))");
    try t.top_true("err?((:err, :Bad))");
    try t.top_false("err?((:ok, 42))");
}

test "result and error conventions work with match" {
    try t.top_true(":true");
}

test "@try panics on err result" {
    try t.expectRuntimeFailureWithMessage(
        \\ @try((:err, :Unlucky))
    , .Panic, ":Unlucky");
}

test "@try works on tuples immediately" {
    try t.expectRuntimeFailureWithMessage(
        \\ (:err, :Unlucky):unwrap()
    , .Panic, ":Unlucky");
}

test "@try panics on bullshit" {
    try t.expectRuntimeError(
        \\ @try "yo"
    , .TypeError);
}

//
// macro
// pattern grammar: %x (capture), %x:type (typed), %GROUP(...)*+? (quantified groups)
//

test "zero-arg macro expands on identifier use" {
    try t.top_number(
        \\const answer = macro `` `42`
        \\answer
    , 42);
}

test "unary macro expands in call position" {
    try t.top_number(
        \\ const id = macro `%e:expr` `%e`
        \\ id(42)
    , 42);
}

test "pipe works" {
    try t.top_number(
        \\ const f = fn(a) a * 2
        \\ 21 |> f
    , 42);
}

test "pipes accept closures" {
    try t.top_number(
        \\ 20 |> fn(x) x + 22
    , 42);
}

test "double pipe" {
    try t.top_number(
        \\ fn a(x) x * 2
        \\ fn b(x) x + 2
        \\ 20 |> a |> b
    , 42);
}

// test "side prefix" {
//     // mean must be a side-effect-only procedure. it is fully ignored
//     try t.top_number(
//         \\ 40 + side print("hi") 2
//     , 42);
//     try t.top_number(
//         \\ let t = 0
//         \\ t += 2
//     , 42);
// }

// test "pipe and println macros expand" {
//     try t.top_atom(
//         \\ const println! = macro `(%fmt:str %ARGS(, %arg:expr)*)` `print(fmt(%fmt %ARGS(, %arg)))`
//         \\ "yo"
//         \\ |> print
//         \\ println!("%v %v", 1, 2)
//     , revo.core_atoms.str(.ok));
// }

test "macro system capabilities and limitations" {
    try t.top_number(
        \\ const id = macro `%x:expr` `%x`
        \\ id(42)
    , 42);

    try t.top_number(
        \\ const count_args = macro `(%fmt:str %ARGS(, %arg:expr)*)` `3`
        \\ count_args("format", 1, 2, 3)
    , 3);
}

// basic simple captures
test "unary macro - single expression capture" {
    try t.top_number(
        \\ const id = macro `%x:expr` `%x`
        \\ id(42)
    , 42);
}

test "binary structure macro - multiple captures with literals" {
    try t.top_number(
        \\ const combine! = macro `(%left:expr %right:expr)` `%left + %right`
        \\ combine!(20, 22)
    , 42);
}

// type-consrtained captures
test "identifier capture - creates bindings" {
    try t.top_number(
        \\ const const! = macro `%name:ident = %val:expr` `const %name = %val`
        \\ const!(answer = 42)
        \\ answer
    , 42);
}

test "string literal capture - constrains to string" {
    try t.top_type(
        \\ const get_format! = macro `(%fmt:str %rest:expr)` `%fmt`
        \\ get_format!("hello", 123)
    , .string);
}

test "number literal capture - constrains to number" {
    try t.top_number(
        \\ const repeat_val! = macro `(%n:number %body:expr)` `%n`
        \\ repeat_val!(42, (1 + 2))
    , 42);
}

// repetition groups
test "zero-or-more repetition - captures multiple items" {
    try t.top_nil(
        \\ const do_all! = macro `(%ITEMS(%item:expr)*)` `do %ITEMS(%item) :nil end`
        \\ do_all!(1, 2, 3)
    );
}

test "one-or-more repetition - at least one required" {
    try t.top_number(
        \\ const sum_all! = macro `(%first:expr %REST(%item:expr)*)` `%first %REST(+ %item)`
        \\ sum_all!(10, 15, 17)
    , 42);
}

test "optional group - zero or one occurrence" {
    try t.top_number(
        \\ const maybe_print! = macro `(%val:expr %MSG(%msg:str)?)` `%val`
        \\ maybe_print!(42, "hello")
    , 42);
}

test "comma-separated repetition - literal separators" {
    try t.top_number(
        \\ const tuple_fst! = macro `(%first:expr %REST(%item:expr)*)` `%first`
        \\ tuple_fst!(10, 15, 17)
    , 10);
}

// complex combinations
test "if-elif-else chain multiple groups with quantifiers" {
    try t.top_number(
        \\ const choose! = macro
        \\     `(%head:number %ITEMS(%item:number)* %MSG(%msg:str)?)`
        \\     `do %head %ITEMS(+ %item) end`
        \\
        \\ choose!(10, 15, 17, "done")
    , 42);
}

test "complex fn def captures, repetition, optional" {
    try t.top_number(
        \\ const sum_from! = macro `(%start:number %ITEMS(%item:expr)+)`
        \\     `do %start %ITEMS(+ %item) end`
        \\
        \\ sum_from!(10, 15, 17)
    , 42);
}

// kw-based control flow
test "negative conditional" {
    try t.top_type(
        \\ const unless! = macro `(%cond:expr %body:expr)` `if %cond nil else %body`
        \\ unless!(5 < 0, :positive)
    , .atom);
}

test "custom keyword structure - keywords at multiple positions" {
    try t.top_number(
        \\ const repeat_until! = macro `(%body:expr %cond:expr)` `%body`
        \\ repeat_until!(10 + 32, 5 == 0)
    , 42);
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
    try t.top_type(
        \\ const pair_down = fn(n) if n == 0 do (:done, 0) end else pair_down(n - 1)
        \\ pair_down(2)
    , .tuple);
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

test "for loop iterates tuple values" {
    try t.top_true(":true");
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

test "while loop counts down" {
    try t.top_number(
        \\ let n = 3
        \\ while n > 0 do
        \\     n = n - 1
        \\ end
        \\ n
    , 0);
}

test "break is loop-only" {
    try t.expectCompileError("break(1)", .UnsupportedSyntax);
}

test "break for loop early" {
    try t.top_number(
        \\ let result = 0
        \\ for i in 0..10 do
        \\     if i == 5 break(i * 2)
        \\     result = result + i
        \\ end
        \\ result
    , 10);
}

test "break while loop early" {
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
}

test "break for loop with value" {
    try t.top_number(
        \\ for i in 0..10 do
        \\     if i == 7 break(i)
        \\ end
    , 7);
}

test "break while loop with value" {
    try t.top_number(
        \\ let i = 0
        \\ while i < 10 do
        \\     if i == 7 break(i)
        \\     i = i + 1
        \\ end
    , 7);
}

test "break for without value returns nil" {
    try t.top_atom(
        \\ const x = for i in 0..5 do
        \\   break
        \\ end
        \\ x
    , "nil");
}

test "break works inside fn" {
    try t.top_atom(
        \\ const x = fn()
        \\   for i in 0..5 do break
        \\   return :asdf
        \\ end
        \\ x()
    , "asdf");
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

test "runtime report carries span and message" {
    try t.expectRuntimeFailure(
        "1 / 0",
        .DivisionByZero,
        1,
        1,
        "division by zero!",
    );
}

test "runtime report includes undefined variable detail" {
    try t.expectRuntimeFailure(
        "missing_name",
        .UndefinedVariable,
        1,
        1,
        "undefined variable `missing_name`",
    );
}

test "runtime report includes not-a-function detail" {
    try t.expectRuntimeFailure(
        "1(2)",
        .NotAFunction,
        1,
        1,
        "expected function, got number",
    );
}

test "runtime report includes wrong arity detail" {
    try t.expectRuntimeFailure(
        \\ const id = fn(x) x
        \\ id()
    ,
        .WrongArity,
        2,
        2,
        "function `id` expected 1 args, got 0",
    );
}

test "runtime span for struct constructor type error points at constructor call" {
    try t.expectRuntimeFailure(
        \\ struct User {
        \\     age: number
        \\ }
        \\ User { age = "old" }
    ,
        .Panic,
        4,
        2,
        "field `age` on `User` expected number, got string",
    );
}

test "runtime span for struct field assignment type error points at assignment" {
    try t.expectRuntimeFailure(
        \\ struct User {
        \\     age: number = 0
        \\ }
        \\ let user = User {}
        \\ user.age = "old"
    ,
        .Panic,
        5,
        2,
        "field `age` on `User` expected number, got string",
    );
}

test "runtime report includes tuple index detail" {
    try t.expectRuntimeFailure(
        \\ const a, b = (1,)
        \\ a
    ,
        .InvalidTuple,
        1,
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
    defer alloc.free(built.ok.instructions);
    defer alloc.free(built.ok.spans);

    try vm.setProgramSourceName("examples/fail.rv");
    vm.mainFiber().program = built.ok.instructions;

    const result = try vm.runReport();
    switch (result) {
        .ok => return error.ExpectedRuntimeFailure,
        .err => |failure| {
            var buf = std.Io.Writer.Allocating.init(alloc);
            defer buf.deinit();
            try failure.renderAt(alloc, &buf.writer, failure.source_name orelse "<source>", source);
            try std.testing.expect(std.mem.indexOf(u8, buf.written(), "examples/fail.rv:1:1") != null);
        },
    }
}

test "runtime renderer includes stack trace call chain" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const source =
        \\ const c = fn() missing_name
        \\ const b = fn() 1 + c()
        \\ const a = fn() 1 + b()
        \\ a()
    ;
    const built = try lang.build(&vm, .{ .text = source }, .{
        .install_debug_info = true,
    });
    try std.testing.expect(built == .ok);
    defer alloc.free(built.ok.instructions);
    defer alloc.free(built.ok.spans);

    vm.mainFiber().program = built.ok.instructions;

    const result = try vm.runReport();
    switch (result) {
        .ok => return error.ExpectedRuntimeFailure,
        .err => |failure| {
            var buf = std.Io.Writer.Allocating.init(alloc);
            defer buf.deinit();
            try failure.render(alloc, &buf.writer, source);

            try std.testing.expect(std.mem.indexOf(u8, buf.written(), "stack trace:") != null);
            try std.testing.expect(std.mem.indexOf(u8, buf.written(), "0: c at <source>:1:") != null);
            try std.testing.expect(std.mem.indexOf(u8, buf.written(), "1: b at <source>:3:") != null);
            try std.testing.expect(std.mem.indexOf(u8, buf.written(), "2: a at <source>:4:") != null);
        },
    }
}

test "fn into unpack" {
    try t.top_number(
        \\ const vector_mul = fn(a, b, factor)
        \\    (a * factor, b * factor)
        \\
        \\ const (x, y) = vector_mul(4, 6, 2)
        \\ x + y
    , 20);
}

test "iterative loop" {
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

test "natives register as functions" {
    try t.top_type("len", .function);
    try t.top_type("tonumber", .function);
    try t.top_type("assert", .function);

    try t.top_true("assert(type(len) == :function)");
}

test "read reads from file path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "readme.rv",
        .data = "hello\nworld",
    });

    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);

    try t.top_string_in_dir(module_dir,
        \\ read({path = "readme.rv"}):unwrap()
    , "hello");
}

test "read accepts delimiter and path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "delim.txt",
        .data = "a|b|c",
    });

    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);

    try t.top_string_in_dir(module_dir,
        \\ read({path = "delim.txt", delimiter = "|"}):unwrap()
    , "a");
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
        \\ const a = import "counter"
        \\ a.count = 41
        \\ const b = import "counter"
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
        \\ {answer = x}
        ,
    });

    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);

    try t.top_number_in_dir(module_dir,
        \\ let x = 99
        \\ const mod = import "answer"
        \\ x + mod.answer
    , 140);
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

test "structs build table-backed instances" {
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
    , "table");
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
    , .Panic, "field `age` on `User` expected number, got string");
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

test "structs reject bad inputs" {
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
    try t.expectRuntimeFailureWithMessage(
        \\ struct User {
        \\     age: number
        \\ }
        \\ User { age = "old" }
    , .Panic, "field `age` on `User` expected number, got string");
}

test "string with rejects empty replacement char" {
    try t.expectRuntimeFailureWithMessage(
        \\ "abc":with(1, "")
    , .TypeError, "argument 2: expected non-empty string, got string");
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

test "top module globals do not leak into imported module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "leakcheck.rv",
        .data =
        \\ x
        ,
    });

    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);

    try t.expectRuntimeErrorInDir(module_dir,
        \\ let x = 99
        \\ import "leakcheck"
    , .Panic);
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

    try t.expectRuntimeErrorInDir(module_dir,
        \\ import "setx"
        \\ x
    , .UndefinedVariable);
}

test "imported module assignment is private to module cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "private_state.rv",
        .data =
        \\ const y = 7
        \\ {value = y}
        ,
    });

    const module_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(module_dir);

    try t.top_number_in_dir(module_dir,
        \\ const m = import "private_state"
        \\ m.value
    , 7);

    try t.expectRuntimeErrorInDir(module_dir,
        \\ import "private_state"
        \\ y
    , .UndefinedVariable);
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

test "non-tail recursion still overflows" {
    try t.expectRuntimeFailureWithMessage(
        \\ const count = fn(n)
        \\     if n == 1000
        \\         n
        \\     else
        \\         1 + count(n + 1)
        \\ count(0)
    ,
        .StackOverflow,
        "stack overflow!",
    );
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
test "match falls through to wildcard" {
    try t.top_number(
        \\ const x = 999
        \\ match x
        \\ | 1 do 1 end
        \\ | 2 do 2 end
        \\ | v do v end
    , 999);
}

test "match guard prevents match" {
    try t.top_number(
        \\ const x = 15
        \\ match x
        \\ | v when v < 10 do 1 end
        \\ | v when v > 10 do 2 end
        \\ | v do 3 end
    , 2);
}

test "match patterns" {
    try t.top_number(
        \\ const x = (:ok, 42)
        \\ match x
        \\ | (:asdf, v) 1
        \\ | (:ok, v) v
        \\ | (:err, e) 2
    , 42);
}

test "match patterns with guards" {
    try t.top_number(
        \\ const x = (:ok, 42)
        \\ match x
        \\ | (:asdf, v) 1
        \\ | (:ok, v) when v < 20 2
        \\ | (:ok, v) when v > 40 v
        \\ | (:ok, v) when number?(v) 3
        \\ | (:err, e) 2
    , 42);
}

//
// table
//
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
    , .InvalidAssignmentTarget, 2, 6, "assignment target is not declared");
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

test "recursive function with guards" {
    try t.top_number(
        \\ const sum = fn(n)
        \\     match n
        \\     | 0 do 0 end
        \\     | x do x + sum(x - 1) end
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
        \\     | v when v > 50 do 1 end
        \\     | v when v > 25 do 2 end
        \\     | v do 3 end
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

test "bullshit: metatable constructors closures and method chaining" {
    try t.top_number(
        \\ let Counter = set_metatable({}, {
        \\   new = fn(start) do
        \\     const state = {n = start}
        \\     set_metatable(state, {
        \\       inc = fn(s, step) do s.n = s.n + step s end,
        \\       value = fn(s) s.n
        \\     })
        \\   end
        \\ })
        \\ let a = Counter.new(10)
        \\ let b = Counter.new(1)
        \\ a:inc(5):inc(7)
        \\ b:inc(2)
        \\ a:value() * 10 + b:value()
    , 223);
}

test "bullshit: import cache and result tuples" {
    if (true) return error.SkipZigTest;
}

test "defer executes on scope exit" {
    if (true) return error.SkipZigTest;
    // TODO: nyi
}

test "string escaping works" {
    try t.top_string("\"hello\\nworld\"", "hello\nworld");
}

test "single and double quotes are distinct" {
    try t.top_string("'hello\\nworld'", "hello\\nworld");
    try t.top_string("\"hello\\nworld\"", "hello\nworld");
}

test "use imports and binds module to scope" {
    if (true) return error.SkipZigTest;
    // TODO: nyi
}

test "spawn creates fiber and join returns result" {
    try t.top_number(
        \\ const add = fn(a, b) a + b
        \\ const h = spawn add(20, 22)
        \\ const r = join(h)
        \\ r
    , 42);
}

test "spawn multiple fibers and join each" {
    try t.top_number(
        \\ const make_val = fn(x) x
        \\ const a = spawn make_val(10)
        \\ const b = spawn make_val(20)
        \\ const c = spawn make_val(12)
        \\ join(a) + join(b) + join(c)
    , 42);
}

test "spawned fiber with sleep completes" {
    try t.top_number(
        \\ const f = fn(n) do sleep(1) n * 2 end
        \\ const h = spawn f(21)
        \\ join(h)
    , 42);
}

test "channel send and recv between fibers" {
    try t.top_number(
        \\ const ch = chan(0)
        \\ const sender = fn(c, v) do send(c, v) v end
        \\ const s = spawn sender(ch, 42)
        \\ const msg = recv(ch)
        \\ join(s)
        \\ msg
    , 42);
}

test "channel buffered send then recv" {
    try t.top_number(
        \\ const ch = chan(2)
        \\ send(ch, 10)
        \\ send(ch, 32)
        \\ recv(ch) + recv(ch)
    , 42);
}

test "yield suspends and resumes fiber" {
    try t.top_type(
        \\ do yield end
    , .atom);
}

test "channel coordinate multiple workers" {
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

test "join preserves result values per handle" {
    try t.top_number(
        \\ const f = fn(x) do sleep(1) x end
        \\ const a = spawn f(100)
        \\ const b = spawn f(200)
        \\ const r1 = join(a)
        \\ const r2 = join(b)
        \\ r1 + r2
    , 300);
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

test "comp evaluates arithmetic at compile time" {
    try t.top_number(
        \\ comp (1 + 2 * 3)
    , 7);
}

test "comp evaluates nested expressions" {
    try t.top_number(
        \\ comp ((10 / 2) + (3 * 4))
    , 17);
}

test "comp with negative numbers" {
    try t.top_number(
        \\ comp (-5 + 10)
    , 5);
}

test "comp result can be used in runtime expressions" {
    try t.top_number(
        \\ let x = comp (2 + 3)
        \\ x * 2
    , 10);
}

test "comp w string concat" {
    try t.top_string(
        \\ comp ("hello" + " " + "world")
    , "hello world");
}

test "comp w comparison" {
    try t.top_atom(
        \\ comp (1 < 2)
    , "true");
}

test "comp w bool ops" {
    try t.top_atom(
        \\ comp (:true and :true)
    , "true");
}

test "comp runtime failures report the comp span" {
    try t.expectCompileFailure(
        \\ comp (1 / 0)
    , .ParseError, 1, 8, "division by zero!");
}

test "proc generated comp failures report the macro call site" {
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
// 
// shared binding gotcha doc
// 
test "closure captured in loop" {
    if (true) return error.SkipZigTest;
    try t.top_number(
        \\ const fs = {}
        \\ for i in 0..3 do
        \\     fs[i] = fn() i
        \\ end
        \\ fs[0]() + fs[1]() + fs[2]()
    , 3);
}

test "closure captures mutable outer variable" {
    if (true) return error.SkipZigTest;
    try t.top_number(
        \\ let counter = {n = 0}
        \\ const inc = fn() do counter.n = counter.n + 1 counter.n end
        \\ const dec = fn() do counter.n = counter.n - 1 counter.n end
        \\ inc() + inc() + dec()
    , 2);
    // how did it even become 4????
}

test "closure in nested scope sees updated binding" {
    if (true) return error.SkipZigTest;
    try t.top_number(
        \\ let x = 0
        \\ const fs = {}
        \\ for i in 0..5 do
        \\   if i > 0 x = x + i
        \\   fs[i] = fn() x
        \\ end
        \\ x + fs[2]() + fs[5]()
    , 17);
}

test "match nested tuple pat" {
    try t.top_number(
        \\ const data = (:ok, (:inner, 42))
        \\ match data
        \\ | (:ok, (:inner, v)) v
        \\ | _ 0
    , 42);
}

test "match nested tuple w guard" {
    try t.top_number(
        \\ const data = (:ok, (:inner, 10))
        \\ match data
        \\ | (:ok, (:inner, v)) when v < 5 1
        \\ | (:ok, (:inner, v)) when v > 5 2
        \\ | _ 0
    , 2);
}

test "match tuple head pattern" {
    // maybe some day
    if (true) return error.SkipZigTest;
    try t.top_type(
        \\ const data = (1, 2, 3, 4)
        \\ match data
        \\ | (first :: rest) rest
        \\ | _ (0,)
    , .tuple);
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

test "buffered channel fill then drain" {
    try t.top_number(
        \\ const ch = chan(3)
        \\ send(ch, 1)
        \\ send(ch, 2)
        \\ send(ch, 3)
        \\ recv(ch) + recv(ch) + recv(ch)
    , 6);
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
    try t.expectRuntimeError(
        \\ const mac! = macro `(%x:expr)` `let hidden = 99 :%x`
        \\ mac!(42)
        \\ hidden
    , .UndefinedVariable);
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
}

test "try ? returns error tuple" {
    try t.expectRuntimeFailureWithMessage(
        \\ (:err, :not_found)?
    , .Panic, ":not_found");
}

test "try ? with function call" {
    try t.top_number(
        \\ const f = fn() (:ok, 10)
        \\ f()?
    , 10);
}

test "try ? stops execution on error" {
    try t.expectRuntimeFailureWithMessage(
        \\ const f = fn() (:err, :not_found)
        \\ f()?
        \\ 99
    , .Panic, ":not_found");
}

test "try ? chains with pipe operator" {
    try t.top_number(
        \\ (:ok, 5)? |> fn(x) x * 2
    , 10);
}

test "orelse with error left side" {
    try t.top_number(
        \\ (:err, :fail) orelse 42
    , 42);
}

test "orelse with ok tuple left side unwraps" {
    try t.top_number(
        \\ (:ok, 100) orelse 42
    , 100);
}

test "orelse with nil left side" {
    try t.top_number(
        \\ :nil orelse 50
    , 50);
}

test "orelse with normal value left side" {
    try t.top_number(
        \\ 10 orelse 20
    , 10);
}

test "orelse chains" {
    try t.top_number(
        \\ (:err, :a) orelse (:err, :b) orelse 99
    , 99);
}

test "orelse right side evaluates on error" {
    try t.top_number(
        \\ const f = fn() (:err, :no)
        \\ f() orelse 77
    , 77);
}

test "combined ? and orelse" {
    try t.top_number(
        \\ (:ok, 15)? orelse 33
    , 15);
}

test "try ? in pattern matching" {
    try t.top_number(
        \\ const f = fn() (:ok, 7)
        \\ match f()?
        \\ | 7 100
        \\ | _ 0
    , 100);
}

test "error propagation stops at module level" {
    try t.expectRuntimeFailureWithMessage(
        \\ const f = fn() (:err, :fail)
        \\ f()?
    , .Panic, ":fail");
}

test "orelse unwraps after fallback" {
    try t.top_number(
        \\ (:err, :fail) orelse (:ok, 88)
    , 88);
}

test "nested ok tuples? extracts inner" {
    try t.top_type(
        \\ (:ok, (:inner, 42))?
    , .tuple);
}
