# basics

**revo in 1 minute**
```ruby
let a = 10       # mutable variable
const b = 20     # immutable binding
global c = 30    # module-level, visible across closures

# functions
fn add(x, y) x + y
const greet = fn(name) "hello, " + name

# tables (the universal collection type)
let t = {1, 2, 3}
let h = {name = "revo", version = 1}
h.stable = :true

# tuples - fixed-shape, immutable
const point = (10, 20)
const (x, y) = point

# pattern matching + result types
fn safe_div(a, b)
    if b == 0 err(:DivByZero)
    else ok(a / b)

match safe_div(10, 2)
    | (:ok, v)  print(v)     # 5
    | (:err, e) print(e)

# pipes
"hello" |> print
(1, 2, 3) |> fn(t) map(t, fn(x) x * 2) |> print  # (2, 4, 6)

# fibers
const h = spawn add(20, 22)
join(h)  # 42
```

## more

the fundamental types are:
- numbers - `1, 1.0, -0.14`
- tables - `{1, 7}, {k = "v", [1 + 4] = "8"}`
    they have an array part and a hashmap part, and are used to represent any other data structure
    that is not already a fundamental type (like strings). there are [some builtin methods](./std.md#table)
    anything that contains more than one item and has to be mutable should be a table.
    ```ruby
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

    struct User { # a struct for now just makes a fn called User, which returns
        name: string # the type is checked at creation time
        age: number = 42
        const get_age = fn(self) self.age
    }
    const me = User({name = "me", age = 99})
    # when you call a function with one argument, if that arg is a string
    # or a table literal, you can do so without parenteheses
    const you = User{name = "you", age = 123}
    print(you:get_age())
    ```
    they are always passed by reference, never copied unless you manually `{1,2,3}:copy()`
- atoms (a.k.a. symbols, sigils)
    only to be used to compare against other atoms

    are the way to express nil, true, and false

    they are not to be created at runtime. very useful to express tagged unions with tuples

    only `:false`, `0`, and `:nil` are falsey - everything else (including `""` and `{}`) is truthy

    for this reason, the language does not have exceptions/errors and uses
    (:err, :ErrorName) and (:ok, value) together with pattern matching, `?`, `orelse`, `:unwrap()`,
    and `ok?`/`err?` to handle errors. toplevel `?` panics instead of returning silently. there are
    helpers to check these:

    ```ruby
    ok?((:ok, 42))      # :true
    err?((:err, :Bad))  # :true
    ok(42):unwrap()    # 42  (panics on :err)
    (:err, :bad)?      # panics at toplevel
    (:err, :bad) orelse 0
    ```
- functions
    a function is very simple. it (technically) is just one expression, to which you can give parameters

    the syntax only requires for one expression. so how do you make it a real [procedure](https://stackoverflow.com/a/721107)?

    `do 1 2 3 end` allows for grouping multiple expressions together. it normally evaluates
    to just what the last expression was, and for `do 1 2 3 end`, it's 3. you can, however,
    `do 1 return 2 3 end`, which returns early with 2!

    ```ruby
    # these two are equivalent
    fn hi(a, b) a + b # most idiomatic for one-liners
    const hi = fn(a, b) a + b

    fn hi(a, b) do # most idiomatic for multiline
        if x < 0 return :none

        let x = a + b
        some(x)
    end
    fn hi(a, b) do let x = a + b return x end # works too
    fn hi(a, b) match a # ocaml influence
        | (:some, v) v + b
        | (:none) :none
    ```

    it is always first-class, no matter how it may appear

    it also captures values from the outer scope, like most modern languages

    closures capture by reference (upvalues link to outer variable slots), so mutations are visible
    to all closures sharing that variable:
    ```ruby
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

    ```ruby
    # a function
    let a = fn() 1 + 2
    let b = fn() do
        let result = some_procedure()
        return result:to_upper()
    end

    let c = fn()
        another_proc()
        |> process_result()

    # all functions are anonymous, meaning you can put them anywhere
    "hello":map(fn(c) c:upper())
    ```

    also, every function really is a function and never just a procedure.
    all expressions return something, it's just that sometimes the result is not going to be of
    much use to you
    ```ruby
    let b = {4} # {4}
    b[0] # 4
    const x = fn() b[0] += 2 # x()/0
    x() # 6
    do end # :nil
    print() # :ok
    let a = let b = 5 # both a and b are 5, line returns 5
    ```

- strings - `"string"`
    they're just like any other strings. double-quoted strings process escape sequences, while
    single-quoted strings are completely literal (no escape processing):
    ```ruby
    "hello\nworld" # newline
    'hello\nworld' # literal backslash-n
    ```
    you can also use the `"string":method()` methods:
    ```ruby
    "hello":upper()           # "HELLO"
    "  hi  ":trim()           # "hi"
    "hello":sub(1, 3)         # "ell"
    "a,b,c":split(",")        # {"a", "b", "c"}
    "hello":find("ll")        # 2, or :missing
    "hello":replace("l", "r") # "herro"
    "hello":starts_with("he") # :true
    ("abc"):with(1, "X")      # "aXc" (0-indexed, returns new string)
    "hello" + " world"        # concatenation
    "ha" * 3                  # "hahaha"
    ```
    found in the [std docs](./std.md#string)
- tuples
    arrays which you can't change the length or contents of. super useful for error handling and
    storing data you know a lot about the shape of. safer and more performant than tables, but do
    not allow for as much flexibility.
    ```ruby
    const t = (1, 2, 3)
    t[0] # 1

    # destructuring
    const (x, y) = (10, 20)

    # functions can return multiple values cleanly
    const vector_mul = fn(a, b, factor)
        (a * factor, b * factor)

    const (vx, vy) = vector_mul(4, 6, 2)
    print(vx + vy) # 20
    ```

# operators

standard arithmetic and comparison work as you'd expect:
```ruby
1 + 2 * 3  # 7
10 / 2     # 5
-(3 + 4)   # -7

1 < 2     # :true
1 == 1    # :true
1 != 2    # :true
"a" < "b" # :true, lexicographic
```

`and`/`or` preserve value semantics rather than collapsing to booleans, which makes them useful
for default values and short-circuit guards:
```ruby
1 and 2    # 2
0 or 9     # 9
0 and 999  # 0 (short-circuit)
1 or 999   # 1 (short-circuit)
not :false # :true
```

assignment operators exist and work as you'd expect. since assignment is an expression, it
returns the rhs:
```ruby
let a = 41
a += 1 # 42
a -= 1  a *= 2  a /= 2

let y = (x = 42) # y is 42
```

# control flow

## if/else

`if` is an expression and returns the value of whichever branch was taken:
```ruby
const a = if 1 == 1
    5
else
    42
print(a) # 5
```

## loop / while / for

`loop` creates a loop block. `break` exits it with a value:

```ruby
const result = loop do
    if x < 10
        x = x + 1
    else
        break(x)
end

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
```

## match

match arms are expressions. wildcards and guards let you cover complex cases cleanly:
```ruby
const r = match x
    | 1 "one"
    | 2 "two"
    | _ "other" # wildcard

# guards with when
const tier = match score
    | v when v >= 90 "A"
    | v when v >= 70 "B"
    | v              "C"

# really useful for result tuples
match safe_div(10, 0)
    | (:ok, v)  print(v)
    | (:err, e) print(fmt("error: %v", e))
```

# pipe operator
pipe passes a value as the first argument to the next function or match expression:
```ruby
fn double(x) x * 2
fn add_one(x) x + 1

21 |> double     # 42
"hello" |> print

# chain with intermediate vars
const val = 5 |> add_one # 6
val |> double            # 12

# polymorphism, with match!
fn poly(x)
  x
  |> match 
  | x when number?(x) "num"
  | x when string?(x) "str"

assert_eq(poly("asdf"), "str")
assert_eq(poly(42), "num")
```

they apply to most of the language, since everything will likely return something useful 
```ruby
const res = (2 + 2)
  |> assert_eq(4) 
  # assert has nothing useful to return, so it should return the value you passed in
  |> inspect # will print and return back the value
  |> tostring # tostring will never error
```

pipes can also be used for error handling

```ruby
# ok pipe
a = (:ok, 20)
  |>? fn(x) x + 22
assert_eq(a, 42)

# err pipe
a = (:err, :DiskFull)
  |>~ fn(v) fmt("handled %v", v)
assert_eq(a, "handled (:err, :DiskFull)")

# mixed
a =
  tonumber("no")
  |>? fn(n) n + 1
  |>~ fn(v) 0
  |> assert_eq(0)
```

becomes very powerful when mixed with expect:
```ruby
fn f(what) what * 2
  |> expect_eq(4) # will return either (:err, :NotEqual) or (:ok, 4)
  |>? "is correct"
  |>~ "is incorrect"

f(2)
f(4)
```

# iteration

`map`, `filter`, `reduce`, `each`, `find`, `all`, and `any` work uniformly on strings, tuples,
and tables:
```ruby
map((1, 2, 3), fn(x) x * 2)              # (2, 4, 6)
filter("hello", fn(c) c != "l")           # "heo"
reduce((1,2,3,4), fn(acc, x) acc + x, 0) # 10
each({a=1, b=2}, fn(v) print(v))          # side effects, returns :ok
find((1,2,3,4), fn(x) x > 2)             # 3
all((1,2,3), fn(x) x > 0)                # :true
any((1,2,3), fn(x) x > 2)                # :true
```

# errors

revo does not have exceptions and tries to crash only in extreme scenarios

this means, errors are treated as values
if a function may error, it's likely to return either
`(:ok, value)`
... or `(:err, :ErrorName)`

see examples/errors.rv for full examples

# propagation: `?` and `orelse`
revo has two operators for error handling: `?` for early return and `orelse` for defaults
```ruby
fn load_config(path) do
	const f = fs.open(path)? # has to succeed
	const raw = f:read() orelse "<none>" # can fall back
	parse_json(raw)
end
```

## the ? operator

`?` propagates errors up the call stack. if an expression is an error (`(:err, ...)`), the function returns immediately with that error. otherwise, the value is unwrapped. at toplevel, the error panics instead of returning silently.

```ruby
fn parse_int(s) match tonumber(s)
	| (:ok, n) n
	| (:err, e) return (:err, e)
end

fn parse_int_short(s) do
	tonumber(s)?
end

# in a sequence
fn parse_version(str) do
	const parts = str:split(".")
	const major = tonumber(parts[1])?
	const minor = tonumber(parts[2])?
	(:ok, (major, minor))
end
```

the toplevel is implicitly a function, so returning an error from it panics too

## test blocks

`test "name" do ... end` defines a small test body that only runs when you pass `--test`
it uses the same module scope as the rest of the file, so it can call local helpers directly

```ruby
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

## orelse

`orelse` assigns a default value when an expression is nil or an error

```ruby
# fallback to default
const name = read_file("name.txt") orelse "unknown"
const x = (:err, :not_found) orelse 0  # x = 0
const y = nil orelse 0                 # y = 0
const z = (:ok, 42) orelse 0           # z = 42
```

# fibers and channels

fibers are cooperative (not preemptive). the main fiber runs first and the run queue is FIFO.
`spawn` takes a function call expression and runs it in a new fiber. `join` blocks until it's done
and returns the result:
```ruby
const h = spawn fn(a, b) a + b (39, 3)
join(h) # 42
```

channels coordinate fibers. unbuffered channels (`chan(0)`) block the sender until a receiver
is ready. buffered channels block only when full:
```ruby
# unbuffered
const ch = chan(0)
const s = spawn fn(c) send(c, 42) (ch)
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
```ruby
do yield end
sleep(100)
```

# stdlib modules

revo ships a small set of helpful globals without imports: essentials like `print`, `read`, `cwd`,
and `@eval`, plus a few module-style namespaces

`fs` - file and directory access:
```ruby
let f = fs.open("./README.md"):unwrap()
let data = f:read()
f:close()

let dir = fs.open("./src"):unwrap()
let entries = dir:readdir():unwrap()
dir:close()

let stat = fs.open("./README.md"):unwrap():stat():unwrap()
stat.size  # file size in bytes
stat.kind  # :file or :dir
```

`json` - encode and decode json:
```ruby
json.encode(("a", "b", "c")):unwrap()  # ["a","b","c"]
json.decode("{\"a\":1}"):unwrap().a    # 1
```

`time` - wall-clock and monotonic time:
```ruby
time.now()         # current time in ms
time.now_ns()      # current time in ns
# monotonic ms
# you want the monotinic clock for measuring time between two events
time.monotonic()   
time.sleep(100)
```

`net` - tcp sockets:
```ruby
# server
const listener = net.listen(1337)
const client = net.accept(listener)
const data = net.recv(client)
net.send(client, data)
net.close(client)

# client
const conn = net.connect("127.0.0.1", 1337)
net.send(conn, "hello")
const reply = net.recv(conn)
net.close(conn)
```

`os` - system access (read from stdin, etc.)

`@eval` - evaluate a string as revo code at runtime:
```ruby
@eval("print(1 + 2)") # 3
```

# imports

`import` loads a module file and caches it - the same path always returns the same table:
```ruby
# counter.rv
let count = 0
{count = count} # whatever the last expression is becomes the module's value

# main.rv
const a = import "counter"
a.count = 41
const b = import "counter"
print(b.count) # 41 (same cached module)
```

module-level `let`/`const` are private to the module. only the returned value is shared with
the importer.

# advanced

## comptime

`comp` evaluates an expression at compile time and replaces it with the constant result in the
bytecode. compile time happens both when executing a script directly and when running
`revo build in.rv out.rvo`:
```ruby
const LIMIT = comp (1024 * 1024)
print(comp ("prefix_" + "suffix")) # prefix_suffix
print(comp (1 < 2))                # :true
print(comp read())                 # only runs at compilation time
```

## macros

macros are compile-time code transformers. they use pattern matching to capture and rearrange
syntax, which lets you extend the language without any runtime cost:
```ruby
## macro `pattern` `template`
## %e:expr   - capture any expression
## %n:ident  - capture an identifier
## %s:str    - capture a string literal

const unless! = macro `(%cond:expr %body:expr)` `if %cond :nil else %body`
unless!(5 < 0, :positive) # :positive

## repetition groups
## %GROUP(...)* - zero or more
## %GROUP(...)+ - one or more
## %GROUP(...)? - optional

const sum_all! = macro `(%first:expr %REST(%item:expr)*)` `%first %REST(+ %item)`
sum_all!(10, 15, 17) # 42
```

some macros come preloaded:
```ruby
unless!(:false, 42)                   # 42
all_true!(1, :true, "t", 1)           # :true
all_true!(1, :true, "t", 1, :false)   # :false
```

## metatables

metatables let you customize table behavior via metamethods. set one with `set_meta`:
```ruby
const mt = {
    __tostring = fn(self) "MyObj",
    __display  = fn(self) "MyObj", # used by fmt %v, falls back to __tostring
    __len      = fn(self) 42,
    __add      = fn(a, b) 100,
    __sub      = fn(a, b) 200,
    __index    = fn(self, key) 0,        # called when a field is missing
    __newindex = fn(self, key, val) nil, # intercept assignment
}
const t = set_metatable({}, mt)

len(t)    # 42
t + 5     # 100
t.missing # 0
```

plain table fields always resolve before `__index` is called. metatable fields (like methods)
resolve before `__index` too, which is how `obj:method()` works without any extra magic:
```ruby
const mt = {get_x = fn(self) self.x}
const t = set_metatable({x = 12}, mt)
t:get_x() # 12
```

forloops can also iterate over any object that has an `__iter` metamethod set

```ruby
range = set_metatable({start=1, end=10}, {
  __iter = fn(self) do
        return fn() do 
            self.start = self.start + 1
            self.start <= self.end
        end
    end
})
for x in range print(x)
```
