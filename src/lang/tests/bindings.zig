const revo = @import("revo");
const lang = revo.lang;

const t = revo.lang.test_helpers;

test "compiles unary operators and atom equality" {
    try t.topAtom("not :false", "true");
    try t.topAtom("not :true", "false");
    try t.topAtom("1 + 1 == 2", "true");
    try t.topNumber("len(\"abcd\")", 4);
    try t.topNumber("-5 + 7", 2);
}

test "hash starts comments only" {
    // comments are trivia now
    try t.expectTypes(
        \\do
        \\    # whole line comment
        \\    let x = ## block comment ## 1
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
    try t.topNumber(
        \\do
        \\    let a = 1
        \\    let b = 2
        \\    a + b
        \\end
    , 3);
}

test "bind, declaration and assignment are expressions and return rhs" {
    try t.topNumber(
        \\ const a = const b = 5
    , 5);
    try t.topNumber(
        \\ let a = let b = 5
    , 5);
    try t.topNumber(
        \\ const a = let b = 5
    , 5);
    try t.topNumber(
        \\ let a = 5
        \\ let b = (a = 42)
    , 42);
}

test "atoms do not collide with other values" {
    try t.topType(
        \\:do
    , .atom);
}

test "the program is in a top-level block" {
    try t.topNumber(
        \\ do const t = -41 (0 - t) + 1 end
    , 42);
}

test "blocks keep only last expression value" {
    try t.topNumber(
        \\ do
        \\   1
        \\   2
        \\   3
        \\ end
    , 3);
}

test "if uses atom false verity" {
    try t.topNumber(
        \\do
        \\    const t = {answer = 41}
        \\    if :false t.answer else t.answer + 1
        \\end
    , 42);
}

test "top verity uses atom booleans" {
    try t.topTrue(":true");
    try t.topFalse(":false");
    try t.topTrue(":ok");
}

test "top verity follows false values" {
    try t.topTrue("1");
    try t.topFalse("0");
    try t.topFalse(":nil");
    try t.topTrue("\"\"");
}

test "and/or preserve value semantics" {
    try t.topTrue("1 and 2");
    try t.topTrue("0 or 9");
    try t.topTrue("(:t or :true or not :nil or 1 or 1.0 or 67) == :t");
}

test "chained or conditions in if parse and run" {
    try t.topNumber(
        \\ const nextword = "."
        \\ if nextword == "." or nextword == "," or nextword == "!" or nextword == "?" do
        \\     1
        \\ end else do
        \\     0
        \\ end
    , 1);
}

test "assignment & op combinations" {
    try t.topNumber("let t = 41 t += 1 t", 42);
    try t.topNumber("let t = 43 t -= 1 t", 42);
    try t.topNumber("let t = 84 t /= 2 t", 42);
    try t.topNumber("let t = 21 t *= 2 t", 42);
}

test "compound assign evaluates object and key once" {
    try t.topNumber(
        \\ let n = 0
        \\ fn key() do n += 1 0 end
        \\ let t = {100}
        \\ t[key()] += 5
        \\ t[0] + n
    , 106);
    try t.topNumber(
        \\ let n = 0
        \\ let t = {v = 10}
        \\ fn obj() do n += 1 t end
        \\ obj().v += 5
        \\ t.v + n
    , 16);
}

test "comparisons" {
    try t.topFalse("1 == 2");
    try t.topTrue("assert(1 < 2)");
    try t.topTrue("assert(\"a\" < \"b\")");
}

test "atom literals are real atoms" {
    try t.topAtom(":good", "good");
}
