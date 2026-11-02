const revo = @import("revo");

const t = revo.lang.test_helpers;

test "arithmetic" {
    try t.topNumber("1 + 2 * 3", 7);
    try t.topNumber("-1", -1);
    try t.topNumber("1.5 + 2.25", 3.75);
    try t.topNumber("5.5 - 0.5", 5.0);
    try t.topNumber("3.0 * 0.5", 1.5);
    try t.topNumber("5.0 / 2.0", 2.5);
}

test "bitwise and floor division" {
    try t.topNumber("5 // 2", 2);
    try t.topNumber("-5 // 2", -3);
    try t.topNumber("-17 // 5", -4);
    try t.topNumber("17 // 5", 3);
    try t.topNumber("5 // -2", -3);

    // python semantics: `//` floors on floats too, result stays float
    try t.topNumber("5.5 // 2", 2);
    try t.topNumber("-5.5 // 2", -3);
    try t.topNumber("5.0 // 2.5", 2);
    try t.topNumber("-17.5 // 5", -4);
    try t.topNumber("7 // 2.0", 3);
    try t.topNumber("-7.25 // 2", -4);

    try t.topNumber("2 band 3", 2);
    try t.topNumber("2 bor 3", 3);
    try t.topNumber("2 bxor 3", 1);
    try t.topNumber("0 bxor 255", 255);
    try t.topNumber("12 band 10", 8);

    try t.topNumber("1 shl 4", 16);
    try t.topNumber("1 shl 63", -9223372036854775808);
    try t.topNumber("-16 shr 2", -4);
    try t.topNumber("16 shr 2", 4);
    try t.topNumber("255 shr 4", 15);

    // precedence: bitwise binds tighter than addition, looser than multiplication
    try t.topNumber("1 + 2 band 3", 3);
    try t.topNumber("1 + 2 shl 2", 9);
    try t.topNumber("1 shl 2 * 2", 16);

    // constant folding path must agree
    try t.topNumber("let a = 6 let b = 3 a band b", 2);
    try t.topNumber("let a = 6 let b = 3 a shl b", 48);
    try t.topNumber("let a = 9 let b = 2 a // b", 4);
    try t.topNumber("let a = 9.5 let b = 2 a // b", 4);
}

test "exponent" {
    try t.topNumber("2 ^ 3", 8);
    try t.topNumber("2 ^ 0", 1);
    try t.topNumber("0 ^ 0", 1);
    try t.topNumber("2 ^ 10", 1024);
    try t.topNumber("-2 ^ 3", -8);
    try t.topNumber("(-2) ^ 2", 4);

    // right-associative, binds tighter than multiplication and unary minus
    try t.topNumber("2 ^ 3 ^ 2", 512);
    try t.topNumber("2 ^ 3 * 4", 32);
    try t.topNumber("-2 ^ 2", -4);

    // negative exponent gives a float, like python
    try t.topNumber("2 ^ -1", 0.5);
    try t.topNumber("2.0 ^ 3", 8);
    try t.topNumber("2 ^ 0.5", 1.4142135623730951);
    try t.topNumber("2 ^ 63", -9223372036854775808);

    // constant folding path must agree
    try t.topNumber("let a = 3 let b = 2 a ^ b", 9);

    // compound assign
    try t.topNumber("let x = 2 x ^= 3 x", 8);
}

test "exponent errors" {
    try t.expectSemanticError("'a' ^ 2");
    try t.expectRuntimeError("fn f(a, b) do a ^ b end f(2, 'x')", .IncompatibleTypes);
    try t.expectRuntimeError("(-2) ^ 0.5", .IncompatibleTypes);
    try t.expectRuntimeError("fn f(a, b) do a ^ b end f(-2.0, 0.5)", .IncompatibleTypes);
}

test "bitwise and floor division errors" {
    // python semantics: non-integral operands fail at runtime, not compile time
    try t.expectRuntimeError("2 band 3.5", .IncompatibleTypes);
    try t.expectRuntimeError("1 shl 2.5", .IncompatibleTypes);
    try t.expectRuntimeError("2.0 bor 3.5", .IncompatibleTypes);
    try t.expectRuntimeError("1.5 shr 2.0", .IncompatibleTypes);
    try t.expectRuntimeError("2.5 bxor 1", .IncompatibleTypes);

    // dynamic operands that turn out non-integral fail at runtime
    try t.expectRuntimeError("fn f(a, b) do a band b end f(2.5, 1)", .IncompatibleTypes);
    try t.expectRuntimeError("fn f(a, b) do a // b end f('a', 2)", .IncompatibleTypes);

    // shift amount out of range
    try t.expectRuntimeError("fn f(a, b) do a shl b end f(1, 64)", .ShiftAmountOutOfRange);
    try t.expectRuntimeError("fn f(a, b) do a shl b end f(1, -1)", .ShiftAmountOutOfRange);
    try t.expectRuntimeError("fn f(a, b) do a shr b end f(1, 70)", .ShiftAmountOutOfRange);

    // division by zero
    try t.expectRuntimeError("fn f(a, b) do a // b end f(1, 0)", .DivisionByZero);
    try t.expectRuntimeError("fn f(a, b) do a // b end f(5.5, 0)", .DivisionByZero);
}

test "concat operator" {
    // string concat
    try t.topString("'hello' ~ ' world'", "hello world");
    try t.topString("'a' ~ 'b' ~ 'c'", "abc");
    try t.topString("'' ~ 'x'", "x");
    try t.topString("'x' ~ ''", "x");

    // number concat (numbers convert to string)
    try t.topString("1 ~ 2", "12");
    try t.topString("1 ~ ' x'", "1 x");
    try t.topString("'x ' ~ 2", "x 2");
    try t.topString("1.5 ~ 2", "1.52");

    // table with __tostring metamethod
    try t.topString(
        \\const mt = {__tostring = fn(self) "custom"}
        \\const t = set_meta({}, mt)
        \\t ~ ""
    , "custom");
    try t.topString(
        \\const mt = {__tostring = fn(self) "hello"}
        \\const t = set_meta({}, mt)
        \\"x" ~ t
    , "xhello");

    // concat + comparison
    try t.topAtom("'ab' ~ 'c' == 'abc'", "true");
    try t.topAtom("'ab' ~ 'c' != 'abc'", "false");

    // compound assign
    try t.topString(
        \\let s = "a"
        \\s ~= "b"
        \\s
    , "ab");

    // mixed types fall through to display
    try t.topString(":hello ~ ' world'", ":hello world");
}

//
// semantic type checking of baselib functions
//

test "doc comments annotate functions without changing runtime behavior" {
    try t.topNumber(
        \\ #* adds numbers *#
        \\ fn add(a, b) a + b
        \\ add(20, 22)
    , 42);
}

test "return statement" {
    try t.topNumber(
        \\ do return 7 8 end
    , 7);
    try t.topAtom(
        \\ fn f() do return :ok end
        \\ f()
    , "ok");
    try t.topNumber(
        \\ fn f() do return 42 end
        \\ f()
    , 42);
}
