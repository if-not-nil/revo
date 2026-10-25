const revo = @import("revo");
const lang = revo.lang;

const t = revo.lang.test_helpers;

//
// match
//
test "match wildcards" {
    try t.topNumber(
        \\ const x = 999
        \\ match x
        \\ | 1 => do 1 end
        \\ | 2 => do 2 end
        \\ | v => do v end
    , 999);
    try t.topNumber(
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

test "match locals dont clobber enclosing call temps" {
    // binder used inside a call in the arm body must see the subject,
    // not callee (slots n registers share frame storage)
    try t.topString(
        \\ fn id(x) x
        \\ id(match "hi" | v => id(v))
    , "hi");
    // match used as a call argument must leave its result contiguous with the callee ([callee, arg])
    // , not stranded above a dead subject slot
    try t.topNumber(
        \\ fn id(x) x
        \\ id(match 1 | 1 => 42 | _ => 0)
    , 42);
    try t.topString(
        \\ fn id(x) x
        \\ id(match "why is it a function" | :nil => :oops | v => id(v))
    , "why is it a function");
}

test "match guards" {
    try t.topNumber(
        \\ const x = 15
        \\ match x
        \\ | v when v < 10 => do 1 end
        \\ | v when v > 10 => do 2 end
        \\ | v => do 3 end
    , 2);
    try t.topNumber(
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
test "match table array patterns" {
    try t.topNumber(
        \\ const x = {:ok, 42}
        \\ match x
        \\ | {:asdf, v} => 1
        \\ | {:ok, v} => v
        \\ | {:err, e} => 2
    , 42);
    try t.topNumber(
        \\ const x = {:ok, 42}
        \\ match x
        \\ | {:asdf, v} => 1
        \\ | {:ok, v} when v < 20 => 2
        \\ | {:ok, v} when v > 40 => v
        \\ | {:ok, v} when number?(v) => 3
        \\ | {:err, e} => 2
    , 42);
}

test "match table patterns fall through on shape mismatch" {
    try t.topNumber(
        \\ match 99
        \\ | {:ok, v} => 1
        \\ | _ => 3
    , 3);
    try t.topNumber(
        \\ match {:ok}
        \\ | {:ok, v} => 1
        \\ | _ => 4
    , 4);
    try t.topNumber(
        \\ match {:ok, 1, 2}
        \\ | {:ok, v} => 1
        \\ | _ => 5
    , 5);
    try t.topNumber(
        \\ match {1, 2, x = 9}
        \\ | {a, b} => a + b
        \\ | _ => 6
    , 3);
}

test "match table nested patterns" {
    try t.topNumber(
        \\ match {:a, {:b, 7}}
        \\ | {:a, {:b, v}} => v
        \\ | _ => 0
    , 7);
    try t.topNumber(
        \\ match {{:ok, 1}, 2}
        \\ | {{:ok, v}, _} => v
        \\ | _ => 0
    , 1);
    try t.topNumber(
        \\ match {:ok, {:x, 5}}
        \\ | {:ok, {_, v}} => v
        \\ | _ => 0
    , 5);
    try t.topNumber(
        \\ const data = {:ok, {:inner, 10}}
        \\ match data
        \\ | {:ok, {:inner, v}} when v < 5 => 1
        \\ | {:ok, {:inner, v}} when v > 5 => 2
        \\ | _ => 0
    , 2);
}

test "match ascriptions" {
    try t.topNumber(
        \\ let a = 123
        \\ match a
        \\ | x: number => x
        \\ | x: string => 0
    , 123);
    try t.topNumber(
        \\ let a = "hi"
        \\ match a
        \\ | x: number => 0
        \\ | x: string => 7
        \\ | _ => 8
    , 7);
    try t.topNumber(
        \\ let a = 123
        \\ match a
        \\ | x: string => 0
        \\ | _ => 9
    , 9);

    try t.topNumber(
        \\ match {1, 2}
        \\ | {x, y: number} => x + y
        \\ | _ => 0
    , 3);
    try t.topNumber(
        \\ match {1, "two"}
        \\ | {x, y: number} => 1
        \\ | {x, y} => 2
        \\ | _ => 3
    , 2);
    try t.topNumber(
        \\ match {:ok, 1}
        \\ | {t: :ok | :err, v} => v
        \\ | _ => 0
    , 1);
    try t.topNumber(
        \\ match {{5}, 1}
        \\ | {{n: number}, _} => n
        \\ | _ => 0
    , 5);
    try t.topNumber(
        \\ let a = {1, 2}
        \\ match a
        \\ | {x} => 10
        \\ | {x, y: number, z} => 7
        \\ | {x, y} => 5
    , 5);
}

test "ascriptions in value position are rejected" {
    try t.expectSemanticFailure(
        \\ const t = {x: number}
        \\ t
    ,
        1,
        13,
        "type ascriptions only go in match patterns",
    );
}
