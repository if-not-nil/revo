---
title: 'docs'
---

<div style="display:flex; gap:1rem; align-items:flex-start; flex-wrap:wrap;">
<div>

<pre class="ascii">

⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡠⠐⠢⠒⣲⢄⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⢠⢒⢰⠄⠀⠀⠀⢀⠌⠀⠀⠀⡌⠄⣀⠂⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⡜⢸⠈⠠⡀⠀⢀⠃⠀⠀⠀⠀⠇⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⢣⠀⢀⠀⠦⡀⢧⡄⠀⣷⠁⢀⡨⠐⠒⠀⠤⢄⡀⠀⠀⠀
⠀⠀⠀⠀⢀⡀⠀⠣⡉⠢⡀⠑⡄⠃⠐⠠⠰⢁⠤⠤⠤⠀⠀⠀⠈⠢⡀⠀
⠀⠀⢀⠎⠁⠀⠀⠀⠀⠱⠎⠱⠈⢸⡀⢀⠎⠁⠀⠀⠀⠀⠀⠀⠀⠀⠈⡆
⠀⣀⢎⠾⠑⠃⠈⠁⠀⠰⠖⢉⠉⢐⣠⠖⠐⠢⣀⣀⣀⣀⠤⠒⠒⢄⠀⡇
⠸⠁⠀⣀⣀⠀⠀⢀⠤⠒⠋⢁⠔⡌⢘⢄⠀⠀⠙⡄⠀⠀⠀⠀⢗⠃⢃⠇
⠠⣤⣮⠀⠀⠀⡠⠁⠀⡴⠊⠁⠀⡇⠈⠀⠀⠀⠀⢠⠀⠀⠀⠀⠀⠈⠁⠀
⠀⠀⠀⠀⠀⢠⠁⠀⠀⠀⠀⠀⢠⠴⡄⠀⠀⠠⡀⠀⠣⡀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠸⡀⡎⣴⢒⠊⠉⠀⠀⠀⠑⠢⡀⠑⠄⠀⢱⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠑⠬⠮⠟⠀⠀⠀⠀⠀⠀⠀⠘⠦⠐⠐⠊⠀⠀⠀⠀⠀⠀
</pre>

- [more](#more)
- [types](#types)
  - [type annotations](#type-annotations)
  - [type aliases](#type-aliases)
  - [union types](#union-types)
  - [coercion](#coercion)
  - [type narrowing](#type-narrowing)
  - [runtime type predicates](#runtime-type-predicates)
  - [structural types](#structural-types)
  - [table methods](#table-methods)
  - [? suffix convention](#suffix-convention)
  - [foreign](#foreign)
- [operators](#operators)
- [control flow](#control-flow)
  - [if/else](#ifelse)
  - [loops](#loops)
  - [match](#match)
- [pipe operator](#pipe-operator)
- [iteration](#iteration)
- [errors](#errors)
  - [the ? operator](#the-operator)
  - [orelse](#orelse)
- [test blocks](#test-blocks)
- [builtins](#builtins)
- [fibers and channels](#fibers-and-channels)
- [stdlib modules](#stdlib-modules)
- [modules](#modules)
- [doc comments](#doc-comments)
- [advanced](#advanced)
  - [comptime](#comptime)
  - [macros](#macros)
  - [metatables](#metatables)

</div>
  <div style="margin-left: 2ch; flex:1; min-width:250px;">

**revo in 1 minute**

```revo
# bindings
let a = 10
const b = 20
global c = 30

const who = "world"
print("hello, #{who}!")

# functions + tables
fn add(x, y) x + y
const user = {
  name = "revo",
  points = add(a, b),
  bump = fn(self) self.points += 1,
}

# pipes
"asdf"
  |> _:upper()
  |> _:sub(1, 2)
  |> _:lower()
  |> assert_eq("sd")
  |> _ ~ "f"
  |> inspect
  |> print

# pipe with closure: fn body runs in pipe context, receives user as u
const bumped = user |> fn(u) u:bump()

#
# result values + propagation/fallback
#

# will unwrap the value, returning from this function otherwise
# when at the toplevel, panics
const n = number("42")?
const fallback = number("nope") orelse 0

# tables + destructuring
const tagged = {:ok, {user.points + n + fallback, user.name}}
const {tag, payload} = tagged
const {total, name} = payload

# destructuring
const {five, ten} = {5, 10}

let {six, seven} = {6, 7}

# match
const state = match total
  | v when v >= 84 => :high
  | _ => :low

# fibers
const h = spawn add(20, 22)

print({tag, total, name, state, join(h)})

# labeled do-blocks act as one-shot loops you can break from
let v = do/b
    let x = 21
    break/b(x * 2)
end
```

</div>
</div>

## more

to get help on any function, just go over to [./std](./std)

you can also point `:h` in the repl at any documented declaration

```text
rεvo > #* just returns 5 *#
     > global hi = fn() 5
hi()/0
rεvo > :h hi
fn hi() -> int
just returns 5
rεvo > :h print
print(args: any...) -> :ok
prints values to stdout with space separator
```

the fundamental types are:

- numbers - `1, 1.0, -0.14`
- tables - `{1, 7}, {k = "v", [1 + 4] = "8"}`
  they have an array part and a hashmap part, and are used to represent any other data structure
  that is not already a fundamental type (like strings). there are [some builtin methods](./std.md#table)
  anything that contains more than one item and has to be mutable should be a table.

    ```revo
    let arr = {1, 5, 3}
    let hashmap = {k = "v"}
    hashmap.x = "y"

    let a = {
        inner = 8, # keys are represented as atoms
        ["inner_str"] = 10, # but can be of any type with the [] syntax
        mutate = fn(self) self.inner *= 2,
        helper = fn() "helped",
    }
    print(a.inner)
    print(a["inner_str"])
    print(a.helper())
    a:mutate() # the colon syntax makes it equivalent to a.mutate(a)
    for k in a:keys()
        print(k)

    a:push(4, 5, 6)       # variadic append
    a:rawget("inner")     # bypasses __index metamethod
    a:rawset("inner", 99) # bypasses __newindex metamethod
    set_meta(a, {{}})  # replace the metatable

    type User = { name: string, age: number, get_age: function }
    fn get_age(self: User) self.age
    let me: User = { name = "me", age = 99, get_age = get_age }
    const you: User = { name = "you", age = 123, get_age = get_age }
    print(you:get_age())
    ```

  they are always passed by reference, never copied unless you manually `{1,2,3}:copy()`
- atoms (a.k.a. symbols, sigils)
  only to be used to compare against other atoms

  are the way to express nil, true, and false

  they are not to be created at runtime. very useful to express tagged unions with tables

  only `:false`, `0`, and `:nil` are falsey - everything else (including `""` and `{{}}`) is truthy

  for this reason, the language does not have exceptions/errors and uses
  {:err, :ErrorName} and {:ok, value} together with pattern matching, `?`, `orelse`, `:unwrap()`,
  and `ok?!`/`err?!` to handle errors. toplevel `?` panics instead of returning silently. there are
  helpers to check these:

    ```revo
    ok?!({:ok, 42})      # :true
    err?!({:err, :Bad})  # :true
    {:ok, 42}:unwrap() # 42  (panics on :err)
    {:err, :bad}?      # panics at toplevel
    {:err, :bad} orelse 0
    ```

- functions
  a function is very simple. it (technically) is just one expression, to which you can give parameters

  the syntax only requires for one expression. so how do you make it a real [procedure](https://stackoverflow.com/a/721107)?

  `do 1 2 3 end` allows for grouping multiple expressions together. it normally evaluates
  to just what the last expression was, and for `do 1 2 3 end`, it's 3. you can, however,
  `do 1 return 2 3 end`, which returns early with 2!

    ```revo
    # these two are equivalent
    fn hi(a, b) a + b # most idiomatic for one-liners
    const hi = fn(a, b) a + b

    fn hi(a, b) do # most idiomatic for multiline
        if a + b < 0 return :none

        a + b
    end
    fn hi(a, b) do let x = a + b return x end # works too
    fn hi(a, b) match a # ocaml influence
        | {:some, v} => v + b
        | {:none}    => :none
    ```

  parameters can be marked optional with `?`. when omitted, they default to `:no`:

    ```revo
    fn greet(name, ?greeting) greeting or "hello"

    greet("alice", "hi")  # "hi"
    greet("bob")          # "hello"  (greeting is :no, `or` goes off)
    ```

  it is always first-class, no matter how it may appear

  it also captures values from the outer scope, like most modern languages

  closures capture outer values by reference, so mutations are visible
  to all closures sharing that variable:

    ```revo
    fn make_counter() do
      let x = 0
      const inc = fn()
        x = x + 1
        x
      inc
    end

    const counter = make_counter()
    print(counter()) # 1
    print(counter()) # 2
    ```

    ```revo
    # a function
    let a = fn() 1 + 2

    # all functions are anonymous, meaning you can put them anywhere
    iter.map("hello", fn(c) c:upper())
    ```

  also, every function really is a function and never just a procedure.
  all expressions return something, it's just that sometimes the result is not going to be of
  much use to you

    ```revo
    let b = {4} # {4}
    b[0] # 4
    b[0] += 2 # 6
    do end # :nil
    print() # :ok
    let a = let b = 5 # both a and b are 5, line returns 5
    ```

- strings - `"string"`
  they're just like any other strings. double-quoted strings process escape sequences, while
  single-quoted strings are completely literal (no escape processing):

    ```revo
    "hello\nworld" # newline
    'hello\nworld' # literal backslash-n
    ```

  backtick strings `` ` `` are for macro patterns; they're parsed as raw text with
  capture placeholders:

    ```revo
    macro unless! `(%cond:expr %body:expr)` `if %cond :nil else %body`
    ```

  you can also use the `"string":method()` methods:

    ```revo
    "hello":upper()           # "HELLO"
    "  hi  ":trim()           # "hi"
    "hello":sub(1, 3)         # "ell"
    "a,b,c":split(",")        # {"a", "b", "c"}
    "hello":find("ll")        # 2, or :missing
    "hello":replace("l", "r") # "herro"
    "hello":starts_with?("he") # :true
    "hello":ends_with?("lo")   # :true
    "hello":contains?("ll")   # :true
    "hello":index_of("ll")    # 2 or :nil
    "hello":reverse()         # "olleh"
    ("abc"):with(1, "X")      # "aXc" (0-indexed, returns new string)
    string_join({"a", "b"}, ",") # "a,b"
    string.join({"a", "b"}, ",") # "a,b"  (module method)
    "hello" ~ " world"        # concatenation
    "ha" * 3                  # "hahaha"
    ```

  found in the [std docs](./std.md#string)
- tables (array part)
  sequences with 0-based indexing, useful for error handling and
  storing data you know the shape of.

    ```revo
    const t = {1, 2, 3}
    t[0] # 1

    # destructuring
    const {x, y} = {10, 20}

    # functions can return multiple values cleanly
    const vector_mul = fn(a, b, factor)
        {a * factor, b * factor}

    const {vx, vy} = vector_mul(4, 6, 2)
    print(vx + vy) # 20
    ```

## types

the compiler infers types, tracks them, and uses them to pick fast paths.
they fall back to `any` when inference fails.

### type annotations

bindings and function parameters can carry type annotations:

```revo
fn double(n: int) -> int
    n * 2
# error: argument 1 to `double` wants int, got string
double("hello")
```

return types come after `->`:

```revo
# error: return type mismatch: wanted int, got string
fn bad() -> int do "hello" end

fn add(a: int, b: int) -> int a + b
```

function-typed bindings also validate arguments:

```revo
const f: function = fn(x: int) x
# error: wants int, got string
f("hello")
```

tables can be annotated by shape, extra fields are fine:

```revo
fn greet(u: { name: string }) u.name
greet({ name = "bob", age = 40 }) # "bob"

let u: { name: string, age: int } = { name = "alice" }
# error: missing field `age`
```

array entries are positional, just the type:

```revo
let t0: {number, number} = {1, 2}

let t1: {number, number, name: string} = {1, 2, name = "me"}
# error: missing field `name`
let bad: {number, number, name: string} = {1, 2}
```

### type aliases

`type` creates a local name for a type expression:

```revo
type Result = {:ok, any} | {:err, atom}

fn safe_div(a, b) -> Result
    if b == 0 {:err, :DivByZero} else {:ok, a / b}
```

type expression syntax:

| syntax | meaning |
|--------|---------|
| `int` | built-in name or alias |
| `int?` | `int \| :nil` (optional sugar) |
| `int \| string` | union type |
| `{int, string}` | table with two array entries |
| `fn(int) -> bool` | function signature |
| `fn(?a: int) -> bool` | function signature with optional param |
| `table<int>` | table with value type `int` |
| `table<string, int>` | table with key `string`, value `int` |
| `{ name: string }` | table with field `name: string` (extra fields ok) |
| `{ number, number }` | table with two array entries (extra fields ok) |
| `{ number, name: string }` | mixed array and named fields |
| `!int` | `:ok(int) \| :err(any)` (error union sugar) |

type names cannot be used as values at runtime:

```revo
pe MyInt = int
error: type name `MyInt` used as a value
t x = MyInt
```

### ambient declarations

`declare` names something the host provides

you're gonna need this for calling functions that come from outside of revo

it works like a typed const, the compiler trusts the type and compiles references
to a plain global load, and the value must exist at runtime or you get `undefined variable`

```revo
declare MAX_ITEMS = number
const x: MAX_ITEMS = 5     # typechecks against declared type
```

function ambients declare a signature with no body. calls typecheck against it
and the return type flows into inference:

```revo
declare lamp = fn(volume: number, label: string) -> bool

fn louder() -> bool
    lamp(11, "kitchen")
```

`#* ... *#` attaches text for the lsp hover:

```revo
#* lights the lamp loudness *#
declare lamp = fn(volume: number, label: string) -> bool
```

`declare` is top-level only, once per name, order-sensitive like `const`, and
rejects value rebinding of the name.

#### `.d.rv` declaration files

a `.d.rv` file holds only `pub declare`s and `pub type`s
importing one is compile-time only,
  the file never executes and the module resolves to an empty table

```revo
# audio.d.rv
pub type Volume = number
pub declare ring = fn(volume: Volume, label: string) -> bool
```

```revo
import "audio.d.rv"

audio.ring(1, "x")     # typechecks; errors at runtime: field ring does not exist
```

both forms accept dotted heads, so an alias can name its module explicitly and is used qualifiedly:
    `pub type audio.Volume = number` is annotated as `audio.Volume`
core `Target:key` heads are rejected on `pub type`; metatable slots are values, not types.

`.d.rv` is also how shared library extensions get their types: `import
"extension.so"` looks up a sibling `extension.d.rv` by stem and types every
call against those `pub declare`s

and the standard library itself is driven by them - `src/std/iface/*.d.rv`
are the single source of truth that the runtime registration, compile-time
typing, and the [generated reference](./std) all read from

### union types

unions model tagged values. each variant is either an atom alone or an atom with a payload:

```revo
type Shape =
      {:circle, number}
    | {:rect, number, number}
    | {:point}

fn area(s: Shape) -> number
    match s
      | {:circle, r}       => 3.14 * r * r
      | {:rect, w, h}      => w * h
      | {:point}           => 0
```

### coercion

assigning a value to a typed binding coerces automatically when safe:

```revo
const n: float = 42      # int -> float, ok
const m: int = 3.14      # float -> int, error
```

- same type coerces
- `any` coerces from/to everything
- `int` -> `float`
- `:true`/`:false` -> `bool`
- atom matching a union's atom-only variant
- function types: contravariant in params, covariant in return

### type narrowing

type predicates in `if` conditions narrow the type within the branch:

```revo
let x = 42
if number?(x)
    x + 1
else
    x
```

supported predicates: `number?`, `string?`, `table?`, `atom?`, `function?`, `foreign?`

### runtime type predicates

built-in checks that narrow types at runtime:

```revo
number?(42)       # :true
string?("hi")     # :true
atom?(:true)      # :true
table?({{}})        # :true
function?(fn() 42) # :true
table?({1, 2})    # :true
```

`type(x)` returns the runtime type as an atom:

```revo
type(42)       # :number
type("hi")     # :string
type(:ok)      # :atom
type(fn() :nil) # :function
type({{}})       # :table
type({1, 2})   # :table
```

### structural types

tables carry fields and closures; structural types describe their shape:

```revo
type Person = { name: string, age: number }

# ok
let p: Person = { name = "alice", age = 30 }
```

field writes just work:

```revo
type Point = { x: number, y: number }
let p: Point = { x = 0, y = 0 }
p.y = 12
```

### table methods

methods are closures stored in the table and receive `self` as the first
argument. method fields go in the type too, so colon calls resolve to
them instead of stdlib methods with the same name:

```revo
type Counter = { n: number, inc: function }
let c: Counter = {
  n = 0,
  inc = fn(self, amount) do
    self.n = self.n + amount
  end,
}

c:inc(5)
print(c.n) # 5
```

### `?` suffix convention

functions whose name ends with `?` must return bool:

```revo
# error: function ending with ? must return bool
fn is_ok?() do :ok end

# ok
fn is_ok?() -> bool do :true end
```

### foreign

`foreign` wraps a raw pointer as a value:

```revo
type(:some_pointer)  # => :foreign
foreign?(42)         # check at runtime
```

foreign values compare by pointer identity and have no destructor; the caller manages the pointer's lifetime

## operators

standard arithmetic and comparison work as you'd expect:

```revo
1 + 2 * 3  # 7
10 / 2     # 5
-(3 + 4)   # -7

1 < 2     # :true
1 == 1    # :true
1 != 2    # :true
"a" < "b" # :true, lexicographic
```

integer division with `//` floors toward negative infinity, like python. it works on floats too
(`x // y` is `floor(x / y)`), returning an int when both operands are integral and a float otherwise
bitwise operators are spelled as words and, like python, reject non-integral operands at runtime:

```revo
5 // 2    # 2
-5 // 2   # -3
5.5 // 2  # 2 (still a float internally, displays without .0)
-5.5 // 2 # -3
7 // 2.0  # 3

2 band 3  # 2
2 bor 3   # 3
2 bxor 3  # 1
1 shl 4   # 16
-16 shr 2 # -4 (arithmetic shift)
2.5 band 1 # runtime error, like python's TypeError
```

since numbers are all the same runtime type, "integral" is judged by value: `2 band 3.0` works (3.0 is integral),
but `2 band 3.5` is an error. `// 0` is a runtime error

bitwise operators bind tighter than `+`/`-` but looser than `*`/`/`, so `1 + 2 band 3` is `1 + (2 band 3)`
rather than `(1 + 2) band 3`. `shl`/`shr` wrap on overflow; shift amounts outside 0..63 are a runtime error

`^` is exponentiation, like python's `**`. it's right-associative and binds tighter than multiplication and
unary minus (`-2 ^ 2` is `-(2 ^ 2)` == -4). integral base with non-negative integral exponent stays an
integer (wrapping); anything else gives a float (`2 ^ -1` == 0.5):

```revo
2 ^ 3     # 8
2 ^ 3 ^ 2 # 512, right-assoc
-2 ^ 2    # -4
2 ^ -1    # 0.5
2 ^ 0.5   # 1.4142135623730951
x ^= 3    # compound assign, like +=
```

numbers are plain doubles, so literals may use the full float range (1.5e300 is fine). arithmetic
overflow gives `inf` (`1e308 * 10`), which compares and propagates like math says; dividing by zero
is a runtime error, not nan

`and`/`or` preserve value semantics rather than collapsing to booleans, which makes them useful
for default values and short-circuit guards:

```revo
1 and 2    # 2
0 or 9     # 9
0 and 999  # 0 (short-circuit)
1 or 999   # 1 (short-circuit)
not :false # :true
```

assignment operators exist and work as you'd expect. since assignment is an expression, it
returns the rhs:

```revo
let a = 41
a += 1 # 42
a -= 1  a *= 2  a /= 2

let x = 42
let y = (x = 0) # y is 0 (x was reassigned)
```

`~` concatenates values into strings!!! polymorphic with fast paths for strings and numbers:

```revo
"hello" ~ " world"   # "hello world"
42 ~ " is the " ~ "answer" # "42 is the answer"
{1, 2} ~ " items"    # "{ 1, 2 } items"
:hello ~ " there"    # ":hello there" (via display writer)
"" ~ "hi"            # "hi" (empty shortcut, no alloc)
```

custom types can opt in via `__tostring`:

```revo
const t = set_meta({x = 5}, {
    __tostring = fn(self) "custom",
})
t ~ "!"  # "custom!"
```

## control flow

### if/else

`if` is an expression and returns the value of whichever branch was taken:

```revo
const a = if 1 == 1
    5
else
    42
print(a) # 5
```

### loops

`loop` creates a loop block. a loop always evaluates to `:nil`; `break` exits it, `continue` skips to the next iteration

BUT you CAN carry a value out of a loop!!!
break out of a labeled loop or do-block with a value:

```revo
let x = 0
const result = loop/l do
    if x < 10 do
        x = x + 1
    end else do
        break/l(x)
    end
end
print(result) # 10

# an unlabeled loop used as an expression is always :nil
let n = 0
const nothing = loop do
    if n < 3 do
        n = n + 1
    end else do
        break(:nil)
    end
end
print(nothing) # :nil

# skip odd numbers
let odds = 0
for i in 0..6 do
    if i % 2 == 0 continue
    odds = odds + i
end
print(odds) # 9 (1 + 3 + 5)
```

#### labeled loops

loops and do-blocks can carry a label (like `loop/a`, `for/a`, `while/a`, `do/a`). `break/a` exits the named block with the value you give it; `continue/a` restarts the named loop. a labeled block only produces a value when it is exited with a labeled break; otherwise it evaluates to `:nil`:

```revo
# break out of an outer loop from inside a nested one
let r = 0
loop/outer do
    for i in 0..5 do
        if i == 3 break/outer(r)
        r = r + 1
    end
end
print(r) # 3 (iterations i=0,1,2 before break)

# skip to the next iteration of the outer loop
let s = 0
let i = 0
while/a i < 5 do
    i = i + 1
    if i == 3 continue/a
    s = s + i
end
print(s) # 12 (1 + 2 + 4 + 5)

# labeled do-blocks act as one-shot loops you can break from
let v = do/b
    let x = 21
    break/b(x * 2)
end
print(v) # 42
```

#### while and for

```revo
let y = 0
while y < 5 do
    y = y + 1
end

# 0..n produces 0, 1, 2, ..., n-1 (inclusive start, exclusive end)
let sum = 0
for i in 0..5 do
    sum = sum + i
end
print(sum) # 15

# three-part range: start..step..end
for i in 0..2..10 do
    sum = sum + i
end # 0, 2, 4, 6, 8

# negative step also works, and open-ended ranges with a negative step
# use -inf as the sentinel so the loop runs downward forever:
for i in 10..-2.. do
    if i < 0 break
    sum = sum + i
end # 10, 8, 6, 4, 2
```

### match

match arms are expressions. wildcards and guards let you cover complex cases cleanly:

```revo
let x = 1
const r = match x
    | 1 => "one"
    | 2 => "two"
    | _ => "other" # wildcard

# guards with when
let score = 75
const tier = match score
    | v when v >= 90 => "A"
    | v when v >= 70 => "B"
    | v              => "C"

# really useful for result tables
fn safe_div(a, b) if b == 0 {:err, :DivByZero} else {:ok, a / b}

match safe_div(10, 0)
    | {:ok, v}  => print(v)
    | {:err, e} => print(fmt("error: %v", e))
```

## pipe operator

pipe passes a value as the first argument to the next expression:

```revo
fn double(x) x * 2
fn and_one(x) x + 1
fn and_both(x, a, b) x + a + b

21 |> double     # 42
"hello" |> print

# chain with intermediate vars
let val = 5 |> and_one # 6
val = 5 |> and_both(1, 2) # 8
val |> double            # 12

# you can call a method with the _: syntax
"hello" |> _:upper() # "HELLO"
"hello" |> _:sub(1, 2) # "el"

# polymorphism, with match!
fn poly(x) match x
  | v when number?(v) => "num"
  | v when string?(v) => "str"

assert_eq(poly("asdf"), "str")
assert_eq(poly(42), "num")

# ad-hoc polymorphism via method dispatch
type Foo = { age: number, display: function }
type Bar = { name: string, display: function }

let x: Foo = { age = 10, display = fn(self) fmt("a %d-yr old", self.age) }
# resolves to x.display(x) (or x:display())
x |> _:display() |> print
```

they apply to most of the language, since everything will likely return something useful

```revo
const res = (2 + 2)
  |> assert_eq(4) 
  # assert has nothing useful to return, so it should return the value you passed in
  |> inspect # will print and return back the value
  |> string # string will never error
```

pipes pair well with `?`, `orelse`, and `match` for error handling:

```revo
const n = number("41") orelse 0
n |> fn(x) x + 1 |> assert_eq(42)

match number("nope")
  | {:ok, v}  => v |> fn(x) x + 1
  | {:err, _} => 0
```

## iteration

all collection functions live under the `iter` module. transforms (`iter.map`, `iter.filter`,
`iter.take`, ...) return lazy iterators; call `iter.collect` (or `iter.collect_string`,
`iter.collect_string`) to materialize them into a value. terminal ops (`iter.reduce`,
`iter.each`, `iter.find`, `iter.all?`, `iter.any?`, `iter.count`, `iter.sum`) run eagerly:

```revo
iter.collect(iter.map({1, 2, 3}, fn(x) x * 2))   # {2, 4, 6}
iter.collect_string(iter.filter("hello", fn(c) c != "l")) # "heo"
iter.reduce({1,2,3,4}, fn(acc, x) acc + x, 0)   # 10
iter.each({a=1, b=2}, fn(v) print(v))            # side effects, returns :ok
iter.find({1,2,3,4}, fn(x) x > 2)               # 3
iter.all?({1,2,3}, fn(x) x > 0)                 # :true
iter.any?({1,2,3}, fn(x) x > 2)                 # :true
```

## slicing

`[start..end]` extracts a contiguous portion of a string or table.
`[start..step..end]` adds a step to skip elements. any bound can be omitted.

```revo
let s = "hello"
s[1..4]          # "ell"
s[..2]           # "he"   (open start)
s[3..]           # "lo"   (open end)
s[..]            # "hello" (full copy)
s[0..2..5]       # "hlo"  (step: every 2nd char)

let t = {1, 2, 3, 4, 5}
t[..3]           # {1, 2, 3}
t[3..]           # {4, 5}
t[1..4][0]       # 2
t[4..-2..0]      # {5, 3, 1}  (negative step)
t[2..2]          # {{}}  (empty)
```

## errors

revo does not have exceptions and tries to crash only in extreme scenarios

this means, errors are treated as values
if a function may error, it's likely to return either
`{:ok, value}`
... or `{:err, :ErrorName}`

see examples/errors.rv for full examples

## propagation: `?` and `orelse`

revo has two operators for error handling: `?` for early return and `orelse` for defaults

```revo
fn load_config(path) do
	const f = fs.open(path)? # has to succeed
	const raw = f:read() orelse "<none>" # can fall back
	parse_json(raw)
end
```

### the ? operator

`?` propagates errors up the call stack. if an expression is an error (`{:err, ...}`), the function returns immediately with that error. otherwise, the value is unwrapped. at toplevel, the error panics instead of returning silently.

```revo
fn parse_int(s) do
  let r = match number(s)
    | {:ok, n} => n
    | {:err, e} => return {:err, e}
  r
end

fn parse_int_short(s) do
  number(s)?
end

# in a sequence
fn parse_version(str) do
  const parts = str:split(".")
  const major = number(parts[0])?
  const minor = number(parts[1])?
  {:ok, {major, minor}}
end
```

the toplevel is implicitly a function, so returning an error from it panics too

### test blocks

`test "name" do ... end` defines a small test body that only runs when you pass `--test`
it uses the same module scope as the rest of the file, so it can call local helpers directly

```revo
fn add(a, b) a + b
fn multiply(a, b) a * b

# the body sees the same module scope as the rest of the file
test "addition" do
	expect(add(20, 22) == 42)?
	expect(add(20, 22) != 22)?
end

# you can also skip tests
test/skip "subtraction (not implemented)" do
  expect(sub(2, 3) == 5)?
end

# you can combine them into suites just like this
suite "math operations" do
  test "addition" do
    expect(add(1, 1) == 2)?
  end

  test "multiply" do
    expect(multiply(3, 4) == 12)?
  end
end

# despite everything, tests always evaluate to :nil
const x = test "nothing" do
	4
end
assert(x == :nil)
```

if a test body hits `?` on an error, it behaves like the rest of the language and panics at top-level

### orelse

`orelse` assigns a default value when an expression is nil, undef, or an error

```revo
# fallback to default
const name = fs.open("./name.txt") orelse "unknown"
const x = {:err, :not_found} orelse 0  # x = 0
const y = :nil orelse 0                # y = 0
const z = {:ok, 42} orelse 0           # z = 42
const t = {a = 1}
const w = t.b orelse 0                 # w = 0, missing keys are :undef
```

## builtins

revo ships a small set of helpful globals without imports:

`len(x)` - length of strings, tables:

```revo
len("hello")   # 5
len({1, 2, 3}) # 3
len({a=1, b=2}) # 2
```

`panic(msg)` - crashes with an error message:

```revo
panic("something went wrong")
```

`number(s)` - parse a string into a number, returns `{:ok, n}` or `{:err, :ParseError}`

```revo
number("42")?
number("nope") orelse 0
```

`string(x)` - convert any value to its string representation

```revo
string(42)      # "42"
string(:hello)  # ":hello"
```

`string_of(code)` and `string_of({codes})` - create a string from ASCII code(s):

```revo
string_of(97)       # "a"
string_of({97, 98}) # "ab"
```

`string.join(table, sep)` - join table elements into a string:

```revo
string.join({"a", "b", "c"}, ",") # "a,b,c"
```

`inspect(x)` - prints the value and returns it (useful in pipe chains):

```revo
42 |> inspect |> fn(x) x * 2 # prints 42, returns 84
```

`assert_eq(a, b)` - panics if values differ, returns `a` on success:

```revo
assert_eq(1 + 1, 2)
```

`expect(cond)` - panics if condition is false, returns `:ok` on success. commonly used with `?` in test blocks:

```revo
expect(1 + 1 == 2)?
```

`input()` - reads a line from stdin (os-only), returns `{:ok, line}` or `{:err, :EndOfStream}` on EOF. use `input({delimiter = :eof})` to read all of stdin:

```revo
const line = input():unwrap()
print(line)
```

`cwd()` - current working directory path:

```revo
print(cwd())
```

`print(...)` - prints values to stdout:

```revo
print("hello", :world, 42)
```

`type(x)` - returns the runtime type as an atom (see [types](#runtime-type-predicates))

`revo.eval(code)` - evaluate a string as revo code at runtime:

```revo
revo.eval("print(1 + 2)") # 3
```

## fibers and channels

fibers are cooperative (not preemptive). the main fiber runs first and the run queue is FIFO.
`spawn` takes a function call expression and runs it in a new fiber. `join` blocks until it's done
and returns the result:

```revo
let add = fn(a, b) a + b
const h = spawn add(39, 3)
join(h) # 42
```

channels coordinate fibers. unbuffered channels (`chan(0)`) block the sender until a receiver
is ready. buffered channels block only when full:

```revo
# unbuffered
const ch = chan(0)
const s = spawn(fn() send(ch, 42))
recv(ch) # 42
join(s)

# buffered
const bch = chan(2)
send(bch, 10)
send(bch, 32)
recv(bch) + recv(bch) # 42
```

`yield` suspends the current fiber and pushes it back to the run queue. `sleep(ms)` parks it
without blocking other fibers:

```revo
do yield end
sleep(100)
```

## stdlib modules

revo ships a small set of helpful globals without imports: essentials like `print`, `read`, `cwd`,
and `revo.eval`, plus a few module-style namespaces

`fs` - file and directory access:

```revo
let f = fs.open("./README.md"):unwrap()
let data = f:read()
f:close()

let dir = fs.open("./src"):unwrap()
let entries = dir:readdir():unwrap()
dir:close()

let stat = fs.open("./README.md"):unwrap():stat():unwrap()
stat.size  # file size in bytes
stat.kind  # :file or :dir

fs.touch("./notes.txt")?  # create an empty file when missing
let g = fs.open("./notes.txt", "w")?  # "w" creates or truncates, "a" creates or keeps
fs.mkdir("./out/build/cache", :true)?  # mkdir -p
fs.copy("./notes.txt", "./out/notes.bak")?
fs.remove("./out", :true)?  # recursive delete, without :true only empty dirs go
fs.exists?("~/")  # paths starting with ~/ expand to home
```

`json` - encode and decode json:

```revo
json.encode(("a", "b", "c")):unwrap()  # ["a","b","c"]
json.decode('{"a":1}'):unwrap().a    # 1
```

`math` - numeric helpers:

```revo
math.abs(-3)      # 3
math.floor(3.7)   # 3
math.ceil(3.2)    # 4
math.sqrt(9)      # 3
math.pow(2, 10)   # 1024
math.min(3, 7)    # 3
math.max(3, 7)    # 7
math.sin(0)       # 0.0
math.cos(0)       # 1.0
math.pi           # 3.141592653589793
```

`time` - wall-clock and monotonic time:

```revo
time.now()              # current time in ms
time.now_ns()           # current time in ns
# monotonic ms starts at program execution
time.monotonic()        # monotonic ms
time.monotonic_ns()     # monotonic ns
time.sleep(100)
```

`net` - tcp sockets:

```revo
# server
const listener = (net.listen(8080))?
const client = listener:accept()?
const data = client:recv({mode = :read_some})?
client:send(data)?
client:close()?

# client
const conn = (net.connect("127.0.0.1", 8080))?
conn:send("hello")?
const reply = conn:recv({mode = :read_some})?
conn:close()?
```

`net.connect` is offloaded from the vm thread: a slow or unreachable host won't freeze
other fibers while the kernel finishes the handshake.

`os` - system access (read from stdin, etc.)

`system` - run a subprocess and return its output:

```revo
system({"echo", "hello"}) # ("hello\n", "")
```

strings interpolate expressions with `#{{}}`. normal interpolation uses display formatting;
use `:?` for debug formatting or `:p` for pretty formatting:

```revo
const name = "world"
"hello #{name}!"
"value = #{name:?}"
"answer = #{42:p}"
```

`fmt` remains useful for dynamic format strings:

```revo
fmt("hello %s", :world)   # hello world
fmt("hello %d", "world")  # hello "world"
fmt("hello %p", :world)   # hello "world" (this one has colors)
```

`debug` - inspect the current vm state:

```revo
debug()  # table with fiber_id, pc, stack, frames, and register info
```

## modules

import resolves a string path to a table of public declarations

```revo
## ./helper.rv ##
pub fn help() do
    print("helped")
end
```

```revo
## ./main.rv ##
import "./helper"  # relative: module_dir only
import "json"      # bare: project_root -> package_path

helper.help() # helped
```

each candidate dir tries `name`, `name.rv`, `name/init.rv`

{{< ref "fn resolveImportPath(raw_path" >}}
{{< ref "NativeResult.other" >}}

```revo
import "nope"  # panic: module not found at main.rv:1:1
```

cached by absolute path + mtime. change the file, re-import reloads
cycles caught via `loading_stack` before they hang

```revo
import "config" # compile and cache
import "config" # stamp match: instant
```

<details>
<summary>for nerds</summary>

{{< ref "fn moduleStamp" >}}
{{< ref "loading_stack" >}}

**preload**
ast walk before expansion extracts macros from imports:

```revo
import "macros"
macros.repeat!(print("hi")) # macro extracted at preload time
```

{{< ref "fn preloadImports(vm" >}}
{{< ref "fn resolveModuleFile(vm" >}}

**wrapModule**
`module_scope = true` wraps root ast with exports:

```text
|# source                  |# after wrapModule
|1 pub const x = 1         |1 const @exports = {{}}
|1 pub fn add(a, b) a + b  |2 const x = 1
|3                         |3 @exports[:x] = x
|4                         |4 fn add(a, b) a + b
|5                         |5 @exports[:add] = add
|6                         |6 @exports
```

{{< ref "fn wrapModule" >}}

**compiler**
`import_stmt` is a first-class node, not sugar
compiles to: `load_global import, const "path", call 1, reg_dupe, bind_local`.
`const x = import "path"` double-binds if names differ.

{{< ref ".import_stmt => |is| {" >}}
{{< ref "if (b.value.expr == .import_stmt and b.target.expr == .ident) {" >}}

**project detection**
`Project.detect` walks ancestors for `lib.json`/`exe.json`
sets `project_root`, appends `"paths"` to `package_path`. in script mode,
simple bare names fail unless a package_path template matches

{{< ref "Project.detect" >}}
{{< ref "vm.project_root" >}}
{{< ref "vm.package_path" >}}

**module_dir**
set to importing file's dir, restored after
relative paths (`./`, `../`) check it. all bare names skip it

{{< ref "vm.module_dir" >}}

**runtime**
native `import()` fn at `std/root.zig`

{{< ref "pub fn import(args" >}}
{{< ref "fn runImportedModule(vm" >}}

`.so`/`.dylib` resolved paths load as C shared libraries via ffi.

```revo
import "sqlite3" # loads sqlite3.dylib if resolution finds it
```

</details>

## doc comments

names and types carry most of the documentation. for the rest there's
`#* ... *#`:

```revo
#* adds two numbers *#
fn add(a, b) a + b
```

multi-line works too:

```revo
#*
adds two numbers
and returns the result
*#
fn add(a, b) a + b
```

any declaration can take one - functions, type aliases, plain values:

```revo
#* named function *#
fn greet(name) "hi " + name

#* anon assigned to const *#
const shout = fn(name) name:upper()

#* method-style *#
fn math:twice(x) x * 2

#* a plain value *#
const width = 80
```

extract docs with `revo doc script.rv`:

```text
# docs for script.rv

- add/2
  adds two numbers
```

the stdlib runs on the same comments: `src/std/iface/*.d.rv` is the single
source of truth behind runtime registration, compile-time typing, and the
[generated reference]({{< ref "std" >}})

## advanced

### comptime

`comp` evaluates an expression at compile time and replaces it with the constant result in the
bytecode. compile time happens both when executing a script directly and when running
`revo build in.rv out.rvo`:

```revo
const LIMIT = comp (1024 * 1024)
print(comp ("prefix_" ~ "suffix")) # prefix_suffix
print(comp (1 < 2))                # :true
print(comp (1 + 2))                # only runs at compilation time
```

### macro

macros are compile-time code transformers. they can rewrite syntax into any
other syntax, letting you extend the language without runtime cost. there are
two kinds: pattern macros and procedural macros

> if a language doesn't have metaprogramming, the programmer **will** metaprogram it themselves

they are also how you implement variable-argument functions

{{< ref "pub const Expr" >}}

#### pattern macros (macro!)

pattern macros match a template and produce a replacement. they use backtick
patterns with typed captures:

```revo
macro unless! `(%cond:expr %body:expr)` `if %cond :nil else %body`
unless!(5 < 0, :positive) # :positive
```

capture types:

```rs
`%e:expr`  - any expression
`%n:ident` - an identifier
`%s:str`   - a string literal
```

repetition groups match sequences:

```revo
macro sum_all! `(%first:expr %REST(%item:expr)*)` `%first %REST(+ %item)`
sum_all!(10, 15, 17) # 42
```

```rs
`%GROUP(...)*` - zero or more
`%GROUP(...)+` - one or more
`%GROUP(...)?` - optional
```

#### procedural macros (proc!)

proc macros run arbitrary revo code at compile time. they receive an iterator
of ast nodes and return a new ast node:

{{< ref "pub fn parseProc(" >}}

```revo
proc add3!(iter) do
  let a = iter:next()
  let b = iter:next()
  let c = iter:next()
  {{:binary, :add, {:binary, :add, a, b}, c}}
end

print(add3!(10, 20, 12)) # 42
```

the iterator methods:
{{< ref "pub fn MacroIter" >}}

- `iter:next()` - consume and return the next ast node
- `iter:next_of(:type)` - next node, asserted to be a specific type
- `iter:peek()` - look ahead without consuming

the return value is always a table wrapping a single ast node: `{node}`

#### ast data format

the ast is encoded as tagged tables -- the same format everywhere (proc macros,
quasiquoting, and revo.parse)

they always match up with the `Expr` struct:

{{< ref "pub const Expr = union(enum)" >}}

building nodes manually works directly with the table format:

```revo
proc print!(iter) do
  let fmt = iter:next_of(:string)
  let args = {fmt}
  while iter:peek() != :nil do
    args:push(iter:next())
  end
  {{:call, {:ident, "print"}, {{:call, {:ident, "fmt"}, args, :false}}, :false}}
end

print!("hello %v", :world) # "hello :world"
```

you can inspect what the iterator receives using `iter:peek()` and `fmt("%?", ...)`:

```revo
proc what!(iter) do
    print(fmt("%?", iter:peek()))
    iter:next_of(:number)
    print(fmt("%?", iter:peek()))
    iter:next()
    iter:next()
end

what!(10, "hello", :world)
```

the `%?` format specifier prints the debug representation of any value

#### quasiquoting (`` ` ``)

backtick-quoted expressions build ast data at runtime. `%name` splices in a
variable's value:

```revo
let a = 20
let b = 22
let r = `(f(%a, %b))`
r == {:call, {:ident, "f"}, {20, 22}, :false, {}} # :true
```

numbers and atoms quote directly:

```revo
let r = `42`
r == {:number, 42} # :true

let r = `:hello`
r == {:hash, "hello"} # :true
```

tables nest:

```revo
let v = 42
let r = `{key = %v}`
r == {:table, {{{:ident, "key"}, :false, {:number, 42}}}}
```

combined with a proc macro:

```revo
proc unless!(iter) do
  let cond = iter:next()
  let body = iter:next()
  {`{:if_expr, %cond, %body, {:nil}}`}
end
```

#### gensym

`gensym()` gives you a unique interned string each call. use it to generate
fresh names that won't clash with user code:

{{< ref "pub fn gensym(" >}}

```revo
const a = gensym()
const b = gensym()
a != b # :true
```

essential for macro hygiene! create a gensym'd variable inside a quasiquote
to avoid capture:

{{< ref "var gensym_counter" >}}

```revo
proc swap!(iter) do
  let tmp = gensym()
  let a = iter:next()
  let b = iter:next()
  {{:decl, {:binding, {:ident, tmp}, :nil, a, :false}, :let, :false},
   {:assign_expr, a, b},
   {:assign_expr, b, {:ident, tmp}}}
end

let x = 1
let y = 2
swap!(x, y)
print(x, y) # 2, 1
```

#### preloaded macros

these live in `src/std/iface/root.d.rv` and merge into every build;
  stdlib groups can add more (`pub macro uri.shout! ...`), called qualified:

```revo
ok?!({:ok, 42})            # :true
err?!({:err, :Bad})        # :true
some?!({:some, 42})        # :true
# none!?({:none})          # (preloaded check for :none)
print!("hello %v", :world) # printf-style: prints "hello :world"
```

### metatables

metatables let you customize table behavior via metamethods. set one with `set_meta`:

```revo
const mt = {
    __tostring = fn(self) "MyObj",
    __display  = fn(self) "MyObj", # used by fmt %v, falls back to __tostring
    __len      = fn(self) 42,
    __index    = fn(self, key) 0,        # called when a field is missing
    __newindex = fn(self, key, val) :nil, # intercept assignment
}
const t = set_meta({{}}, mt)

len(t)    # 42
t.missing # 0
```

plain table fields always resolve before `__index` is called. metatable fields (like methods)
resolve before `__index` too, which is how `obj:method()` works without any extra magic:

```revo
const mt = {get_x = fn(self) self.x}
const t = set_meta({x = 12}, mt)
t:get_x() # 12
```

forloops can also iterate over any object that has an `__iter` metamethod set

```revo
let mt = {__iter = fn(self) do
    let i = 0
    fn() do
      i += 1
      if i > 5 :done else i
    end
  end}
let t = set_meta({start=1}, mt)
for x in t print(x)
```
