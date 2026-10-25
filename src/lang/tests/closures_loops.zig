const revo = @import("revo");
const lang = revo.lang;

const t = revo.lang.test_helpers;

test "interpolated strings evaluate" {
    try t.topString(
        \\let name = "bob"
        \\"hi #{name}!"
    , "hi bob!");
    try t.topString(
        \\let v = 42
        \\"n = #{v:?}"
    , "n = 42");
}

//
// fns / imports
//

test "closures capture outer locals by reference" {
    try t.topNumber(
        \\ const make_adder = fn(x) fn(y) x + y
        \\ const add2 = make_adder(2)
        \\ add2(40)
    , 42);
    try t.topNumber(
        \\ const outer = fn() do
        \\     let x = 1
        \\     const get = fn() x
        \\     x = 2
        \\     get()
        \\ end
        \\ outer()
    , 2);
    try t.topNumber(
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
    try t.topNumber(
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
    try t.topNumber(
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
    try t.topNumber(
        \\ const fact = fn(n) if n == 0 1 else n * fact(n - 1)
        \\ fact(5)
    , 120);
    try t.topTrue(
        \\ const is_even = fn(n) if n == 0 1 else is_odd(n - 1)
        \\ const is_odd = fn(n) if n == 0 0 else is_even(n - 1)
        \\ is_even(10)
    );
    try t.topNumber(
        \\ const outer = fn() do
        \\     const fact = fn(n) if n == 0 1 else n * fact(n - 1)
        \\     fact(5)
        \\ end
        \\ outer()
    , 120);
    try t.topNumber(
        \\ const make_fact = fn(scale) do
        \\     const fact = fn(n) if n == 0 scale else n * fact(n - 1)
        \\     fact
        \\ end
        \\ const fact = make_fact(2)
        \\ fact(3)
    , 12);
}

test "loops thread state and break with a single value" {
    try t.topNumber(
        \\ let x = 0
        \\ const result = loop/l do
        \\     if x < 10
        \\         x = x + 1
        \\     else
        \\         break/l(x)
        \\ end
        \\ result
    , 10);
    try t.topNumber(
        \\ const scale = 2
        \\ let v = 1
        \\ loop/l do
        \\     if v < 10
        \\         v = v * scale
        \\     else
        \\         break/l(v)
        \\ end
    , 16);
    try t.topAtom(
        \\ loop do
        \\     break(:nil)
        \\ end
    , "loop");
    try t.topNumber(
        \\ loop/l do
        \\     break/l(42)
        \\ end
    , 42);
    try t.topNumber(
        \\ let i = 1
        \\ loop/l do
        \\     if i == 1
        \\         break/l(99)
        \\     else
        \\         break/l(i)
        \\ end
    , 99);
}

test "indexed table iteration gets value and index" {
    try t.topNumber(
        \\ for val, i in {10, 20, 30} do
        \\     if i == 1 return val
        \\ end
    , 20);
}

test "simple table_get with integer key" {
    try t.topNumber(
        \\ let t = {10, 20, 30}
        \\ t[0] + t[1] + t[2]
    , 60);
}

test "for loop over table prints all values" {
    try t.topNumber(
        \\ let s = 0
        \\ let t = {10, 20, 30}
        \\ for v in t
        \\     s = s + v
        \\ s
    , 60);
}

test "inner for loop" {
    try t.topNumber(
        \\ let t = 0
        \\ for x in 1..10
        \\  for y in 10..20 t += (x * y)
        \\ t
    , 6525);
}

test "for loop with range literal iterates numeric sequence" {
    try t.topNumber(
        \\ let sum = 0
        \\ for i in 0..5 do
        \\     sum = sum + i
        \\ end
        \\ sum
    , 10);
}

test "for loop with range literal and variable end" {
    try t.topNumber(
        \\ let n = 10
        \\ let sum = 0
        \\ for i in 0..n do
        \\     sum = sum + i
        \\ end
        \\ sum
    , 45);
}

test "for loop with range produces loop result" {
    try t.topAtom(
        \\ for i in 0..3 do
        \\     i + 10
        \\ end
    , "loop");
    try t.topNumber(
        \\ for/l i in 0..3 do
        \\     if i == 1 break/l(i + 10)
        \\ end
    , 11);
}

test "while loop runs while cond holds" {
    try t.topNumber(
        \\ let x = 0
        \\ while x < 5 do
        \\     x = x + 1
        \\ end
        \\ x
    , 5);
    try t.topNumber(
        \\ let x = 0
        \\ while :false do
        \\     x = x + 1
        \\ end
        \\ x
    , 0);
}

test "continue doesnt doesnt work outside of loop" {
    try t.expectCompileError("continue", .UnsupportedSyntax);
}

test "continue skips to next iteration" {
    try t.topNumber(
        \\ let i = 0
        \\ let result = 0
        \\ loop/l do
        \\   i += 1
        \\   if i > 5 break/l(result)
        \\   if i % 2 == 0 continue
        \\   result += i
        \\ end
    , 9);
    try t.topAtom(
        \\ let i = 0
        \\ loop do
        \\   i += 1
        \\   if i > 5 break(i)
        \\ end
    , "loop");
    try t.topNumber(
        \\ let i = 0
        \\ let result = 0
        \\ while i < 5 do
        \\   i += 1
        \\   if i % 2 == 0 continue
        \\   result += i
        \\ end
        \\ result
    , 9);
    try t.topNumber(
        \\ let result = 0
        \\ for i in 1..6 do
        \\   if i % 2 == 0 continue
        \\   result += i
        \\ end
        \\ result
    , 9);
    try t.topNumber(
        \\ let result = 0
        \\ for i in 1..3 do
        \\   for j in 1..5 do
        \\     if j == 2 continue
        \\     result += 1
        \\   end
        \\ end
        \\ result
    , 6);
}

test "break in for loops" {
    try t.topNumber(
        \\ let result = 0
        \\ for i in 0..10 do
        \\     if i == 5 break(i * 2)
        \\     result = result + i
        \\ end
        \\ result
    , 10);

    try t.topNumber(
        \\ for/l i in 0..10 do
        \\     if i == 7 break/l(i)
        \\ end
    , 7);
    try t.topAtom(
        \\ for i in 0..10 do
        \\     if i == 7 break(i)
        \\ end
    , "loop");
    try t.topAtom(
        \\ const x = for i in 0..5 do
        \\   break :nil
        \\ end
        \\ x
    , "loop");
    try t.topAtom(
        \\ const y = for/l i in 0..5 do
        \\   break/l :nil
        \\ end
        \\ y
    , "nil");
}

test "break in while loops" {
    try t.topNumber(
        \\ let x = 0
        \\ let result = 0
        \\ while x < 10 do
        \\     if x == 5 break(x * 2)
        \\     result = result + x
        \\     x = x + 1
        \\ end
        \\ result
    , 10);
    try t.topNumber(
        \\ let i = 0
        \\ while/l i < 10 do
        \\     if i == 7 break/l(i)
        \\     i = i + 1
        \\ end
    , 7);
    try t.topAtom(
        \\ let i = 0
        \\ while i < 10 do
        \\     if i == 7 break(i)
        \\     i = i + 1
        \\ end
    , "loop");
}

test "while body result is loop value after iterations" {
    try t.topAtom(
        \\ let a = 0
        \\ while a < 3 do
        \\     a += 1
        \\ end
    , "loop");
}

test "loop with locals inside does not corrupt loop result" {
    try t.topNumber(
        \\ let a = 0
        \\ let b = 1
        \\ let c = 2
        \\ let d = 3
        \\ const x = loop/l do
        \\     let e = 4
        \\     let f = 5
        \\     let g = 6
        \\     break/l(42)
        \\ end
        \\ x
    , 42);
    try t.topAtom(
        \\ const y = loop do
        \\     let e = 4
        \\     break(42)
        \\ end
        \\ y
    , "loop");
}

test "for range with preceding locals and body locals" {
    try t.topNumber(
        \\ let a = 0
        \\ let b = 1
        \\ let c = 2
        \\ let d = 3
        \\ let e = 4
        \\ let f = 5
        \\ const x = for/l i in 0..3 do
        \\     let g = 6
        \\     let h = 7
        \\     break/l(42)
        \\ end
        \\ x
    , 42);
}

test "for range with two params and preceding locals" {
    try t.topAtom(
        \\ let a = 0
        \\ const x = for i, idx in 0..3 do
        \\     i + idx
        \\ end
        \\ x
    , "loop");
}

test "triple-quoted multiline strings compile and evaluate" {
    try t.topString(
        \\ """
        \\ hello
        \\ world
        \\ """
    , "hello\nworld");

    try t.topString(
        \\ """inline"""
    , "inline");
}

test "test.skip keyword is valid syntax" {
    try t.topNil(
        \\ test / skip "skipped" do 1 + 1 end
    );
}

test "suite keyword compiles and returns nil" {
    try t.topNil(
        \\ suite "example" do
        \\     test "inner" do 1 end
        \\ end
    );

    try t.topNil(
        \\ suite "empty" do end
    );
}
